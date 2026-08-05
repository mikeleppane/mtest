"""One build-run-classify attempt for a file, and the retry loop over it.

Layer 4, the plain (non-selection) run path. `_run_one` spends up to the file's
effective retry budget plus one attempt, each building it under
`--compile-timeout`, executing the binary under the `exec` supervisor, then
resolving and classifying the report its stdout carried. A crash-class ending
with budget left is reported immediately and retried: a build rebuilds
quarantined against a fresh module cache, and a run re-runs the same binary. A
late pass after any retry is flaky.

This is also the SECOND of the three build seams into the artifact store, and
the one whose control flow does the work: the store is consulted once, before
the retry loop is entered, and the staged build is settled once, on the loop's
FIRST pass. Every later pass is a retry — a re-run of the same binary, or a
quarantined rebuild into `build/bin` — and a retry's binary is
invocation-private, so it is never keyed, never counted, and never published.

It sits above `build` (for the compile-spawn policy and the staging helpers),
`store`, `scratch`, `file_result`, and the classify/clamp/retry/verdict leaves,
and below `session`, which drives it for the gate files and the plain run set.
The precompile step reuses its attempt-event and residual-warning shapes so a
session-level step's attempt line carries the same identity a file build's does.
"""
from mtest.config import RunnerConfig, lossy_utf8
from mtest.exec import (
    ExecRuntime,
    ProcessResult,
    ProcessSpec,
    Termination,
    interrupt_requested,
    run_supervised,
    source_identity_key,
)
from mtest.model import (
    Event,
    InternalErrorPayload,
    NodeId,
    Outcome,
    ParseDisposition,
    TestCounts,
    TestResult,
    is_slow,
)
from mtest.protocol import ParsedReport
from mtest.session.build import _COMPILE_GRACE_MS, build_argv
from mtest.session.clamp import clamp_stream
from mtest.session.classify import (
    Classification,
    TrustedReport,
    classify,
    resolve_report,
)
from mtest.session.file_result import (
    CacheAdmissions,
    FileResult,
    _prepend_events,
)
from mtest.session.effective_settings import EffectiveFileSettings
from mtest.session.retry_class import RetryClass, retry_classify
from mtest.session.scratch import (
    _cleanup_quarantine,
    _ensure_dir,
    _invocation_nonce,
    _mangle,
    _quarantine_dir,
    _retry_out_bin,
)
from mtest.session.store import (
    CacheContext,
    _rewrite_output,
    cache_rebuild_note,
)
from mtest.session.store_seam import (
    seam_begin,
    seam_discard,
    seam_settle,
    seam_stage,
)
from mtest.session.verdict import build_verdict


comptime _ATTEMPT_STREAM_HEAD = 65536
"""Head bytes of each stream kept in a non-final attempt's excerpt (64 KiB)."""
comptime _ATTEMPT_STREAM_TAIL = 65536
"""Tail bytes of each stream kept in a non-final attempt's excerpt (64 KiB)."""


comptime _ENOENT = 2
"""The POSIX spawn error for the cache pathname that vanished before exec."""


