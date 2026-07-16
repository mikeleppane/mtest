"""Known-outcome fixture: a passing sibling of the hanging file.

Verdict PASS, exit-class 0. Sorts after test_hanging.mojo, so in the interrupt
scenario (which walks slow/) it stays unscheduled behind the hang and shows up
in the partial summary's NOT-RUN accounting.
"""
from std.testing import assert_equal, TestSuite


def test_slow_pass_a() raises:
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
