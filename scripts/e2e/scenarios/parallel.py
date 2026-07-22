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

import os
import re
import signal
import tempfile
from pathlib import Path

from scripts.checks.reports import json_stream as json_stream_check
from scripts.checks.reports import junit_canonicalize
from scripts.e2e.assertions import (
    SUMMARY_RE,
    expect,
    expect_exit,
    verdict_paths_in_order,
)
from scripts.e2e.runner import (
    FAKE_WINDOW_MOJO,
    LOGGING_MOJO,
    ScenarioContext,
    ScenarioError,
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
    masked = _TIMING_SECONDS.sub("Ts", masked)
    return masked


def _canonical_record(record: dict) -> tuple:
    """A record reduced to its semantic fields, sorted and volatility-stripped."""
    items = sorted(
        (key, str(value))
        for key, value in record.items()
        if key not in _VOLATILE_FIELDS
    )
    return tuple(items)


def _project_stream(text: str) -> dict:
    """Project a `--json` stream to a worker-count-independent shape.

    Records are grouped by file so concurrent interleaving cannot perturb the
    comparison, volatile timing fields are stripped, and the session header
    (minus its worker count) plus the terminal summary are kept whole. Two runs
    that differ only in `-n` must project equally.
    """
    report = json_stream_check.parse_stream(text)
    per_file: dict[str, list[tuple]] = {}
    header: tuple = ()
    terminal: tuple = ()
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
            path = record.get("path", "")
            per_file.setdefault(path, []).append(_canonical_record(record))
    return {
        "header": header,
        "terminal": terminal,
        "exit_code": report.exit_code,
        "per_file": {path: per_file[path] for path in sorted(per_file)},
        "has_progress": any(
            r.get("event") == "progress" for r in report.records
        ),
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
    """Fold `<kind>\\t<name>\\t<edge>[...]` records into per-name (start, end) spans.

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


def s_parallel_interrupt(context: ScenarioContext) -> str:
    """A SIGINT at `-n 2` mid-run exits 2, accounts unstarted files NOT-RUN, and
    leaves no surviving process group.

    Two workers pin the two run-blocked files (each fixture sleeps far past the
    signal once its run log is armed), so a third file can never be dispatched and
    is deterministically NOT-RUN. The interrupt must be what ends the run — a
    harness timeout would raise instead — and the whole process group must be gone
    afterward, proving the parallel teardown left no orphan.
    """
    run_log = _log_path("mtest_interrupt_run_")
    run, pgid = context.runner.run_mtest_signaled(
        [PARALLEL_TREE, "-n", "2", "--gh-annotations", "off"],
        signal_number=signal.SIGINT,
        delay=20.0,
        timeout=90.0,
        env_overrides={
            "MTEST_WINDOW_RUN_LOG": run_log,
            "MTEST_WINDOW_RUN_FLOOR": "3600",
        },
    )
    expect(
        run.returncode == 2,
        f"expected exit 2 on parallel interrupt, got {run.returncode}\n"
        f"{run.stdout}\n{run.stderr}",
    )
    match = SUMMARY_RE.search(run.combined)
    expect(match is not None, f"no partial summary after interrupt:\n{run.combined}")
    not_run = int(match.group("not_run"))
    expect(
        not_run >= 1,
        f"interrupt summary showed no NOT-RUN accounting (not_run={not_run})",
    )
    orphan = True
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        orphan = False
    expect(not orphan, f"process group {pgid} survived the parallel interrupt")
    return f"-n 2 SIGINT: exit 2, {not_run} NOT-RUN, no surviving process group"


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


_PROGRESS_MARKER = "▸".encode("utf-8")


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
