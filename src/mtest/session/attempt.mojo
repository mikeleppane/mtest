"""One build-run-classify attempt for a file, and the retry loop over it.

Layer 4, the plain (non-selection) run path: `_run_one` spends up to
`config.retries + 1` attempts on one file, each attempt building it under
`--compile-timeout`, executing the binary under the `exec` supervisor, and
resolving and classifying the report its stdout carried. A crash-class ending
with budget left is reported immediately and retried — a build rebuilds
quarantined against a fresh module cache, a run re-runs the same binary — and a
late pass after any retry is flaky.

It sits above `build` (for the compile-spawn policy), `scratch`, `file_result`,
and the classify/clamp/retry/verdict leaves, and below `session`, which drives
it for the gate files and the plain run set. The precompile step reuses its
attempt-event and residual-warning shapes so a session-level step's attempt line
carries the same identity a file build's does.
"""
from mtest.config import RunnerConfig, lossy_utf8
from mtest.exec import (
    ExecRuntime,
    ProcessResult,
    ProcessSpec,
    Termination,
    canonicalize,
    interrupt_requested,
    run_supervised,
)
from mtest.model import (
    Event,
    NodeId,
    Outcome,
    ParseDisposition,
    TestCounts,
    TestResult,
    is_slow,
)
from mtest.protocol import ParsedReport
from mtest.session.build import _COMPILE_GRACE_MS
from mtest.session.clamp import clamp_stream
from mtest.session.classify import (
    Classification,
    TrustedReport,
    classify,
    resolve_report,
)
from mtest.session.file_result import FileResult, _prepend_events
from mtest.session.retry_class import RetryClass, retry_classify
from mtest.session.scratch import (
    _cleanup_quarantine,
    _ensure_dir,
    _invocation_nonce,
    _mangle,
    _quarantine_dir,
    _retry_out_bin,
)
from mtest.session.verdict import build_verdict


