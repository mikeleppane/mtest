"""The parallel scheduler: drive many files' build-run pipelines at once.

Layer 4, the path `run_session` takes when the resolved worker count exceeds
one. Where the sequential drivers run one child at a time, this module drives up
to `workers` children concurrently under one `Supervisor`, each child one step —
a build or a run — of some file's own strictly ordered pipeline. A file's steps
stay in order (build, then run, then any crash-class retry, then its verdict);
concurrency is only ever *across* files.

The run is three ordered batches: the gates first, as their own batch — a
failing or drifting gate `kill_all`s the batch immediately, accounts the rest
NOT-RUN, and aborts the whole run — then the parallel run files in discovery
order, then the serial files (a no-op hook here; serial pinning lands later). A
`--maxfail`/`-x` stop halts new dispatch, lets the in-flight files finish, and
leaves the remainder NOT-RUN. An interrupt tears every live group down and
resolves exit 2 through `resolve_exit_code`, never through the kernel's halt.

The token budget keeps concurrent builds from oversubscribing the cores: each
build acquires `K = build_tokens(workers, cores)` tokens against a `cores`-wide
budget and spawns `mojo build --num-threads K`; a run takes no tokens. The
budget is consulted only here, so the sequential path's build argv stays clean.
"""
from std.io import FileDescriptor
from std.time import perf_counter_ns

from mtest.config import RunnerConfig, lossy_utf8
from mtest.exec import (
    Completion,
    ExecRuntime,
    ProcessResult,
    ProcessSpec,
    Supervisor,
    Termination,
    canonicalize,
    interrupt_requested,
    query_effective_cap,
)
from mtest.model import (
    Event,
    Outcome,
    Summary,
    TestCounts,
)
from mtest.report import ReportCoordinator
from mtest.session.attempt import (
    _AttemptResult,
    _compile_crash_residual,
    _finalize_attempt,
    _flaky_eligible,
    _make_attempt_finished,
)
from mtest.session.build import _COMPILE_GRACE_MS
from mtest.session.classify import classify, resolve_report
from mtest.session.file_result import (
    FileResult,
    _CrashFile,
    _failing_count,
    _prepend_events,
)
from mtest.session.pipeline import PipelineHalt, RunPipeline
from mtest.session.pool_plan import WorkerPlan, build_tokens, resolve_workers
from mtest.session.retry_class import retry_classify
from mtest.session.scratch import (
    _ensure_dir,
    _invocation_nonce,
    _mangle,
    _quarantine_dir,
    _retry_out_bin,
)
from mtest.session.verdict import build_verdict

from std.sys import num_logical_cores

comptime _PENDING_BUILD = 0
"""The file needs its next build spawned."""
comptime _BUILDING = 1
"""The file's build is in flight."""
comptime _PENDING_RUN = 2
"""The file is built and needs its run spawned."""
comptime _RUNNING = 3
"""The file's run is in flight."""
comptime _DONE = 4
"""The file has a verdict, or was abandoned NOT-RUN."""

comptime _POLL_SLICE_MS = 50
"""The blocking bound one `wait_any` sweep may sleep."""


def resolve_worker_plan(config: RunnerConfig) raises -> WorkerPlan:
    """Resolve the run's worker plan from the config, cores, and the fd cap.

    A `workers` of exactly one is the sequential path and never queries the cap:
    it resolves to a plain one-worker plan so the sequential run keeps its exact
    behavior and never gains a new failure mode. Any other value reads the
    machine's logical core count and the exec layer's effective descriptor
    ceiling and resolves against both, clamping loudly when the request exceeds
    the ceiling.

    Args:
        config: The run configuration, carrying the requested worker count.

    Returns:
        The resolved plan: `resolved` in `1 ..= cap`, `clamped` set when the cap
        lowered the request.

    Raises:
        Error: The hard environment fault from `query_effective_cap` when the
            descriptor ceiling cannot fit even a single child. A caller maps it
            to internal-error exit 3.
    """
    if config.workers == 1:
        return WorkerPlan(1, 1, 1, False)
    var cap = query_effective_cap()
    return resolve_workers(config.workers, num_logical_cores(), cap)


@fieldwise_init
struct PoolBatchResult(Movable):
    """What one pooled batch folds back into `run_session`.

    Owns its lists; copies are explicit.
    """

    var run_outcomes: List[Outcome]
    """The batch's exit-code multiset contribution."""
    var test_totals: TestCounts
    """The batch's per-test totals."""
    var ran_files: Int
    """How many files produced a tallied verdict."""
    var interrupted: Bool
    """Whether an interrupt aborted the batch (exit 2)."""
    var internal_error: Bool
    """Whether a spawn/machinery failure occurred (exit 3)."""
    var drift: Bool
    """Whether any verdict drifted off the pinned grammar (exit 3)."""
    var aborted: Bool
    """Whether a failing or drifting gate aborted the whole run."""
    var crash_files: List[_CrashFile]
    """The files that ended CRASH, for the sequential attribution post-pass."""


