"""Shared exact parsers, assertions, and live-actor arming for E2E scenarios.

Besides the console/report oracles, this module owns the vocabulary the interrupt
scenarios share: which slow/ files an interrupt must leave NOT-RUN, and the
marker paths plus environment that arm the live actors to announce readiness,
their real process-group ids, and mtest's polite teardown signal. Four scenario
modules signal a live run, and they must all mean the same thing by "armed".

It also owns the hostile-actor capture arithmetic, for the same reason: the
console scenario and the two machine-reporter scenarios all read artifacts
produced from ONE actor invocation, and they must agree byte for byte on what
that actor wrote and on what the runner's capture bound retained of it.
"""

from __future__ import annotations

import functools
import importlib.util
import os
import re
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from xml.etree import ElementTree

from scripts.checks.reports import json_stream as json_stream_check
from scripts.e2e.runner import REPO_ROOT, Run, ScenarioError


SUMMARY_RE = re.compile(
    r"=====\s+(?P<passed>\d+) passed,\s+(?P<failed>\d+) failed,\s+"
    r"(?P<skipped>\d+) skipped"
    r"(?:,\s+(?P<crashed>\d+) crashed)?"
    r"(?:,\s+(?P<timed_out>\d+) timed out)?"
    r"(?:,\s+(?P<compile_error>\d+) compile error)?"
    r"(?:,\s+(?P<malformed>\d+) malformed suite)?"
    r"[^(]*"
    r"\((?P<excluded>\d+) excluded,\s+(?P<not_run>\d+) not run"
    r"(?:,\s+(?P<deselected>\d+) deselected)?\)"
    r"\s+in\s+(?P<seconds>[\d.]+)s\s+====="
)
HEADER_RE = re.compile(r"root:\s+.*?selected:\s+(\d+) files\s+excluded:\s+(\d+)")

VERDICT_TO_BUCKET = {
    "PASS": "passed",
    "FAIL": "failed",
    "CRASH": "crashed",
    "TIMEOUT": "timed_out",
    "COMPILE-ERROR": "compile_error",
}
VERDICT_LINE_TOKENS = list(VERDICT_TO_BUCKET) + ["NO-TESTS"]
VERDICT_LINE_RE = re.compile(
    r"^(?:" + "|".join(re.escape(token) for token in VERDICT_LINE_TOKENS) + r")\s+(\S+)",
    re.MULTILINE,
)


@dataclass
class Summary:
    """Parsed totals from one console summary band."""

    passed: int
    failed: int
    skipped: int
    crashed: int
    timed_out: int
    compile_error: int
    malformed: int
    excluded: int
    not_run: int
    seconds: float
    deselected: int = 0


def verdict_paths_in_order(run: Run) -> list[str]:
    """Return verdict paths in stdout order."""
    return VERDICT_LINE_RE.findall(run.stdout)


def summary(run: Run) -> Summary:
    """Parse the exact summary band from a captured run."""
    match = SUMMARY_RE.search(run.combined)
    if not match:
        raise ScenarioError(f"no summary band in output for {run.argv}\n{run.combined}")
    groups = match.groupdict()

    def number(key: str) -> int:
        return int(groups[key]) if groups.get(key) is not None else 0

    return Summary(
        passed=number("passed"),
        failed=number("failed"),
        skipped=number("skipped"),
        crashed=number("crashed"),
        timed_out=number("timed_out"),
        compile_error=number("compile_error"),
        malformed=number("malformed"),
        excluded=number("excluded"),
        not_run=number("not_run"),
        deselected=number("deselected"),
        seconds=float(groups["seconds"]),
    )


def header(run: Run) -> tuple[int, int]:
    """Parse selected and excluded file counts from the header band."""
    match = HEADER_RE.search(run.combined)
    if not match:
        raise ScenarioError(f"no header band in output for {run.argv}\n{run.combined}")
    return int(match.group(1)), int(match.group(2))


def verdict_line(run: Run, token: str, path: str) -> str | None:
    """Return the first verdict line beginning with ``token`` and naming path."""
    for line in run.stdout.splitlines():
        if line.startswith(token) and path in line:
            return line
    return None


def expect(condition: bool, message: str) -> None:
    """Raise the expected scenario failure when an exact property is false."""
    if not condition:
        raise ScenarioError(message)


def expect_exit(run: Run, code: int) -> None:
    """Assert one exact process exit code with both streams on failure."""
    expect(
        run.returncode == code,
        f"expected exit {code}, got {run.returncode} for {run.argv}\n"
        f"--- stdout ---\n{run.stdout}\n--- stderr ---\n{run.stderr}",
    )


