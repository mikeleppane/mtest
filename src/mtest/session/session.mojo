"""Sequential orchestration: discover -> build -> execute -> classify -> exit (L4).

`run_session` is the integration keystone. It runs the discovered files in a
fixed order — precompile steps, then gates, then run files — building each to a
binary and executing it under the `exec` supervisor. It owns the RUN-report
handshake and the verdict policy: it decodes each child's captured stdout,
resolves WHICH report a truncated capture may trust (`resolve_report`), runs the
TOTAL per-test classifier (`classify`), reconciles a `--only` selection run
against its `--skip-all` collection universe, and maps every termination to an
honest `Outcome` — emitting the closed `Event` set to the composed reporter and
resolving the process exit code. It is sequential by contract: no parallelism;
the ONLY retry is the bounded stale-name recover-once during selection.

The session emits events and NOTHING else. The reporter formats; pre-session CLI
usage errors are main's. The ONE thing that propagates out of `run_session` is a
`discover:` usage error (main maps it to exit 4) — plus an unknown selected test
name (also exit 4); every other failure — an `exec:` machinery raise or a spawn
failure — is caught here and resolved to the internal-error exit code 3.

Exit-code control flow (precedence high to low): an interrupt is 2; an internal
error (spawn failure or machinery raise) is 3; a report that drifted off the
pinned grammar is 3 (the same tier); a precompile failure is 1; otherwise the
pure `exit_code_for` over the RUN outcomes decides 1 / 5 / 0. The selection,
probe, and gate paths honor the same classification and exit-code semantics as
the default run path — they route non-VALID reports through the same
`resolve_report`/`classify` machinery so a forged or off-grammar report never
resolves differently under selection than it would by default.
"""
from std.builtin.sort import sort
from std.os import (
    getenv,
    listdir,
    makedirs,
    remove,
    rmdir,
    setenv,
    unsetenv,
)
from std.os.path import basename, dirname, exists, isdir, join
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
    Event,
    NodeId,
    Outcome,
    ParseDisposition,
    Summary,
    TestCounts,
    TestResult,
    exit_code_for,
)
from mtest.protocol import (
    ParsedReport,
    ParsedRow,
    ReportVerdict,
    collection_disqualifier,
    collection_names,
)
from mtest.report import CompositeReporter, Reporter
from mtest.select import (
    FileIntent,
    NamedTarget,
    OperandParse,
    parse_operands,
    select_from,
    selection_active,
)
from mtest.session.classify import (
    Classification,
    TrustedReport,
    classify,
    resolve_report,
)
from mtest.session.clamp import clamp_stream
from mtest.session.retry_class import RetryClass, retry_classify
from mtest.session.shard import partition
from mtest.session.verdict import build_verdict

comptime _ATTEMPT_STREAM_HEAD = 65536
"""Head bytes of each stream retained in a NON-final attempt's excerpt (64 KiB).
"""
comptime _ATTEMPT_STREAM_TAIL = 65536
"""Tail bytes of each stream retained in a NON-final attempt's excerpt (64 KiB).
"""

comptime _COMPILE_GRACE_MS = 5000
"""SIGTERM->SIGKILL grace for a BUILD killed at `--compile-timeout` (5 s).

Deliberately far wider than the run path's 300 ms. A compiler is killed at its
own convenience, not ours: it may be mid-write to the shared module cache, and
SIGKILLing it 300 ms in is the most plausible way to leave that cache torn. Five
seconds lets it unwind and flush; a compiler still alive after that has ignored
SIGTERM and earns the SIGKILL — which is precisely when the NARROW cache
quarantine on the retry rebuild is worth its keep.
"""

comptime _STALE_NAME_PHRASE = "test not found in suite:"
"""The stdlib phrase when `--only` names a test the suite no longer offers."""

comptime _UNHANDLED_PREFIX = "Unhandled exception caught during execution:"
"""The runtime framing that carries a stale-name refusal as its payload.

A stale-name refusal aborts the suite BEFORE any report is printed, so the
stdlib emits the phrase as the payload of this line — e.g. `Unhandled exception
caught during execution: explicitly allowed test not found in suite: test_x`.
Anchoring the stale-name detection on this framing keeps a test that merely
PRINTS the phrase in its own output (or in an assertion detail) from tripping a
wasted rebuild+reprobe."""


