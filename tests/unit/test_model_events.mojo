"""Tests for the closed, typed event set and its summary tally.

Every event is one `Event` value carrying a `Variant` over one payload struct
per kind. These tests build one event of each kind through its factory and read
the payload back through its typed arm, proving the console reporter can recover
every field it needs purely from the event — no side channel — and that the
outer `kind` tag matches the active arm. A field meaningless for the current
kind is not on that kind's payload at all, so it is unrepresentable rather than
a blank default. The `Summary` tally is checked over the outcome codes.
"""
from std.testing import assert_equal, assert_true, assert_false

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
    SessionStartedPayload,
    WarningPayload,
    PrecompileFailedPayload,
    FileStartedPayload,
    FileFinishedPayload,
    SessionFinishedPayload,
    InternalErrorPayload,
    TestReportedPayload,
    CollectionKnownPayload,
    AttemptFinishedPayload,
    CrashAttributionPayload,
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
    ref p = e.data[SessionStartedPayload]
    assert_equal(p.root, "tests")
    assert_equal(p.toolchain, "/usr/bin/mojo (1.0.0b2)")
    assert_equal(p.selected_count, 7)
    assert_equal(p.excluded_count, 2)
    # Shard fields default so existing callers are unaffected (unsharded run).
    assert_equal(p.shard_label, "")
    assert_equal(p.sharded_out_count, 0)


def test_session_started_carries_shard_fields_when_given() raises:
    var e = Event.session_started(
        "tests",
        "mojo 1.0.0b2",
        selected_count=3,
        excluded_count=0,
        shard_label="2/5",
        sharded_out_count=9,
    )
    ref p = e.data[SessionStartedPayload]
    assert_equal(p.shard_label, "2/5")
    assert_equal(p.sharded_out_count, 9)


def test_warning_payload() raises:
    var e = Event.warning("stale-exclusion", "old_*")
    assert_true(e.kind == EventKind.WARNING)
    ref p = e.data[WarningPayload]
    assert_equal(p.warning_kind, "stale-exclusion")
    assert_equal(p.warning_pattern, "old_*")


def test_precompile_failed_payload() raises:
    var e = Event.precompile_failed(
        "precompile src/mtest", "error: boom\n", casualty_count=12
    )
    assert_true(e.kind == EventKind.PRECOMPILE_FAILED)
    ref p = e.data[PrecompileFailedPayload]
    assert_equal(p.step, "precompile src/mtest")
    assert_equal(p.compiler_output, "error: boom\n")
    assert_equal(p.casualty_count, 12)


def test_file_started_payload() raises:
    var e = Event.file_started("tests/test_a.mojo")
    assert_true(e.kind == EventKind.FILE_STARTED)
    assert_equal(e.data[FileStartedPayload].path, "tests/test_a.mojo")


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
    ref p = e.data[FileFinishedPayload]
    assert_equal(p.path, "tests/test_a.mojo")
    assert_true(p.outcome == Outcome.CRASH)
    assert_equal(p.duration_seconds, 0.5)
    assert_true("tests/test_a.mojo" in p.build_argv)
    assert_equal(p.build_duration_seconds, 1.25)
    assert_equal(len(p.captured_stdout), 1)
    assert_equal(p.captured_stdout[0], UInt8(120))
    assert_equal(p.captured_stderr[0], UInt8(121))
    assert_equal(p.signal_number, 4)
    # Test-granularity fields default when the caller does not pass them.
    assert_true(p.parse_disposition == ParseDisposition.NO_REPORT)
    assert_equal(p.passed_tests, 0)
    assert_equal(p.failed_tests, 0)
    assert_equal(p.skipped_tests, 0)
    assert_equal(p.deselected_tests, 0)


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
    ref p = e.data[FileFinishedPayload]
    assert_true(p.parse_disposition == ParseDisposition.PARSED)
    assert_equal(p.passed_tests, 3)
    assert_equal(p.failed_tests, 1)
    assert_equal(p.skipped_tests, 2)
    assert_equal(p.deselected_tests, 4)


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
    ref p = e.data[FileFinishedPayload]
    assert_equal(p.attempts_used, 1)
    assert_false(p.flaky)
    assert_false(p.slow)


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
    ref p = e.data[FileFinishedPayload]
    assert_equal(p.attempts_used, 3)
    assert_true(p.flaky)
    assert_true(p.slow)


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
    assert_false(e.data[FileFinishedPayload].escalated)


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
    assert_true(e.data[FileFinishedPayload].escalated)


