"""Build one file into the registry and probe it for its test universe.

Layer 4, the shared front half of the selection and collect pipelines: it
compiles a discovered file once, records the build (or the compile error) in the
`cache` registry, then runs the resulting binary under `--skip-all` to learn the
file's test names without running a body. Both passes route every non-qualifying
outcome through the same `resolve_report`/`classify` machinery the default run
path uses, so a crash, a deadline kill, a truncated capture, or an off-grammar
report resolves identically here and there.

This is also the FIRST of the three build seams into the artifact store. A
first-attempt compile under an enabled `CacheContext` keys the file, probes the
store, and either serves the stored binary (compiling nothing) or compiles
straight into a staging directory and publishes it atomically. Everything else —
a disabled context, a recovery rebuild — builds into `build/bin` exactly as
before, because a retry's binary is invocation-private and must never enter a
store other runs read.

It sits above `file_result`, `scratch`, and `store`, and below the selection
sub-session, `collect`, and the crash-attribution post-pass, all of which consume
the build and the universe it produces.
"""
from mtest.cache import BuildProduct, BuildRegistry
from mtest.config import RunnerConfig, lossy_utf8
from mtest.exec import (
    ExecRuntime,
    ProcessResult,
    ProcessSpec,
    interrupt_requested,
    run_supervised,
    source_identity_key,
)
from mtest.model import Event, Outcome, ParseDisposition, TestCounts, is_slow
from mtest.protocol import (
    ReportVerdict,
    collection_disqualifier,
    collection_names,
)
from mtest.session.classify import resolve_report
from mtest.session.effective_settings import EffectiveFileSettings
from mtest.session.file_result import FileResult
from mtest.session.scratch import _ensure_dir, _mangle
from mtest.session.store import (
    CacheContext,
    FileKey,
    PROBE_HIT,
    PUB_FAILED,
    StoreBuildTarget,
    _rewrite_output,
    file_key,
    remove_tree_no_follow,
    store_build_target,
    store_probe,
    store_publish,
)
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
    var from_store: Bool
    """Whether `binary` is an artifact now owned by the store.

    This covers a warm hit and a generation this call just published or adopted.
    The caller needs it for one decision: a store generation can be removed or
    briefly quarantined before this process executes it, because publishing a
    generation reaps that source's older ones and a second run over the checkout
    can publish at any moment. A run that cannot spawn a binary in that position
    is a file to compile, not an internal error.
    """
    var cache_warning: String
    """Why this build could not be published, or empty when nothing went wrong.

    The caller's channel for the one thing this function can discover and cannot
    report itself: it holds no reporter, and `collect` has no event seam at all.
    A publication failure is never a verdict — the binary that was just built is
    still the binary that runs — so it travels beside the outcome rather than
    inside it.
    """


def _blank_file_result() -> FileResult:
    """A placeholder `FileResult` for the non-terminal `_BuildOutcome` path."""
    return FileResult.interrupt()


def _no_staging() -> StoreBuildTarget:
    """The staging target meaning "this build is not going into the store"."""
    return StoreBuildTarget(String(""), String(""))


def _discard_staging(root: String, target: StoreBuildTarget):
    """Remove a staging directory whose build produced nothing worth keeping.

    Called only where the compile did NOT yield a binary this session will run —
    a compile error, a timeout kill, a spawn failure, an interrupt. A staged
    directory left behind on those paths is pure debris: it is named after this
    process, so no later run can ever adopt or reap it.

    Args:
        root: The invocation root.
        target: The staging target; a target that was never staged is a no-op.
    """
    if not target.ok():
        return
    try:
        remove_tree_no_follow(root + "/" + target.tmp_dir_rel)
    except:
        # A staging directory that will not die is litter under a directory
        # mtest owns; failing the run over it is exactly the "cache condition
        # breaks an otherwise green run" the design forbids.
        pass


