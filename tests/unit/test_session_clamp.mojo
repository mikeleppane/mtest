"""Unit tests for the session-side stream clamp (attempt-history memory bound).

`clamp_stream` bounds a captured byte stream to a head window plus a tail window,
flagging whether any bytes were dropped. A non-final retry attempt keeps only a
bounded excerpt of each stream; the final attempt keeps the full capture. The
helper is pure — no processes, no filesystem — and total over its inputs.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.session import ClampedStream, clamp_stream


def _seq(n: Int) -> List[UInt8]:
    """`n` bytes with value `i % 256`, so head/tail slices are identifiable."""
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8(i % 256))
    return out^


def test_under_bound_is_untruncated_and_identical() raises:
    var data = _seq(10)
    var c = clamp_stream(data, 8, 8)
    assert_false(c.truncated)
    assert_equal(len(c.bytes), 10)
    for i in range(10):
        assert_equal(Int(c.bytes[i]), i)


def test_exactly_at_bound_is_untruncated() raises:
    # len == head + tail is the boundary: nothing is dropped.
    var data = _seq(16)
    var c = clamp_stream(data, 8, 8)
    assert_false(c.truncated)
    assert_equal(len(c.bytes), 16)


def test_over_bound_keeps_head_and_tail_and_flags() raises:
    var data = _seq(100)
    var c = clamp_stream(data, 8, 8)
    assert_true(c.truncated)
    assert_equal(len(c.bytes), 16)
    # First 8 bytes are the head (values 0..7).
    for i in range(8):
        assert_equal(Int(c.bytes[i]), i)
    # Last 8 bytes are the tail (values 92..99).
    for i in range(8):
        assert_equal(Int(c.bytes[8 + i]), 92 + i)


def test_empty_is_untruncated() raises:
    var c = clamp_stream(List[UInt8](), 8, 8)
    assert_false(c.truncated)
    assert_equal(len(c.bytes), 0)