struct _PoolFile(Movable):
    """One file's position and carried facts inside a pooled batch."""

    var rel: String
    var phase: Int
    var attempt: Int
    var mangled: String
    var out_bin: String
    var quarantine_dir: String
    var build_argv: List[String]
    var bterm: Termination
    var build_stderr: List[UInt8]
    var bdur: Float64
    var pre_events: List[Event]
    var quarantine_dirs: List[String]
    var had_retry: Bool
    var started_emitted: Bool
    var dispatch_ns: Int

    def __init__(out self, rel: String, mangled: String):
        """A freshly admitted file, before its first build spawns."""
        self.rel = rel
        self.phase = _PENDING_BUILD
        self.attempt = 1
        self.mangled = mangled
        self.out_bin = String("build/bin/") + mangled
        self.quarantine_dir = String("")
        self.build_argv = List[String]()
        self.bterm = Termination.exited(0)
        self.build_stderr = List[UInt8]()
        self.bdur = 0.0
        self.pre_events = List[Event]()
        self.quarantine_dirs = List[String]()
        self.had_retry = False
        self.started_emitted = False
        self.dispatch_ns = 0


def _pool_flush[C: ReportCoordinator](mut reporter: C, console_fd: Int):
    """Drain the coordinator's pending console bytes to the borrowed handle.

    Best-effort, exactly as the sequential driver's flush: a negative handle or
    an empty drain writes nothing, and a failed write is not a new exit cause.

    Args:
        reporter: The coordinator to drain.
        console_fd: The borrowed console descriptor, or negative when none.
    """
    if console_fd < 0:
        return
    var chunk = reporter.drain_console(False)
    if chunk.byte_length() == 0:
        return
    print(chunk, end="", file=FileDescriptor(console_fd), flush=True)


def _emit_progress[
    C: ReportCoordinator
](mut reporter: C, files: List[_PoolFile], completed: Int, total: Int):
    """Emit one ephemeral progress tick for the files currently in flight.

    Console-only: the JSON stream filters this kind, so it never reaches a
    machine consumer. Emitted once per folded completion, a rate the real
    build/run cadence keeps well under ten per second.

    Args:
        reporter: The coordinator the tick is handed to.
        files: The batch's files, scanned for those in flight.
        completed: How many files have a verdict so far.
        total: How many files the batch owns.
    """
    var now = Int(perf_counter_ns())
    var paths = List[String]()
    var elapsed = List[Float64]()
    for i in range(len(files)):
        ref f = files[i]
        if f.phase == _BUILDING or f.phase == _RUNNING:
            paths.append(f.rel)
            elapsed.append(Float64(now - f.dispatch_ns) / 1.0e9)
    reporter.handle(Event.progress(completed, total, paths^, elapsed^))


