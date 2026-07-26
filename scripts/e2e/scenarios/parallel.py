"""Parallel worker-pool E2E scenarios.

The pool landed at the session layer; these scenarios drive it through the real
CLI now that `-n`/`--workers` is served. They prove the two invariants the pool
must hold no matter how many workers run: the observable projection of a run
(verdicts, per-file outcomes, the `--json` event stream, exit code) is identical
across worker counts, and files genuinely run concurrently (overlapping build and
run windows) while each file's own steps stay ordered. The interrupt scenario
proves the parallel teardown leaves no survivor.
"""

from __future__ import annotations

import contextlib
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import tempfile
from typing import Any, cast

from scripts.checks.reports import json_stream as json_stream_check
from scripts.checks.reports import junit as junit_check
from scripts.checks.reports import junit_canonicalize
from scripts.e2e.assertions import (
    INTERRUPT_TIMEOUT,
    SUMMARY_RE,
    expect,
    expect_accounting,
    expect_exit,
    expect_report,
    junit_not_run_files,
    stream_files,
    verdict_paths_in_order,
)
from scripts.e2e.runner import (
    FAKE_FD_MOJO,
    FAKE_WINDOW_MOJO,
    LOGGING_MOJO,
    REPO_ROOT,
    ScenarioContext,
    ScenarioError,
    expect_group_gone,
)


# A small all-pass tree used where a fixed multi-file suite is all that matters;
# e2e/suite carries the failing/crashing variety the projection proof needs.
PARALLEL_TREE = "e2e/parallel"
VARIED_SUITE = "e2e/suite"

_TIMING_BRACKET = re.compile(r"\[\s*[\d.]+\s*\]")
_TIMING_SECONDS = re.compile(r"\b\d+\.\d+s")
_TIMING_TAGS = re.compile(r"\bin\s+[\d.]+s\b")

# Fields whose exact value is a wall-clock or ordering artifact, never a semantic
# outcome; dropped before two runs' streams are compared for projection equality.
_VOLATILE_FIELDS = frozenset(
    {
        "timing",
        "duration_us",
        "build_duration_us",
        "wall_time_us",
        "attribution_us",
        "captured_stdout",
        "captured_stderr",
        "stdout_capture_bytes",
        "stderr_capture_bytes",
    }
)


def _mask_timing(text: str) -> str:
    """Replace every wall-clock artifact in console text with a stable token.

    Two separate processes never share timings, so a byte-for-byte console
    comparison must first blank the bracketed per-test timings, the trailing
    `in N.Ns` band tag, and any bare `N.Ns` duration column.
    """
    masked = _TIMING_BRACKET.sub("[T]", text)
    masked = _TIMING_TAGS.sub("in Ts", masked)
    return _TIMING_SECONDS.sub("Ts", masked)


def _canonical_record(record: dict[str, Any]) -> tuple[tuple[str, str], ...]:
    """A record reduced to its semantic fields, sorted and volatility-stripped."""
    items = sorted(
        (key, str(value))
        for key, value in record.items()
        if key not in _VOLATILE_FIELDS
    )
    return tuple(items)


def _project_stream(text: str) -> dict[str, Any]:
    """Project a `--json` stream to a worker-count-independent shape.

    Records are grouped by file so concurrent interleaving cannot perturb the
    comparison, volatile timing fields are stripped, and the session header
    (minus its worker count) plus the terminal summary are kept whole. Two runs
    that differ only in `-n` must project equally.
    """
    report = json_stream_check.parse_stream(text)
    per_file: dict[str, list[tuple[tuple[str, str], ...]]] = {}
    header: tuple[tuple[str, str], ...] = ()
    terminal: tuple[tuple[str, str], ...] = ()
    for record in report.records:
        event = record.get("event")
        if event == "session_started":
            header = _canonical_record(
                {k: v for k, v in record.items() if k != "workers"}
            )
        elif event == "session_finished":
            terminal = _canonical_record(
                {k: v for k, v in record.items() if k != "wall_time_us"}
            )
        else:
            # `parse_stream` already rejected anything off-schema, so `path` is
            # the string the v1 schema gives it.
            path = cast("str", record.get("path", ""))
            per_file.setdefault(path, []).append(_canonical_record(record))
    return {
        "header": header,
        "terminal": terminal,
        "exit_code": report.exit_code,
        "per_file": {path: per_file[path] for path in sorted(per_file)},
        "has_progress": any(r.get("event") == "progress" for r in report.records),
    }


def _workers_in_stream(text: str) -> int:
    """The `workers` value carried by the stream's `session_started` record."""
    report = json_stream_check.parse_stream(text)
    for record in report.records:
        if record.get("event") == "session_started":
            workers = record.get("workers")
            if isinstance(workers, int):
                return workers
    raise ScenarioError("no session_started.workers in the --json stream")


def _log_path(prefix: str) -> str:
    """A fresh, absent path for a window/build log — the shim creates it."""
    handle, path = tempfile.mkstemp(prefix=prefix, suffix=".tsv")
    os.close(handle)
    os.remove(path)
    return path


