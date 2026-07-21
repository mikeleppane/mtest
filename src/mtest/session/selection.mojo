"""The selection sub-session: probe every run file, then run its chosen subset.

Layer 4, the path taken when any operand is a node id or `-k` is present. This
module is the DRIVER: it asks `pipeline`'s `RunPipeline` kernel which step the
run wants next — build this file, probe it, announce the collection, replay a
terminal verdict, skip a fully deselected file, run a selection — executes that
one step against `exec`, and folds what happened back into the kernel. The
kernel decides; the driver performs. Exactly one step is ever in flight.

The kernel's collection barrier is what makes the run two-pass: every run file
is built and probed so the run-wide selected and deselected totals are known
before a single body executes, and only then does each file's subset run under
`--only`, suppressing the deselected rows and reconciling what came back
against the universe the probe collected. A row set that disagrees with the
universe, or a deselected test that ran anyway, is a malformed suite at exit 1 —
never drift, which stays reserved for a report that left the pinned grammar.

Two recovery mechanisms compose here with separate budgets, both admitted by the
kernel: a bounded recover-once for a suite that refuses a name it just listed
(rebuild, re-probe, re-select, run again), and the `--retries` crash-class
budget (re-run the same binary, no rebuild). A stale-name refusal is an
`Exited(1)` diagnostic, so it is never crash-class and the two never contend for
the same failure. Their events interleave in one chronological stream prepended
to the file's verdict.

It sits above `pipeline`, `build`, `attempt`, `file_result`, and `names`, and
below `session`, which folds its summary into the run accounting.
"""
from std.os.path import isdir

from mtest.cache import BuildRegistry
from mtest.config import RunnerConfig, lossy_utf8
from mtest.discover import normalize_operand, normalize_root
from mtest.discover.result import DiscoveryResult
from mtest.exec import (
    ExecRuntime,
    ProcessResult,
    ProcessSpec,
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
    is_slow,
)
from mtest.protocol import ParsedReport, ParsedRow, ReportVerdict
from mtest.report import ReportCoordinator
from mtest.select import FileIntent, OperandParse, select_from
from mtest.session.attempt import _AttemptResult, _make_attempt_finished
from mtest.session.build import (
    _BuildOutcome,
    _ProbeOutcome,
    _blank_file_result,
    _build_for_selection,
    _probe_file,
)
from mtest.session.classify import classify, resolve_report
from mtest.session.file_result import (
    FileResult,
    _CrashFile,
    _failing_count,
    _prepend_events,
)
from mtest.session.names import _same_set, _str_in
from mtest.session.pipeline import (
    FileStage,
    PipelineHalt,
    RunPipeline,
    StepKind,
)
from mtest.session.retry_class import retry_classify


comptime _STALE_NAME_PHRASE = "test not found in suite:"
"""The stdlib phrase when `--only` names a test the suite no longer offers."""

