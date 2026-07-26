"""First-differing-scalar diagnostics for top-level strings."""

from mtest.assertions._display import (
    BoundedWriter,
    TEXT_CONTEXT_BYTE_CAP,
    _escaped_piece,
    _is_combining_mark,
    _is_enclosing_mark,
    _is_format_control,
    _is_non_ascii_separator,
    _is_private_use,
    _is_unassigned_default_ignorable,
    _is_variation_selector,
)

comptime _SIDE_CONTEXT_BYTE_CAP = 1850
comptime _CONTEXT_PREFIX_RAW_BYTES = 128


def _hex_digit(value: Int) -> String:
    comptime HEX_DIGITS = "0123456789ABCDEF"
    return String(HEX_DIGITS[byte=value])


def _uplus(value: Int) -> String:
    var output = String("U+")
    var highest_shift = 3
    if value > 0xFFFF:
        highest_shift = 4
    if value > 0xFFFFF:
        highest_shift = 5
    for shift in range(highest_shift, -1, -1):
        output += _hex_digit((value >> (shift * 4)) & 0xF)
    return output^


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
            if value >= 0x80 and value <= 0x9F:
                return _uplus(value) + " CONTROL (category Cc)"
            if value == 0xA0:
                return _uplus(value) + " NO-BREAK SPACE (category Zs)"
            if _is_non_ascii_separator(value):
                if value == 0x2028:
                    return _uplus(value) + " LINE SEPARATOR (category Zl)"
                if value == 0x2029:
                    return _uplus(value) + " PARAGRAPH SEPARATOR (category Zp)"
                return _uplus(value) + " SPACE SEPARATOR (category Zs)"
            if _is_variation_selector(value):
                return _uplus(value) + " VARIATION SELECTOR (category Mn)"
            if _is_enclosing_mark(value):
                return _uplus(value) + " ENCLOSING MARK (category Me)"
            if _is_combining_mark(value):
                return _uplus(value) + " COMBINING MARK (category Mn)"
            if value == 0x200B:
                return _uplus(value) + " ZERO WIDTH SPACE (category Cf)"
            if (value >= 0x202A and value <= 0x202E) or (
                value >= 0x2066 and value <= 0x2069
            ):
                return _uplus(value) + " BIDI CONTROL (category Cf)"
            if _is_format_control(value):
                if value == 0xAD:
                    return _uplus(value) + " FORMAT CONTROL (category Cf)"
                if value >= 0xE0020 and value <= 0xE007F:
                    return _uplus(value) + " TAG CHARACTER (category Cf)"
                return _uplus(value) + " FORMAT CONTROL (category Cf)"
            if _is_unassigned_default_ignorable(value):
                return _uplus(value) + " DEFAULT IGNORABLE (category Cn)"
            if _is_private_use(value):
                return _uplus(value) + " PRIVATE USE (category Co)"
            return _uplus(value) + " '" + _escaped_piece(value) + "'"
        offset += scalar.byte_length()
    return "<END> (end of text)"


def _write_context(
    mut output: BoundedWriter,
    title: String,
    text: String,
    focus_line: Int,
    focus_byte: Int,
):
    var first = max(1, focus_line - 2)
    var last = focus_line + 2
    var crop_start = max(0, focus_byte - _CONTEXT_PREFIX_RAW_BYTES)
    var crop_line = _line_at(text, crop_start)
    var text_bytes = text.as_bytes()
    var prefix_cropped = (
        crop_start > 0
        and crop_line >= first
        and text_bytes[crop_start - 1] != UInt8(ord("\n"))
    )
    var line = 1
    var offset = 0
    var header_written = False
    var first_header = True
    for scalar in text.codepoint_slices():
        if output.truncated or line > last:
            return
        var scalar_stop = offset + scalar.byte_length()
        if scalar_stop <= crop_start:
            if Int(ord(scalar)) == 10:
                line += 1
            offset = scalar_stop
            continue
        if line >= first and line <= last and not header_written:
            output.write_trusted(
                "\n  " + title + " line " + String(line) + ": "
            )
            if first_header and prefix_cropped:
                output.write_trusted("... ")
            header_written = True
            first_header = False
        if line >= first and line <= last:
            output.write_escaped_scalar(Int(ord(scalar)))
        if Int(ord(scalar)) == 10:
            line += 1
            header_written = False
        offset = scalar_stop
    if line >= first and line <= last and not header_written:
        output.write_trusted("\n  " + title + " line " + String(line) + ": ")


def write_text_detail(
    mut output: BoundedWriter,
    actual: String,
    expected: String,
):
    """Write bounded context around the first differing Unicode scalar."""
    var byte_index = _first_differing_byte(actual, expected)
    var scalar_index = _scalar_index_at(actual, byte_index)
    var actual_context = BoundedWriter(_SIDE_CONTEXT_BYTE_CAP)
    _write_context(
        actual_context,
        "actual",
        actual,
        _line_at(actual, byte_index),
        byte_index,
    )
    var expected_context = BoundedWriter(_SIDE_CONTEXT_BYTE_CAP)
    _write_context(
        expected_context,
        "expected",
        expected,
        _line_at(expected, byte_index),
        byte_index,
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
    detail.write_trusted(actual_context.finish())
    detail.write_trusted(expected_context.finish())
    output.write_trusted(detail.finish())