def _log_lines(path: str) -> list[str]:
    """The shim/fixture's recorded lines, or [] if it never wrote the file."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        return [line.rstrip("\n") for line in handle if line.strip()]


def _intervals(lines: list[str], kind: str) -> dict[str, tuple[float, float]]:
    r"""Fold `<kind>\t<name>\t<edge>[...]` records into per-name (start, end) spans.

    Each name is stamped twice, start then end, in that order — the build shim
    appends a return code to its end record, the run fixture does not, so the two
    edges are paired by their arrival order rather than their field count.
    """
    edges: dict[str, list[float]] = {}
    for line in lines:
        fields = line.split("\t")
        if len(fields) < 3 or fields[0] != kind:
            continue
        edges.setdefault(fields[1], []).append(float(fields[2]))
    return {
        name: (stamps[0], stamps[-1])
        for name, stamps in edges.items()
        if len(stamps) >= 2
    }


def _built_files(lines: list[str]) -> set[str]:
    """The set of files the logging/window shim recorded a build START for."""
    built: set[str] = set()
    for line in lines:
        fields = line.split("\t")
        if len(fields) >= 2 and fields[0] == "build":
            built.add(fields[1])
    return built


def s_parallel_projection_eq(context: ScenarioContext) -> str:
    """`-n 4` and `-n 1` over a varied suite project to the SAME observable run.

    The enumerated projection: identical exit code, identical per-file `--json`
    event sequences (grouped by file so concurrency order cannot matter),
    identical session header and terminal summary, identical console verdict set,
    and no Progress event in either stream.
    """
    args = [VARIED_SUITE, "--json", "-", "--gh-annotations", "off"]
    many = context.runner.run_mtest([*args, "-n", "4"], timeout=240.0)
    one = context.runner.run_mtest([*args, "-n", "1"], timeout=240.0)
    expect(
        many.returncode == one.returncode,
        f"exit differs across worker counts: -n4 {many.returncode} vs -n1 "
        f"{one.returncode}",
    )
    p_many = _project_stream(many.stdout)
    p_one = _project_stream(one.stdout)
    expect(
        not p_many["has_progress"] and not p_one["has_progress"],
        "a Progress event leaked into the --json stream",
    )
    for key in ("header", "terminal", "exit_code", "per_file"):
        expect(
            p_many[key] == p_one[key],
            f"stream projection differs on {key}: -n4 vs -n1\n"
            f"{p_many[key]!r}\n{p_one[key]!r}",
        )
    verdicts_many = sorted(verdict_paths_in_order(many))
    verdicts_one = sorted(verdict_paths_in_order(one))
    expect(
        verdicts_many == verdicts_one,
        f"console verdict set differs: {verdicts_many} vs {verdicts_one}",
    )
    return (
        f"-n4 == -n1 projection over {VARIED_SUITE}: {len(p_many['per_file'])} "
        f"files, exit {p_many['exit_code']}, no Progress in stream"
    )


def s_parallel_capacity_one(context: ScenarioContext) -> str:
    """`-n 1` is byte-identical to NO FLAG — the capacity-one equivalence.

    A single worker is the sequential default: the timing-masked console and the
    projected `--json` stream must be identical to a run with no `-n` at all, and
    both must report `workers == 1` with no Progress in the stream.
    """
    console_args = [PARALLEL_TREE, "--gh-annotations", "off"]
    one = context.runner.run_mtest([*console_args, "-n", "1"])
    none = context.runner.run_mtest(console_args)
    expect_exit(one, 0)
    expect_exit(none, 0)
    expect(
        _mask_timing(one.stdout) == _mask_timing(none.stdout),
        "the -n 1 console is not byte-identical to the no-flag console "
        "(timing-masked)\n"
        f"--- -n1 ---\n{_mask_timing(one.stdout)}\n"
        f"--- none ---\n{_mask_timing(none.stdout)}",
    )
    stream_args = [PARALLEL_TREE, "--json", "-", "--gh-annotations", "off"]
    one_json = context.runner.run_mtest([*stream_args, "-n", "1"])
    none_json = context.runner.run_mtest(stream_args)
    expect(
        _workers_in_stream(one_json.stdout) == 1
        and _workers_in_stream(none_json.stdout) == 1,
        "capacity-one runs did not both report workers == 1 in the stream",
    )
    expect(
        _project_stream(one_json.stdout) == _project_stream(none_json.stdout),
        "the -n 1 --json stream does not project identically to no-flag",
    )
    return "-n 1 == no flag: identical timing-masked console + projected stream"


def s_parallel_window_overlap(context: ScenarioContext) -> str:
    """At `-n 2`, two files' BUILD windows and RUN windows genuinely overlap.

    The window shim (`--mojo`) stamps each build's wall-clock edges; the fixtures
    stamp their own run edges. Concurrency is proved by the interval inequality
    `start_b < end_a AND start_a < end_b` on both the build log and the run log —
    neither window merely follows the other.
    """
    build_log = _log_path("mtest_window_build_")
    run_log = _log_path("mtest_window_run_")
    run = context.runner.run_mtest(
        [
            "e2e/parallel/test_window_a.mojo",
            "e2e/parallel/test_window_b.mojo",
            "-n",
            "2",
            "--mojo",
            FAKE_WINDOW_MOJO,
            "--gh-annotations",
            "off",
        ],
        timeout=240.0,
        env_overrides={
            "MTEST_WINDOW_LOG": build_log,
            "MTEST_WINDOW_RUN_LOG": run_log,
            "MTEST_WINDOW_BUILD_FLOOR": "0.6",
            "MTEST_WINDOW_RUN_FLOOR": "0.6",
        },
    )
    expect_exit(run, 0)
    builds = _intervals(_log_lines(build_log), "build")
    runs = _intervals(_log_lines(run_log), "run")

    def _assert_overlap(spans: dict[str, tuple[float, float]], what: str) -> None:
        expect(
            len(spans) == 2,
            f"expected two {what} windows, got {len(spans)}: {spans}",
        )
        (_a, (start_a, end_a)), (_b, (start_b, end_b)) = sorted(spans.items())
        expect(
            start_b < end_a and start_a < end_b,
            f"{what} windows did not overlap: "
            f"a=({start_a},{end_a}) b=({start_b},{end_b})",
        )

    _assert_overlap(builds, "build")
    _assert_overlap(runs, "run")
    return "-n 2: build windows overlap AND run windows overlap"


_DISPATCHED = ("a", "b")
"""The two window files `-n 2` can hold in flight, in discovery order."""
_UNDISPATCHED = "c"
"""The window file that must never be dispatched behind the two blocked ones."""
_IN_FLIGHT_FILES = (
    "e2e/parallel/test_window_a.mojo",
    "e2e/parallel/test_window_b.mojo",
)
"""The two identities `-n 2` holds when the interrupt arrives."""
_PARALLEL_NOT_RUN_FILES = (
    *_IN_FLIGHT_FILES,
    "e2e/parallel/test_window_c.mojo",
)
"""Every file a `-n 2` interrupt leaves without a verdict: both in-flight
identities and the one that was never scheduled."""


def s_parallel_interrupt(context: ScenarioContext) -> str:
    """A SIGINT at `-n 2` exits 2 with exact NOT-RUN identities and no survivor.

    Two workers pin the two run-blocked files: each announces its own process
    group and its readiness once its run window is open, so the signal is sent
    on an observed state rather than a wall-clock guess. The third file cannot be
    dispatched behind them, and the run log proves it never was — a pool that
    scheduled one more file after observing the interrupt would leave a third
    record there. Both in-flight identities and the undispatched one are NOT-RUN
    in the console band, in the `--json` stream, and in the JUnit report, and
    every process group the run owned is gone afterwards.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-parallel-interrupt-") as raw:
        tmp = Path(raw)
        ready_dir = tmp / "arming"
        ready_dir.mkdir()
        run_log = _log_path("mtest_interrupt_run_")
        stream_path = os.fspath(tmp / "stream.ndjson")
        junit_path = os.fspath(tmp / "report.xml")
        run, pgid = context.runner.run_mtest_signaled(
            [
                PARALLEL_TREE,
                "-n",
                "2",
                "--json",
                stream_path,
                "--junit-xml",
                junit_path,
                "--color",
                "never",
                "--gh-annotations",
                "off",
            ],
            signal_number=signal.SIGINT,
            timeout=INTERRUPT_TIMEOUT,
            ready_files=tuple(
                os.fspath(ready_dir / f"{name}.ready") for name in _DISPATCHED
            ),
            owned_pgid_files=tuple(
                os.fspath(ready_dir / f"{name}.pgid") for name in _DISPATCHED
            ),
            env_overrides={
                "MTEST_WINDOW_RUN_LOG": run_log,
                "MTEST_WINDOW_RUN_FLOOR": "3600",
                "MTEST_WINDOW_READY_DIR": os.fspath(ready_dir),
            },
        )
        expect_exit(run, 2)

        # No fourth dispatch: the run log carries exactly one start record for
        # each of the two files a `-n 2` pool can hold, and nothing for the third.
        dispatched = [
            line.split("\t")[1]
            for line in _log_lines(run_log)
            if line.split("\t")[0] == "run"
        ]
        # Sorted, because which of two concurrent workers stamps its start first
        # is not a product guarantee — the exact MULTISET is.
        expect(
            sorted(dispatched) == list(_DISPATCHED),
            f"the run log recorded dispatches {sorted(dispatched)}, want exactly "
            f"{list(_DISPATCHED)} — a file was scheduled after the interrupt",
        )
        expect(
            not os.path.exists(ready_dir / f"{_UNDISPATCHED}.ready"),
            f"e2e/parallel/test_window_{_UNDISPATCHED}.mojo announced a run it "
            "was never supposed to be dispatched for",
        )

        bands = SUMMARY_RE.findall(run.combined)
        expect(
            len(bands) == 1,
            f"an interrupted pool must print exactly one terminal summary band, "
            f"got {len(bands)}:\n{run.combined}",
        )
        summ = expect_accounting(run)
        expect(
            (summ.passed, summ.not_run) == (0, len(_PARALLEL_NOT_RUN_FILES)),
            f"parallel interrupt accounting was ({summ.passed} passed, "
            f"{summ.not_run} not run), want (0, {len(_PARALLEL_NOT_RUN_FILES)})"
            f":\n{run.combined}",
        )
        expect(
            not verdict_paths_in_order(run),
            f"an interrupted pool printed verdicts: {verdict_paths_in_order(run)}",
        )

        stream = stream_files(Path(stream_path).read_text(encoding="utf-8"))
        expect(
            stream.has_terminal and stream.exit_code == 2,
            f"the interrupted pool's terminal record was {stream.exit_code!r} "
            f"(terminal={stream.has_terminal})",
        )
        expect(
            sorted(stream.started) == sorted(_IN_FLIGHT_FILES),
            f"the stream announced {stream.started}, want exactly the two "
            f"in-flight files",
        )
        expect(
            stream.finished == {},
            f"the stream finished {stream.finished}; no file reached a verdict",
        )
        expect(
            stream.summary.get("not_run") == len(_PARALLEL_NOT_RUN_FILES)
            and stream.summary.get("pass") == 0,
            f"the terminal summary disagreed with the console band: {stream.summary}",
        )

        report = expect_report(run, junit_path, "the interrupted pool's junit")
        junit_check.check_artifact(report)
        rows = junit_not_run_files(report)
        expect(
            rows == _PARALLEL_NOT_RUN_FILES,
            f"the junit [not-run] rows were {rows}, want {_PARALLEL_NOT_RUN_FILES}",
        )

        expect_group_gone(pgid, "mtest's own group after the parallel interrupt")
        return (
            "-n 2 SIGINT: exit 2, both in-flight identities and the "
            "undispatched one NOT-RUN in console/stream/junit, no fourth "
            "dispatch in the run log, no surviving process group"
        )


