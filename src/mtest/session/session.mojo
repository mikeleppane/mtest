"""Sequential orchestration: discover -> build -> execute -> verdict -> exit (L4).

`run_session` is the integration keystone. It runs the discovered files in a
fixed order — precompile steps, then gates, then run files — building each to a
binary and executing it under the `exec` supervisor, mapping every termination
to an honest `Outcome` through the pure `verdict` functions, emitting the closed
`Event` set to the composed reporter, and resolving the process exit code. It is
sequential by contract: no parallelism, no retries, no report parsing.

The session emits events and NOTHING else. The reporter formats; pre-session CLI
usage errors are main's. The ONE thing that propagates out of `run_session` is a
`discover:` usage error (main maps it to exit 4); every other failure — an
`exec:` machinery raise or a spawn failure — is caught here and resolved to the
internal-error exit code 3.

Exit-code control flow (precedence high to low): an interrupt is 2; an internal
error (spawn failure or machinery raise) is 3; a precompile failure is 1;
otherwise the pure `exit_code_for` over the RUN outcomes decides 1 / 5 / 0.
"""
from std.os import makedirs
from std.os.path import basename, dirname, exists
from std.time import perf_counter_ns

from mtest.config import RunnerConfig, lossy_utf8
from mtest.discover import discover
from mtest.exec import (
    ProcessResult,
    ProcessSpec,
    canonicalize,
    interrupt_requested,
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
from mtest.report import CompositeReporter, Reporter
from mtest.session.classify import classify, resolve_report
from mtest.session.verdict import build_verdict


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
    output. `internal_error` and `interrupted` short-circuit as in `FileResult`.
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


def _run_one(
    config: RunnerConfig,
    root: String,
    rel: String,
    include_paths: List[String],
) raises -> FileResult:
    """Build `rel` to a binary and, if it built, execute it under supervision.

    Composes the `exec` supervisor into the session's build-then-run step for
    one file. The build runs with NO deadline (a stalled compile is a documented
    ceiling); the run runs under `config.timeout_secs`. Build termination maps
    through `build_verdict` (a compiler that dies by a signal is a
    `COMPILE_ERROR`, never a crash); the run maps through `resolve_report`
    (which decides which report a truncated capture may trust) and then
    `classify` (the TOTAL per-test policy). A spawn failure at either step is
    an internal error; an in-flight interrupt (a `TimedOut` with the interrupt
    flag set) aborts without recording a `TIMEOUT`.

    Raises:
        Error: only if the `exec` machinery itself fails (a `pipe`/`fork`
            syscall) or a directory cannot be made — the caller catches these
            and resolves exit 3.
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

    # Build with NO deadline, inside the invocation root. The argv is copied so
    # the original survives to ride the FileFinished event as build_argv. A build
    # machinery raise (a pipe/fork syscall failure) is a build-phase internal
    # error naming the compiler — never mislabeled against another step.
    var bres: ProcessResult
    try:
        bres = run_supervised(
            ProcessSpec.command_in(build_argv.copy(), root, 0)
        )
    except:
        return FileResult.internal(
            Event.internal_error("build", config.mojo_path, 0)
        )
    var bdur = Float64(bres.duration_ms) / 1000.0

    # An interrupt during the build group-kills it (a TimedOut bail-out).
    if interrupt_requested():
        return FileResult.interrupt()
    var bterm = bres.termination
    if bterm.is_spawn_failed():
        # Could not spawn the compiler at all: a machinery diagnostic, not a
        # verdict. The errno rides so the console can name the cause.
        return FileResult.internal(
            Event.internal_error("build", config.mojo_path, bterm.value)
        )

    var bsignal = build_verdict(bterm)
    if bsignal == Outcome.COMPILE_ERROR:
        # The compiler's stderr rides as raw bytes for the console banner.
        var ev = Event.file_finished(
            rel,
            Outcome.COMPILE_ERROR,
            0.0,
            build_argv.copy(),
            bdur,
            List[UInt8](),
            bres.stderr_bytes.copy(),
        )
        return FileResult.ran_with(ev^, Outcome.COMPILE_ERROR)

    # Build OK: run the freshly built binary under the run deadline. A run-phase
    # machinery raise attributes to the RUN step and names the built binary, so a
    # run-side failure is never laundered into a build diagnostic.
    var run_argv = List[String]()
    run_argv.append(out_bin)
    var rres: ProcessResult
    try:
        rres = run_supervised(
            ProcessSpec.command_in(run_argv^, root, config.timeout_secs * 1000)
        )
    except:
        return FileResult.internal(Event.internal_error("run", out_bin, 0))
    var rterm = rres.termination
    if rterm.is_spawn_failed():
        # Could not spawn the freshly built binary: a machinery diagnostic.
        return FileResult.internal(
            Event.internal_error("run", out_bin, rterm.value)
        )
    # An in-flight interrupt returns as TimedOut; never record it as a TIMEOUT.
    if rterm.is_timed_out() and interrupt_requested():
        return FileResult.interrupt()

    var rdur = Float64(rres.duration_ms) / 1000.0

    # The run's own report IS the handshake. Decode the captured stdout, resolve
    # WHICH report to trust under capture overflow (a truncated capture keeps a
    # verdict only if a complete block survived wholly in the tail), then run the
    # TOTAL classifier against the canonical path the child baked into its report.
    var source_path = canonicalize(root + "/" + rel)
    var stdout_text = lossy_utf8(rres.stdout_bytes)
    var trusted = resolve_report(
        stdout_text, source_path, rres.stdout_truncated
    )
    var cls = classify(rterm, trusted.report, trusted.is_overflow)

    # Retrospective per-test events for a VALID report, in row order, between the
    # already-emitted file_started and the file_finished below.
    var pre = List[Event]()
    if cls.disposition == ParseDisposition.PARSED:
        for r in trusted.report.rows:
            pre.append(
                Event.test_reported(
                    TestResult(
                        NodeId(rel, r.name), r.outcome, r.detail, r.timing
                    )
                )
            )
    # A loud warning (drift, malformed suite, overflow, exit-status mismatch)
    # rides just before the file_finished so the reporter can associate it.
    if cls.warning_kind != "":
        pre.append(Event.warning(cls.warning_kind, cls.warning_detail))

    # Carry the per-outcome specifics as data; the console formats them. The
    # terminating signal (CRASH) and the exit code (FAIL) both live in
    # rterm.value; the configured deadline drives the TIMEOUT phrasing.
    var signal_number = 0
    var exit_status = 0
    var timeout_seconds = 0
    if cls.file_outcome == Outcome.CRASH:
        signal_number = rterm.value
    elif cls.file_outcome == Outcome.FAIL:
        exit_status = rterm.value
    elif cls.file_outcome == Outcome.TIMEOUT:
        timeout_seconds = config.timeout_secs

    var ev = Event.file_finished(
        rel,
        cls.file_outcome,
        rdur,
        build_argv.copy(),
        bdur,
        rres.stdout_bytes.copy(),
        rres.stderr_bytes.copy(),
        signal_number=signal_number,
        exit_status=exit_status,
        timeout_seconds=timeout_seconds,
        parse_disposition=cls.disposition,
        passed_tests=cls.passed_tests,
        failed_tests=cls.failed_tests,
        skipped_tests=cls.skipped_tests,
    )
    return FileResult.classified(
        pre^,
        ev^,
        cls.file_outcome,
        cls.exit_outcomes.copy(),
        TestCounts(cls.passed_tests, cls.failed_tests, cls.skipped_tests, 0),
        cls.is_drift,
    )


def _run_precompile(
    config: RunnerConfig,
    root: String,
    src: String,
    out_name: Optional[String],
    include_paths: List[String],
) raises -> PrecompileResult:
    """Precompile one source into a package, with NO deadline, inside `root`.

    Builds `mojo precompile <src> -o <out>` (out defaults to
    `build/<name>.mojopkg`, `name` the `.mojo`-stripped basename of `src`),
    forwarding the include paths and build args. On success returns the OUT
    directory to add to the include set; on failure returns the captured
    compiler output. A spawn failure is an internal error.

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

    var parent = dirname(out_path)
    if parent != "":
        _ensure_dir(root + "/" + parent)

    var argv = List[String]()
    argv.append(config.mojo_path)
    argv.append("precompile")
    argv.append(src)
    argv.append("-o")
    argv.append(out_path)
    for p in include_paths:
        argv.append("-I")
        argv.append(p)
    for a in config.build_args:
        argv.append(a)

    var res = run_supervised(ProcessSpec.command_in(argv^, root, 0))
    if interrupt_requested():
        return PrecompileResult("", "", False, False, True, 0, "")
    var term = res.termination
    if term.is_spawn_failed():
        # Could not spawn the compiler at all: carry the real errno and program
        # so the diagnostic names the cause, exactly as the build/run paths do.
        return PrecompileResult(
            "", "", False, True, False, term.value, config.mojo_path
        )
    if term.is_exited() and term.value == 0:
        var d = dirname(out_path)
        if d == "":
            d = String(".")
        return PrecompileResult(d^, "", True, False, False, 0, "")
    return PrecompileResult(
        "", lossy_utf8(res.stderr_bytes), False, False, False, 0, ""
    )


def run_session[
    *Rs: Reporter
](
    config: RunnerConfig, root: String, mut reporter: CompositeReporter[*Rs]
) raises -> Int:
    """Orchestrate a whole run and return the resolved process exit code.

    Discovers the file set (a `discover:` usage error PROPAGATES — main maps it
    to exit 4), then emits `SessionStarted`, the loud excluded/stale-warning
    events, runs the precompile steps, the gates, and the run files in that
    fixed order, and finally emits `SessionFinished` with the full summary. The
    session emits events only; it prints nothing.

    Args:
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

    var selected = len(disc.gate_files) + len(disc.run_files)
    var excluded = len(disc.excluded)
    reporter.handle(
        Event.session_started(root, config.mojo_path, selected, excluded)
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
    var casualties = selected
    for pc in config.precompiles:
        if interrupt_requested():
            interrupted = True
            break
        try:
            var pr = _run_precompile(config, root, pc.src, pc.out, includes)
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
                        pc.src, pr.compiler_output, casualties
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
                var fr = _run_one(config, root, disc.gate_files[gi], includes)
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
                    # A drifting report forces exit 3 and contributes nothing to
                    # the run outcomes; it is accounted NOT_RUN like an internal
                    # error, but the run continues.
                    drift = True
                    continue
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

    # Run files, sorted; -x stops scheduling after the first failing file.
    if proceed_runs:
        for ri in range(len(disc.run_files)):
            if interrupt_requested():
                interrupted = True
                break
            reporter.handle(Event.file_started(disc.run_files[ri]))
            try:
                var fr = _run_one(config, root, disc.run_files[ri], includes)
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
            except:
                reporter.handle(
                    Event.internal_error("build", config.mojo_path, 0)
                )
                internal_error = True
                break

    # Every selected file that did not produce a tallied verdict is NOT_RUN — a
    # gate casualty, an -x/gate-abort/interrupt skip, a precompile casualty, or a
    # drift file (which forces exit 3 and is accounted here, never tallied).
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
    reporter.handle(
        Event.session_finished(summary^, wall, code, test_counts=test_totals)
    )
    return code
