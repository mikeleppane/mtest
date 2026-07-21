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
from std.builtin.sort import sort
from std.os import getenv, setenv
from std.os.path import basename, dirname, exists, isdir
from std.time import perf_counter_ns

from mtest.cache import BuildProduct, BuildRegistry
from mtest.config import RunnerConfig, lossy_utf8
from mtest.discover import discover, normalize_operand, normalize_root
from mtest.discover.result import DiscoveryResult
from mtest.exec import (
    ExecRuntime,
    ProcessResult,
    ProcessSpec,
    Termination,
    canonicalize,
    interrupt_requested,
    rename_path,
    run_supervised,
)
from mtest.model import (
    AttributionDisposition,
    Event,
    NodeId,
    Outcome,
    ParseDisposition,
    Summary,
    TerminalFacts,
    TestCounts,
    TestResult,
    EXIT_FAILURE,
    EXIT_NOTHING_RAN,
    EXIT_SUCCESS,
    exit_code_for,
    is_slow,
    resolve_exit_code,
)
from mtest.protocol import (
    ParsedReport,
    ParsedRow,
    ReportVerdict,
    collection_disqualifier,
    collection_names,
)
from mtest.report import ReportCoordinator
from mtest.select import (
    FileIntent,
    NamedTarget,
    OperandParse,
    parse_operands,
    select_from,
    selection_active,
)
from mtest.session.attribution import attribution_step, isolation_timeout_secs
from mtest.session.classify import (
    Classification,
    TrustedReport,
    classify,
    resolve_report,
)
from mtest.session.clamp import clamp_stream
from mtest.session.retry_class import RetryClass, retry_classify
from mtest.session.scratch import (
    _cleanup_quarantine,
    _discard_path,
    _ensure_dir,
    _invocation_nonce,
    _mangle,
    _precompile_temp_path,
    _quarantine_dir,
    _restore_cache_env,
    _retry_out_bin,
)
from mtest.session.shard import partition
from mtest.session.verdict import build_verdict

comptime _ATTEMPT_STREAM_HEAD = 65536
"""Head bytes of each stream kept in a non-final attempt's excerpt (64 KiB)."""
comptime _ATTEMPT_STREAM_TAIL = 65536
"""Tail bytes of each stream kept in a non-final attempt's excerpt (64 KiB)."""

comptime _COMPILE_GRACE_MS = 5000
"""SIGTERM-to-SIGKILL grace for a build killed at `--compile-timeout` (5 s).

Much wider than the run path's 300 ms because a compiler may be mid-write to
the shared module cache; killing it early is the most plausible way to leave
that cache torn. Five seconds lets it unwind and flush. A compiler still alive
after that has ignored SIGTERM and is SIGKILLed, which is when the narrow cache
quarantine on the retry rebuild earns its keep.
"""

comptime _STALE_NAME_PHRASE = "test not found in suite:"
"""The stdlib phrase when `--only` names a test the suite no longer offers."""

comptime _UNHANDLED_PREFIX = "Unhandled exception caught during execution:"
"""The runtime framing that carries a stale-name refusal as its payload.

A stale-name refusal aborts the suite before any report is printed, so the
stdlib emits the phrase as this line's payload — e.g. `Unhandled exception
caught during execution: explicitly allowed test not found in suite: test_x`.
Anchoring stale-name detection on this framing keeps a test that merely prints
the phrase in its own output from tripping a wasted rebuild and reprobe."""


@fieldwise_init
struct FileResult(Copyable, Movable):
    """The outcome of building and running one file, plus its control signals.

    Owns its lists and its event; copies are explicit.

    A completed file emits its `pre_events` in order, then its `event`. The
    session accumulates `test_counts` unconditionally, adding it before it
    inspects `is_drift`. A non-drift file also tallies `outcome` once in the
    summary and appends `exit_outcomes` to the run outcomes. A drift file emits
    its events and forces exit 3; drift suppresses the file-level outcome and
    exit-outcome tally, not the per-test totals.
    `internal_error` and `interrupted` are mutually exclusive short-circuits:
    the session emits `event` (for an internal error) and resolves the exit code
    (3 or 2) directly.
    """

    var pre_events: List[Event]
    """Events to emit before `event`: per-test `TestReported` rows, then a loud
    `Warning` when the classification demands one (empty otherwise)."""
    var event: Event
    """The event to emit: a `FileFinished` verdict when `ran`, an
    `InternalError` diagnostic when `internal_error`."""
    var outcome: Outcome
    """The file-level outcome to tally once (only meaningful when `ran`)."""
    var exit_outcomes: List[Outcome]
    """The exit-code multiset contribution: per-test for a valid report, else a
    single file-level entry; empty for a drift file."""
    var test_counts: TestCounts
    """The per-test passed/failed/skipped tally to accumulate run-wide."""
    var ran: Bool
    """Whether the file produced a real verdict to emit and tally."""
    var internal_error: Bool
    """Whether a spawn failure occurred (routes to internal-error exit 3)."""
    var interrupted: Bool
    """Whether an interrupt aborted this file (routes to exit 2)."""
    var is_drift: Bool
    """Whether the report drifted off the pinned grammar (forces exit 3)."""
    var binary_path: String
    """The binary this file's run actually executed, or empty when none ran.

    Carried so the crash-attribution post-pass can rerun that exact binary
    rather than reconstruct a name for it: a crash-class build retry rebuilds to
    `build/bin/<mangled>.inv-<nonce>.attempt-N` and runs that, so the mangled
    name is not always the thing that crashed. Diagnostics only; no verdict
    reads it."""

    @staticmethod
    def ran_with(var event: Event, outcome: Outcome) -> Self:
        """Build a completed file whose only multiset entry is its own outcome.

        Used by the build compile-error path, which has no per-test report.

        Args:
            event: The `FileFinished` verdict to emit. Consumed; the returned
                `FileResult` owns it.
            outcome: The file-level outcome, tallied and used as the sole
                exit-code multiset entry.

        Returns:
            The completed `FileResult`.
        """
        return Self(
            List[Event](),
            event^,
            outcome,
            [outcome],
            TestCounts.zeros(),
            True,
            False,
            False,
            False,
            "",
        )

    @staticmethod
    def classified(
        var pre_events: List[Event],
        var event: Event,
        outcome: Outcome,
        var exit_outcomes: List[Outcome],
        test_counts: TestCounts,
        is_drift: Bool,
    ) -> Self:
        """Build a completed run carrying per-test events and exit outcomes.

        Args:
            pre_events: Per-test rows and any warning, emitted before `event`.
                Consumed; the returned `FileResult` owns it.
            event: The `FileFinished` verdict to emit. Consumed; the returned
                `FileResult` owns it.
            outcome: The file-level outcome to tally once.
            exit_outcomes: The exit-code multiset contribution. Consumed; the
                returned `FileResult` owns it.
            test_counts: The per-test passed/failed/skipped tally.
            is_drift: Whether the report drifted off the pinned grammar, which
                forces exit 3 and suppresses tallying.

        Returns:
            The completed `FileResult`.
        """
        return Self(
            pre_events^,
            event^,
            outcome,
            exit_outcomes^,
            test_counts,
            True,
            False,
            False,
            is_drift,
            "",
        )

    @staticmethod
    def internal(var event: Event) -> Self:
        """Build a spawn failure: no verdict, and the session exits 3.

        Args:
            event: The `InternalError` diagnostic to emit. Consumed; the
                returned `FileResult` owns it.

        Returns:
            The internal-error `FileResult`.
        """
        return Self(
            List[Event](),
            event^,
            Outcome.NOT_RUN,
            List[Outcome](),
            TestCounts.zeros(),
            False,
            True,
            False,
            False,
            "",
        )

    @staticmethod
    def interrupt() -> Self:
        """Build an interrupted file: no verdict, and the session exits 2.

        Returns:
            The interrupted `FileResult`.
        """
        return Self(
            List[Event](),
            Event.file_started(""),
            Outcome.NOT_RUN,
            List[Outcome](),
            TestCounts.zeros(),
            False,
            False,
            True,
            False,
            "",
        )


@fieldwise_init
struct PrecompileResult(Copyable, Movable):
    """The outcome of one precompile step, plus its control signals.

    On success `ok` is set and `out_dir` is the include directory added to every
    subsequent build. On failure `compiler_output` holds the captured compiler
    output, and `term`/`timeout_seconds` carry how the final attempt ended so
    the banner can name that ending in words. `internal_error` and `interrupted`
    short-circuit as in `FileResult`. The caller emits `events` in order before
    acting on the outcome.
    """

    var out_dir: String
    """The output directory to add to the include set on success."""
    var compiler_output: String
    """The captured compiler output on a failed step."""
    var ok: Bool
    """Whether the step built cleanly."""
    var internal_error: Bool
    """Whether a spawn failure occurred (routes to internal-error exit 3)."""
    var interrupted: Bool
    """Whether an interrupt aborted the step (routes to exit 2)."""
    var errno: Int
    """The spawn errno on an internal error, so the diagnostic names the real
    cause (e.g. ENOENT for a nonexistent compiler); 0 otherwise."""
    var program: String
    """The program the step tried to spawn on an internal error, else empty."""
    var events: List[Event]
    """The step's attempt events and warnings, in emission order."""
    var term: Termination
    """The final attempt's raw termination (meaningful on a failed step)."""
    var timeout_seconds: Int
    """The compile deadline mtest enforced, for a step killed at it; else 0."""
    var attempts_used: Int
    """How many attempts the step spent (1 when it ran once with no retry)."""
    var ending_known: Bool
    """Whether `term` is the real ending of a compiler that ran and failed.

    False when the step failed for a reason the compiler never expressed, such
    as a failed promotion where the compiler exited 0 and only the rename lost.
    The banner then says nothing about an ending rather than reporting `term`'s
    Exited(0) as "exited 0" on a step that failed."""

    @staticmethod
    def _blank() -> Self:
        """Return a result with every field at its neutral value."""
        return Self(
            "",
            "",
            False,
            False,
            False,
            0,
            "",
            List[Event](),
            Termination.exited(0),
            0,
            1,
            False,
        )

    @staticmethod
    def interrupt(var events: List[Event]) -> Self:
        """Build an interrupted step, which routes the session to exit 2.

        Args:
            events: The step's events, emitted before the session exits.
                Consumed; the returned `PrecompileResult` owns them.

        Returns:
            The interrupted `PrecompileResult`.
        """
        var r = Self._blank()
        r.interrupted = True
        r.events = events^
        return r^

    @staticmethod
    def internal(errno: Int, program: String, var events: List[Event]) -> Self:
        """Build a spawn failure, which routes the session to exit 3.

        Args:
            errno: The spawn errno, so the diagnostic names the real cause.
            program: The program that could not be spawned.
            events: The step's events, emitted before the session exits.
                Consumed; the returned `PrecompileResult` owns them.

        Returns:
            The internal-error `PrecompileResult`.
        """
        var r = Self._blank()
        r.internal_error = True
        r.errno = errno
        r.program = program
        r.events = events^
        return r^

    @staticmethod
    def success(
        out_dir: String, var events: List[Event], attempts_used: Int
    ) -> Self:
        """Build a successful step whose `out_dir` widens the include set.

        Args:
            out_dir: The directory holding the promoted package.
            events: The step's events, emitted before the session continues.
                Consumed; the returned `PrecompileResult` owns them.
            attempts_used: How many attempts the step spent.

        Returns:
            The successful `PrecompileResult`.
        """
        var r = Self._blank()
        r.ok = True
        r.out_dir = out_dir
        r.events = events^
        r.attempts_used = attempts_used
        return r^

    @staticmethod
    def failure(
        compiler_output: String,
        var events: List[Event],
        term: Termination,
        timeout_seconds: Int,
        attempts_used: Int,
    ) -> Self:
        """Build a failed step, reported as a precompile error and exit 1.

        Args:
            compiler_output: The captured compiler output for the banner.
            events: The step's events, emitted before the session exits.
                Consumed; the returned `PrecompileResult` owns them.
            term: How the compiler ended, so the banner names that ending.
            timeout_seconds: The compile deadline enforced, when the step was
                killed at it; 0 otherwise.
            attempts_used: How many attempts the step spent.

        Returns:
            The failed `PrecompileResult`, with `ending_known` set.
        """
        var r = Self._blank()
        r.compiler_output = compiler_output
        r.events = events^
        r.term = term
        r.timeout_seconds = timeout_seconds
        r.attempts_used = attempts_used
        r.ending_known = True
        return r^

    @staticmethod
    def promotion_failure(
        compiler_output: String, var events: List[Event], attempts_used: Int
    ) -> Self:
        """Build a step where the compiler succeeded but promotion failed.

        Still a precompile error at exit 1, since no package was published, but
        there is no compiler ending to name: the attempt exited 0. Leaving
        `ending_known` False keeps the banner from reporting "exited 0" on a
        failed step and sends the reader to `compiler_output`, which explains
        that the rename lost and that the output directory was left untouched.

        Args:
            compiler_output: The captured output explaining the failed rename.
            events: The step's events, emitted before the session exits.
                Consumed; the returned `PrecompileResult` owns them.
            attempts_used: How many attempts the step spent.

        Returns:
            The failed `PrecompileResult`, with `ending_known` left False.
        """
        var r = Self._blank()
        r.compiler_output = compiler_output
        r.events = events^
        r.attempts_used = attempts_used
        return r^


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
    is pointed at that fresh directory around the build spawn and restored
    immediately after. The session is single-threaded, so mutating mtest's own
    environment is safe. The build and run termination, spawn-failure, and
    in-flight-interrupt short-circuits match the non-retry path exactly.

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
        Error: If restoring `MODULAR_CACHE_DIR` after a quarantined build
            fails, or if canonicalizing the source path fails. Both `exec`
            supervisor calls are caught here and converted into internal-error
            attempts instead. The caller catches what does escape and resolves
            exit 3.
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
        var quarantined = quarantine_dir != ""
        var prev_cache = getenv("MODULAR_CACHE_DIR", "")
        var had_prev = prev_cache != ""
        if quarantined:
            _ = setenv("MODULAR_CACHE_DIR", quarantine_dir, True)

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
                ),
            )
        except:
            if quarantined:
                _restore_cache_env(had_prev, prev_cache)
            return _AttemptResult._internal(
                Event.internal_error("build", config.mojo_path, 0)
            )
        if quarantined:
            _restore_cache_env(had_prev, prev_cache)

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
            attempt's cache-environment restore or source canonicalization
            fails. Both `exec` supervisor calls are caught inside
            `_single_attempt` and become internal-error attempts rather than
            raises. The caller catches what does escape and resolves exit 3.
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


