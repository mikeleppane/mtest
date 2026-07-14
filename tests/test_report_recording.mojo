"""Tests for the RecordingReporter test double (Layer 2).

The RecordingReporter is a stateful test double: it records the event stream so
session and composition tests can assert ordering, kinds, and key payload
fields. It records; it never prints. These tests fan a fixed event stream
through it and read the recorded kinds, paths, and outcomes back in order.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.model import (
    EventKind,
    Summary,
    Event,
    Outcome,
    NodeId,
    TestResult,
    ParseDisposition,
)
from mtest.report import RecordingReporter


def test_records_nothing_before_any_event() raises:
    var r = RecordingReporter()
    assert_equal(r.count(), 0)


def test_records_kinds_in_order() raises:
    var r = RecordingReporter()
    r.handle(Event.session_started("tests", "mojo 1.0.0b2", 2, 1))
    r.handle(Event.warning("stale-exclusion", "pattern matched nothing"))
    r.handle(Event.file_started("tests/test_a.mojo"))
    r.handle(
        Event.file_finished(
            "tests/test_a.mojo",
            Outcome.PASS,
            0.4,
            ["mojo", "build", "tests/test_a.mojo"],
            1.0,
            List[UInt8](),
            List[UInt8](),
        )
    )
    r.handle(Event.session_finished(Summary.zeros(), 2.0, 0))

    assert_equal(r.count(), 5)
    assert_true(r.kind_at(0) == EventKind.SESSION_STARTED)
    assert_true(r.kind_at(1) == EventKind.WARNING)
    assert_true(r.kind_at(2) == EventKind.FILE_STARTED)
    assert_true(r.kind_at(3) == EventKind.FILE_FINISHED)
    assert_true(r.kind_at(4) == EventKind.SESSION_FINISHED)


def test_records_key_file_fields() raises:
    var r = RecordingReporter()
    var stdout_bytes = List[UInt8]()
    stdout_bytes.append(UInt8(ord("b")))
    stdout_bytes.append(UInt8(ord("o")))
    r.handle(
        Event.file_finished(
            "tests/test_gamma.mojo",
            Outcome.CRASH,
            0.09,
            ["mojo", "build", "tests/test_gamma.mojo"],
            0.5,
            stdout_bytes^,
            List[UInt8](),
            signal_number=4,
        )
    )
    assert_equal(r.count(), 1)
    assert_equal(r.path_at(0), "tests/test_gamma.mojo")
    assert_true(r.outcome_at(0) == Outcome.CRASH)
    # The full event is recoverable for richer assertions.
    var e = r.event_at(0)
    assert_equal(e.signal_number, 4)
    assert_equal(len(e.captured_stdout), 2)
    assert_equal(e.captured_stdout[0], UInt8(ord("b")))


def test_records_warning_and_precompile_payloads() raises:
    var r = RecordingReporter()
    r.handle(Event.warning("stale-exclusion", "old_*"))
    r.handle(
        Event.precompile_failed("precompile src/mtest", "error: boom\n", 7)
    )
    assert_equal(r.event_at(0).warning_pattern, "old_*")
    assert_equal(r.event_at(1).step, "precompile src/mtest")
    assert_equal(r.event_at(1).casualty_count, 7)


def test_records_test_reported_and_collection_known() raises:
    var r = RecordingReporter()
    var n = NodeId("tests/test_a.mojo", "test_foo")
    var tr = TestResult(n.copy(), Outcome.FAIL, "boom", "[ 0.01 ]")
    r.handle(Event.test_reported(tr^))
    r.handle(
        Event.collection_known(selected_test_total=9, deselected_test_total=2)
    )
    assert_equal(r.count(), 2)
    assert_true(r.kind_at(0) == EventKind.TEST_REPORTED)
    assert_true(r.kind_at(1) == EventKind.COLLECTION_KNOWN)
    assert_true(r.test_at(0).node == n)
    assert_true(r.test_at(0).outcome == Outcome.FAIL)
    assert_equal(r.selected_test_total_at(1), 9)
    assert_equal(r.deselected_test_total_at(1), 2)


def test_records_file_finished_parse_disposition() raises:
    var r = RecordingReporter()
    r.handle(
        Event.file_finished(
            "tests/test_a.mojo",
            Outcome.FAIL,
            0.1,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.DRIFT,
        )
    )
    assert_true(r.parse_disposition_at(0) == ParseDisposition.DRIFT)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
