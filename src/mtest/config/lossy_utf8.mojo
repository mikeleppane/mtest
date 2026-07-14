"""The shared byte->text codec behind every rendered stream (Layer 1).

`lossy_utf8` is the SINGLE decoder the runner uses to turn raw captured bytes
into a printable `String`: `exec` (Layer 3) decodes a failed precompile step's
stderr for the precompile banner, and `report` (Layer 2) decodes every captured
stdout/stderr and the compile-error compiler banner. It lives here, below both,
so each layer shares this ONE decoding rule rather than duplicating it. Pure: no
I/O, no environment reads.
"""


def lossy_utf8(bytes: List[UInt8]) -> String:
    """Render raw captured bytes as text, replacing invalid UTF-8 visibly.

    Walks the bytes as UTF-8; a valid sequence is copied through unchanged, and
    any byte that cannot begin or continue a valid sequence is replaced with the
    Unicode replacement character (U+FFFD) so the result is always printable and
    never crashes on binary or invalid input.

    Args:
        bytes: The raw captured bytes to render. Not mutated.

    Returns:
        A `String` with every valid sequence preserved and every invalid byte
        replaced by U+FFFD. Allocates the result; does not raise.
    """
    comptime REPLACEMENT = "�"
    var out = String("")
    var n = len(bytes)
    var i = 0
    while i < n:
        var b = Int(bytes[i])
        var seq_len: Int
        var lo: Int
        var hi: Int
        if b < 0x80:
            # ASCII fast path.
            out += chr(b)
            i += 1
            continue
        elif b >= 0xC2 and b <= 0xDF:
            seq_len = 2
            lo = 0x80
            hi = 0xBF
        elif b >= 0xE0 and b <= 0xEF:
            seq_len = 3
            # Tighten the first continuation byte to reject overlong / surrogate.
            if b == 0xE0:
                lo = 0xA0
                hi = 0xBF
            elif b == 0xED:
                lo = 0x80
                hi = 0x9F
            else:
                lo = 0x80
                hi = 0xBF
        elif b >= 0xF0 and b <= 0xF4:
            seq_len = 4
            if b == 0xF0:
                lo = 0x90
                hi = 0xBF
            elif b == 0xF4:
                lo = 0x80
                hi = 0x8F
            else:
                lo = 0x80
                hi = 0xBF
        else:
            # 0x80..0xC1 and 0xF5..0xFF can never begin a sequence.
            out += REPLACEMENT
            i += 1
            continue

        # Validate the continuation bytes; the first has a tightened range.
        var ok = i + seq_len <= n
        if ok:
            var c1 = Int(bytes[i + 1])
            if c1 < lo or c1 > hi:
                ok = False
            else:
                for k in range(2, seq_len):
                    var ck = Int(bytes[i + k])
                    if ck < 0x80 or ck > 0xBF:
                        ok = False
                        break
        if not ok:
            out += REPLACEMENT
            i += 1
            continue

        # A valid sequence: copy its exact bytes through.
        var slice = List[UInt8]()
        for k in range(seq_len):
            slice.append(bytes[i + k])
        out += String(StringSlice(unsafe_from_utf8=Span(slice)))
        i += seq_len
    return out^
