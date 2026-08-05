#!/usr/bin/env python3
"""Run mtest over its own classified suite and refuse to believe its report.

The lane is circular on purpose: `build/mtest` discovers, builds, runs and
reports mtest's own 101 classified test files, which is what makes mtest's own
verdict worthless as evidence. A runner that lost half its inventory, or
collected zero tests from every file, still prints a well-formed report and
exits 0. Two holes make that concrete:

- A module with `main()` and no collected tests builds, runs, prints "0 tests
  run" and exits 0, and `src/mtest/session/classify.mojo` classifies that PASS
  by design, with `e2e/suite/test_zero.mojo` pinning it as the documented
  ceiling. The e2e lane specifies that hole rather than checking it.
- The exec supervision ceiling is 64 in both layers
  (`native/mtest_exec_native.c` `MTEST_EXEC_SLOT_CAPACITY`,
  `src/mtest/exec/supervise.mojo` `_COMPILE_CAP`). A defect conflating that
  concurrency cap with a total-file cap would report 64 green files of 101 and
  exit 0. The whole e2e tree is 41 files whose largest fixture has 12 tests, so
  it cannot surface there.

So this harness derives the truth from the test sources on disk and reconciles
mtest's reports against it. Two independent parsers read two artifacts from one
run, plus the process exit code. The `--json` event stream is primary: per file,
`file_finished` states that file's own `passed_tests`, `parse_disposition` and
outcome, and `test_reported` NAMES every test, so the oracle asserts set
equality between the names mtest reports and the names the source declares. A
grand total cannot say that, since one module running a test twice while another
runs none nets to the same number. The console report is a cross-check over the
same run (header counts, the exact PASS-row path set, the summary band) in a
different grammar read by a different parser. Any disagreement is a loud failure
naming both sides, tagged `[json]` or `[console]`.

What this oracle does NOT prove. It proves mtest REPORTED, per file and by name,
exactly the tests the sources declare right now. Two limits follow.

It witnesses agreement, not execution. Every artifact it reads is one mtest
produced, so a defect that collected test names, skipped running their bodies
and emitted faithful-looking events would satisfy every check here. That hole is
closed beside this lane: `e2e/manifest.json` requires 22 of its 41 fixtures to
NOT report PASS (7 FAIL, 6 CRASH, 4 TIMEOUT, 3 MALFORMED-SUITE, 1 COMPILE-ERROR,
1 DRIFT), and stage 7 of `scripts/build/package_consumption.py` proves the
INSTALLED binary reports FAILURE truthfully. A fabricating mtest reds both.

It cannot prove the sources still declare every test they used to. The inventory
is derived from the tree on each run, so deleting a test function, renaming it
off its `test_` prefix, or moving it into a `struct` moves the expected count
down and a faithful mtest agrees with the smaller number. Verified: take a
3-test file, move one `def test_*` into a struct, and the lane stays green while
the total silently drops. The alternative is a committed expected count, the
hand-maintained ledger this design exists to eliminate, which someone edits to
make CI green and thereby turns a loud failure into a diff nobody reads.

The boundary:

- Loud: a file that reaches ZERO top-level `def test_*`.
  `independent_test_function_names` refuses to produce an empty inventory and
  names the path.
- Not loud: a file dropping from N to M tests where M > 0. The inventory becomes
  M, and mtest is checked against M.
- Not loud: a file LEAVING the tree, since membership is set-compared against
  the tree as it is now. Measured on an out-of-tree copy driving the real binary
  through this real oracle: deleting one whole classified file took a run from
  34 tests to 10 and still printed `selfhost: OK`, rc=0.

The sharpest removal is one character. `def test_foo` -> `def _test_foo` reads
as a deliberate privatisation and leaves no signal in CI, as does a parametric
signature such as `def test_foo[T: Copyable]()`, which this oracle's name check
and Mojo's `discover_tests` drop in lockstep. If you are here because tests went
missing, this rules out mtest having silently skipped them; check `git log -p`
for the rest. `scripts/checks/layout.py`'s `check_classified_mojo_inventory`
states the same boundary from the other side.

The inventory is derived, never declared: no committed path list, no committed
test count, nothing a human edits when adding a test file or function. See
`derive_inventory` and `independent_test_function_names`. That parser is a
deliberate port rather than an import, because it must not share a regex or a
helper with anything that also produces the report it reconciles.

`scripts/harness/watchdog.py` supervises the run under a whole-process-group
deadline. mtest's own `--timeout`/`--compile-timeout` cover a hung child; they
cannot cover a hang in mtest's own scheduler, pool or reaper, which is the code
this lane exercises.

Usage:  python -m scripts.harness.selfhost [-n WORKERS] [ROOT ...]
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
import contextlib
from dataclasses import dataclass
import math
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import sys
import threading
from typing import TYPE_CHECKING


if TYPE_CHECKING:
    from collections.abc import Mapping
    from typing import IO

from scripts.formats import json_stream
from scripts.harness import watchdog


REPO_ROOT = Path(__file__).resolve().parents[2]
MTEST = str(REPO_ROOT / "build" / "mtest")
NATIVE_OBJECT = str(REPO_ROOT / "build" / "native" / "mtest_exec_native_test.o")
DEFAULT_ROOTS = (Path("tests/unit"), Path("tests/integration"))
TEST_FILE_GLOB = "test_*.mojo"

DEFAULT_WORKERS = "auto"
"""The worker policy every pixi task runs under, absent an explicit override.

`auto` is `max(1, cores // 2)` (`src/mtest/session/pool_plan.mojo:79-95`) and
honours CPU affinity, so it scales with whatever machine runs it and nobody has
to re-measure. A fixed integer sized for a small hosted runner would use an
eighth of a 32-core development host and throw away the local speedup that
motivates running the classified suite through mtest at all. Measured: 135.0s at
auto/16 workers on 32 cores, against a run still going at 600s pinned to 4 cores
with `auto` giving 2 workers.

Hosted CI is deliberately not fixed up here, even though `auto` underserves
small runners: a standard 4-vCPU GitHub-hosted Linux runner gets 2 workers and a
3-vCPU macOS runner gets 1, fully serial. Pinning a small integer in THIS module
would make every local invocation inherit it. `.github/workflows/ci.yml` instead
passes an explicit `-n` on the `test` lane only, sized to each runner's core
count (`-n 4` Linux, `-n 3` macOS), so the override travels with the runner it
was sized for.
"""

WORKER_FLAGS = ("-n", "--workers")
"""Command-line spellings of the worker-count override.

Exists so `DEFAULT_WORKERS` can be re-measured on a differently sized host
without editing this module or the tasks that share it.
"""

TIMEOUT_ENV = "MTEST_SELFHOST_TIMEOUT_SECONDS"
DEFAULT_TIMEOUT_SECONDS = 1800.0
"""Whole-process-group ceiling for the self-hosted run, in seconds.

