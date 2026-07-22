"""The shared byte-to-text codec behind every rendered stream.

`lossy_utf8` is the runner's only decoder for turning raw captured bytes into a
printable `String`. `session` is the heaviest caller: it decodes every child's
captured stdout and stderr before parsing or classifying, including a failed
precompile step's stderr and a compile error's compiler banner. `report`
decodes again for whatever it renders into console, JSON, or JUnit output. It
lives below both so they share one decoding rule rather than duplicating it. No
I/O, no environment reads.

This is a pure cross-cutting text utility, not a configuration concern: it
reads no `RunnerConfig` and imports nothing internal, so its natural home is
Layer 0 alongside the other dependency-free primitives. It is parked in
`config` purely for graph position — a low-enough layer that both `report` and
`session` can reach it without an upward import — and it stays here because the
decoder has importers spread across the `config`, `report`, and `session`
packages, so relocating it would churn every one of them for no behavioral gain.
"""


def lossy_utf8(bytes: List[UInt8]) -> String:
    """Render raw captured bytes as text, replacing invalid UTF-8 visibly.

    Walks the bytes as UTF-8, copying each valid sequence through unchanged.
    Any byte that cannot begin or continue a valid sequence becomes the Unicode
    replacement character (U+FFFD), so the result is always printable even for
    binary or malformed input. Overlong encodings, surrogates, and values above
    U+10FFFF are rejected per RFC 3629 and replaced the same way.

    Args:
        bytes: The raw captured bytes to render.

    Returns:
        A `String` with every valid sequence preserved and every invalid byte
        replaced by U+FFFD.
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
        # SAFETY: the branch-specific leading-byte bounds plus the tightened
        # first continuation and every remaining 0x80..0xBF continuation prove
        # this 2..4-byte slice is one RFC 3629 scalar (no overlong, surrogate, or
        # >U+10FFFF value). `slice` remains live until String copies the Span.
        out += String(StringSlice(unsafe_from_utf8=Span(slice)))
        i += seq_len
    return out^