def _mangle(rel: String) -> String:
    """The INJECTIVE binary name for a root-relative file path.

    Strips the `.mojo` suffix, then escapes every `_` as `_u` and every `/`
    as `_s` before emitting the rest of the characters unchanged, so
    `tests/sub/test_a.mojo` becomes `tests_ssub_stest_ua`. Injective because
    both escapes start with `_`: a literal `_` in the input NEVER survives
    un-escaped into the output, so no output byte sequence is ambiguous
    between "an escaped separator" and "a literal underscore" — two distinct
    root-relative paths can never mangle to the same name (contrast a naive
    `/`->`__` replacement, which collides `a/b.mojo` with the literal file
    `a__b.mojo`). Pure.
    """
    var noext = String(rel.removesuffix(".mojo"))
    var out = String("")
    for cp in noext.codepoint_slices():
        if cp == "_":
            out += "_u"
        elif cp == "/":
            out += "_s"
        else:
            out += String(cp)
    return out


def _ensure_dir(path: String) raises:
    """Create `path` and any missing parents; a no-op if it already exists."""
    if not exists(path):
        makedirs(path)


@fieldwise_init
struct FileResult(Copyable, Movable):
    """The outcome of building-and-running one file, plus the control signals.

    A completed file emits its `pre_events` (retrospective per-test rows and any
    loud warning) in order, then its `event` (the `FileFinished` verdict). When
    NOT a drift, the session tallies the file-level `outcome` once in the summary
    and appends `exit_outcomes` (the per-test/file-level multiset contribution)
    to the run outcomes; a drift file (`is_drift`) emits its events but forces
    exit 3 and contributes nothing. `internal_error` and `interrupted` are
    mutually exclusive short-circuits: the session emits `event` (for internal
    error) and resolves the exit code (3 or 2) directly. `test_counts` is the
    per-test tally to accumulate. Owns its lists/event; copies are explicit.
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
    """The exit-code multiset contribution (per-test for VALID, else file-level;
    empty for a drift file)."""
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

    @staticmethod
    def ran_with(var event: Event, outcome: Outcome) -> Self:
        """A completed file whose sole multiset entry is its file-level outcome.

        Used by the build COMPILE_ERROR path, which has no per-test report.
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
        """A completed run carrying its per-test events and multiset contribution.
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
        )

    @staticmethod
    def internal(var event: Event) -> Self:
        """A spawn failure: no verdict, carries the diagnostic, routes to exit 3.
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
        )

    @staticmethod
    def interrupt() -> Self:
        """An interrupt aborted this file: no verdict, routes to exit 2."""
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
        )