@fieldwise_init
struct _AttemptResult(Copyable, Movable):
    """The raw result of one build, run, and classify attempt for a file.

    Owns its captured stream buffers, argv list, and event; copies are explicit.

    Returned by `_single_attempt` so the attempt loop can both build the file's
    terminal `FileResult` (via `_finalize_attempt`) and decide a retry (via
    `retry_classify` over the failed step's raw `Termination`). `control` is `1`
    for an internal error (exit 3), `2` for an interrupt (exit 2), or `0` for a
    completed attempt. A completed attempt is a compile terminal when
    `build_failed` (the build died and no run happened), or otherwise a run that
    classified into `cls`.
    """

    var control: Int
    """`0` completed, `1` internal error, `2` interrupt."""
    var internal_event: Event
    """The InternalError diagnostic when `control == 1`."""
    var build_failed: Bool
    """Whether the build failed terminally (a compile step; no run happened)."""
    var build_argv: List[String]
    """The build command that produced (or tried to produce) the binary."""
    var bterm: Termination
    """The build's raw termination (for `retry_classify` on the build path)."""
    var build_stderr: List[UInt8]
    """The build's captured stderr (the compiler banner / ICE signature)."""
    var bdur: Float64
    """The build wall time in seconds."""
    var out_bin: String
    """The binary path this attempt built/ran."""
    var rterm: Termination
    """The run's raw termination (valid when a run happened)."""
    var run_stdout: List[UInt8]
    """The run's full captured stdout, always unclamped.

    `_make_attempt_finished` clamps a copy of it for a non-final attempt's
    event; the field itself keeps the whole capture."""
    var run_stderr: List[UInt8]
    """The run's full captured stderr."""
    var rdur: Float64
    """The run wall time in seconds."""
    var trusted: TrustedReport
    """The resolved report the run's stdout was trusted to carry."""
    var cls: Classification
    """The per-test classification of the run."""
    var run_stdout_truncated: Bool
    """Whether the run's captured stdout overflowed the capture bound (the
    run-phase `ProcessResult`'s own flag, carried through to the file's
    `FileFinished`; False when no run happened)."""
    var run_stderr_truncated: Bool
    """Whether the run's captured stderr overflowed the capture bound (as
    `run_stdout_truncated`, but for stderr)."""

    @staticmethod
    def _internal(var e: Event) -> Self:
        """An internal-error attempt: routes the file to exit 3.

        Args:
            e: The `InternalError` diagnostic. Consumed; the returned
                `_AttemptResult` owns it.

        Returns:
            The internal-error `_AttemptResult`.
        """
        return Self(
            control=1,
            internal_event=e^,
            build_failed=False,
            build_argv=List[String](),
            bterm=Termination.exited(0),
            build_stderr=List[UInt8](),
            bdur=0.0,
            out_bin="",
            rterm=Termination.exited(0),
            run_stdout=List[UInt8](),
            run_stderr=List[UInt8](),
            rdur=0.0,
            trusted=TrustedReport(ParsedReport.absent(), False),
            cls=_blank_classification(),
            run_stdout_truncated=False,
            run_stderr_truncated=False,
        )

    @staticmethod
    def _interrupt() -> Self:
        """An interrupt aborted the attempt: routes the file to exit 2."""
        return Self(
            control=2,
            internal_event=Event.file_started(""),
            build_failed=False,
            build_argv=List[String](),
            bterm=Termination.exited(0),
            build_stderr=List[UInt8](),
            bdur=0.0,
            out_bin="",
            rterm=Termination.exited(0),
            run_stdout=List[UInt8](),
            run_stderr=List[UInt8](),
            rdur=0.0,
            trusted=TrustedReport(ParsedReport.absent(), False),
            cls=_blank_classification(),
            run_stdout_truncated=False,
            run_stderr_truncated=False,
        )

    @staticmethod
    def _build_failed(
        var build_argv: List[String],
        bterm: Termination,
        var build_stderr: List[UInt8],
        bdur: Float64,
        out_bin: String,
    ) -> Self:
        """A terminal compile failure carrying only the build facts.

        Args:
            build_argv: The build command that failed. Consumed; the returned
                `_AttemptResult` owns it.
            bterm: The build's raw termination.
            build_stderr: The compiler's captured stderr. Consumed; the
                returned `_AttemptResult` owns it.
            bdur: The build wall time in seconds.
            out_bin: The binary path the build was targeting.

        Returns:
            The build-failed `_AttemptResult`.
        """
        return Self(
            control=0,
            internal_event=Event.file_started(""),
            build_failed=True,
            build_argv=build_argv^,
            bterm=bterm,
            build_stderr=build_stderr^,
            bdur=bdur,
            out_bin=out_bin,
            rterm=Termination.exited(0),
            run_stdout=List[UInt8](),
            run_stderr=List[UInt8](),
            rdur=0.0,
            trusted=TrustedReport(ParsedReport.absent(), False),
            cls=_blank_classification(),
            run_stdout_truncated=False,
            run_stderr_truncated=False,
        )

    @staticmethod
    def _built_ok(
        var build_argv: List[String],
        bterm: Termination,
        var build_stderr: List[UInt8],
        bdur: Float64,
        out_bin: String,
    ) -> Self:
        """A successful build that has not been run yet.

        What `build_only` returns, so the caller can settle the staged artifact
        — publish it, or discard it — before anything is executed. Its build
        fields are exactly what the run pass needs handed back to it as the
        prior build's facts.

        Args:
            build_argv: The build command that succeeded. Consumed; the
                returned `_AttemptResult` owns it.
            bterm: The build's raw termination.
            build_stderr: The compiler's captured stderr. Consumed; the
                returned `_AttemptResult` owns it.
            bdur: The build wall time in seconds.
            out_bin: The binary the build produced.

        Returns:
            The built-but-unrun `_AttemptResult`.
        """
        return Self(
            control=0,
            internal_event=Event.file_started(""),
            build_failed=False,
            build_argv=build_argv^,
            bterm=bterm,
            build_stderr=build_stderr^,
            bdur=bdur,
            out_bin=out_bin,
            rterm=Termination.exited(0),
            run_stdout=List[UInt8](),
            run_stderr=List[UInt8](),
            rdur=0.0,
            trusted=TrustedReport(ParsedReport.absent(), False),
            cls=_blank_classification(),
            run_stdout_truncated=False,
            run_stderr_truncated=False,
        )

    @staticmethod
    def _selection_run(
        binary: String,
        rterm: Termination,
        var run_stdout: List[UInt8],
        var run_stderr: List[UInt8],
        rdur: Float64,
        run_stdout_truncated: Bool = False,
        run_stderr_truncated: Bool = False,
    ) -> Self:
        """A ran result for a selection run, for its attempt-finished event.

        The selection path already built the binary in its build-and-probe
        pass, so the build fields are placeholders and only the run fields
        matter.

        Args:
            binary: The binary the selection run executed.
            rterm: The run's raw termination.
            run_stdout: The run's captured stdout. Consumed; the returned
                `_AttemptResult` owns it.
            run_stderr: The run's captured stderr. Consumed; the returned
                `_AttemptResult` owns it.
            rdur: The run wall time in seconds.
            run_stdout_truncated: Whether the stdout capture overflowed.
            run_stderr_truncated: Whether the stderr capture overflowed.

        Returns:
            The completed `_AttemptResult`.
        """
        return Self(
            control=0,
            internal_event=Event.file_started(""),
            build_failed=False,
            build_argv=List[String](),
            bterm=Termination.exited(0),
            build_stderr=List[UInt8](),
            bdur=0.0,
            out_bin=binary,
            rterm=rterm,
            run_stdout=run_stdout^,
            run_stderr=run_stderr^,
            rdur=rdur,
            trusted=TrustedReport(ParsedReport.absent(), False),
            cls=_blank_classification(),
            run_stdout_truncated=run_stdout_truncated,
            run_stderr_truncated=run_stderr_truncated,
        )


