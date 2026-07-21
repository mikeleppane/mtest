"""The selection sub-session: probe every run file, then run its chosen subset.

Layer 4, the path taken when any operand is a node id or `-k` is present. A
first pass builds and probes every run file so the run-wide selected and
deselected totals are known before a single body executes; a second pass runs
each file's subset under `--only`, suppressing the deselected rows, and
reconciles what came back against the universe the probe collected. A row set
that disagrees with the universe, or a deselected test that ran anyway, is a
malformed suite at exit 1 — never drift, which stays reserved for a report that
left the pinned grammar.

Two recovery mechanisms compose here with separate budgets: a bounded
recover-once for a suite that refuses a name it just listed, and the `--retries`
crash-class budget. It sits above `build`, `attempt`, `file_result`, and
`names`, and below `session`, which folds its summary into the run accounting.
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