Measured on one 32-core host: ~134s warm, ~136s cold. The Mojo compiler cache
barely matters there, because compiling 101 files across sixteen workers hides
under the ~69s critical path of the slowest integration file. Core count
dominates: pinned to four cores with both caches cleared, the same run was still
going at 600s with 13 of 101 files outstanding.

The honest slow-host figure is therefore several times the fast one, close
enough to the watchdog's old 900s limit that a hosted runner would have produced
false timeouts. This value is chosen to be wrong in the safe direction, because
a false `rc=124` on a merely slow run looks exactly like the scheduler hang this
lane exists to detect and would be debugged as one.

`MTEST_SELFHOST_TIMEOUT_SECONDS` moves it in either direction, up to
`watchdog.MAX_TIMEOUT_SECONDS`.
"""

ARTIFACT_DIR = Path("build/tests")
ARTIFACT_NONCE_BYTES = 8

LATEST_JSON_STREAM = ARTIFACT_DIR / "selfhost.ndjson"
"""Stable copy of the last run's event stream, for a human reading a red run.

Write-only evidence. Reconciliation only ever touches the per-invocation stream
below, which is what makes the fixed name safe: two concurrent runs racing to
publish here can only decide whose complete stream is retained, never what
either concluded. The publish is an atomic rename, so this path never holds a
half-written or interleaved stream.
"""

JSON_STREAM_LIMIT_BYTES = 64 * 1024 * 1024
"""Refusal ceiling for the event stream, ~140x the ~460KB a green run writes."""

REPORTED_FAILURE_LIMIT = 40
"""How many findings are printed before the rest are counted rather than shown."""

CAPTURE_LIMIT_BYTES = 16 * 1024 * 1024
CAPTURE_TRUNCATION_MARKER = "\n[selfhost: capture limit reached; output truncated]\n"
INTERNAL_ERROR_EXIT_CODE = 70

HEADER_RE = re.compile(
    r"^root:\s+(?P<root>.*?)\s+selected:\s+(?P<selected>\d+)\s+files\s+"
    r"excluded:\s+(?P<excluded>\d+)",
    re.MULTILINE,
)
"""mtest's session header: root, selected file count, excluded file count."""

SUMMARY_RE = re.compile(
    r"^=====\s+(?P<passed>\d+) passed,\s+(?P<failed>\d+) failed,\s+"
    r"(?P<skipped>\d+) skipped"
    r"(?P<abnormal>[^(]*)"
    r"\((?P<excluded>\d+) excluded,\s+(?P<not_run>\d+) not run"
    r"(?:,\s+(?P<deselected>\d+) deselected)?\)"
    r"\s+in\s+[\d.]+s\s+=====",
    re.MULTILINE,
)
"""mtest's summary band.

`abnormal` captures everything mtest appends between the skipped count and the
parenthetical: crashed, timed out, compile error, malformed suite, compile
timeout, precompile error, flaky. A capture rather than a skip, so a nonzero
abnormal count is named instead of silently swallowed.
"""

CACHE_COUNTS_RE = re.compile(r",\s*builds:\s*\d+,\s*cached:\s*\d+")
"""The build-cache accounting mtest appends to the same band.

`builds` counts first-attempt compiles and `cached` counts artifact-store hits,
so a green lane reports `builds: N, cached: 0` against a cold store and
`builds: 0, cached: N` against a warm one. Whether this lane's store is
populated depends on what ran before it, so neither pair is pinnable and the
segment is stripped before the abnormal check rather than asserted.
"""

VERDICT_ROW_RE = re.compile(
    r"^(?P<verdict>PASS|FAIL|CRASH|TIMEOUT|COMPILE-ERROR|COMPILE-TIMEOUT"
    r"|MALFORMED-SUITE|PRECOMPILE-ERROR|FLAKY|NO-TESTS)\s+(?P<path>\S+\.mojo)(?=\s|$)",
    re.MULTILINE,
)
"""One per-file verdict row: the verdict token and the file it names.

The alternation must be exactly the file-row token set `_verdict_token` in
src/mtest/report/console.mojo can print (PASS through FLAKY, plus the
NO-TESTS substitution): any looser pattern can match a line that only looks
like a verdict row. Written out rather than derived from
`scripts/formats/vocabulary.txt`, because this parser is one of two independent
readers of the same run and a shared source would make them agree by
construction. `scripts/tests/test_vocabulary.py` reconciles the two spellings
instead, so drift is a loud failure rather than a hand-sync obligation.

Not scoped to a fixed root prefix the way `dogfood.py`'s row regex is. This
harness gets its roots at runtime and compares every row against the
disk-derived path set for exactly those roots, so a row naming a file outside
them is a membership failure rather than something to filter out first.
"""

Supervisor = Callable[..., watchdog.Termination]


@dataclass(frozen=True)
class Inventory:
    """The source-derived truth about one requested classified subset."""

    tests_by_path: Mapping[str, tuple[str, ...]]
    """Repository-relative test file to its top-level test function names."""

    @property
    def paths(self) -> tuple[str, ...]:
        """Return every inventoried file path, in sorted order."""
        return tuple(self.tests_by_path)

    @property
    def path_set(self) -> frozenset[str]:
        """Return the inventoried file paths as a set for exact comparison."""
        return frozenset(self.tests_by_path)

    @property
    def total_tests(self) -> int:
        """Return the source-derived total number of test functions."""
        return sum(len(names) for names in self.tests_by_path.values())


@dataclass(frozen=True)
class RunArtifacts:
    """The two on-disk artifacts belonging to ONE self-hosted invocation.

    Both carry a per-invocation token rather than a fixed name. Four pixi tasks
    (`test`, `test-unit`, `test-integration`, `test-file`) point at this
    harness, so two invocations on one checkout is ordinary. With fixed names,
    run A could recreate the stream in the window between run B's pre-spawn
    unlink and its post-run read, and B's per-file and per-test-name
    reconciliation would silently describe A's run. A unique path removes the
    window rather than narrowing it.
    """

    stream: Path
    """Where mtest writes this invocation's machine event stream."""
    sentinel: Path
    """Pre-created file the supervisor removes on every non-timeout ending.

    Reconciled after the run by `watchdog.validate_deadline_proof`, so a timeout
    is confirmed against filesystem state rather than trusted from the
    supervisor's own clock.
    """


