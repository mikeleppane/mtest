"""Reap honesty for `exec`: a `waitpid` that cannot retrieve a status is never
laundered into a false PASS.

If the process inherits `SIG_IGN` for SIGCHLD, the kernel auto-reaps children
and `waitpid` fails with ECHILD instead of handing back a status word. A
supervisor that decoded the unfilled status would report `Exited(0)` — a false
PASS — for every child, including genuine failures and crashes. The supervisor
guarantees reapability by resetting SIGCHLD to its default before spawning, so a
real nonzero exit is reported truthfully; a residual reap failure surfaces as a
spawn-failure sentinel (internal error), never as a test outcome.
"""
from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.exec import ExecRuntime, ProcessSpec, run_supervised

from exec_helpers import target, py_spec

comptime _SIGCHLD = 17
comptime _SIG_IGN = 1


def _inherit_sigchld_ignored():
    """Set this process's SIGCHLD disposition to SIG_IGN, the way a parent shell
    or supervisor might, so any child we then spawn is kernel auto-reaped."""
    # SAFETY: on the Linux integration gate `signal` has the pointer-sized
    # handler return ABI modeled by Int; SIGCHLD and SIG_IGN are valid constants,
    # no pointer argument is retained, and ExecRuntime saves/restores this state.
    _ = external_call["signal", Int](Int32(_SIGCHLD), Int(_SIG_IGN))


def test_nonzero_exit_not_laundered_under_ignored_sigchld() raises:
    # Poison the inherited disposition: without the supervisor's own reset this
    # makes every child un-waitable and every result a false Exited(0).
    _inherit_sigchld_ignored()
    var runtime = ExecRuntime()
    runtime.open()
    var argv = List[String]()
    argv.append(target("exit_nonzero.py"))
    var r = run_supervised(runtime, py_spec(argv^))
    runtime.close()
    # The real fate must survive: a genuine Exited(7), never a laundered PASS.
    assert_true(r.termination.is_exited(), String(r.termination))
    assert_equal(r.termination.value, 7)
    assert_false(
        r.termination.is_exited() and r.termination.value == 0,
        "a waitpid failure was laundered into a false Exited(0) PASS",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
