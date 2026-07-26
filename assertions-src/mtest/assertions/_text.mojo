"""First-differing-scalar diagnostics for top-level strings."""

from mtest.assertions._display import (
    BoundedWriter,
    TEXT_CONTEXT_BYTE_CAP,
    _escaped_piece,
)


def _hex_digit(value: Int) -> String:
    comptime HEX_DIGITS = "0123456789ABCDEF"
    return String(HEX_DIGITS[byte=value])


def _uplus(value: Int) -> String:
    var output = String("U+")
    if value <= 0xFFFF:
        for shift in range(3, -1, -1):
            output += _hex_digit((value >> (shift * 4)) & 0xF)
    else:
        for shift in range(7, -1, -1):
            output += _hex_digit((value >> (shift * 4)) & 0xF)
    return output^


def _is_format_control(value: Int) -> Bool:
    return (
        value == 0x200B
        or value == 0x200C
        or value == 0x200D
        or value == 0x200E
        or value == 0x200F
        or (value >= 0x202A and value <= 0x202E)
        or (value >= 0x2060 and value <= 0x2064)
        or (value >= 0x2066 and value <= 0x206F)
        or value == 0xFEFF
    )


def _first_differing_byte(actual: String, expected: String) -> Int:
    var actual_bytes = actual.as_bytes()
    var expected_bytes = expected.as_bytes()
    var common = min(len(actual_bytes), len(expected_bytes))
    var index = 0
    while index < common and actual_bytes[index] == expected_bytes[index]:
        index += 1
    if index == common:
        return index
    while index > 0 and (actual_bytes[index] & UInt8(0xC0)) == UInt8(0x80):
        index -= 1
    return index


def _scalar_index_at(text: String, byte_index: Int) -> Int:
    var offset = 0
    var scalar_index = 0
    for scalar in text.codepoint_slices():
        if offset >= byte_index:
            return scalar_index
        offset += scalar.byte_length()
        scalar_index += 1
    return scalar_index


def _line_at(text: String, byte_index: Int) -> Int:
    var line = 1
    var bytes = text.as_bytes()
    for index in range(min(byte_index, len(bytes))):
        if bytes[index] == UInt8(ord("\n")):
            line += 1
    return line


def _scalar_label(text: String, byte_index: Int) -> String:
    if byte_index >= text.byte_length():
        return "<END> (end of text)"
    var offset = 0
    for scalar in text.codepoint_slices():
        if offset == byte_index:
            var value = Int(ord(scalar))
            if value == 10:
                return _uplus(value) + " LINE FEED (category Cc)"
            if value == 13:
                return _uplus(value) + " CARRIAGE RETURN (category Cc)"
            if value == 0xA0:
                return _uplus(value) + " NO-BREAK SPACE (category Zs)"
            if value >= 0x300 and value <= 0x36F:
                return _uplus(value) + " COMBINING MARK (category Mn)"
            if value == 0x200B:
                return _uplus(value) + " ZERO WIDTH SPACE (category Cf)"
            if (value >= 0x202A and value <= 0x202E) or (
                value >= 0x2066 and value <= 0x2069
            ):
                return _uplus(value) + " BIDI CONTROL (category Cf)"
            if _is_format_control(value):
                return _uplus(value) + " FORMAT CONTROL (category Cf)"
            return _uplus(value) + " '" + _escaped_piece(value) + "'"
        offset += scalar.byte_length()
    return "<END> (end of text)"


def _write_context(
    mut output: BoundedWriter,
    title: String,
    text: String,
    focus_line: Int,
):
    var first = max(1, focus_line - 2)
    var last = focus_line + 2
    var line = 1
    var header_written = False
    for scalar in text.codepoints():
        if line >= first and line <= last and not header_written:
            output.write_trusted(
                "\n  " + title + " line " + String(line) + ": "
            )
            header_written = True
        if line >= first and line <= last:
            output.write_trusted(_escaped_piece(Int(scalar)))
        if Int(scalar) == 10:
            line += 1
            header_written = False
    if line >= first and line <= last and not header_written:
        output.write_trusted("\n  " + title + " line " + String(line) + ": ")


def write_text_detail(
    mut output: BoundedWriter,
    actual: String,
    expected: String,
):
    """Write bounded context around the first differing Unicode scalar."""
    var byte_index = _first_differing_byte(actual, expected)
    var scalar_index = min(
        _scalar_index_at(actual, byte_index),
        _scalar_index_at(expected, byte_index),
    )
    var detail = BoundedWriter(TEXT_CONTEXT_BYTE_CAP)
    detail.write_trusted(
        "text differs at scalar "
        + String(scalar_index)
        + "\n  actual: "
        + _scalar_label(actual, byte_index)
        + "\n  expected: "
        + _scalar_label(expected, byte_index)
    )
    _write_context(detail, "actual", actual, _line_at(actual, byte_index))
    _write_context(detail, "expected", expected, _line_at(expected, byte_index))
    output.write_trusted(detail.finish())