@fieldwise_init
struct PrecompileResult(Copyable, Movable):
    """The outcome of one precompile step, plus the control signals.

    On success `ok` is set and `out_dir` is the include directory added to every
    subsequent build. On failure `compiler_output` holds the captured compiler
    output and the `term_*`/`timeout_seconds` fields carry HOW the final attempt
    ended, so the banner can name the ending in words. `internal_error` and
    `interrupted` short-circuit as in `FileResult`. `events` are the session-level
    events the step produced along the way (a `TRY` per retried attempt, the
    compile-kill residual warnings, and a success-after-retry warning); the caller
    emits them in order before acting on the outcome.
    """

    var out_dir: String
    """The OUT directory to add to the include set on success."""
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
    """The program the step tried to spawn on an internal error; empty otherwise.
    """
    var events: List[Event]
    """The step's attempt events and warnings, in emission order."""
    var term: Termination
    """The final attempt's raw termination (meaningful on a failed step)."""
    var timeout_seconds: Int
    """The compile deadline WE enforced, for a step killed at it; 0 otherwise."""
    var attempts_used: Int
    """How many attempts the step spent (1 when it ran once with no retry)."""
    var ending_known: Bool
    """Whether `term` is the real ending of a compiler that ran and failed.

    False when the step failed for a reason the COMPILER never expressed — a
    failed promotion, where the compiler exited 0 and only the rename lost. The
    banner must then say nothing about an ending rather than report `term`'s
    Exited(0) as the nonsense "exited 0" on a step that failed."""

    @staticmethod
    def _blank() -> Self:
        """A result with every field at its neutral value. Allocates."""
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
        """An interrupt aborted the step: routes the session to exit 2."""
        var r = Self._blank()
        r.interrupted = True
        r.events = events^
        return r^

    @staticmethod
    def internal(errno: Int, program: String, var events: List[Event]) -> Self:
        """The compiler could not be spawned: routes the session to exit 3."""
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
        """The step built and PROMOTED its package; `out_dir` widens -I."""
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
        """The step's final attempt failed: PRECOMPILE-ERROR, exit 1.

        `term` is how the COMPILER ended, so the banner names that ending.
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
        """The compiler SUCCEEDED but its package could not be promoted onto OUT.

        Still a PRECOMPILE-ERROR at exit 1 — no package was published — but the
        step has NO compiler ending to name: this attempt exited 0. Leaving
        `ending_known` False keeps the banner from reporting "exited 0" on a
        failed step and sends the reader to `compiler_output`, which explains
        that the rename is what lost and that OUT was left untouched.
        """
        var r = Self._blank()
        r.compiler_output = compiler_output
        r.events = events^
        r.attempts_used = attempts_used
        return r^


@fieldwise_init
struct _AttemptResult(Copyable, Movable):
    """The raw result of ONE build->run->classify attempt for a file.

    Returned by `_single_attempt` so the attempt loop can BOTH build the file's
    terminal `FileResult` (via `_finalize_attempt`) AND decide a retry (via
    `retry_classify` over the failed step's raw `Termination`). `control` is `1`
    for an internal error (routes to exit 3), `2` for an interrupt (exit 2), or
    `0` for a completed attempt. A completed attempt is a compile terminal when
    `build_failed` (the build died and no run happened) or otherwise a run that
    classified into `cls`. Owns its buffers; copies are explicit.
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
    """The run's full captured stdout (final attempt keeps it; retries clamp it).
    """
    var run_stderr: List[UInt8]
    """The run's full captured stderr."""
    var rdur: Float64
    """The run wall time in seconds."""
    var trusted: TrustedReport
    """The resolved report the run's stdout was trusted to carry."""
    var cls: Classification
    """The TOTAL per-test classification of the run."""

    @staticmethod
    def _internal(var e: Event) -> Self:
        """An internal-error attempt: routes the file to exit 3."""
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
        )

    @staticmethod
    def _build_failed(
        var build_argv: List[String],
        bterm: Termination,
        var build_stderr: List[UInt8],
        bdur: Float64,
        out_bin: String,
    ) -> Self:
        """A terminal compile failure: no run happened; raw bterm/stderr ride.
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
        )

    @staticmethod
    def _selection_run(
        binary: String,
        rterm: Termination,
        var run_stdout: List[UInt8],
        var run_stderr: List[UInt8],
        rdur: Float64,
    ) -> Self:
        """A RAN result for a selection run, so `_make_attempt_finished` can
        emit its TRY line. The selection path already built the binary in phase
        1, so the build fields are placeholders; only the run fields matter.
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
        )


def _blank_classification() -> Classification:
    """A placeholder classification for a non-ran attempt result. Pure."""
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