def s_parallel_shard_disjoint(context: ScenarioContext) -> str:
    """At `-n 2`, the two hash shards partition the suite and never build across.

    The union of both shards' run sets is the whole suite, the two sets are
    disjoint, and a file sharded OUT of a given shard is never built in it — the
    logging shim's build records for a shard name only that shard's files.
    """
    run_sets: list[set[str]] = []
    built_sets: list[set[str]] = []
    for member in ("hash:1/2", "hash:2/2"):
        log = _log_path(f"mtest_shard_{member.replace(':', '_').replace('/', '_')}_")
        run = context.runner.run_mtest(
            [
                VARIED_SUITE,
                "--shard",
                member,
                "-n",
                "2",
                "--mojo",
                LOGGING_MOJO,
                "--gh-annotations",
                "off",
            ],
            timeout=240.0,
            env_overrides={"MTEST_MOJO_LOG": log},
        )
        run_sets.append(set(verdict_paths_in_order(run)))
        built_sets.append(_built_files(_log_lines(log)))

    whole = context.runner.run_mtest(
        [VARIED_SUITE, "-n", "2", "--gh-annotations", "off"], timeout=240.0
    )
    whole_set = set(verdict_paths_in_order(whole))

    union = run_sets[0] | run_sets[1]
    expect(
        union == whole_set,
        f"shards do not cover the suite: union {sorted(union)} vs whole "
        f"{sorted(whole_set)}",
    )
    expect(
        not (run_sets[0] & run_sets[1]),
        f"shards overlap: {sorted(run_sets[0] & run_sets[1])}",
    )
    for index, member in enumerate(("hash:1/2", "hash:2/2")):
        sharded_out = whole_set - run_sets[index]
        leaked = sharded_out & built_sets[index]
        expect(
            not leaked,
            f"shard {member} built files sharded out of it: {sorted(leaked)}",
        )
    return (
        f"-n 2 hash shards partition {len(whole_set)} files disjointly; "
        "no sharded-out file is built"
    )


