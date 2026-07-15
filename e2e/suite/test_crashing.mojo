"""Known-outcome fixture: a test that aborts the process mid-suite.

Verdict CRASH, exit-class 1. Death is by signal, not a nonzero exit: `abort`
raises SIGILL (signal 4), so the runner reports CRASH — a different event from a
FAIL. The abort message is MANDATORY: a bare `abort()` emits no ABORT line and
the crash has nothing to anchor on.
"""
from std.os import abort
from std.testing import assert_equal, TestSuite


def test_before_crash_passes() raises:
    assert_equal(1, 1)


def test_aborts_process() raises:
    abort("simulated hard crash")


def test_after_crash_passes() raises:
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