def _restore_cache_env(had_prev: Bool, prev_cache: String) raises:
    """Restore `MODULAR_CACHE_DIR` to its pre-quarantine value (or unset it)."""
    if had_prev:
        _ = setenv("MODULAR_CACHE_DIR", prev_cache, True)
    else:
        _ = unsetenv("MODULAR_CACHE_DIR")


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
    """Run ONE build->run->classify attempt for `rel`, returning raw facts.

    The single-attempt keystone the retry loop wraps. When `do_build` it builds
    `rel` into `out_bin` (with NO deadline); otherwise it REUSES the prior
    successful build's facts and only re-runs `out_bin` (a run-side retry never
    rebuilds). A NARROW cache quarantine applies ONLY when `quarantine_dir` is
    non-empty (a post-compile-kill rebuild): `MODULAR_CACHE_DIR` is pointed at
    that fresh dir around the build spawn and RESTORED immediately after — the
    session is single-threaded, so mutating mtest's own environment is safe, and
    the shared cache is never used for a post-kill rebuild. The build/run
    termination, spawn-failure, and in-flight-interrupt short-circuits match the
    non-retry path exactly, so an unset `--retries` is byte-for-byte unchanged.

    Raises:
        Error: only if the `exec` machinery itself fails or a directory cannot
            be made — the caller catches these and resolves exit 3.
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
    )


def _rmtree(path: String) raises:
    """Recursively remove `path` and everything under it; a no-op if absent."""
    if not exists(path):
        return
    for name in listdir(path):
        var child = join(path, name)
        if isdir(child):
            _rmtree(child)
        else:
            remove(child)
    rmdir(path)


def _discard_path(path: String):
    """Best-effort delete of one disposable build artifact. Never raises.

    Used for a failed precompile attempt's temp package: it is litter, and
    failing the session over litter would be worse than the litter.
    """
    try:
        _rmtree(path)
    except:
        pass


def _precompile_temp_path(
    out_path: String, src: String, attempt_index: Int
) -> String:
    """The TEMP path attempt `attempt_index` of precompile step `src` builds into.

    A hidden per-step, per-attempt `.tmp` directory beside OUT, holding the
    package under OUT's own basename. Derived from OUT so the promotion is a
    rename within one FILESYSTEM (an atomic replace, never a copy), and distinct
    per attempt so a retry can never inherit a killed attempt's half-written
    bytes.

    Keyed on the MANGLED source as well as the attempt — symmetrically with the
    per-attempt quarantine dir — so two steps, two concurrent mtest runs over one
    root, or a stale dir left by a SIGKILLed run cannot collide on one temp
    directory and unlink it under another compiler's feet. (OUT is safe either
    way: a lost temp fails its own step's promotion, it never publishes.)

    The directory is what hides an unpromoted attempt from the `-I <dir>` scan of
    the OUT directory: the temp CANNOT simply be `<out>.tmp`, because the pinned
    toolchain rejects a package output path that does not end in
    `.mojopkg`/`.mojoc` (`mojo precompile -o x.tmp` is a hard error, not a
    warning). Keeping the required extension and moving the file out of the
    scanned directory buys the same guarantee the suffix would have. Pure.
    """
    var d = dirname(out_path)
    var tmp_dir = (
        ".mtest-precompile-"
        + _mangle(src)
        + ".attempt-"
        + String(attempt_index)
        + ".tmp"
    )
    if d != "":
        tmp_dir = d + "/" + tmp_dir
    return tmp_dir + "/" + String(basename(out_path))


def _cleanup_quarantine(root: String, dirs: List[String]):
    """Best-effort delete of every per-attempt quarantine cache dir.

    A cleanup failure NEVER fails the session (the dirs live under `build/`,
    which is disposable); the shared module cache is never touched.
    """
    for d in dirs:
        try:
            _rmtree(root + "/" + d)
        except:
            pass


def _make_attempt_finished(
    rel: String,
    rc: RetryClass,
    att: _AttemptResult,
    attempt_index: Int,
    attempts_planned: Int,
    step_override: String = "",
) -> Event:
    """The `AttemptFinished` event for ONE non-final crash-class attempt.

    The failed step's raw `Termination` is decomposed into the event's plain
    identity fields, and the captured streams are CLAMPED to a bounded head+tail
    excerpt (the final attempt keeps the full capture in the FileFinished).
    `step_override` names the step when it is not the file path's own build/run —
    the session-level `"precompile"` step reuses this whole seam, so a precompile
    TRY line carries the same identity as a build one.
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
    """Build the file's terminal `FileResult` from its LAST attempt.

    Mirrors the non-retry verdict construction exactly, then threads
    `attempts_used` and — for a late pass after a crash-class attempt — the
    FLAKY outcome/flag. At `attempts_used == 1, flaky == False` the result is
    byte-for-byte the pre-retry behavior.
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
    if cls.file_outcome == Outcome.CRASH:
        signal_number = att.rterm.value
    elif cls.file_outcome == Outcome.FAIL:
        exit_status = att.rterm.value
    elif cls.file_outcome == Outcome.TIMEOUT:
        timeout_seconds = config.timeout_secs

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
    )
    return FileResult.classified(
        pre^,
        ev^,
        file_out,
        cls.exit_outcomes.copy(),
        TestCounts(cls.passed_tests, cls.failed_tests, cls.skipped_tests, 0),
        cls.is_drift,
    )


def _run_one(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    rel: String,
    include_paths: List[String],
) raises -> FileResult:
    """Build `rel`, execute it, and RETRY a crash-class failure up to the budget.

    Runs up to `config.retries + 1` attempts through `_single_attempt`. An
    attempt that PASSES, or fails DETERMINISTICALLY (a real FAIL, a compile
    error, a flooded capture), is final. A crash-class failure with attempts
    remaining is reported immediately as an `AttemptFinished` and retried: a
    crash-class BUILD failure REBUILDS quarantined against a fresh cache (with a
    loud residual-risk warning); a crash-class RUN failure RE-RUNS the same
    binary. If the final attempt passes after any retry the file is FLAKY. An
    interrupt is never retried (short-circuited before the retry decision), and
    an unset `--retries` runs exactly one attempt with the pre-retry behavior.

    Raises:
        Error: only if the `exec` machinery itself fails (a `pipe`/`fork`
            syscall) or a directory cannot be made — the caller catches these
            and resolves exit 3.
    """
    _ensure_dir(root + "/build/bin")
    var mangled = _mangle(rel)
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
            attempt_passed = not att.cls.file_outcome.is_failing()

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
                        (
                            "the compile of '"
                            + rel
                            + "' was killed ("
                            + rc.label
                            + "); the shared module cache may be suspect, so"
                            " the rebuild ran quarantined against a fresh"
                            " per-attempt cache (the shared cache was neither"
                            " used nor deleted)"
                        ),
                    )
                )
                do_build = True
                out_bin = (
                    String("build/bin/")
                    + mangled
                    + ".attempt-"
                    + String(attempt_index + 1)
                )
                quarantine_dir = (
                    String("build/quarantine/")
                    + mangled
                    + "/attempt-"
                    + String(attempt_index + 1)
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
    """Whether `needle` equals any element of `items`. Pure."""
    for x in items:
        if x == needle:
            return True
    return False


def _same_set(a: List[String], b: List[String]) -> Bool:
    """Whether `a` and `b` hold the same set of names (order-independent)."""
    if len(a) != len(b):
        return False
    for x in a:
        if not _str_in(b, x):
            return False
    return True


def _has_stale_name_diagnostic(text: String) -> Bool:
    """Whether `text` carries the stdlib's ANCHORED stale-name refusal. Pure.

    A stale-name refusal aborts the suite before any report is printed, so the
    stdlib emits the phrase as the payload of an `Unhandled exception caught
    during execution:` line. Anchoring on that framing — a line that BOTH opens
    with the runtime prefix AND carries the `test not found in suite:` phrase —
    keeps a test that merely PRINTS the phrase in its own output (or in an
    assertion detail on some other line) from being mistaken for a refusal.
    """
    for line in text.split("\n"):
        var l = String(line)
        if l.startswith(_UNHANDLED_PREFIX) and (_STALE_NAME_PHRASE in l):
            return True
    return False


def _failing_count(outcomes: List[Outcome]) -> Int:
    """The number of failing-class entries in a run-outcome multiset. Pure.

    `outcomes` is already TEST-granular (per-test for a VALID report, one
    file-level entry otherwise), so this is exactly the `--maxfail` counter:
    each element counts once, with no re-derivation from file-level outcomes
    and no double-counting."""
    var n = 0
    for o in outcomes:
        if o.is_failing():
            n += 1
    return n


def _intent_for(
    rel: String, plan: OperandParse, nroot: String
) raises -> FileIntent:
    """The selection intent for a discovered file (Stage 1 -> per-file intent).

    A file is WHOLE when no node id was given at all, or when a plain operand
    (file or directory) covered it — the union rule: a plain operand always
    beats a node id. Otherwise its intent is the union of the test names every
    node-id operand attached to it.
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
    """The terminal FileResult to replay when `terminal`."""