def s_collect_parallel(context: ScenarioContext) -> str:
    """`collect -n 2` is byte-identical to `collect` (the capacity-one default).

    Collection only enumerates node ids; a worker count must not perturb one
    byte of the listing.
    """
    many = context.runner.run_mtest(["collect", PARALLEL_TREE, "-n", "2"])
    one = context.runner.run_mtest(["collect", PARALLEL_TREE])
    expect_exit(many, 0)
    expect_exit(one, 0)
    expect(
        many.stdout == one.stdout,
        "collect -n 2 is not byte-identical to collect\n"
        f"--- -n2 ---\n{many.stdout}\n--- default ---\n{one.stdout}",
    )
    return "collect -n 2 == collect: byte-identical node-id listing"


def s_parallel_auto_smoke(context: ScenarioContext) -> str:
    """`-n auto` resolves to a POSITIVE worker count in the stream and console.

    No timing assertion — the auto count is machine-dependent. Only its presence
    and positivity are contractual: the `session_started` record carries a
    positive `workers`, and the console header renders a `workers:` token exactly
    when that count exceeds one.
    """
    run = context.runner.run_mtest(
        [PARALLEL_TREE, "-n", "auto", "--json", "-", "--gh-annotations", "off"],
        timeout=240.0,
    )
    workers = _workers_in_stream(run.stdout)
    expect(
        workers >= 1,
        f"-n auto resolved to a non-positive worker count: {workers}",
    )
    if workers > 1:
        expect(
            f"workers: {workers}" in run.stderr,
            f"-n auto resolved {workers} workers but the console header omits it",
        )
    return f"-n auto resolved a positive worker count ({workers}) in the stream"


def s_parallel_json_workers(context: ScenarioContext) -> str:
    """The live `--json` stream at `-n 2` carries the resolved workers (2)."""
    run = context.runner.run_mtest(
        [PARALLEL_TREE, "-n", "2", "--json", "-", "--gh-annotations", "off"],
        timeout=240.0,
    )
    workers = _workers_in_stream(run.stdout)
    expect(
        workers == 2,
        f"session_started.workers was {workers}, expected 2 at -n 2",
    )
    return "-n 2: session_started.workers == 2 in the live stream"


def s_parallel_j_rejected(context: ScenarioContext) -> str:
    """A user `-j`/`--num-threads` build argument is a forbidden argument (exit 4).

    The runner owns build parallelism, so both spellings are rejected before any
    build, with a message naming the forbidden argument and pointing at
    `-n`/`--workers`.
    """
    for token in ("-j", "--num-threads"):
        run = context.runner.run_mtest(
            [PARALLEL_TREE, "--build-arg", token], check_binary=True
        )
        expect_exit(run, 4)
        expect(
            "forbidden build argument" in run.combined
            and "-n/--workers" in run.combined,
            f"--build-arg {token} was not rejected as a forbidden build "
            f"argument naming -n/--workers:\n{run.combined}",
        )
    return "--build-arg -j and --num-threads both rejected exit 4 (name -n/--workers)"