def _blank_classification() -> Classification:
    """A placeholder classification for an attempt result with no run."""
    return Classification(
        Outcome.NOT_RUN,
        ParseDisposition.NO_REPORT,
        0,
        0,
        0,
        List[Outcome](),
        False,
        "",
        "",
    )


def _single_attempt(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    settings: EffectiveFileSettings,
    root: String,
    rel: String,
    include_paths: List[String],
    out_bin: String,
    do_build: Bool,
    quarantine_dir: String,
    prior_build_argv: List[String],
    prior_bterm: Termination,
    prior_build_stderr: List[UInt8],
    prior_bdur: Float64,
    build_only: Bool = False,
) raises -> _AttemptResult:
    """Run one build, run, and classify attempt for `rel`, returning raw facts.

    The retry loop wraps this. When `do_build` is set it builds `rel` into
    `out_bin` under `--compile-timeout`; otherwise it reuses the prior
    successful build's facts and only re-runs `out_bin`, since a run-side retry
    never rebuilds. `build_only` stops after a successful build and hands the
    build facts back unrun, so the caller can settle a staged artifact before
    anything executes; the caller then asks for the run as an ordinary
    `do_build=False` pass over whichever binary settling left live. A cache
    quarantine applies only when `quarantine_dir` is
    non-empty, which happens on a post-compile-kill rebuild: `MODULAR_CACHE_DIR`
    is set in the build child's own environment (via `spec.env_extra`), so
    mtest's own environment is never touched and concurrent builds cannot
    clobber each other's cache directory. The build and run termination,
    spawn-failure, and in-flight-interrupt short-circuits match the non-retry
    path exactly.

    Args:
        runtime: The exec runtime supervising the build and run spawns.
        config: The resolved runner configuration.
        settings: The file's effective deadlines and retry/serial policy.
        root: The invocation root the child processes run in.
        rel: The root-relative path of the file to build and run.
        include_paths: Directories passed to the compiler as `-I`.
        out_bin: The binary path to build into and execute.
        do_build: Whether to build; False reuses the prior build's facts.
        quarantine_dir: A fresh module-cache directory to use for this build,
            or empty to leave `MODULAR_CACHE_DIR` alone.
        prior_build_argv: The previous attempt's build command, reused when
            `do_build` is False.
        prior_bterm: The previous attempt's build termination.
        prior_build_stderr: The previous attempt's captured build stderr.
        prior_bdur: The previous attempt's build wall time in seconds.
        build_only: Whether to return after a successful build instead of
            running the binary. Honored only together with `do_build`, since
            there is nothing to stop after when no build happens.

    Returns:
        The raw attempt facts, including its control signal.

    Raises:
        Error: If canonicalizing the source path fails. Both `exec` supervisor
            calls are caught here and converted into internal-error attempts
            instead. The caller catches what does escape and resolves exit 3.
    """
    var argv = prior_build_argv.copy()
    var bterm = prior_bterm
    var build_stderr = prior_build_stderr.copy()
    var bdur = prior_bdur

    if do_build:
        argv = build_argv(
            config.mojo_path,
            "build",
            include_paths,
            config.build_args,
            out_bin,
            rel,
        )

        # NARROW quarantine: only a post-compile-kill rebuild redirects the
        # module cache. The spike observed NO cache corruption from a killed
        # compile (the cache commits atomically), so this is defense-in-depth.
        # The override rides the CHILD's environment via `env_extra`, so the
        # parent's environment is never touched and concurrent quarantined
        # builds cannot clobber each other's cache directory.
        var env_extra = List[String]()
        if quarantine_dir != "":
            env_extra.append("MODULAR_CACHE_DIR=" + quarantine_dir)

        # Build under `--compile-timeout` (0 disables), inside the invocation
        # root, with the COMPILE-specific grace. A build machinery raise is a
        # build-phase internal error naming the compiler.
        var bres: ProcessResult
        try:
            bres = run_supervised(
                runtime,
                ProcessSpec.command_in(
                    argv.copy(),
                    root,
                    settings.compile_timeout_secs * 1000,
                    _COMPILE_GRACE_MS,
                    env_extra^,
                ),
            )
        except:
            return _AttemptResult._internal(
                Event.internal_error("build", config.mojo_path, 0)
            )

        bdur = Float64(bres.duration_ms) / 1000.0
        # An interrupt during the build group-kills it (a TimedOut bail-out).
        if interrupt_requested():
            return _AttemptResult._interrupt()
        bterm = bres.termination
        if bterm.is_spawn_failed():
            # Could not spawn the compiler at all: a machinery diagnostic.
            return _AttemptResult._internal(
                Event.internal_error("build", config.mojo_path, bterm.value)
            )
        build_stderr = bres.stderr_bytes.copy()
        if build_verdict(bterm).is_failing():
            # A compile failure (a COMPILE_ERROR, or a COMPILE_TIMEOUT when our
            # deadline killed it): no run happens. The raw bterm + stderr ride so
            # the caller can BOTH finalize the build verdict AND classify a retry
            # (a signaled/timed-out/ICE compiler is crash-class).
            return _AttemptResult._build_failed(
                argv^, bterm, build_stderr^, bdur, out_bin
            )
        if build_only:
            # The artifact exists and nothing has run it. Whatever the caller
            # does with it next decides which binary the run will name, so the
            # run cannot already have happened.
            return _AttemptResult._built_ok(
                argv^, bterm, build_stderr^, bdur, out_bin
            )

    # Build OK (or reused from a prior successful build): run the binary. A
    # run-phase machinery raise attributes to the RUN step and names the binary.
    var run_argv = List[String]()
    run_argv.append(out_bin)
    var rres: ProcessResult
    try:
        rres = run_supervised(
            runtime,
            ProcessSpec.command_in(
                run_argv^, root, settings.timeout_secs * 1000
            ),
        )
    except:
        return _AttemptResult._internal(Event.internal_error("run", out_bin, 0))
    var rterm = rres.termination
    if rterm.is_spawn_failed():
        return _AttemptResult._internal(
            Event.internal_error("run", out_bin, rterm.value)
        )
    # An in-flight interrupt returns as TimedOut; never record it as a TIMEOUT.
    if rterm.is_timed_out() and interrupt_requested():
        return _AttemptResult._interrupt()

    var rdur = Float64(rres.duration_ms) / 1000.0

    # The run's own report IS the handshake. Decode the captured stdout, resolve
    # WHICH report to trust under capture overflow, then run the TOTAL classifier
    # against the canonical path the child baked into its report.
    var source_path = source_identity_key(root, rel)
    var stdout_text = lossy_utf8(rres.stdout_bytes)
    var trusted = resolve_report(
        stdout_text, source_path, rres.stdout_truncated
    )
    var cls = classify(rterm, trusted.report, trusted.is_overflow)

    return _AttemptResult(
        control=0,
        internal_event=Event.file_started(""),
        build_failed=False,
        build_argv=argv^,
        bterm=bterm,
        build_stderr=build_stderr^,
        bdur=bdur,
        out_bin=out_bin,
        rterm=rterm,
        run_stdout=rres.stdout_bytes.copy(),
        run_stderr=rres.stderr_bytes.copy(),
        rdur=rdur,
        trusted=trusted^,
        cls=cls^,
        run_stdout_truncated=rres.stdout_truncated,
        run_stderr_truncated=rres.stderr_truncated,
    )


