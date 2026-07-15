"""Probe fixture: two consecutive failing tests.

Pins consecutive FAIL-detail attribution and the multi-failure summary count
(`2 failed`).
"""
from std.testing import assert_equal, TestSuite


def test_first_fails() raises:
    assert_equal(10, 11)


def test_second_fails() raises:
    assert_equal(20, 21)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