# --- The SELECTION pipeline: probe -> select -> run -> reconcile. -------------


def _str_in(items: List[String], needle: String) -> Bool:
    """Whether `needle` equals any element of `items`."""
    for x in items:
        if x == needle:
            return True
    return False


def _select_names(names: List[String], selected: List[String]) -> List[String]:
    """Restrict `names` to `selected`, giving attribution's isolation set.

    Crash attribution reruns a crashed file's tests one at a time to name the
    culprit. Under `-k` or `--only` the file's full test universe was probed,
    but only the selected subset actually ran, and isolating a deselected test
    could name a culprit in code the user never invoked. An empty `selected`
    means no selection is active, so every name is a candidate.

    Args:
        names: The file's probed test names, in source order.
        selected: The names that actually ran, or empty when no selection is
            active.

    Returns:
        The candidate names, in the source order given by `names`.
    """
    if len(selected) == 0:
        return names.copy()
    var kept = List[String]()
    for n in names:
        if _str_in(selected, n):
            kept.append(n)
    return kept^


def _same_set(a: List[String], b: List[String]) -> Bool:
    """Whether `a` and `b` hold the same set of names (order-independent)."""
    if len(a) != len(b):
        return False
    for x in a:
        if not _str_in(b, x):
            return False
    return True


def _has_stale_name_diagnostic(text: String) -> Bool:
    """Whether `text` carries the stdlib's anchored stale-name refusal.

    A refusal is recognized only on a line that both opens with the
    `Unhandled exception caught during execution:` prefix and carries the
    `test not found in suite:` phrase. Requiring both keeps a test that merely
    prints the phrase in its own output, or in an assertion detail on some other
    line, from being mistaken for a refusal.

    Args:
        text: The captured output to scan, line by line.

    Returns:
        True when some line matches both the prefix and the phrase.
    """
    for line in text.split("\n"):
        var l = String(line)
        if l.startswith(_UNHANDLED_PREFIX) and (_STALE_NAME_PHRASE in l):
            return True
    return False


def _failing_count(outcomes: List[Outcome]) -> Int:
    """Count the failing-class entries in a run-outcome multiset.

    `outcomes` is already test-granular — per-test for a valid report, one
    file-level entry otherwise — so this is exactly the `--maxfail` counter:
    each element counts once, with no re-derivation from file-level outcomes.

    Args:
        outcomes: The accumulated run-outcome multiset.

    Returns:
        How many entries are failing-class."""
    var n = 0
    for o in outcomes:
        if o.is_failing():
            n += 1
    return n


def _intent_for(
    rel: String, plan: OperandParse, nroot: String
) raises -> FileIntent:
    """Resolve one discovered file's selection intent from the operand plan.

    A file is whole when no node id was given at all, or when a plain file or
    directory operand covered it, since a plain operand always beats a node id.
    Otherwise its intent is the union of the test names every node-id operand
    attached to it.

    Args:
        rel: The root-relative path of the discovered file.
        plan: The parsed operands, carrying plain operands and named targets.
        nroot: The normalized invocation root operands resolve against.

    Returns:
        The file's intent: whole-file, or the named subset.

    Raises:
        Error: If an operand cannot be normalized against `nroot`.
    """
    if not plan.has_node_id:
        return FileIntent.whole_file()
    for p in plan.plain_operands:
        var rp = normalize_operand(p, nroot)
        if rp == "":
            return FileIntent.whole_file()  # the root itself covers everything
        var abs_p = nroot + "/" + rp
        if isdir(abs_p):
            if rel == rp or rel.startswith(rp + "/"):
                return FileIntent.whole_file()
        elif rel == rp:
            return FileIntent.whole_file()
    var names = List[String]()
    for t in plan.named_targets:
        var trp = normalize_operand(t.file_part, nroot)
        if trp == rel and not _str_in(names, t.name):
            names.append(String(t.name))
    if len(names) > 0:
        return FileIntent.named(names^)
    return FileIntent.whole_file()


@fieldwise_init
struct _BuildOutcome(Copyable, Movable):
    """The result of building one file into the registry for selection."""

    var ok: Bool
    """Whether the binary is ready (`binary`/`canonical` valid)."""
    var binary: String
    """The built binary path when `ok`."""
    var canonical: String
    """The canonical source path when `ok`."""
    var build_argv: List[String]
    """The build command, for a terminal file_finished's reproduce line."""
    var bdur: Float64
    """The build wall time in seconds."""
    var terminal: Bool
    """Whether a terminal `FileResult` was produced (compile error/internal)."""
    var result: FileResult
    """The terminal `FileResult` to replay when `terminal`."""


def _blank_file_result() -> FileResult:
    """A placeholder `FileResult` for the non-terminal `_BuildOutcome` path."""
    return FileResult.interrupt()


def _build_for_selection(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    rel: String,
    include_paths: List[String],
    mut reg: BuildRegistry,
) raises -> _BuildOutcome:
    """Build `rel` into the registry once, or produce a terminal result.

    A compile error records a compile-error entry and returns a terminal
    compile-error result; a spawn or machinery failure returns a terminal
    internal-error result; an interrupt returns a terminal interrupt. On success
    the registry holds the fresh build, and the binary and canonical paths ride
    back for the probe and the run to share.

    Args:
        runtime: The exec runtime supervising the build spawn.
        config: The resolved runner configuration.
        root: The invocation root the compiler runs in.
        rel: The root-relative path of the file to build.
        include_paths: Directories passed to the compiler as `-I`.
        reg: The build registry that records the build or compile error.

    Returns:
        The build outcome, terminal or ready-to-probe.

    Raises:
        Error: If the build output directory cannot be made, or if
            canonicalizing the source path after a successful build fails. The
            registry writes are non-raising, and the build spawn is caught here
            and turned into a terminal internal-error result.
    """
    _ensure_dir(root + "/build/bin")
    var mangled = _mangle(rel)
    var out_bin = String("build/bin/") + mangled
    var build_argv = List[String]()
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

    var bres: ProcessResult
    try:
        bres = run_supervised(
            runtime,
            ProcessSpec.command_in(
                build_argv.copy(),
                root,
                config.compile_timeout_secs * 1000,
                _COMPILE_GRACE_MS,
            ),
        )
    except:
        return _BuildOutcome(
            False,
            "",
            "",
            List[String](),
            0.0,
            True,
            FileResult.internal(
                Event.internal_error("build", config.mojo_path, 0)
            ),
        )
    var bdur = Float64(bres.duration_ms) / 1000.0
    if interrupt_requested():
        return _BuildOutcome(
            False, "", "", List[String](), 0.0, True, FileResult.interrupt()
        )
    var bterm = bres.termination
    if bterm.is_spawn_failed():
        return _BuildOutcome(
            False,
            "",
            "",
            List[String](),
            0.0,
            True,
            FileResult.internal(
                Event.internal_error("build", config.mojo_path, bterm.value)
            ),
        )
    var bsignal = build_verdict(bterm)
    if bsignal.is_failing():
        # COMPILE_ERROR, or COMPILE_TIMEOUT when `--compile-timeout` killed the
        # build. Either way the file is terminal here and never probed or run.
        var bto = 0
        if bsignal == Outcome.COMPILE_TIMEOUT:
            bto = config.compile_timeout_secs
        reg.record_compile_error(rel, lossy_utf8(bres.stderr_bytes))
        var ev = Event.file_finished(
            rel,
            bsignal,
            0.0,
            build_argv.copy(),
            bdur,
            List[UInt8](),
            bres.stderr_bytes.copy(),
            timeout_seconds=bto,
            slow=is_slow(bdur, 0.0),
        )
        return _BuildOutcome(
            False,
            "",
            "",
            build_argv^,
            bdur,
            True,
            FileResult.ran_with(ev^, bsignal),
        )
    var canonical = canonicalize(root + "/" + rel)
    reg.record_build(BuildProduct.built(rel, out_bin, canonical))
    return _BuildOutcome(
        True, out_bin, canonical, build_argv^, bdur, False, _blank_file_result()
    )


