"""The session-side capture clamp for retry attempt history.

`--retries` re-runs a crash-class failure. Each non-final attempt is reported as
an `AttemptFinished` event carrying an excerpt of its captured streams rather
than the full capture; the final attempt owns the full bytes in the file's
`FileFinished`. Retaining every attempt whole would let a flooding crash loop
grow memory in proportion to the retry budget, so a non-final attempt's streams
are clamped to a bounded head window plus a bounded tail window, with a flag
recording whether anything was dropped.

This follows the same head-plus-tail shape as the exec layer's
`BoundedCapture`, but is a simpler clamp over an already-materialized
`List[UInt8]`: no ring buffer, no streaming, no I/O.
"""


@fieldwise_init
struct ClampedStream(Copyable, Movable):
    """A byte stream clamped to a head-plus-tail window, with a dropped flag.

    Owns its buffer; copies are explicit.
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
    `truncated` is False. Otherwise the first `head_max` and the last `tail_max`
    bytes are kept, the middle is dropped, and `truncated` is True. Total over
    every non-negative bound.

    Args:
        data: The captured stream.
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
