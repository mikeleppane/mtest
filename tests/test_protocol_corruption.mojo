"""Synthesized-input tests for `parse_report` (Layer 2): raw form and forgeries.

The goldens are normalized (timing token `T`, path token `<REPO>/...`); these
tests instead build report strings the way a LIVE child prints them — numeric
timings and absolute canonical paths — to prove the parser reads real runtime
output, and pin the exact-path identity rule (a same-suffix impostor path does
not match). The corruption pins then plant one defect at a time and assert which
of OFF_GRAMMAR / AMBIGUOUS it lands in: a structural break a user cannot fake is
OFF_GRAMMAR; a pattern a test's own stdout CAN produce is AMBIGUOUS.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.model import Outcome
from mtest.protocol import ReportVerdict, parse_report

comptime SP = "/home/x/proj/tests/test_a.mojo"


def _raw_two_row_fail() -> String:
    """A live-shaped report: 1 PASS, 1 FAIL with detail, trailer present."""
    return (
        "Running 2 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.012 ] test_one\n"
        "    FAIL [ 0.030 ] test_two\n"
        "      At /home/x/proj/tests/test_a.mojo:5:3: AssertionError: nope\n"
        "--------\n"
        "Summary [ 0.042 ] 2 tests run: 1 passed , 1 failed , 0 skipped \n"
        "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "
    )


def test_raw_numeric_timings_and_absolute_path_valid() raises:
    var r = parse_report(_raw_two_row_fail(), SP)
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(r.declared_count, 2)
    assert_equal(len(r.rows), 2)
    assert_true(r.rows[0].outcome == Outcome.PASS)
    assert_equal(r.rows[0].name, "test_one")
    assert_equal(r.rows[0].timing, "0.012")
    assert_true(r.rows[1].outcome == Outcome.FAIL)
    assert_equal(r.rows[1].timing, "0.030")
    assert_true("At /home/x/proj/tests/test_a.mojo:5:3:" in r.rows[1].detail)
    assert_equal(r.summary_passed, 1)
    assert_equal(r.summary_failed, 1)
    assert_true(r.has_trailer)


def test_symlink_equal_path_matches() raises:
    # Exec hands both sides the same realpath; a header path that byte-equals
    # source_path matches and parses VALID.
    var text = (
        "Running 1 tests for /var/run/link/tests/t.mojo \n"
        "    PASS [ 0.001 ] test_ok\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
    )
    var r = parse_report(text, "/var/run/link/tests/t.mojo")
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(len(r.rows), 1)
    assert_equal(r.rows[0].name, "test_ok")


def test_impostor_same_suffix_path_absent() raises:
    # Same basename/suffix but a different root must NOT match — exact bytes only.
    var text = (
        "Running 1 tests for /other/tests/t.mojo \n"
        "    PASS [ 0.001 ] test_ok\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
    )
    var r = parse_report(text, "/a/b/tests/t.mojo")
    assert_true(r.verdict == ReportVerdict.ABSENT)
    assert_equal(len(r.rows), 0)


def test_summary_deleted_is_off_grammar() raises:
    # A genuine matching header but no terminal Summary framing.
    var text = (
        "Running 2 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.012 ] test_one\n"
        "    FAIL [ 0.030 ] test_two\n"
        "      At /home/x/proj/tests/test_a.mojo:5:3: AssertionError: nope\n"
        "--------\n"
        "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.OFF_GRAMMAR)


def test_rule_replaced_is_off_grammar() raises:
    # The line before the Summary must be the 8-dash rule; noise there is drift.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "==not-the-rule==\n"
        "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.OFF_GRAMMAR)


def test_second_appended_block_is_ambiguous() raises:
    # A whole second report appended after a clean one — a forgery a user can
    # print; never "choose the last".
    var block = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
    )
    var r = parse_report(block + "\n" + block, SP)
    assert_true(r.verdict == ReportVerdict.AMBIGUOUS)


def test_duplicate_row_name_is_ambiguous() raises:
    var text = (
        "Running 2 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] dup\n"
        "    PASS [ 0.001 ] dup\n"
        "--------\n"
        "Summary [ 0.001 ] 2 tests run: 2 passed , 0 failed , 0 skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.AMBIGUOUS)


def test_fewer_rows_than_declared_off_grammar() raises:
    # The header declares more tests than rows appear — a truncation a user
    # cannot fake through their own stdout.
    var text = (
        "Running 2 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "--------\n"
        "Summary [ 0.001 ] 2 tests run: 2 passed , 0 failed , 0 skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.OFF_GRAMMAR)


def test_more_rows_than_declared_ambiguous() raises:
    # An extra row beyond the declared count — a user CAN inject a row-lookalike.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "    PASS [ 0.001 ] test_two\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.AMBIGUOUS)


def test_trailer_with_zero_failures_off_grammar() raises:
    # The `Test suite' ... 'failed!` trailer with a zero failure count is an
    # internal inconsistency the toolchain never emits.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped \n"
        "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.OFF_GRAMMAR)


def test_summary_lookalike_in_detail_stays_valid() raises:
    # A rule-lookalike and a Summary-lookalike planted INSIDE a FAIL's detail
    # are still detail — the real terminal framing was already found at the END.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    FAIL [ 0.001 ] test_one\n"
        "      At /home/x/proj/tests/test_a.mojo:1:1: AssertionError: boom\n"
        "Summary [ 0.001 ] 99 tests run: 99 passed , 0 failed , 0 skipped \n"
        "      trailing detail after the lookalike\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(len(r.rows), 1)
    assert_true(r.rows[0].outcome == Outcome.FAIL)
    assert_equal(r.declared_count, 1)
    assert_equal(r.summary_failed, 1)
    # The planted Summary-lookalike rode through as verbatim detail, uncounted.
    assert_true("99 tests run" in r.rows[0].detail)
    assert_true("trailing detail after the lookalike" in r.rows[0].detail)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