@fieldwise_init
struct _ProbeOutcome(Copyable, Movable):
    """The result of probing one built file with `--skip-all`."""

    var qualified: Bool
    """Whether the probe read as a collection listing (universe is valid)."""
    var universe: List[String]
    """The collected test names, in discovery order (when qualified)."""
    var terminal: Bool
    """Whether a terminal `FileResult` was produced, for a crash, timeout,
    malformed suite, drift, capture overflow, spawn failure, or interrupt."""
    var result: FileResult
    """The terminal `FileResult` to replay when `terminal`."""
    var internal_error: Bool
    """Whether the probe could not spawn the binary (routes to exit 3)."""
    var interrupted: Bool
    """Whether an interrupt aborted the probe (routes to exit 2)."""


def _probe_terminal(
    rel: String,
    outcome: Outcome,
    disposition: ParseDisposition,
    warning_kind: String,
    warning_detail: String,
    build_argv: List[String],
    bdur: Float64,
    var stdout_bytes: List[UInt8],
    var stderr_bytes: List[UInt8],
    is_drift: Bool,
    signal_number: Int = 0,
    timeout_seconds: Int = 0,
    escalated: Bool = False,
    stdout_truncated: Bool = False,
    stderr_truncated: Bool = False,
) -> FileResult:
    """Build a file-level terminal result for a probe that did not qualify.

    Args:
        rel: The root-relative path of the probed file.
        outcome: The file-level outcome the probe resolved to.
        disposition: How the probe's stdout parsed.
        warning_kind: The warning to emit before the verdict, or empty for none.
        warning_detail: The warning's detail text.
        build_argv: The build command, for the verdict's reproduce line.
        bdur: The build wall time in seconds.
        stdout_bytes: The probe's captured stdout. Consumed; it moves into the
            emitted `FileFinished`.
        stderr_bytes: The probe's captured stderr. Consumed; it moves into the
            emitted `FileFinished`.
        is_drift: Whether the probe drifted off the pinned grammar, which
            suppresses the exit-outcome contribution.
        signal_number: The signal that killed the probe, for a crash.
        timeout_seconds: The deadline enforced, for a timeout.
        escalated: The probe termination's latched SIGKILL escalation, passed by
            the timeout caller so a probe killed at the deadline reads like
            every other timeout verdict.
        stdout_truncated: Whether the probe's stdout capture overflowed. The
            probe genuinely executes the file's binary, so this is real
            truncation of that file's run.
        stderr_truncated: Whether the probe's stderr capture overflowed.

    Returns:
        The terminal `FileResult`.
    """
    var pre = List[Event]()
    if warning_kind != "":
        pre.append(Event.warning(warning_kind, warning_detail))
    var ev = Event.file_finished(
        rel,
        outcome,
        0.0,
        build_argv.copy(),
        bdur,
        stdout_bytes^,
        stderr_bytes^,
        signal_number=signal_number,
        timeout_seconds=timeout_seconds,
        parse_disposition=disposition,
        escalated=escalated,
        slow=is_slow(bdur, 0.0),
        stdout_truncated=stdout_truncated,
        stderr_truncated=stderr_truncated,
    )
    var exits = List[Outcome]()
    if not is_drift:
        exits.append(outcome)
    return FileResult.classified(
        pre^, ev^, outcome, exits^, TestCounts.zeros(), is_drift
    )


def _probe_file(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    rel: String,
    binary: String,
    canonical: String,
    build_argv: List[String],
    bdur: Float64,
    mut reg: BuildRegistry,
) raises -> _ProbeOutcome:
    """Run the `--skip-all` probe and route its result.

    Termination handling is total, mirroring `_run_one`'s run-phase policy so a
    probe never resolves differently than the default path would: a spawn
    failure is an internal error (exit 3); an interrupt-induced timeout is an
    interrupt (exit 2); a signaled probe is that file's crash; a plain timeout
    is a timeout. On a clean exit the captured stdout is decoded and resolved
    under the same truncation policy the run path uses (`resolve_report`), so
    only a report wholly retained in the tail is trusted and a forged report in
    a truncated head is refused as capture overflow — a failing outcome, never a
    qualifying listing.

    A qualifying probe yields the universe as its collection listing, recorded
    in the registry. An off-grammar probe is drift (exit 3); a capture-overflow
    probe is `CAPTURE_OVERFLOW` (exit-1 class); an absent, ambiguous, or valid
    but disqualified probe is `MALFORMED_SUITE`, meaning the module ran bodies
    or ignored `--skip-all`.

    Args:
        runtime: The exec runtime supervising the probe spawn.
        config: The resolved runner configuration, for the run deadline.
        root: The invocation root the probe runs in.
        rel: The root-relative path of the probed file.
        binary: The already-built binary to probe.
        canonical: The canonical source path the report must name.
        build_argv: The build command, for a terminal verdict's reproduce line.
        bdur: The build wall time in seconds.
        reg: The build registry that records the collected universe.

    Returns:
        The probe outcome: a qualifying universe, or a terminal result.

    Raises:
        Error: If the `exec` machinery itself fails or the registry write fails.
    """
    var argv = List[String]()
    argv.append(binary)
    argv.append("--skip-all")
    var pres = run_supervised(
        runtime, ProcessSpec.command_in(argv^, root, config.timeout_secs * 1000)
    )
    var pterm = pres.termination
    if pterm.is_spawn_failed():
        # Could not spawn the freshly built binary: a machinery diagnostic, not
        # a verdict — routed to the internal-error exit code, exactly as the run
        # path's spawn-failure handling does.
        return _ProbeOutcome(
            False,
            List[String](),
            True,
            FileResult.internal(
                Event.internal_error("probe", binary, pterm.value)
            ),
            True,
            False,
        )
    # An in-flight interrupt returns as TimedOut; never record it as a TIMEOUT.
    if pterm.is_timed_out() and interrupt_requested():
        return _ProbeOutcome(
            False, List[String](), True, FileResult.interrupt(), False, True
        )
    if pterm.is_signaled():
        return _ProbeOutcome(
            False,
            List[String](),
            True,
            _probe_terminal(
                rel,
                Outcome.CRASH,
                ParseDisposition.NO_REPORT,
                "",
                "",
                build_argv,
                bdur,
                pres.stdout_bytes.copy(),
                pres.stderr_bytes.copy(),
                False,
                signal_number=pterm.value,
                stdout_truncated=pres.stdout_truncated,
                stderr_truncated=pres.stderr_truncated,
            ),
            False,
            False,
        )
    if pterm.is_timed_out():
        return _ProbeOutcome(
            False,
            List[String](),
            True,
            _probe_terminal(
                rel,
                Outcome.TIMEOUT,
                ParseDisposition.NO_REPORT,
                "",
                "",
                build_argv,
                bdur,
                pres.stdout_bytes.copy(),
                pres.stderr_bytes.copy(),
                False,
                timeout_seconds=config.timeout_secs,
                escalated=pterm.escalated,
                stdout_truncated=pres.stdout_truncated,
                stderr_truncated=pres.stderr_truncated,
            ),
            False,
            False,
        )

    # Clean exit: resolve WHICH report to trust under capture overflow before
    # consulting it. A truncated capture that kept no valid block in its tail is
    # refused as overflow — a forged all-SKIP report in the retained head must
    # never qualify as a collection listing.
    var trusted = resolve_report(
        lossy_utf8(pres.stdout_bytes), canonical, pres.stdout_truncated
    )
    if trusted.is_overflow:
        return _ProbeOutcome(
            False,
            List[String](),
            True,
            _probe_terminal(
                rel,
                Outcome.FAIL,
                ParseDisposition.CAPTURE_OVERFLOW,
                "capture-overflow",
                (
                    "the --skip-all probe's stdout overflowed the capture bound"
                    " and no complete report survived in the retained tail"
                    " (look for the '[mtest: output truncated' marker); reduce"
                    " the probe's output or raise the capture bound"
                ),
                build_argv,
                bdur,
                pres.stdout_bytes.copy(),
                pres.stderr_bytes.copy(),
                False,
                stdout_truncated=pres.stdout_truncated,
                stderr_truncated=pres.stderr_truncated,
            ),
            False,
            False,
        )

    var report = trusted.report.copy()
    var disq = collection_disqualifier(report)
    if disq == "":
        var universe = collection_names(report)
        var listing = List[String]()
        for nm in universe:
            listing.append(rel + "::" + nm)
        reg.record_probe(rel, True, listing^)
        return _ProbeOutcome(
            True, universe^, False, _blank_file_result(), False, False
        )

    if report.verdict == ReportVerdict.OFF_GRAMMAR:
        return _ProbeOutcome(
            False,
            List[String](),
            True,
            _probe_terminal(
                rel,
                Outcome.NOT_RUN,
                ParseDisposition.DRIFT,
                "drift",
                (
                    "the --skip-all probe drifted off the pinned grammar ("
                    + report.reason
                    + "); check the toolchain pin and tests/snapshots/protocol/"
                ),
                build_argv,
                bdur,
                pres.stdout_bytes.copy(),
                pres.stderr_bytes.copy(),
                True,
                stdout_truncated=pres.stdout_truncated,
                stderr_truncated=pres.stderr_truncated,
            ),
            False,
            False,
        )
    return _ProbeOutcome(
        False,
        List[String](),
        True,
        _probe_terminal(
            rel,
            Outcome.MALFORMED_SUITE,
            ParseDisposition.NO_REPORT,
            "malformed-suite",
            (
                "the --skip-all probe did not read as a collection listing ("
                + disq
                + "); a conforming module lists its tests as all-SKIP under"
                " --skip-all"
            ),
            build_argv,
            bdur,
            pres.stdout_bytes.copy(),
            pres.stderr_bytes.copy(),
            False,
            stdout_truncated=pres.stdout_truncated,
            stderr_truncated=pres.stderr_truncated,
        ),
        False,
        False,
    )


@fieldwise_init
struct _Collected(Copyable, Movable):
    """One file after the build, probe, and select pass: terminal or runnable.

    Owns its lists and its terminal result; copies are explicit.
    """

    var rel: String
    var terminal: Bool
    var terminal_result: FileResult
    var universe: List[String]
    var selected: List[String]
    var deselected: List[String]
    var intent: FileIntent
    var binary: String
    var canonical: String
    var build_argv: List[String]
    var bdur: Float64


def _selected_view(
    var rows: List[ParsedRow], selected: List[String]
) -> ParsedReport:
    """Build a synthetic valid report of the selected rows, tallies recomputed.

    The child under `--only` reports every test, marking non-selected ones as
    skipped. The classifier must see only the selected rows so the file verdict
    and exit-code contribution reflect the selection rather than the suppressed
    deselections.

    Args:
        rows: The full report's rows. Consumed; the kept rows move into the
            returned report.
        selected: The names that were actually selected.

    Returns:
        A valid `ParsedReport` over the selected rows alone.
    """
    var kept = List[ParsedRow]()
    var p = 0
    var f = 0
    var s = 0
    for r in rows:
        if _str_in(selected, r.name):
            if r.outcome == Outcome.PASS:
                p += 1
            elif r.outcome == Outcome.FAIL:
                f += 1
            elif r.outcome == Outcome.SKIP:
                s += 1
            kept.append(r.copy())
    return ParsedReport.valid(kept^, len(kept), p, f, s, f > 0)


