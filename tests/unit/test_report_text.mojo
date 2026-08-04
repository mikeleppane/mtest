"""Tests for the shared pure-text run-report module (Layer 2).

`report_text` gives every report renderer one shared, pure implementation of
Markdown structural escaping and the console's FAIL-detail normalization, so a
console rendering and a Markdown rendering of the same event stream cannot
drift apart from two independent implementations. These tests pin the exact
expected bytes, not a structural "no raw character" property, because a
delimiter-producing escaper always leaves some structural character behind by
design.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.report.report_text import (
    md_code_fence,
    md_code_span,
    md_escape_cell,
    normalize_detail,
)


def test_md_cell_escapes_structural_characters() raises:
    assert_equal(md_escape_cell("a|b"), "a\\|b")
    # Only '<' and '&' are escaped; a bare '>' is inert.
    assert_equal(md_escape_cell("<details>"), "&lt;details>")
    assert_equal(md_escape_cell("x&y"), "x&amp;y")


def test_md_cell_flattens_newlines_via_escape_scalar() raises:
    # escape_scalar renders LF as the FOUR VISIBLE characters \x0A
    # (console_text._byte_escape, "\\x" + hex); md_escape_cell then doubles
    # that backslash structurally. Raw expected bytes: a \ \ x 0 A b.
    assert_equal(md_escape_cell("a\nb"), "a\\\\x0Ab")
    # Tab takes the same road (raw: a \ \ x 0 9 b):
    assert_equal(md_escape_cell("a\tb"), "a\\\\x09b")


def test_md_cell_neutralizes_an_inline_link() raises:
    """A path that spells a link renders as inert text, not as a live link."""
    assert_equal(
        md_escape_cell("test_[click](https://example.com/x).mojo"),
        "test_\\[click\\](https://example.com/x).mojo",
    )


def test_md_cell_neutralizes_an_image_reference() raises:
    """The image form is the beacon case: it would load a remote resource."""
    assert_equal(
        md_escape_cell("![x](https://example.com/p.png)"),
        "\\!\\[x\\](https://example.com/p.png)",
    )


def test_md_cell_neutralizes_a_reference_style_link() raises:
    """Both the reference use and the definition it would resolve against."""
    assert_equal(md_escape_cell("[x][ref]"), "\\[x\\]\\[ref\\]")
    assert_equal(
        md_escape_cell("[ref]: https://example.com/x"),
        "\\[ref\\]: https://example.com/x",
    )


def test_md_cell_escapes_a_leading_bang_only_at_the_front() raises:
    """The leading rule mirrors the list/heading/quote rule already there."""
    assert_equal(md_escape_cell("a!b"), "a!b")


def test_code_span_grows_past_interior_backticks() raises:
    assert_equal(md_code_span("a`b"), "``a`b``")
    assert_equal(md_code_span("x"), "`x`")


def test_code_span_pads_a_boundary_backtick() raises:
    """Without the padding CommonMark parses no code span here at all."""
    assert_equal(md_code_span("`x"), "`` `x ``")
    assert_equal(md_code_span("x`"), "`` x` ``")


def test_code_span_keeps_link_syntax_verbatim_and_inert() raises:
    """A code span's content is literal by CommonMark's own rule, so the
    bracket pass `md_escape_cell` performs would be visible noise here."""
    assert_equal(md_code_span("[x](https://e/p)"), "`[x](https://e/p)`")


def test_code_fence_longer_than_interior_run() raises:
    var fenced = md_code_fence("uses ``` three")
    assert_true(fenced.startswith("````\n"))
    assert_true(fenced.endswith("\n````\n"))


def test_normalize_detail_matches_console_transform() raises:
    var got = normalize_detail("  line one\n  At /r/tests/a.mojo:3", "/r")
    assert_equal(got, "line one\nAt tests/a.mojo:3")


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
