"""Table tests for the PURE per-test classifier (Layer 4).

`run_verdict` maps a bare termination; `classify` is the richer, TOTAL policy
that folds the RUN termination together with the run's own parsed report and the
capture-overflow signal into a file outcome, a parse disposition, the per-test
counts, and the exit-code multiset contribution. This module pins EVERY row of
that policy table with synthesized `Termination` + `ParsedReport` inputs — no
processes, no filesystem — exactly as `test_session_verdict.mojo` pins the bare
mapping. `resolve_report` (the capture-overflow tail reparse) is pinned here too.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.exec import Termination
from mtest.model import Outcome, ParseDisposition
from mtest.protocol import ParsedReport, ParsedRow, ReportVerdict
from mtest.session import classify, resolve_report


def _row(name: String, oc: Outcome) -> ParsedRow:
    """A minimal parsed row with no detail or timing."""
    return ParsedRow(name, oc, "", "")


def _valid(
    var rows: List[ParsedRow], passed: Int, failed: Int, skipped: Int
) -> ParsedReport:
    """A VALID report whose declared count reconciles with the tallies."""
    var trailer = failed > 0
    return ParsedReport.valid(
        rows^, passed + failed + skipped, passed, failed, skipped, trailer
    )


# ---- abnormal terminations (parser unconsulted or overridden) ----------------


def test_signaled_is_crash_no_report() raises:
    var c = classify(Termination.signaled(11), ParsedReport.absent(), False)
    assert_true(c.file_outcome == Outcome.CRASH)
    assert_true(c.disposition == ParseDisposition.NO_REPORT)
    assert_false(c.is_drift)
    assert_equal(len(c.exit_outcomes), 1)
    assert_true(c.exit_outcomes[0] == Outcome.CRASH)
    assert_equal(c.warning_kind, "")


def test_timed_out_is_timeout_no_report() raises:
    var t = Termination.timed_out(Termination.SIGNALED, 15, True)
    var c = classify(t, ParsedReport.absent(), False)
    assert_true(c.file_outcome == Outcome.TIMEOUT)
    assert_true(c.disposition == ParseDisposition.NO_REPORT)
    assert_equal(len(c.exit_outcomes), 1)
    assert_true(c.exit_outcomes[0] == Outcome.TIMEOUT)
    assert_equal(c.warning_kind, "")


def test_timeout_valid_report_does_not_rescue() raises:
    # A latched TIMEOUT stays TIMEOUT even if a complete valid report was seen.
    var rows = [_row("a", Outcome.PASS)]
    var t = Termination.timed_out(Termination.EXITED, 0, False)
    var c = classify(t, _valid(rows^, 1, 0, 0), False)
    assert_true(c.file_outcome == Outcome.TIMEOUT)
    assert_true(c.disposition == ParseDisposition.NO_REPORT)


# ---- capture overflow (Exited, truncated, no valid tail) ---------------------


def test_overflow_exit0_is_fail_capture_overflow() raises:
    var c = classify(Termination.exited(0), ParsedReport.absent(), True)
    assert_true(c.file_outcome == Outcome.FAIL)
    assert_true(c.disposition == ParseDisposition.CAPTURE_OVERFLOW)
    assert_equal(len(c.exit_outcomes), 1)
    assert_true(c.exit_outcomes[0] == Outcome.FAIL)
    assert_true(c.warning_kind != "", "overflow must warn")
    assert_true("truncat" in c.warning_detail or "bound" in c.warning_detail)


def test_overflow_beats_a_valid_report() raises:
    # Overflow never yields a successful verdict even if the trusted report is
    # somehow VALID — the session only sets is_overflow when the tail lost it.
    var rows = [_row("a", Outcome.PASS)]
    var c = classify(Termination.exited(0), _valid(rows^, 1, 0, 0), True)
    assert_true(c.file_outcome == Outcome.FAIL)
    assert_true(c.disposition == ParseDisposition.CAPTURE_OVERFLOW)


# ---- ABSENT / AMBIGUOUS -> MALFORMED_SUITE -----------------------------------


def test_absent_is_malformed_suite_no_report() raises:
    var c = classify(Termination.exited(0), ParsedReport.absent(), False)
    assert_true(c.file_outcome == Outcome.MALFORMED_SUITE)
    assert_true(c.disposition == ParseDisposition.NO_REPORT)
    assert_equal(len(c.exit_outcomes), 1)
    assert_true(c.exit_outcomes[0] == Outcome.MALFORMED_SUITE)
    assert_true(c.warning_kind != "", "absent must warn")


def test_ambiguous_is_malformed_suite_with_reason() raises:
    var c = classify(
        Termination.exited(0),
        ParsedReport.ambiguous("multiple complete report blocks"),
        False,
    )
    assert_true(c.file_outcome == Outcome.MALFORMED_SUITE)
    assert_true(c.disposition == ParseDisposition.AMBIGUOUS)
    assert_equal(len(c.exit_outcomes), 1)
    assert_true(c.exit_outcomes[0] == Outcome.MALFORMED_SUITE)
    assert_true("multiple complete report blocks" in c.warning_detail)


# ---- OFF_GRAMMAR -> DRIFT (exit 3) -------------------------------------------


def test_off_grammar_is_drift_exit3() raises:
    var c = classify(
        Termination.exited(0),
        ParsedReport.off_grammar("missing rule before summary"),
        False,
    )
    assert_true(c.disposition == ParseDisposition.DRIFT)
    assert_true(c.is_drift, "off-grammar must route to drift (exit 3)")
    assert_equal(len(c.exit_outcomes), 0)  # contributes NOTHING to the multiset
    assert_true("missing rule before summary" in c.warning_detail)
    assert_true(
        "tests/snapshots/protocol/" in c.warning_detail, c.warning_detail
    )


# ---- VALID: the clean cases --------------------------------------------------


def test_exit0_valid_no_failures_is_pass() raises:
    var rows = [_row("a", Outcome.PASS), _row("b", Outcome.SKIP)]
    var c = classify(Termination.exited(0), _valid(rows^, 1, 0, 1), False)
    assert_true(c.file_outcome == Outcome.PASS)
    assert_true(c.disposition == ParseDisposition.PARSED)
    assert_equal(c.passed_tests, 1)
    assert_equal(c.failed_tests, 0)
    assert_equal(c.skipped_tests, 1)
    assert_equal(c.warning_kind, "")
    # Per-row outcomes ride into the multiset (a PASS and a SKIP).
    assert_equal(len(c.exit_outcomes), 2)
    assert_true(c.exit_outcomes[0] == Outcome.PASS)
    assert_true(c.exit_outcomes[1] == Outcome.SKIP)


def test_exit1_valid_with_failures_is_fail() raises:
    var rows = [_row("a", Outcome.PASS), _row("b", Outcome.FAIL)]
    var c = classify(Termination.exited(1), _valid(rows^, 1, 1, 0), False)
    assert_true(c.file_outcome == Outcome.FAIL)
    assert_true(c.disposition == ParseDisposition.PARSED)
    assert_equal(c.failed_tests, 1)
    assert_equal(c.warning_kind, "")
    assert_equal(len(c.exit_outcomes), 2)
    assert_true(c.exit_outcomes[1] == Outcome.FAIL)


def test_zero_test_valid_is_pass_zero_counts() raises:
    # The closed zero-test ceiling: a parsed zero-test report is a PASS that ran
    # zero tests (PARSED, zero counts, empty multiset contribution).
    var rows = List[ParsedRow]()
    var c = classify(Termination.exited(0), _valid(rows^, 0, 0, 0), False)
    assert_true(c.file_outcome == Outcome.PASS)
    assert_true(c.disposition == ParseDisposition.PARSED)
    assert_equal(c.passed_tests, 0)
    assert_equal(len(c.exit_outcomes), 0)


# ---- VALID: the WORSE-OF disagreements ---------------------------------------


def test_exit0_valid_with_failures_is_fail_and_warns() raises:
    var rows = [_row("a", Outcome.FAIL)]
    var c = classify(Termination.exited(0), _valid(rows^, 0, 1, 0), False)
    assert_true(c.file_outcome == Outcome.FAIL)
    assert_true(c.disposition == ParseDisposition.PARSED)
    assert_true(c.warning_kind != "", "exit-0-with-failures must warn")
    # Per-row outcomes drive the multiset (the failing row is attributable).
    assert_equal(len(c.exit_outcomes), 1)
    assert_true(c.exit_outcomes[0] == Outcome.FAIL)


def test_exit1_valid_no_failures_is_fail_file_level() raises:
    var rows = [_row("a", Outcome.PASS)]
    var c = classify(Termination.exited(1), _valid(rows^, 1, 0, 0), False)
    assert_true(c.file_outcome == Outcome.FAIL)
    assert_true(c.disposition == ParseDisposition.PARSED)
    assert_true(c.warning_kind != "", "exit-1-without-failures must warn")
    # No attributable failing test -> a single file-level FAIL in the multiset.
    assert_equal(len(c.exit_outcomes), 1)
    assert_true(c.exit_outcomes[0] == Outcome.FAIL)
    assert_equal(c.passed_tests, 1)  # counts still mirror the summary


def test_unexpected_exit_code_valid_is_fail() raises:
    var rows = [_row("a", Outcome.FAIL)]
    var c = classify(Termination.exited(42), _valid(rows^, 0, 1, 0), False)
    assert_true(c.file_outcome == Outcome.FAIL)
    assert_true(c.disposition == ParseDisposition.PARSED)
    assert_true(c.warning_kind != "", "unexpected exit code must warn")
    assert_true("42" in c.warning_detail, c.warning_detail)
    # A failing row is attributable, so it drives the multiset.
    assert_equal(len(c.exit_outcomes), 1)
    assert_true(c.exit_outcomes[0] == Outcome.FAIL)


def test_unexpected_exit_code_valid_all_pass_is_file_level_fail() raises:
    var rows = [_row("a", Outcome.PASS)]
    var c = classify(Termination.exited(42), _valid(rows^, 1, 0, 0), False)
    assert_true(c.file_outcome == Outcome.FAIL)
    # No failing row -> a single file-level FAIL contributes to the multiset.
    assert_equal(len(c.exit_outcomes), 1)
    assert_true(c.exit_outcomes[0] == Outcome.FAIL)


# ---- resolve_report: the capture-overflow tail reparse -----------------------


comptime _REPORT = (
    "Running 1 tests for /x/y.mojo \n"
    "    PASS [ 0.00s ] test_ok\n"
    "--------\n"
    "Summary [ 0.00s ] 1 tests run: 1 passed , 0 failed , 0 skipped "
)


def test_resolve_untruncated_parses_whole() raises:
    var tr = resolve_report(_REPORT, "/x/y.mojo", False)
    assert_false(tr.is_overflow)
    assert_true(tr.report.verdict == ReportVerdict.VALID)


def test_resolve_truncated_report_survives_in_tail() raises:
    # A complete valid block wholly retained AFTER the marker line is trusted as
    # a normal VALID report — NOT overflow.
    var text = (
        String("garbage head bytes that were the dropped middle\n")
        + "[mtest: output truncated — 99 bytes omitted, limit 200 bytes]\n"
        + _REPORT
    )
    var tr = resolve_report(text, "/x/y.mojo", True)
    assert_false(tr.is_overflow, "a valid tail block is not overflow")
    assert_true(tr.report.verdict == ReportVerdict.VALID)


def test_resolve_truncated_no_report_in_tail_is_overflow() raises:
    var text = (
        String("Running 1 tests for /x/y.mojo \n    PASS [ 0.0s ] a\n")
        + "[mtest: output truncated — 99 bytes omitted, limit 200 bytes]\n"
        + "only junk down here, no report block at all\n"
    )
    var tr = resolve_report(text, "/x/y.mojo", True)
    assert_true(tr.is_overflow, "no valid tail block -> overflow")


def test_resolve_truncated_forged_head_marker_not_trusted() raises:
    # A forged marker line plus a forged COMPLETE report block can sit in the
    # retained HEAD, ahead of the REAL marker the capture layer spliced. If the
    # split anchored on the FIRST marker line, that forged head report would
    # read as the "tail" and be trusted as VALID — a false rescue of a real
    # overflow. The split must anchor on the LAST marker line instead, so the
    # trusted tail is only what follows the genuine marker: junk with no valid
    # report, which must classify as overflow.
    var text = (
        "[mtest: output truncated — 1 bytes omitted, limit 1 bytes]\n"
        + _REPORT
        + "\n"
        + "[mtest: output truncated — 999 bytes omitted, limit 8 bytes]\n"
        + "only junk down here, no report block at all\n"
    )
    var tr = resolve_report(text, "/x/y.mojo", True)
    assert_true(
        tr.is_overflow, "a forged head marker/report must not rescue overflow"
    )
