"""Known-outcome fixture: a second passing sibling of the hanging file.

Verdict PASS, exit-class 0. Same role as test_slow_pass_a: a file left NOT-RUN
when the interrupt truncates the slow/ walk.
"""
from std.testing import assert_equal, TestSuite


def test_slow_pass_b() raises:
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
