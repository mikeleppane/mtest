"""Run orchestration: discover, build, execute, classify, exit.

`run_session` runs the discovered files in a fixed order (precompile steps, then
gates, then run files), building each to a binary and executing it under the
`exec` supervisor. It owns the run-report handshake and the verdict policy: it
decodes each child's captured stdout, resolves which report a truncated capture
may trust (`resolve_report`), runs the per-test classifier (`classify`),
reconciles a `--only` selection run against its `--skip-all` collection
universe, and maps every termination to an `Outcome`, emitting events to the
composed reporter and resolving the process exit code.

The resolved worker count picks the driver. One worker keeps the sequential loop
in this module; more than one hands the gate batch and the run files to the
parallel pool, which enforces the same admission, retry, and stop policy through
the same `RunPipeline` kernel. Selection (`-k` or a node id) always resolves to
one worker and runs through the sequential selection sub-session. Two retry
mechanisms exist. The bounded stale-name recover-once reprobes a file whose
`--only` names vanished from the suite. Crash-class file runs spend one initial
attempt plus their effective per-file retries, while precompile steps retain the
resolved global retry budget.

The session emits events and nothing else; the reporter formats, and pre-session
CLI usage errors belong to main. Only two failures propagate out of
`run_session`: a `discover:` usage error and an unknown selected test name, both
of which main maps to exit 4. Every other failure, an `exec:` machinery raise or
a spawn failure, is caught here and resolved to internal-error exit 3.

The session does not decide the exit code: it states the facts it observed and
`resolve_exit_code` in the model layer ranks them. The precedence, high to low:
an interrupt is 2; an internal error (spawn failure or machinery raise) is 3; a
report that drifted off the pinned grammar is also 3; a precompile failure is 1;
otherwise `exit_code_for` over the run outcomes decides 1, 5, or 0, and under
`--fail-on-flaky` a 0 with at least one FLAKY file becomes 1. A terminal
artifact that could not be delivered then escalates anything below 2 to 3. The
selection, probe, and gate paths route non-valid reports through the same
`resolve_report`/`classify` machinery as the default path, so a forged or
off-grammar report resolves identically either way.
"""
from std.sys import num_logical_cores
from std.time import perf_counter_ns

from mtest.cache import BuildRegistry
from mtest.config import ResolvedConfig, RunnerConfig, StateDelta
from mtest.discover import discover
from mtest.exec import ExecRuntime, interrupt_requested
from mtest.model import (
    Event,
    NotRunFacts,
    NotRunRecord,
    Outcome,
    Summary,
    TerminalFacts,
    TerminationKind,
    classify_not_run,
    exit_code_for,
    resolve_exit_code,
)
from mtest.platform import (
    direct_write_failed,
    process_id,
    write_all_bytes_fd_status,
)
from mtest.report import ReportCoordinator, ReportFinalizeContext
from mtest.select import NamedTarget, parse_operands, selection_active
from mtest.select.shuffle import shuffle_strings
from mtest.session.attempt import _run_one
from mtest.session.attribution_run import _run_crash_attribution
from mtest.session.effective_settings import (
    _compat_resolved_config,
    effective_file_settings,
)
from mtest.session.file_result import (
    CacheAdmissions,
    RunTally,
    _failing_count,
    settle_file,
)
from mtest.select.failure_selection import (
    missing_file_identifiers,
    order_failed_first,
    remembered_file_matches,
)
from mtest.session.pipeline import PipelineHalt, RunPipeline
from mtest.session.pool import (
    PoolBatchResult,
    _run_pool_batch,
    resolve_worker_plan,
)
from mtest.session.pool_plan import partition_effective_serial, stale_serials
from mtest.session.precompile import run_precompile_step
from mtest.session.selection import _run_selection
from mtest.session.shard import partition
from mtest.session.store import (
    CacheContext,
    collect_env_base,
    finalize_includes,
)