def expect_report(run: Run, path: str | Path, what: str) -> Path:
    """Assert a report exists before its format-specific oracle reads it."""
    report = Path(path)
    expect(
        report.exists(),
        f"{what} was never written to {report}: {run.argv} exited "
        f"{run.returncode} and produced no report\n"
        f"--- stdout ---\n{run.stdout}\n--- stderr ---\n{run.stderr}",
    )
    return report


INTERRUPT_TIMEOUT = 300.0
"""Whole-call budget for one interrupt scenario: two cold `mojo build`s, the
signal round trip, and finalization. A hang guard, never a threshold — the
readiness barrier, not the clock, decides when the signal is sent."""

HARD_KILL_GUARD_SECONDS = 2.0
"""How long a second interrupt may take to end the run, from signal to exit.

The blocked actor is a compile slot, whose SIGTERM-to-SIGKILL grace is 5 s. A
second interrupt that did NOT hard-kill would therefore surface as the whole
grace, three seconds the far side of this bound — the same 2 s/5 s separation
`tests/integration/test_exec_pool.mojo` uses, and far outside loaded-CI jitter.
Without this bound the double-interrupt scenario is green against a product that
ignores the second signal entirely."""

SLOW_TREE = "e2e/slow"
"""The tree every sequential interrupt scenario walks."""
SLOW_PASSING_FILE = "e2e/slow/test_first_pass.mojo"
"""The one file a sequential slow/ walk COMPLETES before the next child blocks."""
SLOW_BLOCKED_FILE = "e2e/slow/test_grace_stubborn.mojo"
"""The file that is in flight, blocked and armed, when the interrupt arrives."""
SLOW_NOT_RUN_FILES = (
    "e2e/slow/test_grace_stubborn.mojo",
    "e2e/slow/test_hanging.mojo",
    "e2e/slow/test_slow_pass_a.mojo",
    "e2e/slow/test_slow_pass_b.mojo",
)
"""Exactly the slow/ files an interrupt leaves without a verdict: the blocked
child that never finished plus every file behind it that was never scheduled."""


@dataclass(frozen=True)
class SlowArming:
    """The marker paths and environment that arm the e2e/slow interrupt actors.

    Every path lives in one harness-owned scratch directory, so no run can see a
    marker another run left behind and "ready" always means this run's actor.
    """

    passed_file: str
    ready_file: str
    pgid_file: str

    @property
    def env(self) -> dict[str, str]:
        """The environment overrides that arm both slow/ actors."""
        return {
            "MTEST_SLOW_PASSED_FILE": self.passed_file,
            "MTEST_SLOW_READY_FILE": self.ready_file,
            "MTEST_SLOW_PGID_FILE": self.pgid_file,
        }

    @property
    def ready_files(self) -> tuple[str, ...]:
        """The barrier: one file has PASSED and the next child is blocked."""
        return (self.passed_file, self.ready_file)

    @property
    def owned_pgid_files(self) -> tuple[str, ...]:
        """Where the blocked actor records its real process-group id."""
        return (self.pgid_file,)


def arm_slow_tree(directory: str | Path) -> SlowArming:
    """Name this run's slow/ marker paths inside a harness-owned directory.

    Args:
        directory: An empty scratch directory this run owns.

    Returns:
        The marker paths and the environment that arms the actors to write them.
    """
    root = os.fspath(directory)
    return SlowArming(
        passed_file=os.path.join(root, "passed"),
        ready_file=os.path.join(root, "blocked-ready"),
        pgid_file=os.path.join(root, "blocked-pgid"),
    )


@dataclass(frozen=True)
class StubbornArming:
    """The marker paths and environment that arm the teardown-witness compile.

    The blocked actor here is the stubborn `--mojo` stand-in holding one named
    file's compile open, which is the only actor that can observe mtest's polite
    SIGTERM and live to report it.
    """

    target: str
    ready_file: str
    pgid_file: str
    teardown_file: str

    @property
    def env(self) -> dict[str, str]:
        """The environment overrides that arm the stubborn compile."""
        return {
            "MTEST_STUBBORN_TARGET": self.target,
            "MTEST_STUBBORN_READY_FILE": self.ready_file,
            "MTEST_STUBBORN_PGID_FILE": self.pgid_file,
            "MTEST_STUBBORN_TEARDOWN_FILE": self.teardown_file,
        }

    @property
    def ready_files(self) -> tuple[str, ...]:
        """The barrier: the target's compile is armed and holding."""
        return (self.ready_file,)

    @property
    def owned_pgid_files(self) -> tuple[str, ...]:
        """Where the blocked compile records its real process-group id."""
        return (self.pgid_file,)

    @property
    def teardown_ready_files(self) -> tuple[str, ...]:
        """The barrier: the blocked compile observed mtest's polite SIGTERM."""
        return (self.teardown_file,)


