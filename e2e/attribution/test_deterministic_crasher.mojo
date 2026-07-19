"""Attribution fixture: ONE specific test always kills the process.

Verdict CRASH, exit-class 1 — exactly as if attribution did not exist. Its role
is the ATTRIBUTED half of the crash-attribution honesty pair: the crash is
unconditional and belongs to `test_boom` alone, so the bounded isolation pass
re-runs the tests in source order (`--only test_alpha_ok` passes, then
`--only test_boom` dies by signal) and names `test_boom` as the culprit.

`abort` raises the target trap — SIGILL (signal 4) on linux-64/x86_64 and
SIGTRAP (signal 5) on osx-arm64 — the same death the e2e/suite crash fixture
uses. The message is MANDATORY, since a bare `abort()` gives the crash nothing
to anchor on. The two passing siblings exist so attribution has something to
EXCLUDE — a single-test file would name its only test without proving anything.

Reached ONLY by the crash-attribution scenario; never in the default suite.
"""
from std.os import abort
from std.testing import assert_true, TestSuite


def test_alpha_ok() raises:
    assert_true(True)


def test_boom() raises:
    abort("attribution fixture: the deterministic culprit")


def test_gamma_ok() raises:
    assert_true(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
