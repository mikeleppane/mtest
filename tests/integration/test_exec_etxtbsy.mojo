"""Text-file-busy latch precedence for the `exec` supervisor.

When a deadline or an interrupt fires while the child is still retrying a
text-file-busy (ETXTBSY) exec, the run must report TimedOut — our own kill won
the race — never a SpawnFailed machinery error. The testing adapter injects
ETXTBSY at the first child execve call, placing the child in the real bounded
retry delay without relying on an ambient filesystem race, then injects EIO at
the second call so SpawnFailed genuinely competes with the timeout latch.
Because the child inherits our SIGTERM handler, it survives the group SIGTERM
long enough to reach the errno-reporting path — the exact race in which the
latch must still win.

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
comptime _SIGCONT = 18
comptime _SIGSTOP = 19
comptime _EIO = 5
comptime _ETXTBSY = 26
comptime _OP_CHILD_EXECVE = 24
comptime _DELAY_MS = 10
comptime _STOP_DELAY_MS = 5
comptime _STOP_DURATION_MS = 100
"""Milliseconds the SIGINT helper polls (10 ms) so the interrupt latch flips a
short way INTO the busy-exec retry window — late enough that the group SIGTERM's
grace escalation does not preempt the child before it reaches the errno path
(the race in which the latch must still win), yet well inside the window."""


def _inject_etxtbsy_then_exec_error() raises:
    """Make child execve return ETXTBSY once, then a terminal EIO."""
    # SAFETY: these test-only ABI calls use scalar values only. The operation
    # discriminator names CHILD_EXECVE; occurrences one and two are ordered and
    # nonzero; both errno values are positive; no pointer crosses either ABI.
    external_call["mtest_exec_test_fault_reset", NoneType]()
    var status = external_call["mtest_exec_test_fault_configure", Int32](
        UInt32(_OP_CHILD_EXECVE), UInt32(1), Int32(_ETXTBSY), Int64(0)
    )
    assert_true(status == 0, "could not configure child execve fault")
    # SAFETY: this secondary test-only ABI also accepts scalars only; occurrence
    # two follows the configured primary occurrence, EIO is positive, the result
    # payload is zero as required for an error, and no pointer crosses the ABI.
    status = external_call["mtest_exec_test_fault_configure_secondary", Int32](
        UInt32(_OP_CHILD_EXECVE), UInt32(2), Int32(_EIO), Int64(0)
    )
    assert_true(status == 0, "could not configure terminal child execve fault")


def _schedule_self_stop_then_continue() raises -> Int32:
    """Stop the supervisor across its deadline, then let it resume."""
    # SAFETY: `poll_storage` owns one initialized Int64 cell before fork. Each
    # nfds-zero poll ignores the pointer, and the child's COW copy stays live
    # until it exits without destructors. The parent frees only its own copy.
    var poll_storage = alloc[Int64](1)
    memset_zero(poll_storage.bitcast[UInt8](), 8)
    # SAFETY: getpid and fork use their exact Linux scalar/no-argument ABIs,
    # retain no pointer, and all child-visible storage is initialized pre-fork.
    var self_pid = external_call["getpid", Int32]()
    var pid = external_call["fork", Int32]()
    if Int(pid) == 0:
        # SAFETY: after fork the helper calls only poll, kill, and _exit, all
        # async-signal-safe. Both nfds-zero polls ignore the live COW pointer;
        # bounded scalar delays bracket exact Linux SIGSTOP/SIGCONT delivery to
        # the parent's pid, and no call retains a pointer or returns ownership.
        _ = external_call["poll", Int32](
            poll_storage.bitcast[UInt8](), UInt64(0), Int32(_STOP_DELAY_MS)
        )
        _ = external_call["kill", Int32](self_pid, Int32(_SIGSTOP))
        _ = external_call["poll", Int32](
            poll_storage.bitcast[UInt8](), UInt64(0), Int32(_STOP_DURATION_MS)
        )
        _ = external_call["kill", Int32](self_pid, Int32(_SIGCONT))
        # SAFETY: _exit is async-signal-safe, accepts the exact scalar status,
        # retains no state, and terminates without running Mojo destructors.
        external_call["_exit", NoneType](Int32(0))
    if Int(pid) < 0:
        # SAFETY: fork failed, so the parent uniquely owns the allocation and
        # may free it exactly once before raising.
        poll_storage.free()
        raise Error("could not fork stop/continue test helper")
    # SAFETY: parent and child now have distinct COW images. Freeing the unique
    # parent allocation cannot invalidate the child's still-live copy.
    poll_storage.free()
    return pid


def _reap_helper(helper: Int32) raises:
    """Reap one exact test helper without consuming a supervised child."""
    # SAFETY: `st` owns one zero-initialized aligned Int32. waitpid writes at
    # most that status, retains no pointer, and targets only the supplied helper.
    var st = alloc[Int32](1)
    memset_zero(st.bitcast[UInt8](), 4)
    var reaped = external_call["waitpid", Int32](helper, st, Int32(0))
    # SAFETY: waitpid retained nothing; `st` remains uniquely owned raw trivial
    # storage on success or failure and is freed exactly once before asserting.
    st.free()
    assert_true(reaped == helper, "could not reap test helper")


def test_deadline_beats_stuck_etxtbsy_exec_latches_timed_out() raises:
    # The child inherits our SIGTERM handler, so the deadline's group SIGTERM does
    # not kill it outright: it leaves the ETXTBSY delay and reaches the injected
    # terminal EIO, which reports SpawnFailed. The deadline latch must win, so the
    # verdict is TimedOut, not SpawnFailed.
    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    _inject_etxtbsy_then_exec_error()
    var helper = _schedule_self_stop_then_continue()
    var t = target("etxtbsy_target.sh")
    var argv = List[String]()
    argv.append(t)
    var r = run_supervised(runtime, ProcessSpec.command(argv^, 20))
    _reap_helper(helper)
    # SAFETY: this test-only scalar ABI clears only native fault-table state;
    # it accepts no pointer, retains nothing, and the runtime has no live child.
    external_call["mtest_exec_test_fault_reset", NoneType]()
    assert_true(r.termination.is_timed_out(), String(r.termination))
    assert_true(r.termination.final_is_exited(), String(r.termination))
    # The target exits 0, so a nonzero final exit proves the injected terminal
    # EIO path won. Memcheck full-leak mode may replace the normal 127 with its
    # configured error exit because the transient fork copy owns COW allocations.
    assert_true(r.termination.final_value != 0, String(r.termination))
    # Bounded by the retry window, not left to run unsupervised.
    assert_true(r.duration_ms < 2000, String(r.duration_ms))
    runtime.close()


def _schedule_self_sigint() raises -> Int32:
    """Fork a helper that polls for `_DELAY_MS`, delivers SIGINT, and exits.

    Flipping the interrupt latch a short way INTO the supervised run (rather than
    pre-setting it) mirrors how a real Ctrl-C lands mid-flight: the group SIGTERM
    then fires late enough that its grace escalation does not preempt the child
    before it reaches the errno path. Returns the helper pid for the caller to
    reap. The helper is targeted by pid, so the supervisor's own targeted waitpid
    never touches it.
    """
    # SAFETY: `poll_storage` owns one initialized Int64 cell before fork. The
    # child retains its COW copy until poll returns; nfds zero means poll never
    # reads it. The parent frees its allocation after fork and the child exits
    # without running destructors.
    var poll_storage = alloc[Int64](1)
    memset_zero(poll_storage.bitcast[UInt8](), 8)
    # SAFETY: getpid and fork use their exact POSIX scalar/no-argument ABIs and
    # retain no pointer. All child-visible state above is initialized pre-fork.
    var self_pid = external_call["getpid", Int32]()
    var pid = external_call["fork", Int32]()
    if Int(pid) == 0:
        # SAFETY: this post-fork helper calls only poll, kill, and _exit, which
        # POSIX requires to be async-signal-safe. `poll_storage` remains live in
        # the child's private COW image; nfds zero prevents dereference, the
        # scalar timeout is bounded, and no foreign call retains a pointer.
        _ = external_call["poll", Int32](
            poll_storage.bitcast[UInt8](), UInt64(0), Int32(_DELAY_MS)
        )
        _ = external_call["kill", Int32](self_pid, Int32(_SIGINT))
        external_call["_exit", NoneType](Int32(0))
    if Int(pid) < 0:
        # SAFETY: fork failed, so only the parent owns `poll_storage`; no child can borrow
        # it and freeing the unique allocation once is valid before raising.
        poll_storage.free()
        raise Error("could not fork SIGINT test helper")
    # SAFETY: only the parent reaches this line; its `poll_storage` allocation is unique.
    # The successful child owns a separate COW image and cannot observe the free.
    poll_storage.free()
    return pid


def test_interrupt_beats_stuck_etxtbsy_exec_latches_timed_out() raises:
    # An interrupt that arrives DURING the busy-exec retry window must surface as
    # the exec-level TimedOut (which the session routes to the interrupt exit),
    # never a SpawnFailed machinery error. No deadline: the interrupt alone drives
    # the kill. A helper delivers the SIGINT mid-run so the child, surviving the
    # caught group SIGTERM, still reaches the errno path under the latch.
    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    _inject_etxtbsy_then_exec_error()
    var t = target("etxtbsy_target.sh")
    var helper = _schedule_self_sigint()
    var argv = List[String]()
    argv.append(t)
    var r = run_supervised(runtime, ProcessSpec.command(argv^, 0))
    # Reap the helper and clear the latch before asserting, so neither the zombie
    # nor the interrupt state can leak into the rest of the suite.
    _reap_helper(helper)
    _reset_interrupt()
    # SAFETY: this test-only scalar ABI clears only native fault-table state;
    # it accepts no pointer, retains nothing, and the runtime has no live child.
    external_call["mtest_exec_test_fault_reset", NoneType]()
    runtime.close()
    assert_true(r.termination.is_timed_out(), String(r.termination))
    assert_true(r.termination.final_is_exited(), String(r.termination))
    # As above, nonzero discriminates the EIO setup failure from target exit 0
    # without coupling this correctness test to a memory tool's error-exit value.
    assert_true(r.termination.final_value != 0, String(r.termination))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
