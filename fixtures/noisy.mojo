"""Probe fixture: the parser's adversary.

Carries the normalizer's negative tests. User `print`s stream IMMEDIATELY, while
TestSuite buffers its report and flushes it as one block at the end — so all of
this user noise precedes the report, and a parser that anchors on the FIRST
`Running`/report-looking line instead of the LAST one would be fooled:

- a REPORT-LOOKALIKE line (`    PASS [ 0.001 ] fake_impostor`) that matches the
  per-test report grammar exactly, yet is user output and must survive the
  normalizer byte-exact (timing normalization is anchored to the real report
  block, not to any line that looks like one);
- a TIMING-LOOKALIKE line containing `[ 0.001 ]` outside the report grammar,
  emitted WITHOUT a trailing newline, to pin how unterminated user output frames
  against the report flush;
- a test that writes to STDERR (a Mojo test can: `print(..., file=stderr)`), to
  pin stream interleaving under separate capture;
- a failing test, so the whole thing exercises the failure/flush path.
"""
from std.sys import stderr
from std.testing import assert_equal, TestSuite


def test_prints_and_passes() raises:
    print("    PASS [ 0.001 ] fake_impostor")
    print("just a plain user line")
    assert_equal(1, 1)


def test_prints_then_fails() raises:
    print("noisy test writing to stderr", file=stderr)
    print("about to fail, on stdout")
    assert_equal(1, 2)


def test_prints_timing_lookalike() raises:
    print("user mentions [ 0.001 ] mid-sentence", end="")
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
