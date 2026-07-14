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

from mtest.config import RunnerConfig, shell_join
from mtest.discover import discover
from mtest.exec import (
    ProcessSpec,
    Termination,
    interrupt_requested,
    lossy_utf8,
    run_supervised,
)
from mtest.model import Event, Outcome, Summary, exit_code_for
from mtest.report import CompositeReporter, Reporter
from mtest.session.verdict import build_verdict, run_verdict


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


def _signal_name(signo: Int) -> String:
    """The `"SIGNAME, description"` words for a common Linux terminating signal.

    Covers the signals a supervised child can plausibly die by. Returns `""`
    for a signal number outside that set, so the caller can fall back to the
    bare number. Pure.
    """
    if signo == 1:
        return String("SIGHUP, hangup")
    if signo == 2:
        return String("SIGINT, interrupt")
    if signo == 3:
        return String("SIGQUIT, quit")
    if signo == 4:
        return String("SIGILL, illegal instruction")
    if signo == 5:
        return String("SIGTRAP, trace/breakpoint trap")
    if signo == 6:
        return String("SIGABRT, abort")
    if signo == 7:
        return String("SIGBUS, bus error")
    if signo == 8:
        return String("SIGFPE, floating-point exception")
    if signo == 9:
        return String("SIGKILL, killed")
    if signo == 11:
        return String("SIGSEGV, segmentation fault")
    if signo == 13:
        return String("SIGPIPE, broken pipe")
    if signo == 15:
        return String("SIGTERM, terminated")
    return String("")


def _detail_for(
    outcome: Outcome, term: Termination, timeout_secs: Int
) -> String:
    """The per-outcome `detail` string the console renders: signal, exit, etc.

    `FAIL` carries the exit code, `CRASH` the terminating signal named in
    words when recognized (`"signal 4 — SIGILL, illegal instruction"`, else
    just `"signal <n>"`), `TIMEOUT` the configured deadline; every other
    outcome carries no detail. Pure.
    """
    if outcome == Outcome.FAIL:
        return String("exit ") + String(term.value)
    if outcome == Outcome.CRASH:
        var base = String("signal ") + String(term.value)
        var name = _signal_name(term.value)
        if name.byte_length() > 0:
            return base + " — " + name
        return base
    if outcome == Outcome.TIMEOUT:
        return String("timed out after ") + String(timeout_secs) + "s"
    return String("")


def _ensure_dir(path: String) raises:
    """Create `path` and any missing parents; a no-op if it already exists."""
    if not exists(path):
        makedirs(path)


