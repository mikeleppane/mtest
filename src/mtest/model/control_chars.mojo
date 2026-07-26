"""Which code points a terminal emulator interprets rather than displays.

Three surfaces render untrusted, child-controlled text to a terminal and must
neutralize it first: the console reporter (`report/console_text.mojo`), the
`doctor` diagnostic lines (`cli/doctor.mojo`), and the `config show` TOML
rendering (`config/show.mojo`). They cannot share their *escape text* — the
console emits `\\xHH` and `\\u00HH` in uppercase hex, `doctor` emits lowercase
`\\xHH`, and `config show` must emit `\\u00HH` because it is producing TOML,
whose basic strings have a `\\uXXXX` escape and no `\\xHH` escape at all.

What they can and must share is the *classification*: the set of code points a
terminal treats as instructions. That set is defined once, here, so extending
it reaches every surface at once instead of leaving one of them behind. This
module lives in `model` because it is the only layer all three may import from:
`config` may not import `report`, which is exactly how the second and third
copies of this policy came to exist.

The set is:

- the **C0 controls** `U+0000..U+001F`, which include ESC (`U+001B`), the
  introducer for every classic control sequence;
- **DEL** `U+007F`;
- the **C1 controls** `U+0080..U+009F`, which are the single-code-point forms of
  sequences that otherwise need ESC — `U+009B` is CSI, `U+009D` is OSC,
  `U+009C` is ST — so a payload carrying them drives a terminal with no ESC byte
  anywhere in it. Omitting C1 is the classic hole in a terminal escaper, because
  a scan for ESC never sees one.

Classification is by code point, not by byte: the C1 controls are two-byte UTF-8
sequences that a byte scan would either miss or split.

**Non-goal: visual spoofing.** This module answers "can the child drive the
terminal", not "can the child mislead the reader". Code points that reorder or
disguise text while executing nothing — the bidi overrides and isolates, zero
width characters, and confusable homoglyphs — are not interpreted controls and
are deliberately absent from the set.
"""


def is_c0_control(code: Int) -> Bool:
    """Whether `code` is a C0 control or DEL.

    Args:
        code: A Unicode code point value.

    Returns:
        True for `U+0000..U+001F` and for DEL `U+007F`.
    """
    return (code >= 0 and code < 0x20) or code == 0x7F


def is_c1_control(code: Int) -> Bool:
    """Whether `code` is a C1 control.

    Args:
        code: A Unicode code point value.

    Returns:
        True for `U+0080..U+009F`, which a terminal in UTF-8 mode interprets as
        CSI, OSC, ST and their neighbours without any ESC byte present.
    """
    return code >= 0x80 and code <= 0x9F


def is_interpreted_control(code: Int, preserve_lf_tab: Bool) -> Bool:
    """Whether a terminal would interpret `code` rather than display it.

    The one policy point every terminal-facing escaper in mtest consults. A
    caller that answers False here must copy the code point through unchanged;
    a caller that answers True must replace it with escape text in whatever
    spelling its own output format requires.

    Args:
        code: A Unicode code point value.
        preserve_lf_tab: Whether LF (`U+000A`) and Tab (`U+0009`) are being
            rendered literally. A block that legitimately spans lines passes
            True; a value that must occupy exactly one line passes False, which
            makes LF and Tab interpreted controls like the rest of C0.

    Returns:
        True when `code` is a C0 control, DEL, or a C1 control, except that LF
        and Tab are excluded when `preserve_lf_tab` is set.
    """
    if preserve_lf_tab and (code == 0x0A or code == 0x09):
        return False
    return is_c0_control(code) or is_c1_control(code)
