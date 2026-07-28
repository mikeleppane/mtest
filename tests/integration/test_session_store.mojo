"""Integration tests for the session store and its scaffolding."""
from std.os.path import isdir
from std.testing import TestSuite, assert_equal, assert_true

from cache_fixtures import dir_listing, write_bytes
from tmptree import temp_root


def test_write_bytes_round_trips_invalid_utf8() raises:
    var root = temp_root()
    write_bytes(root, "blob.bin", [UInt8(0), UInt8(255), UInt8(195), UInt8(40)])
    assert_true(isdir(root))
    assert_equal(len(dir_listing(root)), 1)
    assert_equal(dir_listing(root)[0], "blob.bin")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