_PROGRESS_MARKER = "▸".encode()


def s_parallel_progress_tty(context: ScenarioContext) -> str:
    """The live progress counter renders on a PTY at `-n 2` and never on a pipe.

    The counter is a terminal-only affordance: a PTY-attached run at `-n 2` must
    write the counter marker to the terminal, while a piped run at the same
    worker count writes not one marker byte to any stream. Only marker
    presence/absence is asserted — never a timing or count value, which a second
    process could never reproduce. The `--json` stream at `-n 2` is confirmed to
    carry no `progress` event, extending the stream-absence pin to two workers.
    """
    pty_rc, pty_out = context.runner.run_mtest_pty(
        [PARALLEL_TREE, "-n", "2", "--gh-annotations", "off"],
        timeout=240.0,
    )
    expect(
        pty_rc == 0,
        f"expected exit 0 under a pty at -n 2, got {pty_rc}\n{pty_out!r}",
    )
    expect(
        _PROGRESS_MARKER in pty_out,
        "the live progress counter marker was absent from a PTY run at -n 2",
    )

    piped = context.runner.run_mtest(
        [PARALLEL_TREE, "-n", "2", "--gh-annotations", "off"], timeout=240.0
    )
    expect_exit(piped, 0)
    marker = _PROGRESS_MARKER.decode("utf-8")
    expect(
        marker not in piped.stdout
        and marker not in piped.stderr
        and "\x1b[K" not in piped.combined,
        "a progress counter byte leaked into a piped (non-terminal) run",
    )

    stream = context.runner.run_mtest(
        [PARALLEL_TREE, "-n", "2", "--json", "-", "--gh-annotations", "off"],
        timeout=240.0,
    )
    expect(
        not _project_stream(stream.stdout)["has_progress"],
        "a progress event leaked into the --json stream at -n 2",
    )
    return "-n 2: counter present on a PTY, absent on a pipe and in the stream"


