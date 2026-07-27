#!/usr/bin/env python3
"""Run mtest over its own classified suite and refuse to believe its report.

This lane is circular on purpose: `build/mtest` discovers, builds, runs and
reports mtest's own 101 classified test files. Circularity is exactly what makes
mtest's own verdict worthless as evidence here — a runner that lost half its
inventory, or collected zero tests from every file it found, still prints a
well-formed report and still exits 0. Two concrete holes make that concrete:

- **The zero-collection PASS.** A module with `main()` and no collected tests
  builds, runs, prints "0 tests run" and exits 0, and
  `src/mtest/session/classify.mojo` classifies that PASS *by design* ("this
  includes the zero-test PASS"), with `e2e/suite/test_zero.mojo` pinning it as
  the documented ceiling. The e2e lane is therefore the specification of that
  hole, not a check on it: e2e stays green on a run where every classified
  module collected nothing.
- **Scale-dependent truncation.** The exec supervision ceiling is 64 in both
  layers (`native/mtest_exec_native.c` `MTEST_EXEC_SLOT_CAPACITY`,
  `src/mtest/exec/supervise.mojo` `_COMPILE_CAP`). A defect conflating that
  concurrency cap with a total-file cap would report 64 green files of 101 and
  exit 0. The whole e2e tree is 41 files and its largest fixture has 12 tests,
  so neither the file cap nor a four-digit count-accumulation defect can show
  up there.

So this harness derives the truth independently, from the test sources on disk,
and reconciles four things against mtest's console report: the exit code, the
selected/excluded file counts, the exact set of file paths that reported PASS,
and the exact per-test total. Any disagreement is a loud failure naming both
sides. mtest is never asked what it ran; it is only checked against what the
sources say it must have run.

The inventory is derived, never declared. There is no committed path list, no
committed test count, and nothing a human edits when adding a test file or a
test function -- see `derive_inventory` and `independent_test_function_names`.
The parser is a deliberate port rather than an import: it must not share a
regex or a helper with `scripts/harness/aggregate.py`, because independence
from the generator is the property being relied on.

The whole run is supervised by `scripts/harness/watchdog.py` under a
whole-process-group deadline. mtest's own `--timeout`/`--compile-timeout` cover
a hung *child*; they cannot cover a hang in mtest's own scheduler, pool or
reaper, which is precisely the code this lane exercises.

Usage:  python -m scripts.harness.selfhost [ROOT ...]
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
import contextlib
from dataclasses import dataclass
import math
import os
from pathlib import Path
import re
import signal
import sys
import threading
from typing import TYPE_CHECKING


if TYPE_CHECKING:
    from collections.abc import Mapping
    from typing import IO

from scripts.harness import watchdog


REPO_ROOT = Path(__file__).resolve().parents[2]
MTEST = str(REPO_ROOT / "build" / "mtest")
NATIVE_OBJECT = str(REPO_ROOT / "build" / "native" / "mtest_exec_native_test.o")
DEFAULT_ROOTS = (Path("tests/unit"), Path("tests/integration"))
TEST_FILE_GLOB = "test_*.mojo"

DEFAULT_WORKERS = "auto"
"""Provisional worker policy. A later task measures and pins this value."""

TIMEOUT_ENV = "MTEST_SELFHOST_TIMEOUT_SECONDS"
DEFAULT_TIMEOUT_SECONDS = watchdog.DEFAULT_TIMEOUT_SECONDS
"""Whole-process-group ceiling for the self-hosted run, in seconds.

The measured full run is roughly 135s on 32 cores and 629s on 4, so the ceiling
has to clear the slow machine with room for a cold Mojo compiler cache. 900s is
both comfortably above that and the largest value the watchdog accepts
(`watchdog._validate_timeout_seconds` rejects anything above its own default),
so this is the widest honest ceiling available. `MTEST_SELFHOST_TIMEOUT_SECONDS`
lowers it; nothing can raise it.
"""

DEADLINE_SENTINEL = Path("build/tests/selfhost.run-deadline")
"""Pre-created file the supervisor removes on every non-timeout ending.

Reconciled after the run by `watchdog.validate_deadline_proof`, so a timeout is
confirmed against filesystem state rather than trusted from the supervisor's
own clock.
"""

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
parenthetical -- crashed, timed out, compile error, malformed suite, compile
timeout, precompile error, flaky. It is a capture rather than a skip so that a
nonzero abnormal count is *named* instead of silently swallowed.
"""

