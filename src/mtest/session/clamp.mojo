"""The session-side capture clamp for retry attempt history (Layer 4).

`--retries` re-runs a crash-class failure. Each NON-final attempt is reported as
an `AttemptFinished` event carrying an EXCERPT of its captured streams, not the
full capture — the final attempt owns the full bytes in the file's
`FileFinished`. Keeping the whole capture of every attempt would let a flooding
crash loop blow up memory in proportion to the retry budget, so a non-final
attempt's streams are clamped to a bounded head window plus a bounded tail
window, with a flag recording whether anything was dropped.

This mirrors the SPIRIT of the exec layer's `BoundedCapture` (head + tail with a
truncation marker) but is a much simpler, pure, session-side clamp over an
already-materialized `List[UInt8]`: no ring buffer, no streaming, no I/O. It is
total and never raises.
"""


@fieldwise_init
struct ClampedStream(Copyable, Movable):
    """A byte stream clamped to a head+tail window, plus a truncation flag.

    `bytes` is the retained excerpt (the whole stream when nothing was dropped,
    else the head window followed immediately by the tail window). `truncated`
    is True iff at least one middle byte was dropped. Owns its buffer; copies
    are explicit.
    """

    var bytes: List[UInt8]
    """The retained bytes: the whole stream, or head window then tail window."""
    var truncated: Bool
    """Whether any middle bytes were dropped to fit the head+tail bound."""


def clamp_stream(
    data: List[UInt8], head_max: Int, tail_max: Int
) -> ClampedStream:
    """Clamp `data` to at most `head_max` head bytes plus `tail_max` tail bytes.

    When `len(data) <= head_max + tail_max` the whole stream is retained and
    `truncated` is False. Otherwise the first `head_max` bytes and the last
    `tail_max` bytes are kept (the middle dropped) and `truncated` is True. Pure;
    total over every non-negative bound; never raises.

    Args:
        data: The captured stream. Not mutated.
        head_max: How many leading bytes to always keep.
        tail_max: How many trailing bytes to always keep.

    Returns:
        The clamped excerpt and its truncation flag.
    """
    var n = len(data)
    if n <= head_max + tail_max:
        return ClampedStream(data.copy(), False)
    var out = List[UInt8]()
    for i in range(head_max):
        out.append(data[i])
    for i in range(n - tail_max, n):
        out.append(data[i])
    return ClampedStream(out^, True)
