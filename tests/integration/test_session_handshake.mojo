"""The run-report-as-handshake, proven end to end through a real build+run.

The session now PARSES each run's own report and classifies the file with a
TOTAL policy — the pure classifier is table-tested in
`test_session_classify.mojo`; this module proves the WIRING against real
adversaries built and executed for real. A silent binary is MALFORMED_SUITE (it
spoke no report), a forger that appends a second block is MALFORMED_SUITE
(AMBIGUOUS), a liar whose report drifts off the pinned grammar routes to exit 3
(DRIFT), and a suite that collects ZERO tests is a PASS that ran zero tests — the
closed zero-test ceiling, PASS-from-a-parsed-report, never PASS-from-exit-status.
"""
from std.testing import assert_equal, assert_true

from mtest.model import Event, EventKind, Outcome, ParseDisposition
from mtest.report import CompositeReporter, RecordingReporter
from mtest.session import run_session

from session_fixtures import (
    SRC_FLOOD_PROBE,
    SRC_FORGER,
    SRC_LIAR,
    SRC_SILENT,
    SRC_ZERO,
    base_config,
    temp_root,
    write_file,
)


def _finished(rec: RecordingReporter) raises -> Event:
    """The single FILE_FINISHED event in the stream (fails if not exactly one).
    """
    var found = -1
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_FINISHED:
            assert_true(found < 0, "more than one FILE_FINISHED")
            found = i
    assert_true(found >= 0, "no FILE_FINISHED event")
    return rec.event_at(found)


def test_silent_binary_is_malformed_suite() raises:
    var root = temp_root()
    write_file(root, "tests/test_silent.mojo", SRC_SILENT)

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(base_config(), root, comp)

    assert_equal(code, 1, "a malformed suite is in the failing class")
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.outcome == Outcome.MALFORMED_SUITE,
        "a file that spoke no report is MALFORMED_SUITE",
    )
    assert_true(finished.parse_disposition == ParseDisposition.NO_REPORT)


def test_forger_two_blocks_is_malformed_suite_ambiguous() raises:
    var root = temp_root()
    write_file(root, "tests/test_forger.mojo", SRC_FORGER)

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(base_config(), root, comp)

    assert_equal(code, 1)
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(finished.outcome == Outcome.MALFORMED_SUITE)
    assert_true(
        finished.parse_disposition == ParseDisposition.AMBIGUOUS,
        "a second appended block is AMBIGUOUS",
    )
    # A loud warning names what was ambiguous.
    var saw_warning = False
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.WARNING:
            saw_warning = True
    assert_true(saw_warning, "an ambiguous report must warn")


def test_liar_off_grammar_routes_to_exit_3_drift() raises:
    var root = temp_root()
    write_file(root, "tests/test_liar.mojo", SRC_LIAR)

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(base_config(), root, comp)

    assert_equal(code, 3, "an off-grammar report routes to exit 3 (drift)")
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.parse_disposition == ParseDisposition.DRIFT,
        "an off-grammar report is DRIFT",
    )
    # Drift emits a diagnostic warning carrying the reason, and the file is
    # accounted NOT_RUN (it contributes nothing to the run outcomes).
    var saw_drift_warning = False
    for i in range(rec.count()):
        if (
            rec.kind_at(i) == EventKind.WARNING
            and rec.event_at(i).warning_kind == "drift"
        ):
            saw_drift_warning = True
    assert_true(saw_drift_warning, "drift must emit a drift warning")
    var last = rec.event_at(rec.count() - 1)
    assert_true(last.kind == EventKind.SESSION_FINISHED)
    assert_equal(last.exit_code, 3)
    assert_equal(last.summary.count_of(Outcome.NOT_RUN), 1)


def test_zero_test_report_is_pass_that_ran_zero_tests() raises:
    var root = temp_root()
    write_file(root, "tests/test_zero.mojo", SRC_ZERO)

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(base_config(), root, comp)

    # A single zero-test file: it PASSED at the file level, but no test actually
    # ran, so the run-outcome multiset is empty -> exit 5 (nothing ran). The
    # ceiling is closed: this is PASS-from-a-parsed-zero-test-report.
    assert_equal(code, 5)
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(finished.outcome == Outcome.PASS)
    assert_true(finished.parse_disposition == ParseDisposition.PARSED)
    assert_equal(finished.passed_tests, 0)
    assert_equal(finished.failed_tests, 0)
    # No per-test row was reported (zero tests collected).
    var test_reports = 0
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.TEST_REPORTED:
            test_reports += 1
    assert_equal(test_reports, 0)


def test_plain_run_overflow_marks_stdout_truncated() raises:
    # A real one-test suite that prints a complete report, then floods stdout
    # far past the capture bound. The plain (non-selection) run path applies
    # the SAME truncation-distrust policy the probe does, so the overflow is a
    # failing outcome — and the file-scope process result's own truncation
    # must ride the verdict honestly, not silently default to "nothing was
    # cut".
    var root = temp_root()
    write_file(root, "tests/test_flood.mojo", SRC_FLOOD_PROBE)
    var cfg = base_config()
    cfg.timeout_secs = 30

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1, "an overflowing plain run is a failing outcome")
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.parse_disposition == ParseDisposition.CAPTURE_OVERFLOW,
        "an overflowing plain run is CAPTURE_OVERFLOW",
    )
    assert_true(
        finished.stdout_truncated,
        "the plain run's own overflow must mark stdout_truncated",
    )