def arm_stubborn_compile(directory: str | Path, target: str) -> StubbornArming:
    """Name this run's stubborn-compile marker paths in a harness-owned dir.

    Args:
        directory: An empty scratch directory this run owns.
        target: The repo-relative source path whose compile must block.

    Returns:
        The marker paths and the environment that arms the stand-in.
    """
    root = os.fspath(directory)
    return StubbornArming(
        target=target,
        ready_file=os.path.join(root, "stubborn-ready"),
        pgid_file=os.path.join(root, "stubborn-pgid"),
        teardown_file=os.path.join(root, "stubborn-teardown"),
    )


@dataclass(frozen=True)
class StreamFiles:
    """One `--json` stream reduced to its per-file identities and totals."""

    started: tuple[str, ...]
    finished: dict[str, str]
    summary: dict[str, int]
    exit_code: int | None
    has_terminal: bool

    @property
    def unfinished(self) -> tuple[str, ...]:
        """Files the stream announced as started but never finished."""
        return tuple(p for p in self.started if p not in self.finished)


def stream_files(text: str) -> StreamFiles:
    """Project a `--json` stream onto the file identities it names.

    The machine stream deliberately carries no synthetic not-run record, so a
    NOT-RUN identity is stated by absence: a file that started and never
    finished was killed in flight, and a file with no record at all was never
    scheduled. Both are exact.

    Args:
        text: The captured NDJSON stream.

    Returns:
        The started paths in order, the finished paths mapped to their outcome,
        the terminal summary counts, the terminal exit code, and whether the
        terminal record was committed at all.

    Raises:
        ScenarioError: If the stream is corrupt beyond one torn tail.
    """
    report = json_stream_check.parse_stream(text)
    started: list[str] = []
    finished: dict[str, str] = {}
    summary: dict[str, int] = {}
    for record in report.records:
        event = record.get("event")
        if event == "file_started":
            started.append(record.get("path", ""))
        elif event == "file_finished":
            finished[record.get("path", "")] = record.get("outcome", "")
        elif event == "session_finished":
            summary = dict(record.get("summary", {}))
    return StreamFiles(
        started=tuple(started),
        finished=finished,
        summary=summary,
        exit_code=report.exit_code,
        has_terminal=report.terminal is not None,
    )


def junit_not_run_files(path: str | Path) -> tuple[str, ...]:
    """The suites carrying the synthetic `[not-run]` row, in document order.

    Args:
        path: The published JUnit report.

    Returns:
        Each suite name whose only row is the not-run marker.
    """
    root = ElementTree.parse(os.fspath(path)).getroot()
    suites = root.iter("testsuite") if root.tag != "testsuite" else [root]
    names: list[str] = []
    for suite in suites:
        for case in suite.findall("testcase"):
            if case.get("name") == "[not-run]":
                names.append(suite.get("name") or "")
                break
    return tuple(names)


HOSTILE_ACTOR_PATH = os.path.join(
    REPO_ROOT, "tests", "fixtures", "exec", "hostile_report_actor.py"
)
"""The committed hostile actor, the single source of the bytes under test.

The scenarios import it rather than restating its payload: an assertion written
against a copy of the bytes would keep passing after the actor stopped emitting
them."""

CAPTURE_BOUND_BYTES = 8 * 1024 * 1024
"""The runner's default per-stream head+tail capture bound.

Restated from `_DEFAULT_CAP_BYTES` in `src/mtest/exec/supervise.mojo`, which no
Python can import. A drift between the two surfaces here as an exact-count
mismatch in the hostile-reporters scenario, never as a silent pass."""

CAPTURE_HEAD_BYTES = CAPTURE_BOUND_BYTES // 2
"""The leading window the capture always keeps (`Supervisor.__init__`)."""

CAPTURE_TAIL_BYTES = CAPTURE_BOUND_BYTES - CAPTURE_HEAD_BYTES
"""The trailing window the capture always keeps, which is the region mtest
reparses for a report once the bound is exceeded."""

REPORT_WINDOW_BYTES = 65536
"""The per-end window each machine reporter keeps of a captured stream.

Restated from `_STREAM_HEAD`/`_STREAM_TAIL` in `report/json_stream.mojo` and
`_JUNIT_HEAD`/`_JUNIT_TAIL` in `report/junit.mojo`, which agree by contract; the
hostile-reporters scenario is where that agreement is actually exercised."""

ELISION = "…"
"""The visible marker both reporters splice between their two windows."""