def run_artifacts(repo_root: Path) -> RunArtifacts:
    """Mint the artifact paths for one invocation.

    Args:
        repo_root: The repository root the artifacts live under.

    Returns:
        Paths unique to this invocation. A random nonce carries the uniqueness,
        because pids are reused and a later run inheriting a dead run's pid
        would inherit its stream. The pid is there only to make the file legible
        to a human reading `build/tests/`.
    """
    token = f"{os.getpid()}-{secrets.token_hex(ARTIFACT_NONCE_BYTES)}"
    directory = repo_root / ARTIFACT_DIR
    return RunArtifacts(
        directory / f"selfhost.{token}.ndjson",
        directory / f"selfhost.{token}.run-deadline",
    )


def publish_latest_stream(stream: Path, repo_root: Path) -> str | None:
    """Publish one run's stream to the stable evidence path, atomically.

    The reconciled file has a per-invocation name nobody can guess, so this
    copies it to `LATEST_JSON_STREAM` as one predictable place to look after a
    red run, including a timeout's partial stream. The copy lands through
    `os.replace`, so a reader of the stable path never sees a half-written or
    interleaved stream. Losing a publish race costs evidence, never
    correctness, since nothing reads this path back.

    Args:
        stream: This invocation's stream. Absent is not an error: a run that
            died before writing one has nothing to publish.
        repo_root: The repository root the stable path lives under.

    Returns:
        A message describing why publication failed, or None on success or when
        there was nothing to publish.
    """
    if not stream.is_file() or stream.is_symlink():
        return None
    target = repo_root / LATEST_JSON_STREAM
    staging = target.with_name(f"{target.name}.{os.getpid()}.staging")
    try:
        shutil.copyfile(stream, staging)
        os.replace(staging, target)
    except OSError as exc:
        with contextlib.suppress(OSError):
            staging.unlink(missing_ok=True)
        return f"could not publish the event stream to {target}: {exc}"
    return None


@dataclass(frozen=True)
class SupervisedRun:
    """One supervised mtest run: how it ended and what it printed."""

    termination: watchdog.Termination
    stdout: str
    stderr: str
    truncated: bool = False
    """Whether either stream exceeded the capture limit and lost bytes."""


class _TeeCapture:
    """Retain a bounded byte prefix of one drained stream while passing it on.

    The watchdog tees a supervised child's pipes to whatever `sys.stdout` and
    `sys.stderr` are at spawn time, so redirecting those onto this sink is how
    the harness gets the text it parses. Passing the bytes through to the
    caller's real stream keeps a long lane visibly alive.
    """

    def __init__(self, passthrough: IO[bytes] | None, limit_bytes: int) -> None:
        """Open one bounded, pass-through capture.

        Args:
            passthrough: The caller's real byte stream, or None to only retain.
            limit_bytes: Maximum retained bytes before the truncation marker.
        """
        self._passthrough = passthrough
        self._limit_bytes = limit_bytes
        self._retained = bytearray()
        self._truncated = False
        # A drainer thread and the supervisor's own diagnostics both write here.
        self._lock = threading.Lock()

    @property
    def buffer(self) -> _TeeCapture:
        """Expose this byte sink so the watchdog tee writes undecoded chunks."""
        return self

    @property
    def truncated(self) -> bool:
        """Whether the capture limit was reached and bytes were dropped."""
        with self._lock:
            return self._truncated

    def write(self, value: str | bytes) -> int:
        """Retain the byte prefix that fits, pass every byte through.

        Args:
            value: A drained chunk of child bytes, or diagnostic text written
                by the supervisor through the redirected stream.

        Returns:
            The full length accepted, matching the stream-write interface.
        """
        encoded = (
            value.encode("utf-8", errors="replace") if isinstance(value, str) else value
        )
        with self._lock:
            remaining = self._limit_bytes - len(self._retained)
            retained = encoded[: max(0, remaining)]
            if retained:
                self._retained.extend(retained)
            if len(encoded) > len(retained):
                self._truncated = True
            passthrough = self._passthrough
        if passthrough is not None:
            try:
                passthrough.write(encoded)
                passthrough.flush()
            except (OSError, ValueError):
                # The caller's stream is gone, but retention must continue:
                # dropping the capture turns a reportable ending into an
                # unexplainable one.
                with self._lock:
                    self._passthrough = None
        return len(value)

    def flush(self) -> None:
        """Match the stream interface; retention needs no flushing."""

    def finish(self) -> str:
        """Return the retained text, marked explicitly when bytes were lost."""
        with self._lock:
            text = bytes(self._retained).decode("utf-8", errors="replace")
            truncated = self._truncated
        return text + (CAPTURE_TRUNCATION_MARKER if truncated else "")


def independent_test_function_names(source: str, origin: str) -> tuple[str, ...]:
    """Parse top-level ``def test_*`` declarations with no shared helper.

    A deliberate port rather than an import: it uses no regular expression and
    shares no helper with the code paths that produce the report it checks.
    That independence is the property being relied on, so do not "simplify" it
    into sharing a parser with anything else.

    Args:
        source: The complete text of one Mojo test file.
        origin: The repository-relative path, named in failure messages.

    Returns:
        Every top-level test function name, in declaration order.

    Raises:
        AssertionError: If the file declares no test function at all, or
            declares the same test function name twice.
    """
    names: list[str] = []
    for line in source.splitlines():
        if not line.startswith("def "):
            continue
        declaration = line.removeprefix("def ")
        opening = declaration.find("(")
        if opening == -1:
            continue
        prefix = declaration[:opening]
        name = prefix.rstrip()
        if prefix[len(name) :] and not prefix[len(name) :].isspace():
            continue
        if not name.startswith("test_") or len(name) == len("test_"):
            continue
        if not name or any(
            not (character.isascii() and (character.isalnum() or character == "_"))
            for character in name
        ):
            continue
        names.append(name)
    if not names:
        raise AssertionError(
            f"selfhost: independent oracle found no test_* functions in {origin}"
        )
    if len(names) != len(set(names)):
        raise AssertionError(
            f"selfhost: independent oracle found duplicate test function names "
            f"in {origin}"
        )
    return tuple(names)


def _reraise_walk_error(error: OSError) -> None:
    """Turn a directory-walk error into a failure instead of a silent skip."""
    raise error


def _test_files_under(root_absolute: Path, label: str) -> list[Path]:
    """Return every real test file at or under one requested root.

    Args:
        root_absolute: The absolute path of the requested root.
        label: The repository-relative spelling, named in failure messages.

    Returns:
        Absolute paths of the matching regular files, in sorted order.

    Raises:
        ValueError: If a named file is not a real test file, or if a directory
            contains a `test_*.mojo` entry that is not a regular file.
    """
    if root_absolute.is_file():
        if not root_absolute.match(TEST_FILE_GLOB) or root_absolute.is_symlink():
            raise ValueError(f"not a real {TEST_FILE_GLOB} test file: {label}")
        return [root_absolute]
    found: list[Path] = []
    for directory, _subdirectories, entries in os.walk(
        root_absolute, onerror=_reraise_walk_error, followlinks=False
    ):
        for entry in entries:
            candidate = Path(directory) / entry
            if not candidate.match(TEST_FILE_GLOB):
                continue
            if candidate.is_symlink() or not candidate.is_file():
                raise ValueError(
                    f"test file is not a regular file: {candidate} (under {label})"
                )
            found.append(candidate)
    return sorted(found)


