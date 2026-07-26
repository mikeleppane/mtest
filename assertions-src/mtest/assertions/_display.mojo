"""Bounded display primitives for source-only assertion diagnostics."""


comptime VALUE_BYTE_CAP = 1024
comptime BODY_BYTE_CAP = 16384
comptime TEXT_CONTEXT_BYTE_CAP = 4096
comptime DICTIONARY_KEY_BYTE_CAP = 1024
comptime DISPLAY_LIMIT = 8
comptime TRUNCATION_MARKER = "... [truncated]"
comptime REASON_BYTE_BUDGET = 4096

# Unicode 15.0 General_Category Mn and Me ranges, packed as fixed-width
# six-hex-digit inclusive endpoint pairs for allocation-free binary search.
comptime _MARK_RANGES: StaticString = "00030000036f0004830004890005910005bd0005bf0005bf0005c10005c20005c40005c50005c70005c700061000061a00064b00065f0006700006700006d60006dc0006df0006e40006e70006e80006ea0006ed00071100071100073000074a0007a60007b00007eb0007f30007fd0007fd00081600081900081b00082300082500082700082900082d00085900085b00089800089f0008ca0008e10008e300090200093a00093a00093c00093c00094100094800094d00094d0009510009570009620009630009810009810009bc0009bc0009c10009c40009cd0009cd0009e20009e30009fe0009fe000a01000a02000a3c000a3c000a41000a42000a47000a48000a4b000a4d000a51000a51000a70000a71000a75000a75000a81000a82000abc000abc000ac1000ac5000ac7000ac8000acd000acd000ae2000ae3000afa000aff000b01000b01000b3c000b3c000b3f000b3f000b41000b44000b4d000b4d000b55000b56000b62000b63000b82000b82000bc0000bc0000bcd000bcd000c00000c00000c04000c04000c3c000c3c000c3e000c40000c46000c48000c4a000c4d000c55000c56000c62000c63000c81000c81000cbc000cbc000cbf000cbf000cc6000cc6000ccc000ccd000ce2000ce3000d00000d01000d3b000d3c000d41000d44000d4d000d4d000d62000d63000d81000d81000dca000dca000dd2000dd4000dd6000dd6000e31000e31000e34000e3a000e47000e4e000eb1000eb1000eb4000ebc000ec8000ece000f18000f19000f35000f35000f37000f37000f39000f39000f71000f7e000f80000f84000f86000f87000f8d000f97000f99000fbc000fc6000fc600102d00103000103200103700103900103a00103d00103e00105800105900105e00106000107100107400108200108200108500108600108d00108d00109d00109d00135d00135f0017120017140017320017330017520017530017720017730017b40017b50017b70017bd0017c60017c60017c90017d30017dd0017dd00180b00180d00180f00180f0018850018860018a90018a900192000192200192700192800193200193200193900193b001a17001a18001a1b001a1b001a56001a56001a58001a5e001a60001a60001a62001a62001a65001a6c001a73001a7c001a7f001a7f001ab0001ace001b00001b03001b34001b34001b36001b3a001b3c001b3c001b42001b42001b6b001b73001b80001b81001ba2001ba5001ba8001ba9001bab001bad001be6001be6001be8001be9001bed001bed001bef001bf1001c2c001c33001c36001c37001cd0001cd2001cd4001ce0001ce2001ce8001ced001ced001cf4001cf4001cf8001cf9001dc0001dff0020d00020f0002cef002cf1002d7f002d7f002de0002dff00302a00302d00309900309a00a66f00a67200a67400a67d00a69e00a69f00a6f000a6f100a80200a80200a80600a80600a80b00a80b00a82500a82600a82c00a82c00a8c400a8c500a8e000a8f100a8ff00a8ff00a92600a92d00a94700a95100a98000a98200a9b300a9b300a9b600a9b900a9bc00a9bd00a9e500a9e500aa2900aa2e00aa3100aa3200aa3500aa3600aa4300aa4300aa4c00aa4c00aa7c00aa7c00aab000aab000aab200aab400aab700aab800aabe00aabf00aac100aac100aaec00aaed00aaf600aaf600abe500abe500abe800abe800abed00abed00fb1e00fb1e00fe0000fe0f00fe2000fe2f0101fd0101fd0102e00102e001037601037a010a01010a03010a05010a06010a0c010a0f010a38010a3a010a3f010a3f010ae5010ae6010d24010d27010eab010eac010efd010eff010f46010f50010f82010f8501100101100101103801104601107001107001107301107401107f0110810110b30110b60110b90110ba0110c20110c201110001110201112701112b01112d0111340111730111730111800111810111b60111be0111c90111cc0111cf0111cf01122f01123101123401123401123601123701123e01123e0112410112410112df0112df0112e30112ea01130001130101133b01133c01134001134001136601136c01137001137401143801143f01144201144401144601144601145e01145e0114b30114b80114ba0114ba0114bf0114c00114c20114c30115b20115b50115bc0115bd0115bf0115c00115dc0115dd01163301163a01163d01163d01163f0116400116ab0116ab0116ad0116ad0116b00116b50116b70116b701171d01171f01172201172501172701172b01182f01183701183901183a01193b01193c01193e01193e0119430119430119d40119d70119da0119db0119e00119e0011a01011a0a011a33011a38011a3b011a3e011a47011a47011a51011a56011a59011a5b011a8a011a96011a98011a99011c30011c36011c38011c3d011c3f011c3f011c92011ca7011caa011cb0011cb2011cb3011cb5011cb6011d31011d36011d3a011d3a011d3c011d3d011d3f011d45011d47011d47011d90011d91011d95011d95011d97011d97011ef3011ef4011f00011f01011f36011f3a011f40011f40011f42011f42013440013440013447013455016af0016af4016b30016b36016f4f016f4f016f8f016f92016fe4016fe401bc9d01bc9e01cf0001cf2d01cf3001cf4601d16701d16901d17b01d18201d18501d18b01d1aa01d1ad01d24201d24401da0001da3601da3b01da6c01da7501da7501da8401da8401da9b01da9f01daa101daaf01e00001e00601e00801e01801e01b01e02101e02301e02401e02601e02a01e08f01e08f01e13001e13601e2ae01e2ae01e2ec01e2ef01e4ec01e4ef01e8d001e8d601e94401e94a0e01000e01ef"
comptime _MARK_RANGE_COUNT = _MARK_RANGES.byte_length() // 12


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