def _run_pool_batch[
    C: ReportCoordinator
](
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    files: List[String],
    include_paths: List[String],
    mut reporter: C,
    mut summary: Summary,
    workers: Int,
    cores: Int,
    is_gate: Bool,
    console_fd: Int,
) raises -> PoolBatchResult:
    """Drive one batch of files' build-run pipelines at capacity `workers`.

    The engine fills open slots in discovery order — a ready run first, since a
    run frees a slot without a token, then the earliest pending build the token
    budget admits — blocks once in `wait_any`, and folds each completion into
    its file's pipeline, spawning that file's next step or settling its verdict.
    A `Completion`'s `kill_cause` is consumed: an interrupt-caused kill abandons
    its file NOT-RUN and tears the batch down; a deadline kill is a genuine
    TIMEOUT verdict. The gate batch aborts the whole run on the first failing or
    drifting verdict; the run batch honors `-x`/`--maxfail`, letting in-flight
    files finish and leaving the rest NOT-RUN.

    Args:
        runtime: The active exec runtime; the Supervisor drives children under
            the process-global signal state it owns.
        config: The resolved run configuration.
        root: The invocation root every child runs in.
        files: The batch's files, in discovery order.
        include_paths: Directories passed to the compiler as `-I`.
        reporter: The coordinator every event is handed to.
        summary: The run summary, accumulated as files settle.
        workers: The resolved worker count — the Supervisor's capacity.
        cores: The machine's logical core count, for the token budget.
        is_gate: Whether this batch is the gates, which abort the run on a
            failing or drifting verdict.
        console_fd: The borrowed console descriptor for incremental flushes.

    Returns:
        What the batch folds back into `run_session`.

    Raises:
        Error: A source-canonicalization or scratch-directory failure. Supervisor
            machinery raises are caught and resolved to internal-error facts.
    """
    if not runtime.active:
        raise Error("session: the parallel pool requires an active ExecRuntime")
    var n = len(files)
    var result = PoolBatchResult(
        List[Outcome](),
        TestCounts.zeros(),
        0,
        False,
        False,
        False,
        False,
        List[_CrashFile](),
    )
    if n == 0:
        return result^

    var attempts_planned = config.retries + 1
    var nonce = _invocation_nonce()
    var k = build_tokens(workers, cores)
    var budget = cores if cores >= 1 else 1

    _ensure_dir(root + "/build/bin")

    var state = List[_PoolFile]()
    for i in range(n):
        state.append(_PoolFile(files[i], _mangle(files[i])))

    # The kernel serves as the stop-policy oracle: gates are always exit-first,
    # the run batch honors the config's `-x`/`--maxfail`. `record_verdict`'s 8a
    # guard keeps a straggling limit verdict from downgrading a latched halt.
    var pipeline = RunPipeline(
        n,
        config.retries,
        True if is_gate else config.exitfirst,
        0 if is_gate else config.maxfail,
    )

    var supervisor = Supervisor(workers)
    var tokens_in_use = 0
    var stop_scheduling = False
    var completed = 0

    while True:
        # Scheduling boundary: a pending interrupt tears the batch down at once,
        # abandoning every unfinished file.
        if not result.interrupted and interrupt_requested():
            result.interrupted = True
            pipeline.halt_interrupted()
            try:
                supervisor.kill_all()
            except:
                pass
            break

        # Fill open slots: a ready run first (free), else the earliest pending
        # build the token budget admits.
        if not stop_scheduling:
            while supervisor.in_flight() < workers:
                var picked = -1
                var as_run = False
                for i in range(n):
                    if state[i].phase == _PENDING_RUN:
                        picked = i
                        as_run = True
                        break
                if picked == -1:
                    for i in range(n):
                        if state[i].phase == _PENDING_BUILD:
                            if (
                                tokens_in_use == 0
                                or tokens_in_use + k <= budget
                            ):
                                picked = i
                            break
                if picked == -1:
                    break
                if as_run:
                    var run_argv = List[String]()
                    run_argv.append(state[picked].out_bin)
                    _ = supervisor.spawn(
                        ProcessSpec.command_in(
                            run_argv^, root, config.timeout_secs * 1000
                        ),
                        picked,
                    )
                    state[picked].phase = _RUNNING
                    state[picked].dispatch_ns = Int(perf_counter_ns())
                else:
                    var build_argv = List[String]()
                    build_argv.append(config.mojo_path)
                    build_argv.append("build")
                    build_argv.append(state[picked].rel)
                    build_argv.append("-o")
                    build_argv.append(state[picked].out_bin)
                    for p in include_paths:
                        build_argv.append("-I")
                        build_argv.append(p)
                    for a in config.build_args:
                        build_argv.append(a)
                    state[picked].build_argv = build_argv.copy()
                    # The token flag rides the SPAWN argv; the stored reproduce
                    # argv stays clean, so an ordinary verdict's reproduce line
                    # carries no `--num-threads`.
                    var spawn_argv = build_argv^
                    spawn_argv.append("--num-threads")
                    spawn_argv.append(String(k))
                    var env_extra = List[String]()
                    if state[picked].quarantine_dir != "":
                        env_extra.append(
                            "MODULAR_CACHE_DIR=" + state[picked].quarantine_dir
                        )
                    _ = supervisor.spawn(
                        ProcessSpec.command_in(
                            spawn_argv^,
                            root,
                            config.compile_timeout_secs * 1000,
                            _COMPILE_GRACE_MS,
                            env_extra^,
                        ),
                        picked,
                    )
                    state[picked].phase = _BUILDING
                    state[picked].dispatch_ns = Int(perf_counter_ns())
                    tokens_in_use += k
                    if not state[picked].started_emitted:
                        reporter.handle(Event.file_started(state[picked].rel))
                        state[picked].started_emitted = True

        if supervisor.in_flight() == 0:
            break

        var completion = Optional[Completion](None)
        var faulted = False
        try:
            completion = supervisor.wait_any(_POLL_SLICE_MS)
        except:
            faulted = True
        if faulted:
            # A machinery fault tore the Supervisor down. Resolve to exit 3 and
            # abandon the rest; the teardown already ran inside `wait_any`.
            result.internal_error = True
            pipeline.halt_internal_error()
            break
        if not completion:
            continue

        var comp = completion.take()
        var i = comp.tag
        var was_build = state[i].phase == _BUILDING
        var interrupt_kill = False
        if comp.kill_cause:
            interrupt_kill = comp.kill_cause.value().is_interrupt()

        if was_build:
            tokens_in_use -= k

        if interrupt_kill:
            # Its file is abandoned NOT-RUN; tear the rest down.
            result.interrupted = True
            pipeline.halt_interrupted()
            state[i].phase = _DONE
            try:
                supervisor.kill_all()
            except:
                pass
            break

        var res = comp.result.copy()
        var term = res.termination

        var gate_kill = False
        if was_build:
            state[i].bdur = Float64(res.duration_ms) / 1000.0
            state[i].bterm = term
            state[i].build_stderr = res.stderr_bytes.copy()
            if term.is_spawn_failed():
                reporter.handle(
                    Event.internal_error("build", config.mojo_path, term.value)
                )
                result.internal_error = True
                stop_scheduling = True
                pipeline.halt_internal_error()
                state[i].phase = _DONE
            else:
                var bv = build_verdict(term)
                if bv.is_failing():
                    var rc = retry_classify(
                        "build", term, False, state[i].build_stderr
                    )
                    if (
                        rc.retry_eligible
                        and state[i].attempt < attempts_planned
                        and not stop_scheduling
                    ):
                        state[i].had_retry = True
                        var att = _AttemptResult._build_failed(
                            state[i].build_argv.copy(),
                            term,
                            state[i].build_stderr.copy(),
                            state[i].bdur,
                            state[i].out_bin,
                        )
                        state[i].pre_events.append(
                            _make_attempt_finished(
                                state[i].rel,
                                rc,
                                att,
                                state[i].attempt,
                                attempts_planned,
                            )
                        )
                        state[i].pre_events.append(
                            Event.warning(
                                "compile-kill-residual",
                                _compile_crash_residual(
                                    "compile", state[i].rel, rc, term
                                ),
                            )
                        )
                        state[i].attempt += 1
                        state[i].out_bin = _retry_out_bin(
                            state[i].mangled, state[i].attempt, nonce
                        )
                        state[i].quarantine_dir = _quarantine_dir(
                            "", state[i].mangled, state[i].attempt, nonce
                        )
                        _ensure_dir(root + "/" + state[i].quarantine_dir)
                        state[i].quarantine_dirs.append(state[i].quarantine_dir)
                        state[i].phase = _PENDING_BUILD
                    else:
                        # A terminal compile failure. A COMPILE_TIMEOUT reproduce
                        # line names the effective `--num-threads`; a plain
                        # compile error stays clean.
                        var verdict_argv = state[i].build_argv.copy()
                        if bv == Outcome.COMPILE_TIMEOUT:
                            verdict_argv.append("--num-threads")
                            verdict_argv.append(String(k))
                        var att = _AttemptResult._build_failed(
                            verdict_argv^,
                            term,
                            state[i].build_stderr.copy(),
                            state[i].bdur,
                            state[i].out_bin,
                        )
                        var fr = _finalize_attempt(
                            config, state[i].rel, att^, state[i].attempt, False
                        )
                        gate_kill = _settle(
                            state,
                            i,
                            fr^,
                            reporter,
                            summary,
                            pipeline,
                            result,
                            is_gate,
                        )
                        completed += 1
                        if (not is_gate) and pipeline.halt() != (
                            PipelineHalt.RUNNING
                        ):
                            stop_scheduling = True
                else:
                    state[i].phase = _PENDING_RUN
        else:
            # A completed run.
            if term.is_spawn_failed():
                reporter.handle(
                    Event.internal_error("run", state[i].out_bin, term.value)
                )
                result.internal_error = True
                stop_scheduling = True
                pipeline.halt_internal_error()
                state[i].phase = _DONE
            else:
                var rdur = Float64(res.duration_ms) / 1000.0
                var source_path = canonicalize(root + "/" + state[i].rel)
                var trusted = resolve_report(
                    lossy_utf8(res.stdout_bytes),
                    source_path,
                    res.stdout_truncated,
                )
                var cls = classify(term, trusted.report, trusted.is_overflow)
                var attempt_passed = _flaky_eligible(cls.file_outcome)
                var rc = retry_classify("run", term, False, res.stderr_bytes)
                if (
                    rc.retry_eligible
                    and state[i].attempt < attempts_planned
                    and not stop_scheduling
                ):
                    state[i].had_retry = True
                    var att = _AttemptResult(
                        0,
                        Event.file_started(""),
                        False,
                        state[i].build_argv.copy(),
                        state[i].bterm,
                        state[i].build_stderr.copy(),
                        state[i].bdur,
                        state[i].out_bin,
                        term,
                        res.stdout_bytes.copy(),
                        res.stderr_bytes.copy(),
                        rdur,
                        trusted.copy(),
                        cls.copy(),
                        res.stdout_truncated,
                        res.stderr_truncated,
                    )
                    state[i].pre_events.append(
                        _make_attempt_finished(
                            state[i].rel,
                            rc,
                            att,
                            state[i].attempt,
                            attempts_planned,
                        )
                    )
                    state[i].attempt += 1
                    # A run retry re-runs the same binary; no rebuild.
                    state[i].phase = _PENDING_RUN
                else:
                    var flaky = state[i].had_retry and attempt_passed
                    var att = _AttemptResult(
                        0,
                        Event.file_started(""),
                        False,
                        state[i].build_argv.copy(),
                        state[i].bterm,
                        state[i].build_stderr.copy(),
                        state[i].bdur,
                        state[i].out_bin,
                        term,
                        res.stdout_bytes.copy(),
                        res.stderr_bytes.copy(),
                        rdur,
                        trusted.copy(),
                        cls.copy(),
                        res.stdout_truncated,
                        res.stderr_truncated,
                    )
                    var fr = _finalize_attempt(
                        config, state[i].rel, att^, state[i].attempt, flaky
                    )
                    gate_kill = _settle(
                        state,
                        i,
                        fr^,
                        reporter,
                        summary,
                        pipeline,
                        result,
                        is_gate,
                    )
                    completed += 1
                    if (not is_gate) and pipeline.halt() != (
                        PipelineHalt.RUNNING
                    ):
                        stop_scheduling = True

        _emit_progress(reporter, state, completed, n)
        _pool_flush(reporter, console_fd)

        if gate_kill:
            try:
                supervisor.kill_all()
            except:
                pass
            break

    return result^