@dataclass(frozen=True)
class Request:
    """One parsed self-host command line."""

    workers: str
    """The `-n` value to hand mtest: `auto` or a positive integer, as text."""
    roots: tuple[str, ...]
    """The requested suite roots; empty means the default classified roots."""


def parse_request(
    argv: Sequence[str], *, default_workers: str = DEFAULT_WORKERS
) -> Request:
    """Split a self-host command line into a worker count and suite roots.

    Hand-rolled rather than `argparse`, which treats an operand beginning with
    `-` as an unknown option and exits the process itself, turning a mistyped
    root into a bare `SystemExit(2)` with no `FATAL: selfhost:` line. Every
    rejection here is a `ValueError` that `main` reports in the harness's voice.

    Validating the worker value here is defense in depth. mtest's own CLI
    already rejects a non-positive or non-numeric count before it can reach the
    internal zero-means-auto sentinel (`parse_worker_count`,
    `src/mtest/config/value_validation.mojo`), exiting 4. Checking here lets the
    harness fail without spawning a subprocess, and covers a worker count
    arriving from a config file rather than this command line.

    Args:
        argv: The command line after the program name.
        default_workers: The `-n` value used when the flag is absent.

    Returns:
        The parsed request.

    Raises:
        ValueError: If the worker flag is repeated, carries no value, or carries
            anything other than `auto` or a positive integer.
    """
    workers: str | None = None
    roots: list[str] = []
    pending_flag: str | None = None
    for argument in argv:
        if pending_flag is not None:
            value, pending_flag = argument, None
        elif argument in WORKER_FLAGS:
            pending_flag = argument
            continue
        else:
            matched = next(
                (flag for flag in WORKER_FLAGS if argument.startswith(f"{flag}=")), None
            )
            if matched is None:
                roots.append(argument)
                continue
            value = argument[len(matched) + 1 :]
        if workers is not None:
            raise ValueError("the worker count was given more than once")
        if value != "auto" and not (
            value.isascii() and value.isdecimal() and int(value) > 0
        ):
            raise ValueError(
                f"worker count must be 'auto' or a positive integer: {value!r}"
            )
        workers = value
    if pending_flag is not None:
        raise ValueError(f"{pending_flag} needs a worker count")
    return Request(default_workers if workers is None else workers, tuple(roots))


def normalized_roots(repo_root: Path, paths: Sequence[str]) -> list[Path]:
    """Return narrow repository-relative suite roots, or raise ``ValueError``.

    Args:
        repo_root: The repository root every root is resolved against.
        paths: Requested roots as given on the command line. Empty means the
            default classified roots.

    Returns:
        Repository-relative roots, each an existing directory or test file.

    Raises:
        ValueError: If a root escapes the repository, leaves `tests/`, or does
            not name a real file or directory.
    """
    raw_roots = list(paths) if paths else [str(path) for path in DEFAULT_ROOTS]
    normalized: list[Path] = []
    for original in raw_roots:
        root = original
        while root.startswith("./"):
            root = root[2:]
        root = root.rstrip("/")
        candidate = Path(root)
        if not root or candidate.is_absolute() or ".." in candidate.parts:
            raise ValueError(f"unsafe suite root: {root or '<empty>'}")
        if candidate != Path("tests") and candidate.parts[:1] != ("tests",):
            raise ValueError(f"suite root must be tests/ or below: {root}")
        absolute = repo_root / candidate
        if not absolute.exists() or absolute.is_symlink():
            raise ValueError(f"suite root is not a real file or directory: {root}")
        normalized.append(candidate)
    return normalized


def derive_inventory(repo_root: Path, roots: Sequence[Path]) -> Inventory:
    """Derive the complete expected inventory from the test sources on disk.

    Nothing here is declared. The file set comes from walking the requested
    roots and the per-file test counts come from parsing each file, so adding a
    test file or a test function costs zero edits anywhere in this repository.

    Args:
        repo_root: The repository root the roots are relative to.
        roots: Repository-relative roots, as returned by `normalized_roots`.

    Returns:
        The path-to-test-names inventory for exactly those roots.

    Raises:
        ValueError: If the requested roots contain no test file at all, or
            contain an entry that is not a regular file.
        AssertionError: If a test file declares no test function, or declares
            one twice.
        OSError: If a test file or directory cannot be read.
    """
    tests_by_path: dict[str, tuple[str, ...]] = {}
    for root in roots:
        for absolute in _test_files_under(repo_root / root, str(root)):
            relative = str(absolute.relative_to(repo_root))
            if relative in tests_by_path:
                continue
            source = absolute.read_text(encoding="utf-8")
            tests_by_path[relative] = independent_test_function_names(source, relative)
    if not tests_by_path:
        raise ValueError(
            f"no {TEST_FILE_GLOB} files found under requested roots: "
            f"{[str(root) for root in roots]}"
        )
    return Inventory(dict(sorted(tests_by_path.items())))


def mtest_argv(
    mtest_path: str,
    native_object: str,
    roots: Sequence[Path],
    workers: str,
    json_path: str,
) -> list[str]:
    """Build the self-hosted run command for one set of roots.

    `-I build -I tests/support` is mandatory: the integration suites import
    `exec_helpers` and `session_fixtures` as top-level include-path modules. The
    native adapter object reaches the child compiler as a linker argument
    (`-Xlinker <obj>`), because a bare object path is not a positional and
    `mojo build src.mojo obj.o` fails with "too many input files".

    `--json` is what makes per-file reconciliation possible. The console report
    states one grand total, which can be right while the distribution behind it
    is wrong; the event stream states each file's own `passed_tests` and names
    every test it reported.

    Args:
        mtest_path: The mtest binary to run.
        native_object: The compiled native test adapter to link into each file.
        roots: Repository-relative roots to hand mtest.
        workers: The `-n` value: `auto` or a positive integer, as text. See
            `DEFAULT_WORKERS` for the pinned policy and why it is not a
            fixed integer.
        json_path: Where mtest writes its machine event stream. Required rather
            than defaulted: it must be this invocation's own path, and a default
            here would be a fixed name two concurrent runs could share.

    Returns:
        The complete argv, without shell interpretation.
    """
    return [
        mtest_path,
        "-I",
        "build",
        "-I",
        "tests/support",
        "--build-arg=--Werror",
        "--build-arg=--no-optimization",
        "--build-arg=-Xlinker",
        f"--build-arg={native_object}",
        "-n",
        workers,
        "--json",
        json_path,
        *[str(root) for root in roots],
    ]


