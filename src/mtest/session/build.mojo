"""Build one file into the registry and probe it for its test universe.

Layer 4, the shared front half of the selection and collect pipelines: it
compiles a discovered file once, records the build (or the compile error) in the
`cache` registry, then runs the resulting binary under `--skip-all` to learn the
file's test names without running a body. Both passes route every non-qualifying
outcome through the same `resolve_report`/`classify` machinery the default run
path uses, so a crash, a deadline kill, a truncated capture, or an off-grammar
report resolves identically here and there.

It sits above `file_result` and `scratch` and below the selection sub-session,
`collect`, and the crash-attribution post-pass, all of which consume the build
and the universe it produces.
"""
from mtest.cache import BuildProduct, BuildRegistry
from mtest.config import RunnerConfig, lossy_utf8
from mtest.exec import (
    ExecRuntime,
    ProcessResult,
    ProcessSpec,
    canonicalize,
    interrupt_requested,
    run_supervised,
)
from mtest.model import Event, Outcome, ParseDisposition, TestCounts, is_slow
from mtest.protocol import (
    ReportVerdict,
    collection_disqualifier,
    collection_names,
)
from mtest.session.classify import resolve_report
from mtest.session.file_result import FileResult
from mtest.session.scratch import _ensure_dir, _mangle
from mtest.session.verdict import build_verdict


comptime _COMPILE_GRACE_MS = 5000
"""SIGTERM-to-SIGKILL grace for a build killed at `--compile-timeout` (5 s).

Much wider than the run path's 300 ms because a compiler may be mid-write to
the shared module cache; killing it early is the most plausible way to leave
that cache torn. Five seconds lets it unwind and flush. A compiler still alive
after that has ignored SIGTERM and is SIGKILLed, which is when the narrow cache
quarantine on the retry rebuild earns its keep.
"""


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
