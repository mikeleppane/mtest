"""Known-outcome fixture: the `--maxfail` spread, file 1 of 3.

Verdict FAIL, exit-class 1. Sorts first among the maxfail/ siblings, so
`--maxfail 1` stops scheduling right after this file runs.
"""
from std.testing import assert_equal, TestSuite


def test_one_fails() raises:
    assert_equal(1, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