def _reconcile_and_classify(
    config: RunnerConfig,
    rel: String,
    term: ProcessResult,
    universe: List[String],
    selected: List[String],
    deselected: List[String],
    build_argv: List[String],
    bdur: Float64,
    canonical: String,
    attempts_used: Int = 1,
    flaky_if_pass: Bool = False,
) -> FileResult:
    """Reconcile a completed selection run against the universe and classify.

    A crash or timeout is that file's abnormal outcome. Otherwise the report
    must be valid and its row set must equal the universe, and every
    non-selected row must be a suppressed skip counted as deselected. A
    non-selected row that ran, or any membership instability, is
    `MALFORMED_SUITE` — the exit-1 class, never drift. The selected rows drive
    the verdict through the classifier.

    Args:
        config: The resolved runner configuration, for the run deadline.
        rel: The root-relative path of the file.
        term: The completed run's process result.
        universe: The test names collected by the probe.
        selected: The names the selection chose to run.
        deselected: The names suppressed by the selection, counted in the
            verdict.
        build_argv: The build command, for the verdict's reproduce line.
        bdur: The build wall time in seconds.
        canonical: The canonical source path the report must name.
        attempts_used: How many attempts the run spent, carried on every
            `FileFinished` so the reporter can show a retried run's count.
        flaky_if_pass: Set when an earlier attempt was crash-class, which
            promotes a valid pass to flaky.

    Returns:
        The file's terminal `FileResult`.
    """
    var rterm = term.termination
    var rdur = Float64(term.duration_ms) / 1000.0

    if rterm.is_signaled():
        return _run_terminal_file(
            rel,
            Outcome.CRASH,
            ParseDisposition.NO_REPORT,
            "",
            "",
            build_argv,
            bdur,
            rdur,
            term,
            len(deselected),
            signal_number=rterm.value,
            attempts_used=attempts_used,
        )
    if rterm.is_timed_out():
        return _run_terminal_file(
            rel,
            Outcome.TIMEOUT,
            ParseDisposition.NO_REPORT,
            "",
            "",
            build_argv,
            bdur,
            rdur,
            term,
            len(deselected),
            timeout_seconds=config.timeout_secs,
            attempts_used=attempts_used,
            escalated=rterm.escalated,
        )

    var trusted = resolve_report(
        lossy_utf8(term.stdout_bytes), canonical, term.stdout_truncated
    )
    if trusted.is_overflow or trusted.report.verdict != ReportVerdict.VALID:
        # No VALID report to reconcile. Route it through the SAME total
        # classifier the default path uses so selection preserves every
        # distinction: capture-overflow -> CAPTURE_OVERFLOW (exit-1 class),
        # OFF_GRAMMAR -> DRIFT (exit 3), ABSENT/AMBIGUOUS -> MALFORMED_SUITE.
        # Only a VALID report whose membership fails to reconcile (below) is the
        # selection-specific MALFORMED_SUITE.
        var cls = classify(rterm, trusted.report, trusted.is_overflow)
        return _classified_terminal(
            rel,
            cls,
            build_argv,
            bdur,
            rdur,
            term,
            len(deselected),
            attempts_used=attempts_used,
        )

    var report = trusted.report.copy()
    # The row set must equal the universe: every collected test must appear.
    var row_names = List[String]()
    for r in report.rows:
        row_names.append(r.name)
    if not _same_set(row_names, universe):
        return _run_terminal_file(
            rel,
            Outcome.MALFORMED_SUITE,
            ParseDisposition.NO_REPORT,
            "malformed-suite",
            (
                "the selection run's tests did not match the collected set (a"
                " test appeared or vanished between collection and run)"
            ),
            build_argv,
            bdur,
            rdur,
            term,
            len(deselected),
            attempts_used=attempts_used,
        )
    # A non-selected row MUST be SKIP (the selection-induced skip we suppress).
    for r in report.rows:
        if not _str_in(selected, r.name) and r.outcome != Outcome.SKIP:
            return _run_terminal_file(
                rel,
                Outcome.MALFORMED_SUITE,
                ParseDisposition.NO_REPORT,
                "malformed-suite",
                (
                    "a deselected test ran under --only instead of reporting a"
                    " selection-induced SKIP: "
                    + r.name
                ),
                build_argv,
                bdur,
                rdur,
                term,
                len(deselected),
                attempts_used=attempts_used,
            )

    var sel_view = _selected_view(report.rows.copy(), selected)
    var cls = classify(rterm, sel_view^, False)

    var pre = List[Event]()
    for r in report.rows:
        if _str_in(selected, r.name):
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
    if cls.file_outcome == Outcome.FAIL:
        exit_status = rterm.value

    # A late pass after a crash-class retry is FLAKY (not PASS): promote the
    # outcome while keeping the passing per-test exit multiset, so a flaky
    # selection pass counts 0 toward --maxfail and exit 0. A crash-then-FAIL
    # stays FAIL (still failing), never flaky.
    var file_out = cls.file_outcome
    var flaky = flaky_if_pass and not cls.file_outcome.is_failing()
    if flaky:
        file_out = Outcome.FLAKY

    var ev = Event.file_finished(
        rel,
        file_out,
        rdur,
        build_argv.copy(),
        bdur,
        term.stdout_bytes.copy(),
        term.stderr_bytes.copy(),
        signal_number=signal_number,
        exit_status=exit_status,
        parse_disposition=cls.disposition,
        passed_tests=cls.passed_tests,
        failed_tests=cls.failed_tests,
        skipped_tests=cls.skipped_tests,
        deselected_tests=len(deselected),
        attempts_used=attempts_used,
        flaky=flaky,
        slow=is_slow(bdur, rdur),
        stdout_truncated=term.stdout_truncated,
        stderr_truncated=term.stderr_truncated,
    )
    return FileResult.classified(
        pre^,
        ev^,
        file_out,
        cls.exit_outcomes.copy(),
        TestCounts(
            cls.passed_tests,
            cls.failed_tests,
            cls.skipped_tests,
            len(deselected),
        ),
        cls.is_drift,
    )


def _run_terminal_file(
    rel: String,
    outcome: Outcome,
    disposition: ParseDisposition,
    warning_kind: String,
    warning_detail: String,
    build_argv: List[String],
    bdur: Float64,
    rdur: Float64,
    term: ProcessResult,
    deselected_count: Int,
    signal_number: Int = 0,
    timeout_seconds: Int = 0,
    attempts_used: Int = 1,
    escalated: Bool = False,
) -> FileResult:
    """Build a file-level terminal result for a selection run.

    Used for a crash, timeout, or malformed suite, where no per-test rows exist.

    Args:
        rel: The root-relative path of the file.
        outcome: The file-level outcome to report and tally.
        disposition: How the run's stdout parsed.
        warning_kind: The warning to emit before the verdict, or empty for none.
        warning_detail: The warning's detail text.
        build_argv: The build command, for the verdict's reproduce line.
        bdur: The build wall time in seconds.
        rdur: The run wall time in seconds.
        term: The run's process result, supplying the captured streams.
        deselected_count: How many tests the selection suppressed.
        signal_number: The signal that killed the run, for a crash.
        timeout_seconds: The deadline enforced, for a timeout.
        attempts_used: How many attempts the run spent.
        escalated: The run termination's latched SIGKILL escalation, passed by
            the timeout caller so a selection run's timeout verdict tells the
            same story the default path's does.

    Returns:
        The terminal `FileResult`.
    """
    var pre = List[Event]()
    if warning_kind != "":
        pre.append(Event.warning(warning_kind, warning_detail))
    var ev = Event.file_finished(
        rel,
        outcome,
        rdur,
        build_argv.copy(),
        bdur,
        term.stdout_bytes.copy(),
        term.stderr_bytes.copy(),
        signal_number=signal_number,
        timeout_seconds=timeout_seconds,
        parse_disposition=disposition,
        deselected_tests=deselected_count,
        attempts_used=attempts_used,
        escalated=escalated,
        slow=is_slow(bdur, rdur),
        stdout_truncated=term.stdout_truncated,
        stderr_truncated=term.stderr_truncated,
    )
    return FileResult.classified(
        pre^,
        ev^,
        outcome,
        [outcome],
        TestCounts(0, 0, 0, deselected_count),
        False,
    )


def _classified_terminal(
    rel: String,
    cls: Classification,
    build_argv: List[String],
    bdur: Float64,
    rdur: Float64,
    term: ProcessResult,
    deselected_count: Int,
    attempts_used: Int = 1,
) -> FileResult:
    """Build a file-level terminal result from a `Classification`.

    Bridges a selection run whose report was not a reconcilable valid one — a
    capture overflow, an off-grammar drift, or an absent or ambiguous report —
    from the `classify` result to a `FileResult`, so the selection path emits
    the same outcome, disposition, warning, exit-code contribution, and drift
    flag the default run path would for the identical report. Carries no
    per-test rows.

    Args:
        rel: The root-relative path of the file.
        cls: The classification of the run.
        build_argv: The build command, for the verdict's reproduce line.
        bdur: The build wall time in seconds.
        rdur: The run wall time in seconds.
        term: The run's process result, supplying the captured streams.
        deselected_count: How many tests the selection suppressed.
        attempts_used: How many attempts the run spent.

    Returns:
        The terminal `FileResult`.
    """
    var pre = List[Event]()
    if cls.warning_kind != "":
        pre.append(Event.warning(cls.warning_kind, cls.warning_detail))
    var ev = Event.file_finished(
        rel,
        cls.file_outcome,
        rdur,
        build_argv.copy(),
        bdur,
        term.stdout_bytes.copy(),
        term.stderr_bytes.copy(),
        parse_disposition=cls.disposition,
        deselected_tests=deselected_count,
        attempts_used=attempts_used,
        slow=is_slow(bdur, rdur),
        stdout_truncated=term.stdout_truncated,
        stderr_truncated=term.stderr_truncated,
    )
    return FileResult.classified(
        pre^,
        ev^,
        cls.file_outcome,
        cls.exit_outcomes.copy(),
        TestCounts(0, 0, 0, deselected_count),
        cls.is_drift,
    )