def test_file_finished_defaults_truncation_flags_to_false() raises:
    # A file whose captured streams fit under the capture bound must never
    # carry a phantom truncation: the default is the honest "nothing was cut".
    var e = Event.file_finished(
        "tests/test_a.mojo",
        Outcome.PASS,
        duration_seconds=0.1,
        build_argv=List[String](),
        build_duration_seconds=0.0,
        captured_stdout=List[UInt8](),
        captured_stderr=List[UInt8](),
    )
    ref p = e.data[FileFinishedPayload]
    assert_false(p.stdout_truncated)
    assert_false(p.stderr_truncated)


def test_file_finished_carries_truncation_flags_when_given() raises:
    # The session propagates the file-scope process result's own per-stream
    # truncation booleans onto the verdict, independently per stream.
    var e = Event.file_finished(
        "tests/test_a.mojo",
        Outcome.FAIL,
        duration_seconds=0.1,
        build_argv=List[String](),
        build_duration_seconds=0.0,
        captured_stdout=List[UInt8](),
        captured_stderr=List[UInt8](),
        stdout_truncated=True,
        stderr_truncated=False,
    )
    ref p = e.data[FileFinishedPayload]
    assert_true(p.stdout_truncated)
    assert_false(p.stderr_truncated)


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
    ref p = e.data[AttemptFinishedPayload]
    assert_equal(p.path, "tests/test_a.mojo")
    assert_equal(p.step, "run")
    assert_equal(p.attempt_index, 1)
    assert_equal(p.attempts_planned, 3)
    assert_equal(p.term_kind, 2)
    assert_equal(p.term_value, 11)
    assert_equal(p.term_final_kind, 2)
    assert_equal(p.term_final_value, 9)
    assert_true(p.escalated)
    assert_true(p.retry_eligible)
    assert_equal(p.classification, "signal")
    assert_equal(p.duration_seconds, 0.42)
    assert_equal(len(p.captured_stdout), 1)
    assert_equal(p.captured_stdout[0], UInt8(120))
    assert_equal(p.captured_stderr[0], UInt8(121))
    assert_true(p.stdout_truncated)
    assert_false(p.stderr_truncated)
    assert_true("tests/test_a.mojo" in p.attempt_argv)


def test_crash_attribution_payload() raises:
    var e = Event.crash_attribution(
        "tests/test_a.mojo",
        AttributionDisposition.ATTRIBUTED,
        culprit_test="test_boom",
        isolation_reruns=4,
        attribution_seconds=1.5,
    )
    assert_true(e.kind == EventKind.CRASH_ATTRIBUTION)
    ref p = e.data[CrashAttributionPayload]
    assert_equal(p.path, "tests/test_a.mojo")
    assert_true(p.attribution_disposition == AttributionDisposition.ATTRIBUTED)
    assert_equal(p.culprit_test, "test_boom")
    assert_equal(p.isolation_reruns, 4)
    assert_equal(p.attribution_seconds, 1.5)


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
    ref p = e.data[InternalErrorPayload]
    assert_equal(p.step, "build")
    assert_equal(p.program, "/usr/bin/mojo")
    assert_equal(p.errno, 2)


