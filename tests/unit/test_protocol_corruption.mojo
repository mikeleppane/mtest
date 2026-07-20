"""Synthesized-input tests for `parse_report` (Layer 2): raw form and forgeries.

The snapshots are normalized (timing token `T`, path token `<REPO>/...`); these
tests instead build report strings the way a LIVE child prints them — numeric
timings and absolute canonical paths — to prove the parser reads real runtime
output, and pin the exact-path identity rule (a same-suffix impostor path does
not match). The corruption pins then plant one defect at a time and assert which
of OFF_GRAMMAR / AMBIGUOUS it lands in: a structural break a user cannot fake is
OFF_GRAMMAR; a pattern a test's own stdout CAN produce is AMBIGUOUS.
"""
from std.testing import assert_equal, assert_true, assert_false

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


def test_rule_deleted_is_off_grammar() raises:
    # With the 8-dash rule removed the Summary follows a row directly; the line
    # before the Summary is not the rule.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
    )
    assert_true(parse_report(text, SP).verdict == ReportVerdict.OFF_GRAMMAR)


def test_summary_tally_does_not_sum_off_grammar() raises:
    # passed + failed + skipped must equal the declared total; here 2+1+1 != 3.
    var text = (
        "Running 3 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "    PASS [ 0.001 ] test_two\n"
        "    PASS [ 0.001 ] test_three\n"
        "--------\n"
        "Summary [ 0.001 ] 3 tests run: 2 passed , 1 failed , 1 skipped "
    )
    assert_true(parse_report(text, SP).verdict == ReportVerdict.OFF_GRAMMAR)


def test_row_tallies_disagree_with_summary_off_grammar() raises:
    # The Summary is self-consistent (1+1+1 == 3) but the three PASS rows do not
    # match its passed/failed/skipped split — broken arithmetic.
    var text = (
        "Running 3 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "    PASS [ 0.001 ] test_two\n"
        "    PASS [ 0.001 ] test_three\n"
        "--------\n"
        "Summary [ 0.001 ] 3 tests run: 1 passed , 1 failed , 1 skipped "
    )
    assert_true(parse_report(text, SP).verdict == ReportVerdict.OFF_GRAMMAR)


def test_malformed_row_names_off_grammar() raises:
    # An empty, a whitespace-containing, and a `::`-bearing row name are each a
    # malformed name the toolchain never emits.
    for bad in [
        "    PASS [ 0.001 ] ",
        "    PASS [ 0.001 ] a b",
        "    PASS [ 0.001 ] a::b",
    ]:
        var text = (
            "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
            + String(bad)
            + "\n--------\n"
            "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
        )
        assert_true(parse_report(text, SP).verdict == ReportVerdict.OFF_GRAMMAR)


def test_trailer_absent_with_failures_off_grammar() raises:
    # A failing run must carry the `Test suite' ... 'failed!` trailer; its
    # absence with failed > 0 is an inconsistency.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    FAIL [ 0.001 ] test_one\n"
        "      boom\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 1 failed , 0 skipped "
    )
    assert_true(parse_report(text, SP).verdict == ReportVerdict.OFF_GRAMMAR)


def test_trailer_names_different_path_off_grammar() raises:
    # The trailer must name source_path byte-for-byte; a foreign path is drift.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    FAIL [ 0.001 ] test_one\n"
        "      boom\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        "Test suite' /other/tests/test_a.mojo 'failed! "
    )
    assert_true(parse_report(text, SP).verdict == ReportVerdict.OFF_GRAMMAR)


def test_truncation_marker_before_report_stays_valid() raises:
    # A truncation marker in the tail BEFORE a complete report is pre-report
    # junk; refusing overflow is the session's job, not the parser's.
    var text = (
        "[mtest: output truncated — 999 bytes omitted, limit 12 bytes]\n"
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
    )
    assert_true(parse_report(text, SP).verdict == ReportVerdict.VALID)


def test_truncation_severed_framing_off_grammar() raises:
    # Truncation cut the report off after the header: a matching header with no
    # rule and no Summary.
    var text = (
        "Running 2 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one"
    )
    assert_true(parse_report(text, SP).verdict == ReportVerdict.OFF_GRAMMAR)


def test_truncation_severed_header_is_absent() raises:
    # Truncation cut the header itself; the partial `Running` never matches.
    var text = "Running 2 tes"
    assert_true(parse_report(text, SP).verdict == ReportVerdict.ABSENT)


def test_replacement_char_in_detail_stays_valid() raises:
    # A U+FFFD from a lossy decode inside FAIL detail is absorbed verbatim.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    FAIL [ 0.001 ] test_one\n"
        "      boom � here\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_true("�" in r.rows[0].detail)


def test_replacement_char_in_path_breaks_identity_absent() raises:
    # A U+FFFD in the header path means it no longer byte-equals source_path, so
    # the exact-identity rule finds no matching header -> ABSENT.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_�.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
    )
    assert_true(parse_report(text, SP).verdict == ReportVerdict.ABSENT)


def test_stderr_content_is_invisible_to_the_parser() raises:
    # `parse_report` takes only stdout. A report-lookalike that lived on stderr
    # is never concatenated in, so the genuine stdout report parses VALID alone.
    var stdout_text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
    )
    # A forged second report that only ever existed on stderr — deliberately NOT
    # passed to parse_report, documenting that the parser scans stdout only.
    var stderr_text = (
        "Running 9 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] forged\n"
        "--------\n"
        "Summary [ 0.001 ] 9 tests run: 9 passed , 0 failed , 0 skipped "
    )
    _ = stderr_text
    assert_true(parse_report(stdout_text, SP).verdict == ReportVerdict.VALID)