def _settle[
    C: ReportCoordinator
](
    mut state: List[_PoolFile],
    i: Int,
    var fr: FileResult,
    mut reporter: C,
    mut summary: Summary,
    mut pipeline: RunPipeline,
    mut result: PoolBatchResult,
    is_gate: Bool,
) raises -> Bool:
    """Settle one file's verdict: emit it, account it, and apply the policy.

    Prepends the file's accumulated attempt events, emits the verdict, folds the
    per-test totals, and — for a non-drift verdict — tallies the outcome, extends
    the run multiset, records the verdict against the stop policy, and queues a
    crash for attribution. A drift verdict forces exit 3 and is accounted NOT-RUN
    rather than tallied, exactly as the sequential path does.

    Args:
        state: The batch's file state, whose `i`th entry is being settled.
        i: The settling file's index.
        fr: The file's terminal result. Consumed.
        reporter: The coordinator the verdict is handed to.
        summary: The run summary to tally into.
        pipeline: The stop-policy kernel.
        result: The batch accumulators to fold into.
        is_gate: Whether this is a gate, which aborts the run on a failing or
            drifting verdict.

    Returns:
        True when a gate verdict aborts the whole run (the caller kills the
        batch); False otherwise.
    """
    var settled = _prepend_events(state[i].pre_events.copy(), fr^)
    for pe in settled.pre_events:
        reporter.handle(pe)
    reporter.handle(settled.event)
    result.test_totals.passed += settled.test_counts.passed
    result.test_totals.failed += settled.test_counts.failed
    result.test_totals.skipped += settled.test_counts.skipped
    result.test_totals.deselected += settled.test_counts.deselected
    state[i].phase = _DONE

    if settled.is_drift:
        result.drift = True
        if is_gate:
            result.aborted = True
            return True
        return False

    summary.counts[settled.outcome.code] += 1
    result.run_outcomes.extend(settled.exit_outcomes.copy())
    result.ran_files += 1
    if (not is_gate) and settled.outcome == Outcome.CRASH:
        result.crash_files.append(
            _CrashFile(state[i].rel, settled.binary_path, List[String]())
        )
    pipeline.record_verdict(
        i, settled.outcome.is_failing(), _failing_count(result.run_outcomes)
    )
    if is_gate and settled.outcome.is_failing():
        result.aborted = True
        return True
    return False
