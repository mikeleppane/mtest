"""Table tests for the PURE verdict-mapping functions (Layer 4).

The whole product's honesty is that a crash is never a failure, our deadline
kill is never a crash, a spawn failure is never a test outcome, and a compiler
that dies by a signal is a BUILD failure, never a test crash. These tests pin
`run_verdict` and `build_verdict` over EVERY `Termination` kind so that honesty
can never silently blur.
"""
from std.testing import assert_true, TestSuite

from mtest.exec import Termination
from mtest.model import Outcome
from mtest.session import run_verdict, build_verdict


def test_run_verdict_exit_zero_is_pass() raises:
    assert_true(run_verdict(Termination.exited(0)) == Outcome.PASS)


def test_run_verdict_exit_nonzero_is_fail() raises:
    assert_true(run_verdict(Termination.exited(1)) == Outcome.FAIL)
    assert_true(run_verdict(Termination.exited(127)) == Outcome.FAIL)


def test_run_verdict_signal_is_crash() raises:
    # SIGSEGV (11) and SIGABRT (6) are crashes, never failures.
    assert_true(run_verdict(Termination.signaled(11)) == Outcome.CRASH)
    assert_true(run_verdict(Termination.signaled(6)) == Outcome.CRASH)


def test_run_verdict_timed_out_is_timeout() raises:
    assert_true(
        run_verdict(Termination.timed_out(Termination.SIGNALED, 15, True))
        == Outcome.TIMEOUT
    )


def test_run_verdict_spawn_failed_is_not_run_sentinel() raises:
    # SpawnFailed is never a test outcome; the sentinel is NOT_RUN (the caller
    # checks is_spawn_failed() first and routes to exit 3).
    assert_true(run_verdict(Termination.spawn_failed(2)) == Outcome.NOT_RUN)


def test_build_verdict_exit_zero_is_pass_sentinel() raises:
    # PASS is the "proceed to run" signal.
    assert_true(build_verdict(Termination.exited(0)) == Outcome.PASS)


def test_build_verdict_exit_nonzero_is_compile_error() raises:
    assert_true(build_verdict(Termination.exited(1)) == Outcome.COMPILE_ERROR)


def test_build_verdict_signal_is_compile_error() raises:
    # A compiler that dies by a signal is a BUILD failure, NEVER a test crash.
    assert_true(
        build_verdict(Termination.signaled(11)) == Outcome.COMPILE_ERROR
    )


def test_build_verdict_timed_out_is_compile_timeout() raises:
    # A build we killed at `--compile-timeout` is its OWN outcome: the compiler
    # never got to say anything about the code, so calling it a COMPILE_ERROR
    # would blame the source for our deadline. Never a NOT_RUN sentinel, never a
    # test CRASH. (An interrupt-induced TimedOut never reaches here — the caller
    # short-circuits an interrupt before consulting the verdict.)
    assert_true(
        build_verdict(Termination.timed_out(Termination.SIGNALED, 15, True))
        == Outcome.COMPILE_TIMEOUT
    )


def test_build_verdict_timed_out_escalated_is_also_compile_timeout() raises:
    # A compiler that ignored SIGTERM and needed the SIGKILL escalation is still
    # our deadline kill, not a compile error.
    assert_true(
        build_verdict(Termination.timed_out(Termination.SIGNALED, 9, True))
        == Outcome.COMPILE_TIMEOUT
    )


def test_build_verdict_spawn_failed_is_not_run_sentinel() raises:
    assert_true(build_verdict(Termination.spawn_failed(2)) == Outcome.NOT_RUN)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