def _blank_file_result() -> FileResult:
    """A placeholder FileResult for the non-terminal `_BuildOutcome` path."""
    return FileResult.interrupt()


def _build_for_selection(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    rel: String,
    include_paths: List[String],
    mut reg: BuildRegistry,
) raises -> _BuildOutcome:
    """Build `rel` into the registry (once), or produce a terminal FileResult.

    A compile error records a compile-error entry and returns a terminal
    COMPILE_ERROR FileResult; a spawn/machinery failure returns a terminal
    internal-error FileResult; an interrupt returns a terminal interrupt. On
    success the registry holds the fresh build and the binary/canonical ride
    back for the probe and run to share.
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
    """Whether a terminal FileResult was produced (crash/timeout/malformed/drift/
    overflow/spawn-failure/interrupt)."""
    var result: FileResult
    """The terminal FileResult to replay when `terminal`."""
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
) -> FileResult:
    """A file-level terminal FileResult for a probe that did not qualify."""
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

    Termination handling is TOTAL, mirroring `_run_one`'s run-phase policy so a
    probe never resolves differently than the default path would: a SpawnFailed
    probe is an internal error (exit 3); an interrupt-induced timeout is an
    interrupt (exit 2); a signaled probe is that file's CRASH; a plain timeout is
    a TIMEOUT. On a clean exit the captured stdout is decoded and resolved under
    the SAME truncation policy the run path uses (`resolve_report`): only a
    report wholly retained in the tail is trusted, so a forged report in a
    truncated head is refused as capture-overflow (a failing outcome, never a
    qualifying listing, never exit 0).

    Qualifying -> the universe is the collection listing (recorded in the
    registry). An OFF_GRAMMAR probe is DRIFT (exit 3); a capture-overflow probe
    is CAPTURE_OVERFLOW (exit-1 class); an ABSENT/AMBIGUOUS/VALID-but-
    disqualified probe is MALFORMED_SUITE (the module ran bodies or ignored
    `--skip-all`).
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
        ),
        False,
        False,
    )


@fieldwise_init
struct _Collected(Copyable, Movable):
    """One file after phase-1 build+probe+select: terminal, or runnable."""

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
    """A synthetic VALID report of just the selected rows, tallies recomputed.

    The child under `--only` reports every test (non-selected ones as SKIP); the
    classifier must see only the SELECTED rows so the file verdict and exit-code
    contribution reflect the selection, not the suppressed deselections.
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

    A crash/timeout is that file's abnormal outcome. Otherwise the report must
    be VALID and its row set must equal the universe; a non-selected row must be
    SKIP (suppressed, counted DESELECTED) — a non-selected row that RAN, or any
    membership instability, is MALFORMED_SUITE (exit-1 class, never drift). The
    SELECTED rows drive the verdict via the pure classifier.

    `attempts_used` rides every FileFinished so the reporter can show a retried
    selection run's attempt count; `flaky_if_pass` (set when an earlier attempt
    was crash-class) promotes a VALID pass to FLAKY. Both default so a single
    attempt is byte-for-byte unchanged.
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
) -> FileResult:
    """A file-level terminal FileResult for a selection run (crash/malformed).
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
    """A file-level terminal FileResult from a `Classification` (no per-test rows).

    Bridges a selection run whose report was NOT a reconcilable VALID one — a
    capture overflow, an off-grammar drift, or an absent/ambiguous report — from
    the pure `classify` result to a `FileResult`, so the selection path emits the
    same outcome, disposition, warning, exit-code contribution, and drift flag
    the default run path would for the identical report.
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
    """Precompile one source into a package — bounded, retried, promoted ATOMICALLY.

    Builds `mojo precompile <src> -o <temp>` (OUT defaults to
    `build/<name>.mojopkg`, `name` the `.mojo`-stripped basename of `src`),
    forwarding the include paths and build args. Every ATTEMPT writes a temp path
    derived from OUT (`_precompile_temp_path`) and is RENAMED onto OUT only after
    it exits 0, so a killed, crashed, or rejected attempt never touches OUT: a
    good package from an earlier run survives a failed step byte-for-byte, and no
    dependent ever builds against a half-written package. Failed temps are deleted
    best-effort; a cleanup failure never fails the session.

    The step is bounded by `--compile-timeout` with the compile-specific grace —
    the same treatment the per-file builds get — and gets the same crash-class
    `--retries` budget: up to `config.retries + 1` attempts, retried ONLY when
    `retry_classify("precompile", ...)` calls the failure crash-class, each retry
    on a FRESH temp path and quarantined against a fresh per-attempt module cache
    (with the loud residual warning). At `--retries 0` exactly one attempt runs
    and behavior is unchanged apart from the invisible temp-then-rename.

    Precompile attempts are SESSION-level: their `AttemptFinished` events name the
    `src` spelling and carry `step="precompile"`; there is no FLAKY verdict and no
    file counter — a success after a crash-class attempt emits a loud warning
    instead.

    Raises:
        Error: only if the `exec` machinery itself fails or the OUT directory
            cannot be made — the caller catches these and resolves exit 3.
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

    var attempts_planned = config.retries + 1
    var events = List[Event]()
    var quarantine_dirs = List[String]()
    var quarantine_dir = String("")
    var had_retry = False
    var attempt_index = 1

    while True:
        var tmp_path = _precompile_temp_path(out_path, src, attempt_index)
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
                    (
                        "the precompile of '"
                        + src
                        + "' was killed ("
                        + rc.label
                        + "); the shared module cache may be suspect, so the"
                        " rebuild ran quarantined against a fresh per-attempt"
                        " cache (the shared cache was neither used nor deleted)"
                    ),
                )
            )
            _discard_path(root + "/" + tmp_dir)
            quarantine_dir = (
                String("build/quarantine/precompile-")
                + _mangle(src)
                + "/attempt-"
                + String(attempt_index + 1)
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
    """What the selection sub-session folds back into `run_session`."""

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
    """Whether a probe drifted off the pinned grammar (exit 3)."""


def _prepend_events(var extra: List[Event], var fr: FileResult) -> FileResult:
    """Prepend `extra` events (a loud recovery warning) to `fr.pre_events`."""
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
    """Run one file's selected subset, with recover-once AND crash-class retries.

    Runs plain when the selection is the whole universe, else with `--only`. Two
    ORTHOGONAL recovery mechanisms compose here, each with its own budget:

    - Stale-name recover-once: if the run reports `… test not found in suite:` (a
      suite refusing a name it just listed), emit a LOUD warning, REBUILD (atomic
      registry replace), RE-PROBE, RE-VALIDATE, and RE-RUN once; a SECOND
      stale-name error is MALFORMED_SUITE (exit-1 class), never exit 3.
    - Crash-class retries (`--retries N`): a run that dies by signal or a
      deadline (never an interrupt, short-circuited first) is re-run — the SAME
      already-built binary, no rebuild — up to `retries` extra times, each
      non-final attempt reported immediately as a TRY line; a late pass is FLAKY.

    A stale-name refusal is an `Exited(1)` diagnostic, so it is never crash-class
    — the two mechanisms never contend for the same failure. Their events
    interleave in one chronological `pre_stream` prepended to the file's verdict.
    At `--retries 0` this is byte-for-byte the pre-retry recover-once behavior.
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
    *Rs: Reporter
](
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    disc: DiscoveryResult,
    include_paths: List[String],
    plan: OperandParse,
    mut reporter: CompositeReporter[*Rs],
    mut summary: Summary,
) raises -> SelectionSummary:
    """The SELECTION sub-session: probe every run file, then run the selection.

    Phase 1 builds+probes+selects every run file (sharing each build through the
    registry), so the run-wide selected/deselected totals are known and emitted
    as `collection_known` BEFORE any test body runs. Phase 2 then runs each
    file's selected subset, suppressing the deselected rows. An unknown test name
    raises out to exit 4; a machinery failure resolves to exit 3.
    """
    var nroot = normalize_root(root)
    var reg = BuildRegistry()
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
    )