def _make_attempt_finished(
    rel: String,
    rc: RetryClass,
    att: _AttemptResult,
    attempt_index: Int,
    attempts_planned: Int,
    step_override: String = "",
) -> Event:
    """Build the `AttemptFinished` event for one non-final attempt.

    The failed step's raw `Termination` is decomposed into the event's identity
    fields, and the captured streams are clamped to a bounded head-and-tail
    excerpt; only the final attempt keeps the full capture, in its
    `FileFinished`.

    Args:
        rel: The root-relative path of the file this attempt belongs to.
        rc: The retry classification whose label names why a retry followed.
        att: The attempt whose failed step supplies the termination and streams.
        attempt_index: This attempt's number.
        attempts_planned: How many attempts the file was allowed.
        step_override: Names the step when it is not the file's own build or
            run. The session-level precompile step reuses this seam so its
            attempt line carries the same identity as a build one.

    Returns:
        The `AttemptFinished` event.
    """
    var step: String
    var term: Termination
    var argv: List[String]
    var dur: Float64
    var out_bytes: List[UInt8]
    var err_bytes: List[UInt8]
    if att.build_failed:
        step = String("build")
        term = att.bterm
        argv = att.build_argv.copy()
        dur = att.bdur
        out_bytes = List[UInt8]()
        err_bytes = att.build_stderr.copy()
    else:
        step = String("run")
        term = att.rterm
        argv = [att.out_bin]
        dur = att.rdur
        out_bytes = att.run_stdout.copy()
        err_bytes = att.run_stderr.copy()
    if step_override != "":
        step = step_override.copy()
    var co = clamp_stream(out_bytes, _ATTEMPT_STREAM_HEAD, _ATTEMPT_STREAM_TAIL)
    var ce = clamp_stream(err_bytes, _ATTEMPT_STREAM_HEAD, _ATTEMPT_STREAM_TAIL)
    return Event.attempt_finished(
        rel,
        step,
        attempt_index,
        attempts_planned,
        term.kind,
        term.value,
        term.final_kind,
        term.final_value,
        term.escalated,
        True,
        rc.label,
        dur,
        co.bytes.copy(),
        ce.bytes.copy(),
        co.truncated,
        ce.truncated,
        argv^,
    )