VERDICT_ROW_RE = re.compile(
    r"^(?P<verdict>[A-Z][A-Z-]{2,})\s+(?P<path>\S+\.mojo)(?=\s|$)",
    re.MULTILINE,
)
"""One per-file verdict row: the verdict token and the file it names.

Deliberately not scoped to a fixed root prefix the way `dogfood.py`'s row
regex is. This harness is given its roots at runtime, and every row it sees is
compared against the disk-derived path set for exactly those roots, so a row
naming a file outside them is a membership failure rather than something to
filter out before comparing.
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
    the harness gets the text it must parse. Passing the bytes through to the
    caller's real stream as well keeps a multi-minute lane visibly alive rather
    than silent until it ends.
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
                # The caller's stream is gone. Retention must continue anyway:
                # dropping the capture here would turn a reportable ending into
                # an unexplainable one.
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

    A deliberate port of `scripts/checks/layout.py`'s oracle parser rather than
    an import of it: a later task deletes most of that module's classified
    ledgers, and this oracle must not be coupled to a module being gutted. It
    uses no regular expression and touches nothing that
    `scripts/harness/aggregate.py` uses, because independence from the
    generator is the entire property being relied on. Do not "simplify" it into
    sharing a parser with anything else.

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
    workers: str = DEFAULT_WORKERS,
) -> list[str]:
    """Build the self-hosted run command for one set of roots.

    `-I build -I tests/support` is mandatory: the integration suites import
    `exec_helpers` and `session_fixtures` as top-level include-path modules. The
    native adapter object reaches the child compiler as a linker argument
    (`-Xlinker <obj>`) because a bare object path is not a positional --
    `mojo build src.mojo obj.o` fails with "too many input files".

    Args:
        mtest_path: The mtest binary to run.
        native_object: The compiled native test adapter to link into each file.
        roots: Repository-relative roots to hand mtest.
        workers: The `-n` value. Provisional; a later task pins it.

    Returns:
        The complete argv, without shell interpretation.
    """
    return [
        mtest_path,
        "-I",
        "build",
        "-I",
        "tests/support",
        "--build-arg=--no-optimization",
        "--build-arg=-Xlinker",
        f"--build-arg={native_object}",
        "-n",
        workers,
        *[str(root) for root in roots],
    ]


def timeout_seconds(environment: Mapping[str, str]) -> float:
    """Read the whole-process-group ceiling for the self-hosted run.

    Args:
        environment: The harness process environment to read.

    Returns:
        The ceiling in seconds: `DEFAULT_TIMEOUT_SECONDS` unless
        `MTEST_SELFHOST_TIMEOUT_SECONDS` lowers it.

    Raises:
        ValueError: If the override is not a finite number in
            `(0, DEFAULT_TIMEOUT_SECONDS]`, so a typo cannot quietly disarm or
            uselessly shorten the deadline.
    """
    raw = environment.get(TIMEOUT_ENV)
    if raw is None:
        return DEFAULT_TIMEOUT_SECONDS
    try:
        seconds = float(raw)
    except ValueError as exc:
        raise ValueError(f"{TIMEOUT_ENV} must be a number: {raw!r}") from exc
    if not math.isfinite(seconds) or not (0 < seconds <= DEFAULT_TIMEOUT_SECONDS):
        raise ValueError(
            f"{TIMEOUT_ENV} must be finite and between 0 and "
            f"{DEFAULT_TIMEOUT_SECONDS:g} seconds: {raw!r}"
        )
    return seconds


def run_mtest(
    command: Sequence[str],
    *,
    repo_root: Path,
    seconds: float,
    supervisor: Supervisor = watchdog.run_command,
) -> SupervisedRun:
    """Run one mtest command under a whole-process-group deadline.

    Follows `scripts/harness/classified.py`'s `_run_step` pattern: a sentinel
    file is created before the spawn and removed by the supervisor on every
    non-timeout ending, then reconciled here. That makes "this timed out" a
    claim confirmed against filesystem state rather than one taken on the
    supervisor's word.

    Args:
        command: The complete mtest argv.
        repo_root: Working directory for the child and anchor for the sentinel.
        seconds: The wall-clock ceiling handed to the supervisor.
        supervisor: The watchdog entrypoint, injectable for tests.

    Returns:
        The structured termination plus the run's captured stdout and stderr.
        Every failure, including one raised by the supervisor itself, is
        returned as a `HarnessError` termination rather than propagated.
    """
    sentinel = repo_root / DEADLINE_SENTINEL
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
    # The watchdog only opens pipes when a marker retention is requested, and it
    # tees them to whatever `sys.stdout`/`sys.stderr` are at spawn time. This
    # run has no module markers to retain, so the retention is given a prefix no
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
            "no single session header -- found "
            f"{len(headers)} 'root: ... selected: N files excluded: M' line(s); "
            "cannot reconcile file membership"
        )
        return
    reported_root, raw_selected, raw_excluded = headers[0]
    if reported_root != str(repo_root):
        failures.append(
            "session root mismatch -- mtest reported root "
            f"{reported_root!r}, harness ran it in {str(repo_root)!r}; "
            "reported paths are not comparable to the derived inventory"
        )
    selected = int(raw_selected)
    excluded = int(raw_excluded)
    if selected != len(inventory.paths):
        failures.append(
            "selected file count mismatch -- mtest selected "
            f"{selected} file(s), the sources declare {len(inventory.paths)}"
        )
    if excluded != 0:
        failures.append(
            f"mtest excluded {excluded} file(s); the self-hosted lane must exclude none"
        )


def _reconcile_paths(output: str, inventory: Inventory, failures: list[str]) -> None:
    """Check the exact set of PASS-reporting paths against the derived set."""
    rows = VERDICT_ROW_RE.findall(output)
    passed = {path for verdict, path in rows if verdict == "PASS"}
    other = sorted({(verdict, path) for verdict, path in rows if verdict != "PASS"})
    if other:
        failures.append(
            "mtest reported non-PASS verdict row(s): "
            + ", ".join(f"{verdict} {path}" for verdict, path in other)
        )
    expected = inventory.path_set
    if passed != expected:
        missing = sorted(expected - passed)
        extra = sorted(passed - expected)
        failures.append(
            "exact path membership mismatch -- "
            f"mtest reported PASS for {len(passed)} file(s), the sources declare "
            f"{len(expected)}; "
            f"never reported: {missing}; reported but not on disk: {extra}"
        )


def _reconcile_totals(output: str, inventory: Inventory, failures: list[str]) -> None:
    """Check the per-test summary totals against the derived per-file counts."""
    matches = list(SUMMARY_RE.finditer(output))
    if len(matches) != 1:
        failures.append(
            f"no single summary band -- found {len(matches)} "
            "'===== N passed, ... =====' line(s); cannot reconcile test totals"
        )
        return
    summary = matches[0]
    expected_total = inventory.total_tests
    reported_passed = int(summary.group("passed"))
    if reported_passed != expected_total:
        failures.append(
            "exact test-total mismatch -- mtest reported "
            f"{reported_passed} passed, the sources declare {expected_total} "
            f"test function(s) across {len(inventory.paths)} file(s); a module "
            "that collected nothing looks exactly like this"
        )
    for group in ("failed", "skipped", "excluded", "not_run"):
        raw = summary.group(group)
        if raw is not None and int(raw) != 0:
            label = group.replace("_", " ")
            failures.append(f"mtest reported {raw} {label}; must be 0")
    deselected = summary.group("deselected")
    if deselected is not None and int(deselected) != 0:
        failures.append(f"mtest reported {deselected} deselected; must be 0")
    abnormal = summary.group("abnormal").strip()
    if abnormal:
        failures.append(
            f"mtest's summary carries abnormal file counts: {abnormal!r}; "
            "the self-hosted lane must report none"
        )


def reconcile(
    *,
    output: str,
    inventory: Inventory,
    repo_root: Path,
    exit_code: int,
    truncated: bool = False,
) -> list[str]:
    """Reconcile mtest's report against the source-derived inventory.

    Four independent comparisons, all evaluated even when an earlier one has
    already failed, so one run names every disagreement instead of the first:
    the exit code, the selected/excluded file counts, the exact PASS path set,
    and the exact per-test totals.

    Args:
        output: mtest's captured console output.
        inventory: The source-derived truth for the roots that were run.
        repo_root: The directory mtest was run in, checked against its header.
        exit_code: mtest's real exit status.
        truncated: Whether the capture dropped bytes; a truncated report cannot
            be reconciled and is reported as its own failure.

    Returns:
        One message per disagreement, each naming both sides. Empty means the
        report and the sources agree completely.
    """
    failures: list[str] = []
    if exit_code != 0:
        failures.append(f"mtest exited {exit_code} (must be 0)")
    if truncated:
        failures.append(
            f"mtest's output exceeded the {CAPTURE_LIMIT_BYTES}-byte capture "
            "limit; the report below is incomplete and cannot be reconciled"
        )
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

    command = mtest_argv(mtest_path, native_object, resolved_roots, workers)
    print(f"selfhost: running {' '.join(command)}", flush=True)
    run = run_mtest(
        command, repo_root=repo_root, seconds=seconds, supervisor=supervisor
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

    failures = reconcile(
        output=run.stdout,
        inventory=inventory,
        repo_root=repo_root,
        exit_code=termination.code,
        truncated=run.truncated,
    )
    if failures:
        print(
            "FATAL: selfhost: mtest's report disagrees with the test sources "
            f"({len(failures)} finding(s)). mtest cannot be trusted to report "
            "its own completeness; the sources are the oracle.",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"FATAL: selfhost: {failure}", file=sys.stderr)
        return 1

    print(
        f"selfhost: OK -- mtest ({mtest_path}) selected and passed all "
        f"{len(inventory.paths)} classified file(s) and all "
        f"{inventory.total_tests} test(s); exact paths and exact totals match "
        "the sources"
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    """Run the requested classified roots through mtest and check the report.

    Args:
        argv: Requested roots, or None to read them from `sys.argv`.

    Returns:
        `verify`'s exit code, or 2 when the request itself was rejected.
    """
    paths = list(sys.argv[1:] if argv is None else argv)
    try:
        return verify(paths)
    except (AssertionError, OSError, ValueError) as exc:
        print(f"FATAL: selfhost: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