def s_parallel_junit_canonical_eq(context: ScenarioContext) -> str:
    """`--junit-xml` at `-n 4` canonicalizes equally to `-n 1` over a varied suite.

    Re-runs the Phase-4 JUnit canonicalizer equality under concurrency: the two
    reports differ only in masked timing, so their canonical forms are byte-equal.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-parallel-junit-") as tmp:
        many = Path(tmp) / "n4.xml"
        one = Path(tmp) / "n1.xml"
        run_many = context.runner.run_mtest(
            [VARIED_SUITE, "--junit-xml", str(many), "-n", "4"], timeout=240.0
        )
        run_one = context.runner.run_mtest(
            [VARIED_SUITE, "--junit-xml", str(one), "-n", "1"], timeout=240.0
        )
        expect_exit(run_many, 1)
        expect_exit(run_one, 1)
        expect(
            many.exists() and one.exists(),
            "a parallel JUnit run exited as expected but wrote no report",
        )
        junit_canonicalize.assert_equal_runs(many, one)
    return "-n 4 JUnit canonicalizes equal to -n 1 over the varied suite"


def _disjoint(a: tuple[float, float], b: tuple[float, float]) -> bool:
    """Whether two half-open wall-clock windows never overlap."""
    return a[1] <= b[0] or b[1] <= a[0]


def s_parallel_serial_noverlap(context: ScenarioContext) -> str:
    """At `-n 2`, `--serial` files run one-at-a-time AFTER the parallel batch.

    One unpinned file (`test_window_a`) runs in the parallel batch; two pinned
    files run on the serial pass. The build shim (`--mojo`) stamps each build's
    window and the fixtures stamp their own run windows, both floored so every
    window is observably wide. The proof is by interval, never by raw timing:

    * every serial file's build window is disjoint from every other build window
      and starts AFTER the lone parallel file's build (serial-last at build
      time);
    * every serial run window is disjoint from every other run window and starts
      AFTER the parallel file's run window (serial-last at run time);
    * `test_a_retry` CRASHES then PASSES under `--retries 1`, so it stamps TWO
      attempt windows — the retry attempt's window is disjoint from and precedes
      the next serial file's window, proving the file's whole pipeline (including
      the retry) drained inside its single serial slot before the next file was
      admitted.
    """
    build_log = _log_path("mtest_serial_build_")
    run_log = _log_path("mtest_serial_run_")
    scratch = os.path.join(REPO_ROOT, "build", "e2e-scratch")
    marker = os.path.join(scratch, "serial_retry_marker")
    os.makedirs(scratch, exist_ok=True)
    if os.path.exists(marker):
        os.remove(marker)
    try:
        run = context.runner.run_mtest(
            [
                "e2e/parallel/test_window_a.mojo",
                "e2e/serial/test_a_retry.mojo",
                "e2e/serial/test_b_next.mojo",
                "-n",
                "2",
                "--serial",
                "e2e/serial/*",
                "--retries",
                "1",
                "--mojo",
                FAKE_WINDOW_MOJO,
                "--gh-annotations",
                "off",
            ],
            timeout=240.0,
            env_overrides={
                "MTEST_WINDOW_LOG": build_log,
                "MTEST_WINDOW_RUN_LOG": run_log,
                "MTEST_WINDOW_BUILD_FLOOR": "0.6",
                "MTEST_WINDOW_RUN_FLOOR": "0.6",
            },
        )
    finally:
        if os.path.exists(marker):
            os.remove(marker)

    # FLAKY (a pass after a crash-class retry) is exit 0.
    expect_exit(run, 0)

    builds = _intervals(_log_lines(build_log), "build")
    runs = _intervals(_log_lines(run_log), "run")

    # --- build windows (all in the shim's clock) ---
    par_build = "e2e/parallel/test_window_a.mojo"
    serial_builds = [
        "e2e/serial/test_a_retry.mojo",
        "e2e/serial/test_b_next.mojo",
    ]
    for name in [par_build, *serial_builds]:
        expect(name in builds, f"no build window for {name}: {builds}")
    for name in serial_builds:
        expect(
            builds[par_build][1] <= builds[name][0],
            f"serial build {name} started before the parallel build drained: "
            f"parallel={builds[par_build]} serial={builds[name]}",
        )
    expect(
        _disjoint(builds[serial_builds[0]], builds[serial_builds[1]]),
        f"the two serial build windows overlap: "
        f"{builds[serial_builds[0]]} vs {builds[serial_builds[1]]}",
    )

    # --- run windows (all in the fixtures' clock) ---
    for name in ("a", "aretry1", "aretry2", "bnext"):
        expect(name in runs, f"no run window named {name!r}: {runs}")
    serial_runs = ["aretry1", "aretry2", "bnext"]
    for name in serial_runs:
        expect(
            runs["a"][1] <= runs[name][0],
            f"serial run {name} started before the parallel run drained: "
            f"parallel={runs['a']} serial={runs[name]}",
        )
    for i in range(len(serial_runs)):
        for j in range(i + 1, len(serial_runs)):
            expect(
                _disjoint(runs[serial_runs[i]], runs[serial_runs[j]]),
                f"serial run windows overlap: {serial_runs[i]}={runs[serial_runs[i]]} "
                f"{serial_runs[j]}={runs[serial_runs[j]]}",
            )
    # The forced retry: the retry attempt's window precedes the next serial file.
    expect(
        runs["aretry2"][1] <= runs["bnext"][0],
        f"the retry attempt did not drain before the next serial file: "
        f"aretry2={runs['aretry2']} bnext={runs['bnext']}",
    )
    return (
        "-n 2: serial builds AND runs are disjoint and serial-last; the forced "
        "retry drains inside its slot before the next serial file"
    )


def s_parallel_serial_stale_glob(context: ScenarioContext) -> str:
    """A `--serial` glob matching no discovered file is a loud stale warning.

    Mirrors the stale-`--exclude` warning: the pattern names nothing, so mtest
    reports it as stale and runs everything in the parallel batch unchanged.
    """
    run = context.runner.run_mtest(
        [
            "e2e/serial/test_b_next.mojo",
            "-n",
            "2",
            "--serial",
            "e2e/nowhere/*does-not-match*",
            "--gh-annotations",
            "off",
        ],
        timeout=120.0,
    )
    expect_exit(run, 0)
    expect(
        "stale-serial" in run.stdout,
        f"no stale-serial warning for an unmatched --serial glob:\n{run.stdout}",
    )
    expect(
        "matched no files" in run.stdout,
        f"the stale-serial warning did not explain itself:\n{run.stdout}",
    )
    return "an unmatched --serial glob -> loud stale-serial warning, exit 0"


FD_CLAMP_SOFT_LIMIT = 76
"""The child's soft `RLIMIT_NOFILE` for the live clamp.

Chosen so the exec layer's own arithmetic — `min(64, (soft - 64 - 3) // 3)`,
64 descriptors of reserved headroom and 3 per supervised child — lands on
exactly three workers: `(76 - 64 - 3) // 3 == 3`. It is also comfortably above
the layer's `_MIN_SOFT_FD` (70), so the run clamps rather than raising the
hard environment fault a ceiling too small for even one child would raise."""

FD_CLAMP_REQUEST = 16
"""The worker count the clamped run asks for: far above the cap, and not a
number the cap arithmetic could ever produce by coincidence."""

FD_CLAMP_CAP = 3
"""The cap `FD_CLAMP_SOFT_LIMIT` yields, asserted as an exact resolved count."""

FD_CLAMP_CONTROL_MIN_SOFT = 115
"""The ambient soft `RLIMIT_NOFILE` the CONTROL run needs to stay unclamped.

The control asserts the full 16 workers, which the same arithmetic reaches only
from `(115 - 64 - 3) // 3 == 16`. A host below this clamps the control too, and
the scenario would fail describing the product when the cause is the host — so
the requirement is asserted up front, beside the hard-limit check, rather than
left for the next reader to derive from an attribution failure."""

FD_CLAMP_TREE = "build/e2e-scratch/fd-clamp"
"""Repo-relative home of this scenario's GENERATED sources.