@fieldwise_init
struct FileResult(Copyable, Movable):
    """The outcome of building-and-running one file, plus the control signals.

    `ran` marks a genuine recorded verdict whose `event` the session emits and
    whose `outcome` it tallies. `internal_error` and `interrupted` are mutually
    exclusive short-circuits: the session ignores `event`/`outcome` and resolves
    the exit code (3 or 2) directly. Owns its `event`; copies are explicit.
    """

    var event: Event
    """The `FileFinished` event to emit (only meaningful when `ran`)."""
    var outcome: Outcome
    """The recorded outcome to tally (only meaningful when `ran`)."""
    var ran: Bool
    """Whether the file produced a real verdict to emit and tally."""
    var internal_error: Bool
    """Whether a spawn failure occurred (routes to internal-error exit 3)."""
    var interrupted: Bool
    """Whether an interrupt aborted this file (routes to exit 2)."""

    @staticmethod
    def ran_with(var event: Event, outcome: Outcome) -> Self:
        """A completed file carrying its emit event and tally outcome."""
        return Self(event^, outcome, True, False, False)

    @staticmethod
    def internal() -> Self:
        """A spawn failure: no verdict, routes to exit 3."""
        return Self(Event.file_started(""), Outcome.NOT_RUN, False, True, False)

    @staticmethod
    def interrupt() -> Self:
        """An interrupt aborted this file: no verdict, routes to exit 2."""
        return Self(Event.file_started(""), Outcome.NOT_RUN, False, False, True)


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
    `COMPILE_ERROR`, never a crash); the run maps through `run_verdict`. A spawn
    failure at either step is an internal error; an in-flight interrupt (a
    `TimedOut` with the interrupt flag set) aborts without recording a `TIMEOUT`.

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
    var build_cmd = shell_join(build_argv)

    # Build with NO deadline, inside the invocation root.
    var bres = run_supervised(ProcessSpec.command_in(build_argv^, root, 0))
    var bdur = Float64(bres.duration_ms) / 1000.0

    # An interrupt during the build group-kills it (a TimedOut bail-out).
    if interrupt_requested():
        return FileResult.interrupt()
    var bterm = bres.termination
    if bterm.is_spawn_failed():
        return FileResult.internal()

    var bsignal = build_verdict(bterm)
    if bsignal == Outcome.COMPILE_ERROR:
        var detail = lossy_utf8(bres.stderr_bytes)
        var ev = Event.file_finished(
            rel, Outcome.COMPILE_ERROR, 0.0, build_cmd, bdur, "", "", detail
        )
        return FileResult.ran_with(ev^, Outcome.COMPILE_ERROR)

    # Build OK: run the freshly built binary under the run deadline.
    var run_argv = List[String]()
    run_argv.append(out_bin)
    var rres = run_supervised(
        ProcessSpec.command_in(run_argv^, root, config.timeout_secs * 1000)
    )
    var rterm = rres.termination
    if rterm.is_spawn_failed():
        return FileResult.internal()
    # An in-flight interrupt returns as TimedOut; never record it as a TIMEOUT.
    if rterm.is_timed_out() and interrupt_requested():
        return FileResult.interrupt()

    var outcome = run_verdict(rterm)
    var rdur = Float64(rres.duration_ms) / 1000.0
    var detail = _detail_for(outcome, rterm, config.timeout_secs)
    var ev = Event.file_finished(
        rel,
        outcome,
        rdur,
        build_cmd,
        bdur,
        lossy_utf8(rres.stdout_bytes),
        lossy_utf8(rres.stderr_bytes),
        detail,
    )
    return FileResult.ran_with(ev^, outcome)


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
        return PrecompileResult("", "", False, False, True)
    var term = res.termination
    if term.is_spawn_failed():
        return PrecompileResult("", "", False, True, False)
    if term.is_exited() and term.value == 0:
        var d = dirname(out_path)
        if d == "":
            d = String(".")
        return PrecompileResult(d^, "", True, False, False)
    return PrecompileResult(
        "", lossy_utf8(res.stderr_bytes), False, False, False
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
                e.path, Outcome.EXCLUDED, 0.0, "", 0.0, "", "", e.pattern
            )
        )
        summary.counts[Outcome.EXCLUDED.code] += 1
    for pat in disc.stale_excludes:
        reporter.handle(
            Event.warning(
                "stale-exclusion",
                String("exclude pattern '") + pat + "' matched nothing",
            )
        )

    var run_outcomes = List[Outcome]()
    var interrupted = False
    var internal_error = False
    var precompile_failed = False

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
                    internal_error = True
                    break
                reporter.handle(fr.event)
                summary.counts[fr.outcome.code] += 1
                run_outcomes.append(fr.outcome)
                if fr.outcome.is_failing():
                    gate_abort = True
                    break
            except:
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
                    internal_error = True
                    break
                reporter.handle(fr.event)
                summary.counts[fr.outcome.code] += 1
                run_outcomes.append(fr.outcome)
                if config.exitfirst and fr.outcome.is_failing():
                    break
            except:
                internal_error = True
                break

    # Every selected file that did not produce a verdict is NOT_RUN — a gate
    # casualty, an -x/gate-abort/interrupt skip, or a precompile casualty.
    var not_run = selected - len(run_outcomes)
    summary.counts[Outcome.NOT_RUN.code] += not_run

    var code: Int
    if interrupted:
        code = 2
    elif internal_error:
        code = 3
    elif precompile_failed:
        code = 1
    else:
        code = exit_code_for(run_outcomes)

    var wall = Float64(perf_counter_ns() - started_ns) / 1.0e9
    reporter.handle(Event.session_finished(summary^, wall, code))
    return code
