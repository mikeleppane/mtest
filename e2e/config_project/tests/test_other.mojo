"""Config fixture selected by explicit files and CLI path replacement."""
from std.testing import assert_equal, TestSuite


def test_other_passes() raises:
    assert_equal(7, 7)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
