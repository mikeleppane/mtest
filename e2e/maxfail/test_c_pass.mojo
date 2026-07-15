"""Known-outcome fixture: the `--maxfail` spread, file 3 of 3.

Verdict PASS, exit-class 0. Sorts last among the maxfail/ siblings; under
`--maxfail 1` or `--maxfail 2` it stays NOT-RUN. Under `--maxfail 0` (no
limit) or `--maxfail 3` it runs and passes.
"""
from std.testing import assert_equal, TestSuite


def test_passes() raises:
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