comptime _ATTEMPT_STREAM_HEAD = 65536
"""Head bytes of each stream kept in a non-final attempt's excerpt (64 KiB)."""
comptime _ATTEMPT_STREAM_TAIL = 65536
"""Tail bytes of each stream kept in a non-final attempt's excerpt (64 KiB)."""


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
            1,
            e^,
            False,
            List[String](),
            Termination.exited(0),
            List[UInt8](),
            0.0,
            "",
            Termination.exited(0),
            List[UInt8](),
            List[UInt8](),
            0.0,
            TrustedReport(ParsedReport.absent(), False),
            _blank_classification(),
            False,
            False,
        )

    @staticmethod
    def _interrupt() -> Self:
        """An interrupt aborted the attempt: routes the file to exit 2."""
        return Self(
            2,
            Event.file_started(""),
            False,
            List[String](),
            Termination.exited(0),
            List[UInt8](),
            0.0,
            "",
            Termination.exited(0),
            List[UInt8](),
            List[UInt8](),
            0.0,
            TrustedReport(ParsedReport.absent(), False),
            _blank_classification(),
            False,
            False,
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
            0,
            Event.file_started(""),
            True,
            build_argv^,
            bterm,
            build_stderr^,
            bdur,
            out_bin,
            Termination.exited(0),
            List[UInt8](),
            List[UInt8](),
            0.0,
            TrustedReport(ParsedReport.absent(), False),
            _blank_classification(),
            False,
            False,
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
            0,
            Event.file_started(""),
            False,
            List[String](),
            Termination.exited(0),
            List[UInt8](),
            0.0,
            binary,
            rterm,
            run_stdout^,
            run_stderr^,
            rdur,
            TrustedReport(ParsedReport.absent(), False),
            _blank_classification(),
            run_stdout_truncated,
            run_stderr_truncated,
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
) raises -> _AttemptResult:
    """Run one build, run, and classify attempt for `rel`, returning raw facts.

    The retry loop wraps this. When `do_build` is set it builds `rel` into
    `out_bin` under `--compile-timeout`; otherwise it reuses the prior
    successful build's facts and only re-runs `out_bin`, since a run-side retry
    never rebuilds. A cache quarantine applies only when `quarantine_dir` is
    non-empty, which happens on a post-compile-kill rebuild: `MODULAR_CACHE_DIR`
    is set in the build child's own environment (via `spec.env_extra`), so
    mtest's own environment is never touched and concurrent builds cannot
    clobber each other's cache directory. The build and run termination,
    spawn-failure, and in-flight-interrupt short-circuits match the non-retry
    path exactly.

    Args:
        runtime: The exec runtime supervising the build and run spawns.
        config: The resolved runner configuration.
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

    Returns:
        The raw attempt facts, including its control signal.

    Raises:
        Error: If canonicalizing the source path fails. Both `exec` supervisor
            calls are caught here and converted into internal-error attempts
            instead. The caller catches what does escape and resolves exit 3.
    """
    var build_argv = prior_build_argv.copy()
    var bterm = prior_bterm
    var build_stderr = prior_build_stderr.copy()
    var bdur = prior_bdur

    if do_build:
        build_argv = List[String]()
        build_argv.append(config.mojo_path)
        build_argv.append("build")
        build_argv.append(rel)
        build_argv.append("-o")
        build_argv.append(out_bin)
        for p in include_paths:
            build_argv.append("-I")
            build_argv.append(p)
        for a in config.build_args:
            build_argv.append(a)

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
                    build_argv.copy(),
                    root,
                    config.compile_timeout_secs * 1000,
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
                build_argv^, bterm, build_stderr^, bdur, out_bin
            )

    # Build OK (or reused from a prior successful build): run the binary. A
    # run-phase machinery raise attributes to the RUN step and names the binary.
    var run_argv = List[String]()
    run_argv.append(out_bin)
    var rres: ProcessResult
    try:
        rres = run_supervised(
            runtime,
            ProcessSpec.command_in(run_argv^, root, config.timeout_secs * 1000),
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
    var source_path = canonicalize(root + "/" + rel)
    var stdout_text = lossy_utf8(rres.stdout_bytes)
    var trusted = resolve_report(
        stdout_text, source_path, rres.stdout_truncated
    )
    var cls = classify(rterm, trusted.report, trusted.is_overflow)

    return _AttemptResult(
        0,
        Event.file_started(""),
        False,
        build_argv^,
        bterm,
        build_stderr^,
        bdur,
        out_bin,
        rterm,
        rres.stdout_bytes.copy(),
        rres.stderr_bytes.copy(),
        rdur,
        trusted^,
        cls^,
        rres.stdout_truncated,
        rres.stderr_truncated,
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
    config: RunnerConfig,
    rel: String,
    var att: _AttemptResult,
    attempts_used: Int,
    flaky: Bool,
) -> FileResult:
    """Build the file's terminal `FileResult` from its last attempt.

    Mirrors the non-retry verdict construction, then threads `attempts_used`
    and, for a late pass after a crash-class attempt, the flaky outcome and
    flag.

    Args:
        config: The resolved runner configuration, for the deadline values the
            verdict banner reports.
        rel: The root-relative path of the file.
        att: The last attempt, consumed for its streams and classification.
        attempts_used: How many attempts the file spent.
        flaky: Whether this attempt passed only after a crash-class attempt.

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
            bto = config.compile_timeout_secs
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
        timeout_seconds = config.timeout_secs
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


def _flaky_eligible(file_outcome: Outcome) -> Bool:
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
    root: String,
    rel: String,
    include_paths: List[String],
) raises -> FileResult:
    """Build `rel`, execute it, and retry a crash-class failure up to budget.

    Runs up to `config.retries + 1` attempts through `_single_attempt`. An
    attempt that passes, or fails deterministically with a real failure, a
    compile error, or a flooded capture, is final. A crash-class failure with
    attempts remaining is reported immediately as an `AttemptFinished` and
    retried: a crash-class build failure rebuilds quarantined against a fresh
    cache and emits a residual-risk warning, while a crash-class run failure
    re-runs the same binary. If the final attempt passes after any retry the
    file is flaky. An interrupt is short-circuited before the retry decision and
    so is never retried, and an unset `--retries` runs exactly one attempt.

    Args:
        runtime: The exec runtime supervising the build and run spawns.
        config: The resolved runner configuration, including the retry budget.
        root: The invocation root the child processes run in.
        rel: The root-relative path of the file to build and run.
        include_paths: Directories passed to the compiler as `-I`.

    Returns:
        The file's terminal result, with each non-final attempt's events
        prepended.

    Raises:
        Error: If a build or quarantine directory cannot be made, or if an
            attempt's source canonicalization fails. Both `exec` supervisor
            calls are caught inside `_single_attempt` and become internal-error
            attempts rather than raises. The caller catches what does escape and
            resolves exit 3.
    """
    _ensure_dir(root + "/build/bin")
    var mangled = _mangle(rel)
    var nonce = _invocation_nonce()
    var attempts_planned = config.retries + 1

    # AttemptFinished (+ any compile-kill warning) for each NON-final attempt,
    # in order; prepended to the final FileResult so the reporter renders each
    # the moment its attempt completed, before the file's verdict.
    var attempt_events = List[Event]()
    var quarantine_dirs = List[String]()
    var had_retry = False

    var do_build = True
    var quarantine_dir = String("")
    var out_bin = String("build/bin/") + mangled
    var prior_build_argv = List[String]()
    var prior_bterm = Termination.exited(0)
    var prior_build_stderr = List[UInt8]()
    var prior_bdur = 0.0

    var attempt_index = 1
    while True:
        var att = _single_attempt(
            runtime,
            config,
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
        )
        if att.control == 1:
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
            attempt_passed = _flaky_eligible(att.cls.file_outcome)

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
        var fr = _finalize_attempt(config, rel, att^, attempt_index, flaky)
        _cleanup_quarantine(root, quarantine_dirs)
        return _prepend_events(attempt_events^, fr^)
