"""Bounded display primitives for source-only assertion diagnostics."""


comptime VALUE_BYTE_CAP = 1024
comptime BODY_BYTE_CAP = 16384
comptime TEXT_CONTEXT_BYTE_CAP = 4096
comptime DICTIONARY_KEY_BYTE_CAP = 1024
comptime DISPLAY_LIMIT = 8
comptime TRUNCATION_MARKER = "... [truncated]"


def _hex_digit(value: Int) -> String:
    comptime HEX_DIGITS = "0123456789abcdef"
    return String(HEX_DIGITS[byte=value])


def _hex_escape(value: Int) -> String:
    if value <= 0xFF:
        return "\\x" + _hex_digit((value >> 4) & 0xF) + _hex_digit(value & 0xF)
    if value <= 0xFFFF:
        var output = String("\\u")
        for shift in range(3, -1, -1):
            output += _hex_digit((value >> (shift * 4)) & 0xF)
        return output^
    var output = String("\\U")
    for shift in range(7, -1, -1):
        output += _hex_digit((value >> (shift * 4)) & 0xF)
    return output^


def _is_display_control(value: Int) -> Bool:
    return (
        value == 0x200B
        or value == 0x200C
        or value == 0x200D
        or value == 0x200E
        or value == 0x200F
        or value == 0x2028
        or value == 0x2029
        or (value >= 0x202A and value <= 0x202E)
        or (value >= 0x2060 and value <= 0x2064)
        or (value >= 0x2066 and value <= 0x206F)
        or value == 0xFEFF
    )


def _escaped_piece(value: Int) -> String:
    if value == 10:
        return "\\n"
    if value == 13:
        return "\\r"
    if value == 9:
        return "\\t"
    if value == 34:
        return '\\"'
    if value == 92:
        return "\\\\"
    if value < 32 or value == 127 or _is_display_control(value):
        return _hex_escape(value)
    return String(chr(value))


struct BoundedWriter(Movable, Writer):
    """Retain complete escaped UTF-8 scalars under a fixed byte cap.

    Args:
        max_bytes: Maximum bytes returned by `finish`, including its complete
            truncation marker.
    """

    var retained: String
    var max_bytes: Int
    var truncated: Bool

    def __init__(out self, max_bytes: Int):
        self.retained = String("")
        self.max_bytes = max_bytes
        self.truncated = False

    def _append_trusted_piece(mut self, piece: String):
        if self.truncated:
            return
        if self.retained.byte_length() + piece.byte_length() <= self.max_bytes:
            self.retained += piece
        else:
            self.truncated = True

    def write_string(mut self, string: StringSlice):
        if self.truncated:
            return
        for codepoint in string.codepoints():
            var piece = _escaped_piece(Int(codepoint))
            if (
                self.retained.byte_length() + piece.byte_length()
                <= self.max_bytes
            ):
                self.retained += piece
            else:
                self.truncated = True
                break

    def write_trusted(mut self, string: String):
        """Append mtest-owned layout or an already escaped projection."""
        if self.truncated:
            return
        for scalar in string.codepoint_slices():
            self._append_trusted_piece(String(scalar))
            if self.truncated:
                return

    def finish(self) -> String:
        """Return retained text with a complete marker when input was omitted.
        """
        if not self.truncated:
            return self.retained.copy()
        var prefix_cap = (
            self.max_bytes - String(TRUNCATION_MARKER).byte_length()
        )
        var prefix = String("")
        for scalar in self.retained.codepoint_slices():
            if prefix.byte_length() + scalar.byte_length() > prefix_cap:
                break
            prefix += String(scalar)
        return prefix + String(TRUNCATION_MARKER)


def render_value[T: Writable](value: T) -> String:
    """Render one opaque value once into a bounded escaped projection."""
    var output = BoundedWriter(VALUE_BYTE_CAP)
    value.write_to(output)
    return output.finish()


def write_opaque_detail[
    T: Writable
](mut output: BoundedWriter, actual: T, expected: T,):
    """Write bounded actual and expected projections for an unequal pair."""
    var actual_text = render_value(actual)
    var expected_text = render_value(expected)
    if actual_text == expected_text:
        output.write_trusted("values compare unequal but render identically")
    else:
        output.write_trusted("values differ")
    output.write_trusted("\n  actual: ")
    output.write_trusted(actual_text)
    output.write_trusted("\n  expected: ")
    output.write_trusted(expected_text)
