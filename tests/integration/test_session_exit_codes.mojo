"""Exact exit codes and the -x (exitfirst) NOT_RUN fan-out.

Pins the three codes the model's pure function decides as the session resolves
them end to end: 0 (all ran and passed), 5 (nothing was runnable), and 1 via a
failing file. Also pins -x: after the first failing file the session stops
scheduling and every remaining run file becomes NOT_RUN.
"""
from std.testing import assert_equal, assert_true

from mtest.model import (
    EventKind,
    Outcome,
    SessionStartedPayload,
    SessionFinishedPayload,
)
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_session

from session_fixtures import (
    SRC_FAIL,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


def test_all_pass_is_exit_0() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(base_config(), root, comp)

    assert_equal(code, 0)
    var last = comp.composite.reporters[0].event_at(
        comp.composite.reporters[0].count() - 1
    )
    assert_equal(last.data[SessionFinishedPayload].exit_code, 0)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.PASS), 2
    )


def test_nothing_runnable_is_exit_5() raises:
    # An empty root: the walk yields no files, so nothing is runnable.
    var root = temp_root()

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(base_config(), root, comp)

    assert_equal(code, 5, "nothing runnable resolves to exit 5")
    ref rec = comp.composite.reporters[0]
    # Only the session frame: start + finish.
    assert_equal(rec.count(), 2)
    assert_true(rec.kind_at(0) == EventKind.SESSION_STARTED)
    assert_equal(rec.event_at(0).data[SessionStartedPayload].selected_count, 0)
    assert_true(rec.kind_at(1) == EventKind.SESSION_FINISHED)
    assert_equal(rec.event_at(1).data[SessionFinishedPayload].exit_code, 5)


def test_exitfirst_stops_and_fans_out_not_run() raises:
    var root = temp_root()
    write_file(root, "tests/test_a_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_b_pass.mojo", SRC_PASS)

    var config = base_config()
    config.exitfirst = True

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    # start + first-file triple (started, test_reported, finished) + finish = 5;
    # the second file is never started.
    assert_equal(rec.count(), 5)
    assert_true(rec.kind_at(3) == EventKind.FILE_FINISHED)
    assert_true(rec.outcome_at(3) == Outcome.FAIL)
    assert_equal(rec.path_at(3), "tests/test_a_fail.mojo")
    var last = rec.event_at(4)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 1
    )


def test_spawn_failure_is_exit_3() raises:
    # A bogus compiler path cannot be exec'd: the supervisor reports a
    # SpawnFailed termination, which is an INTERNAL error (exit 3), never a
    # test outcome and never a COMPILE_ERROR.
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)

    var config = base_config()
    config.mojo_path = "mtest_no_such_compiler_xyz"

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 3, "a spawn failure is the internal-error exit 3")
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_true(last.kind == EventKind.SESSION_FINISHED)
    assert_equal(last.data[SessionFinishedPayload].exit_code, 3)
    # No verdict was recorded; the file is accounted for as NOT_RUN.
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(
            Outcome.COMPILE_ERROR
        ),
        0,
    )
