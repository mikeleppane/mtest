"""Config/state fixture with no test functions, producing exit 5 alone."""
from std.testing import TestSuite


def _helper() -> Int:
    return 0


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