def _run_precompile(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    src: String,
    out_name: Optional[String],
    include_paths: List[String],
) raises -> PrecompileResult:
    """Precompile one source into a package, promoted atomically on success.

    Builds `mojo precompile <src> -o <temp>`, forwarding the include paths and
    build args. Every attempt writes a temp path derived from the output path
    (see `_precompile_temp_path`) and is renamed onto it only after the attempt
    exits 0, so a killed, crashed, or rejected attempt never touches the output:
    a good package from an earlier run survives a failed step unchanged, and no
    dependent ever builds against a half-written package. Failed temps are
    deleted best-effort, and a cleanup failure never fails the session.

    The step is bounded by `--compile-timeout` with the compile-specific grace,
    the same treatment per-file builds get, and gets the same crash-class
    `--retries` budget: up to `config.retries + 1` attempts, retried only when
    `retry_classify("precompile", ...)` calls the failure crash-class. Each
    retry writes a fresh temp path and is quarantined against a fresh
    per-attempt module cache, with a residual warning.

    Precompile attempts are session-level: their `AttemptFinished` events name
    the `src` spelling and carry `step="precompile"`. There is no flaky verdict
    and no file counter, so a success after a crash-class attempt emits a
    warning instead.

    Args:
        runtime: The exec runtime supervising the compiler spawns.
        config: The resolved runner configuration.
        root: The invocation root the compiler runs in.
        src: The source to precompile.
        out_name: The output package path, or None to default to
            `build/<name>.mojopkg` where `name` is `src`'s `.mojo`-stripped
            basename.
        include_paths: Directories passed to the compiler as `-I`.

    Returns:
        The step's result, in one of four caller-visible states: a success
        carrying the include directory; a failure, either a compiler failure
        that names its ending or a promotion failure that has none to name,
        both reported as a precompile error at exit 1; a spawn failure at
        exit 3; or an interrupt at exit 2.

    Raises:
        Error: If the `exec` machinery itself fails, or the output or temp
            directory cannot be made. The caller catches these and resolves
            exit 3.
    """
    var name = String(basename(src).removesuffix(".mojo"))
    var out_path: String
    if out_name:
        out_path = out_name.value().copy()
    else:
        out_path = String("build/") + name + ".mojopkg"

    # The temp lives beside OUT, so its parent must exist before the first
    # attempt writes it (and the rename stays within one directory).
    var parent = dirname(out_path)
    if parent != "":
        _ensure_dir(root + "/" + parent)

    var nonce = _invocation_nonce()
    var attempts_planned = config.retries + 1
    var events = List[Event]()
    var quarantine_dirs = List[String]()
    var quarantine_dir = String("")
    var had_retry = False
    var attempt_index = 1

    while True:
        var tmp_path = _precompile_temp_path(
            out_path, src, attempt_index, nonce
        )
        var tmp_dir = dirname(tmp_path)
        _ensure_dir(root + "/" + tmp_dir)
        var argv = List[String]()
        argv.append(config.mojo_path)
        argv.append("precompile")
        argv.append(src)
        argv.append("-o")
        argv.append(tmp_path)
        for p in include_paths:
            argv.append("-I")
            argv.append(p)
        for a in config.build_args:
            argv.append(a)

        # NARROW quarantine: only a post-compile-kill retry redirects the module
        # cache, exactly as the file build path does. The session is
        # single-threaded, so mutating our own environment around the spawn is
        # safe; it is restored immediately after.
        var quarantined = quarantine_dir != ""
        var prev_cache = getenv("MODULAR_CACHE_DIR", "")
        var had_prev = prev_cache != ""
        if quarantined:
            _ = setenv("MODULAR_CACHE_DIR", quarantine_dir, True)

        var res: ProcessResult
        try:
            res = run_supervised(
                runtime,
                ProcessSpec.command_in(
                    argv.copy(),
                    root,
                    config.compile_timeout_secs * 1000,
                    _COMPILE_GRACE_MS,
                ),
            )
        except e:
            if quarantined:
                _restore_cache_env(had_prev, prev_cache)
            _discard_path(root + "/" + tmp_dir)
            _cleanup_quarantine(root, quarantine_dirs)
            raise e^
        if quarantined:
            _restore_cache_env(had_prev, prev_cache)

        var dur = Float64(res.duration_ms) / 1000.0
        # An interrupt during the step group-kills it (a TimedOut bail-out). It
        # is answered BEFORE the termination is read, so an interrupt is never
        # mistaken for a deadline — whatever the supervisor had to do to stop it.
        if interrupt_requested():
            _discard_path(root + "/" + tmp_dir)
            _cleanup_quarantine(root, quarantine_dirs)
            return PrecompileResult.interrupt(events^)

        var term = res.termination
        if term.is_spawn_failed():
            # Could not spawn the compiler at all: carry the real errno and
            # program so the diagnostic names the cause, exactly as the
            # build/run paths do.
            _discard_path(root + "/" + tmp_dir)
            _cleanup_quarantine(root, quarantine_dirs)
            return PrecompileResult.internal(
                term.value, config.mojo_path, events^
            )

        if term.is_exited() and term.value == 0:
            # PROMOTE: the package is real, so publish it indivisibly. A rename
            # that fails leaves OUT untouched — the step is honestly a failure,
            # never a half-published package.
            try:
                rename_path(root + "/" + tmp_path, root + "/" + out_path)
            except:
                # The COMPILER exited 0; only the rename lost (e.g. OUT is a
                # directory, or its parent is read-only). There is no compiler
                # ending to name, so this result carries none.
                _discard_path(root + "/" + tmp_dir)
                _cleanup_quarantine(root, quarantine_dirs)
                return PrecompileResult.promotion_failure(
                    String(
                        "mtest: the precompile of '"
                        + src
                        + "' succeeded, but its package could not be promoted"
                        " from '"
                    )
                    + tmp_path
                    + "' to '"
                    + out_path
                    + "'. The compiler is not at fault: check that OUT is a"
                    " writable file path (a directory or a read-only parent at"
                    " OUT will fail here). OUT was left untouched.\n",
                    events^,
                    attempt_index,
                )
            if had_retry:
                # No FLAKY verdict exists for a session-level step, so the
                # warning IS the signal that this package was not built cleanly
                # the first time.
                events.append(
                    Event.warning(
                        "precompile-succeeded-after-retry",
                        (
                            "the precompile step '"
                            + src
                            + "' succeeded only on attempt "
                            + String(attempt_index)
                            + " of "
                            + String(attempts_planned)
                            + "; its earlier attempt(s) were killed or crashed,"
                            " so treat this package as suspect"
                        ),
                    )
                )
            # The promoted package left the temp directory empty; take it away
            # too, so a successful step leaves the OUT tree exactly as an
            # unpromoted run would have.
            _discard_path(root + "/" + tmp_dir)
            _cleanup_quarantine(root, quarantine_dirs)
            var d = dirname(out_path)
            if d == "":
                d = String(".")
            return PrecompileResult.success(d, events^, attempt_index)

        # The attempt failed. Classify it for retry eligibility under the BUILD
        # rules (`interrupted` is False: an interrupt was short-circuited above,
        # so a TimedOut reaching here is a genuine deadline).
        var rc = retry_classify("precompile", term, False, res.stderr_bytes)
        var more_attempts = attempt_index < attempts_planned
        if rc.retry_eligible and more_attempts:
            had_retry = True
            var att = _AttemptResult._build_failed(
                argv.copy(), term, res.stderr_bytes.copy(), dur, tmp_path
            )
            events.append(
                _make_attempt_finished(
                    src,
                    rc,
                    att,
                    attempt_index,
                    attempts_planned,
                    step_override="precompile",
                )
            )
            # A compile kill: the shared module cache MAY be suspect. Warn
            # loudly and run the NEXT attempt quarantined against a fresh
            # per-attempt cache, into a fresh temp path.
            events.append(
                Event.warning(
                    "compile-kill-residual",
                    _compile_crash_residual("precompile", src, rc, term),
                )
            )
            _discard_path(root + "/" + tmp_dir)
            quarantine_dir = _quarantine_dir(
                "precompile-", _mangle(src), attempt_index + 1, nonce
            )
            _ensure_dir(root + "/" + quarantine_dir)
            quarantine_dirs.append(quarantine_dir)
            attempt_index += 1
            continue

        # Final attempt: the step is a PRECOMPILE-ERROR. OUT was never written.
        _discard_path(root + "/" + tmp_dir)
        _cleanup_quarantine(root, quarantine_dirs)
        var timeout_seconds = 0
        if term.is_timed_out():
            timeout_seconds = config.compile_timeout_secs
        return PrecompileResult.failure(
            lossy_utf8(res.stderr_bytes),
            events^,
            term,
            timeout_seconds,
            attempt_index,
        )


@fieldwise_init
struct SelectionSummary(Copyable, Movable):
    """What the selection sub-session folds back into `run_session`.

    Owns its lists; copies are explicit.
    """

    var run_outcomes: List[Outcome]
    """The exit-code multiset contribution of the run files."""
    var test_totals: TestCounts
    """The per-test totals (passed/failed/skipped/deselected) run-wide."""
    var ran_files: Int
    """How many run files produced a tallied verdict."""
    var interrupted: Bool
    """Whether an interrupt aborted the sub-session (exit 2)."""
    var internal_error: Bool
    """Whether a spawn/machinery failure occurred (exit 3)."""
    var drift: Bool
    """Whether any report drifted off the pinned grammar (exit 3).

    Set both by a probe whose collection listing drifted and by an executed
    selected run whose own report drifted."""
    var crash_files: List[_CrashFile]
    """The run files that ended CRASH, in discovery order, for the bounded
    crash-attribution post-pass. Diagnostics only: this list feeds no count, no
    outcome multiset, and no exit code."""


def _prepend_events(var extra: List[Event], var fr: FileResult) -> FileResult:
    """Prepend `extra` events to `fr.pre_events`, consuming both.

    Args:
        extra: Attempt and recovery events that happened before the verdict.
            Consumed.
        fr: The file result to prepend onto. Consumed; it is returned.

    Returns:
        `fr` with the merged event stream.
    """
    if len(extra) == 0:
        return fr^
    var merged = List[Event]()
    for e in extra:
        merged.append(e.copy())
    for e in fr.pre_events:
        merged.append(e.copy())
    fr.pre_events = merged^
    return fr^