@functools.cache
def hostile_actor() -> ModuleType:
    """Import the committed hostile actor as a module, once per process.

    Returns:
        The actor module, with `CANONICAL` still the committed placeholder. Every
        payload function takes the real path as an argument, so nothing here
        depends on that global.

    Raises:
        ScenarioError: If the actor cannot be located or imported.
    """
    spec = importlib.util.spec_from_file_location(
        "e2e_hostile_report_actor", HOSTILE_ACTOR_PATH
    )
    if spec is None or spec.loader is None:
        raise ScenarioError(f"cannot import the hostile actor at {HOSTILE_ACTOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def capture_marker(omitted: int) -> bytes:
    """The exact truncation marker the capture splices at the bound.

    Mirrors `_marker_text` in `src/mtest/exec/capture.mojo`, including its
    surrounding newlines. Written here as an independent expectation so the
    retained byte count can be predicted rather than read back from the artifact
    it is supposed to be judging.

    Args:
        omitted: How many middle bytes the bound dropped.

    Returns:
        The marker's UTF-8 bytes, LF-framed on both sides.
    """
    return (
        f"\n[mtest: output truncated — {omitted} bytes omitted, "
        f"limit {CAPTURE_BOUND_BYTES} bytes]\n"
    ).encode("utf-8")


@dataclass(frozen=True)
class HostileStream:
    """One stream the hostile actor wrote, and what survives each bound.

    `raw` is every byte the child put on the descriptor. The rest is derived:
    what the runner's capture retains, and what a machine reporter keeps of that
    retained value. Each property states one policy, so a failure names the
    policy that broke rather than "the numbers differ".
    """

    raw: bytes

    @property
    def truncated(self) -> bool:
        """Whether the stream overran the capture bound (`was_truncated`)."""
        return len(self.raw) > CAPTURE_BOUND_BYTES

    @property
    def omitted(self) -> int:
        """How many middle bytes the capture bound dropped."""
        return max(len(self.raw) - CAPTURE_BOUND_BYTES, 0)

    @property
    def retained(self) -> bytes:
        """The bytes the capture hands the reporters: head, marker, tail."""
        if not self.truncated:
            return self.raw
        return (
            self.raw[:CAPTURE_HEAD_BYTES]
            + capture_marker(self.omitted)
            + self.raw[len(self.raw) - CAPTURE_TAIL_BYTES :]
        )

    @property
    def reporter_text(self) -> str:
        """The bounded text both machine reporters render from `retained`.

        The reporters' own head+tail window over the retained bytes, each window
        decoded independently exactly as `_excerpt_bytes` and
        `bounded_text_from_bytes` decode theirs.
        """
        data = self.retained
        if len(data) <= 2 * REPORT_WINDOW_BYTES:
            return data.decode("utf-8", "replace")
        head = data[:REPORT_WINDOW_BYTES].decode("utf-8", "replace")
        tail = data[len(data) - REPORT_WINDOW_BYTES :].decode("utf-8", "replace")
        return head + ELISION + tail

    @property
    def reporter_omitted(self) -> int:
        """How many retained bytes the reporters' own window dropped."""
        return max(len(self.retained) - 2 * REPORT_WINDOW_BYTES, 0)


@dataclass(frozen=True)
class HostileStreams:
    """Both streams of one hostile-actor run, plus the report it ends on."""

    stdout: HostileStream
    stderr: HostileStream
    detail: str
    """The child's per-test failure detail, exactly as it wrote it — the text
    every reporter's per-test surface has to render from."""


def hostile_streams(canonical: str, flood_lines: int) -> HostileStreams:
    """Predict both streams of one armed hostile-actor run, byte for byte.

    Reproduces `main`'s write order — flood, hostile block, report on stdout; the
    hostile block alone on stderr — from the actor's own payload constants.

    Args:
        canonical: The absolute, symlink-resolved source path the build stand-in
            embeds, which the report header must byte-equal.
        flood_lines: The flood line count the run arms through the actor's
            environment variable.

    Returns:
        The two predicted streams and the failure detail they carry.
    """
    actor = hostile_actor()
    stdout_raw = (
        actor.flood_block(flood_lines)
        + actor.hostile_block(b"child stdout", canonical)
        + actor.report_block(False, canonical)
    )
    stderr_raw = actor.hostile_block(b"child stderr", canonical)
    detail = actor.failure_detail(canonical).decode("utf-8", "replace")
    return HostileStreams(
        stdout=HostileStream(stdout_raw),
        stderr=HostileStream(stderr_raw),
        detail=detail,
    )


def expect_accounting(run: Run) -> Summary:
    """Reconcile the summary and header excluded-file counts."""
    parsed_summary = summary(run)
    _selected, header_excluded = header(run)
    expect(
        parsed_summary.excluded == header_excluded,
        f"excluded mismatch: summary {parsed_summary.excluded} vs header "
        f"{header_excluded} for {run.argv}",
    )
    return parsed_summary