def _finalize_attempt(
    settings: EffectiveFileSettings,
    rel: String,
    var att: _AttemptResult,
    attempts_used: Int,
    flaky: Bool,
    serial: Bool = False,
) -> FileResult:
    """Build the file's terminal `FileResult` from its last attempt.

    Mirrors the non-retry verdict construction, then threads `attempts_used`
    and, for a late pass after a crash-class attempt, the flaky outcome and
    flag.

    Args:
        settings: The file's effective deadlines and retry/serial policy.
        rel: The root-relative path of the file.
        att: The last attempt, consumed for its streams and classification.
        attempts_used: How many attempts the file spent.
        flaky: Whether this attempt passed only after a crash-class attempt.
        serial: Whether the file ran one-at-a-time on the serial pass rather
            than a worker; rides the verdict as an informal annotation.

    Returns:
        The file's terminal `FileResult`.
    """
    if att.build_failed:
        # COMPILE_ERROR (the compiler rejected the code) or COMPILE_TIMEOUT (we
        # killed it at the deadline) — the raw build termination decides, so a
        # deadline kill is never mislabelled as the source's fault. The
        # compiler's stderr rides as raw bytes for the console banner; the
        # deadline rides so the banner can name it.
        var bout = build_verdict(att.bterm)
        var bto = 0
        if bout == Outcome.COMPILE_TIMEOUT:
            bto = settings.compile_timeout_secs
        var ev = Event.file_finished(
            rel,
            bout,
            0.0,
            att.build_argv.copy(),
            att.bdur,
            List[UInt8](),
            att.build_stderr.copy(),
            timeout_seconds=bto,
            attempts_used=attempts_used,
            slow=is_slow(att.bdur, 0.0),
            serial=serial,
        )
        return FileResult.ran_with(ev^, bout)

    var cls = att.cls.copy()
    # Retrospective per-test events for a VALID report, in row order.
    var pre = List[Event]()
    if cls.disposition == ParseDisposition.PARSED:
        for r in att.trusted.report.rows:
            pre.append(
                Event.test_reported(
                    TestResult(
                        NodeId(rel, r.name), r.outcome, r.detail, r.timing
                    )
                )
            )
    if cls.warning_kind != "":
        pre.append(Event.warning(cls.warning_kind, cls.warning_detail))

    var signal_number = 0
    var exit_status = 0
    var timeout_seconds = 0
    # The run Termination's latched SIGKILL escalation rides the verdict, so a
    # `--timeout N` with no retries (hence no TRY line) can still say whether the
    # child stopped on the polite SIGTERM or had to be killed. Only a TIMEOUT
    # latches it; every other outcome leaves it False rather than guessing.
    var escalated = False
    if cls.file_outcome == Outcome.CRASH:
        signal_number = att.rterm.value
    elif cls.file_outcome == Outcome.FAIL:
        exit_status = att.rterm.value
    elif cls.file_outcome == Outcome.TIMEOUT:
        timeout_seconds = settings.timeout_secs
        escalated = att.rterm.escalated

    # A late pass after a crash-class attempt is FLAKY (not PASS): the file
    # tallies under FLAKY, but its per-test exit multiset stays the passing
    # (non-failing) one, so a flaky pass counts 0 toward --maxfail and exit 0.
    var file_out = cls.file_outcome
    if flaky:
        file_out = Outcome.FLAKY

    var ev = Event.file_finished(
        rel,
        file_out,
        att.rdur,
        att.build_argv.copy(),
        att.bdur,
        att.run_stdout.copy(),
        att.run_stderr.copy(),
        signal_number=signal_number,
        exit_status=exit_status,
        timeout_seconds=timeout_seconds,
        parse_disposition=cls.disposition,
        passed_tests=cls.passed_tests,
        failed_tests=cls.failed_tests,
        skipped_tests=cls.skipped_tests,
        attempts_used=attempts_used,
        flaky=flaky,
        escalated=escalated,
        slow=is_slow(att.bdur, att.rdur),
        stdout_truncated=att.run_stdout_truncated,
        stderr_truncated=att.run_stderr_truncated,
        serial=serial,
    )
    var fr = FileResult.classified(
        pre^,
        ev^,
        file_out,
        cls.exit_outcomes.copy(),
        TestCounts(cls.passed_tests, cls.failed_tests, cls.skipped_tests, 0),
        cls.is_drift,
    )
    # The binary this attempt actually RAN — which a BUILD retry moves to a
    # `.attempt-N` path. Crash attribution reruns this, never a reconstruction.
    fr.binary_path = att.out_bin
    return fr^


