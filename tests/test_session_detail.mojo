"""Pins `_detail_for`'s CRASH branch: the terminating signal is named in words.

A bare `signal 4` on a CRASH line makes the reader go look up what SIGILL
means; the console renders `_detail_for`'s string verbatim, so the words have
to live here. This locks the known-signal shape (`signal 4 — SIGILL, illegal
instruction`) and the unknown-signal fallback (`signal 99`, no dangling
`— `), reached through the same private-helper seam `test_session_mangle.mojo`
uses for `_mangle`.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.exec import Termination
from mtest.model import Outcome
from mtest.session.session import _detail_for


def test_crash_detail_names_a_known_signal_in_words() raises:
    var detail = _detail_for(Outcome.CRASH, Termination.signaled(4), 30)
    assert_true("signal 4" in detail, detail)
    assert_true("SIGILL" in detail, detail)
    assert_true("illegal instruction" in detail, detail)


def test_crash_detail_falls_back_for_an_unknown_signal() raises:
    var detail = _detail_for(Outcome.CRASH, Termination.signaled(99), 30)
    assert_equal(detail, "signal 99")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