def timeout_seconds(environment: Mapping[str, str]) -> float:
    """Read the whole-process-group ceiling for the self-hosted run.

    Args:
        environment: The harness process environment to read.

    Returns:
        The ceiling in seconds: `DEFAULT_TIMEOUT_SECONDS` unless
        `MTEST_SELFHOST_TIMEOUT_SECONDS` overrides it.

    Raises:
        ValueError: If the override is not a finite number in
            `(0, watchdog.MAX_TIMEOUT_SECONDS]`, so a typo cannot quietly
            disarm the deadline or uselessly shorten it.
    """
    raw = environment.get(TIMEOUT_ENV)
    if raw is None:
        return DEFAULT_TIMEOUT_SECONDS
    try:
        seconds = float(raw)
    except ValueError as exc:
        raise ValueError(f"{TIMEOUT_ENV} must be a number: {raw!r}") from exc
    if not math.isfinite(seconds) or not (0 < seconds <= watchdog.MAX_TIMEOUT_SECONDS):
        raise ValueError(
            f"{TIMEOUT_ENV} must be finite and between 0 and "
            f"{watchdog.MAX_TIMEOUT_SECONDS:g} seconds: {raw!r}"
        )
    return seconds


def run_mtest(
    command: Sequence[str],
    *,
    repo_root: Path,
    sentinel: Path,
    seconds: float,
    supervisor: Supervisor = watchdog.run_command,
) -> SupervisedRun:
    """Run one mtest command under a whole-process-group deadline.

    A sentinel file is created before the spawn, removed by the supervisor on
    every non-timeout ending, and reconciled here, so "this timed out" is
    confirmed against filesystem state rather than taken on the supervisor's
    word.

    Args:
        command: The complete mtest argv.
        repo_root: Working directory for the child.
        sentinel: This invocation's deadline sentinel, from `run_artifacts`.
        seconds: The wall-clock ceiling handed to the supervisor.
        supervisor: The watchdog entrypoint, injectable for tests.

    Returns:
        The structured termination plus the run's captured stdout and stderr.
        Every failure, including one raised by the supervisor itself, is
        returned as a `HarnessError` termination rather than propagated.
    """
    try:
        sentinel.parent.mkdir(parents=True, exist_ok=True)
        sentinel.unlink(missing_ok=True)
        sentinel.touch()
    except OSError as exc:
        return SupervisedRun(
            watchdog.HarnessError(f"could not create deadline sentinel: {exc}"),
            "",
            "",
        )

    stdout = _TeeCapture(getattr(sys.stdout, "buffer", None), CAPTURE_LIMIT_BYTES)
    stderr = _TeeCapture(getattr(sys.stderr, "buffer", None), CAPTURE_LIMIT_BYTES)
    # The watchdog only opens pipes when a marker retention is requested. This
    # run has no module markers to retain, so the retention gets a prefix no
    # line can carry and exists purely to turn capture on.
    retention = watchdog.MarkerRetention("\0selfhost-no-marker")
    try:
        with (
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            termination = supervisor(
                command,
                source="selfhost: classified suite",
                step="run",
                timeout_seconds=seconds,
                deadline_sentinel=sentinel,
                cwd=repo_root,
                marker_retention=retention,
            )
    # BLE001: this is the supervisor boundary. An exception escaping here would
    # wedge the gate instead of reporting a harness error for the run.
    except Exception as exc:  # noqa: BLE001
        with contextlib.suppress(OSError):
            sentinel.unlink(missing_ok=True)
        return SupervisedRun(
            watchdog.HarnessError(f"supervisor raised: {exc}"),
            stdout.finish(),
            stderr.finish(),
        )
    termination = watchdog.validate_deadline_proof(termination, sentinel)
    return SupervisedRun(
        termination,
        stdout.finish(),
        stderr.finish(),
        truncated=stdout.truncated or stderr.truncated,
    )


def _reconcile_header(
    output: str, inventory: Inventory, repo_root: Path, failures: list[str]
) -> None:
    """Check mtest's file-membership counts against the derived inventory."""
    headers = HEADER_RE.findall(output)
    if len(headers) != 1:
        failures.append(
            "[console] no single session header -- found "
            f"{len(headers)} 'root: ... selected: N files excluded: M' line(s); "
            "cannot reconcile file membership"
        )
        return
    reported_root, raw_selected, raw_excluded = headers[0]
    if reported_root != str(repo_root):
        failures.append(
            "[console] session root mismatch -- mtest reported root "
            f"{reported_root!r}, harness ran it in {str(repo_root)!r}; "
            "reported paths are not comparable to the derived inventory"
        )
    selected = int(raw_selected)
    excluded = int(raw_excluded)
    if selected != len(inventory.paths):
        failures.append(
            "[console] selected file count mismatch -- mtest selected "
            f"{selected} file(s), the sources declare {len(inventory.paths)}"
        )
    if excluded != 0:
        failures.append(
            f"[console] mtest excluded {excluded} file(s); the self-hosted "
            "lane must exclude none"
        )


def _reconcile_paths(output: str, inventory: Inventory, failures: list[str]) -> None:
    """Check the exact set of PASS-reporting paths against the derived set."""
    rows = VERDICT_ROW_RE.findall(output)
    passed = {path for verdict, path in rows if verdict == "PASS"}
    other = sorted({(verdict, path) for verdict, path in rows if verdict != "PASS"})
    if other:
        failures.append(
            "[console] mtest reported non-PASS verdict row(s): "
            + ", ".join(f"{verdict} {path}" for verdict, path in other)
        )
    expected = inventory.path_set
    if passed != expected:
        missing = sorted(expected - passed)
        extra = sorted(passed - expected)
        failures.append(
            "[console] exact path membership mismatch -- "
            f"mtest reported PASS for {len(passed)} file(s), the sources declare "
            f"{len(expected)}; "
            f"never reported: {missing}; reported but not on disk: {extra}"
        )


def _reconcile_totals(output: str, inventory: Inventory, failures: list[str]) -> None:
    """Check the per-test summary totals against the derived per-file counts."""
    matches = list(SUMMARY_RE.finditer(output))
    if len(matches) != 1:
        failures.append(
            f"[console] no single summary band -- found {len(matches)} "
            "'===== N passed, ... =====' line(s); cannot reconcile test totals"
        )
        return
    summary = matches[0]
    expected_total = inventory.total_tests
    reported_passed = int(summary.group("passed"))
    if reported_passed != expected_total:
        failures.append(
            "[console] exact test-total mismatch -- mtest reported "
            f"{reported_passed} passed, the sources declare {expected_total} "
            f"test function(s) across {len(inventory.paths)} file(s); a module "
            "that collected nothing looks exactly like this"
        )
    for group in ("failed", "skipped", "excluded", "not_run"):
        raw = summary.group(group)
        if raw is not None and int(raw) != 0:
            label = group.replace("_", " ")
            failures.append(f"[console] mtest reported {raw} {label}; must be 0")
    deselected = summary.group("deselected")
    if deselected is not None and int(deselected) != 0:
        failures.append(f"[console] mtest reported {deselected} deselected; must be 0")
    abnormal = CACHE_COUNTS_RE.sub("", summary.group("abnormal")).strip()
    if abnormal:
        failures.append(
            f"[console] mtest's summary carries abnormal file counts: {abnormal!r}; "
            "the self-hosted lane must report none"
        )


def _int_field(record: Mapping[str, object], key: str) -> int | None:
    """Return one integer field, or None when it is absent or not an integer.

    Args:
        record: One decoded stream record.
        key: The field name to read.

    Returns:
        The integer value. `bool` is rejected because it is an `int` subclass in
        Python, and reading a forged `true` as `1` is the silent coercion this
        oracle exists to refuse.
    """
    value = record.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def _str_field(record: Mapping[str, object], key: str) -> str | None:
    """Return one string field, or None when it is absent or not a string."""
    value = record.get(key)
    return value if isinstance(value, str) else None


def _file_record_problems(
    record: Mapping[str, object], declared: tuple[str, ...]
) -> list[str]:
    """Return every disagreement between one `file_finished` record and source.

    Args:
        record: One decoded `file_finished` record.
        declared: The test function names the file's source declares.

    Returns:
        One message per disagreement, each naming both sides.
    """
    problems: list[str] = []
    outcome = _str_field(record, "outcome")
    if outcome != "pass":
        problems.append(f"outcome={outcome!r} (must be 'pass')")
    # A file whose report mtest could not parse is a silent-loss case: the run
    # happened, the output was not understood, and the counts mean nothing.
    disposition = _str_field(record, "parse_disposition")
    if disposition != "parsed":
        problems.append(f"parse_disposition={disposition!r} (must be 'parsed')")
    passed = _int_field(record, "passed_tests")
    if passed != len(declared):
        problems.append(
            f"passed_tests={passed} but the source declares {len(declared)} "
            "test function(s)"
        )
    for key in ("failed_tests", "skipped_tests", "deselected_tests"):
        value = _int_field(record, key)
        if value != 0:
            problems.append(f"{key}={value} (must be 0)")
    for key in ("exit_status", "signal_number"):
        value = _int_field(record, key)
        if value != 0:
            problems.append(f"{key}={value} (must be 0)")
    attempts = _int_field(record, "attempts_used")
    if attempts != 1:
        problems.append(f"attempts_used={attempts} (must be 1; a retry hides a flake)")
    if record.get("flaky") is not False:
        problems.append(f"flaky={record.get('flaky')!r} (must be false)")
    return problems


def _reconcile_file_records(
    records: Sequence[Mapping[str, object]],
    inventory: Inventory,
    failures: list[str],
) -> frozenset[str]:
    """Reconcile every `file_finished` record against that file's own source.

    Args:
        records: Every decoded `file_finished` record.
        inventory: The source-derived truth for the roots that were run.
        failures: Accumulator appended to, one message per disagreement.

    Returns:
        The set of paths the stream reported a `file_finished` record for.
    """
    by_path: dict[str, Mapping[str, object]] = {}
    for record in records:
        path = _str_field(record, "path")
        if path is None:
            failures.append("[json] a file_finished record carries no string path")
            continue
        if path in by_path:
            failures.append(f"[json] duplicate file_finished record for {path}")
            continue
        by_path[path] = record

    reported = frozenset(by_path)
    if reported != inventory.path_set:
        failures.append(
            "[json] file_finished membership mismatch -- "
            f"the stream reports {len(reported)} file(s), the sources declare "
            f"{len(inventory.path_set)}; never reported: "
            f"{sorted(inventory.path_set - reported)}; reported but not on disk: "
            f"{sorted(reported - inventory.path_set)}"
        )

    for path, declared in sorted(inventory.tests_by_path.items()):
        finished = by_path.get(path)
        if finished is None:
            continue
        problems = _file_record_problems(finished, declared)
        if problems:
            failures.append(f"[json] {path}: " + "; ".join(problems))
    return reported


def _reconcile_test_records(
    records: Sequence[Mapping[str, object]],
    inventory: Inventory,
    mentioned: frozenset[str],
    failures: list[str],
) -> None:
    """Reconcile the exact set of reported test names against each file's source.

    A per-file count can be satisfied by running the wrong tests; a set equality
    on names cannot.

    Args:
        records: Every decoded `test_reported` record.
        inventory: The source-derived truth for the roots that were run.
        mentioned: Paths the stream named in a `file_finished` record. A file
            the stream never mentioned is already reported by the membership
            check, and restating it per file would bury that finding.
        failures: Accumulator appended to, one message per disagreement.
    """
    by_path: dict[str, list[str]] = {}
    for record in records:
        path = _str_field(record, "path")
        name = _str_field(record, "name")
        if path is None or name is None:
            failures.append(
                "[json] a test_reported record carries no string path/name pair"
            )
            continue
        outcome = _str_field(record, "outcome")
        if outcome != "pass":
            failures.append(
                f"[json] {path}::{name} outcome={outcome!r} (must be 'pass')"
            )
        by_path.setdefault(path, []).append(name)

    for path, declared in sorted(inventory.tests_by_path.items()):
        reported = by_path.pop(path, [])
        if path not in mentioned and not reported:
            continue
        duplicates = sorted({name for name in reported if reported.count(name) > 1})
        if duplicates:
            failures.append(
                f"[json] {path}: test(s) reported more than once: {duplicates}"
            )
        expected = frozenset(declared)
        actual = frozenset(reported)
        if actual != expected:
            failures.append(
                f"[json] {path}: reported test names differ from the source -- "
                f"declared but never reported: {sorted(expected - actual)}; "
                f"reported but not declared: {sorted(actual - expected)}"
            )
    for path, names in sorted(by_path.items()):
        failures.append(
            f"[json] {path}: reported {len(names)} test(s) for a file the sources "
            "do not declare at all"
        )


def _reconcile_stream_totals(
    terminal: Mapping[str, object], inventory: Inventory, failures: list[str]
) -> None:
    """Reconcile the terminal `session_finished` record against the sources."""
    exit_code = _int_field(terminal, "exit_code")
    if exit_code != 0:
        failures.append(f"[json] session_finished exit_code={exit_code} (must be 0)")
    counts = terminal.get("test_counts")
    if not isinstance(counts, dict):
        failures.append("[json] session_finished carries no test_counts object")
    else:
        passed = _int_field(counts, "passed")
        if passed != inventory.total_tests:
            failures.append(
                f"[json] session_finished test_counts.passed={passed}, the "
                f"sources declare {inventory.total_tests}"
            )
        for key in ("failed", "skipped", "deselected"):
            value = _int_field(counts, key)
            if value != 0:
                failures.append(f"[json] session_finished test_counts.{key}={value}")
    summary = terminal.get("summary")
    if not isinstance(summary, dict):
        failures.append("[json] session_finished carries no summary object")
        return
    if _int_field(summary, "pass") != len(inventory.path_set):
        failures.append(
            f"[json] session_finished summary.pass={summary.get('pass')!r}, the "
            f"sources declare {len(inventory.path_set)} file(s)"
        )
    nonzero = sorted(
        (key, value)
        for key, value in summary.items()
        if key != "pass" and _int_field(summary, key) != 0
    )
    if nonzero:
        failures.append(
            "[json] session_finished summary carries nonzero non-pass bucket(s): "
            f"{nonzero}"
        )


def reconcile_stream(
    stream_text: str, inventory: Inventory, repo_root: Path, failures: list[str]
) -> None:
    """Reconcile mtest's `--json` event stream against the derived inventory.

    The primary source of truth. Unlike the console report it states each file's
    own result, so every file must report exactly the tests its own source
    declares rather than merely contributing to a correct grand total.

    Args:
        stream_text: The complete newline-delimited event stream.
        inventory: The source-derived truth for the roots that were run.
        repo_root: The directory mtest ran in, checked against `session_started`.
        failures: Accumulator appended to, one message per disagreement.
    """
    try:
        report = json_stream.parse_stream(stream_text)
    except json_stream.StreamError as exc:
        failures.append(f"[json] mtest's event stream is not a valid v1 stream: {exc}")
        return
    if report.torn_tail:
        failures.append(
            "[json] mtest's event stream ends in an unterminated fragment: the "
            "writer died mid-line, so the run was cut short"
        )
    if report.terminal is None:
        failures.append(
            "[json] mtest's event stream carries no session_finished record: the "
            "run never reached its terminal event"
        )

    started = [r for r in report.records if r.get("event") == "session_started"]
    if len(started) != 1:
        failures.append(
            f"[json] found {len(started)} session_started record(s); expected 1"
        )
    else:
        root = _str_field(started[0], "root")
        if root != str(repo_root):
            failures.append(
                f"[json] session_started root={root!r}, harness ran mtest in "
                f"{str(repo_root)!r}; reported paths are not comparable"
            )
        selected = _int_field(started[0], "selected_count")
        if selected != len(inventory.path_set):
            failures.append(
                f"[json] session_started selected_count={selected}, the sources "
                f"declare {len(inventory.path_set)} file(s)"
            )
        excluded = _int_field(started[0], "excluded_count")
        if excluded != 0:
            failures.append(f"[json] session_started excluded_count={excluded}")

    mentioned = _reconcile_file_records(
        [r for r in report.records if r.get("event") == "file_finished"],
        inventory,
        failures,
    )
    _reconcile_test_records(
        [r for r in report.records if r.get("event") == "test_reported"],
        inventory,
        mentioned,
        failures,
    )
    if report.terminal is not None:
        _reconcile_stream_totals(report.terminal, inventory, failures)


def read_stream(path: Path) -> str:
    """Read one event stream, refusing a file too large to be a real report.

    Args:
        path: Where mtest was asked to write its machine event stream.

    Returns:
        The stream text.

    Raises:
        ValueError: If the file is absent, or larger than
            `JSON_STREAM_LIMIT_BYTES`.
        OSError: If the file cannot be read.
    """
    if not path.is_file() or path.is_symlink():
        raise ValueError(
            f"mtest wrote no machine event stream at {path}; the run cannot be "
            "reconciled per file"
        )
    size = path.stat().st_size
    if size > JSON_STREAM_LIMIT_BYTES:
        raise ValueError(
            f"mtest's event stream at {path} is {size} bytes, above the "
            f"{JSON_STREAM_LIMIT_BYTES}-byte ceiling; refusing to parse it"
        )
    return path.read_text(encoding="utf-8", errors="replace")


def reconcile(
    *,
    output: str,
    inventory: Inventory,
    repo_root: Path,
    exit_code: int,
    stream_text: str,
    truncated: bool = False,
) -> list[str]:
    """Reconcile mtest's report against the source-derived inventory.

    Two independent parses of two independent artifacts. Every comparison is
    evaluated even after an earlier one failed, so one run names every
    disagreement instead of the first. The `--json` event stream is primary
    because it states each file's own result; the console report is a
    cross-check in a different grammar read by a different parser. Messages are
    tagged `[json]` or `[console]` so a reader can tell which parse objected.

    Args:
        output: mtest's captured console output.
        inventory: The source-derived truth for the roots that were run.
        repo_root: The directory mtest was run in, checked against its header.
        exit_code: mtest's real exit status.
        stream_text: mtest's `--json` machine event stream.
        truncated: Whether the capture dropped bytes; a truncated report cannot
            be reconciled and is reported as its own failure.

    Returns:
        One message per disagreement, each naming both sides. Empty means both
        reports and the sources agree completely.
    """
    failures: list[str] = []
    if exit_code != 0:
        failures.append(f"mtest exited {exit_code} (must be 0)")
    if truncated:
        failures.append(
            f"[console] mtest's output exceeded the {CAPTURE_LIMIT_BYTES}-byte "
            "capture limit; the report is incomplete and cannot be reconciled"
        )
    reconcile_stream(stream_text, inventory, repo_root, failures)
    _reconcile_header(output, inventory, repo_root, failures)
    _reconcile_paths(output, inventory, failures)
    _reconcile_totals(output, inventory, failures)
    return failures


def _raise_signal(signo: int) -> int:
    """Restore and re-raise one signal from the self-host harness process."""
    if signo not in (signal.SIGKILL, signal.SIGSTOP):
        signal.signal(signo, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signo})
    os.kill(os.getpid(), signo)
    return 128 + signo


