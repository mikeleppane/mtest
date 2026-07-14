"""The outcome of one supervised run (Layer 3).

`ProcessResult` is what `run_supervised` hands back: the raw captured bytes of
each stream (kept SEPARATE and, under the capture bound, byte-exact — trailing
spaces, empty arguments, and invalid UTF-8 all survive), a structured
`Termination`, and the wall duration. The bytes are raw so a byte-exact test can
assert on them; `lossy_utf8` is the helper a later rendering layer uses to turn
those raw bytes into a printable `String` without crashing on invalid sequences.
"""
from mtest.exec.termination import Termination


@fieldwise_init
struct ProcessResult(Copyable, Movable):
    """The captured streams, the termination, and the duration of one run.

    Owns the two capture buffers, so copies are explicit; holds no fds and never
    raises once constructed.
    """

    var stdout_bytes: List[UInt8]
    """The child's raw stdout, bounded per the capture limit; kept separate."""
    var stderr_bytes: List[UInt8]
    """The child's raw stderr, bounded per the capture limit; kept separate."""
    var termination: Termination
    """How the child ended: Exited / Signaled / TimedOut / SpawnFailed."""
    var duration_ms: Int
    """Wall time from fork to reap, in milliseconds."""


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
