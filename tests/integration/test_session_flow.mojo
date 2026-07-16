"""The happy-path event stream of the session, driven through a real build+run.

Builds a tiny temp tree of known-outcome fixtures and runs the session against
it through a CompositeReporter of TWO recorders (the N=2 seam), then asserts the
whole event stream: ordering (SessionStarted -> excluded -> warning -> file
pairs -> SessionFinished), the selected/excluded counts, the per-file verdicts
(a real PASS and a real FAIL, kept distinct), the summary tally, and the exact
resolved exit code. Both recorders must observe the identical stream.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.model import EventKind, Outcome, ParseDisposition
from mtest.report import CompositeReporter, RecordingReporter
from mtest.session import run_session

from session_fixtures import (
    SRC_FAIL,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


def test_flow_pass_fail_excluded_warning_exit1() raises:
    var root = temp_root()
    write_file(root, "tests/test_a_pass.mojo", SRC_PASS)
    write_file(root, "tests/test_b_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_skipme.mojo", SRC_PASS)

    var config = base_config()
    config.excludes.append("*skipme*")
    config.excludes.append("ghost_*")  # matches nothing -> stale warning

    var comp = CompositeReporter(
        Tuple(RecordingReporter(), RecordingReporter())
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1, "a FAIL must resolve to exit 1")

    ref rec = comp.reporters[0]
    # Full ordered stream: 1 start + 1 excluded + 1 warning + 2 file triples
    # (started, one retrospective test_reported, finished) + 1 finish = 10.
    assert_equal(rec.count(), 10)

    assert_true(rec.kind_at(0) == EventKind.SESSION_STARTED)
    assert_equal(rec.event_at(0).selected_count, 2)
    assert_equal(rec.event_at(0).excluded_count, 1)

    assert_true(rec.kind_at(1) == EventKind.FILE_FINISHED)
    assert_true(rec.outcome_at(1) == Outcome.EXCLUDED)
    assert_equal(rec.path_at(1), "tests/test_skipme.mojo")
    assert_equal(rec.event_at(1).exclusion_pattern, "*skipme*")

    assert_true(rec.kind_at(2) == EventKind.WARNING)
    assert_equal(rec.event_at(2).warning_kind, "stale-exclusion")

    # Run files, sorted: test_a_pass then test_b_fail. Each emits its per-test
    # TestReported row BETWEEN its file_started and file_finished.
    assert_true(rec.kind_at(3) == EventKind.FILE_STARTED)
    assert_equal(rec.path_at(3), "tests/test_a_pass.mojo")
    assert_true(rec.kind_at(4) == EventKind.TEST_REPORTED)
    assert_true(rec.test_at(4).outcome == Outcome.PASS)
    assert_equal(rec.test_at(4).node.path, "tests/test_a_pass.mojo")
    assert_true(rec.kind_at(5) == EventKind.FILE_FINISHED)
    assert_true(rec.outcome_at(5) == Outcome.PASS)
    assert_equal(rec.path_at(5), "tests/test_a_pass.mojo")
    # The verdict now rests on the PARSED report, not the exit status alone.
    assert_true(rec.parse_disposition_at(5) == ParseDisposition.PARSED)
    assert_equal(rec.event_at(5).passed_tests, 1)

    assert_true(rec.kind_at(6) == EventKind.FILE_STARTED)
    assert_equal(rec.path_at(6), "tests/test_b_fail.mojo")
    assert_true(rec.kind_at(7) == EventKind.TEST_REPORTED)
    assert_true(rec.test_at(7).outcome == Outcome.FAIL)
    assert_true(rec.kind_at(8) == EventKind.FILE_FINISHED)
    assert_true(rec.outcome_at(8) == Outcome.FAIL)
    assert_equal(rec.event_at(8).exit_status, 1)
    assert_equal(rec.event_at(8).failed_tests, 1)

    var last = rec.event_at(9)
    assert_true(last.kind == EventKind.SESSION_FINISHED)
    assert_equal(last.exit_code, 1)
    assert_equal(last.summary.count_of(Outcome.PASS), 1)
    assert_equal(last.summary.count_of(Outcome.FAIL), 1)
    assert_equal(last.summary.count_of(Outcome.EXCLUDED), 1)
    assert_equal(last.summary.count_of(Outcome.NOT_RUN), 0)
    # The authoritative per-test totals ride on SessionFinished.
    assert_equal(last.test_counts.passed, 1)
    assert_equal(last.test_counts.failed, 1)

    # The build command is faithful (the reproduce line), carried as argv.
    var argv = rec.event_at(5).build_argv.copy()
    assert_true("build" in argv)
    assert_true("tests/test_a_pass.mojo" in argv)

    # The N=2 seam: the second recorder observed the identical stream.
    assert_equal(comp.reporters[1].count(), 10)
    assert_true(comp.reporters[1].kind_at(9) == EventKind.SESSION_FINISHED)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
