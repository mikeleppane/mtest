"""Which code points a terminal emulator interprets rather than displays.

Four surfaces render untrusted, child-controlled text to a terminal and must
neutralize it first: the console reporter (`report/console_text.mojo`), the
`doctor` diagnostic lines (`cli/doctor.mojo`), the `config show` TOML rendering
(`config/show.mojo`), and the configuration diagnostics that quote an offending
key or value back from `mtest.toml` (`config/toml_bridge.mojo`). They cannot
share their *escape text*: the console emits `\\xHH` and `\\u00HH` in uppercase
hex, `doctor` and the TOML diagnostics emit lowercase `\\xHH`, and `config show`
must emit `\\u00HH` because it is producing TOML, whose basic strings have a
`\\uXXXX` escape and no `\\xHH` escape at all.

They can and must share the *classification*: the set of code points a
terminal treats as instructions. That set is defined once, here, so extending
it reaches every surface at once instead of leaving one of them behind. This
module lives in `model` because it is the only layer all four may import from:
`config` may not import `report`, which is exactly how the second and third
copies of this policy came to exist.

**Bound on that promise: the set must stay within `U+0000..U+00FF`.** Every
consuming surface renders exactly two hex digits from the low byte, so a code
point above `U+00FF` would be spelled wrongly rather than escaped: silently in
the console (its assembler masks the value) and as an out-of-range index in the
other three. Adding a code point inside Latin-1 reaches all four surfaces for
free; adding one above it requires widening each surface's escape assembler
first. The candidates named as non-goals below all lie above `U+00FF`, so this
is the bound the next extension will meet.

The set is:

- the **C0 controls** `U+0000..U+001F`, which include ESC (`U+001B`), the
  introducer for every classic control sequence;
- **DEL** `U+007F`;
- the **C1 controls** `U+0080..U+009F`, which are the single-code-point forms of
  sequences that otherwise need ESC (`U+009B` is CSI, `U+009D` is OSC, `U+009C`
  is ST), so a payload carrying them drives a terminal with no ESC byte
  anywhere in it. Omitting C1 is the classic hole in a terminal escaper, because
  a scan for ESC never sees one.

Classification is by code point, not by byte: the C1 controls are two-byte UTF-8
sequences that a byte scan would either miss or split.

**Non-goal: visual spoofing.** This module answers "can the child drive the
terminal", not "can the child mislead the reader". Code points that reorder or
disguise text while executing nothing (the bidi overrides and isolates, zero
width characters, and confusable homoglyphs) are not interpreted controls and
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

    Examples:

    ```mojo
    from mtest.model import is_c1_control

    var csi = is_c1_control(0x9B)  # True: CSI, reached with no ESC byte
    var nbsp = is_c1_control(0xA0)  # False: just above the C1 block
    ```
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

    Examples:

    ```mojo
    from mtest.model import is_interpreted_control

    var esc = is_interpreted_control(0x1B, preserve_lf_tab=False)  # True
    var letter = is_interpreted_control(0x41, preserve_lf_tab=False)  # False
    var newline = is_interpreted_control(0x0A, preserve_lf_tab=True)  # False
    ```
    """
    if preserve_lf_tab and (code == 0x0A or code == 0x09):
        return False
    return is_c0_control(code) or is_c1_control(code)


def _hex_escape(code: Int) -> String:
    """Render one interpreted control as `\\xNN`.

    Two hex digits always suffice: `is_interpreted_control` is True only for
    C0, DEL, and C1, so the widest value it ever passes here is `U+009F`.
    """
    comptime DIGITS = "0123456789abcdef"
    return (
        String("\\x")
        + String(DIGITS[byte=(code >> 4) & 0xF])
        + String(DIGITS[byte=code & 0xF])
    )


def escape_one_line(text: String) -> String:
    """Render `text` on exactly ONE physical line, with no terminal control.

    A path, node id, or pattern is user-controlled input that mtest echoes back
    in diagnostics. Emitted raw, a `\\n` inside one splits a single diagnostic
    into two physical lines — a consumer parsing stderr line-wise reads a bogus
    second record — and an ESC or C1 byte drives the reader's terminal. Both
    are input smuggling a diagnostic's structure, so every interpolation of
    untrusted text into a one-line message goes through here.

    LF, CR, and Tab get named short forms because a reader recognizes them;
    every other interpreted control becomes a hex escape. Non-control code
    points, including all non-ASCII text, pass through unchanged, so a legible
    Unicode filename stays legible.

    Args:
        text: Untrusted display text, already valid UTF-8.

    Returns:
        A single-line, control-free rendering of `text`.

    Examples:

    ```mojo
    from mtest.model import escape_one_line

    # A newline in a path can no longer forge a second diagnostic line.
    var safe = escape_one_line("paths/line\nbreak/test_a.mojo")
    ```
    """
    var escaped = String("")
    for cp in text.codepoints():
        var value = Int(cp)
        if value == 0x0A:
            escaped += "\\n"
        elif value == 0x0D:
            escaped += "\\r"
        elif value == 0x09:
            escaped += "\\t"
        elif is_interpreted_control(value, preserve_lf_tab=False):
            escaped += _hex_escape(value)
        else:
            escaped += String(cp)
    return escaped^
