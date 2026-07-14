"""Known-outcome fixture: a passing suite meant to be excluded.

Verdict PASS, exit-class 0 when actually run. Its purpose is to be the target of
`--exclude`: when a pattern covers it the runner reports a loud EXCLUDED line and
does not build it. Living in its own directory keeps it out of the default walk.
"""
from std.testing import assert_equal, TestSuite


def test_excluded_would_pass() raises:
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
