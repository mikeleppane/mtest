"""Config/state fixture whose one test flips from FAIL to PASS by marker."""
from std.os.path import exists
from std.testing import assert_true, TestSuite


def test_marker_controls_outcome() raises:
    assert_true(exists("state-pass-marker"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