def test_fail_detail_preserves_leading_empty_line() raises:
    # A FAIL whose detail BEGINS with an empty line must keep that line verbatim:
    # `["", "      boom"]` is two lines, so the join is "\n      boom", not the
    # lone "      boom" that dropping the empty leader would yield.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    FAIL [ 0.001 ] test_one\n"
        "\n"
        "      boom\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(len(r.rows), 1)
    assert_true(r.rows[0].outcome == Outcome.FAIL)
    assert_equal(r.rows[0].detail, "\n      boom")


def test_fail_detail_interior_empty_line_round_trips() raises:
    # Interior empty lines already survive; pin `["a", "", "b"]` -> "a\n\nb".
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    FAIL [ 0.001 ] test_one\n"
        "a\n"
        "\n"
        "b\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(r.rows[0].detail, "a\n\nb")


def test_fail_detail_single_empty_line_is_empty_string() raises:
    # A FAIL whose ONLY detail line is empty is the same bytes as no detail:
    # `[""]` -> "". Still a FAIL row, counted, with empty detail.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    FAIL [ 0.001 ] test_one\n"
        "\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(len(r.rows), 1)
    assert_true(r.rows[0].outcome == Outcome.FAIL)
    assert_equal(r.rows[0].detail, "")


def test_pre_report_header_lookalike_before_real_report_valid() raises:
    # The realistic case: a test's own stdout is streamed BEFORE the toolchain's
    # buffered report, so a header-lookalike the test PRINTS (here with a DIFFERENT
    # count) precedes the real block. The anchor must be the LAST matching header
    # before the rule — the earlier printed header is user output to ignore — so
    # the genuine report is found and reconciles. Anchor-on-first would misread the
    # printed header as the anchor and land OFF_GRAMMAR, wrongly blaming the
    # toolchain.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "Running 3 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_one\n"
        "    PASS [ 0.001 ] test_two\n"
        "    PASS [ 0.001 ] test_three\n"
        "--------\n"
        "Summary [ T ] 3 tests run: 3 passed , 0 failed , 0 skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(len(r.rows), 3)


def test_forged_extra_token_in_passed_field_off_grammar() raises:
    # A hand-forged Summary whose passed field carries an EXTRA token between the
    # count and the label (`1 forged passed`). The field still ends in ` passed`
    # and its first space-token still reads as 1, so a suffix-only check would
    # accept it and the whole report would reconcile to a false GREEN. The summary
    # grammar is exactly `<digits> passed`; the extra token violates it, so the
    # line is no Summary at all, the report has a genuine header without terminal
    # framing, and it is OFF_GRAMMAR — never VALID.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_ok\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 1 forged passed , 0 failed , 0 skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.OFF_GRAMMAR)
    assert_true(r.verdict != ReportVerdict.VALID)


def test_forged_extra_token_in_each_field_off_grammar() raises:
    # An extra token planted in ALL THREE summary fields at once. Each count still
    # reads as a valid non-negative integer that reconciles with the rows, so a
    # suffix-only check would still land VALID; the exact `<digits> <label>` shape
    # is what rejects it. OFF_GRAMMAR.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_ok\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 1 forged passed , 0 bogus failed , 0"
        " junk skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.OFF_GRAMMAR)
    assert_true(r.verdict != ReportVerdict.VALID)


def test_forged_leading_zero_count_off_grammar() raises:
    # A leading-zero count (`01 passed`) is off the pinned grammar: the toolchain
    # never zero-pads. A first-token parse would normalize `01` to 1 and accept
    # it; requiring the field to equal exactly `String(count) + " passed"` rejects
    # the padded form. OFF_GRAMMAR, never a false PASS.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    PASS [ 0.001 ] test_ok\n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 01 passed , 0 failed , 0 skipped "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.OFF_GRAMMAR)
    assert_true(r.verdict != ReportVerdict.VALID)


def test_fail_detail_header_lookalike_reconciles_valid() raises:
    # A conforming test (plausibly the runner's OWN suite) FAILs while asserting
    # about paths, and its failure detail contains a flush-left line that byte-
    # equals this file's own header, `Running 1 tests for <P> `. That line is a
    # matching header sitting AFTER the real one, so anchoring blindly on the last
    # header before the rule hijacks the anchor onto the detail line, the block
    # underflows its declared count, and the report is misread as toolchain drift
    # (OFF_GRAMMAR -> exit 3) purely from test CONTENT. Choosing the anchor by
    # reconciliation finds the real header — whose block DOES reconcile — and the
    # detail line rides through as verbatim FAIL detail. VALID, not OFF_GRAMMAR.
    var text = (
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "    FAIL [ 0.001 ] test_paths\n"
        "Running 1 tests for /home/x/proj/tests/test_a.mojo \n"
        "--------\n"
        "Summary [ 0.001 ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "
    )
    var r = parse_report(text, SP)
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(len(r.rows), 1)
    assert_true(r.rows[0].outcome == Outcome.FAIL)
    assert_true("Running 1 tests for" in r.rows[0].detail)
