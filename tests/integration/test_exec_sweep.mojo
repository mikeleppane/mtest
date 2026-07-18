"""Process-group cleanup for ordinary and escaped descendants.

The supervisor owns the child's whole process group. On the timeout/interrupt
path it already group-kills, but a NORMALLY-exiting child that forked a
grandchild would otherwise leak it: the leader is reaped and the parent returns
while the grandchild lives on. The supervisor sweeps the group (an immediate
SIGKILL, after draining the leader's output) on every exit path, so the
grandchild is reached too — while the reported status stays the leader's real
clean exit, never TimedOut. A descendant can leave that group with `setsid()`;
if it retains a capture pipe, the bounded post-leader drain raises a named
machinery error instead of laundering the leader's exit 0 into success.
"""
from std.os import remove
from std.os.path import exists
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.time import perf_counter_ns

from mtest.exec import ExecRuntime, ProcessSpec, run_supervised

from exec_helpers import bytes_to_str, target, py_spec


def test_group_sweep_reaches_grandchild_on_normal_exit() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var sentinel = String("build/tests/sweep_sentinel.txt")
    if exists(sentinel):
        remove(sentinel)
    var argv = List[String]()
    argv.append(target("grandchild_exit0.py"))
    argv.append(sentinel)
    # NO timeout: the direct child exits 0 at once and is reaped normally.
    var r = run_supervised(runtime, py_spec(argv^, 0))
    # Cleanup only: the reported status is the leader's real clean exit.
    assert_true(r.termination.is_exited(), String(r.termination))
    assert_equal(r.termination.value, 0)
    assert_false(r.termination.is_timed_out(), String(r.termination))
    # Wait past the grandchild's 2s survival window, then prove it never wrote:
    # the normal-exit group sweep reached it. Without the sweep it would survive.
    var wait = List[String]()
    wait.append("python3")
    wait.append("-c")
    wait.append("import time; time.sleep(3)")
    _ = run_supervised(runtime, ProcessSpec.command(wait^))
    runtime.close()
    assert_false(exists(sentinel), "grandchild survived the normal-exit sweep")


def test_escaped_descendant_retaining_pipe_is_never_success() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var control_path = String("build/tests/escaped-descendant-") + String(
        perf_counter_ns()
    )
    var ready_path = control_path + ".ready"
    var stop_path = control_path + ".stop"
    if exists(ready_path):
        remove(ready_path)
    if exists(stop_path):
        remove(stop_path)

    var spawn_argv = List[String]()
    spawn_argv.append(target("escaped_pipe_holder.py"))
    spawn_argv.append("spawn")
    spawn_argv.append(control_path)
    var message = String("")
    var returned_success = False
    var started_ns = perf_counter_ns()
    try:
        _ = run_supervised(runtime, py_spec(spawn_argv^, 0))
        returned_success = True
    except e:
        message = String(e)
    var elapsed_ms = (perf_counter_ns() - started_ns) // 1_000_000

    # External cleanup is separately supervised and deadline-bounded. The
    # actor also self-expires, so even a broken cleanup path cannot leak in CI.
    var cleanup_argv = List[String]()
    cleanup_argv.append(target("escaped_pipe_holder.py"))
    cleanup_argv.append("cleanup")
    cleanup_argv.append(control_path)
    var cleanup = run_supervised(runtime, py_spec(cleanup_argv^, 6000))
    runtime.close()

    assert_false(returned_success, "leader exit 0 was accepted as success")
    assert_equal(
        message,
        "exec: descendant retained a capture pipe past the cleanup deadline",
    )
    assert_true(elapsed_ms < 5000, String(elapsed_ms))
    assert_true(cleanup.termination.is_exited(), String(cleanup.termination))
    assert_equal(cleanup.termination.value, 0)
    assert_equal(bytes_to_str(cleanup.stdout_bytes), "CLEANED\n")
    assert_false(exists(ready_path), "escapee left its ready marker behind")
    assert_false(exists(stop_path), "cleanup left its stop marker behind")


def test_escapee_cleanup_without_acknowledgement_fails_loudly() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var control_path = String("build/tests/unresponsive-escapee-") + String(
        perf_counter_ns()
    )
    var ready_path = control_path + ".ready"
    var stop_path = control_path + ".stop"

    var setup_argv = List[String]()
    setup_argv.append(target("escaped_pipe_holder.py"))
    setup_argv.append("unresponsive")
    setup_argv.append(control_path)
    var setup = run_supervised(runtime, py_spec(setup_argv^, 3000))

    var cleanup_argv = List[String]()
    cleanup_argv.append(target("escaped_pipe_holder.py"))
    cleanup_argv.append("cleanup")
    cleanup_argv.append(control_path)
    var cleanup = run_supervised(runtime, py_spec(cleanup_argv^, 6000))
    if exists(ready_path):
        remove(ready_path)
    if exists(stop_path):
        remove(stop_path)
    runtime.close()

    assert_true(setup.termination.is_exited(), String(setup.termination))
    assert_equal(setup.termination.value, 0)
    assert_true(cleanup.termination.is_exited(), String(cleanup.termination))
    assert_equal(cleanup.termination.value, 70)
    assert_equal(bytes_to_str(cleanup.stdout_bytes), "")
    assert_true(cleanup.duration_ms < 5000, String(cleanup.duration_ms))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