Deliberately outside `e2e/`. mtest names each build product after the source
path (`/` -> `_s`, `_` -> `_u`), so sources here compile to
`build/bin/build_se2e-scratch_sfd-clamp_...` — a prefix the real compiler never
produces for a committed fixture. That matters because the stand-in writes
Python scripts, not ELF binaries: pointed at a committed fixture it would leave
a `#!`-headed script sitting under the exact name a real `mojo build` produces,
where a later scenario expecting a prebuilt binary, or a `build/` cleanliness
check, would trip over it. `build/` is also gitignored and never walked by the
manifest-completeness oracle, so these files join no committed inventory."""

FD_CLAMP_NAMES = ("test_fd_alpha", "test_fd_beta", "test_fd_gamma", "test_fd_delta")
"""The four generated modules. More files than workers, so the clamped pool has
to recycle a slot to finish the set."""

FD_CLAMP_FILES = tuple(f"{FD_CLAMP_TREE}/{name}.mojo" for name in FD_CLAMP_NAMES)
"""The four generated sources, in the order they are written."""

FD_CLAMP_SOURCE = '''\
"""Generated all-pass fixture for the live descriptor-clamp scenario."""
from std.testing import assert_equal, TestSuite


def {test_name}() raises:
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
'''
"""One generated module's whole source.

Exactly ONE test per file, so the summary band's per-TEST total is 4 — the
number the contract names — while per-FILE identity is pinned separately and
exactly by the console PASS set and the stream's finished map. Generating the
files rather than borrowing committed fixtures also makes that test count a
property of this scenario instead of an assumption about four unrelated files.
Real `TestSuite` shape, so the fixture genuinely compiles and passes under the
actual compiler even though this scenario always hands it to the stand-in."""

FD_CLAMP_WARNING = (
    f"worker-clamp: requested {FD_CLAMP_REQUEST} workers but the environment's"
    f" file-descriptor ceiling caps concurrency at {FD_CLAMP_CAP}; running with"
    f" {FD_CLAMP_CAP}"
)
"""The exact console warning, naming request, cap, and resolved count.

