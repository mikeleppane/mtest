"""Boundary tests for the terminal-control classification (Layer 0).

`control_chars` is the one definition of which code points a terminal
interprets rather than displays. Three surfaces consult it — the console
reporter, `doctor`, and `config show` — and they spell their escapes three
different ways, so the classification is the only thing they can share and the
only thing that must never drift.

Every range boundary is pinned with a literal code point rather than derived
from the predicate under test, so an edit that widens or narrows a range shows
up as a failure here rather than being restated by the test.
"""
from std.testing import assert_false, assert_true

from mtest.model.control_chars import (
    is_c0_control,
    is_c1_control,
    is_interpreted_control,
)


def test_c0_covers_nul_through_unit_separator() raises:
    assert_true(is_c0_control(0x00))
    assert_true(is_c0_control(0x1B))
    assert_true(is_c0_control(0x1F))
    assert_false(is_c0_control(0x20))


def test_c0_includes_del_but_not_its_neighbours() raises:
    assert_false(is_c0_control(0x7E))
    assert_true(is_c0_control(0x7F))
    assert_false(is_c0_control(0x80))


def test_c1_covers_padding_through_application_program_command() raises:
    assert_false(is_c1_control(0x7F))
    assert_true(is_c1_control(0x80))
    assert_true(is_c1_control(0x9F))
    assert_false(is_c1_control(0xA0))


def test_c1_holds_the_esc_free_sequence_introducers() raises:
    """CSI, ST and OSC in the single-code-point form a scan for ESC misses."""
    assert_true(is_c1_control(0x9B))
    assert_true(is_c1_control(0x9C))
    assert_true(is_c1_control(0x9D))


def test_interpreted_set_is_c0_del_and_c1() raises:
    assert_true(is_interpreted_control(0x00, preserve_lf_tab=False))
    assert_true(is_interpreted_control(0x1B, preserve_lf_tab=False))
    assert_true(is_interpreted_control(0x7F, preserve_lf_tab=False))
    assert_true(is_interpreted_control(0x9B, preserve_lf_tab=False))
    assert_false(is_interpreted_control(0x41, preserve_lf_tab=False))
    assert_false(is_interpreted_control(0xA0, preserve_lf_tab=False))


def test_preserving_lf_and_tab_exempts_only_those_two() raises:
    assert_false(is_interpreted_control(0x0A, preserve_lf_tab=True))
    assert_false(is_interpreted_control(0x09, preserve_lf_tab=True))
    # CR is not exempt: a block that keeps CR lets a child overwrite a line
    # it already wrote.
    assert_true(is_interpreted_control(0x0D, preserve_lf_tab=True))
    assert_true(is_interpreted_control(0x1B, preserve_lf_tab=True))
    assert_true(is_interpreted_control(0x9B, preserve_lf_tab=True))


def test_lf_and_tab_are_interpreted_when_not_preserved() raises:
    assert_true(is_interpreted_control(0x0A, preserve_lf_tab=False))
    assert_true(is_interpreted_control(0x09, preserve_lf_tab=False))


def test_every_code_point_below_the_c1_ceiling_is_classified_once() raises:
    """No code point is both classes, and the union is exactly the two ranges.

    A sweep rather than samples, so a range edit that overlaps or leaves a hole
    cannot pass by missing whichever literal the other cases happened to pick.
    """
    for code in range(0, 0x100):
        var c0 = is_c0_control(code)
        var c1 = is_c1_control(code)
        assert_false(c0 and c1)
        assert_true(
            (c0 or c1) == is_interpreted_control(code, preserve_lf_tab=False)
        )
        var expected = (
            (code < 0x20) or code == 0x7F or (code >= 0x80 and code <= 0x9F)
        )
        assert_true((c0 or c1) == expected)


def test_code_points_above_latin_1_are_never_interpreted() raises:
    # The bidi overrides and isolates are a visual-spoofing concern, not a
    # terminal-instruction one, and are deliberately outside the set.
    assert_false(is_interpreted_control(0x202E, preserve_lf_tab=False))
    assert_false(is_interpreted_control(0x2066, preserve_lf_tab=False))
    assert_false(is_interpreted_control(0xFFFD, preserve_lf_tab=False))
    assert_false(is_interpreted_control(0x1F600, preserve_lf_tab=False))
