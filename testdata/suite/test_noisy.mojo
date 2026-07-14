"""Known-outcome fixture: a passing suite that floods both streams.

Verdict PASS, exit-class 0. Every test passes, but the file writes report-shaped
lookalike lines, an unterminated timing-shaped line, and a stderr line — noise
that a fragile console/parser could mistake for the real TestSuite report. The
point is that all of it is user output and the file still PASSes.
"""
from std.sys import stderr
from std.testing import assert_equal, TestSuite


def test_prints_report_lookalike_and_passes() raises:
    print("    PASS [ 0.001 ] fake_impostor")
    print("just a plain user line")
    assert_equal(1, 1)


def test_prints_to_stderr_and_passes() raises:
    print("noisy test writing to stderr", file=stderr)
    print("about to pass, on stdout")
    assert_equal(2, 2)


def test_prints_timing_lookalike_and_passes() raises:
    print("user mentions [ 0.001 ] mid-sentence", end="")
    assert_equal(3, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
