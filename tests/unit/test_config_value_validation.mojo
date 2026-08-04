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

The module also owns the closed choice lists. Those lists are published so a
completion renderer can offer exactly what the parser accepts, which is only
true while every list and its `parse_*_value` agree in both directions: every
published spelling parses, and nothing outside a list does. Both directions are
asserted here, because a list that drifts one entry wide teaches a user a value
the parser refuses.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import (
    AnnotationsMode,
    ColorWhen,
    ReportStyle,
    ShowOutput,
    annotations_choices,
    collect_format_choices,
    color_choices,
    parse_annotations_value,
    parse_collect_format_value,
    parse_color_value,
    parse_nonnegative_decimal,
    parse_report_style_value,
    parse_report_value,
    parse_show_output_value,
    parse_worker_count,
    report_format_prefixes,
    report_style_choices,
    show_output_choices,
    workers_choices,
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


def _joined(values: List[String]) -> String:
    """Render a choice list as one `|`-separated line for exact comparison."""
    var rendered = String("")
    for i in range(len(values)):
        if i > 0:
            rendered += "|"
        rendered += values[i]
    return rendered^


# --- the published choice lists are exactly the accepted sets ---


def test_show_output_choices_are_the_published_three() raises:
    assert_equal(_joined(show_output_choices()), "failures|all|none")


def test_every_show_output_choice_is_accepted() raises:
    for choice in show_output_choices():
        assert_true(
            Bool(parse_show_output_value(choice)),
            "unaccepted choice: " + choice,
        )


def test_show_output_list_order_is_the_discriminant_order() raises:
    """Position `i` maps to `ShowOutput(i)`, named constant by named constant.

    The parser derives the typed value from the position, so a reordered list
    would silently remap every spelling. The spellings are therefore written
    out literally here rather than read back out of the list under test.
    """
    assert_equal(_joined(show_output_choices()), "failures|all|none")
    assert_true(
        parse_show_output_value("failures").value() == ShowOutput.FAILURES
    )
    assert_true(parse_show_output_value("all").value() == ShowOutput.ALL)
    assert_true(parse_show_output_value("none").value() == ShowOutput.NONE)


def test_show_output_refuses_a_spelling_outside_the_list() raises:
    assert_false(Bool(parse_show_output_value("failure")))
    assert_false(Bool(parse_show_output_value("ALL")))
    assert_false(Bool(parse_show_output_value("")))


def test_color_choices_are_the_published_three() raises:
    assert_equal(_joined(color_choices()), "auto|always|never")


def test_every_color_choice_is_accepted() raises:
    for choice in color_choices():
        assert_true(
            Bool(parse_color_value(choice)), "unaccepted choice: " + choice
        )


def test_color_list_order_is_the_discriminant_order() raises:
    assert_equal(_joined(color_choices()), "auto|always|never")
    assert_true(parse_color_value("auto").value() == ColorWhen.AUTO)
    assert_true(parse_color_value("always").value() == ColorWhen.ALWAYS)
    assert_true(parse_color_value("never").value() == ColorWhen.NEVER)


def test_color_refuses_a_spelling_outside_the_list() raises:
    assert_false(Bool(parse_color_value("yes")))
    assert_false(Bool(parse_color_value("Auto")))
    assert_false(Bool(parse_color_value("")))


def test_annotations_choices_are_the_published_three() raises:
    assert_equal(_joined(annotations_choices()), "off|on|auto")


def test_every_annotations_choice_is_accepted() raises:
    for choice in annotations_choices():
        assert_true(
            Bool(parse_annotations_value(choice)),
            "unaccepted choice: " + choice,
        )


def test_annotations_list_order_is_the_discriminant_order() raises:
    assert_equal(_joined(annotations_choices()), "off|on|auto")
    assert_true(parse_annotations_value("off").value() == AnnotationsMode.OFF)
    assert_true(parse_annotations_value("on").value() == AnnotationsMode.ON)
    assert_true(parse_annotations_value("auto").value() == AnnotationsMode.AUTO)


def test_annotations_refuses_a_spelling_outside_the_list() raises:
    assert_false(Bool(parse_annotations_value("true")))
    assert_false(Bool(parse_annotations_value("Off")))
    assert_false(Bool(parse_annotations_value("")))


def test_report_style_choices_are_the_published_two() raises:
    assert_equal(_joined(report_style_choices()), "concise|full")


def test_every_report_style_choice_is_accepted() raises:
    for choice in report_style_choices():
        assert_true(
            Bool(parse_report_style_value(choice)),
            "unaccepted choice: " + choice,
        )


def test_report_style_list_order_is_the_discriminant_order() raises:
    assert_equal(_joined(report_style_choices()), "concise|full")
    assert_true(
        parse_report_style_value("concise").value() == ReportStyle.CONCISE
    )
    assert_true(parse_report_style_value("full").value() == ReportStyle.FULL)


# --- the collect `--format` domain, owned here rather than in the parser ---


def test_collect_format_choices_are_the_published_two() raises:
    assert_equal(_joined(collect_format_choices()), "lines|json")


def test_collect_format_lines_selects_the_plain_listing() raises:
    var parsed = parse_collect_format_value("lines")
    assert_true(Bool(parsed))
    assert_false(parsed.value())


def test_collect_format_json_selects_the_ndjson_stream() raises:
    var parsed = parse_collect_format_value("json")
    assert_true(Bool(parsed))
    assert_true(parsed.value())


def test_every_collect_format_choice_is_accepted() raises:
    for choice in collect_format_choices():
        assert_true(
            Bool(parse_collect_format_value(choice)),
            "unaccepted choice: " + choice,
        )


def test_collect_format_refuses_a_spelling_outside_the_list() raises:
    assert_false(Bool(parse_collect_format_value("")))
    assert_false(Bool(parse_collect_format_value("JSON")))
    assert_false(Bool(parse_collect_format_value("ndjson")))


# --- `--workers`: a one-member closed arm beside a free integer arm ---


def test_workers_choices_are_the_closed_arm_alone() raises:
    """`auto` is closed; every other accepted value is a free integer."""
    assert_equal(_joined(workers_choices()), "auto")


def test_every_workers_choice_is_accepted() raises:
    for choice in workers_choices():
        var parsed = parse_worker_count(choice)
        assert_true(Bool(parsed), "unaccepted choice: " + choice)
        assert_equal(parsed.value(), 0)


def test_workers_refuses_a_near_miss_on_the_closed_arm() raises:
    assert_false(Bool(parse_worker_count("Auto")))
    assert_false(Bool(parse_worker_count("automatic")))


# --- `--report`: closed prefixes, then a free path ---


def test_report_format_prefixes_carry_their_separator() raises:
    """The published entries are what a renderer offers, colon included."""
    assert_equal(_joined(report_format_prefixes()), "md:|html:")


def test_every_report_prefix_is_accepted_before_a_path() raises:
    for prefix in report_format_prefixes():
        var parsed = parse_report_value(prefix + "out.txt")
        assert_true(Bool(parsed), "unaccepted prefix: " + prefix)
        assert_equal(parsed.value().path, "out.txt")
        assert_equal(parsed.value().format + ":", prefix)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
