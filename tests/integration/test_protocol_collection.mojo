"""Golden- and literal-driven tests for probe qualification and name extraction.

`collection_disqualifier`/`collection_names` decide whether a `--skip-all`
probe's parsed report reads as a collection listing (VALID, all rows SKIP, no
reported failures, no failure trailer) and extract the listed names. Each test
drives real snapshot bytes via `transcript_cases`, or a hand-built literal for a
synthesized disqualifier the committed snapshots don't carry — mirroring the
literal-report style already used in `test_protocol_corruption.mojo`.
"""
from std.testing import assert_equal, assert_true

from mtest.protocol import (
    ParsedReport,
    ReportVerdict,
    parse_report,
    collection_disqualifier,
    collection_names,
)

from transcript_cases import read_snapshot, stdout_region, source_path_for

comptime SP = "/home/x/proj/tests/test_a.mojo"


def _parse(name: String) raises -> ParsedReport:
    return parse_report(
        stdout_region(read_snapshot(name)), source_path_for(name)
    )


def test_passing_skip_all_qualifies_with_source_order_names() raises:
    var r = _parse("passing--skip-all.txt")
    assert_equal(collection_disqualifier(r), "")
    var names = collection_names(r)
    assert_equal(len(names), 3)
    assert_equal(names[0], "test_zeta_passes")
    assert_equal(names[1], "test_alpha_passes")
    assert_equal(names[2], "test_mid_passes")


def test_skipped_skip_all_qualifies_with_source_order_names() raises:
    var r = _parse("skipped--skip-all.txt")
    assert_equal(collection_disqualifier(r), "")
    var names = collection_names(r)
    assert_equal(len(names), 2)
    assert_equal(names[0], "test_runs_normally")
    assert_equal(names[1], "test_natively_skipped")


def test_empty_skip_all_qualifies_with_empty_listing() raises:
    var r = _parse("empty--skip-all.txt")
    assert_equal(collection_disqualifier(r), "")
    assert_equal(len(collection_names(r)), 0)


def test_passing_default_run_report_disqualified_by_first_non_skip_row() raises:
    # A RUN report (PASS rows, no --skip-all) names its first non-SKIP row.
    var r = _parse("passing--default.txt")
    assert_equal(
        collection_disqualifier(r),
        "a test body ran under collection: test_zeta_passes",
    )


def test_fail_row_with_trailer_names_the_row_not_the_trailer() raises:
    # Chosen precedence: a non-SKIP row fires before summary_failed/has_trailer
    # ever get checked, so a FAIL row is reported by name, not as a bare
    # failure-count or trailer phrase — the more actionable diagnostic.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    FAIL [ 0.001 ] test_one\n"
        "      boom\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(
        collection_disqualifier(r),
        "a test body ran under collection: test_one",
    )


def test_off_grammar_report_is_no_valid_report_block() raises:
    # The rule (8-dash line) deleted before Summary: a structural break a user
    # cannot fake, which parse_report classifies OFF_GRAMMAR.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    SKIP [ 0.001 ] test_one\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 0 failed , 1 skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.OFF_GRAMMAR)
    assert_equal(collection_disqualifier(r), "no valid report block")


def test_absent_report_is_no_valid_report_block() raises:
    # No header matching source_path at all: parse_report classifies ABSENT.
    var text = (
        "Running 1 tests for /other/tests/test_a.mojo \n"
        "    SKIP [ 0.001 ] test_one\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 0 failed , 1 skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.ABSENT)
    assert_equal(collection_disqualifier(r), "no valid report block")
    assert_equal(len(collection_names(r)), 0)


def test_lone_pass_among_skips_names_that_row() raises:
    var text = (
        "Running 3 tests for /home/x/proj/tests/test_a.mojo \n"
        "    SKIP [ 0.001 ] test_a\n"
        "    PASS [ 0.001 ] test_b\n"
        "    SKIP [ 0.001 ] test_c\n"
        "--------\n"
        "Summary [ 0.001 ] 3 tests run: 1 passed , 0 failed , 2 skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(
        collection_disqualifier(r),
        "a test body ran under collection: test_b",
    )