def _build_for_selection(
    mut runtime: ExecRuntime,
    config: RunnerConfig,
    settings: EffectiveFileSettings,
    root: String,
    rel: String,
    include_paths: List[String],
    mut reg: BuildRegistry,
    mut ctx: CacheContext,
    attempts_used: Int = 1,
    recovering: Bool = False,
) raises -> _BuildOutcome:
    """Build `rel` into the registry once, or produce a terminal result.

    A compile error records a compile-error entry and returns a terminal
    compile-error result; a spawn or machinery failure returns a terminal
    internal-error result; an interrupt returns a terminal interrupt. On success
    the registry holds the fresh build, and the binary and canonical paths ride
    back for the probe and the run to share.

    The artifact store is consulted on a FIRST attempt under an enabled context,
    and only there. A hit compiles nothing: the stored binary, its recorded
    command line, and its original build duration ride back exactly as a fresh
    build's would, and the `--skip-all` probe still runs on it downstream. A miss
    compiles into a staging directory inside the store and publishes it
    atomically; a publication that fails leaves the staged binary alive, because
    that binary is the one this session is about to run.

    Args:
        runtime: The exec runtime supervising the build spawn.
        config: The resolved runner configuration.
        settings: The file's effective build deadline and other policy.
        root: The invocation root the compiler runs in.
        rel: The root-relative path of the file to build.
        include_paths: Directories passed to the compiler as `-I`.
        reg: The build registry that records the build or compile error.
        ctx: The session's cache state. Its counters are advanced here — one
            `built_files` per first-attempt compile admission (compile failures
            included), one `cached_files` per hit — and it is switched off if
            this file proves the store unusable.
        attempts_used: The current file attempt, for a terminal recovery build.
            It is the CRASH-class attempt number and is 1 on a stale-name
            recovery too, so it never decides whether the store is consulted.
        recovering: Whether this is the stale-name recover-once rebuild rather
            than the file's first compile. A recovery rebuild is
            invocation-private: it never keys, probes, publishes, or counts. It
            exists precisely to obtain a binary the store's answer would not
            give — serving the generation this session just published would make
            the rebuild a no-op and the recovery a lie.

    Returns:
        The build outcome, terminal or ready-to-probe.

    Raises:
        Error: If the build output directory cannot be made, or if
            canonicalizing the source path after a successful build fails. The
            registry writes are non-raising, and the build spawn is caught here
            and turned into a terminal internal-error result. Nothing in the
            cache path raises: an unusable store costs a rebuild, never a run.
    """
    # `build/bin` is created unconditionally, exactly as before: a recovery
    # rebuild lands there, and so does every build under a disabled cache — and
    # a compile error's reproduce line names it (see the failing branch below),
    # so it has to be a directory a user can actually build into.
    _ensure_dir(root + "/build/bin")
    var mangled = _mangle(rel)
    var plain_out = String("build/bin/") + mangled
    var out_bin = plain_out
    var first_attempt = not recovering
    var target = _no_staging()
    var key = Optional[FileKey](None)
    var cache_warning = String("")
    var from_store = False

    if ctx.enabled and first_attempt:
        key = file_key(ctx, root, rel)
        if not key:
            # A source that will not read is about to fail its build anyway, and
            # a key that cannot cover its own source must never be written.
            ctx.disable("cannot read the test file '" + rel + "'")
        else:
            var hit = store_probe(root, key.value())
            if hit.kind == PROBE_HIT:
                var stored = source_identity_key(root, rel)
                reg.record_build(BuildProduct.built(rel, hit.bin_rel, stored))
                ctx.cached_files += 1
                # The stored build's own duration, not zero: the SLOW token must
                # read the same on a warm run as it did on the cold one.
                return _BuildOutcome(
                    True,
                    hit.bin_rel,
                    stored,
                    hit.argv.copy(),
                    hit.build_seconds,
                    False,
                    _blank_file_result(),
                    True,
                    String(""),
                )
            target = store_build_target(root, mangled)
            if target.ok():
                # Compile straight into the store, so publication is one
                # `rename(2)` and never a copy of a binary that could differ
                # from the one that was digested.
                out_bin = target.out_rel
            else:
                # Cache off for the session: a store that cannot be staged into
                # once will not stage the next file either, and probing on would
                # spend a digest per file for a hit that can never be published.
                ctx.disable(
                    "the cache could not create its store directory under"
                    " '.mtest-cache'"
                )
                key = Optional[FileKey](None)

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

    if first_attempt:
        # ADMISSION, and the only place either counter moves on this path: the
        # file is about to be compiled for the first time, so it is a built
        # file whatever the compiler goes on to say about it. Counting after the
        # spawn would quietly drop every compile error out of the accounting and
        # break `built_files + cached_files == first-attempt admissions`.
        ctx.built_files += 1

    var bres: ProcessResult
    try:
        bres = run_supervised(
            runtime,
            ProcessSpec.command_in(
                build_argv.copy(),
                root,
                settings.compile_timeout_secs * 1000,
                _COMPILE_GRACE_MS,
            ),
        )
    except:
        _discard_staging(root, target)
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
            False,
            String(""),
        )
    var bdur = Float64(bres.duration_ms) / 1000.0
    if interrupt_requested():
        _discard_staging(root, target)
        return _BuildOutcome(
            False,
            "",
            "",
            List[String](),
            0.0,
            True,
            FileResult.interrupt(),
            False,
            String(""),
        )
    var bterm = bres.termination
    if bterm.is_spawn_failed():
        _discard_staging(root, target)
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
            False,
            String(""),
        )
    var bsignal = build_verdict(bterm)
    if bsignal.is_failing():
        # COMPILE_ERROR, or COMPILE_TIMEOUT when `--compile-timeout` killed the
        # build. Either way the file is terminal here and never probed or run.
        var bto = 0
        if bsignal == Outcome.COMPILE_TIMEOUT:
            bto = settings.compile_timeout_secs
        reg.record_compile_error(rel, lossy_utf8(bres.stderr_bytes))
        # The reproduce line names `build/bin`, never the staging directory the
        # compile actually wrote to. A failed build publishes nothing, so that
        # directory is deleted on the next line and a line naming it would be a
        # line no user could ever run; `build/bin/<mangled>` is where an
        # uncached build puts this file's binary and is live either way. This is
        # the same liberty `store_publish` takes on success, for the same
        # reason: record the path the artifact can be reached at.
        var shown_argv = _rewrite_output(build_argv, out_bin, plain_out)
        _discard_staging(root, target)
        var ev = Event.file_finished(
            rel,
            bsignal,
            0.0,
            shown_argv.copy(),
            bdur,
            List[UInt8](),
            bres.stderr_bytes.copy(),
            timeout_seconds=bto,
            attempts_used=attempts_used,
            slow=is_slow(bdur, 0.0),
        )
        return _BuildOutcome(
            False,
            "",
            "",
            shown_argv^,
            bdur,
            True,
            FileResult.ran_with(ev^, bsignal),
            False,
            String(""),
        )
    var canonical = source_identity_key(root, rel)
    var final_bin = out_bin
    var recorded_argv = build_argv.copy()
    if target.ok() and key:
        var pub = store_publish(root, key.value(), target, bdur, build_argv)
        # The rule with no exceptions: run `bin_rel`, record `argv`. On PUB_OK
        # the staging directory this build's own argv names is already gone; on
        # PUB_ADOPTED the live binary belongs to a generation this run never
        # built and whose command line it therefore cannot reconstruct; on
        # PUB_FAILED both are this run's own staging path, which is still there.
        final_bin = pub.bin_rel
        recorded_argv = pub.argv.copy()
        if pub.kind == PUB_FAILED:
            cache_warning = pub.warning
        else:
            # Publication or adoption puts the path this selection driver will
            # probe under store ownership. The probe's bounded recovery must
            # cover the same quarantine pathname gap as a warm hit.
            from_store = True
    reg.record_build(BuildProduct.built(rel, final_bin, canonical))
    return _BuildOutcome(
        True,
        final_bin,
        canonical,
        recorded_argv^,
        bdur,
        False,
        _blank_file_result(),
        from_store,
        cache_warning^,
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
    attempts_used: Int = 1,
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
        attempts_used: The current file attempt, for a terminal recovery probe.
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
        attempts_used=attempts_used,
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
    settings: EffectiveFileSettings,
    root: String,
    rel: String,
    binary: String,
    canonical: String,
    build_argv: List[String],
    bdur: Float64,
    mut reg: BuildRegistry,
    attempts_used: Int = 1,
) raises -> _ProbeOutcome:
    """Run the `--skip-all` probe and route its result.

    Termination handling is total, mirroring `_run_one`'s run-phase policy so a
    probe never resolves differently than the default path would: a spawn
    failure is an internal error (exit 3); an interrupt-induced timeout is an
    interrupt (exit 2); a signaled probe is that file's crash; a plain timeout
    is a timeout. On a clean exit the captured stdout is decoded and resolved
    under the same truncation policy the run path uses (`resolve_report`), so
    only a report wholly retained in the tail is trusted and a forged report in
    a truncated head is refused as capture overflow: a failing outcome, never a
    qualifying listing.

    A qualifying probe yields the universe as its collection listing, recorded
    in the registry. An off-grammar probe is drift (exit 3); a capture-overflow
    probe is `CAPTURE_OVERFLOW` (exit-1 class); an absent, ambiguous, or valid
    but disqualified probe is `MALFORMED_SUITE`, meaning the module ran bodies
    or ignored `--skip-all`.

    Args:
        runtime: The exec runtime supervising the probe spawn.
        settings: The file's effective probe deadline and other policy.
        root: The invocation root the probe runs in.
        rel: The root-relative path of the probed file.
        binary: The already-built binary to probe.
        canonical: The canonical source path the report must name.
        build_argv: The build command, for a terminal verdict's reproduce line.
        bdur: The build wall time in seconds.
        reg: The build registry that records the collected universe.
        attempts_used: The current file attempt, for a terminal recovery probe.

    Returns:
        The probe outcome: a qualifying universe, or a terminal result.

    Raises:
        Error: If the `exec` machinery itself fails or the registry write fails.
    """
    var argv = List[String]()
    argv.append(binary)
    argv.append("--skip-all")
    var pres = run_supervised(
        runtime,
        ProcessSpec.command_in(argv^, root, settings.timeout_secs * 1000),
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
                attempts_used=attempts_used,
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
                timeout_seconds=settings.timeout_secs,
                attempts_used=attempts_used,
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
                attempts_used=attempts_used,
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
                attempts_used=attempts_used,
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
            attempts_used=attempts_used,
            stdout_truncated=pres.stdout_truncated,
            stderr_truncated=pres.stderr_truncated,
        ),
        False,
        False,
    )
