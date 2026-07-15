"""Known-outcome fixture: a passing suite one directory down.

Verdict PASS, exit-class 0. Proves the directory walk recurses into
subdirectories rather than scanning only the top level.
"""
from std.testing import assert_equal, TestSuite


def test_nested_passes() raises:
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
