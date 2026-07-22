"""`--maxfail`: the test-granularity early stop, and its `-x` composition.

`config.maxfail` counts FAILING entries in the already test-granular
`run_outcomes` multiset (the same multiset `exit_code_for` consults): a file
with parsed FAIL rows contributes one entry per FAIL row, a file-level abnormal
outcome (CRASH/TIMEOUT/COMPILE_ERROR/MALFORMED_SUITE/…) contributes exactly
one. The check runs BETWEEN files, right where `-x` is checked, so a file can
OVERSHOOT the limit — it always finishes before the count is read. `maxfail=0`
disables the limit (the `--timeout 0` convention).
"""
from std.testing import assert_equal, assert_true

from mtest.model import EventKind, Outcome, SessionFinishedPayload
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_session

from session_fixtures import (
    SRC_COMPILE_ERROR,
    SRC_CRASH,
    SRC_FAIL,
    SRC_FAIL_MULTI,
    SRC_MATRIX_FAIL,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


def test_maxfail_one_stops_after_first_failing_file() raises:
    var root = temp_root()
    write_file(root, "tests/test_a_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_b_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_c_fail.mojo", SRC_FAIL)

    var config = base_config()
    config.maxfail = 1

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 2
    )


def test_maxfail_two_stops_after_second_failing_file() raises:
    var root = temp_root()
    write_file(root, "tests/test_a_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_b_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_c_fail.mojo", SRC_FAIL)

    var config = base_config()
    config.maxfail = 2

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL), 2
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 1
    )


def test_maxfail_three_runs_every_file_when_exactly_reached() raises:
    var root = temp_root()
    write_file(root, "tests/test_a_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_b_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_c_fail.mojo", SRC_FAIL)

    var config = base_config()
    config.maxfail = 3

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL), 3
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 0
    )


def test_maxfail_zero_is_no_limit() raises:
    var root = temp_root()
    write_file(root, "tests/test_a_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_b_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_c_fail.mojo", SRC_FAIL)

    var config = base_config()
    config.maxfail = 0

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL), 3
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 0
    )


def test_maxfail_overshoot_counts_the_whole_file() raises:
    # A single file with THREE failing tests under --maxfail 1: the file runs
    # to completion (its full per-test contribution is 3, not 1) and only THEN
    # trips the stop — the check is between files, never mid-file.
    var root = temp_root()
    write_file(root, "tests/test_a_multi.mojo", SRC_FAIL_MULTI)
    write_file(root, "tests/test_b_pass.mojo", SRC_PASS)

    var config = base_config()
    config.maxfail = 1

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    # The per-test tally proves the overshooting file ran to completion: all
    # three of its FAIL rows were counted, not just the one that tripped the
    # limit.
    assert_equal(last.data[SessionFinishedPayload].test_counts.failed, 3)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 1
    )


def test_maxfail_one_counts_a_file_level_abnormal_as_one() raises:
    # A CRASH has no per-test attribution: it is a single file-level entry in
    # the multiset, so --maxfail 1 stops right after it, same as a single FAIL.
    var root = temp_root()
    write_file(root, "tests/test_a_crash.mojo", SRC_CRASH)
    write_file(root, "tests/test_b_pass.mojo", SRC_PASS)

    var config = base_config()
    config.maxfail = 1

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.CRASH), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 1
    )


def test_maxfail_composes_with_exitfirst_first_trigger_wins() raises:
    # -x trips on the very FIRST failing file regardless of its per-test
    # count; with maxfail set far higher, -x is the trigger that stops
    # scheduling, proving the two compose rather than one starving the other.
    var root = temp_root()
    write_file(root, "tests/test_a_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_b_pass.mojo", SRC_PASS)

    var config = base_config()
    config.exitfirst = True
    config.maxfail = 100

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 1
    )


def test_maxfail_stops_scheduling_in_the_selection_path() raises:
    # `-k bad` makes SELECTION active (the sub-session in `_run_selection`),
    # not the default whole-file path. Both files select their one failing
    # `test_bad`; --maxfail 1 must stop scheduling there too, the same as the
    # default path.
    var root = temp_root()
    write_file(root, "tests/test_a_mf.mojo", SRC_MATRIX_FAIL)
    write_file(root, "tests/test_b_mf.mojo", SRC_MATRIX_FAIL)

    var config = base_config()
    config.keyword = "bad"
    config.maxfail = 1

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 1
    )


def test_maxfail_stops_scheduling_after_a_terminal_file_under_selection() raises:
    # A TERMINAL file under SELECTION (here a compile error, resolved in
    # phase 1 and replayed in phase 2) must honor --maxfail exactly like a
    # runnable file: the phase-2 terminal branch has to stop scheduling before
    # the NEXT file runs, the same as the non-selection loop and the runnable
    # branch both already do. `-k pass` makes selection active without needing
    # the compile-error file to probe at all.
    var root = temp_root()
    write_file(root, "tests/test_a_compile_error.mojo", SRC_COMPILE_ERROR)
    write_file(root, "tests/test_b_pass.mojo", SRC_PASS)

    var config = base_config()
    config.keyword = "pass"
    config.maxfail = 1

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(
            Outcome.COMPILE_ERROR
        ),
        1,
    )
    # test_b_pass must be NOT-RUN, exactly as the non-selection path would
    # have skipped it past --maxfail — not started, not built into a verdict.
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 1
    )
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_STARTED:
            assert_true(
                rec.path_at(i) != "tests/test_b_pass.mojo",
                "test_b_pass.mojo must never be scheduled past --maxfail 1",
            )