def verify(
    roots: Sequence[str] = (),
    *,
    repo_root: Path = REPO_ROOT,
    mtest_path: str = MTEST,
    native_object: str = NATIVE_OBJECT,
    workers: str = DEFAULT_WORKERS,
    environment: Mapping[str, str] | None = None,
    supervisor: Supervisor = watchdog.run_command,
) -> int:
    """Run mtest over the requested roots and reconcile its report.

    Args:
        roots: Requested roots; empty means both default classified roots.
        repo_root: The repository root, and the child's working directory.
        mtest_path: The mtest binary under test.
        native_object: The compiled native test adapter linked into each file.
        workers: The `-n` value handed to mtest.
        environment: Environment consulted for the deadline override.
        supervisor: The watchdog entrypoint that runs mtest.

    Returns:
        0 when the report and the sources agree completely; 1 on any
        disagreement or a missing binary; `watchdog.TIMEOUT_EXIT_CODE` when the
        run exceeded its deadline; `INTERNAL_ERROR_EXIT_CODE` on a harness or
        supervisor failure. A signalled run re-raises that signal instead.

    Raises:
        ValueError: If a root is unsafe, a root holds no test file, or the
            deadline override is malformed.
        OSError: If a test source or directory cannot be read.
        AssertionError: If a test file declares no test function, or two with
            the same name.
    """
    resolved_roots = normalized_roots(repo_root, roots)
    inventory = derive_inventory(repo_root, resolved_roots)
    resolved_environment = dict(os.environ) if environment is None else environment
    seconds = timeout_seconds(resolved_environment)
    print(
        f"selfhost: source-derived inventory: {len(inventory.paths)} file(s), "
        f"{inventory.total_tests} test(s) under "
        f"{[str(root) for root in resolved_roots]}",
        flush=True,
    )
    if not os.path.exists(mtest_path):
        print(
            f"FATAL: selfhost: binary not found at {mtest_path}; "
            "run `pixi run build-bin`",
            file=sys.stderr,
        )
        return 1

    # Per-invocation names, so two concurrent runs on one checkout cannot read
    # each other's stream. See `RunArtifacts`.
    artifacts = run_artifacts(repo_root)
    artifacts.stream.parent.mkdir(parents=True, exist_ok=True)
    try:
        return _verify_run(
            artifacts,
            inventory=inventory,
            repo_root=repo_root,
            mtest_path=mtest_path,
            native_object=native_object,
            resolved_roots=resolved_roots,
            workers=workers,
            seconds=seconds,
            supervisor=supervisor,
        )
    finally:
        # Evidence, then cleanup, for EVERY ending including a timeout's partial
        # stream: a red run is not debuggable without one, and the real name
        # carries a nonce nobody can guess.
        publish_failure = publish_latest_stream(artifacts.stream, repo_root)
        if publish_failure is not None:
            print(f"WARNING: selfhost: {publish_failure}", file=sys.stderr)
        for artifact in (artifacts.stream, artifacts.sentinel):
            # The sentinel has already served its purpose: `run_mtest` reconciled
            # it through `watchdog.validate_deadline_proof` before returning.
            with contextlib.suppress(OSError):
                artifact.unlink(missing_ok=True)


