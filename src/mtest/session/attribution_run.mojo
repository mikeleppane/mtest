"""The bounded crash-attribution post-pass: isolation reruns after a CRASH.

Layer 4, run once after every file has its verdict and before the summary band.
A CRASH verdict is honest but cannot say WHICH test killed the process, so this
pass re-runs a crashed file's tests one at a time and names the first that dies
by signal.

It is SECONDARY EVIDENCE and never a verdict input: it emits `CrashAttribution`
events and one loud announcement and touches nothing else — not the summary
counts, not the run outcomes, not the exit code, not the file's `FileFinished`.
A crashed file's verdict and the process exit code are identical whether the
pass names a culprit, fails to reproduce the crash, or never runs at all. It
sits above `build`'s registry listings, `file_result`, `names`, and the
attribution budget leaf, and below `session`, which schedules it.
"""
from std.os.path import exists
from std.time import perf_counter_ns

from mtest.cache import BuildRegistry
from mtest.config import RunnerConfig, lossy_utf8
from mtest.exec import (
    ExecRuntime,
    ProcessResult,
    ProcessSpec,
    canonicalize,
    interrupt_requested,
    run_supervised,
)
from mtest.model import AttributionDisposition, Event
from mtest.protocol import collection_disqualifier, collection_names
from mtest.report import ReportCoordinator
from mtest.session.attribution import attribution_step, isolation_timeout_secs
from mtest.session.classify import resolve_report
from mtest.session.file_result import _CrashFile
from mtest.session.names import _select_names


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
