"""Known-outcome fixture: the `--maxfail` spread, file 2 of 3.

Verdict FAIL, exit-class 1. Sorts second among the maxfail/ siblings, so
`--maxfail 2` stops scheduling right after this file runs, leaving only the
third (passing) sibling NOT-RUN.
"""
from std.testing import assert_equal, TestSuite


def test_one_fails() raises:
    assert_equal(1, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
