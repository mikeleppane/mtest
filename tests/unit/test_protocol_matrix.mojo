"""The exhaustive corruption matrix for `parse_report` (Layer 2).

One base VALID report (numeric timings, an absolute path — live runtime shape,
not a normalized snapshot) is corrupted by inserting ONE noise line at EVERY parser
state and the classification is pinned per cell. The insertion points are the
states a forger could aim at: [H] after the header before the first row, [P]
right after a PASS/SKIP row, [Fd] inside a FAIL row's detail, [RS] between the
rule and the Summary, and [Post] after the terminal framing. The noise kinds are
the shapes a user's own stdout can print: plain junk, a row-lookalike, the rule,
a Summary-lookalike, and the header itself.

The doctrine the matrix proves: a structural break a user's stdout CANNOT forge
lands OFF_GRAMMAR (toolchain drift); a pattern user bytes CAN produce lands
AMBIGUOUS; and noise a FAIL absorbs as verbatim detail leaves a genuine single
report VALID. No corrupted input reaches VALID unless it truly is one report.
"""
from std.testing import assert_true, TestSuite

from mtest.protocol import ReportVerdict, parse_report

comptime V = ReportVerdict
comptime SP = "/home/x/proj/tests/test_a.mojo"

# The base report's lines (a live-shaped mixed run: PASS, FAIL+detail, PASS,
# declared 3, trailer present because one test failed).
comptime HDR = "Running 3 tests for /home/x/proj/tests/test_a.mojo "
comptime ROW1 = "    PASS [ 0.001 ] test_one"
comptime ROW2 = "    FAIL [ 0.002 ] test_two"
comptime DETAIL2 = "      At /home/x/proj/tests/test_a.mojo:5:3: boom"
comptime ROW3 = "    PASS [ 0.003 ] test_three"
comptime RULE = "--------"
comptime SUMMARY = (
    "Summary [ 0.004 ] 3 tests run: 2 passed , 1 failed , 0 skipped "
)
comptime TRAILER = "Test suite' /home/x/proj/tests/test_a.mojo 'failed! "

# The five noise kinds, each a line a test's own stdout could print byte-for-byte.
comptime N_JUNK = "GARBAGE"
comptime N_ROW = "    PASS [ 0.001 ] extra_one"
comptime N_RULE = "--------"
comptime N_SUMMARY = (
    "Summary [ T ] 9 tests run: 9 passed , 0 failed , 0 skipped "
)
comptime N_HEADER = "Running 3 tests for /home/x/proj/tests/test_a.mojo "


def _join(lines: List[String]) -> String:
    """Join `lines` with `\\n` into one report string. Allocates."""
    var out = String("")
    for i in range(len(lines)):
        if i > 0:
            out += "\n"
        out += lines[i]
    return out


def _at_h(noise: String) -> String:
    """Insert `noise` after the header, before the first row ([H])."""
    return _join(
        [HDR, noise, ROW1, ROW2, DETAIL2, ROW3, RULE, SUMMARY, TRAILER]
    )


def _at_p(noise: String) -> String:
    """Insert `noise` immediately after the first PASS row ([P])."""
    return _join(
        [HDR, ROW1, noise, ROW2, DETAIL2, ROW3, RULE, SUMMARY, TRAILER]
    )


def _at_fd(noise: String) -> String:
    """Insert `noise` inside the FAIL row's detail ([Fd])."""
    return _join(
        [HDR, ROW1, ROW2, DETAIL2, noise, ROW3, RULE, SUMMARY, TRAILER]
    )


def _at_rs(noise: String) -> String:
    """Insert `noise` between the rule and the Summary ([RS])."""
    return _join(
        [HDR, ROW1, ROW2, DETAIL2, ROW3, RULE, noise, SUMMARY, TRAILER]
    )


def _at_post(noise: String) -> String:
    """Insert `noise` after the terminal framing (trailer) ([Post])."""
    return _join(
        [HDR, ROW1, ROW2, DETAIL2, ROW3, RULE, SUMMARY, TRAILER, noise]
    )


# ---- [H] after the header, before the first row (no preceding FAIL) ----


def test_h_junk_off_grammar() raises:
    assert_true(parse_report(_at_h(N_JUNK), SP).verdict == V.OFF_GRAMMAR)


def test_h_row_lookalike_ambiguous() raises:
    assert_true(parse_report(_at_h(N_ROW), SP).verdict == V.AMBIGUOUS)


def test_h_rule_lookalike_off_grammar() raises:
    assert_true(parse_report(_at_h(N_RULE), SP).verdict == V.OFF_GRAMMAR)


def test_h_summary_lookalike_off_grammar() raises:
    assert_true(parse_report(_at_h(N_SUMMARY), SP).verdict == V.OFF_GRAMMAR)


def test_h_header_lookalike_valid() raises:
    # An identical header inserted right after the real header, before the first
    # row. The anchor is the LAST matching header before the rule, so it takes the
    # inner (second) header; the real rows follow and reconcile, and the earlier
    # header is ignored — correct results, harmless. (Exact-path-impossible in real
    # output.)
    assert_true(parse_report(_at_h(N_HEADER), SP).verdict == V.VALID)


