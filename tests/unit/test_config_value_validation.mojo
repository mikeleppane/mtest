"""Range boundaries for the source-neutral decimal value parsers.

`parse_nonnegative_decimal` screens for ASCII digits and then converts. The
conversion is the whole risk: `atol` does NOT raise across the entire
out-of-range domain — at exactly `2^63` and `2^63 + 1` it wraps to `Int.MIN`
instead. Because the digit screen has already excluded a sign, a wrapped value
is indistinguishable from a legitimate parse unless the range is re-checked
after conversion.

That hole is not academic: every caller treats the result as non-negative, so a
wrapped `Int.MIN` silently disables `--timeout` (an unbounded run), defeats
`--maxfail` (early stop never fires), and corrupts `--retries`/`--durations`.
The boundary is therefore pinned exactly — the largest accepted value, the two
wrapping values, and the neighbours on both sides — rather than sampled.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import (
    ReportStyle,
    parse_nonnegative_decimal,
    parse_report_style_value,
    parse_report_value,
    parse_worker_count,
)


# --- parse_nonnegative_decimal: the accepted domain ---


def test_zero_is_accepted() raises:
    var parsed = parse_nonnegative_decimal("0")
    assert_true(Bool(parsed))
    assert_equal(parsed.value(), 0)


def test_i64_max_is_accepted() raises:
    var parsed = parse_nonnegative_decimal("9223372036854775807")
    assert_true(Bool(parsed))
    assert_equal(parsed.value(), 9223372036854775807)


def test_leading_zeros_are_accepted() raises:
    var parsed = parse_nonnegative_decimal("007")
    assert_true(Bool(parsed))
    assert_equal(parsed.value(), 7)


# --- parse_nonnegative_decimal: the wrapping boundary ---


def test_two_pow_63_is_refused() raises:
    """`2^63` — the first value `atol` wraps rather than rejecting."""
    assert_false(Bool(parse_nonnegative_decimal("9223372036854775808")))


def test_two_pow_63_plus_one_is_refused() raises:
    """`2^63 + 1` wraps to `Int.MIN + 1`, the second and last wrapping value."""
    assert_false(Bool(parse_nonnegative_decimal("9223372036854775809")))


def test_zero_padded_two_pow_63_is_refused() raises:
    """Padding must not smuggle a wrapping value past the range check."""
    assert_false(
        Bool(parse_nonnegative_decimal("00000000000009223372036854775808"))
    )


def test_two_pow_63_plus_two_is_refused() raises:
    """The neighbour above the wrapping window: already refused today."""
    assert_false(Bool(parse_nonnegative_decimal("9223372036854775810")))


def test_u64_max_is_refused() raises:
    assert_false(Bool(parse_nonnegative_decimal("18446744073709551615")))


# --- parse_nonnegative_decimal: non-decimal spellings ---


def test_empty_is_refused() raises:
    assert_false(Bool(parse_nonnegative_decimal("")))


def test_negative_sign_is_refused() raises:
    assert_false(Bool(parse_nonnegative_decimal("-1")))


def test_non_digit_is_refused() raises:
    assert_false(Bool(parse_nonnegative_decimal("soon")))


# --- parse_worker_count rides the same conversion ---


def test_worker_count_refuses_two_pow_63() raises:
    """`-n` is saved today only by its own `< 1` guard; pin it regardless."""
    assert_false(Bool(parse_worker_count("9223372036854775808")))


def test_worker_count_accepts_i64_max() raises:
    var parsed = parse_worker_count("9223372036854775807")
    assert_true(Bool(parsed))
    assert_equal(parsed.value(), 9223372036854775807)


# --- parse_report_value: the accepted FORMAT:PATH domain ---


def test_report_value_accepts_markdown() raises:
    var parsed = parse_report_value("md:build/report.md")
    assert_true(Bool(parsed))
    assert_equal(parsed.value().format, "md")
    assert_equal(parsed.value().path, "build/report.md")


def test_report_value_accepts_html() raises:
    var parsed = parse_report_value("html:report.html")
    assert_true(Bool(parsed))
    assert_equal(parsed.value().format, "html")
    assert_equal(parsed.value().path, "report.html")


def test_report_value_keeps_every_later_colon_in_the_path() raises:
    """The split is at the FIRST colon, so a colon-bearing path survives."""
    var parsed = parse_report_value("md:build/a:b.md")
    assert_true(Bool(parsed))
    assert_equal(parsed.value().path, "build/a:b.md")


def test_report_value_accepts_an_absolute_path() raises:
    var parsed = parse_report_value("html:/tmp/out.html")
    assert_true(Bool(parsed))
    assert_equal(parsed.value().path, "/tmp/out.html")


# --- parse_report_value: the refused domain ---


def test_report_value_refuses_an_unknown_format() raises:
    assert_false(Bool(parse_report_value("xml:r.xml")))


def test_report_value_refuses_a_missing_separator() raises:
    assert_false(Bool(parse_report_value("report.md")))


def test_report_value_refuses_an_empty_path() raises:
    assert_false(Bool(parse_report_value("md:")))


def test_report_value_refuses_an_empty_format() raises:
    assert_false(Bool(parse_report_value(":report.md")))


def test_report_value_refuses_an_empty_value() raises:
    assert_false(Bool(parse_report_value("")))


def test_report_value_refuses_a_bare_separator() raises:
    assert_false(Bool(parse_report_value(":")))


def test_report_value_format_match_is_case_sensitive() raises:
    """The closed set is lowercase; `MD` is a value error, not an alias."""
    assert_false(Bool(parse_report_value("MD:report.md")))


# --- parse_report_style_value: a closed two-member set ---


def test_report_style_accepts_concise() raises:
    var parsed = parse_report_style_value("concise")
    assert_true(Bool(parsed))
    assert_true(parsed.value() == ReportStyle.CONCISE)


def test_report_style_accepts_full() raises:
    var parsed = parse_report_style_value("full")
    assert_true(Bool(parsed))
    assert_true(parsed.value() == ReportStyle.FULL)


def test_report_style_refuses_anything_else() raises:
    assert_false(Bool(parse_report_style_value("")))
    assert_false(Bool(parse_report_style_value("Full")))
    assert_false(Bool(parse_report_style_value("verbose")))


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