def _is_non_ascii_separator(value: Int) -> Bool:
    return (
        value == 0xA0
        or value == 0x1680
        or (value >= 0x2000 and value <= 0x200A)
        or value == 0x2028
        or value == 0x2029
        or value == 0x202F
        or value == 0x205F
        or value == 0x3000
    )


def _is_format_control(value: Int) -> Bool:
    return (
        value == 0xAD
        or (value >= 0x600 and value <= 0x605)
        or value == 0x61C
        or value == 0x6DD
        or value == 0x70F
        or value == 0x890
        or value == 0x891
        or value == 0x8E2
        or value == 0x180E
        or value == 0x200B
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
        or (value >= 0xFFF9 and value <= 0xFFFB)
        or value == 0x110BD
        or value == 0x110CD
        or (value >= 0x13430 and value <= 0x1343F)
        or (value >= 0x1BCA0 and value <= 0x1BCA3)
        or (value >= 0x1D173 and value <= 0x1D17A)
        or value == 0xE0001
        or (value >= 0xE0020 and value <= 0xE007F)
    )


def _is_variation_selector(value: Int) -> Bool:
    return (value >= 0xFE00 and value <= 0xFE0F) or (
        value >= 0xE0100 and value <= 0xE01EF
    )


def _packed_hex_value(offset: Int) -> Int:
    var value = 0
    for index in range(offset, offset + 6):
        var digit = Int(ord(_MARK_RANGES[byte=index]))
        if digit >= ord("0") and digit <= ord("9"):
            value = value * 16 + digit - ord("0")
        else:
            value = value * 16 + digit - ord("a") + 10
    return value


def _is_combining_mark(value: Int) -> Bool:
    var low = 0
    var high = _MARK_RANGE_COUNT
    while low < high:
        var middle = low + (high - low) // 2
        var offset = middle * 12
        var start = _packed_hex_value(offset)
        var stop = _packed_hex_value(offset + 6)
        if value < start:
            high = middle
        elif value > stop:
            low = middle + 1
        else:
            return True
    return False


def _is_enclosing_mark(value: Int) -> Bool:
    return (
        (value >= 0x488 and value <= 0x489)
        or value == 0x1ABE
        or (value >= 0x20DD and value <= 0x20E0)
        or (value >= 0x20E2 and value <= 0x20E4)
        or (value >= 0xA670 and value <= 0xA672)
    )


def _is_visually_blank(value: Int) -> Bool:
    return (
        value == 0x115F
        or value == 0x1160
        or value == 0x2800
        or value == 0x3164
        or value == 0xFFA0
    )


def _is_private_use(value: Int) -> Bool:
    return (
        (value >= 0xE000 and value <= 0xF8FF)
        or (value >= 0xF0000 and value <= 0xFFFFD)
        or (value >= 0x100000 and value <= 0x10FFFD)
    )


