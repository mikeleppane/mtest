"""Text-file-busy latch precedence for the `exec` supervisor.

When a deadline or an interrupt fires while the child is still retrying a
text-file-busy (ETXTBSY) exec, the run must report TimedOut — our own kill won
the race — never a SpawnFailed machinery error. The testing adapter injects
ETXTBSY at the first child execve call, placing the child in the real bounded
retry delay without relying on an ambient filesystem race. Because the child
inherits our SIGTERM handler, it survives the group SIGTERM long enough to reach
the errno-reporting path — the exact race in which the latch must still win.

Kept in its own module because it installs signal handlers and drives the process
wide interrupt latch, which it resets so no state leaks into the other suites.
"""
from std.ffi import external_call
from std.memory import alloc, memset_zero
from std.testing import assert_true, TestSuite

from mtest.exec import (
    ProcessSpec,
    run_supervised,
    ExecRuntime,
)
from mtest.exec.signals import _reset_interrupt

from exec_helpers import target

comptime _SIGINT = 2
comptime _ETXTBSY = 26
comptime _OP_CHILD_EXECVE = 24
comptime _DELAY_NS = 10_000_000
"""Nanoseconds the SIGINT helper sleeps (10 ms) so the interrupt latch flips a
short way INTO the busy-exec retry window — late enough that the group SIGTERM's
grace escalation does not preempt the child before it reaches the errno path
(the race in which the latch must still win), yet well inside the window."""


def _inject_one_etxtbsy() raises:
    """Make the testing adapter's first child execve return ETXTBSY."""
    # SAFETY: both calls cross the test-only ABI with scalar values only. The
    # operation discriminator names CHILD_EXECVE, occurrence one is nonzero,
    # ETXTBSY is the supported Linux errno, and no pointer crosses the ABI.
    external_call["mtest_exec_test_fault_reset", NoneType]()
    var status = external_call["mtest_exec_test_fault_configure", Int32](
        UInt32(_OP_CHILD_EXECVE), UInt32(1), Int32(_ETXTBSY), Int64(0)
    )
    assert_true(status == 0, "could not configure child execve fault")


def test_deadline_beats_stuck_etxtbsy_exec_latches_timed_out() raises:
    # The child inherits our SIGTERM handler, so the deadline's group SIGTERM does
    # not kill it outright: it keeps retrying the busy exec and would otherwise
    # exhaust its retries and report SpawnFailed. The deadline latch must win, so
    # the verdict is TimedOut, not SpawnFailed.
    var runtime = ExecRuntime()
    _reset_interrupt()
    _inject_one_etxtbsy()
    var t = target("etxtbsy_target.sh")
    var argv = List[String]()
    argv.append(t)
    var r = run_supervised(runtime, ProcessSpec.command(argv^, 20))
    # SAFETY: this test-only scalar ABI clears only native fault-table state;
    # it accepts no pointer, retains nothing, and the runtime has no live child.
    external_call["mtest_exec_test_fault_reset", NoneType]()
    assert_true(r.termination.is_timed_out(), String(r.termination))
    # Bounded by the retry window, not left to run unsupervised.
    assert_true(r.duration_ms < 2000, String(r.duration_ms))
    runtime.close()


def _schedule_self_sigint() raises -> Int32:
    """Fork a helper that sleeps `_DELAY_NS`, delivers SIGINT to us, and exits.

    Flipping the interrupt latch a short way INTO the supervised run (rather than
    pre-setting it) mirrors how a real Ctrl-C lands mid-flight: the group SIGTERM
    then fires late enough that its grace escalation does not preempt the child
    before it reaches the errno path. Returns the helper pid for the caller to
    reap. The helper is targeted by pid, so the supervisor's own targeted waitpid
    never touches it.
    """
    # SAFETY: `nap` owns four contiguous Int64 cells. Zeroing all 32 bytes fully
    # initializes the two timespec-shaped records before either process reads
    # them. The child borrows its COW copy only for nanosleep; the parent frees
    # its allocation after fork and the child exits without running destructors.
    var nap = alloc[Int64](4)
    memset_zero(nap.bitcast[UInt8](), 4 * 8)
    nap[1] = _DELAY_NS
    # SAFETY: getpid and fork use their exact POSIX scalar/no-argument ABIs and
    # retain no pointer. All child-visible state above is initialized pre-fork.
    var self_pid = external_call["getpid", Int32]()
    var pid = external_call["fork", Int32]()
    if Int(pid) == 0:
        # SAFETY: this post-fork helper calls only nanosleep, kill, and _exit,
        # which are async-signal-safe on the supported Linux gate. `nap` and its
        # remainder record were fully initialized before fork and remain live in
        # the child's private COW image; neither foreign call retains a pointer.
        _ = external_call["nanosleep", Int32](
            nap.bitcast[UInt8](), (nap + 2).bitcast[UInt8]()
        )
        _ = external_call["kill", Int32](self_pid, Int32(_SIGINT))
        external_call["_exit", NoneType](Int32(0))
    if Int(pid) < 0:
        # SAFETY: fork failed, so only the parent owns `nap`; no child can borrow
        # it and freeing the unique allocation once is valid before raising.
        nap.free()
        raise Error("could not fork SIGINT test helper")
    # SAFETY: only the parent reaches this line; its `nap` allocation is unique.
    # The successful child owns a separate COW image and cannot observe the free.
    nap.free()
    return pid


def test_interrupt_beats_stuck_etxtbsy_exec_latches_timed_out() raises:
    # An interrupt that arrives DURING the busy-exec retry window must surface as
    # the exec-level TimedOut (which the session routes to the interrupt exit),
    # never a SpawnFailed machinery error. No deadline: the interrupt alone drives
    # the kill. A helper delivers the SIGINT mid-run so the child, surviving the
    # caught group SIGTERM, still reaches the errno path under the latch.
    var runtime = ExecRuntime()
    _reset_interrupt()
    _inject_one_etxtbsy()
    var t = target("etxtbsy_target.sh")
    var helper = _schedule_self_sigint()
    var argv = List[String]()
    argv.append(t)
    var r = run_supervised(runtime, ProcessSpec.command(argv^, 0))
    # Reap the helper and clear the latch before asserting, so neither the zombie
    # nor the interrupt state can leak into the rest of the suite.
    # SAFETY: `st` owns one aligned Int32. It is zero-initialized before crossing
    # the waitpid ABI, which writes at most that one status and retains no pointer.
    var st = alloc[Int32](1)
    memset_zero(st.bitcast[UInt8](), 4)
    var reaped = external_call["waitpid", Int32](helper, st, Int32(0))
    # SAFETY: waitpid retains no pointer and `st` remains uniquely owned and
    # unread. Even on wait failure it is raw trivial storage, so freeing it once
    # is valid before separately asserting that the exact helper was reaped.
    st.free()
    assert_true(reaped == helper, "could not reap SIGINT test helper")
    _reset_interrupt()
    # SAFETY: this test-only scalar ABI clears only native fault-table state;
    # it accepts no pointer, retains nothing, and the runtime has no live child.
    external_call["mtest_exec_test_fault_reset", NoneType]()
    runtime.close()
    assert_true(r.termination.is_timed_out(), String(r.termination))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
