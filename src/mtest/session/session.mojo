"""Sequential orchestration: discover, build, execute, classify, exit.

`run_session` runs the discovered files in a fixed order — precompile steps,
then gates, then run files — building each to a binary and executing it under
the `exec` supervisor. It owns the run-report handshake and the verdict policy:
it decodes each child's captured stdout, resolves which report a truncated
capture may trust (`resolve_report`), runs the per-test classifier (`classify`),
reconciles a `--only` selection run against its `--skip-all` collection
universe, and maps every termination to an `Outcome` — emitting events to the
composed reporter and resolving the process exit code. Execution is sequential
by contract: no parallelism. Two retry mechanisms exist. The bounded stale-name
recover-once reprobes a file whose `--only` names vanished from the suite, and
the `--retries` budget runs up to `config.retries + 1` attempts on a
crash-class ending — applied to precompile steps, whole run files, and selected
subsets alike.

The session emits events and nothing else; the reporter formats, and pre-session
CLI usage errors belong to main. Only two failures propagate out of
`run_session`: a `discover:` usage error and an unknown selected test name, both
of which main maps to exit 4. Every other failure — an `exec:` machinery raise
or a spawn failure — is caught here and resolved to internal-error exit 3.

The session does not decide the exit code: it states the facts it observed and
`resolve_exit_code` in the model layer ranks them. The precedence, high to low:
an interrupt is 2; an internal error (spawn failure or machinery raise) is 3; a
report that drifted off the pinned grammar is also 3; a precompile failure is 1;
otherwise `exit_code_for` over the run outcomes decides 1, 5, or 0. A terminal
artifact that could not be delivered then escalates anything below 2 to 3. The
selection, probe, and gate paths route non-valid reports through the same
`resolve_report`/`classify` machinery as the default path, so a forged or
off-grammar report resolves identically either way.
"""
from std.io import FileDescriptor
from std.sys import num_logical_cores
from std.time import perf_counter_ns

from mtest.cache import BuildRegistry
from mtest.config import RunnerConfig
from mtest.discover import discover
from mtest.exec import ExecRuntime, interrupt_requested
from mtest.model import (
    Event,
    Outcome,
    Summary,
    TerminalFacts,
    TestCounts,
    exit_code_for,
    resolve_exit_code,
)
from mtest.report import ReportCoordinator
from mtest.select import NamedTarget, parse_operands, selection_active
from mtest.session.attempt import _run_one
from mtest.session.attribution_run import _run_crash_attribution
from mtest.session.file_result import _CrashFile, _failing_count
from mtest.session.pipeline import PipelineHalt, RunPipeline
from mtest.session.pool import _run_pool_batch, resolve_worker_plan
from mtest.session.pool_plan import partition_serial, stale_serials
from mtest.session.precompile import _run_precompile
from mtest.session.selection import _run_selection
from mtest.session.shard import partition


def _flush_console[
    C: ReportCoordinator
](mut reporter: C, console_fd: Int, closing: Bool):
    """Drain the coordinator's pending console bytes to the borrowed handle.

    The driver owns no console destination of its own: `main` resolves it and
    lends the descriptor, keeping close and teardown. A negative handle (a
    library caller that lent none, or a recording driver) or an empty drain
    writes nothing. The write is best-effort, exactly as the single terminal
    console flush was — a dead destination is not a new exit cause, so a failed
    incremental write is not distinguished here either.

    Args:
        reporter: The coordinator to drain. A recording coordinator drains
            empty, so this is a no-op for the session's own test drivers.
        console_fd: The borrowed console descriptor, or negative when none was
            lent.
        closing: Whether this is the terminal drain, which also emits the
            framed sections and the summary band.
    """
    if console_fd < 0:
        return
    var chunk = reporter.drain_console(closing)
    if chunk.byte_length() == 0:
        return
    print(chunk, end="", file=FileDescriptor(console_fd), flush=True)