def _is_unassigned_default_ignorable(value: Int) -> Bool:
    # Unicode 15.0 reserves these Cn ranges as Default_Ignorable_Code_Point.
    return (
        value == 0x2065
        or (value >= 0xFFF0 and value <= 0xFFF8)
        or value == 0xE0000
        or (value >= 0xE0002 and value <= 0xE001F)
        or (value >= 0xE0080 and value <= 0xE00FF)
        or (value >= 0xE01F0 and value <= 0xE0FFF)
    )


def _requires_escape(value: Int) -> Bool:
    return (
        value < 32
        or (value >= 0x7F and value <= 0x9F)
        or _is_non_ascii_separator(value)
        or _is_format_control(value)
        or _is_variation_selector(value)
        or _is_combining_mark(value)
        or _is_visually_blank(value)
        or _is_private_use(value)
        or _is_unassigned_default_ignorable(value)
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
    if _requires_escape(value):
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
    var marker_safe_bytes: Int
    var truncated: Bool

    def __init__(out self, max_bytes: Int):
        """Create an empty writer with a finalized-output byte cap."""
        self.retained = String("")
        self.max_bytes = max_bytes
        self.marker_safe_bytes = 0
        self.truncated = False

    def _append_trusted_piece(mut self, piece: String):
        if self.truncated:
            return
        if self.retained.byte_length() + piece.byte_length() <= self.max_bytes:
            self.retained += piece
            if (
                self.retained.byte_length()
                <= self.max_bytes - String(TRUNCATION_MARKER).byte_length()
            ):
                self.marker_safe_bytes = self.retained.byte_length()
        else:
            self.truncated = True

    def write_string(mut self, string: StringSlice):
        """Append user text with disruptive scalars escaped atomically."""
        if self.truncated:
            return
        for codepoint in string.codepoints():
            var piece = _escaped_piece(Int(codepoint))
            self._append_trusted_piece(piece)
            if self.truncated:
                break

    def write_escaped_scalar(mut self, value: Int):
        """Append one complete escaped scalar or omit it as one unit."""
        self._append_trusted_piece(_escaped_piece(value))

    def write_trusted(mut self, string: String):
        """Append mtest-owned layout or an already escaped projection."""
        self._append_trusted_piece(string)

    def finish(self) -> String:
        """Return retained text with a complete marker when input was omitted.
        """
        if not self.truncated:
            return self.retained.copy()
        var prefix = String("")
        for scalar in self.retained.codepoint_slices():
            if (
                prefix.byte_length() + scalar.byte_length()
                > self.marker_safe_bytes
            ):
                break
            prefix += String(scalar)
        return prefix + String(TRUNCATION_MARKER)


def render_value[T: Writable](value: T) -> String:
    """Render one opaque value once into a bounded escaped projection."""
    var projection = _render_projection(value)
    return projection.text.copy()


def detail_byte_cap(has_reason: Bool) -> Int:
    """Reserve bounded room for a caller reason only on a failing path."""
    if has_reason:
        return BODY_BYTE_CAP - REASON_BYTE_BUDGET
    return BODY_BYTE_CAP


def finish_detail(mismatch: String, reason: String) -> String:
    """Assemble bounded mismatch text while retaining a present caller reason.
    """
    var output = BoundedWriter(BODY_BYTE_CAP)
    output.write_trusted(mismatch)
    if reason:
        output.write_trusted("\n  reason: ")
        output.write(reason)
    return output.finish()


@fieldwise_init
struct _RenderedProjection(Movable):
    """One escaped value projection and whether its byte cap omitted input."""

    var text: String
    var truncated: Bool


def _render_projection[T: Writable](value: T) -> _RenderedProjection:
    """Render once while retaining whether the projection was truncated."""
    var output = BoundedWriter(VALUE_BYTE_CAP)
    value.write_to(output)
    var truncated = output.truncated
    return _RenderedProjection(output.finish(), truncated)


def write_opaque_detail[
    T: Writable
](mut output: BoundedWriter, actual: T, expected: T,):
    """Write bounded actual and expected projections for an unequal pair."""
    var actual_projection = _render_projection(actual)
    var expected_projection = _render_projection(expected)
    if actual_projection.text == expected_projection.text:
        if actual_projection.truncated or expected_projection.truncated:
            output.write_trusted(
                "values differ; projections are identical up to the "
                + String(VALUE_BYTE_CAP)
                + "-byte display cap"
            )
        else:
            output.write_trusted(
                "values compare unequal but render identically"
            )
    else:
        output.write_trusted("values differ")
    output.write_trusted("\n  actual: ")
    output.write_trusted(actual_projection.text)
    output.write_trusted("\n  expected: ")
    output.write_trusted(expected_projection.text)