comptime _UNHANDLED_PREFIX = "Unhandled exception caught during execution:"
"""The runtime framing that carries a stale-name refusal as its payload.

A stale-name refusal aborts the suite before any report is printed, so the
stdlib emits the phrase as this line's payload — e.g. `Unhandled exception
caught during execution: explicitly allowed test not found in suite: test_x`.
Anchoring stale-name detection on this framing keeps a test that merely prints
the phrase in its own output from tripping a wasted rebuild and reprobe."""


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
struct _Collected(Copyable, Movable):
    """One run file's payload, carried across the steps the pipeline requests.

    Owns its lists and its terminal result; copies are explicit. The build and
    probe fields are replaced wholesale by a stale-name recovery rebuild, never
    patched field by field, so no stale binary, canonical source, or universe
    survives one.
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
    var pre_stream: List[Event]
    """The attempt and recovery events accumulated across this file's steps,
    prepended to its verdict when it finally settles."""
    var had_crash_retry: Bool
    """Whether an earlier attempt was crash-class, which promotes a late pass
    to FLAKY."""


def _blank_collected(rel: String) -> _Collected:
    """An admitted-but-untouched run file, before its build step runs.

    Args:
        rel: The root-relative path of the discovered file.

    Returns:
        The file's initial payload. Allocates its empty lists.
    """
    return _Collected(
        rel,
        False,
        _blank_file_result(),
        List[String](),
        List[String](),
        List[String](),
        FileIntent.whole_file(),
        "",
        "",
        List[String](),
        0.0,
        List[Event](),
        False,
    )


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


def _selection_run_argv(
    binary: String, selected: List[String], universe: List[String]
) -> List[String]:
    """Build one selected run's argv: plain when whole, else under `--only`.

    Args:
        binary: The built binary to execute.
        selected: The names the selection chose to run.
        universe: The names the probe collected.

    Returns:
        The argv to supervise. Allocates the list.
    """
    var argv = List[String]()
    argv.append(binary)
    if not _same_set(selected, universe):
        argv.append("--only")
        for nm in selected:
            argv.append(nm)
    return argv^


def _stale_name_warning(rel: String) -> Event:
    """The loud warning a first stale-name refusal emits before recovering.

    Args:
        rel: The root-relative path of the refusing file.

    Returns:
        The `Warning` event to prepend to the file's verdict.
    """
    return Event.warning(
        "stale-name",
        (
            "the suite for '"
            + rel
            + "' refused a test it listed under --skip-all ('"
            + _STALE_NAME_PHRASE
            + "'); rebuilding and recollecting once before retrying"
        ),
    )


def _chameleon_result(
    c: _Collected,
    term: ProcessResult,
    attempts_used: Int,
) -> FileResult:
    """The verdict for a suite that refused a listed name twice running.

    A second stale-name refusal after a fresh rebuild and recollect is a
    malformed suite at exit 1 — the module's `--skip-all` listing disagrees
    with the names it accepts under `--only` — never drift.

    Args:
        c: The refusing file's payload.
        term: The refusing run's process result.
        attempts_used: How many attempts the run spent.

    Returns:
        The terminal `FileResult`.
    """
    return _run_terminal_file(
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
        c.build_argv,
        c.bdur,
        Float64(term.duration_ms) / 1000.0,
        term,
        len(c.deselected),
        attempts_used=attempts_used,
    )


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

    Drives the `RunPipeline` kernel, which decides which step comes next; this
    function only executes the step it is handed and folds the result back. The
    kernel's collection barrier is what makes the run two-pass: every file is
    built, probed, and selected before the run-wide selected and deselected
    totals are emitted as `collection_known`, and only then does any test body
    execute. Exactly one step is ever in flight.

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

    var collected = List[_Collected]()
    for ri in range(len(disc.run_files)):
        collected.append(_blank_collected(disc.run_files[ri]))

    var pipeline = RunPipeline(
        len(disc.run_files), config.retries, config.exitfirst, config.maxfail
    )
    var attempts_planned = config.retries + 1

    var announced = False
    var run_outcomes = List[Outcome]()
    var test_totals = TestCounts.zeros()
    var ran_files = 0
    var drift = False
    var crash_files = List[_CrashFile]()

    while True:
        var step = pipeline.next_step()
        if step.kind == StepKind.NOTHING:
            break

        if step.kind == StepKind.ANNOUNCE_COLLECTION:
            # Collection is known: emit the run-wide totals before any body
            # runs. A file that never became runnable contributes neither.
            var sel_total = 0
            var desel_total = 0
            for c in collected:
                if not c.terminal:
                    sel_total += len(c.selected)
                    desel_total += len(c.deselected)
            reporter.handle(Event.collection_known(sel_total, desel_total))
            announced = True
            pipeline.record_collection_announced()
            continue

        var i = step.file_index

        if step.kind == StepKind.BUILD_FILE:
            # The interrupt poll sits at each file's FIRST step of a pass, not
            # at every step: a recovery rebuild belongs to a file already in
            # flight and is not a fresh scheduling boundary.
            if not step.recovering and interrupt_requested():
                pipeline.halt_interrupted()
                continue
            var bo: _BuildOutcome
            try:
                bo = _build_for_selection(
                    runtime, config, root, collected[i].rel, include_paths, reg
                )
            except:
                reporter.handle(
                    Event.internal_error("build", config.mojo_path, 0)
                )
                pipeline.halt_internal_error()
                continue
            if bo.terminal:
                if bo.result.interrupted:
                    pipeline.halt_interrupted()
                    continue
                if bo.result.internal_error:
                    reporter.handle(bo.result.event)
                    pipeline.halt_internal_error()
                    continue
                if step.recovering:
                    # The file's verdict stream is already open: settle it now,
                    # carrying the recovery events that precede it.
                    var rfr = _prepend_events(
                        collected[i].pre_stream.copy(), bo.result.copy()
                    )
                    collected[i].build_argv = bo.build_argv.copy()
                    collected[i].bdur = bo.bdur
                    for pe in rfr.pre_events:
                        reporter.handle(pe)
                    reporter.handle(rfr.event)
                    test_totals.deselected += rfr.test_counts.deselected
                    if rfr.is_drift:
                        drift = True
                        pipeline.record_settled(i)
                        continue
                    summary.counts[rfr.outcome.code] += 1
                    run_outcomes.extend(rfr.exit_outcomes.copy())
                    ran_files += 1
                    pipeline.record_verdict(
                        i,
                        rfr.outcome.is_failing(),
                        _failing_count(run_outcomes),
                    )
                    continue
                # A compile-error terminal: replay it in the run pass with the
                # others, so it honors discovery order and the stop limits.
                collected[i].terminal = True
                collected[i].terminal_result = bo.result.copy()
                collected[i].build_argv = bo.build_argv.copy()
                collected[i].bdur = bo.bdur
                pipeline.record_build_terminal(i)
                continue
            # A rebuild replaces the whole product, never a field at a time.
            collected[i].binary = bo.binary
            collected[i].canonical = bo.canonical
            collected[i].build_argv = bo.build_argv.copy()
            collected[i].bdur = bo.bdur
            pipeline.record_build_ready(i)
            continue

        if step.kind == StepKind.PROBE_FILE:
            var po: _ProbeOutcome
            try:
                po = _probe_file(
                    runtime,
                    config,
                    root,
                    collected[i].rel,
                    collected[i].binary,
                    collected[i].canonical,
                    collected[i].build_argv,
                    collected[i].bdur,
                    reg,
                )
            except:
                reporter.handle(
                    Event.internal_error("probe", collected[i].binary, 0)
                )
                pipeline.halt_internal_error()
                continue
            if po.interrupted:
                pipeline.halt_interrupted()
                continue
            if po.internal_error:
                reporter.handle(po.result.event)
                pipeline.halt_internal_error()
                continue
            if po.terminal:
                if step.recovering:
                    var pfr = _prepend_events(
                        collected[i].pre_stream.copy(), po.result.copy()
                    )
                    for pe in pfr.pre_events:
                        reporter.handle(pe)
                    reporter.handle(pfr.event)
                    test_totals.deselected += pfr.test_counts.deselected
                    if pfr.is_drift:
                        drift = True
                        pipeline.record_settled(i)
                        continue
                    summary.counts[pfr.outcome.code] += 1
                    run_outcomes.extend(pfr.exit_outcomes.copy())
                    ran_files += 1
                    if pfr.outcome == Outcome.CRASH:
                        # A recovery re-probe that dies by signal is a crash
                        # like any other: it must reach the attribution pass,
                        # or its banner count is short and its
                        # `CrashAttribution` row never renders. The rebuild
                        # rewrites the binary in place — `_mangle(rel)` is
                        # injective in `rel` alone — so the path here is the
                        # same string the pre-rebuild build produced.
                        crash_files.append(
                            _CrashFile(
                                collected[i].rel,
                                collected[i].binary,
                                collected[i].selected.copy(),
                            )
                        )
                    pipeline.record_verdict(
                        i,
                        pfr.outcome.is_failing(),
                        _failing_count(run_outcomes),
                    )
                    continue
                collected[i].terminal = True
                collected[i].terminal_result = po.result.copy()
                pipeline.record_probe_terminal(i)
                continue
            # Qualified: select from the fresh universe. An unknown named test
            # is a `select:` usage error and propagates to exit 4.
            collected[i].universe = po.universe.copy()
            if not step.recovering:
                collected[i].intent = _intent_for(collected[i].rel, plan, nroot)
            var sr = select_from(
                collected[i].universe,
                collected[i].rel,
                collected[i].intent,
                config.keyword,
            )
            collected[i].selected = sr.selected.copy()
            collected[i].deselected = sr.deselected.copy()
            pipeline.record_probe_qualified(i, len(sr.selected) == 0)
            continue

        # --- the run pass: replay, skip, or run one file --------------------
        # A file's first step in this pass is its scheduling boundary: poll the
        # interrupt there and announce it started. A crash retry or a recovery
        # re-run is a continuation of a file already announced.
        var first_touch = pipeline.stage_of(i) == FileStage.COLLECTED
        if first_touch:
            if interrupt_requested():
                pipeline.halt_interrupted()
                continue
            reporter.handle(Event.file_started(collected[i].rel))

        if step.kind == StepKind.REPLAY_TERMINAL:
            var fr = collected[i].terminal_result.copy()
            for pe in fr.pre_events:
                reporter.handle(pe)
            reporter.handle(fr.event)
            test_totals.deselected += fr.test_counts.deselected
            if fr.is_drift:
                drift = True
                pipeline.record_settled(i)
                continue
            summary.counts[fr.outcome.code] += 1
            run_outcomes.extend(fr.exit_outcomes.copy())
            ran_files += 1
            if fr.outcome == Outcome.CRASH:
                crash_files.append(
                    _CrashFile(
                        collected[i].rel,
                        collected[i].binary,
                        collected[i].selected.copy(),
                    )
                )
            pipeline.record_verdict(
                i, fr.outcome.is_failing(), _failing_count(run_outcomes)
            )
            continue

        if step.kind == StepKind.SKIP_DESELECTED:
            # Every test deselected: the file is NOT executed. Account the
            # deselections; the file itself lands in the NOT-RUN accounting.
            reporter.handle(
                Event.file_finished(
                    collected[i].rel,
                    Outcome.NOT_RUN,
                    0.0,
                    collected[i].build_argv.copy(),
                    collected[i].bdur,
                    List[UInt8](),
                    List[UInt8](),
                    deselected_tests=len(collected[i].deselected),
                    slow=is_slow(collected[i].bdur, 0.0),
                )
            )
            test_totals.deselected += len(collected[i].deselected)
            pipeline.record_settled(i)
            continue

        # StepKind.RUN_SELECTION.
        var run_argv = _selection_run_argv(
            collected[i].binary, collected[i].selected, collected[i].universe
        )
        var rres: ProcessResult
        try:
            rres = run_supervised(
                runtime,
                ProcessSpec.command_in(
                    run_argv^, root, config.timeout_secs * 1000
                ),
            )
        except:
            reporter.handle(Event.internal_error("run", collected[i].binary, 0))
            pipeline.halt_internal_error()
            continue
        var rterm = rres.termination
        if rterm.is_spawn_failed():
            reporter.handle(
                Event.internal_error("run", collected[i].binary, rterm.value)
            )
            pipeline.halt_internal_error()
            continue
        if rterm.is_timed_out() and interrupt_requested():
            pipeline.halt_interrupted()
            continue

        # Stale-name detection PARSES the report first: a VALID report — even a
        # FAIL — is a genuine per-test result, never a stale-name refusal. Only
        # when the run produced NO valid report AND the stdlib's anchored
        # refusal diagnostic appears is this a stale name (which a bare
        # substring in a test's own output must never forge).
        var stdout_text = lossy_utf8(rres.stdout_bytes)
        var run_trusted = resolve_report(
            stdout_text, collected[i].canonical, rres.stdout_truncated
        )
        var no_valid_report = run_trusted.report.verdict != ReportVerdict.VALID
        var is_stale = (
            rterm.is_exited()
            and rterm.value == 1
            and no_valid_report
            and _has_stale_name_diagnostic(stdout_text)
        )

        var fr: FileResult
        if is_stale:
            if pipeline.admit_stale_name_recovery(i):
                # Warn loudly, then rebuild with an atomic registry replace and
                # re-probe before retrying. The kernel routes the next two
                # steps; a second refusal after that is the chameleon.
                collected[i].pre_stream.append(
                    _stale_name_warning(collected[i].rel)
                )
                continue
            fr = _chameleon_result(collected[i], rres, step.attempt)
        else:
            # A crash-class run (signal / deadline; an interrupt was
            # short-circuited above) is re-run when attempts remain.
            # Deterministic outcomes (a FAIL, malformed suite, capture
            # overflow, drift) classify NOT eligible and finalize now.
            var rc = retry_classify("run", rterm, False, rres.stderr_bytes)
            if rc.retry_eligible and pipeline.admit_crash_retry(i):
                collected[i].had_crash_retry = True
                var att = _AttemptResult._selection_run(
                    collected[i].binary,
                    rterm,
                    rres.stdout_bytes.copy(),
                    rres.stderr_bytes.copy(),
                    Float64(rres.duration_ms) / 1000.0,
                    rres.stdout_truncated,
                    rres.stderr_truncated,
                )
                collected[i].pre_stream.append(
                    _make_attempt_finished(
                        collected[i].rel,
                        rc,
                        att,
                        step.attempt,
                        attempts_planned,
                    )
                )
                continue
            fr = _reconcile_and_classify(
                config,
                collected[i].rel,
                rres,
                collected[i].universe,
                collected[i].selected,
                collected[i].deselected,
                collected[i].build_argv,
                collected[i].bdur,
                collected[i].canonical,
                attempts_used=step.attempt,
                flaky_if_pass=collected[i].had_crash_retry,
            )

        var settled = _prepend_events(collected[i].pre_stream.copy(), fr^)
        for pe in settled.pre_events:
            reporter.handle(pe)
        reporter.handle(settled.event)
        test_totals.passed += settled.test_counts.passed
        test_totals.failed += settled.test_counts.failed
        test_totals.skipped += settled.test_counts.skipped
        test_totals.deselected += settled.test_counts.deselected
        if settled.is_drift:
            drift = True
            pipeline.record_settled(i)
            continue
        summary.counts[settled.outcome.code] += 1
        run_outcomes.extend(settled.exit_outcomes.copy())
        ran_files += 1
        if settled.outcome == Outcome.CRASH:
            crash_files.append(
                _CrashFile(
                    collected[i].rel,
                    collected[i].binary,
                    collected[i].selected.copy(),
                )
            )
        pipeline.record_verdict(
            i, settled.outcome.is_failing(), _failing_count(run_outcomes)
        )

    var interrupted = pipeline.halt() == PipelineHalt.INTERRUPTED
    var internal_error = pipeline.halt() == PipelineHalt.INTERNAL_ERROR

    # An abort before the collection barrier discards the front half's work:
    # nothing ran, so the sub-session folds back no outcomes and no totals.
    if not announced:
        return SelectionSummary(
            List[Outcome](),
            TestCounts.zeros(),
            0,
            interrupted,
            internal_error,
            False,
            List[_CrashFile](),
        )

    return SelectionSummary(
        run_outcomes^,
        test_totals,
        ran_files,
        interrupted,
        internal_error,
        drift,
        crash_files^,
    )