def _compile_crash_residual(
    noun: String, name: String, rc: RetryClass, term: Termination
) -> String:
    """Compose the residual-risk warning for a retried crash-class compile.

    Crash-class covers two shapes, and the sentence must be true for both: a
    compiler mtest killed at the compile deadline, and one that crashed on its
    own by dying to a signal or exiting nonzero with an ICE signature. The cause
    phrase is read off `term` so a self-exited ICE is not described as killed.
    The cache-suspect tail is the same for both, since the shared module cache
    may be torn either way, which is why the rebuild ran quarantined.

    Args:
        noun: The step being described, e.g. `"compile"`.
        name: The source or step name the warning is about.
        rc: The retry classification whose label is quoted in the warning.
        term: The failed compile's termination, which decides the cause phrase.

    Returns:
        The warning detail text.
    """
    var cause: String
    if term.is_timed_out():
        cause = "was killed at the compile deadline"
    elif term.is_signaled():
        cause = "crashed (died by signal)"
    else:
        cause = (
            "crashed on its own (exited nonzero with a compiler-crash"
            " signature)"
        )
    return (
        "the "
        + noun
        + " of '"
        + name
        + "' "
        + cause
        + " ("
        + rc.label
        + "); the shared module cache may be suspect, so the rebuild ran"
        " quarantined against a fresh per-attempt cache (the shared cache was"
        " neither used nor deleted)"
    )


def flaky_eligible(file_outcome: Outcome) -> Bool:
    """Whether a post-retry final attempt counts as a flaky-eligible pass.

    A file is flaky only when a retry followed a crash-class failure and the
    final attempt is a genuine pass. An off-grammar report classifies to
    `NOT_RUN` plus drift, which is neither failing nor passing, so keying on
    `== PASS` rather than `not is_failing()` keeps a crash-then-drift file at
    its real drift verdict of exit 3 instead of laundering it into a green flaky
    pass, while a crash-then-clean-pass still qualifies.

    Args:
        file_outcome: The final attempt's file-level outcome.

    Returns:
        True when the outcome is `PASS`.
    """
    return file_outcome == Outcome.PASS


