"""Timeout, latch, and group-kill invariants for `exec`.

Our own deadline kill is attributable to us and LATCHES to `TimedOut` regardless
of how the child then dies, and the kill targets the process group:
- a child that catches SIGTERM and exits 0 in the grace window -> TimedOut with
  final Exited(0), not escalated;
- a plain sleeper killed by the default SIGTERM -> TimedOut, final Signaled(15);
- a child that ignores SIGTERM -> escalated to SIGKILL -> TimedOut, Signaled(9);
- a child that closes both streams then hangs is killed by the deadline (EOF is
  not completion);
- a grandchild that inherits the pipe is reached by the group kill.
"""
from std.os import remove
from std.os.path import exists
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.exec import ExecRuntime, ProcessSpec, run_supervised

from exec_helpers import target, py_spec


def test_clean_grace_exit_latches_to_timed_out() raises:
    var runtime = ExecRuntime()
    var argv = List[String]()
    argv.append(target("sigterm_grace_exit.py"))
    var r = run_supervised(runtime, py_spec(argv^, 200))
    runtime.close()
    assert_true(r.termination.is_timed_out(), String(r.termination))
    # The child actually exited 0 in the grace window — retained, but latched.
    assert_true(r.termination.final_is_exited(), String(r.termination))
    assert_equal(r.termination.final_value, 0)
    assert_false(r.termination.escalated, String(r.termination))


def test_sigterm_death_latches_to_timed_out() raises:
    var runtime = ExecRuntime()
    var argv = List[String]()
    argv.append(target("sleeper.py"))
    var r = run_supervised(runtime, py_spec(argv^, 200))
    runtime.close()
    assert_true(r.termination.is_timed_out(), String(r.termination))
    assert_false(r.termination.final_is_exited(), String(r.termination))
    assert_equal(r.termination.final_value, 15)  # SIGTERM
    assert_false(r.termination.escalated, String(r.termination))


def test_sigterm_ignorer_escalates_to_sigkill() raises:
    var runtime = ExecRuntime()
    var argv = List[String]()
    argv.append(target("sigterm_ignorer.py"))
    var r = run_supervised(runtime, py_spec(argv^, 200))
    runtime.close()
    assert_true(r.termination.is_timed_out(), String(r.termination))
    assert_false(r.termination.final_is_exited(), String(r.termination))
    assert_equal(r.termination.final_value, 9)  # SIGKILL
    assert_true(r.termination.escalated, String(r.termination))


def test_close_streams_then_hang_killed_by_deadline() raises:
    var runtime = ExecRuntime()
    # Both pipes hit EOF immediately, but the child sleeps on: the deadline, not
    # EOF, must end it. A blocking-wait-after-EOF bug would hang here forever.
    var argv = List[String]()
    argv.append(target("close_streams_then_hang.py"))
    var r = run_supervised(runtime, py_spec(argv^, 300))
    runtime.close()
    assert_true(r.termination.is_timed_out(), String(r.termination))
    # It was killed near the deadline, not left to run its 300s sleep.
    assert_true(r.duration_ms < 5000, String(r.duration_ms))


def test_group_kill_reaches_grandchild() raises:
    var runtime = ExecRuntime()
    var sentinel = String("build/tests/grandchild_sentinel.txt")
    if exists(sentinel):
        remove(sentinel)
    var argv = List[String]()
    argv.append(target("grandchild_spawner.py"))
    argv.append(sentinel)
    var r = run_supervised(runtime, py_spec(argv^, 300))
    assert_true(r.termination.is_timed_out(), String(r.termination))
    # Wait past the grandchild's 2s survival window, then prove it never wrote:
    # the group kill reached it. A single-child kill would leave it to survive.
    var wait = List[String]()
    wait.append("python3")
    wait.append("-c")
    wait.append("import time; time.sleep(3)")
    _ = run_supervised(runtime, ProcessSpec.command(wait^))
    runtime.close()
    assert_false(exists(sentinel), "grandchild survived the group kill")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