def run_session[
    C: ReportCoordinator
](
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    mut reporter: C,
    console_fd: Int = -1,
) raises -> Int:
    """Orchestrate a whole run and return the resolved process exit code.

    Discovers the file set, emits `SessionStarted` and the excluded and
    stale-exclusion events, then runs the precompile steps, the gates, and the
    run files in that fixed order. Termination then proceeds in two ordered
    steps. First it seals the run accounting and finalizes each machine
    artifact — assembling, verify-writing, and atomically renaming the JUnit
    report, and collecting and reporting a finalization failure — with the
    interrupt linearization fixed at the moment the accounting is sealed. Only
    then does it resolve the final exit code and dispatch `SessionFinished`
    exactly once, carrying it. The session emits events only; it prints nothing.

    Parameters:
        C: The report coordinator this session drives, inferred from the
            argument. The session polls its stream health at each scheduling
            boundary and treats a latched write failure as a fatal abort, and
            synthesizes `[not-run]` rows and finalizes the JUnit report while
            sealing the accounting. A coordinator with no reporter behind a
            channel answers inertly, so the session never branches on what is
            composed. The annotation tail is rendered by `main` after this
            returns, from the same coordinator.

    Args:
        runtime: Exclusive owner of process-global exec and signal state.
        config: Every knob the run reads.
        root: The invocation root; built binaries and paths are relative to it.
        reporter: The coordinator the session fans every event to.
        console_fd: A borrowed console descriptor the session flushes rendered
            bytes to as the run progresses, then seals with a closing drain
            before returning. `main` lends the resolved destination and keeps
            close and teardown; a negative value (the default, and every
            recording driver) flushes nothing, leaving the buffer for the
            caller to read. The write is best-effort and carries no new exit
            cause, exactly as the single terminal flush did.

    Returns:
        The resolved exit code: 2 on an interrupt; 3 on an internal error, a
        report that drifted off the pinned grammar, a latched machine-stream
        failure such as a dead `--json` destination, or a failed JUnit
        finalization; 1 on a precompile failure; else `exit_code_for` over the
        run outcomes, which is 1, 5, or 0.

    Raises:
        Error: If discovery reports a `discover:` usage error, or selection
            names an unknown test. Main maps both to exit 4. Every other
            failure is caught and resolved to exit 3.
    """
    var started_ns = perf_counter_ns()

    # Discovery. A discover: usage error propagates to main (exit 4).
    var disc = discover(config, root)

    # Sharding partitions the discovered RUN files (never the gates): keep only
    # the subset this shard owns so every downstream count, casualty, run loop,
    # and the exit-code multiset see exactly this shard's work.
    var shard_label = String("")
    var sharded_out_count = 0
    if config.shard_n > 0:
        var before = len(disc.run_files)
        disc.run_files = partition(
            disc.run_files.copy(),
            config.shard_mode,
            config.shard_m,
            config.shard_n,
        )
        sharded_out_count = before - len(disc.run_files)
        shard_label = String(config.shard_m) + "/" + String(config.shard_n)

    # Resolve the worker count before announcing the run: `1` (the default)
    # stays the sequential path and never queries the descriptor cap; any other
    # value resolves the pool's capacity against the cores and the effective
    # cap, clamping loudly. A hard environment fault (a descriptor ceiling too
    # small for a single child) is folded as an internal error below, resolving
    # to exit 3 the same as any other machinery failure.
    # Selection (`-k` or a node id) runs through the sequential selection
    # sub-session, which the pool does not drive, so a worker request cannot be
    # honored there. Resolve to one worker under selection so the header reports
    # the truthful sequential mode instead of a parallelism the run never uses,
    # and `--serial` stays a consistent no-op (the selection run is already
    # one file at a time).
    var sel_active = selection_active(config.paths, config.keyword)
    var resolved_workers = 1
    var worker_clamp_note = String("")
    var worker_env_error = False
    if config.workers != 1 and not sel_active:
        try:
            var wp = resolve_worker_plan(config)
            resolved_workers = wp.resolved
            if wp.clamped:
                worker_clamp_note = wp.limiting_note()
        except:
            worker_env_error = True
    var cores = num_logical_cores()

    var selected = len(disc.gate_files) + len(disc.run_files)
    var excluded = len(disc.excluded)
    reporter.handle(
        Event.session_started(
            root,
            config.mojo_path,
            selected,
            excluded,
            shard_label=shard_label,
            sharded_out_count=sharded_out_count,
            workers=resolved_workers,
        )
    )
    if worker_clamp_note != "":
        reporter.handle(Event.warning("worker-clamp", worker_clamp_note))

    var summary = Summary.zeros()

    # Loud excluded lines and stale-exclusion warnings.
    for e in disc.excluded:
        reporter.handle(
            Event.file_finished(
                e.path,
                Outcome.EXCLUDED,
                0.0,
                List[String](),
                0.0,
                List[UInt8](),
                List[UInt8](),
                exclusion_pattern=e.pattern,
            )
        )
        summary.counts[Outcome.EXCLUDED.code] += 1
    for pat in disc.stale_excludes:
        reporter.handle(Event.warning("stale-exclusion", pat))
    # A `--serial` glob matching no discovered run file is stale for the same
    # reason a `--exclude` glob is: the pattern names nothing, so the caller
    # almost certainly mistyped it. This is about the glob, not the worker count,
    # so it fires on every run — even the sequential one, where serial pinning
    # has no execution effect.
    for pat in stale_serials(disc.run_files, config.serial_globs):
        reporter.handle(Event.warning("stale-serial", pat))

    var run_outcomes = List[Outcome]()
    var test_totals = TestCounts.zeros()
    var ran_files = 0
    var interrupted = False
    # A descriptor-ceiling fault while resolving the worker plan is a machinery
    # fault: resolve it as an internal error (exit 3), the same as any other.
    var internal_error = worker_env_error
    var precompile_failed = False
    var drift = False
    # A latched machine-stream write failure (a dead `--json -` pipe, a full or
    # unwritable destination) is a FATAL ABORT: the run's product is no longer
    # deliverable, so the session stops scheduling and resolves exit 3. It is
    # polled at each scheduling boundary (like `interrupt_requested`); the poll
    # is a comptime no-op when no stream reporter is composed.
    var stream_dead = reporter.stream_failed()
    # The registry the selection/collect probe machinery records builds and
    # qualifying listings into. The plain run loop keeps no entry here — it never
    # probes — so the attribution post-pass falls back to a fresh probe for its
    # files. Diagnostics read it; nothing else does.
    var reg = BuildRegistry()
    # The CRASH files, in discovery order, for the bounded attribution post-pass.
    # Collected as verdicts land; feeds no count, no multiset, no exit code.
    var crash_files = List[_CrashFile]()

    # Precompile steps, in listed order. Each success widens the include set.
    var includes = config.include_paths.copy()
    # Every selected file (gates first, then the run set) depends on the
    # precompiled packages, so a precompile failure makes all of them casualties
    # — named individually in the banner (§8.3), not merely counted.
    var casualty_files = disc.gate_files.copy()
    for f in disc.run_files:
        casualty_files.append(String(f))
    for pc in config.precompiles:
        if interrupt_requested():
            interrupted = True
            break
        if reporter.stream_failed():
            stream_dead = True
            break
        try:
            var pr = _run_precompile(
                runtime, config, root, pc.src, pc.out, includes
            )
            # The step's own attempt record first, in order: each retried
            # attempt's TRY line, its residual warning, and a success-after-retry
            # warning — the session-level signal that stands in for the FLAKY
            # verdict a file would get.
            for ev in pr.events:
                reporter.handle(ev)
            if pr.interrupted:
                interrupted = True
                break
            if pr.internal_error:
                reporter.handle(
                    Event.internal_error("precompile", pr.program, pr.errno)
                )
                internal_error = True
                break
            if not pr.ok:
                precompile_failed = True
                reporter.handle(
                    Event.precompile_failed(
                        pc.src,
                        pr.compiler_output,
                        len(casualty_files),
                        casualties=casualty_files,
                        ending_known=pr.ending_known,
                        term_kind=pr.term.kind,
                        term_value=pr.term.value,
                        escalated=pr.term.escalated,
                        timeout_seconds=pr.timeout_seconds,
                        attempts_used=pr.attempts_used,
                    )
                )
                break
            includes.append(pr.out_dir)
        except:
            reporter.handle(
                Event.internal_error("precompile", config.mojo_path, 0)
            )
            internal_error = True
            break

    var gate_abort = False
    var proceed = not (
        interrupted or internal_error or precompile_failed or stream_dead
    )

    # Gates first: a failing gate aborts the whole session immediately. The stop
    # policy runs through the same `RunPipeline` kernel the selection and plain
    # run paths use — a gate is always exit-first, so a failing gate latches
    # `LIMIT_REACHED` and aborts scheduling, exactly as before.
    var gate_pipeline = RunPipeline(
        len(disc.gate_files), config.retries, True, 0
    )
    # The parallel pool runs the gates as their own batch, aborting the run on
    # the first failing or drifting gate exactly as the sequential loop does.
    if proceed and resolved_workers > 1:
        var gb = _run_pool_batch(
            runtime,
            config,
            root,
            disc.gate_files,
            includes,
            reporter,
            summary,
            resolved_workers,
            cores,
            True,
            console_fd,
        )
        run_outcomes.extend(gb.run_outcomes.copy())
        test_totals.passed += gb.test_totals.passed
        test_totals.failed += gb.test_totals.failed
        test_totals.skipped += gb.test_totals.skipped
        test_totals.deselected += gb.test_totals.deselected
        ran_files += gb.ran_files
        if gb.interrupted:
            interrupted = True
        if gb.internal_error:
            internal_error = True
        if gb.drift:
            drift = True
        if gb.aborted:
            gate_abort = True
    if proceed and resolved_workers <= 1:
        for gi in range(len(disc.gate_files)):
            if interrupt_requested():
                interrupted = True
                break
            if reporter.stream_failed():
                stream_dead = True
                break
            reporter.handle(Event.file_started(disc.gate_files[gi]))
            try:
                var fr = _run_one(
                    runtime, config, root, disc.gate_files[gi], includes
                )
                if fr.interrupted:
                    interrupted = True
                    break
                if fr.internal_error:
                    reporter.handle(fr.event)
                    internal_error = True
                    break
                for pe in fr.pre_events:
                    reporter.handle(pe)
                reporter.handle(fr.event)
                test_totals.passed += fr.test_counts.passed
                test_totals.failed += fr.test_counts.failed
                test_totals.skipped += fr.test_counts.skipped
                if fr.is_drift:
                    # A drifting gate is at least as serious as a failing one: a
                    # gate exists to stop the run early, so a gate that drifts
                    # aborts scheduling the same way, fanning the remaining files
                    # out to NOT_RUN. Drift keeps exit-3 precedence over the
                    # exit-1 a failing gate would resolve to.
                    drift = True
                    gate_abort = True
                    break
                summary.counts[fr.outcome.code] += 1
                run_outcomes.extend(fr.exit_outcomes.copy())
                ran_files += 1
                gate_pipeline.record_verdict(
                    gi, fr.outcome.is_failing(), _failing_count(run_outcomes)
                )
                if gate_pipeline.halt() != PipelineHalt.RUNNING:
                    gate_abort = True
                    break
            except:
                reporter.handle(
                    Event.internal_error("build", config.mojo_path, 0)
                )
                internal_error = True
                break

    var proceed_runs = not (
        interrupted
        or internal_error
        or precompile_failed
        or gate_abort
        or stream_dead
    )

    # SELECTION is active when any operand is a node id or `-k` is present.
    # `parse_operands` below re-derives the same malformed-node-id shape check
    # (`sep_count > 1`) that `discover`'s `_classify` already applies to EVERY
    # operand in `config.paths` UNCONDITIONALLY at the very top of this
    # function (discover.mojo's Stage 2) — before precompiles, gates, or any
    # `proceed_runs`-gated step runs. So a malformed node id always raises its
    # exit-4 usage error before a failing gate/precompile could ever be
    # reached, and a failing gate/precompile can never mask it: discover's
    # check dominates every time. `parse_operands` here exists to build the
    # `OperandParse` selection intent (plain operands vs. named targets), not
    # to gate malformed syntax a second time — see
    # `test_malformed_node_id_raises_even_when_a_gate_fails` in
    # tests/integration/test_session_selection.mojo for the pinned regression.
    # `sel_active` is resolved once up top (it also forces one worker).

    # Run files. Under selection, the run set is probed then run through the
    # selection sub-session; otherwise the plain build-then-run loop applies.
    if proceed_runs and sel_active:
        var plan = parse_operands(config.paths)
        var sel = _run_selection(
            runtime, config, root, disc, includes, plan, reporter, summary, reg
        )
        run_outcomes.extend(sel.run_outcomes.copy())
        test_totals.passed += sel.test_totals.passed
        test_totals.failed += sel.test_totals.failed
        test_totals.skipped += sel.test_totals.skipped
        test_totals.deselected += sel.test_totals.deselected
        ran_files += sel.ran_files
        if sel.interrupted:
            interrupted = True
        if sel.internal_error:
            internal_error = True
        if sel.drift:
            drift = True
        crash_files.extend(sel.crash_files.copy())
    elif proceed_runs and resolved_workers > 1:
        # The parallel pool drives the run files at capacity `resolved_workers`,
        # honoring `-x`/`--maxfail` (in-flight files finish, the rest NOT-RUN)
        # and folding an interrupt back for exit 2. Selection is not pooled
        # here, so this branch is the non-selection run set only.
        #
        # Serial pinning splits the dispatched run files: files matching a
        # `--serial` glob run OUTSIDE the pool, one whole pipeline at a time,
        # AFTER the parallel batch (serial-last). The partition happens here, on
        # the files actually dispatched (post-shard, post-selection), so nothing
        # discover counts or shards is disturbed; each sub-list keeps the
        # dispatched order.
        var split = partition_serial(disc.run_files, config.serial_globs)
        var rb = _run_pool_batch(
            runtime,
            config,
            root,
            split.parallel,
            includes,
            reporter,
            summary,
            resolved_workers,
            cores,
            False,
            console_fd,
        )
        run_outcomes.extend(rb.run_outcomes.copy())
        test_totals.passed += rb.test_totals.passed
        test_totals.failed += rb.test_totals.failed
        test_totals.skipped += rb.test_totals.skipped
        test_totals.deselected += rb.test_totals.deselected
        ran_files += rb.ran_files
        if rb.interrupted:
            interrupted = True
        if rb.internal_error:
            internal_error = True
        if rb.drift:
            drift = True
        crash_files.extend(rb.crash_files.copy())

        # The serial pass runs at capacity one AFTER the parallel batch drains.
        # Capacity one is the whole-pipeline drain: a single Supervisor slot
        # cannot admit the next file's build until the current file's verdict
        # frees it, and a file holds its slot through build → run → any retries,
        # so no two serial files (nor a serial and a parallel file) ever overlap.
        # `-x`/`--maxfail` and interrupts span BOTH batches. If the parallel
        # batch already halted on its limit, aborted on an interrupt, or hit a
        # machinery fault, the serial files land NOT-RUN rather than starting
        # fresh work (`stop_serial`). Otherwise the serial pass CONTINUES the
        # run-wide `--maxfail` tally: it is seeded with the parallel batch's
        # failing count so the ceiling counts failures across both batches
        # instead of resetting to zero at the boundary.
        var stop_serial = rb.interrupted or rb.internal_error or rb.halted
        if len(split.serial) > 0 and not stop_serial:
            var sb = _run_pool_batch(
                runtime,
                config,
                root,
                split.serial,
                includes,
                reporter,
                summary,
                1,
                cores,
                False,
                console_fd,
                serial=True,
                initial_failing=_failing_count(rb.run_outcomes),
            )
            run_outcomes.extend(sb.run_outcomes.copy())
            test_totals.passed += sb.test_totals.passed
            test_totals.failed += sb.test_totals.failed
            test_totals.skipped += sb.test_totals.skipped
            test_totals.deselected += sb.test_totals.deselected
            ran_files += sb.ran_files
            if sb.interrupted:
                interrupted = True
            if sb.internal_error:
                internal_error = True
            if sb.drift:
                drift = True
            crash_files.extend(sb.crash_files.copy())
    elif proceed_runs:
        # The plain run path settles each file build-then-run through `_run_one`
        # and routes its `-x`/`--maxfail` stop policy through the same
        # `RunPipeline` kernel the selection and gate paths use, rather than
        # re-deciding the limits inline.
        var run_pipeline = RunPipeline(
            len(disc.run_files),
            config.retries,
            config.exitfirst,
            config.maxfail,
        )
        for ri in range(len(disc.run_files)):
            if interrupt_requested():
                interrupted = True
                break
            if reporter.stream_failed():
                stream_dead = True
                break
            reporter.handle(Event.file_started(disc.run_files[ri]))
            try:
                var fr = _run_one(
                    runtime, config, root, disc.run_files[ri], includes
                )
                if fr.interrupted:
                    interrupted = True
                    break
                if fr.internal_error:
                    reporter.handle(fr.event)
                    internal_error = True
                    break
                for pe in fr.pre_events:
                    reporter.handle(pe)
                reporter.handle(fr.event)
                # Flush this file's rendered verdict as soon as it lands. The
                # plain-run branch runs only when selection is inactive, so no
                # raise can follow before the run returns; a leaked partial
                # flush ahead of a usage-error raise is therefore impossible on
                # this path.
                _flush_console(reporter, console_fd, closing=False)
                test_totals.passed += fr.test_counts.passed
                test_totals.failed += fr.test_counts.failed
                test_totals.skipped += fr.test_counts.skipped
                if fr.is_drift:
                    drift = True
                    continue
                summary.counts[fr.outcome.code] += 1
                run_outcomes.extend(fr.exit_outcomes.copy())
                ran_files += 1
                if fr.outcome == Outcome.CRASH:
                    # The plain run path runs no selection, so every test name is
                    # an attribution candidate: an empty selected set.
                    crash_files.append(
                        _CrashFile(
                            disc.run_files[ri], fr.binary_path, List[String]()
                        )
                    )
                run_pipeline.record_verdict(
                    ri, fr.outcome.is_failing(), _failing_count(run_outcomes)
                )
                if run_pipeline.halt() != PipelineHalt.RUNNING:
                    break
            except:
                reporter.handle(
                    Event.internal_error("build", config.mojo_path, 0)
                )
                internal_error = True
                break

    # Flush every header rendered so far that no incremental flush above
    # already emitted: the precompile banner, the gate verdicts, and the
    # selection sub-session's per-file lines. Reached only once the run pass has
    # returned normally, so it never fires ahead of a selection usage-error
    # raise — matching the old terminal flush, which `main` performed only on a
    # normal return.
    _flush_console(reporter, console_fd, closing=False)

    # Every selected file that did not produce a tallied verdict is NOT_RUN — a
    # gate casualty, an -x/--maxfail/gate-abort/interrupt skip, a precompile
    # casualty, or a drift file (which forces exit 3 and is accounted here,
    # never tallied).
    var not_run = selected - ran_files
    summary.counts[Outcome.NOT_RUN.code] += not_run

    # A stream failure that latched during the run loop (not caught at a
    # scheduling boundary because it tripped on the final file's own events) is
    # picked up here so a dead pipe on the last file still resolves to the fatal
    # exit 3 rather than the run's own code.
    if reporter.stream_failed():
        stream_dead = True

    # The pure exit-code outcome over the run outcomes at TEST granularity
    # (1/5/0), computed BEFORE the terminal protocol so `exit_code_for` stays the
    # sole authority for that tier and is never touched by the resolution around
    # it.
    var outcome_code = exit_code_for(run_outcomes)

    # The bounded crash-attribution post-pass. It runs HERE — after every file
    # has its verdict and the summary is tallied — precisely so it CANNOT
    # influence either: the only thing left for it to do is emit
    # `CrashAttribution` events. A crashed file's verdict and this process's exit
    # code are byte-identical whether the pass names a culprit, fails to
    # reproduce the crash, or is skipped entirely. It is skipped under an
    # interrupt (exit 2 must not wait on diagnostics) and under a stream death (a
    # fatal abort must not spend time on diagnostics whose consumer is gone). A
    # raise out of it is caught and dropped rather than allowed to disturb the
    # settled accounting.
    if not interrupted and not stream_dead:
        try:
            _run_crash_attribution(
                runtime, config, root, crash_files, reg, reporter
            )
        except:
            pass

    # --- PHASE 1: finalize. Seal the accounting and publish each artifact. -----
    #
    # INTERRUPT LINEARIZATION is fixed HERE, at Phase-1 entry: a run-time
    # interrupt (recorded during scheduling) OR one that arrived during the
    # crash-attribution pass resolves toward exit 2. A finalization-PHASE
    # interrupt (one delivered after this point) does NOT change the resolved
    # code — a Ctrl-C during finalize truncates nothing already accounted, and
    # in-flight finalize steps complete.
    var interrupt_latched = interrupted or interrupt_requested()

    # A latched machine-stream write failure that tripped on the final file's own
    # events (missed at the scheduling boundaries) is the JSON stream's "finalize"
    # tier — picked up here so a dead pipe on the last file still escalates.
    if reporter.stream_failed():
        stream_dead = True

    # Synthesize a `[not-run]` row into the JUnit report for every selected file
    # that never produced a verdict (interrupt/gate-abort/--maxfail casualties),
    # then finalize the report: assemble in node-id order, verify-write the
    # unique temp, atomic-rename onto PATH. The prior report survives every
    # failure. A latched junit SPOOL failure did NOT abort the run mid-flight (the
    # deliberate asymmetry vs the stream's fatal abort); it surfaces NOW.
    reporter.note_not_run(casualty_files)
    var junit_fin = reporter.finalize_junit()
    var finalize_failed = junit_fin.failed
    if finalize_failed:
        # Loudly report the finalization failure — the console shows it and the
        # JSON stream carries it, both BEFORE the terminal record.
        reporter.handle(Event.warning("junit-finalize", junit_fin.detail))

    # --- PHASE 2: resolve + dispatch. Resolve once, dispatch SessionFinished ----
    # exactly once carrying that code. `exit_code_for` is untouched: the two-phase
    # protocol resolves AROUND it. The session states the FACTS it observed and
    # the model ranks them, so the precedence lives in one place for every caller
    # that reaches an exit code. A stream death or a failed JUnit finalization is
    # the same fact to the resolver: a terminal artifact was not delivered.
    var code = resolve_exit_code(
        TerminalFacts(
            interrupted=interrupt_latched,
            internal_error=internal_error,
            drift=drift,
            precompile_failed=precompile_failed,
            outcome_code=outcome_code,
            delivery_failed=stream_dead or finalize_failed,
        )
    )

    var wall = Float64(perf_counter_ns() - started_ns) / 1.0e9
    # A file that passed only after a crash-class retry tallied under FLAKY; that
    # run-wide count rides the SessionFinished summary line.
    var flaky_files = summary.count_of(Outcome.FLAKY)
    reporter.handle(
        Event.session_finished(
            summary^,
            wall,
            code,
            test_counts=test_totals,
            flaky_files=flaky_files,
        )
    )

    # Seal the console: emit any remaining header, then the framed sections and
    # the summary band, in `output()` order. This is the last console write the
    # driver makes; `main` renders the fence-restoration epilogue and the
    # annotation tail after this returns, so both still land AFTER the final
    # console bytes exactly as before.
    _flush_console(reporter, console_fd, closing=True)

    # The dispatch just above is ITSELF a stream write, and can latch a NEW
    # failure during that very write (a `--json -` consumer that closes its
    # read end right after `file_finished`; a file destination that hits
    # ENOSPC exactly on the terminal line) — a failure `stream_dead` above
    # could not have seen, because it did not exist yet. Re-poll the SAME
    # latch Phase 1 already polls; if it is now set and was not already
    # folded into `stream_dead`, re-resolve with the pure function again,
    # passing the SAME interrupt/error/drift/precompile/outcome facts (a
    # finalization-phase interrupt still must not move the code — only the
    # delivery outcome does) and `delivery_failed=True`. The same
    # precedence applies: a resolved 2 still stands, a resolved 3 stays 3, a
    # resolved 0/1/5 escalates to 3. The already-attempted terminal record
    # (torn or absent on the now-dead stream) is the consumer's truncation
    # signal; the EXIT CODE is the out-of-band signal and must not lie about
    # it by returning the code resolved before the stream died.
    if not stream_dead and reporter.stream_failed():
        code = resolve_exit_code(
            TerminalFacts(
                interrupted=interrupt_latched,
                internal_error=internal_error,
                drift=drift,
                precompile_failed=precompile_failed,
                outcome_code=outcome_code,
                delivery_failed=True,
            )
        )
    return code


def run_session[
    C: ReportCoordinator
](config: RunnerConfig, root: String, mut reporter: C) raises -> Int:
    """Run a session with a locally owned runtime, for direct library callers.

    The CLI uses the overload that accepts an already-open runtime, so a runtime
    open failure maps to internal exit 3 before session error handling. This
    convenience overload preserves the library surface while still passing
    exclusive mutable ownership to every supervised child.

    Parameters:
        C: The report coordinator this session drives, inferred from the
            argument.

    Args:
        config: Every knob the run reads.
        root: The invocation root; built binaries and paths are relative to it.
        reporter: The coordinator the session fans every event to.

    Returns:
        The resolved exit code, as the primary overload defines it.

    Raises:
        Error: If the runtime cannot be opened or closed, or if the primary
            overload raises. A close failure during error handling is appended
            to the original message.
    """
    var runtime = ExecRuntime()
    try:
        runtime.open()
        var code = run_session(runtime, config, root, reporter)
        runtime.close()
        return code
    except error:
        var primary = String(error)
        try:
            runtime.close()
        except cleanup_error:
            raise Error(primary + "; " + String(cleanup_error))
        raise Error(primary)