def _verify_run(
    artifacts: RunArtifacts,
    *,
    inventory: Inventory,
    repo_root: Path,
    mtest_path: str,
    native_object: str,
    resolved_roots: Sequence[Path],
    workers: str,
    seconds: float,
    supervisor: Supervisor,
) -> int:
    """Run mtest once against one set of artifacts and reconcile its reports.

    Split out of `verify` so artifact publication and cleanup wrap every exit
    path, including the early returns for a timeout and a harness error.

    Args:
        artifacts: This invocation's stream and deadline sentinel paths.
        inventory: The source-derived truth for the roots being run.
        repo_root: The repository root, and the child's working directory.
        mtest_path: The mtest binary under test.
        native_object: The compiled native test adapter linked into each file.
        resolved_roots: Normalized repository-relative roots to run.
        workers: The `-n` value handed to mtest.
        seconds: The wall-clock ceiling handed to the supervisor.
        supervisor: The watchdog entrypoint that runs mtest.

    Returns:
        The exit code documented on `verify`.
    """
    command = mtest_argv(
        mtest_path, native_object, resolved_roots, workers, str(artifacts.stream)
    )
    print(f"selfhost: running {' '.join(command)}", flush=True)
    run = run_mtest(
        command,
        repo_root=repo_root,
        sentinel=artifacts.sentinel,
        seconds=seconds,
        supervisor=supervisor,
    )
    termination = run.termination
    if isinstance(termination, watchdog.TimedOut):
        print(
            f"FATAL: selfhost: the self-hosted run exceeded {seconds:g}s and its "
            "process group was terminated; mtest's own --timeout cannot cover a "
            "hang in its scheduler, pool or reaper",
            file=sys.stderr,
        )
        return watchdog.TIMEOUT_EXIT_CODE
    if isinstance(termination, watchdog.HarnessError):
        print(
            f"FATAL: selfhost: watchdog/internal failure: {termination.detail}",
            file=sys.stderr,
        )
        return INTERNAL_ERROR_EXIT_CODE
    if not isinstance(termination, watchdog.Exited):
        print(
            f"CRASHED: selfhost: the self-hosted run ended on signal "
            f"{termination.signo}",
            file=sys.stderr,
            flush=True,
        )
        return _raise_signal(termination.signo)

    try:
        stream_text = read_stream(artifacts.stream)
    except (OSError, ValueError) as exc:
        print(f"FATAL: selfhost: {exc}", file=sys.stderr)
        return 1

    failures = reconcile(
        output=run.stdout,
        inventory=inventory,
        repo_root=repo_root,
        exit_code=termination.code,
        stream_text=stream_text,
        truncated=run.truncated,
    )
    if failures:
        print(
            "FATAL: selfhost: mtest's report disagrees with the test sources "
            f"({len(failures)} finding(s)). mtest cannot be trusted to report "
            "its own completeness; the sources are the oracle.",
            file=sys.stderr,
        )
        for failure in failures[:REPORTED_FAILURE_LIMIT]:
            print(f"FATAL: selfhost: {failure}", file=sys.stderr)
        # A per-file oracle over 101 files can produce hundreds of findings from
        # one defect. Show enough to diagnose it and count the rest, rather than
        # burying the first and usually most explanatory one.
        if len(failures) > REPORTED_FAILURE_LIMIT:
            print(
                f"FATAL: selfhost: ... and {len(failures) - REPORTED_FAILURE_LIMIT} "
                "further finding(s) not shown",
                file=sys.stderr,
            )
        return 1

    print(
        f"selfhost: OK -- mtest ({mtest_path}) selected and passed all "
        f"{len(inventory.paths)} classified file(s) and all "
        f"{inventory.total_tests} test(s); every file reported exactly the "
        "test names its own source declares"
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    """Run the requested classified roots through mtest and check the report.

    Args:
        argv: The command line after the program name, or None to read it from
            `sys.argv`.

    Returns:
        `verify`'s exit code, or 2 when the request itself was rejected.
    """
    raw = list(sys.argv[1:] if argv is None else argv)
    try:
        request = parse_request(raw)
        return verify(request.roots, workers=request.workers)
    except (AssertionError, OSError, ValueError) as exc:
        print(f"FATAL: selfhost: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