# ---- [P] immediately after a PASS/SKIP row ----


def test_p_junk_off_grammar() raises:
    assert_true(parse_report(_at_p(N_JUNK), SP).verdict == V.OFF_GRAMMAR)


def test_p_row_lookalike_ambiguous() raises:
    assert_true(parse_report(_at_p(N_ROW), SP).verdict == V.AMBIGUOUS)


def test_p_rule_lookalike_off_grammar() raises:
    assert_true(parse_report(_at_p(N_RULE), SP).verdict == V.OFF_GRAMMAR)


def test_p_summary_lookalike_off_grammar() raises:
    assert_true(parse_report(_at_p(N_SUMMARY), SP).verdict == V.OFF_GRAMMAR)


def test_p_header_lookalike_off_grammar() raises:
    assert_true(parse_report(_at_p(N_HEADER), SP).verdict == V.OFF_GRAMMAR)


# ---- [Fd] inside a FAIL row's detail ----


def test_fd_junk_valid() raises:
    assert_true(parse_report(_at_fd(N_JUNK), SP).verdict == V.VALID)


def test_fd_row_lookalike_ambiguous() raises:
    # A row-shaped line is parsed as a genuine extra row, not detail: rows now
    # exceed the declared count, which a user CAN forge -> AMBIGUOUS.
    assert_true(parse_report(_at_fd(N_ROW), SP).verdict == V.AMBIGUOUS)


def test_fd_rule_lookalike_valid() raises:
    assert_true(parse_report(_at_fd(N_RULE), SP).verdict == V.VALID)


def test_fd_summary_lookalike_valid() raises:
    # The end-scan already found the genuine last Summary; the planted one rides
    # through as verbatim detail.
    assert_true(parse_report(_at_fd(N_SUMMARY), SP).verdict == V.VALID)


def test_fd_header_lookalike_valid() raises:
    # An identical header inserted INSIDE a FAIL's detail (a test asserting about
    # the file's own canonical path could print it byte-for-byte). Anchoring
    # blindly on the LAST matching header before the rule would hijack the anchor
    # onto this in-detail header and underflow the declared count, misreading
    # conforming CONTENT as toolchain drift (OFF_GRAMMAR -> exit 3). The anchor is
    # chosen by reconciliation instead: the in-detail header's block does not
    # reconcile, so the real header — whose block does — wins, and the planted
    # line rides through as verbatim FAIL detail. VALID.
    assert_true(parse_report(_at_fd(N_HEADER), SP).verdict == V.VALID)


# ---- [RS] between the rule and the Summary ----


def test_rs_junk_off_grammar() raises:
    assert_true(parse_report(_at_rs(N_JUNK), SP).verdict == V.OFF_GRAMMAR)


def test_rs_row_lookalike_off_grammar() raises:
    assert_true(parse_report(_at_rs(N_ROW), SP).verdict == V.OFF_GRAMMAR)


def test_rs_rule_lookalike_off_grammar() raises:
    assert_true(parse_report(_at_rs(N_RULE), SP).verdict == V.OFF_GRAMMAR)


def test_rs_summary_lookalike_off_grammar() raises:
    # The end-scan takes the planted trailing Summary; its preceding line is not
    # the rule.
    assert_true(parse_report(_at_rs(N_SUMMARY), SP).verdict == V.OFF_GRAMMAR)


def test_rs_header_lookalike_off_grammar() raises:
    assert_true(parse_report(_at_rs(N_HEADER), SP).verdict == V.OFF_GRAMMAR)


# ---- [Post] after the terminal framing ----


def test_post_junk_valid() raises:
    assert_true(parse_report(_at_post(N_JUNK), SP).verdict == V.VALID)


def test_post_row_lookalike_valid() raises:
    assert_true(parse_report(_at_post(N_ROW), SP).verdict == V.VALID)


def test_post_rule_lookalike_valid() raises:
    assert_true(parse_report(_at_post(N_RULE), SP).verdict == V.VALID)


def test_post_summary_lookalike_off_grammar() raises:
    # The end-scan takes the planted Summary appended after the trailer; the
    # trailer before it is not the rule.
    assert_true(parse_report(_at_post(N_SUMMARY), SP).verdict == V.OFF_GRAMMAR)


def test_post_header_lookalike_lone_valid() raises:
    # A lone trailing header with no framing after it is tolerated as junk.
    assert_true(parse_report(_at_post(N_HEADER), SP).verdict == V.VALID)


def test_post_header_lookalike_second_block_ambiguous() raises:
    # A trailing header that BEGINS a full second block yields two complete
    # matching-path blocks -> AMBIGUOUS.
    var second = _join([N_HEADER, ROW1, RULE, SUMMARY])
    var text = _at_post("") + "\n" + second
    assert_true(parse_report(text, SP).verdict == V.AMBIGUOUS)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
