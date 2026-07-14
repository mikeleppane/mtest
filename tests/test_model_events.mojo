"""Tests for the closed, typed event set and its summary tally.

Every event is one `Event` value tagged by an `EventKind` discriminant, carrying
the payload fields for its variant while the rest stay at defaults. These tests
build one event of each kind through its factory and read the payload back,
proving the console reporter can recover every field it needs purely from the
event — no side channel. The `Summary` tally is checked over the outcome codes.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.model import (
    EventKind,
    Summary,
    Event,
    Outcome,
    NodeId,
    TestResult,
    ParseDisposition,
    TestCounts,
)


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
    var e = Event.warning("stale-exclusion", "old_*")
    assert_true(e.kind == EventKind.WARNING)
    assert_equal(e.warning_kind, "stale-exclusion")
    assert_equal(e.warning_pattern, "old_*")


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
    var argv: List[String] = ["mojo", "build", "tests/test_a.mojo"]
    var e = Event.file_finished(
        "tests/test_a.mojo",
        Outcome.CRASH,
        duration_seconds=0.5,
        build_argv=argv^,
        build_duration_seconds=1.25,
        captured_stdout=[UInt8(120)],
        captured_stderr=[UInt8(121)],
        signal_number=4,
    )
    assert_true(e.kind == EventKind.FILE_FINISHED)
    assert_equal(e.path, "tests/test_a.mojo")
    assert_true(e.outcome == Outcome.CRASH)
    assert_equal(e.duration_seconds, 0.5)
    assert_true("tests/test_a.mojo" in e.build_argv)
    assert_equal(e.build_duration_seconds, 1.25)
    assert_equal(len(e.captured_stdout), 1)
    assert_equal(e.captured_stdout[0], UInt8(120))
    assert_equal(e.captured_stderr[0], UInt8(121))
    assert_equal(e.signal_number, 4)
    # Test-granularity fields default when the caller does not pass them.
    assert_true(e.parse_disposition == ParseDisposition.NO_REPORT)
    assert_equal(e.passed_tests, 0)
    assert_equal(e.failed_tests, 0)
    assert_equal(e.skipped_tests, 0)
    assert_equal(e.deselected_tests, 0)


def test_file_finished_carries_test_granularity_fields_when_given() raises:
    var e = Event.file_finished(
        "tests/test_a.mojo",
        Outcome.FAIL,
        duration_seconds=0.5,
        build_argv=List[String](),
        build_duration_seconds=0.0,
        captured_stdout=List[UInt8](),
        captured_stderr=List[UInt8](),
        parse_disposition=ParseDisposition.PARSED,
        passed_tests=3,
        failed_tests=1,
        skipped_tests=2,
        deselected_tests=4,
    )
    assert_true(e.parse_disposition == ParseDisposition.PARSED)
    assert_equal(e.passed_tests, 3)
    assert_equal(e.failed_tests, 1)
    assert_equal(e.skipped_tests, 2)
    assert_equal(e.deselected_tests, 4)


def test_internal_error_payload() raises:
    var e = Event.internal_error("build", "/usr/bin/mojo", 2)
    assert_true(e.kind == EventKind.INTERNAL_ERROR)
    assert_equal(e.step, "build")
    assert_equal(e.program, "/usr/bin/mojo")
    assert_equal(e.errno, 2)


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
    # test_counts defaults to zeros when the caller does not pass it.
    assert_equal(e.test_counts.passed, 0)
    assert_equal(e.test_counts.failed, 0)
    assert_equal(e.test_counts.skipped, 0)
    assert_equal(e.test_counts.deselected, 0)


def test_session_finished_carries_test_counts_when_given() raises:
    var s = Summary.zeros()
    var counts = TestCounts(passed=8, failed=2, skipped=1, deselected=3)
    var e = Event.session_finished(
        s^, wall_time_seconds=1.0, exit_code=1, test_counts=counts
    )
    assert_equal(e.test_counts.passed, 8)
    assert_equal(e.test_counts.failed, 2)
    assert_equal(e.test_counts.skipped, 1)
    assert_equal(e.test_counts.deselected, 3)


def test_test_reported_payload() raises:
    var n = NodeId("tests/test_a.mojo", "test_foo")
    var tr = TestResult(n.copy(), Outcome.FAIL, "boom", "[ 0.01 ]")
    var e = Event.test_reported(tr.copy())
    assert_true(e.kind == EventKind.TEST_REPORTED)
    assert_true(e.test.node == n)
    assert_true(e.test.outcome == Outcome.FAIL)
    assert_equal(e.test.detail, "boom")
    assert_equal(e.test.timing, "[ 0.01 ]")
    # path_at accessors keep working: path mirrors the test's node path.
    assert_equal(e.path, "tests/test_a.mojo")
    # Every other payload field stays at its blank default.
    assert_equal(e.root, "")
    assert_equal(e.selected_count, 0)
    assert_equal(e.selected_test_total, 0)
    assert_equal(e.deselected_test_total, 0)


def test_collection_known_payload() raises:
    var e = Event.collection_known(
        selected_test_total=12, deselected_test_total=3
    )
    assert_true(e.kind == EventKind.COLLECTION_KNOWN)
    assert_equal(e.selected_test_total, 12)
    assert_equal(e.deselected_test_total, 3)
    # Every other payload field stays at its blank default.
    assert_equal(e.path, "")
    assert_true(e.test.node == NodeId("", ""))


def test_blank_defaults_test_field_to_not_run() raises:
    # _blank must default `test` so a stray non-TEST_REPORTED event never
    # carries a garbage TestResult.
    var e = Event.session_started("tests", "mojo 1.0.0b2", 1, 0)
    assert_true(e.test.node == NodeId("", ""))
    assert_true(e.test.outcome == Outcome.NOT_RUN)
    assert_equal(e.test.detail, "")
    assert_equal(e.test.timing, "")


def test_event_kinds_are_distinct() raises:
    var kinds = [
        EventKind.SESSION_STARTED,
        EventKind.WARNING,
        EventKind.PRECOMPILE_FAILED,
        EventKind.FILE_STARTED,
        EventKind.FILE_FINISHED,
        EventKind.SESSION_FINISHED,
        EventKind.INTERNAL_ERROR,
        EventKind.TEST_REPORTED,
        EventKind.COLLECTION_KNOWN,
    ]
    for i in range(len(kinds)):
        for j in range(len(kinds)):
            if i == j:
                assert_true(kinds[i] == kinds[j])
            else:
                assert_false(kinds[i] == kinds[j])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
