"""Probe fixture: a test that aborts the process mid-suite.

Pins the crash path: the buffered report is LOST (no PASS lines, no Summary),
an `ABORT:` line is emitted, and the process dies by SIGNAL rather than exiting.
The abort message is MANDATORY — a bare `abort()` emits no `ABORT:` line, so the
structural pin would have nothing to anchor on.
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