def test_session_finished_payload() raises:
    var s = Summary.zeros()
    s.counts[Outcome.PASS.code] = 5
    s.counts[Outcome.FAIL.code] = 1
    s.counts[Outcome.EXCLUDED.code] = 2
    var e = Event.session_finished(s^, wall_time_seconds=3.5, exit_code=1)
    assert_true(e.kind == EventKind.SESSION_FINISHED)
    ref p = e.data[SessionFinishedPayload]
    assert_equal(p.summary.count_of(Outcome.PASS), 5)
    assert_equal(p.summary.count_of(Outcome.EXCLUDED), 2)
    assert_equal(p.wall_time_seconds, 3.5)
    assert_equal(p.exit_code, 1)
    # flaky_files defaults to zero when the caller does not pass it.
    assert_equal(p.flaky_files, 0)
    # test_counts defaults to zeros when the caller does not pass it.
    assert_equal(p.test_counts.passed, 0)
    assert_equal(p.test_counts.failed, 0)
    assert_equal(p.test_counts.skipped, 0)
    assert_equal(p.test_counts.deselected, 0)


def test_session_finished_carries_test_counts_when_given() raises:
    var s = Summary.zeros()
    var counts = TestCounts(passed=8, failed=2, skipped=1, deselected=3)
    var e = Event.session_finished(
        s^, wall_time_seconds=1.0, exit_code=1, test_counts=counts
    )
    ref p = e.data[SessionFinishedPayload]
    assert_equal(p.test_counts.passed, 8)
    assert_equal(p.test_counts.failed, 2)
    assert_equal(p.test_counts.skipped, 1)
    assert_equal(p.test_counts.deselected, 3)


def test_session_finished_carries_flaky_files_when_given() raises:
    var s = Summary.zeros()
    var e = Event.session_finished(
        s^, wall_time_seconds=1.0, exit_code=0, flaky_files=2
    )
    assert_equal(e.data[SessionFinishedPayload].flaky_files, 2)


def test_test_reported_payload() raises:
    var n = NodeId("tests/test_a.mojo", "test_foo")
    var tr = TestResult(n.copy(), Outcome.FAIL, "boom", "[ 0.01 ]")
    var e = Event.test_reported(tr.copy())
    assert_true(e.kind == EventKind.TEST_REPORTED)
    ref p = e.data[TestReportedPayload]
    assert_true(p.test.node == n)
    assert_true(p.test.outcome == Outcome.FAIL)
    assert_equal(p.test.detail, "boom")
    assert_equal(p.test.timing, "[ 0.01 ]")
    # path accessors keep working: path mirrors the test's node path.
    assert_equal(p.path, "tests/test_a.mojo")
    # No other kind's payload is present: the arm set is closed, so a field
    # meaningless for TEST_REPORTED is unrepresentable rather than a default.
    assert_false(e.data.isa[SessionStartedPayload]())
    assert_false(e.data.isa[CollectionKnownPayload]())


def test_collection_known_payload() raises:
    var e = Event.collection_known(
        selected_test_total=12, deselected_test_total=3
    )
    assert_true(e.kind == EventKind.COLLECTION_KNOWN)
    ref p = e.data[CollectionKnownPayload]
    assert_equal(p.selected_test_total, 12)
    assert_equal(p.deselected_test_total, 3)
    # No file-scope or per-test payload rides along; the arm is closed.
    assert_false(e.data.isa[FileFinishedPayload]())
    assert_false(e.data.isa[TestReportedPayload]())


def test_tag_is_derived_from_the_active_payload_arm() raises:
    # The outer `kind` is never passed in: it is the active payload's own KIND,
    # so a kind and its payload can never disagree, and no stray non-matching
    # payload can ride under a mismatched tag.
    var e = Event.session_started("tests", "mojo 1.0.0b2", 1, 0)
    assert_true(e.kind == EventKind.SESSION_STARTED)
    assert_true(e.kind == SessionStartedPayload.KIND)
    assert_true(e.data.isa[SessionStartedPayload]())
    assert_false(e.data.isa[TestReportedPayload]())


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