Pinned whole rather than by fragments: three separate `in` checks for the
request and the cap would also pass against a warning that named those numbers
in any other roles, and this scenario exists to prove which number is which.
Interpolated from the constants above so the sentence and the counts this
scenario asserts elsewhere can never drift apart."""


def _write_fd_clamp_tree() -> None:
    """Generate this scenario's four all-pass sources, replacing any residue.

    Raises:
        OSError: The scratch tree could not be created or written.
    """
    root = os.path.join(REPO_ROOT, FD_CLAMP_TREE)
    os.makedirs(root, exist_ok=True)
    for name in FD_CLAMP_NAMES:
        with open(os.path.join(root, f"{name}.mojo"), "w", encoding="utf-8") as f:
            f.write(FD_CLAMP_SOURCE.format(test_name=f"{name}_passes"))


def _remove_fd_clamp_artifacts() -> None:
    """Delete the generated sources and the products the stand-in fabricated.

    The fabricated products are Python scripts under compiler-shaped names, so
    they are removed on every path — success or failure — rather than left for
    a later scenario to find. Best-effort: a missing artifact is the intended
    state, and a cleanup failure must never replace a scenario's own diagnosis.
    """
    shutil.rmtree(os.path.join(REPO_ROOT, FD_CLAMP_TREE), ignore_errors=True)
    # A hand-mirror of the product's `_mangle` (src/mtest/session/scratch.mojo),
    # which cannot be imported from Python. Two sequential replaces match its
    # single pass only while `FD_CLAMP_TREE` holds no `_` and `FD_CLAMP_NAMES`
    # hold no `/`; introduce either and the passes interfere, the reconstructed
    # name stops matching, and the products below go silently uncollected.
    if "_" in FD_CLAMP_TREE:
        raise AssertionError(FD_CLAMP_TREE)
    if any("/" in name for name in FD_CLAMP_NAMES):
        raise AssertionError(FD_CLAMP_NAMES)
    mangled = FD_CLAMP_TREE.replace("_", "_u").replace("/", "_s")
    for name in FD_CLAMP_NAMES:
        product = os.path.join(
            REPO_ROOT,
            "build",
            "bin",
            f"{mangled}_s{name.replace('_', '_u')}",
        )
        with contextlib.suppress(OSError):
            os.remove(product)


def s_parallel_fd_clamp(context: ScenarioContext) -> str:
    """A real low `RLIMIT_NOFILE` clamps `-n 16` to 3 loudly and still runs all 4.

    The limit is genuine: the harness lowers the soft descriptor limit of the
    mtest CHILD ONLY, through a `preexec_fn` between the fork and the exec, so
    the kernel — not a stub, a mock, or an environment variable — is what the
    exec layer's `query_effective_cap` reads.

    Because 76 descriptors cannot link a real Mojo binary, the compiler is
    `fake_fd_mojo.py`, which fabricates directly executable pass actors instead
    of calling LLVM. That keeps the ceiling where the scenario claims it is —
    on mtest's native pool and scheduler — rather than moving the failure into
    the toolchain, where it would prove nothing about worker sizing.

    The four sources are GENERATED under `build/e2e-scratch/`, not borrowed from
    the committed tree, for two reasons: the per-file test count becomes a
    property of this scenario rather than an assumption about other fixtures,
    and the stand-in's Python-script products land under a `build_s...` name no
    real `mojo build` ever produces, so they can neither be mistaken for nor
    overwrite compiler output. Both the sources and those products are removed
    on every exit path.

    The clamp is attributed, not merely observed. A CONTROL run with the same
    argv and no fd limit must resolve the full 16 workers and print no clamp
    warning at all, so the only difference between the two runs is the real
    kernel limit, and three workers cannot be credited to the request, the file
    count, the machine's cores, or the stand-in compiler.
    """
    if not hasattr(resource, "RLIMIT_NOFILE"):
        # Neither supported platform reaches this: Linux and macOS both define
        # RLIMIT_NOFILE, so this is a statement about portability, not a
        # tolerance that could quietly disarm the scenario on a supported host.
        return "skipped: this platform has no RLIMIT_NOFILE to lower"
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    expect(
        hard == resource.RLIM_INFINITY or hard >= FD_CLAMP_SOFT_LIMIT,
        f"the host's hard RLIMIT_NOFILE is {hard}, below the {FD_CLAMP_SOFT_LIMIT} "
        "this scenario lowers the child to — the run could not even start",
    )
    # The control run inherits THIS process's soft limit, so the host has to be
    # able to reach the full request for the control to mean anything. Stated
    # here, next to the hard-limit precondition, so a hardened host is named as
    # the cause up front rather than surfacing later as an attribution failure.
    expect(
        soft == resource.RLIM_INFINITY or soft >= FD_CLAMP_CONTROL_MIN_SOFT,
        f"the host's own soft RLIMIT_NOFILE is {soft}, below the "
        f"{FD_CLAMP_CONTROL_MIN_SOFT} the unlimited CONTROL run needs to resolve "
        f"the full {FD_CLAMP_REQUEST} workers — on this host the control would "
        "clamp too, and the scenario could not attribute the clamp to the limit "
        "it imposes",
    )

    args = [
        *FD_CLAMP_FILES,
        "-n",
        str(FD_CLAMP_REQUEST),
        "--json",
        "-",
        "--mojo",
        FAKE_FD_MOJO,
        "--gh-annotations",
        "off",
    ]
    # Inside the `try`, not before it: writing the tree is itself a loop over
    # four files, so a failure partway through leaves sources behind unless the
    # `finally` already owns them.
    try:
        _write_fd_clamp_tree()
        run = context.runner.run_mtest(
            args, timeout=240.0, fd_limit=FD_CLAMP_SOFT_LIMIT
        )
        expect_exit(run, 0)

        expect(
            FD_CLAMP_WARNING in run.stderr,
            f"the clamped run did not print the exact worker-clamp warning "
            f"{FD_CLAMP_WARNING!r}:\n--- stderr ---\n{run.stderr}",
        )
        workers = _workers_in_stream(run.stdout)
        expect(
            workers == FD_CLAMP_CAP,
            f"session_started.workers was {workers}, want exactly {FD_CLAMP_CAP} "
            f"under a soft RLIMIT_NOFILE of {FD_CLAMP_SOFT_LIMIT}",
        )

        # `--json -` owns stdout, so the human console — verdict rows included —
        # is on stderr for this run.
        console_passes = sorted(
            line.split()[1]
            for line in run.stderr.splitlines()
            if line.startswith("PASS ") and len(line.split()) > 1
        )
        expect(
            console_passes == sorted(FD_CLAMP_FILES),
            f"the clamped console reported PASS for {console_passes}, want exactly "
            f"{sorted(FD_CLAMP_FILES)}:\n{run.stderr}",
        )
        stream = stream_files(run.stdout)
        expect(
            stream.finished == dict.fromkeys(FD_CLAMP_FILES, "pass"),
            f"the clamped stream finished {stream.finished}, want all four files pass",
        )

        summ = expect_accounting(run)
        actual = (
            summ.passed,
            summ.failed,
            summ.skipped,
            summ.crashed,
            summ.timed_out,
            summ.compile_error,
            summ.malformed,
            summ.excluded,
            summ.not_run,
        )
        expect(
            actual == (len(FD_CLAMP_FILES), 0, 0, 0, 0, 0, 0, 0, 0),
            f"the clamped run's summary band was {actual}, want "
            f"({len(FD_CLAMP_FILES)}, 0, 0, 0, 0, 0, 0, 0, 0):\n{run.combined}",
        )
        expect(
            stream.summary.get("pass") == len(FD_CLAMP_FILES)
            and stream.summary.get("not_run") == 0,
            f"the machine summary disagreed with the console band: {stream.summary}",
        )
        expect(
            "INTERNAL-ERROR" not in run.combined and "EMFILE" not in run.combined,
            "a descriptor exhaustion or internal error surfaced under the clamp:\n"
            f"{run.combined}",
        )

        # The CONTROL: same argv, no fd limit. Its full 16 workers and silent
        # console are what make the clamp above attributable to the kernel limit.
        control = context.runner.run_mtest(args, timeout=240.0)
        expect_exit(control, 0)
        control_workers = _workers_in_stream(control.stdout)
        expect(
            control_workers == FD_CLAMP_REQUEST,
            f"without the fd limit the same argv resolved {control_workers} workers, "
            f"want the full {FD_CLAMP_REQUEST} — the clamp above cannot be "
            "attributed to RLIMIT_NOFILE unless this run is unclamped. This "
            f"host's own soft RLIMIT_NOFILE is {soft}, which the precondition "
            f"above required to be at least {FD_CLAMP_CONTROL_MIN_SOFT}",
        )
        expect(
            "worker-clamp" not in control.combined,
            f"the unlimited control run printed a worker-clamp warning:\n"
            f"{control.combined}",
        )
    finally:
        _remove_fd_clamp_artifacts()
    return (
        f"soft RLIMIT_NOFILE {FD_CLAMP_SOFT_LIMIT}: -n {FD_CLAMP_REQUEST} clamps "
        f"loudly to {FD_CLAMP_CAP} workers, all {len(FD_CLAMP_FILES)} files PASS, "
        f"exit 0; the same argv unlimited resolves {FD_CLAMP_REQUEST} and warns "
        "nothing"
    )