def _run_selected_with_recovery(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    c: _Collected,
    mut reg: BuildRegistry,
    include_paths: List[String],
) raises -> FileResult:
    """Run one file's selected subset, with recover-once and crash retries.

    Runs plain when the selection is the whole universe, else with `--only`. Two
    orthogonal recovery mechanisms compose here, each with its own budget:

    - Stale-name recover-once: if the run reports `test not found in suite:`,
      meaning the suite refused a name it just listed, emit a warning, rebuild
      with an atomic registry replace, re-probe, re-validate, and re-run once. A
      second stale-name error is `MALFORMED_SUITE`, the exit-1 class, never
      exit 3.
    - Crash-class retries, under `--retries N`: a run that dies by signal or
      deadline — never an interrupt, which is short-circuited first — is re-run
      on the same already-built binary, with no rebuild, up to `retries` extra
      times. Each non-final attempt is reported immediately, and a late pass is
      flaky.

    A stale-name refusal is an `Exited(1)` diagnostic, so it is never
    crash-class and the two mechanisms never contend for the same failure. Their
    events interleave in one chronological stream prepended to the file's
    verdict.

    Args:
        runtime: The exec runtime supervising the run, rebuild, and probe.
        config: The resolved runner configuration.
        root: The invocation root the children run in.
        c: The collected file, carrying its binary, universe, and selection.
        reg: The build registry, updated by a stale-name rebuild and re-probe.
        include_paths: Directories passed to the compiler on a rebuild.

    Returns:
        The file's terminal `FileResult`, with its attempt and recovery events
        prepended.

    Raises:
        Error: If re-selection after a stale-name rebuild finds a named test
            missing from the fresh universe, a `select:` usage error. The run,
            rebuild, and probe calls are each caught here and turned into
            internal-error results instead.
    """
    var binary = c.binary
    var canonical = c.canonical
    var build_argv = c.build_argv.copy()
    var bdur = c.bdur
    var universe = c.universe.copy()
    var selected = c.selected.copy()
    var deselected = c.deselected.copy()
    var pre_stream = List[Event]()
    var attempts = 0
    var attempts_planned = config.retries + 1
    var crash_attempt = 1
    var had_crash_retry = False

    while True:
        var run_argv = List[String]()
        run_argv.append(binary)
        if not _same_set(selected, universe):
            run_argv.append("--only")
            for nm in selected:
                run_argv.append(nm)
        var rres: ProcessResult
        try:
            rres = run_supervised(
                runtime,
                ProcessSpec.command_in(
                    run_argv^, root, config.timeout_secs * 1000
                ),
            )
        except:
            return FileResult.internal(Event.internal_error("run", binary, 0))
        var rterm = rres.termination
        if rterm.is_spawn_failed():
            return FileResult.internal(
                Event.internal_error("run", binary, rterm.value)
            )
        if rterm.is_timed_out() and interrupt_requested():
            return FileResult.interrupt()

        # Stale-name detection PARSES the report first: a VALID report — even a
        # FAIL — is a genuine per-test result, never a stale-name refusal. Only
        # when the run produced NO valid report AND the stdlib's anchored refusal
        # diagnostic appears is this a stale name (which a bare substring in a
        # test's own output must never forge).
        var stdout_text = lossy_utf8(rres.stdout_bytes)
        var run_trusted = resolve_report(
            stdout_text, canonical, rres.stdout_truncated
        )
        var no_valid_report = run_trusted.report.verdict != ReportVerdict.VALID
        var is_stale = (
            rterm.is_exited()
            and rterm.value == 1
            and no_valid_report
            and _has_stale_name_diagnostic(stdout_text)
        )
        if not is_stale:
            # A crash-class run (signal / deadline; an interrupt was
            # short-circuited above, so `interrupted` is False) is re-run when
            # attempts remain. Deterministic outcomes (a FAIL, malformed suite,
            # capture overflow, drift) classify NOT eligible and finalize now.
            var rc = retry_classify("run", rterm, False, rres.stderr_bytes)
            if rc.retry_eligible and crash_attempt < attempts_planned:
                had_crash_retry = True
                var rdur = Float64(rres.duration_ms) / 1000.0
                var att = _AttemptResult._selection_run(
                    binary,
                    rterm,
                    rres.stdout_bytes.copy(),
                    rres.stderr_bytes.copy(),
                    rdur,
                    rres.stdout_truncated,
                    rres.stderr_truncated,
                )
                pre_stream.append(
                    _make_attempt_finished(
                        c.rel, rc, att, crash_attempt, attempts_planned
                    )
                )
                crash_attempt += 1
                continue
            var fr = _reconcile_and_classify(
                config,
                c.rel,
                rres,
                universe,
                selected,
                deselected,
                build_argv,
                bdur,
                canonical,
                attempts_used=crash_attempt,
                flaky_if_pass=had_crash_retry,
            )
            return _prepend_events(pre_stream^, fr^)

        if attempts >= 1:
            # A second stale-name error after a fresh rebuild+recollect: the
            # suite is a chameleon that keeps refusing names it just listed.
            var rdur = Float64(rres.duration_ms) / 1000.0
            var fr = _run_terminal_file(
                c.rel,
                Outcome.MALFORMED_SUITE,
                ParseDisposition.NO_REPORT,
                "malformed-suite",
                (
                    "the suite refused a selected test it had just listed, then"
                    " refused again after a fresh rebuild + recollect (the"
                    " '"
                    + _STALE_NAME_PHRASE
                    + "' chameleon); the module's --skip-all listing disagrees"
                    " with the names it accepts under --only"
                ),
                build_argv,
                bdur,
                rdur,
                rres,
                len(deselected),
                attempts_used=crash_attempt,
            )
            return _prepend_events(pre_stream^, fr^)

        attempts += 1
        pre_stream.append(
            Event.warning(
                "stale-name",
                (
                    "the suite for '"
                    + c.rel
                    + "' refused a test it listed under --skip-all ('"
                    + _STALE_NAME_PHRASE
                    + "'); rebuilding and recollecting once before retrying"
                ),
            )
        )
        # REBUILD (atomic registry replace), then RE-PROBE and RE-VALIDATE.
        var bo: _BuildOutcome
        try:
            bo = _build_for_selection(
                runtime, config, root, c.rel, include_paths, reg
            )
        except:
            return FileResult.internal(
                Event.internal_error("build", config.mojo_path, 0)
            )
        if bo.terminal:
            return _prepend_events(pre_stream^, bo.result.copy())
        binary = bo.binary
        canonical = bo.canonical
        build_argv = bo.build_argv.copy()
        bdur = bo.bdur
        var po: _ProbeOutcome
        try:
            po = _probe_file(
                runtime,
                config,
                root,
                c.rel,
                binary,
                canonical,
                build_argv,
                bdur,
                reg,
            )
        except:
            return FileResult.internal(Event.internal_error("probe", binary, 0))
        if po.terminal:
            return _prepend_events(pre_stream^, po.result.copy())
        universe = po.universe.copy()
        var sr = select_from(universe, c.rel, c.intent, config.keyword)
        selected = sr.selected.copy()
        deselected = sr.deselected.copy()


