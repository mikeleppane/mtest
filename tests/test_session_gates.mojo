"""Gate ordering and the gate-abort NOT_RUN fan-out.

A failing gate aborts the whole session immediately: every remaining gate and
every run file becomes NOT_RUN and nothing else is scheduled. A passing gate
lets the run files proceed. These tests pin both, asserting the event stream and
the summary tally over a real build+run of tiny fixtures.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.model import EventKind, Outcome
from mtest.report import CompositeReporter, RecordingReporter
from mtest.session import run_session

from session_fixtures import (
    SRC_FAIL,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


def test_failing_gate_aborts_and_fans_out_not_run() raises:
    var root = temp_root()
    write_file(root, "tests/test_gate.mojo", SRC_FAIL)
    write_file(root, "tests/test_run.mojo", SRC_PASS)

    var config = base_config()
    config.gates.append("tests/test_gate.mojo")

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)

    assert_equal(code, 1, "a failing gate resolves to exit 1")
    ref rec = comp.reporters[0]
    # start + gate started/finished + finish = 4; the run file is NEVER started.
    assert_equal(rec.count(), 4)
    assert_true(rec.kind_at(0) == EventKind.SESSION_STARTED)
    assert_true(rec.kind_at(1) == EventKind.FILE_STARTED)
    assert_equal(rec.path_at(1), "tests/test_gate.mojo")
    assert_true(rec.kind_at(2) == EventKind.FILE_FINISHED)
    assert_true(rec.outcome_at(2) == Outcome.FAIL)
    assert_true(rec.kind_at(3) == EventKind.SESSION_FINISHED)

    var last = rec.event_at(3)
    assert_equal(last.summary.count_of(Outcome.FAIL), 1)
    # The run file that never ran is accounted for as NOT_RUN.
    assert_equal(last.summary.count_of(Outcome.NOT_RUN), 1)


def test_passing_gate_lets_run_files_proceed() raises:
    var root = temp_root()
    write_file(root, "tests/test_gate.mojo", SRC_PASS)
    write_file(root, "tests/test_run.mojo", SRC_PASS)

    var config = base_config()
    config.gates.append("tests/test_gate.mojo")

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)

    assert_equal(code, 0, "all pass resolves to exit 0")
    ref rec = comp.reporters[0]
    # start + gate pair + run pair + finish = 6. Gate is scheduled BEFORE the run.
    assert_equal(rec.count(), 6)
    assert_equal(rec.path_at(1), "tests/test_gate.mojo")
    assert_equal(rec.path_at(3), "tests/test_run.mojo")
    var last = rec.event_at(5)
    assert_equal(last.summary.count_of(Outcome.PASS), 2)
    assert_equal(last.summary.count_of(Outcome.NOT_RUN), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
