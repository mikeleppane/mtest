"""Probe fixture: a module with a helper but ZERO `test_` functions.

Pins `Running 0 tests`, exit 0 (the per-file zero-test case; mtest maps a whole
session collecting nothing to exit 5, but a single empty file is not an error).
"""
from std.testing import TestSuite


def _helper_not_a_test() -> Int:
    return 42


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