def _run_selection[
    C: ReportCoordinator
](
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    disc: DiscoveryResult,
    include_paths: List[String],
    plan: OperandParse,
    mut reporter: C,
    mut summary: Summary,
    mut reg: BuildRegistry,
) raises -> SelectionSummary:
    """Run the selection sub-session: probe every run file, then run it.

    A first pass builds, probes, and selects every run file, sharing each build
    through the registry, so the run-wide selected and deselected totals are
    known and emitted as `collection_known` before any test body runs. A second
    pass then runs each file's selected subset, suppressing the deselected rows.
    A machinery failure resolves to exit 3.

    Parameters:
        C: The report coordinator this step fans events to.

    Args:
        runtime: The exec runtime supervising every build, probe, and run.
        config: The resolved runner configuration.
        root: The invocation root the children run in.
        disc: The discovery result, supplying the run files and exclusions.
        include_paths: Directories passed to the compiler as `-I`.
        plan: The parsed operands, giving each file its selection intent.
        reporter: The composed reporter every event is handed to.
        summary: The run summary, accumulated as files finish.
        reg: The build registry recording builds, probes, and compile errors.

    Returns:
        What the sub-session folds back into `run_session`.

    Raises:
        Error: If selection names an unknown test, a `select:` usage error
            which main maps to exit 4.
    """
    var nroot = normalize_root(root)
    var collected = List[_Collected]()
    var interrupted = False
    var internal_error = False

    # --exclude beats a node id: a node-id file that was excluded is dropped
    # loudly rather than silently ignored.
    for t in plan.named_targets:
        var trp = normalize_operand(t.file_part, nroot)
        for ex in disc.excluded:
            if ex.path == trp:
                reporter.handle(
                    Event.warning(
                        "excluded-node-id",
                        (
                            "node id '"
                            + t.file_part
                            + "::"
                            + t.name
                            + "' names a file excluded by '"
                            + ex.pattern
                            + "'; dropping it"
                        ),
                    )
                )
                break

    # PHASE 1: build + probe + select every run file.
    for ri in range(len(disc.run_files)):
        if interrupt_requested():
            interrupted = True
            break
        var rel = disc.run_files[ri]
        var bo: _BuildOutcome
        try:
            bo = _build_for_selection(
                runtime, config, root, rel, include_paths, reg
            )
        except:
            reporter.handle(Event.internal_error("build", config.mojo_path, 0))
            internal_error = True
            break
        if bo.terminal:
            if bo.result.interrupted:
                interrupted = True
                break
            if bo.result.internal_error:
                reporter.handle(bo.result.event)
                internal_error = True
                break
            # A compile-error terminal: replay it in phase 2 with the others.
            collected.append(
                _Collected(
                    rel,
                    True,
                    bo.result.copy(),
                    List[String](),
                    List[String](),
                    List[String](),
                    FileIntent.whole_file(),
                    "",
                    "",
                    bo.build_argv.copy(),
                    bo.bdur,
                )
            )
            continue

        var po: _ProbeOutcome
        try:
            po = _probe_file(
                runtime,
                config,
                root,
                rel,
                bo.binary,
                bo.canonical,
                bo.build_argv,
                bo.bdur,
                reg,
            )
        except:
            reporter.handle(Event.internal_error("probe", bo.binary, 0))
            internal_error = True
            break
        if po.interrupted:
            interrupted = True
            break
        if po.internal_error:
            reporter.handle(po.result.event)
            internal_error = True
            break
        if po.terminal:
            collected.append(
                _Collected(
                    rel,
                    True,
                    po.result.copy(),
                    List[String](),
                    List[String](),
                    List[String](),
                    FileIntent.whole_file(),
                    bo.binary,
                    bo.canonical,
                    bo.build_argv.copy(),
                    bo.bdur,
                )
            )
            continue

        # Qualified: select from the universe (unknown test -> exit 4, propagated).
        var intent = _intent_for(rel, plan, nroot)
        var sr = select_from(po.universe, rel, intent, config.keyword)
        collected.append(
            _Collected(
                rel,
                False,
                _blank_file_result(),
                po.universe.copy(),
                sr.selected.copy(),
                sr.deselected.copy(),
                intent^,
                bo.binary,
                bo.canonical,
                bo.build_argv.copy(),
                bo.bdur,
            )
        )

    if interrupted or internal_error:
        return SelectionSummary(
            List[Outcome](),
            TestCounts.zeros(),
            0,
            interrupted,
            internal_error,
            False,
            List[_CrashFile](),
        )

    # Collection is known: emit the run-wide totals before any body runs.
    var sel_total = 0
    var desel_total = 0
    for c in collected:
        if not c.terminal:
            sel_total += len(c.selected)
            desel_total += len(c.deselected)
    reporter.handle(Event.collection_known(sel_total, desel_total))

    # PHASE 2: run each file's selected subset (or replay its terminal result).
    var run_outcomes = List[Outcome]()
    var test_totals = TestCounts.zeros()
    var ran_files = 0
    var drift = False
    var crash_files = List[_CrashFile]()

    for ci in range(len(collected)):
        if interrupt_requested():
            interrupted = True
            break
        ref c = collected[ci]
        reporter.handle(Event.file_started(c.rel))

        if c.terminal:
            var fr = c.terminal_result.copy()
            for pe in fr.pre_events:
                reporter.handle(pe)
            reporter.handle(fr.event)
            test_totals.deselected += fr.test_counts.deselected
            if fr.is_drift:
                drift = True
                continue
            summary.counts[fr.outcome.code] += 1
            run_outcomes.extend(fr.exit_outcomes.copy())
            ran_files += 1
            if fr.outcome == Outcome.CRASH:
                crash_files.append(
                    _CrashFile(c.rel, c.binary, c.selected.copy())
                )
            # Mirror the runnable branch's early-stop below (and the
            # non-selection loop's): a TERMINAL file — compile error, probe
            # crash, probe timeout, or malformed suite — must honor -x /
            # --maxfail exactly like a runnable one, or the remaining files
            # keep scheduling past a limit the non-selection path would have
            # respected.
            if config.exitfirst and fr.outcome.is_failing():
                break
            if (
                config.maxfail > 0
                and _failing_count(run_outcomes) >= config.maxfail
            ):
                break
            continue

        if len(c.selected) == 0:
            # Every test deselected: the file is NOT executed. Account the
            # deselections; the file itself lands in the NOT-RUN accounting.
            reporter.handle(
                Event.file_finished(
                    c.rel,
                    Outcome.NOT_RUN,
                    0.0,
                    c.build_argv.copy(),
                    c.bdur,
                    List[UInt8](),
                    List[UInt8](),
                    deselected_tests=len(c.deselected),
                    slow=is_slow(c.bdur, 0.0),
                )
            )
            test_totals.deselected += len(c.deselected)
            continue

        var fr = _run_selected_with_recovery(
            runtime, config, root, c, reg, include_paths
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
        test_totals.deselected += fr.test_counts.deselected
        if fr.is_drift:
            drift = True
            continue
        summary.counts[fr.outcome.code] += 1
        run_outcomes.extend(fr.exit_outcomes.copy())
        ran_files += 1
        if fr.outcome == Outcome.CRASH:
            crash_files.append(_CrashFile(c.rel, c.binary, c.selected.copy()))
        if config.exitfirst and fr.outcome.is_failing():
            break
        if (
            config.maxfail > 0
            and _failing_count(run_outcomes) >= config.maxfail
        ):
            break

    return SelectionSummary(
        run_outcomes^,
        test_totals,
        ran_files,
        interrupted,
        internal_error,
        drift,
        crash_files^,
    )


# --- The CRASH-ATTRIBUTION post-pass: bounded isolation reruns. ---------------
#
# A CRASH verdict is honest but unhelpful: the process died, but the verdict
# cannot say WHICH test killed it. This post-pass re-runs a crashed file's tests
# one at a time and names the first that dies by signal.
#
# It is SECONDARY EVIDENCE and NEVER a verdict input. Everything below emits
# `CrashAttribution` events and the one loud announcement, and touches NOTHING
# else: not `summary.counts`, not `run_outcomes`, not the exit code, not the
# file's `FileFinished`. That is the whole doctrine — a crashed file's verdict
# and the process exit code are identical whether attribution names a culprit,
# fails to reproduce the crash, or never runs at all. UNATTRIBUTED stands
# whenever isolation does not reproduce; the pass never guesses.


@fieldwise_init
struct _CrashFile(Copyable, Movable):
    """One crashed file queued for attribution, with the binary that ran.

    The binary is carried, never reconstructed from `rel`: a crash-class build
    retry rebuilds to `build/bin/<mangled>.inv-<nonce>.attempt-N` and runs that,
    so only the run itself knows what actually crashed.
    """

    var rel: String
    """The root-relative path of the crashed file."""
    var binary: String
    """The binary its crashed run executed."""
    var selected: List[String]
    """The test names actually selected in this run; empty means no selection
    was active, so all names qualify. Attribution isolates only these, never a
    deselected test that never ran under the user's `-k` or `--only`."""


def _secs_since(started_ns: UInt) -> Float64:
    """Wall seconds elapsed since a `perf_counter_ns` reading."""
    return Float64(perf_counter_ns() - started_ns) / 1.0e9


@fieldwise_init
struct _AttributionListing(Copyable, Movable):
    """The binary and the source-order test names to isolate for one file."""

    var ok: Bool
    """Whether both a qualifying listing and a runnable binary were found."""
    var binary: String
    """The root-relative built binary to re-run under `--only`."""
    var names: List[String]
    """The file's test names in the listing's own source order, never sorted."""


def _attribution_probe(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    rel: String,
    binary: String,
) raises -> _AttributionListing:
    """Re-probe `binary` with `--skip-all` for its test-name universe.

    The fallback when the registry holds no qualifying listing for `rel`: the
    plain, non-selection run loop never probes, so a crashed file from it
    arrives here unlisted.

    Distinct from `_probe_file`, which exists to give a file a verdict.
    `_probe_file` builds a terminal `FileResult` for a non-qualifying probe and
    records into the registry, both wrong here, since the file's verdict is
    already settled. This probe also runs under the isolation deadline rather
    than `--timeout`, so a `--timeout 0` run cannot hang the pass. Anything
    short of a clean exit carrying a qualifying listing yields `ok = False`,
    which the caller renders as `PROBE_FAILED`.

    Args:
        runtime: The exec runtime supervising the probe spawn.
        config: The resolved runner configuration, for the isolation deadline.
        root: The invocation root the probe runs in.
        rel: The root-relative path of the crashed file.
        binary: The binary that crashed, re-probed here.

    Returns:
        The listing, with `ok` False when no qualifying listing was recovered.

    Raises:
        Error: If the `exec` machinery itself fails; the caller catches it.
    """
    var argv = List[String]()
    argv.append(binary)
    argv.append("--skip-all")
    var pres = run_supervised(
        runtime,
        ProcessSpec.command_in(
            argv^, root, isolation_timeout_secs(config.timeout_secs) * 1000
        ),
    )
    var term = pres.termination
    if not term.is_exited():
        # Signaled, timed out, or unspawnable: no listing to be had.
        return _AttributionListing(False, binary, List[String]())
    var canonical = canonicalize(root + "/" + rel)
    var trusted = resolve_report(
        lossy_utf8(pres.stdout_bytes), canonical, pres.stdout_truncated
    )
    if trusted.is_overflow:
        return _AttributionListing(False, binary, List[String]())
    if collection_disqualifier(trusted.report) != "":
        return _AttributionListing(False, binary, List[String]())
    return _AttributionListing(
        True, binary, collection_names(trusted.report.copy())
    )


def _attribution_listing(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    rel: String,
    binary: String,
    reg: BuildRegistry,
) raises -> _AttributionListing:
    """Recover `rel`'s qualifying listing from the registry, else by probing.

    The registry is preferred: the selection and collect paths already probed
    every file with `--skip-all` and recorded the qualifying node-id listing, so
    re-probing would spawn a process to learn what is already known. The
    registry stores the listing as `rel::name` node ids, and the names are
    recovered by stripping that prefix, preserving source order. The listing is
    trusted only when its entry describes the same binary that crashed, since a
    listing read off a different build is not this crash's test universe.

    `binary` is the path the file's crashed run actually executed, carried here
    from that run rather than reconstructed. A crash-class build retry rebuilds
    to `build/bin/<mangled>.inv-<nonce>.attempt-N` and runs that binary, so a
    file whose rebuilt binary crashes at runtime earns its crash verdict on a
    path the mangled name does not name. Reconstructing `build/bin/<mangled>`
    would probe
    a binary that either does not exist, yielding a useless `PROBE_FAILED`, or
    is a stale leftover from an earlier run, which could name a culprit in code
    that never ran.

    The plain run loop keeps no registry entry, so its crashed files fall back
    to a fresh probe. A missing binary or a non-qualifying probe yields
    `ok = False`, which the caller renders as `PROBE_FAILED`.

    Args:
        runtime: The exec runtime supervising a fallback probe spawn.
        config: The resolved runner configuration, for the isolation deadline.
        root: The invocation root the probe runs in.
        rel: The root-relative path of the crashed file.
        binary: The binary that crashed.
        reg: The build registry consulted before probing.

    Returns:
        The listing, with `ok` False when no qualifying listing was recovered.

    Raises:
        Error: If the `exec` machinery itself fails; the caller catches it.
    """
    if binary == "" or not exists(root + "/" + binary):
        return _AttributionListing(False, binary, List[String]())
    if reg.has(rel):
        var bp = reg.get(rel)
        if bp.probed and bp.qualified and bp.binary_path == binary:
            var prefix = rel + "::"
            var names = List[String]()
            for node_id in bp.listing:
                names.append(String(node_id.removeprefix(prefix)))
            return _AttributionListing(True, binary, names^)
    return _attribution_probe(runtime, config, root, rel, binary)


def _attribute_one[
    C: ReportCoordinator
](
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    rel: String,
    binary: String,
    selected: List[String],
    reg: BuildRegistry,
    pass_started_ns: UInt,
    mut reporter: C,
) raises -> Bool:
    """Attribute one crashed file, normally emitting one `CrashAttribution`.

    An interrupt observed while recovering the listing or between reruns
    abandons the file and returns False, emitting nothing for it. Every other
    path emits exactly one event.

    Runs each of the file's tests alone under `--only <name>` in source order
    and stops at the first rerun that dies by signal; that test is the culprit,
    reported as `ATTRIBUTED`. Under a `-k` or `--only` selection, a non-empty
    `selected` restricts the candidates, so attribution can never name a
    deselected test that never ran. Every other stop renders its own
    disposition: `NO_REPRODUCTION` when every test ran alone without crashing,
    `RUN_CAP` or `TIME_BUDGET` when a bound cut the search short, and
    `PROBE_FAILED` when the listing could not be recovered or a rerun could not
    be spawned.

    Isolation reruns are never retried. `--retries` re-runs a crash-class
    failure to decide a verdict, and this pass decides no verdict: a crash here
    is the answer it is looking for, and re-running it would only spend budget.

    Every `exec` failure is caught and rendered as `PROBE_FAILED`, so nothing
    here propagates: attribution must not fail a session.

    Parameters:
        C: The report coordinator this step fans events to.

    Args:
        runtime: The exec runtime supervising the listing probe and the reruns.
        config: The resolved runner configuration, for the isolation deadline.
        root: The invocation root the reruns happen in.
        rel: The root-relative path of the crashed file.
        binary: The binary its crashed run executed.
        selected: The names that actually ran, or empty when no selection was
            active.
        reg: The build registry consulted for an existing listing.
        pass_started_ns: When the whole attribution pass started, for the
            session-wide time budget.
        reporter: The composed reporter the attribution event is handed to.

    Returns:
        False when an interrupt abandoned the pass, in which case the caller
        stops immediately and emits nothing further. True otherwise, including
        for every disposition, since a stopped search is a normal, fully
        reported outcome.
    """
    var file_started_ns = perf_counter_ns()

    # The SESSION budget is checked HERE, before the listing — not only inside
    # the rerun loop below. Recovering a listing can itself cost a probe of up to
    # the isolation deadline (the plain run loop records no registry entry, so
    # EVERY one of its crashed files pays that probe). A pass that has already
    # spent its budget must not buy one more probe per remaining file merely to
    # earn the right to say TIME_BUDGET: with many crashed files under
    # `--timeout 0` that is 60 s of diagnostics apiece, behind an exit code
    # resolved long before. The file still gets its typed line; it just does not
    # get a process.
    var pre = attribution_step(1, 0, 0.0, _secs_since(pass_started_ns))
    if pre.should_stop:
        reporter.handle(
            Event.crash_attribution(rel, pre.disposition, "", 0, 0.0)
        )
        return True

    var listing: _AttributionListing
    try:
        listing = _attribution_listing(runtime, config, root, rel, binary, reg)
    except:
        listing = _AttributionListing(False, "", List[String]())
    if interrupt_requested():
        return False
    if not listing.ok:
        reporter.handle(
            Event.crash_attribution(
                rel,
                AttributionDisposition.PROBE_FAILED,
                "",
                0,
                _secs_since(file_started_ns),
            )
        )
        return True

    # Restrict to the names the user actually selected: a deselected test never
    # ran in this session, so isolating it could name a culprit out of code the
    # run never invoked. An empty selection (the plain run path) keeps them all.
    var names = _select_names(listing.names, selected)

    var timeout_ms = isolation_timeout_secs(config.timeout_secs) * 1000
    var runs = 0
    var index = 0
    while True:
        if interrupt_requested():
            return False
        var step = attribution_step(
            len(names) - index,
            runs,
            _secs_since(file_started_ns),
            _secs_since(pass_started_ns),
        )
        if step.should_stop:
            reporter.handle(
                Event.crash_attribution(
                    rel,
                    step.disposition,
                    "",
                    runs,
                    _secs_since(file_started_ns),
                )
            )
            return True

        var name = names[index]
        index += 1
        var argv = List[String]()
        argv.append(listing.binary)
        argv.append("--only")
        argv.append(name)
        var res: ProcessResult
        try:
            res = run_supervised(
                runtime, ProcessSpec.command_in(argv^, root, timeout_ms)
            )
        except:
            # The machinery failed mid-pass. A verdict already stands, so this
            # is a diagnostic that gave up, never a session failure.
            reporter.handle(
                Event.crash_attribution(
                    rel,
                    AttributionDisposition.PROBE_FAILED,
                    "",
                    runs,
                    _secs_since(file_started_ns),
                )
            )
            return True
        var term = res.termination
        if term.is_spawn_failed():
            reporter.handle(
                Event.crash_attribution(
                    rel,
                    AttributionDisposition.PROBE_FAILED,
                    "",
                    runs,
                    _secs_since(file_started_ns),
                )
            )
            return True
        # Counted only now: a spawn that never produced a process is not a rerun,
        # and reporting one would overstate what the pass actually tried.
        runs += 1
        if term.is_timed_out() and interrupt_requested():
            return False
        if term.is_signaled():
            # The culprit: this test, run entirely alone, killed the process.
            reporter.handle(
                Event.crash_attribution(
                    rel,
                    AttributionDisposition.ATTRIBUTED,
                    name,
                    runs,
                    _secs_since(file_started_ns),
                )
            )
            return True
        # Anything else — a pass, a failing assertion, a deadline — is NOT the
        # crash this pass is hunting. Say nothing about it and move on: only a
        # reproduced crash may name a culprit.


def _run_crash_attribution[
    C: ReportCoordinator
](
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    crash_files: List[_CrashFile],
    reg: BuildRegistry,
    mut reporter: C,
) raises:
    """Run the bounded crash-attribution post-pass over every crashed file.

    Runs once, after every file has its verdict and before the summary band, in
    discovery order.

    The pass announces itself before spawning any extra process, so a watcher of
    a long run is never surprised by the reruns. Each file then renders exactly
    one typed line. When the session budget is gone the remaining files still
    get their line, reported as `TIME_BUDGET` rather than vanishing, so the pass
    accounts for every crashed file it was asked about.

    Skipped entirely under an interrupt, and abandoned the moment one arrives
    mid-pass: exit 2 must not wait on diagnostics.

    Parameters:
        C: The report coordinator this step fans events to.

    Args:
        runtime: The exec runtime supervising the probes and reruns.
        config: The resolved runner configuration, for the isolation deadline.
        root: The invocation root the reruns happen in.
        crash_files: The crashed files to attribute, in discovery order.
        reg: The build registry consulted for existing listings.
        reporter: The composed reporter every event is handed to.
    """
    if len(crash_files) == 0 or interrupt_requested():
        return
    reporter.handle(
        Event.warning(
            "crash-attribution-start",
            (
                "re-running the crashed file(s) one test at a time to name the"
                " culprit ("
                + String(len(crash_files))
                + " file(s); bounded and best-effort). This is SECONDARY"
                " diagnostics: the CRASH verdict already stands and nothing"
                " found here can change it or the exit code"
            ),
        )
    )
    var pass_started_ns = perf_counter_ns()
    for cf in crash_files:
        if not _attribute_one(
            runtime,
            config,
            root,
            cf.rel,
            cf.binary,
            cf.selected.copy(),
            reg,
            pass_started_ns,
            reporter,
        ):
            return


def run_session[
    C: ReportCoordinator
](
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    mut reporter: C,
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
        )
    )

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

    var run_outcomes = List[Outcome]()
    var test_totals = TestCounts.zeros()
    var ran_files = 0
    var interrupted = False
    var internal_error = False
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

    # Gates first: a failing gate aborts the whole session immediately.
    if proceed:
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
                if fr.outcome.is_failing():
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
    var sel_active = selection_active(config.paths, config.keyword)

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
    elif proceed_runs:
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
                if config.exitfirst and fr.outcome.is_failing():
                    break
                if (
                    config.maxfail > 0
                    and _failing_count(run_outcomes) >= config.maxfail
                ):
                    break
            except:
                reporter.handle(
                    Event.internal_error("build", config.mojo_path, 0)
                )
                internal_error = True
                break

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