def _run_one(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    settings: EffectiveFileSettings,
    root: String,
    rel: String,
    include_paths: List[String],
    mut ctx: CacheContext,
    mut admissions: CacheAdmissions,
) raises -> FileResult:
    """Build `rel`, execute it, and retry a crash-class failure up to budget.

    Runs through `_single_attempt` up to the file's effective retry budget plus
    one attempt. An attempt that passes, or fails deterministically with a real
    failure, a compile error, or a flooded capture, is final. A crash-class
    failure with attempts remaining is reported immediately as an
    `AttemptFinished` and retried: a crash-class build failure rebuilds
    quarantined against a fresh cache and emits a residual-risk warning, while
    a crash-class run failure re-runs the same binary. If the final attempt
    passes after any retry the file is flaky. An interrupt is short-circuited
    before the retry decision and so is never retried, and an unset `--retries`
    runs exactly one attempt.

    The artifact store is consulted ONCE, before the loop, under an enabled
    context. A hit compiles nothing: the stored binary, its recorded command
    line, and its original build duration enter the loop exactly as a reused
    build's facts would, so the first pass is a bare run. A miss stages a
    directory inside the store and points the compile's `-o` at it; the first
    pass then BUILDS ONLY, the staged artifact is published, and the run
    happens over whatever publication left live. That order is the store's own
    rule — record `pub.argv`, run `pub.bin_rel` — and it is what keeps the
    binary a verdict describes and the binary the record names the same one.
    Every later pass is a retry and touches none of that.

    Args:
        runtime: The exec runtime supervising the build and run spawns.
        config: The resolved runner configuration for build inputs.
        settings: The file's effective deadlines and retry/serial policy.
        root: The invocation root the child processes run in.
        rel: The root-relative path of the file to build and run.
        include_paths: Directories passed to the compiler as `-I`.
        ctx: The session's cache state, switched off if this file proves the
            store unusable.
        admissions: The run's admission accumulator. Exactly one admission is
            charged here — `built` when the file reaches the compiler (compile
            failures included), `cached` on a store hit.

    Returns:
        The file's terminal result, with each non-final attempt's events
        prepended. A publication that failed rides in front of them as a
        `cache-publish` warning: the build survived, only its publication did
        not, so it is never a verdict.

    Raises:
        Error: If a build or quarantine directory cannot be made, or if an
            attempt's source canonicalization fails. Both `exec` supervisor
            calls are caught inside `_single_attempt` and become internal-error
            attempts rather than raises. Nothing in the cache path raises: an
            unusable store costs a rebuild, never a run. The caller catches what
            does escape and resolves exit 3.
    """
    # `build/bin` is created unconditionally, exactly as before: every retry
    # rebuild lands there, and so does every build under a disabled cache — and
    # a compile error's reproduce line names it, so it has to be a directory a
    # user can actually build into.
    _ensure_dir(root + "/build/bin")
    var mangled = _mangle(rel)
    var nonce = _invocation_nonce()
    var attempts_planned = settings.retries + 1

    # AttemptFinished (+ any compile-kill warning) for each NON-final attempt,
    # in order; prepended to the final FileResult so the reporter renders each
    # the moment its attempt completed, before the file's verdict.
    var attempt_events = List[Event]()
    var quarantine_dirs = List[String]()
    var had_retry = False

    var do_build = True
    var quarantine_dir = String("")
    var plain_out = String("build/bin/") + mangled
    var out_bin = plain_out
    var prior_build_argv = List[String]()
    var prior_bterm = Termination.exited(0)
    var prior_build_stderr = List[UInt8]()
    var prior_bdur = 0.0

    # --- The store, consulted once, before the first attempt is spawned. ----
    # It has to be here and not inside the loop: `store_probe` MUTATES the store
    # (a generation that fails validation is deleted), so it may only ever be
    # asked about a key this call is genuinely about to build or run.
    var staging = seam_begin(ctx, root, rel)
    # Whether this file is about to run a binary the store served, whether it
    # just published or adopted one, and whether it has already fallen back.
    # Publishing deletes a source's older generations, so a second run over the
    # same checkout can remove the generation this one validated between probe
    # and exec. A binary that is no longer there is a reason to compile the
    # file, not an internal error — and once, so a binary that will not spawn
    # for any other reason still reaches the internal-error path rather than
    # looping.
    var store_hit = False
    var published_store_artifact = False
    var store_rebuilt = False
    if staging.hit:
        # The loop enters as if a build had already succeeded: this is exactly
        # the shape a run-side retry uses, which is why nothing downstream needs
        # to know a compile was skipped. The stored build's OWN duration rides,
        # not zero, so the SLOW token reads the same on a warm run as it did on
        # the cold one.
        do_build = False
        out_bin = staging.bin_rel
        prior_build_argv = staging.argv.copy()
        prior_bterm = Termination.exited(0)
        prior_bdur = staging.build_seconds
        store_hit = True
        admissions.cached += 1
    else:
        seam_stage(ctx, staging, root, mangled)
        if staging.target.ok():
            out_bin = staging.target.out_rel

    if do_build:
        # ADMISSION, and the only place either counter moves on this path: the
        # file is about to be compiled for the first time, so it is a built file
        # whatever the compiler goes on to say about it. The spawn happens one
        # call down, inside `_single_attempt`, so counting on the way back would
        # quietly drop every compile error out of the accounting and break
        # `built + cached == first-attempt admissions`.
        admissions.built += 1

    var attempt_index = 1
    while True:
        # --- Is this pass the one that settles the staged build? ------------
        # `do_build and attempt_index == 1` IS the first-attempt compile, and
        # both halves are load-bearing. `attempt_index == 1` alone would be
        # true forever if the loop ever gained a pass that does not advance it;
        # `do_build` alone is true again on the compile-kill rebuild below,
        # which re-enters the loop with `do_build = True` and a fresh
        # `_retry_out_bin` under `build/bin`. That rebuild is invocation-private
        # — it exists to get past a compiler the shared module cache may have
        # torn — so publishing it would write a retry's binary into a store that
        # other runs read. The staging is detached once the block has run, so it
        # cannot fire twice however the loop is later reshaped.
        var settling = (
            staging.target.ok()
            and Bool(staging.key)
            and do_build
            and attempt_index == 1
        )
        # That pass BUILDS ONLY, so publication happens before anything is
        # executed. The store's rule is record `pub.argv`, run `pub.bin_rel`,
        # and running first would break both halves of it: on PUB_OK the run
        # would be the staging binary while the record named the generation, so
        # a test reading its own executable path passes cold and fails warm over
        # identical inputs; on PUB_ADOPTED the verdict would belong to this
        # process's own bytes while the record named the winner's.
        var att = _single_attempt(
            runtime,
            config,
            settings,
            root,
            rel,
            include_paths,
            out_bin,
            do_build,
            quarantine_dir,
            prior_build_argv,
            prior_bterm,
            prior_build_stderr,
            prior_bdur,
            settling,
        )

        if settling:
            var owed = staging.take()
            if att.control != 0:
                # An internal error or an interrupt during the build: no binary
                # came out of it, so the staged directory is pure debris. The
                # BUILD step's diagnostic names the compiler rather than a path
                # inside the store, so nothing here needs rewriting.
                seam_discard(owed^, root)
            elif att.build_failed:
                # The reproduce line names `build/bin`, never the staging
                # directory the compile actually wrote to. A failed build
                # publishes nothing, so that directory is deleted on the next
                # line and a line naming it would be a line no user could ever
                # run; `build/bin/<mangled>` is where an uncached build puts
                # this file's binary and is live either way.
                var shown = _rewrite_output(att.build_argv, out_bin, plain_out)
                att.build_argv = shown^
                seam_discard(owed^, root)
            else:
                var pub = seam_settle(owed^, root, att.bdur, att.build_argv)
                # `out_bin` moves with the settled binary, so the run below —
                # and any crash-class RUN retry after it — spawns exactly the
                # path that was recorded. On an adoption that runs the winner's
                # binary rather than the bytes this process compiled: they
                # answer to the same key, so they are the same build, and this
                # is the only ordering in which the verdict and the artifact
                # describe each other.
                out_bin = pub.bin_rel
                if not pub.owned:
                    # The build survived; only its publication did not. A
                    # publication failure is never a verdict, so it rides in
                    # front of this file's events as a warning.
                    attempt_events.append(
                        Event.warning("cache-publish", pub.warning)
                    )
                else:
                    # The cache has just taken ownership of the binary this
                    # session will execute. A concurrent unreadable-generation
                    # quarantine can briefly move that final pathname aside;
                    # a real ENOENT from this next exec gets the same bounded
                    # local rebuild as a warm hit below.
                    published_store_artifact = True
                # The run pass, over the settled binary and carrying this
                # build's facts forward exactly as a run-side retry does.
                var built_term = att.bterm
                var built_stderr = att.build_stderr.copy()
                var built_dur = att.bdur
                att = _single_attempt(
                    runtime,
                    config,
                    settings,
                    root,
                    rel,
                    include_paths,
                    out_bin,
                    False,
                    quarantine_dir,
                    pub.argv,
                    built_term,
                    built_stderr,
                    built_dur,
                )

        if att.control == 1:
            var ie_step = String(
                att.internal_event.data[InternalErrorPayload].step
            )
            var ie_errno = att.internal_event.data[InternalErrorPayload].errno
            if (
                (
                    store_hit
                    or (published_store_artifact and ie_errno == _ENOENT)
                )
                and not store_rebuilt
                and ie_step == "run"
            ):
                # The store's binary would not spawn. A warm hit may degrade
                # over any run-spawn failure, as before; a binary this session
                # just published degrades only over ENOENT, the concrete
                # quarantine pathname gap, so an unrelated supervisor failure
                # remains an internal error. This is not a retry:
                # `attempt_index` does not move, no attempt is reported, and
                # the file was already admitted either as a cache hit or its
                # first cold build, so neither counter moves. The key was
                # dropped at the hit or after publication, so the rebuild
                # stages and publishes nothing — it lands in `build/bin` like
                # every uncached build.
                store_hit = False
                published_store_artifact = False
                store_rebuilt = True
                do_build = True
                out_bin = plain_out
                attempt_events.append(
                    Event.warning("cache-rebuild", cache_rebuild_note(rel))
                )
                continue
            _cleanup_quarantine(root, quarantine_dirs)
            return FileResult.internal(att.internal_event.copy())
        if att.control == 2:
            _cleanup_quarantine(root, quarantine_dirs)
            return FileResult.interrupt()

        # Classify the completed attempt's failed step for retry eligibility. An
        # interrupt was already short-circuited above, so `interrupted` is False
        # here — honoring the DEFENSIVE NOTE never to pass interrupted=True
        # without a TimedOut (a TimedOut reaching here is a genuine deadline).
        var rc: RetryClass
        var attempt_passed = False
        if att.build_failed:
            rc = retry_classify("build", att.bterm, False, att.build_stderr)
        else:
            rc = retry_classify("run", att.rterm, False, att.run_stderr)
            attempt_passed = flaky_eligible(att.cls.file_outcome)

        var more_attempts = attempt_index < attempts_planned
        if rc.retry_eligible and more_attempts:
            had_retry = True
            attempt_events.append(
                _make_attempt_finished(
                    rel, rc, att, attempt_index, attempts_planned
                )
            )
            if att.build_failed:
                # A compile kill: the shared module cache MAY be suspect. Warn
                # loudly and run the NEXT rebuild quarantined against a fresh
                # per-attempt cache with a fresh output path.
                attempt_events.append(
                    Event.warning(
                        "compile-kill-residual",
                        _compile_crash_residual("compile", rel, rc, att.bterm),
                    )
                )
                do_build = True
                out_bin = _retry_out_bin(mangled, attempt_index + 1, nonce)
                quarantine_dir = _quarantine_dir(
                    "", mangled, attempt_index + 1, nonce
                )
                _ensure_dir(root + "/" + quarantine_dir)
                quarantine_dirs.append(quarantine_dir)
            else:
                # A run crash: RE-RUN the same already-built binary (no rebuild,
                # no quarantine). Carry the prior build facts forward.
                do_build = False
                quarantine_dir = String("")
                prior_build_argv = att.build_argv.copy()
                prior_bterm = att.bterm
                prior_build_stderr = att.build_stderr.copy()
                prior_bdur = att.bdur
            attempt_index += 1
            continue

        # Final attempt: passed, failed deterministically, or budget exhausted.
        var flaky = had_retry and attempt_passed
        var fr = _finalize_attempt(settings, rel, att^, attempt_index, flaky)
        _cleanup_quarantine(root, quarantine_dirs)
        return _prepend_events(attempt_events^, fr^)
