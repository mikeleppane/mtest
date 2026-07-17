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
    AttributionDisposition,
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
    # Shard fields default so existing callers are unaffected (unsharded run).
    assert_equal(e.shard_label, "")
    assert_equal(e.sharded_out_count, 0)


def test_session_started_carries_shard_fields_when_given() raises:
    var e = Event.session_started(
        "tests",
        "mojo 1.0.0b2",
        selected_count=3,
        excluded_count=0,
        shard_label="2/5",
        sharded_out_count=9,
    )
    assert_equal(e.shard_label, "2/5")
    assert_equal(e.sharded_out_count, 9)


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


def test_file_finished_defaults_new_resilience_fields() raises:
    # attempts_used/flaky/slow default so existing callers are unaffected: a
    # file that ran once, was not flaky, and was not slow.
    var e = Event.file_finished(
        "tests/test_a.mojo",
        Outcome.PASS,
        duration_seconds=0.1,
        build_argv=List[String](),
        build_duration_seconds=0.0,
        captured_stdout=List[UInt8](),
        captured_stderr=List[UInt8](),
    )
    assert_equal(e.attempts_used, 1)
    assert_false(e.flaky)
    assert_false(e.slow)


def test_file_finished_carries_resilience_fields_when_given() raises:
    var e = Event.file_finished(
        "tests/test_a.mojo",
        Outcome.FLAKY,
        duration_seconds=0.1,
        build_argv=List[String](),
        build_duration_seconds=0.0,
        captured_stdout=List[UInt8](),
        captured_stderr=List[UInt8](),
        attempts_used=3,
        flaky=True,
        slow=True,
    )
    assert_equal(e.attempts_used, 3)
    assert_true(e.flaky)
    assert_true(e.slow)


def test_file_finished_defaults_escalated_to_false() raises:
    # A file whose run needed no kill at all must never carry an escalation: the
    # default is the honest "we did not have to escalate".
    var e = Event.file_finished(
        "tests/test_a.mojo",
        Outcome.PASS,
        duration_seconds=0.1,
        build_argv=List[String](),
        build_duration_seconds=0.0,
        captured_stdout=List[UInt8](),
        captured_stderr=List[UInt8](),
    )
    assert_false(e.escalated)


def test_file_finished_carries_the_latched_escalation_when_given() raises:
    # The FINAL verdict of a timed-out file needs the same latched escalation the
    # TRY lines already carry, so a run WITHOUT retries can still say whether the
    # child went down on the polite SIGTERM or had to be SIGKILLed.
    var e = Event.file_finished(
        "tests/test_a.mojo",
        Outcome.TIMEOUT,
        duration_seconds=1.3,
        build_argv=List[String](),
        build_duration_seconds=0.0,
        captured_stdout=List[UInt8](),
        captured_stderr=List[UInt8](),
        timeout_seconds=1,
        escalated=True,
    )
    assert_true(e.escalated)


def test_attempt_finished_payload_carries_full_record() raises:
    var argv: List[String] = ["mojo", "run", "tests/test_a.mojo"]
    var e = Event.attempt_finished(
        "tests/test_a.mojo",
        "run",
        attempt_index=1,
        attempts_planned=3,
        term_kind=2,
        term_value=11,
        term_final_kind=2,
        term_final_value=9,
        escalated=True,
        retry_eligible=True,
        classification="signal",
        duration_seconds=0.42,
        captured_stdout=[UInt8(120)],
        captured_stderr=[UInt8(121)],
        stdout_truncated=True,
        stderr_truncated=False,
        attempt_argv=argv^,
    )
    assert_true(e.kind == EventKind.ATTEMPT_FINISHED)
    assert_equal(e.path, "tests/test_a.mojo")
    assert_equal(e.step, "run")
    assert_equal(e.attempt_index, 1)
    assert_equal(e.attempts_planned, 3)
    assert_equal(e.term_kind, 2)
    assert_equal(e.term_value, 11)
    assert_equal(e.term_final_kind, 2)
    assert_equal(e.term_final_value, 9)
    assert_true(e.escalated)
    assert_true(e.retry_eligible)
    assert_equal(e.classification, "signal")
    assert_equal(e.duration_seconds, 0.42)
    assert_equal(len(e.captured_stdout), 1)
    assert_equal(e.captured_stdout[0], UInt8(120))
    assert_equal(e.captured_stderr[0], UInt8(121))
    assert_true(e.stdout_truncated)
    assert_false(e.stderr_truncated)
    assert_true("tests/test_a.mojo" in e.attempt_argv)


def test_crash_attribution_payload() raises:
    var e = Event.crash_attribution(
        "tests/test_a.mojo",
        AttributionDisposition.ATTRIBUTED,
        culprit_test="test_boom",
        isolation_reruns=4,
        attribution_seconds=1.5,
    )
    assert_true(e.kind == EventKind.CRASH_ATTRIBUTION)
    assert_equal(e.path, "tests/test_a.mojo")
    assert_true(e.attribution_disposition == AttributionDisposition.ATTRIBUTED)
    assert_equal(e.culprit_test, "test_boom")
    assert_equal(e.isolation_reruns, 4)
    assert_equal(e.attribution_seconds, 1.5)


def test_attribution_disposition_constants_distinct_and_count() raises:
    var values = [
        AttributionDisposition.ATTRIBUTED,
        AttributionDisposition.NO_REPRODUCTION,
        AttributionDisposition.PROBE_FAILED,
        AttributionDisposition.RUN_CAP,
        AttributionDisposition.TIME_BUDGET,
    ]
    assert_equal(AttributionDisposition.COUNT, 5)
    assert_equal(len(values), AttributionDisposition.COUNT)
    for i in range(len(values)):
        for j in range(len(values)):
            if i == j:
                assert_true(values[i] == values[j])
            else:
                assert_true(values[i] != values[j])
                assert_false(values[i] == values[j])


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
    # flaky_files defaults to zero when the caller does not pass it.
    assert_equal(e.flaky_files, 0)
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


def test_session_finished_carries_flaky_files_when_given() raises:
    var s = Summary.zeros()
    var e = Event.session_finished(
        s^, wall_time_seconds=1.0, exit_code=0, flaky_files=2
    )
    assert_equal(e.flaky_files, 2)


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
        EventKind.ATTEMPT_FINISHED,
        EventKind.CRASH_ATTRIBUTION,
    ]
    for i in range(len(kinds)):
        for j in range(len(kinds)):
            if i == j:
                assert_true(kinds[i] == kinds[j])
            else:
                assert_false(kinds[i] == kinds[j])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