# --- The COLLECT path: probe every file for its node ids, print the listing. --


@fieldwise_init
struct CollectResult(Copyable, Movable):
    """What `run_collect` hands back to `main` to print outside the event seam.

    Owns its lists; copies are explicit.

    `main` prints `listing` verbatim to stdout, one node id per line, and every
    `diagnostics` line to stderr, then exits with `code`.
    """

    var listing: List[String]
    """The sorted node-id listing, and the only thing stdout carries."""
    var diagnostics: List[String]
    """Per-file error and note lines for stderr, never mixed into `listing`."""
    var code: Int
    """The resolved exit code: 2 on an interrupt, 3 on drift or an internal
    error, 1 on a failing file, 5 when nothing was collectable, else 0."""


def _collect_phrase(fr: FileResult) -> String:
    """A short stderr phrase for a probe that did not yield node ids."""
    var o = fr.outcome
    if o == Outcome.COMPILE_ERROR:
        return "compile error (probe skipped)"
    if o == Outcome.CRASH:
        return "the --skip-all probe crashed"
    if o == Outcome.TIMEOUT:
        return "the --skip-all probe timed out"
    if fr.is_drift:
        return (
            "the --skip-all probe drifted off the pinned grammar (drift,"
            " exit 3)"
        )
    return "the --skip-all probe did not list its tests (malformed suite)"


def run_collect(
    mut runtime: ExecRuntime, config: RunnerConfig, root: String
) raises -> CollectResult:
    """Probe every discovered run file for its node ids and build the listing.

    Reuses the selection probe machinery — `_build_for_selection` and
    `_probe_file`, sharing each build through a `BuildRegistry` — to learn each
    file's node ids under `--skip-all`, running no test body. A qualifying file
    contributes `rel::name` for every collected name. A compile error, crash,
    timeout, or malformed suite writes a stderr diagnostic and the listing
    continues with the other files, in the exit-1 class; an off-grammar probe is
    drift, at exit 3; a spawn or machinery failure aborts the listing, also at
    exit 3. The listing is sorted lexicographically.

    `main` prints the result outside the event seam — the second sanctioned
    exception, after usage errors — so stdout carries only the listing while
    every diagnostic goes to stderr. This function prints nothing and drives no
    reporter.

    Args:
        runtime: The exec runtime supervising every build and probe spawn.
        config: The resolved runner configuration.
        root: The invocation root the children run in.

    Returns:
        The listing, the stderr diagnostics, and the resolved exit code: 2 if
        interrupted, else 3 on any drift or internal failure, else 1 if any file
        failed to collect, else 5 if no node ids were collectable, else 0.

    Raises:
        Error: If discovery reports a `discover:` usage error, which main maps
            to exit 4. Every build and probe failure is caught here and folded
            into the result.
    """
    var disc = discover(config, root)  # a discover: usage error propagates.

    # Collect honors the same shard partition as a run: the listing is exactly
    # this shard's node ids. Gate files are never sharded (collect has none).
    if config.shard_n > 0:
        disc.run_files = partition(
            disc.run_files.copy(),
            config.shard_mode,
            config.shard_m,
            config.shard_n,
        )

    var reg = BuildRegistry()
    var includes = config.include_paths.copy()
    var node_ids = List[String]()
    var diags = List[String]()
    var any_failing = False
    var drift = False
    var internal = False
    var interrupted = False

    # `-k` is a run-time selection filter; collect prints the FULL discovered
    # listing and ignores it with a note (deterministic and documented).
    if config.keyword != "":
        diags.append(
            "collect: -k is ignored in collect mode; printing the full node-id"
            " listing for the discovered files"
        )

    # Precompile steps first, widening the include set so a file importing a
    # precompiled package can build for its probe. A failed or unspawnable step
    # is a machinery-class abort (exit 3): collection cannot proceed honestly.
    for pc in config.precompiles:
        if interrupt_requested():
            interrupted = True
            break
        try:
            var pr = _run_precompile(
                runtime, config, root, pc.src, pc.out, includes
            )
            if pr.interrupted:
                interrupted = True
                break
            if pr.internal_error or not pr.ok:
                diags.append(
                    "collect: precompile step '"
                    + pc.src
                    + "' failed; aborting collection"
                )
                internal = True
                break
            includes.append(pr.out_dir)
        except:
            # `_run_precompile`'s own machinery (e.g. the output directory could
            # not be created) raised rather than returning a result. Mirror
            # `run_session`'s handling: an internal-abort diagnostic and exit 3,
            # not a `discover:`-style usage error. Not independently unit-tested
            # here — `run_session`'s sibling except (session.mojo ~1580) has no
            # dedicated raise-path test either; both are machinery-only
            # defensive code exercised only by the `pr.internal_error`
            # return-value path in `test_session_precompile.mojo`.
            diags.append(
                "collect: precompile step '"
                + pc.src
                + "' failed; aborting collection"
            )
            internal = True
            break

    if not (interrupted or internal):
        for ri in range(len(disc.run_files)):
            if interrupt_requested():
                interrupted = True
                break
            var rel = disc.run_files[ri]
            var bo: _BuildOutcome
            try:
                bo = _build_for_selection(
                    runtime, config, root, rel, includes, reg
                )
            except:
                diags.append(
                    "collect: " + rel + ": internal build failure; aborting"
                )
                internal = True
                break
            if bo.terminal:
                if bo.result.interrupted:
                    interrupted = True
                    break
                if bo.result.internal_error:
                    diags.append(
                        "collect: " + rel + ": internal build failure; aborting"
                    )
                    internal = True
                    break
                # A compile-error terminal: a diagnostic; the listing continues.
                diags.append(
                    "collect: " + rel + ": " + _collect_phrase(bo.result)
                )
                any_failing = True
                continue

            var po: _ProbeOutcome
            try:
                po = _probe_file(
                    runtime,
                    config,
                    root,
                    rel,
                    bo.binary,
                    bo.canonical,
                    bo.build_argv,
                    bo.bdur,
                    reg,
                )
            except:
                diags.append(
                    "collect: " + rel + ": internal probe failure; aborting"
                )
                internal = True
                break
            if po.interrupted:
                interrupted = True
                break
            if po.internal_error:
                diags.append(
                    "collect: " + rel + ": internal probe failure; aborting"
                )
                internal = True
                break
            if po.qualified:
                for nm in po.universe:
                    node_ids.append(rel + "::" + nm)
                continue

            # A non-qualifying terminal probe: diagnostic, then classify. Drift
            # forces exit 3 but the listing still continues; the rest are exit-1.
            diags.append("collect: " + rel + ": " + _collect_phrase(po.result))
            if po.result.is_drift:
                drift = True
            else:
                any_failing = True

    sort(node_ids)

    # Collect's own outcome tier, in `exit_code_for`'s shape over the listing it
    # produced: a file that failed to yield node ids is failing, an empty
    # listing means nothing was collectable, else success. The control-flow
    # facts rank above it in the model resolver, exactly as they do for a run.
    # A collect probe precompiles nothing and publishes no terminal artifact, so
    # those two facts are false by construction rather than by omission.
    var outcome_code: Int
    if any_failing:
        outcome_code = EXIT_FAILURE
    elif len(node_ids) == 0:
        outcome_code = EXIT_NOTHING_RAN
    else:
        outcome_code = EXIT_SUCCESS
    var code = resolve_exit_code(
        TerminalFacts(
            interrupted=interrupted,
            internal_error=internal,
            drift=drift,
            precompile_failed=False,
            outcome_code=outcome_code,
            delivery_failed=False,
        )
    )
    return CollectResult(node_ids^, diags^, code)


def run_collect(config: RunnerConfig, root: String) raises -> CollectResult:
    """Collect with a locally owned runtime, for direct library callers.

    Args:
        config: The resolved runner configuration.
        root: The invocation root the children run in.

    Returns:
        The collect result, as the primary overload defines it.

    Raises:
        Error: If the runtime cannot be opened or closed, or if the primary
            overload raises. A close failure during error handling is appended
            to the original message.
    """
    var runtime = ExecRuntime()
    try:
        runtime.open()
        var result = run_collect(runtime, config, root)
        runtime.close()
        return result^
    except error:
        var primary = String(error)
        try:
            runtime.close()
        except cleanup_error:
            raise Error(primary + "; " + String(cleanup_error))
        raise Error(primary)
