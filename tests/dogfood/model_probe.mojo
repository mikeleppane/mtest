"""Focused self-host probe for the public model vocabulary."""
from std.testing import assert_true, TestSuite

from mtest.model import Outcome


def test_failure_classification_stays_distinct() raises:
    """A crash remains failing without becoming an assertion failure."""
    assert_true(Outcome.CRASH.is_failing())
    assert_true(Outcome.CRASH != Outcome.FAIL)


def main() raises:
    """Run this standalone probe through mtest's normal TestSuite protocol."""
    TestSuite.discover_tests[__functions_in_module()]().run()
