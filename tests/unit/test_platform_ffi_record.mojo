"""`FfiRecord`: the zeroed, word-rounded byte record handed to foreign calls.

Every native ABI record and `struct stat` read goes through `load`/`store`, so
these pin what the offsets mean: zero on construction, a size rounded up to
whole 8-byte words, and typed fields that alias the same little-endian bytes.
An out-of-bounds index aborts the process, which a TestSuite case cannot
observe; the bound itself is pinned by the last in-range field.
"""
from std.testing import assert_equal, TestSuite

from mtest.platform import FfiRecord


def test_a_new_record_is_zero_and_word_rounded() raises:
    var record = FfiRecord(bytes=13)
    assert_equal(record.byte_length(), 16)
    for i in range(16):
        assert_equal(record.load[UInt8](i), 0)


def test_store_then_load_round_trips_each_width() raises:
    var record = FfiRecord(bytes=16)
    record.store[UInt8](15, 0xAB)
    record.store[UInt16](1, 0x1234)
    record.store[UInt32](1, 0xDEADBEEF)
    assert_equal(record.load[UInt8](15), 0xAB)
    assert_equal(record.load[UInt16](1), 0x1234)
    assert_equal(record.load[UInt32](1), 0xDEADBEEF)


def test_typed_fields_alias_the_same_bytes() raises:
    # Index `i` of `T` is byte offset `i * size_of[T]()`: the `struct stat`
    # and native-record offsets in `platform` and `exec` depend on it.
    var record = FfiRecord(bytes=8)
    record.store[UInt32](1, 0x01020304)
    assert_equal(record.load[UInt64](0), 0x0102030400000000)
    assert_equal(record.load[UInt8](4), 0x04)


def test_the_last_whole_field_is_in_bounds() raises:
    var record = FfiRecord(bytes=24)
    record.store[UInt64](2, 7)
    assert_equal(record.load[UInt64](2), 7)
    assert_equal(record.load[UInt32](5), 0)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
