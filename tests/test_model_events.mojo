"""Tests for the closed, typed event set and its summary tally.

Every event is one `Event` value tagged by an `EventKind` discriminant, carrying
the payload fields for its variant while the rest stay at defaults. These tests
build one event of each kind through its factory and read the payload back,
proving the console reporter can recover every field it needs purely from the
event — no side channel. The `Summary` tally is checked over the outcome codes.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.model import EventKind, Summary, Event, Outcome


def test_summary_zeros_and_reads() raises:
    var s = Summary.zeros()
    assert_equal(s.total(), 0)
    for o in [Outcome.PASS, Outcome.FAIL, Outcome.EXCLUDED, Outcome.NOT_RUN]:
        assert_equal(s.count_of(o), 0)


def test_summary_counts_include_excluded_and_not_run() raises:
    var s = Summary.zeros()
    s.counts[Outcome.PASS.code] = 4
    s.counts[Outcome.FAIL.code] = 1
    s.counts[Outcome.EXCLUDED.code] = 2
    s.counts[Outcome.NOT_RUN.code] = 3
    assert_equal(s.count_of(Outcome.PASS), 4)
    assert_equal(s.count_of(Outcome.FAIL), 1)
    assert_equal(s.count_of(Outcome.EXCLUDED), 2)
    assert_equal(s.count_of(Outcome.NOT_RUN), 3)
    assert_equal(s.total(), 10)


def test_session_started_payload() raises:
    var e = Event.session_started(
        "tests", "/usr/bin/mojo (1.0.0b2)", selected_count=7, excluded_count=2
    )
    assert_true(e.kind == EventKind.SESSION_STARTED)
    assert_equal(e.root, "tests")
    assert_equal(e.toolchain, "/usr/bin/mojo (1.0.0b2)")
    assert_equal(e.selected_count, 7)
    assert_equal(e.excluded_count, 2)


def test_warning_payload() raises:
    var e = Event.warning("stale-exclusion", "pattern 'old_*' matched nothing")
    assert_true(e.kind == EventKind.WARNING)
    assert_equal(e.warning_kind, "stale-exclusion")
    assert_equal(e.message, "pattern 'old_*' matched nothing")


def test_precompile_failed_payload() raises:
    var e = Event.precompile_failed(
        "precompile src/mtest", "error: boom\n", casualty_count=12
    )
    assert_true(e.kind == EventKind.PRECOMPILE_FAILED)
    assert_equal(e.step, "precompile src/mtest")
    assert_equal(e.compiler_output, "error: boom\n")
    assert_equal(e.casualty_count, 12)


def test_file_started_payload() raises:
    var e = Event.file_started("tests/test_a.mojo")
    assert_true(e.kind == EventKind.FILE_STARTED)
    assert_equal(e.path, "tests/test_a.mojo")


def test_file_finished_payload_carries_render_inputs() raises:
    var e = Event.file_finished(
        "tests/test_a.mojo",
        Outcome.CRASH,
        duration_seconds=0.5,
        build_command="mojo build tests/test_a.mojo",
        build_duration_seconds=1.25,
        captured_stdout="on stdout\n",
        captured_stderr="on stderr\n",
        detail="signal 4 (SIGILL)",
    )
    assert_true(e.kind == EventKind.FILE_FINISHED)
    assert_equal(e.path, "tests/test_a.mojo")
    assert_true(e.outcome == Outcome.CRASH)
    assert_equal(e.duration_seconds, 0.5)
    assert_equal(e.build_command, "mojo build tests/test_a.mojo")
    assert_equal(e.build_duration_seconds, 1.25)
    assert_equal(e.captured_stdout, "on stdout\n")
    assert_equal(e.captured_stderr, "on stderr\n")
    assert_equal(e.detail, "signal 4 (SIGILL)")


def test_session_finished_payload() raises:
    var s = Summary.zeros()
    s.counts[Outcome.PASS.code] = 5
    s.counts[Outcome.FAIL.code] = 1
    s.counts[Outcome.EXCLUDED.code] = 2
    var e = Event.session_finished(s^, wall_time_seconds=3.5, exit_code=1)
    assert_true(e.kind == EventKind.SESSION_FINISHED)
    assert_equal(e.summary.count_of(Outcome.PASS), 5)
    assert_equal(e.summary.count_of(Outcome.EXCLUDED), 2)
    assert_equal(e.wall_time_seconds, 3.5)
    assert_equal(e.exit_code, 1)


def test_event_kinds_are_distinct() raises:
    var kinds = [
        EventKind.SESSION_STARTED,
        EventKind.WARNING,
        EventKind.PRECOMPILE_FAILED,
        EventKind.FILE_STARTED,
        EventKind.FILE_FINISHED,
        EventKind.SESSION_FINISHED,
    ]
    for i in range(len(kinds)):
        for j in range(len(kinds)):
            if i == j:
                assert_true(kinds[i] == kinds[j])
            else:
                assert_false(kinds[i] == kinds[j])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