def _flush_console[
    C: ReportCoordinator
](mut reporter: C, console_fd: Int, closing: Bool) -> Bool:
    """Drain the coordinator's pending console bytes to the borrowed handle.

    The driver owns no console destination of its own: `main` resolves it and
    lends the descriptor, keeping close and teardown. A negative handle (a
    library caller that lent none, or a recording driver) or an empty drain
    writes nothing.

    The console report is the run's PRIMARY output, so a destination that
    cannot take it is a delivery failure the session latches and the model
    ranks — the same fact a dead `--json` destination presents. A run that
    printed nothing has not reported, and its own verdict is no longer the
    honest answer. A departed consumer is the carve-out and is not latched:
    `mtest tests | head -1` still exits by its outcomes (§9).

    A raw `write(2)` rather than a `FileDescriptor`: constructing one takes
    ownership of a descriptor the session only borrowed, and its teardown
    closes it — which faults outright when the borrowed descriptor is already
    closed, killing a run that had otherwise finished.

    Args:
        reporter: The coordinator to drain. A recording coordinator drains
            empty, so this is a no-op for the session's own test drivers.
        console_fd: The borrowed console descriptor, or negative when none was
            lent.
        closing: Whether this is the terminal drain, which also emits the
            framed sections and the summary band.

    Returns:
        Whether this drain failed to deliver its bytes for a reason other than
        a departed consumer. False when nothing was written.
    """
    if console_fd < 0:
        return False
    var chunk = reporter.drain_console(closing)
    if chunk.byte_length() == 0:
        return False
    return direct_write_failed(
        write_all_bytes_fd_status(console_fd, chunk.as_bytes())
    )


def _warn_cache_off[
    C: ReportCoordinator
](mut ctx: CacheContext, config: RunnerConfig, mut reporter: C):
    """Say once, and only once, that this run is building without its cache.

    The warning is latched on the context rather than on a local, so the two
    places that ask — right after the key prefix is finalized, and again once the
    run has settled — cannot both fire. The first covers everything known before
    any file is built (an unrecognized build argument, an unreadable include
    root, a compiler that will not answer `--version`); the second covers a
    context that only went off mid-run, when a store proved unusable or a source
    would not read.

    `--no-cache` says nothing: the user turned the cache off, and reporting back
    that it is off is noise. That is why `CacheContext.disabled` presets
    `warned`, and why this checks the flag as well — the two agree, and either
    one alone would be enough.

    Parameters:
        C: The report coordinator the warning is fanned to.

    Args:
        ctx: The session's cache state; `warned` is set when the warning fires.
        config: The run's config, read for `no_cache`.
        reporter: The coordinator the warning is handed to.
    """
    if ctx.enabled or ctx.warned or config.no_cache:
        return
    reporter.handle(Event.warning("cache-off", ctx.disable_reason))
    ctx.warned = True


def _absorb_batch(
    mut tally: RunTally,
    mut admissions: CacheAdmissions,
    batch: PoolBatchResult,
):
    """Fold one pooled batch's whole result into the session.

    The batch's cache admissions land on the run's one accumulator here rather
    than being counted inside the batch: the gate, parallel, and serial batches
    each account for themselves, and every fold happens long before the terminal
    artifacts read the totals.

    Args:
        tally: The session accumulator every driver's work lands in.
        admissions: The run's admission accumulator, which the batch's charges
            are added to.
        batch: The finished batch. Copied, not consumed.
    """
    tally.merge(batch.tally)
    admissions.merge(batch.admissions)


def _is_gate_file(gate_files: List[String], path: String) -> Bool:
    """Whether `path` is one of the run's gate files, by exact match.

    Args:
        gate_files: The run's gate paths. Not mutated.
        path: The path to test.

    Returns:
        True iff `path` equals one entry of `gate_files`.
    """
    for gate in gate_files:
        if gate == path:
            return True
    return False


@fieldwise_init
struct SessionResult(Copyable, Movable):
    """The resolved session code and its live last-run verdict delta."""

    var code: Int
    """The resolved exit code."""

    var state_delta: StateDelta
    """The fresh observations folded from emitted verdict events."""


