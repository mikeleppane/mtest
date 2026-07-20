"""Focused self-host probe for session verdict fidelity."""
from std.testing import assert_true, TestSuite

from mtest.exec import Termination
from mtest.model import Outcome
from mtest.session import build_verdict, run_verdict


def test_session_keeps_crashes_and_compile_failures_distinct() raises:
    """Run and build signal deaths map to their different outcome classes."""
    assert_true(run_verdict(Termination.signaled(11)) == Outcome.CRASH)
    assert_true(
        build_verdict(Termination.signaled(11)) == Outcome.COMPILE_ERROR
    )


def main() raises:
    """Run this standalone probe through mtest's normal TestSuite protocol."""
    TestSuite.discover_tests[__functions_in_module()]().run()
