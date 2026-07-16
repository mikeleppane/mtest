"""Known-outcome collect fixture: a clean two-test suite.

Under `--skip-all` (the collect probe) it lists its two tests and runs no body,
so `mtest collect` emits its two node ids. Reached only by the collect scenario;
a whole run of it PASSes.
"""
from std.testing import TestSuite, assert_true


def test_one() raises:
    assert_true(True)


def test_two() raises:
    assert_true(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
