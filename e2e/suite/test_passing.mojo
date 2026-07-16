"""Known-outcome fixture: an all-passing suite.

Verdict PASS, exit-class 0. The baseline: three passing tests, whole file
exits 0. Used both as a member of the default suite/ walk and standalone as the
single-file exit-0 case.
"""
from std.testing import assert_equal, TestSuite


def test_one_passes() raises:
    assert_equal(1, 1)


def test_two_passes() raises:
    assert_equal(2, 2)


def test_three_passes() raises:
    assert_equal(3, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