def run_session[
    *Rs: Reporter
](
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    root: String,
    mut reporter: CompositeReporter[*Rs],
) raises -> Int:
    """Orchestrate a whole run and return the resolved process exit code.

    Discovers the file set (a `discover:` usage error PROPAGATES — main maps it
    to exit 4), then emits `SessionStarted`, the loud excluded/stale-warning
    events, runs the precompile steps, the gates, and the run files in that
    fixed order, and finally emits `SessionFinished` with the full summary. The
    session emits events only; it prints nothing.

    Args:
        runtime: Exclusive owner of process-global exec and signal state.
        config: Every knob the run reads.
        root: The invocation root; built binaries and paths are relative to it.
        reporter: The composed reporters the session fans every event to.

    Returns:
        The resolved exit code: 2 on interrupt, 3 on an internal error, 1 on a
        precompile failure, else `exit_code_for` over the run outcomes (1/5/0).

    Raises:
        Error: a `discover:` usage error only; every other failure is caught and
            resolved to exit 3.
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
    var proceed = not (interrupted or internal_error or precompile_failed)

    # Gates first: a failing gate aborts the whole session immediately.
    if proceed:
        for gi in range(len(disc.gate_files)):
            if interrupt_requested():
                interrupted = True
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
        interrupted or internal_error or precompile_failed or gate_abort
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
            runtime, config, root, disc, includes, plan, reporter, summary
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
    elif proceed_runs:
        for ri in range(len(disc.run_files)):
            if interrupt_requested():
                interrupted = True
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

    # Exit-code precedence (high to low): interrupt (2), internal error (3) and
    # drift (3, the same tier), precompile failure (1), else the pure
    # `exit_code_for` over the run outcomes at TEST granularity (1/5/0).
    var code: Int
    if interrupted:
        code = 2
    elif internal_error:
        code = 3
    elif drift:
        code = 3
    elif precompile_failed:
        code = 1
    else:
        code = exit_code_for(run_outcomes)

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
    return code


def run_session[
    *Rs: Reporter
](
    config: RunnerConfig, root: String, mut reporter: CompositeReporter[*Rs]
) raises -> Int:
    """Run a session with a locally owned runtime for direct library callers.

    The CLI uses the overload that accepts its already-open runtime so runtime
    construction failures map to internal exit 3 before session error handling.
    This convenience overload preserves the session test/library surface while
    still passing exclusive mutable ownership to every supervised child.
    """
    var runtime = ExecRuntime()
    try:
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
    """What `run_collect` hands back to `main` to print OUTSIDE the reporter seam.

    `main` prints `listing` verbatim to STDOUT (one node id per line, byte-clean)
    and every `diagnostics` line to STDERR, then exits `code`. Owns its lists;
    copies are explicit.
    """

    var listing: List[String]
    """The SORTED node-id listing for STDOUT — the ONLY thing STDOUT carries."""
    var diagnostics: List[String]
    """Per-file error / note lines for STDERR (never mixed into the listing)."""
    var code: Int
    """The resolved exit code: 2 interrupt, 3 drift/internal, 1 failing, 5
    nothing collectable, else 0."""


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

    Reuses the selection probe machinery (`_build_for_selection` + `_probe_file`,
    sharing each build through a `BuildRegistry`) to learn each file's node ids
    under `--skip-all`, running NO test body. A qualifying file contributes
    `rel::name` for every collected name; a compile error / crash / timeout /
    malformed suite writes a stderr diagnostic and the listing CONTINUES with the
    other files (exit-1 class); an off-grammar probe is DRIFT (exit 3); a
    spawn/machinery failure ABORTS the listing (exit 3). The listing is SORTED
    lexicographically (the frozen order).

    The caller (`main`) prints the result OUTSIDE the reporter seam — the SECOND
    sanctioned exception to the event seam, after usage errors — so STDOUT stays
    byte-clean (only the listing) while every diagnostic goes to STDERR. This
    function prints nothing and drives no reporter.

    Session exit code: 2 if interrupted; else 3 if any drift or internal failure;
    else 1 if any file failed to collect; else 5 if nothing was collectable (no
    node ids); else 0.

    Raises:
        Error: a `discover:` usage error only (main maps it to exit 4); every
            build/probe failure is caught here and folded into the result.
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

    var code: Int
    if interrupted:
        code = 2
    elif internal:
        code = 3
    elif drift:
        code = 3
    elif any_failing:
        code = 1
    elif len(node_ids) == 0:
        code = 5
    else:
        code = 0
    return CollectResult(node_ids^, diags^, code)


def run_collect(config: RunnerConfig, root: String) raises -> CollectResult:
    """Collect with a locally owned runtime for direct library callers."""
    var runtime = ExecRuntime()
    try:
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
