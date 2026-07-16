"""Process-group sweep for `exec`: a normal exit leaves no grandchild behind.

The supervisor owns the child's whole process group. On the timeout/interrupt
path it already group-kills, but a NORMALLY-exiting child that forked a
grandchild would otherwise leak it: the leader is reaped and the parent returns
while the grandchild lives on. The supervisor sweeps the group (an immediate
SIGKILL, after draining the leader's output) on every exit path, so the
grandchild is reached too — while the reported status stays the leader's real
clean exit, never TimedOut.
"""
from std.os import remove
from std.os.path import exists
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.exec import ExecRuntime, ProcessSpec, run_supervised

from exec_helpers import target, py_spec


def test_group_sweep_reaches_grandchild_on_normal_exit() raises:
    var runtime = ExecRuntime()
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