def run_session[
    C: ReportCoordinator
](
    mut runtime: ExecRuntime,
    resolved: ResolvedConfig,
    root: String,
    mut reporter: C,
    console_fd: Int = -1,
) raises -> Int:
    """Orchestrate a whole run and return the resolved process exit code.

    Discovers the file set, emits `SessionStarted` and the excluded and
    stale-exclusion events, then runs the precompile steps, the gates, and the
    run files in that fixed order. Termination then proceeds in two ordered
    steps. First it seals the run accounting and finalizes each machine
    artifact: assembling, verify-writing, and atomically renaming the JUnit
    report, then collecting and reporting a finalization failure. The interrupt
    linearization is fixed at the moment the accounting is sealed. Only then does
    it resolve the final exit code and dispatch `SessionFinished` exactly once,
    carrying it. The session emits events only; it prints nothing.

    Parameters:
        C: The report coordinator this session drives, inferred from the
            argument. The session polls its stream health at each scheduling
            boundary and treats a latched write failure as a fatal abort. While
            sealing the accounting it synthesizes `[not-run]` rows and finalizes
            the JUnit report through the same coordinator. A coordinator with no
            reporter behind a channel answers inertly, so the session never
            branches on what is composed. `main` renders the annotation tail
            from that coordinator after this returns.

    Args:
        runtime: Exclusive owner of process-global exec and signal state.
        resolved: Layered global configuration and per-file override tables.
        root: The invocation root; built binaries and paths are relative to it.
        reporter: The coordinator the session fans every event to.
        console_fd: A borrowed console descriptor the session flushes rendered
            bytes to as the run progresses, then seals with a closing drain
            before returning. `main` lends the resolved destination and keeps
            close and teardown; a negative value (the default, and every
            recording driver) flushes nothing and leaves the buffer for the
            caller to read. The write is best-effort and carries no new exit
            cause.

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
    var config = resolved.config.copy()
    var started_ns = perf_counter_ns()

    # Discovery. A discover: usage error propagates to main (exit 4).
    var disc = discover(config, root)
    reporter.configure_state_gates(disc.gate_files)

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

    # This shard's run files in discovery's sorted order, captured before any
    # execution-order rewrite below (`--failed-first`, `--shuffle`). Every
    # surface that REPORTS the run set rather than driving it reads this one, so
    # a listing stays node-id sorted no matter what order the files execute in.
    var reportable_run_files = disc.run_files.copy()

    # Randomized order applies AFTER the shard partition (shard membership is a
    # cross-machine contract over the sorted list) and only to run files: gates
    # keep their listed order. The seed resolves here so the header can always
    # print it; an unseeded --shuffle mixes the clock with the pid, which
    # separates two shards launched in the same tick on one host. Two hosts at
    # equal uptime handing out equal pids can still collide, so `--seed` is the
    # only way to guarantee distinct or identical orders across machines.
    var shuffle_seed = 0
    if config.shuffle:
        shuffle_seed = config.shuffle_seed
        if shuffle_seed < 0:
            shuffle_seed = Int(
                (perf_counter_ns() ^ UInt(process_id() << 20))
                & 0x7FFF_FFFF_FFFF_FFFF
            )
        shuffle_strings(disc.run_files, UInt64(shuffle_seed))

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
    if config.last_failed:
        sel_active = True
    var state_files = disc.gate_files.copy()
    state_files.extend(reportable_run_files.copy())
    var ff_has_match = (
        config.failed_first
        and resolved.state
        and remembered_file_matches(state_files, resolved.last_run_state)
    )
    if config.failed_first and ff_has_match and sel_active:
        var ordered = order_failed_first(
            disc.gate_files,
            disc.run_files,
            [],
            resolved.last_run_state,
        )
        disc.run_files = ordered.parallel.copy()
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
            config_file=resolved.config_file,
            shuffle=config.shuffle,
            shuffle_seed=shuffle_seed,
        )
    )
    for warning in resolved.state_warnings:
        reporter.handle(Event.warning("state-malformed-line", warning))
    # `--cache-clear` deleted the last-run state before this session started, so
    # a reselection flag that survived the same command line has nothing left to
    # select from. Said here rather than from main because this is where a
    # reporter exists, and gated on the plumbed flag rather than on the config
    # so an ordinary `--lf` run's event stream is unchanged.
    if resolved.state_cleared and (config.last_failed or config.failed_first):
        reporter.handle(
            Event.warning(
                "cache-clear",
                "last-run state was just cleared; running the full selection",
            )
        )
    if config.last_failed:
        if not resolved.state:
            reporter.handle(
                Event.warning(
                    "lf-empty",
                    (
                        "lf: state disabled by mtest.toml — running the full"
                        " selection"
                    ),
                )
            )
        elif len(resolved.last_run_state.records) == 0:
            reporter.handle(
                Event.warning(
                    "lf-empty",
                    (
                        "lf: no previously-failing tests match this"
                        " selection — running the full selection"
                    ),
                )
            )
    if config.failed_first:
        if not resolved.state:
            reporter.handle(
                Event.warning(
                    "lf-empty",
                    (
                        "lf: state disabled by mtest.toml — running the full"
                        " selection"
                    ),
                )
            )
        else:
            for identifier in missing_file_identifiers(
                state_files, resolved.last_run_state
            ):
                reporter.handle(
                    Event.warning(
                        "lf-stale",
                        (
                            "lf: previously-failing "
                            + identifier
                            + " no longer exists — dropped"
                        ),
                    )
                )
            if not ff_has_match:
                reporter.handle(
                    Event.warning(
                        "lf-empty",
                        (
                            "lf: no previously-failing tests match this"
                            " selection — running the full selection"
                        ),
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
    # A symlink the walk refused is a selection the user believes is running.
    # A symlinked directory is not descended (cycle safety) and a dangling
    # `test_*.mojo` link cannot be built; either way the set actually run is
    # smaller than the tree suggests, so say so rather than exit 0 in silence.
    for link in disc.skipped_links:
        reporter.handle(Event.warning("skipped-symlink", link))
    # The same honesty for a non-symlink shape: a directory, FIFO, socket, or
    # device sitting at a test file's name. The set actually run is smaller
    # than the tree suggests, so say so rather than exit 0 quietly.
    for entry in disc.skipped_nonregular:
        reporter.handle(Event.warning("skipped-nonregular", entry))
    # And once more for a file that is perfectly runnable and simply cannot be
    # named: `::` is the node-id separator, so a test under such a path has no
    # operand, no node id, and no last-run entry. Running it would put a result
    # in the report that nothing could ever point back at.
    for entry in disc.skipped_unaddressable:
        reporter.handle(Event.warning("skipped-unaddressable", entry))
    # A `--serial` glob matching no discovered run file is stale for the same
    # reason a `--exclude` glob is: the pattern names nothing, so the caller
    # almost certainly mistyped it. This is about the glob, not the worker count,
    # so it fires on every run — even the sequential one, where serial pinning
    # has no execution effect.
    for pat in stale_serials(reportable_run_files, config.serial_globs):
        reporter.handle(Event.warning("stale-serial", pat))

    # Everything the run accumulates as its files settle, wherever they ran:
    # the gate loop and the plain run loop settle straight into it, and the
    # selection sub-session and each pooled batch fold theirs back into it.
    var tally = RunTally.zeros()
    # The run's build-cache accounting, charged by every driver and read once
    # by both terminal artifacts after the last file has settled.
    var admissions = CacheAdmissions.zeros()
    # The console report is the run's primary output, so a destination
    # that would not take it is a delivery failure the model ranks —
    # latched across every drain, both drivers, and never cleared.
    # A descriptor-ceiling fault while resolving the worker plan is a machinery
    # fault: resolve it as an internal error (exit 3), the same as any other.
    tally.internal_error = worker_env_error
    var precompile_failed = False
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

    # The build cache's session state, established BEFORE the first child that
    # could build anything. `--no-cache` is answered here and nowhere later:
    # every store operation from `store_build_target` onward creates
    # `.mtest-cache/` and its ownership marker as a side effect, so a gate placed
    # any further down would still leave behind the directory the user asked
    # this run not to touch.
    var ctx: CacheContext
    if config.no_cache:
        ctx = CacheContext.disabled("--no-cache")
    else:
        ctx = collect_env_base(runtime, config, root)

    # Precompile steps, in listed order. Each success widens the include set.
    var includes = config.include_paths.copy()
    # Every selected file (gates first, then the run set) depends on the
    # precompiled packages, so a precompile failure makes all of them casualties
    # — named individually in the banner (§8.3), not merely counted. Built from
    # the sorted snapshot: this list is a report about files that never ran, so
    # it must not inherit the order they would have run in.
    var casualty_files = disc.gate_files.copy()
    for f in reportable_run_files:
        casualty_files.append(String(f))
    # Every earlier step's package is an input to the next one, so the key of a
    # step carries them explicitly. Skipped steps land here too: their output is
    # on disk and on the include path exactly as a step that ran.
    var prior_outputs = List[String]()
    for pc in config.precompiles:
        if interrupt_requested():
            tally.interrupted = True
            break
        if reporter.stream_failed():
            stream_dead = True
            break
        try:
            var step = run_precompile_step(
                runtime,
                config,
                root,
                pc,
                ctx,
                includes,
                prior_outputs,
                use_cache=True,
            )
            if not step:
                continue
            ref pr = step.value()
            # The step's own attempt record first, in order: each retried
            # attempt's TRY line, its residual warning, and a success-after-retry
            # warning — the session-level signal that stands in for the FLAKY
            # verdict a file would get.
            for ev in pr.events:
                reporter.handle(ev)
            if pr.interrupted:
                tally.interrupted = True
                break
            if pr.internal_error:
                reporter.handle(
                    Event.internal_error("precompile", pr.program, pr.errno)
                )
                tally.internal_error = True
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
                        term_kind=TerminationKind(pr.term.kind),
                        term_value=pr.term.value,
                        escalated=pr.term.escalated,
                        timeout_seconds=pr.timeout_seconds,
                        attempts_used=pr.attempts_used,
                    )
                )
                break
        except:
            reporter.handle(
                Event.internal_error("precompile", config.mojo_path, 0)
            )
            tally.internal_error = True
            break

    # The include set is complete only now: every precompile step that succeeded
    # added its output directory to it, and a file built later can import from
    # there. Absorbing the roots' contents here — after the loop, before the
    # first gate — is what makes one prefix serve every per-file key.
    finalize_includes(ctx, root, includes)
    _warn_cache_off(ctx, config, reporter)

    var proceed = not (
        tally.interrupted
        or tally.internal_error
        or precompile_failed
        or stream_dead
    )

    # Gates first: a failing gate aborts the whole session immediately. The stop
    # policy runs through the same `RunPipeline` kernel the selection and plain
    # run paths use — a gate is always exit-first, so a failing gate latches
    # `LIMIT_REACHED` and aborts scheduling, exactly as before.
    var gate_retry_budgets = List[Int]()
    for gate_file in disc.gate_files:
        gate_retry_budgets.append(
            effective_file_settings(resolved, gate_file).retries
        )
    var gate_pipeline = RunPipeline.from_retry_budgets(
        gate_retry_budgets^, True, 0
    )
    # The parallel pool runs the gates as their own batch, aborting the run on
    # the first failing or drifting gate exactly as the sequential loop does.
    if proceed and resolved_workers > 1:
        var gb = _run_pool_batch(
            runtime,
            resolved,
            root,
            disc.gate_files,
            includes,
            reporter,
            summary,
            resolved_workers,
            cores,
            True,
            console_fd,
            ctx,
        )
        _absorb_batch(tally, admissions, gb)
    if proceed and resolved_workers <= 1:
        for gi in range(len(disc.gate_files)):
            if interrupt_requested():
                tally.interrupted = True
                break
            if reporter.stream_failed():
                stream_dead = True
                break
            reporter.handle(Event.file_started(disc.gate_files[gi]))
            try:
                var settings = effective_file_settings(
                    resolved, disc.gate_files[gi]
                )
                var fr = _run_one(
                    runtime,
                    config,
                    settings,
                    root,
                    disc.gate_files[gi],
                    includes,
                    ctx,
                    admissions,
                )
                if fr.interrupted:
                    tally.interrupted = True
                    break
                if fr.internal_error:
                    reporter.handle(fr.event)
                    tally.internal_error = True
                    break
                var gate_binary = String(fr.binary_path)
                if settle_file(
                    tally,
                    reporter,
                    summary,
                    gate_pipeline,
                    gi,
                    disc.gate_files[gi],
                    settings,
                    gate_binary,
                    List[String](),
                    List[Event](),
                    fr^,
                    is_gate=True,
                ):
                    break
                if gate_pipeline.halt() != PipelineHalt.RUNNING:
                    tally.aborted = True
                    break
            except:
                reporter.handle(
                    Event.internal_error("build", config.mojo_path, 0)
                )
                tally.internal_error = True
                break

    var proceed_runs = not (
        tally.interrupted
        or tally.internal_error
        or precompile_failed
        or tally.aborted
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
            runtime,
            resolved,
            root,
            disc,
            includes,
            plan,
            reporter,
            summary,
            reg,
            ctx,
            admissions,
        )
        tally.merge(sel.tally)
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
        var split = partition_effective_serial(disc.run_files, resolved)
        if config.failed_first and ff_has_match:
            var ordered = order_failed_first(
                disc.gate_files,
                split.parallel,
                split.serial,
                resolved.last_run_state,
            )
            split.parallel = ordered.parallel.copy()
            split.serial = ordered.serial.copy()
        var rb = _run_pool_batch(
            runtime,
            resolved,
            root,
            split.parallel,
            includes,
            reporter,
            summary,
            resolved_workers,
            cores,
            False,
            console_fd,
            ctx,
        )
        _absorb_batch(tally, admissions, rb)

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
        var stop_serial = (
            rb.tally.interrupted or rb.tally.internal_error or rb.halted
        )
        if len(split.serial) > 0 and not stop_serial:
            var sb = _run_pool_batch(
                runtime,
                resolved,
                root,
                split.serial,
                includes,
                reporter,
                summary,
                1,
                cores,
                False,
                console_fd,
                ctx,
                serial=True,
                initial_failing=_failing_count(rb.tally.run_outcomes),
            )
            _absorb_batch(tally, admissions, sb)
    elif proceed_runs:
        if config.failed_first and ff_has_match:
            var ordered = order_failed_first(
                disc.gate_files,
                disc.run_files,
                [],
                resolved.last_run_state,
            )
            disc.run_files = ordered.parallel.copy()
        # The plain run path settles each file build-then-run through `_run_one`
        # and routes its `-x`/`--maxfail` stop policy through the same
        # `RunPipeline` kernel the selection and gate paths use, rather than
        # re-deciding the limits inline.
        var run_retry_budgets = List[Int]()
        for run_file in disc.run_files:
            run_retry_budgets.append(
                effective_file_settings(resolved, run_file).retries
            )
        var run_pipeline = RunPipeline.from_retry_budgets(
            run_retry_budgets^,
            config.exitfirst,
            config.maxfail,
        )
        for ri in range(len(disc.run_files)):
            if interrupt_requested():
                tally.interrupted = True
                break
            if reporter.stream_failed():
                stream_dead = True
                break
            reporter.handle(Event.file_started(disc.run_files[ri]))
            try:
                var settings = effective_file_settings(
                    resolved, disc.run_files[ri]
                )
                var fr = _run_one(
                    runtime,
                    config,
                    settings,
                    root,
                    disc.run_files[ri],
                    includes,
                    ctx,
                    admissions,
                )
                if fr.interrupted:
                    tally.interrupted = True
                    break
                if fr.internal_error:
                    reporter.handle(fr.event)
                    tally.internal_error = True
                    break
                # The plain run path runs no selection, so every test name is
                # an attribution candidate: an empty selected set.
                var run_binary = String(fr.binary_path)
                _ = settle_file(
                    tally,
                    reporter,
                    summary,
                    run_pipeline,
                    ri,
                    disc.run_files[ri],
                    settings,
                    run_binary,
                    List[String](),
                    List[Event](),
                    fr^,
                )
                # Flush this file's rendered verdict as soon as it lands. The
                # plain-run branch runs only when selection is inactive, so no
                # raise can follow before the run returns; a leaked partial
                # flush ahead of a usage-error raise is therefore impossible on
                # this path.
                if _flush_console(reporter, console_fd, closing=False):
                    tally.console_dead = True
                if run_pipeline.halt() != PipelineHalt.RUNNING:
                    break
            except:
                reporter.handle(
                    Event.internal_error("build", config.mojo_path, 0)
                )
                tally.internal_error = True
                break

    # Flush every header rendered so far that no incremental flush above
    # already emitted: the precompile banner, the gate verdicts, and the
    # selection sub-session's per-file lines. Reached only once the run pass has
    # returned normally, so it never fires ahead of a selection usage-error
    # raise — matching the old terminal flush, which `main` performed only on a
    # normal return.
    if _flush_console(reporter, console_fd, closing=False):
        tally.console_dead = True

    # Every selected file that did not produce a tallied verdict is NOT_RUN — a
    # gate casualty, an -x/--maxfail/gate-abort/interrupt skip, a precompile
    # casualty, or a drift file (which forces exit 3 and is accounted here,
    # never tallied).
    var not_run = selected - tally.ran_files
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
    var outcome_code = exit_code_for(tally.run_outcomes)

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
    if not tally.interrupted and not stream_dead:
        try:
            _run_crash_attribution(
                runtime, root, tally.crash_files, reg, reporter
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
    var interrupt_latched = tally.interrupted or interrupt_requested()

    # A latched machine-stream write failure that tripped on the final file's own
    # events (missed at the scheduling boundaries) is the JSON stream's "finalize"
    # tier — picked up here so a dead pipe on the last file still escalates.
    if reporter.stream_failed():
        stream_dead = True

    # Classify why each selected file (gate and run alike, casualty_files by
    # construction) never produced a tallied verdict — one record per entry,
    # including a file that DID run, because a consumer with verdict knowledge
    # (the report writer's row index) filters rather than this call. Latched
    # causal facts are checked first, in their causal order: a latched earlier
    # cause explains the stop even when the exit-code resolver later escalates
    # for delivery, because these rows answer "why did this file not run"
    # while `resolve_exit_code` separately answers "can the verdict be
    # trusted". A dead stream ranks below every latched cause and above the
    # bare gate-membership heuristic, so a gate file that never ran because the
    # stream died is a delivery casualty, not a gate casualty, when no gate
    # actually aborted.
    var not_run_records = List[NotRunRecord]()
    for i in range(len(casualty_files)):
        var path = casualty_files[i]
        var reason = classify_not_run(
            NotRunFacts(
                interrupt_latched=interrupt_latched,
                internal_error=tally.internal_error,
                drift=tally.drift,
                precompile_failed=precompile_failed,
                gate_abort=tally.aborted,
                stream_dead=stream_dead,
                is_gate_file=_is_gate_file(disc.gate_files, path),
            )
        )
        not_run_records.append(NotRunRecord(path, reason))
    reporter.note_not_run_records(not_run_records)

    # Synthesize a `[not-run]` row into the JUnit report for every selected file
    # that never produced a verdict (interrupt/gate-abort/--maxfail casualties),
    # then finalize the report: assemble in node-id order, verify-write the
    # unique temp, atomic-rename onto PATH. The prior report survives every
    # failure. A latched junit SPOOL failure did NOT abort the run mid-flight (the
    # deliberate asymmetry vs the stream's fatal abort); it surfaces NOW.
    reporter.note_not_run(casualty_files)
    # A context that only went off mid-run — a store that could not be created,
    # a source that would not read — has had no chance to say so yet. It says so
    # here, before either terminal artifact is sealed. The latch on the context
    # makes this a no-op whenever the warning already fired up top.
    _warn_cache_off(ctx, config, reporter)

    # The run-wide build-cache accounting, read once here and handed to BOTH
    # terminal artifacts below: the JUnit finalize (which has no event to ride,
    # so the counts travel on the call) and the SessionFinished payload. Every
    # driver charges the run's one accumulator, and it is read HERE, ahead of
    # both, so the XML and the JSON stream can never carry different numbers.
    # The rule the drivers obey: `built` counts a FIRST-ATTEMPT compile
    # admission, compile FAILURES included; `cached` a cache-hit admission;
    # retries, probes and precompile steps count as neither. So
    # `built + cached == first-attempt compile admissions`, gates included.
    var built_files = admissions.built
    var cached_files = admissions.cached
    var junit_fin = reporter.finalize_junit(built_files, cached_files)
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
    # A file that passed only after a crash-class retry tallied under FLAKY; that
    # run-wide count rides the SessionFinished summary line, and under
    # `--fail-on-flaky` it is also a terminal fact the model ranks. Derived once,
    # ahead of the resolve, so both resolutions below rank the same fact.
    var flaky_files = summary.count_of(Outcome.FLAKY)
    var flaky_failed = config.fail_on_flaky and flaky_files > 0

    # The single wall-clock snapshot, taken HERE rather than after the resolve
    # so the run report's own writing time is excluded from the duration the
    # report and the terminal record both carry. What now sits between this
    # reading and the `session_finished` emit is the report finalize and the
    # resolver call; the resolver is pure and allocation-free, so the only
    # measurable exclusion is the report I/O, which is the point.
    # `summary.counts` is copied before `summary^` moves at that emit.
    var wall = Float64(perf_counter_ns() - started_ns) / 1.0e9

    # Publish the run report's sinks. Like the JUnit finalize above, this
    # happens BEFORE the delivery fact is computed, because a sink that could
    # not be published is one of the facts that fact is made of. Each sink
    # reports independently and each failure is announced on its own, ahead of
    # the terminal record, exactly as the JUnit finalization failure is.
    var report_ctx = ReportFinalizeContext(
        counts=summary.counts.copy(),
        tests_passed=tally.test_totals.passed,
        tests_failed=tally.test_totals.failed,
        tests_skipped=tally.test_totals.skipped,
        flaky_files=flaky_files,
        built_files=built_files,
        cached_files=cached_files,
        wall_seconds=wall,
        interrupted=interrupt_latched,
        drift=tally.drift,
        workers=resolved_workers,
        shuffle=config.shuffle,
        shuffle_seed=shuffle_seed,
        shard_label=shard_label,
    )
    var report_fin = reporter.finalize_reports(report_ctx)
    if report_fin.md_failed:
        reporter.handle(Event.warning("report-finalize", report_fin.md_detail))
    if report_fin.html_failed:
        reporter.handle(
            Event.warning("report-finalize", report_fin.html_detail)
        )

    # One delivery fact, five ways to earn it: a dead machine stream, a JUnit
    # report that could not be published, a console that would not take the
    # run's report, and either run-report sink that could not be published. The
    # model does not distinguish them, and neither should this — each means a
    # terminal artifact the caller asked for never arrived. Every term is also
    # read a second time through this same variable, which guards the delivery
    # re-resolve below: dropping one here would silently disarm that guard too.
    var delivery_failed = (
        stream_dead
        or finalize_failed
        or tally.console_dead
        or report_fin.md_failed
        or report_fin.html_failed
    )

    var code = resolve_exit_code(
        TerminalFacts(
            interrupted=interrupt_latched,
            internal_error=tally.internal_error,
            drift=tally.drift,
            precompile_failed=precompile_failed,
            outcome_code=outcome_code,
            delivery_failed=delivery_failed,
            flaky_failed=flaky_failed,
        )
    )

    reporter.handle(
        Event.session_finished(
            summary^,
            wall,
            code,
            test_counts=tally.test_totals,
            flaky_files=flaky_files,
            built_files=built_files,
            cached_files=cached_files,
        )
    )

    # Seal the console: emit any remaining header, then the framed sections and
    # the summary band, in `output()` order. This is the last console write the
    # driver makes; `main` renders the fence-restoration epilogue and the
    # annotation tail after this returns, so both still land AFTER the final
    # console bytes exactly as before.
    if _flush_console(reporter, console_fd, closing=True):
        tally.console_dead = True

    # Both of the last two writes can latch a NEW delivery failure the resolve
    # above could not have seen, because neither had happened yet: the dispatch
    # is ITSELF a stream write (a `--json -` consumer that closes its read end
    # right after `file_finished`; a file destination that hits ENOSPC exactly
    # on the terminal line), and the closing flush is the one carrying the
    # framed sections and the summary band — the part of the console report a
    # reader most needs. Re-poll both; if either is now set and neither was
    # already folded in, re-resolve with the pure function again,
    # passing the SAME interrupt/error/drift/precompile/outcome/flaky facts (a
    # finalization-phase interrupt still must not move the code — only the
    # delivery outcome does) and `delivery_failed=True`. The same
    # precedence applies: a resolved 2 still stands, a resolved 3 stays 3, a
    # resolved 0/1/5 escalates to 3. The already-attempted terminal record
    # (torn or absent on the now-dead stream) is the consumer's truncation
    # signal; the EXIT CODE is the out-of-band signal and must not lie about
    # it by returning the code resolved before the stream died.
    if not delivery_failed and (reporter.stream_failed() or tally.console_dead):
        code = resolve_exit_code(
            TerminalFacts(
                interrupted=interrupt_latched,
                internal_error=tally.internal_error,
                drift=tally.drift,
                precompile_failed=precompile_failed,
                outcome_code=outcome_code,
                delivery_failed=True,
                flaky_failed=flaky_failed,
            )
        )
    return code


def run_session_with_state[
    C: ReportCoordinator
](
    mut runtime: ExecRuntime,
    resolved: ResolvedConfig,
    root: String,
    mut reporter: C,
    console_fd: Int = -1,
) raises -> SessionResult:
    """Run one layered session and return its code plus live state delta.

    Parameters:
        C: The report coordinator this session drives, inferred from the
            argument. The state delta is read back from it once the run returns.

    Args:
        runtime: Exclusive owner of process-global exec and signal state.
        resolved: Layered global configuration and override tables.
        root: The invocation root.
        reporter: The coordinator receiving the event stream.
        console_fd: The borrowed console descriptor, or negative for none.

    Returns:
        The session's resolved code and fresh verdict observations.

    Raises:
        Error: The same pre-session usage errors as `run_session`.
    """
    var code = run_session(runtime, resolved, root, reporter, console_fd)
    return SessionResult(code, reporter.state_delta())


def run_session[
    C: ReportCoordinator
](
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    mut reporter: C,
    console_fd: Int = -1,
) raises -> Int:
    """Run from the legacy config with no per-file override tables.

    Parameters:
        C: The report coordinator this session drives, inferred from the
            argument.

    Args:
        runtime: Exclusive owner of process-global exec and signal state.
        config: The legacy resolved runner configuration.
        root: The invocation root; built binaries and paths are relative to it.
        reporter: The coordinator the session fans every event to.
        console_fd: The borrowed console destination, or negative for none.

    Returns:
        The resolved exit code from the layered primary overload.
    """
    var resolved = _compat_resolved_config(config)
    return run_session(runtime, resolved, root, reporter, console_fd)


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

    Examples:

    ```mojo
    from mtest.config import RunnerConfig
    from mtest.report import CompositeReporter, RecordingCoordinator
    from mtest.report import RecordingReporter
    from mtest.session import run_session

    var comp = RecordingCoordinator(CompositeReporter(Tuple(RecordingReporter())))
    var code = run_session(RunnerConfig.default(), "/path/to/suite", comp)
    ```
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


def run_session[
    C: ReportCoordinator
](resolved: ResolvedConfig, root: String, mut reporter: C) raises -> Int:
    """Run a session from layered configuration for direct library callers.

    Parameters:
        C: The report coordinator this session drives, inferred from the
            argument.

    Args:
        resolved: Layered values, provenance, and per-file override tables.
        root: The invocation root; built binaries and paths are relative to it.
        reporter: The coordinator the session fans every event to.

    Returns:
        The resolved exit code, as the primary overload defines it.

    Raises:
        Error: If the runtime cannot be opened or closed, or if the primary
            overload raises.
    """
    var runtime = ExecRuntime()
    try:
        runtime.open()
        var code = run_session(runtime, resolved, root, reporter)
        runtime.close()
        return code
    except error:
        var primary = String(error)
        try:
            runtime.close()
        except cleanup_error:
            raise Error(primary + "; " + String(cleanup_error))
        raise Error(primary)
