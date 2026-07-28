"""Integration tests for the session store and its scaffolding."""
from std.os.path import isdir
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from mtest.platform import read_regular_file_bytes

from cache_fixtures import dir_listing, write_bytes
from tmptree import temp_root


def test_write_bytes_round_trips_invalid_utf8() raises:
    var root = temp_root()
    write_bytes(root, "blob.bin", [UInt8(0), UInt8(255), UInt8(195), UInt8(40)])
    assert_true(isdir(root))
    assert_equal(len(dir_listing(root)), 1)
    assert_equal(dir_listing(root)[0], "blob.bin")


def test_reads_binary_bytes_verbatim() raises:
    var root = temp_root()
    write_bytes(root, "blob.bin", [UInt8(0), UInt8(255), UInt8(195), UInt8(40)])
    var data = read_regular_file_bytes(root + "/blob.bin", 64)
    assert_equal(len(data), 4)
    assert_equal(Int(data[0]), 0)
    assert_equal(Int(data[2]), 195)


def test_rejects_missing_file() raises:
    var root = temp_root()
    with assert_raises(contains="could not open regular file"):
        _ = read_regular_file_bytes(root + "/absent.bin", 64)


def test_rejects_over_cap() raises:
    var root = temp_root()
    write_bytes(root, "blob.bin", [UInt8(1), UInt8(2), UInt8(3), UInt8(4)])
    var exact = read_regular_file_bytes(root + "/blob.bin", 4)
    assert_equal(len(exact), 4)
    with assert_raises(contains="exceeds"):
        _ = read_regular_file_bytes(root + "/blob.bin", 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
