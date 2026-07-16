"""Text-file-busy latch precedence for the `exec` supervisor.

When a deadline or an interrupt fires while the child is still retrying a
text-file-busy (ETXTBSY) exec, the run must report TimedOut — our own kill won
the race — never a SpawnFailed machinery error. Holding the target open for
writing across the run makes every execvp attempt return ETXTBSY deterministically
(Linux refuses to exec a file that has an open-for-write descriptor), so the child
stays in its bounded retry window and, because it inherits our SIGTERM handler,
survives the group SIGTERM long enough to reach the errno-reporting path — the
exact race in which the latch must still win.

Kept in its own module because it installs signal handlers and drives the process
wide interrupt latch, which it resets so no state leaks into the other suites.
"""
from std.ffi import external_call
from std.memory import UnsafePointer, alloc
from std.testing import assert_true, TestSuite

from mtest.exec import (
    ProcessSpec,
    run_supervised,
    ExecRuntime,
)
from mtest.exec.signals import _reset_interrupt

from exec_helpers import target

comptime _SIGINT = 2
comptime _O_WRONLY = 1
comptime _DELAY_NS = 60_000_000
"""Nanoseconds the SIGINT helper sleeps (60 ms) so the interrupt latch flips a
short way INTO the busy-exec retry window — late enough that the group SIGTERM's
grace escalation does not preempt the child before it reaches the errno path
(the race in which the latch must still win), yet well inside the window."""


def _open_wronly(path: String) -> Int32:
    """Open `path` write-only and return the fd (caller closes).

    Holding the returned descriptor open pins the file busy, so every execvp of
    it returns ETXTBSY for as long as the fd lives. Mirrors the parent-side cstr
    build the supervisor uses; frees the temporary path copy.
    """
    var n = path.byte_length()
    var p = alloc[UInt8](n + 1)
    for i in range(n):
        p[i] = path.unsafe_ptr()[i]
    p[n] = 0
    var fd = external_call["open", Int32](p, Int32(_O_WRONLY))
    p.free()
    return fd


def test_deadline_beats_stuck_etxtbsy_exec_latches_timed_out() raises:
    # The child inherits our SIGTERM handler, so the deadline's group SIGTERM does
    # not kill it outright: it keeps retrying the busy exec and would otherwise
    # exhaust its retries and report SpawnFailed. The deadline latch must win, so
    # the verdict is TimedOut, not SpawnFailed.
    var runtime = ExecRuntime()
    _reset_interrupt()
    var t = target("etxtbsy_target.sh")
    var fd = _open_wronly(t)
    assert_true(Int(fd) >= 0, "could not open the target O_WRONLY")
    var argv = List[String]()
    argv.append(t)
    var r = run_supervised(ProcessSpec.command(argv^, 100))
    _ = external_call["close", Int32](fd)
    assert_true(r.termination.is_timed_out(), String(r.termination))
    # Bounded by the retry window, not left to run unsupervised.
    assert_true(r.duration_ms < 2000, String(r.duration_ms))
    runtime.close()


def _schedule_self_sigint() -> Int32:
    """Fork a helper that sleeps `_DELAY_NS`, delivers SIGINT to us, and exits.

    Flipping the interrupt latch a short way INTO the supervised run (rather than
    pre-setting it) mirrors how a real Ctrl-C lands mid-flight: the group SIGTERM
    then fires late enough that its grace escalation does not preempt the child
    before it reaches the errno path. Returns the helper pid for the caller to
    reap. The helper is targeted by pid, so the supervisor's own targeted waitpid
    never touches it.
    """
    var self_pid = external_call["getpid", Int32]()
    var pid = external_call["fork", Int32]()
    if Int(pid) == 0:
        var nap = alloc[Int64](4)
        nap[0] = 0
        nap[1] = _DELAY_NS
        nap[2] = 0
        nap[3] = 0
        _ = external_call["nanosleep", Int32](
            nap.bitcast[UInt8](), (nap + 2).bitcast[UInt8]()
        )
        _ = external_call["kill", Int32](self_pid, Int32(_SIGINT))
        external_call["_exit", NoneType](Int32(0))
    return pid


def test_interrupt_beats_stuck_etxtbsy_exec_latches_timed_out() raises:
    # An interrupt that arrives DURING the busy-exec retry window must surface as
    # the exec-level TimedOut (which the session routes to the interrupt exit),
    # never a SpawnFailed machinery error. No deadline: the interrupt alone drives
    # the kill. A helper delivers the SIGINT mid-run so the child, surviving the
    # caught group SIGTERM, still reaches the errno path under the latch.
    var runtime = ExecRuntime()
    _reset_interrupt()
    var t = target("etxtbsy_target.sh")
    var fd = _open_wronly(t)
    assert_true(Int(fd) >= 0, "could not open the target O_WRONLY")
    var helper = _schedule_self_sigint()
    var argv = List[String]()
    argv.append(t)
    var r = run_supervised(ProcessSpec.command(argv^, 0))
    _ = external_call["close", Int32](fd)
    # Reap the helper and clear the latch before asserting, so neither the zombie
    # nor the interrupt state can leak into the rest of the suite.
    var st = alloc[Int32](1)
    _ = external_call["waitpid", Int32](helper, st, Int32(0))
    st.free()
    _reset_interrupt()
    runtime.close()
    assert_true(r.termination.is_timed_out(), String(r.termination))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
