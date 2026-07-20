"""Pins the console's CRASH detail: the terminating signal is named in words.

A bare `signal 4` on a CRASH line makes the reader go look up what SIGILL
means; the console now composes the detail string from the event's
`signal_number`, so the words have to live in `report`. This locks the
known-signal shape (`signal 4 — SIGILL, illegal instruction`) and the
unknown-signal fallback (`signal 99`, no dangling `— `), reached through the
shared report-layer signal helper.
"""
from std.testing import assert_equal, assert_true

from mtest.model import Event, Outcome
from mtest.report.console import _outcome_detail
from mtest.report.signals import _signal_name_for_target


def _crash_detail(signo: Int) -> String:
    """The console detail string for a CRASH terminated by `signo`."""
    var e = Event.file_finished(
        "tests/test_x.mojo",
        Outcome.CRASH,
        0.0,
        List[String](),
        0.0,
        List[UInt8](),
        List[UInt8](),
        signal_number=signo,
    )
    return _outcome_detail(e)


def test_signal_name_names_a_known_signal_in_words() raises:
    var name = _signal_name_for_target(4)
    assert_true("SIGILL" in name, name)
    assert_true("illegal instruction" in name, name)


def test_crash_detail_names_a_known_signal_in_words() raises:
    var detail = _crash_detail(4)
    assert_true("signal 4" in detail, detail)
    assert_true("SIGILL" in detail, detail)
    assert_true("illegal instruction" in detail, detail)


def test_crash_detail_falls_back_for_an_unknown_signal() raises:
    var detail = _crash_detail(99)
    assert_equal(detail, "signal 99")
