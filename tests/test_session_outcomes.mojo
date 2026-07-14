"""End-to-end verdict honesty: a crash, a compile error, and a timeout stay
distinct through a real build+run.

The pure verdict functions are table-tested elsewhere; this module proves the
session actually RECORDS those distinctions end to end — a process that dies by a
signal is a CRASH (never a FAIL), a source the compiler rejects is a
COMPILE_ERROR (never a run CRASH), and a process that outruns its deadline is a
TIMEOUT (never a FAIL). All three resolve to exit 1.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.model import EventKind, Outcome
from mtest.report import CompositeReporter, RecordingReporter
from mtest.session import run_session

from session_fixtures import (
    SRC_COMPILE_ERROR,
    SRC_CRASH,
    SRC_HANG,
    base_config,
    temp_root,
    write_file,
)


def test_signal_death_is_crash_not_fail() raises:
    var root = temp_root()
    write_file(root, "tests/test_crash.mojo", SRC_CRASH)

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(base_config(), root, comp)

    assert_equal(code, 1)
    ref rec = comp.reporters[0]
    var finished = rec.event_at(2)
    assert_true(finished.kind == EventKind.FILE_FINISHED)
    assert_true(finished.outcome == Outcome.CRASH, "signal death must be CRASH")
    assert_true("signal" in finished.detail, finished.detail)


def test_compiler_rejection_is_compile_error_not_crash() raises:
    var root = temp_root()
    write_file(root, "tests/test_cerr.mojo", SRC_COMPILE_ERROR)

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(base_config(), root, comp)

    assert_equal(code, 1)
    ref rec = comp.reporters[0]
    var finished = rec.event_at(2)
    assert_true(
        finished.outcome == Outcome.COMPILE_ERROR,
        "a rejected build is COMPILE_ERROR, never a run CRASH",
    )
    # The compiler's stderr rides on detail for the reproduce section.
    assert_true(finished.detail.byte_length() > 0)


def test_deadline_overrun_is_timeout_not_fail() raises:
    var root = temp_root()
    write_file(root, "tests/test_hang.mojo", SRC_HANG)

    var config = base_config()
    config.timeout_secs = 1  # keep the deadline short for the test

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.reporters[0]
    var finished = rec.event_at(2)
    assert_true(
        finished.outcome == Outcome.TIMEOUT, "a deadline overrun is TIMEOUT"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
