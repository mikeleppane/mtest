"""End-to-end verdict honesty: a crash, a compile error, and a timeout stay
distinct through a real build+run.

The pure verdict functions are table-tested elsewhere; this module proves the
session actually RECORDS those distinctions end to end — a process that dies by a
signal is a CRASH (never a FAIL), a source the compiler rejects is a
COMPILE_ERROR (never a run CRASH), and a process that outruns its deadline is a
TIMEOUT (never a FAIL). All three resolve to exit 1.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.config import shell_join
from mtest.model import EventKind, Outcome
from mtest.report import CompositeReporter, RecordingReporter
from mtest.session import run_session

from session_fixtures import (
    SRC_COMPILE_ERROR,
    SRC_CRASH,
    SRC_HANG,
    SRC_PASS,
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
    assert_true(finished.signal_number > 0, String(finished.signal_number))


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
    # The compiler's stderr rides as captured bytes for the compiler banner.
    assert_true(len(finished.captured_stderr) > 0)


def test_compile_error_build_command_is_shell_quoted() raises:
    # A space-bearing build arg must survive into the COMPILE-ERROR
    # reproduce line quoted, or a copy-pasted repro command silently
    # splits into two argv tokens.
    var root = temp_root()
    write_file(root, "tests/test_cerr.mojo", SRC_COMPILE_ERROR)

    var config = base_config()
    config.build_args.append("path with space")

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.reporters[0]
    var finished = rec.event_at(2)
    assert_true(finished.outcome == Outcome.COMPILE_ERROR)
    # The raw space-bearing arg rides in the argv; the reproduce line shell-joins
    # it into a copy-paste-safe (quoted) command.
    assert_true("path with space" in finished.build_argv)
    var joined = shell_join(finished.build_argv)
    assert_true("'path with space'" in joined, joined)


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


def test_spawn_failure_routes_to_exit_3_and_emits_diagnostic() raises:
    # A nonexistent compiler cannot be spawned: the session must resolve exit 3,
    # emit an INTERNAL_ERROR diagnostic naming the build step and the program,
    # and record NO false verdict for the file (it stays NOT-RUN).
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)

    var config = base_config()
    config.mojo_path = "/no/such/mojo/compiler"

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)

    assert_equal(code, 3, "a spawn failure resolves to exit 3")
    ref rec = comp.reporters[0]

    var saw_internal = False
    var saw_verdict = False
    for i in range(rec.count()):
        var e = rec.event_at(i)
        if e.kind == EventKind.INTERNAL_ERROR:
            saw_internal = True
            assert_equal(e.step, "build")
            assert_equal(e.program, "/no/such/mojo/compiler")
        if e.kind == EventKind.FILE_FINISHED:
            saw_verdict = True
    assert_true(saw_internal, "no INTERNAL_ERROR diagnostic was emitted")
    assert_true(not saw_verdict, "a spawn failure must record no verdict")

    var last = rec.event_at(rec.count() - 1)
    assert_true(last.kind == EventKind.SESSION_FINISHED)
    assert_equal(last.exit_code, 3)
    assert_equal(last.summary.count_of(Outcome.NOT_RUN), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
