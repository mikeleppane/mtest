"""The console's text-safety boundary for untrusted, child-controlled text.

Everything mtest prints for a human passes through a terminal emulator, and a
terminal emulator is an interpreter: an ESC byte followed by a control sequence
repositions the cursor, repaints the screen, changes the title, or — with an OSC
sequence — asks the terminal to answer back. A test binary controls its own
stdout, its assertion messages, its file and test names, and the compiler
controls its diagnostics, so every one of those strings is attacker-controlled
text that must never reach the terminal as instructions.

This module is that one boundary. It holds three pure functions and no state, no
I/O, and no environment access, so the policy is auditable in one place and the
console renderer never decides per-call what is safe:

- `escape_scalar` for a value that must occupy exactly one console line — a
  path, a node id, a pattern, a program name, a reproduce argument;
- `escape_multiline` for a block that legitimately spans lines — captured
  stdout/stderr, a failure detail, a compiler diagnostic;
- `prefix_lines` for fencing such a block behind a visible gutter, so a child
  cannot forge a line that reads as one of mtest's own.

The escapers act on Unicode code points, not bytes, because the C1 controls
U+0080..U+009F are two-byte UTF-8 sequences that a byte scan would either miss
or split. Their input is a Mojo `String`, valid UTF-8 by construction; raw child
bytes reach that form through `lossy_utf8` first, exactly as the machine
reporters require.

The escaped result is for display only. Nothing here runs upstream of parsing,
capture, the NDJSON stream, or the JUnit report: those keep their own raw
semantics and their own escaping, and routing console-escaped text into them
would corrupt both.
"""


def _hex_digit(value: Int) -> String:
    """The uppercase ASCII hex digit for one nibble.

    Args:
        value: The nibble to render; the callers here mask to `0..15`.

    Returns:
        `"0"`..`"9"` for `0..9` and `"A"`..`"F"` for `10..15`.
    """
    if value < 10:
        return String(chr(48 + value))
    return String(chr(65 + value - 10))


def _byte_escape(prefix: String, value: Int) -> String:
    """`prefix` followed by `value`'s low byte in two uppercase hex digits.

    The one place an escape sequence's text is assembled, so `\\x` and `\\u00`
    forms cannot drift apart in width or letter case.

    Args:
        prefix: The literal escape introducer, `"\\\\x"` or `"\\\\u00"`.
        value: The code point being escaped. Only its low byte is rendered,
            which is exact for every code point this module escapes: they all
            lie in `U+0000..U+009F`.

    Returns:
        The introducer followed by exactly two uppercase hex digits.
    """
    return prefix + _hex_digit((value >> 4) & 15) + _hex_digit(value & 15)


def _escape_controls(text: String, preserve_lf_tab: Bool) -> String:
    """The shared escaping mechanism behind the two policy functions.

    Walks `text` by code point and rewrites exactly the three ranges a terminal
    interprets: the C0 controls `U+0000..U+001F`, DEL `U+007F`, and the C1
    controls `U+0080..U+009F`. Every other code point — printable ASCII,
    accented Latin, CJK, emoji, and the U+FFFD a lossy decode produced — is
    copied through unchanged, so the only difference between the input and the
    output is a control the terminal would have executed.

    The single policy point is `preserve_lf_tab`; `escape_scalar` and
    `escape_multiline` name the two settings, and no other caller may.

    Args:
        text: Valid UTF-8 display text.
        preserve_lf_tab: Whether LF (`U+000A`) and Tab (`U+0009`) ride through
            literally. False makes the result single-line and tab-free.

    Returns:
        `text` with every interpreted control replaced by its escape text.
    """
    var out = String("")
    for cp in text.codepoints():
        var value = Int(cp)
        if value == 0x0A or value == 0x09:
            if preserve_lf_tab:
                out += String(cp)
            else:
                out += _byte_escape("\\x", value)
        elif value < 0x20:
            out += _byte_escape("\\x", value)
        elif value == 0x7F:
            out += _byte_escape("\\x", value)
        elif value >= 0x80 and value <= 0x9F:
            out += _byte_escape("\\u00", value)
        else:
            out += String(cp)
    return out^


def escape_scalar(text: String) -> String:
    """Neutralize `text` for a console value that must stay on one line.

    Escapes every C0 control `U+0000..U+001F` — LF and Tab included — plus DEL
    `U+007F` and every C1 control `U+0080..U+009F`. A path, node id, pattern,
    program name, or reproduce argument therefore cannot break its own line,
    realign a column, or start a control sequence, whatever bytes the child
    chose for it.

    Args:
        text: The untrusted value, already valid UTF-8.

    Returns:
        A single-line, control-free rendering of `text`.
    """
    return _escape_controls(text, preserve_lf_tab=False)


def escape_multiline(text: String) -> String:
    """Neutralize `text` for a console block that legitimately spans lines.

    Keeps LF and Tab literal, because a captured stream, a failure detail, and
    a compiler diagnostic are all shaped by them, and escapes every other C0
    control, DEL, and every C1 control. CR is escaped along with the rest: a
    bare CR returns the cursor to the start of the line and lets a child
    overwrite what mtest already printed.

    Args:
        text: The untrusted block, already valid UTF-8.

    Returns:
        `text` with its line and tab structure intact and every other control
        rendered as visible escape text.
    """
    return _escape_controls(text, preserve_lf_tab=True)


def prefix_lines(text: String, prefix: String = "    | ") -> String:
    """Fence every logical line of `text` behind `prefix`.

    Owns line fencing and nothing else: it makes no judgement about which
    characters are safe, so it must be applied to already-escaped text. The
    gutter is what makes the child's territory visible — an escaped line can no
    longer forge a control sequence, but it could still forge text that reads
    like one of mtest's own verdict or banner lines, and a gutter it cannot
    reproduce settles that.

    A logical line is a run of text up to and including its terminating LF. A
    trailing LF therefore closes the last line rather than opening an empty one,
    so `"a\\n\\nb\\n"` yields three fenced lines and never a phantom fourth. An
    empty logical line still gets its gutter, keeping the block's shape. Every
    emitted line is LF-terminated, so a block whose final line was unterminated
    gains that terminator and cannot run into whatever mtest prints next.

    Args:
        text: The already-escaped block to fence.
        prefix: The gutter to place before each line.

    Returns:
        The fenced block, or `""` when `text` is empty.
    """
    if text.byte_length() == 0:
        return String("")
    var lines = text.split("\n")
    var count = len(lines)
    if count > 0 and String(lines[count - 1]).byte_length() == 0:
        # The final LF terminated the previous line; it opens no new one.
        count -= 1
    var out = String("")
    for i in range(count):
        out += prefix + String(lines[i]) + "\n"
    return out^
