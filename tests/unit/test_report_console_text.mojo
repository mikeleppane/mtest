"""Table tests for the console text-safety boundary (Layer 2).

`console_text` is the single place mtest decides which characters a terminal is
allowed to interpret, so these tests pin the mapping exactly rather than
structurally: every assertion names the whole expected string, and the two
completeness sweeps walk `U+0000..U+009F` and require that nothing a terminal
executes survives. A test here fails on the exact byte that changed.

The three surfaces under test are `escape_scalar` (a value that must occupy one
console line), `escape_multiline` (a block whose LF and Tab structure is real),
and `prefix_lines` (the gutter that fences an escaped block).
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.report.console_text import (
    escape_multiline,
    escape_scalar,
    prefix_lines,
)


def _count(haystack: String, needle: String) -> Int:
    """How many non-overlapping times `needle` occurs in `haystack`."""
    return len(haystack.split(needle)) - 1


def _is_interpreted_control(value: Int) -> Bool:
    """Whether a code point is one a terminal emulator acts on.

    The three ranges this module exists to neutralize: the C0 controls, DEL, and
    the C1 controls. Written independently of the escapers so a sweep using it
    cannot agree with a broken implementation by construction.

    Args:
        value: The code point to classify.

    Returns:
        True for `U+0000..U+001F`, `U+007F`, and `U+0080..U+009F`.
    """
    if value < 0x20:
        return True
    if value == 0x7F:
        return True
    return value >= 0x80 and value <= 0x9F


def _holds_interpreted_control(text: String) -> Bool:
    """Whether `text` still carries any code point a terminal would act on."""
    for cp in text.codepoints():
        if _is_interpreted_control(Int(cp)):
            return True
    return False


# --- escape_scalar: EVERY C0, including LF and Tab ---


def test_escape_scalar_maps_named_c0_controls_to_uppercase_hex() raises:
    # Literal expectations, not a recomputation of the implementation's own
    # arithmetic: each pair is the exact text this mapping promises.
    assert_equal(escape_scalar(chr(0x00)), "\\x00")
    assert_equal(escape_scalar(chr(0x07)), "\\x07")
    assert_equal(escape_scalar(chr(0x08)), "\\x08")
    assert_equal(escape_scalar(chr(0x0B)), "\\x0B")
    assert_equal(escape_scalar(chr(0x0C)), "\\x0C")
    assert_equal(escape_scalar(chr(0x0D)), "\\x0D")
    assert_equal(escape_scalar(chr(0x1B)), "\\x1B")
    assert_equal(escape_scalar(chr(0x1F)), "\\x1F")


def test_escape_scalar_escapes_lf_and_tab_too() raises:
    # The difference from `escape_multiline`: a scalar value is one line, so its
    # own LF and Tab are escaped rather than preserved.
    assert_equal(escape_scalar("a\nb"), "a\\x0Ab")
    assert_equal(escape_scalar("a\tb"), "a\\x09b")


def test_escape_scalar_maps_del_to_uppercase_hex() raises:
    assert_equal(escape_scalar(chr(0x7F)), "\\x7F")


def test_escape_scalar_maps_c1_controls_to_the_u_form() raises:
    assert_equal(escape_scalar(chr(0x80)), "\\u0080")
    assert_equal(escape_scalar(chr(0x85)), "\\u0085")
    assert_equal(escape_scalar(chr(0x9B)), "\\u009B")
    assert_equal(escape_scalar(chr(0x9F)), "\\u009F")


def test_escape_scalar_leaves_every_interpreted_control_unrenderable() raises:
    # Completeness sweep: not one code point in the three ranges may survive as
    # itself. Exempting a single value from the escaper reds this.
    for value in range(0x00, 0xA0):
        if not _is_interpreted_control(value):
            continue
        var escaped = escape_scalar(chr(value))
        assert_false(
            _holds_interpreted_control(escaped),
            String("escape_scalar left code point ") + String(value) + " raw",
        )


def test_escape_scalar_leaves_printable_ascii_byte_identical() raises:
    var plain = String(
        " !\"#$%&'()*+,-./0123456789:;<=>?@ABCXYZ[\\]^_`abcxyz{|}~"
    )
    assert_equal(escape_scalar(plain), plain)


def test_escape_scalar_leaves_printable_unicode_unchanged() raises:
    # U+00A0 sits one past the C1 range, so the upper boundary is pinned too.
    var text = String("héllo — 日本語 🚀 ") + chr(0xA0) + chr(0xFFFD)
    assert_equal(escape_scalar(text), text)


def test_escape_scalar_keeps_quotes_and_backslashes_literal() raises:
    # The escaper adds escape TEXT; it is not a quoting function and must not
    # double up a backslash or touch a quote.
    assert_equal(escape_scalar("a\\b'c\"d"), "a\\b'c\"d")


def test_escape_scalar_neutralizes_a_csi_color_sequence() raises:
    assert_equal(escape_scalar("\x1b[31mred\x1b[0m"), "\\x1B[31mred\\x1B[0m")


def test_escape_scalar_neutralizes_an_osc_terminated_by_bel() raises:
    assert_equal(escape_scalar("\x1b]0;pwned\x07"), "\\x1B]0;pwned\\x07")


def test_escape_scalar_neutralizes_an_osc_terminated_by_st() raises:
    # ST has two spellings: the two-byte ESC-backslash and the single C1 U+009C.
    assert_equal(escape_scalar("\x1b]0;pwned\x1b\\"), "\\x1B]0;pwned\\x1B\\")
    assert_equal(
        escape_scalar(String("\x1b]0;pwned") + chr(0x9C)),
        "\\x1B]0;pwned\\u009C",
    )


# --- escape_multiline: LF and Tab survive, everything else does not ---


def test_escape_multiline_preserves_lf_and_tab() raises:
    assert_equal(escape_multiline("a\nb\tc\n"), "a\nb\tc\n")


def test_escape_multiline_escapes_cr_so_a_child_cannot_overwrite_a_line() raises:
    assert_equal(escape_multiline("done\rfake"), "done\\x0Dfake")


def test_escape_multiline_maps_named_c0_controls_to_uppercase_hex() raises:
    assert_equal(escape_multiline(chr(0x00)), "\\x00")
    assert_equal(escape_multiline(chr(0x07)), "\\x07")
    assert_equal(escape_multiline(chr(0x08)), "\\x08")
    assert_equal(escape_multiline(chr(0x0B)), "\\x0B")
    assert_equal(escape_multiline(chr(0x0C)), "\\x0C")
    assert_equal(escape_multiline(chr(0x1B)), "\\x1B")
    assert_equal(escape_multiline(chr(0x1F)), "\\x1F")


def test_escape_multiline_maps_del_and_c1_controls() raises:
    assert_equal(escape_multiline(chr(0x7F)), "\\x7F")
    assert_equal(escape_multiline(chr(0x80)), "\\u0080")
    assert_equal(escape_multiline(chr(0x9F)), "\\u009F")


def test_escape_multiline_leaves_only_lf_and_tab_interpreted() raises:
    # Completeness sweep with the two documented exemptions named explicitly.
    for value in range(0x00, 0xA0):
        if not _is_interpreted_control(value):
            continue
        var escaped = escape_multiline(chr(value))
        if value == 0x0A or value == 0x09:
            assert_equal(escaped, chr(value))
            continue
        assert_false(
            _holds_interpreted_control(escaped),
            String("escape_multiline left code point ")
            + String(value)
            + " raw",
        )


def test_escape_multiline_leaves_printable_unicode_unchanged() raises:
    var text = String("héllo — 日本語 🚀\n\tindented\n")
    assert_equal(escape_multiline(text), text)


def test_escape_multiline_neutralizes_an_osc_terminated_by_bel() raises:
    assert_equal(escape_multiline("\x1b]0;pwned\x07\n"), "\\x1B]0;pwned\\x07\n")


def test_escape_multiline_neutralizes_a_nul_inside_a_line() raises:
    assert_equal(escape_multiline("a\x00b\n"), "a\\x00b\n")


# --- prefix_lines: the gutter, and nothing else ---


def test_prefix_lines_fences_every_logical_line() raises:
    assert_equal(prefix_lines("a\n\nb\n"), "    | a\n    | \n    | b\n")


def test_prefix_lines_final_lf_creates_no_phantom_line() raises:
    # The exact defect the mapping calls out: a trailing LF closes the last
    # line, it does not open an empty fourth one.
    assert_equal(_count(prefix_lines("a\n\nb\n"), "    | "), 3)


def test_prefix_lines_empty_text_is_empty() raises:
    assert_equal(prefix_lines(""), "")


def test_prefix_lines_terminates_an_unterminated_last_line() raises:
    assert_equal(prefix_lines("a\nb"), "    | a\n    | b\n")


def test_prefix_lines_fences_a_single_empty_logical_line() raises:
    assert_equal(prefix_lines("\n"), "    | \n")


def test_prefix_lines_accepts_a_custom_prefix() raises:
    assert_equal(prefix_lines("a\nb\n", "> "), "> a\n> b\n")


def test_prefix_lines_does_not_escape_anything() raises:
    # Line fencing only: it holds no character policy, so an ESC handed to it
    # rides through. This is why it is always applied AFTER an escaper.
    assert_equal(prefix_lines("\x1b[31m\n"), "    | \x1b[31m\n")


def test_escaped_then_fenced_block_carries_no_interpreted_control() raises:
    # The composition the console actually performs, end to end.
    var hostile = String("ok\n\x1b[2J\x1b]0;t\x07\rfake\n") + chr(0x9B) + "\n"
    var rendered = prefix_lines(escape_multiline(hostile))
    assert_equal(
        rendered,
        "    | ok\n    | \\x1B[2J\\x1B]0;t\\x07\\x0Dfake\n    | \\u009B\n",
    )
