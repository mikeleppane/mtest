"""Probe fixture: a mix of passing and failing tests.

Pins the FAIL detail line shape (`At <path>:<line>:<col>: ...`), the failing
exit code, and the misquoted `Test suite' <path> 'failed!` trailer.
"""
from std.testing import assert_equal, TestSuite


def test_first_passes() raises:
    assert_equal(1, 1)


def test_second_fails() raises:
    assert_equal(1, 2)


def test_third_passes() raises:
    assert_equal(3, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
