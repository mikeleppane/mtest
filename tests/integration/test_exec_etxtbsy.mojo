"""Text-file-busy retry and latch precedence for the `exec` supervisor.

A transient ETXTBSY is what a freshly written executable looks like while its
writer still holds it open, so the bounded retry exists to survive it. The
recovery case proves the retry actually reaches a successful `execve`: the
adapter fails the first two child attempts with ETXTBSY and then stops faulting,
and the run must end as an ordinary child completion with the target's exact
bytes — not merely as an honest failure. Because the adapter's occurrence
counters live in the forked child and cannot be read back, that case also pins a
duration floor only two real retry backoffs can clear; otherwise "recovered" and
"never faulted" would look identical.

When a deadline or an interrupt fires around a text-file-busy (ETXTBSY) exec,
the run must report TimedOut — our own kill won the race — never a SpawnFailed
machinery error. The testing adapter injects ETXTBSY at the first child execve
call, placing the child in the real bounded retry delay without relying on an
ambient filesystem race, then injects EIO at the second call so SpawnFailed
genuinely competes with the timeout latch.

The deadline case delays the supervisor's first post-open clock read until both
the deadline and child exit are in the past. It therefore pins the loop ordering:
the timeout latch must be set before an observation of the already-waitable child
can end the loop. The interrupt case instead delivers SIGINT during the retry;
the child inherits our SIGTERM handler and survives long enough to reach the
errno-reporting path under the already-set latch.

Kept in its own module because it installs signal handlers and drives the process
wide interrupt latch, which it resets so no state leaks into the other suites.
"""
from std.ffi import external_call
from std.memory import alloc, memset_zero
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.exec import (
    ProcessSpec,
    run_supervised,
    ExecRuntime,
)
from mtest.exec.signals import _reset_interrupt

from exec_helpers import bytes_to_str, target
from foreign_abi import (
    configure_monotonic_wait,
    configure_native_fault,
    configure_secondary_native_fault,
    monotonic_wait_fired,
    native_test_constant,
    reap_child,
    reset_native_faults,
)

comptime _SIGINT = 2
comptime _CONSTANT_EIO = 4
comptime _CONSTANT_ETXTBSY = 5
comptime _OP_CHILD_EXECVE = 24
comptime _DELAY_MS = 10
comptime _CLOCK_WAIT_OCCURRENCE = 2
comptime _CLOCK_WAIT_MAX_MS = 1000
"""Milliseconds the SIGINT helper polls (10 ms) so the interrupt latch flips a
short way INTO the busy-exec retry window — late enough that the group SIGTERM's
grace escalation does not preempt the child before it reaches the errno path
(the race in which the latch must still win), yet well inside the window."""
comptime _RETRY_DELAY_MS = 50
"""The child's per-retry busy-exec backoff, mirroring the adapter's
MTEST_ETXTBSY_DELAY_MS. Only ever used to derive a LOWER bound, so the pinned
value can only make the derived floor conservative, never wrong."""
comptime _FAULTED_ATTEMPTS = 2
"""Child execve occurrences the recovery test faults before letting one through.
"""
comptime _MIN_RECOVERED_MS = _RETRY_DELAY_MS * _FAULTED_ATTEMPTS


def _inject_etxtbsy_then_exec_error() raises:
    """Make child execve return ETXTBSY once, then a terminal EIO."""
    # The operation discriminator names CHILD_EXECVE; occurrences one and two
    # are ordered and nonzero, so the secondary fault follows the primary.
    reset_native_faults()
    configure_native_fault(
        _OP_CHILD_EXECVE, 1, Int(native_test_constant(_CONSTANT_ETXTBSY))
    )
    configure_secondary_native_fault(
        _OP_CHILD_EXECVE, 2, Int(native_test_constant(_CONSTANT_EIO))
    )


def _inject_etxtbsy_for_the_first_two_attempts() raises:
    """Fault child execve occurrences one and two with ETXTBSY, then stop.

    Occurrence three onward is left unfaulted, so the third attempt reaches the
    real `execve` and the retry has to succeed rather than expire.
    """
    reset_native_faults()
    configure_native_fault(
        _OP_CHILD_EXECVE, 1, Int(native_test_constant(_CONSTANT_ETXTBSY))
    )
    configure_secondary_native_fault(
        _OP_CHILD_EXECVE, 2, Int(native_test_constant(_CONSTANT_ETXTBSY))
    )


def test_transient_etxtbsy_recovers_to_a_successful_child() raises:
    # Two transient ETXTBSY attempts inside the bounded retry budget, then a
    # clean exec: the run must be an ordinary completion carrying the target's
    # exact stdout, an empty stderr, and Exited(0) — not an honest failure.
    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    _inject_etxtbsy_for_the_first_two_attempts()
    var t = target("etxtbsy_target.sh")
    var argv = List[String]()
    argv.append(t)
    var result = run_supervised(runtime, ProcessSpec.command(argv^, 0))
    reset_native_faults()
    runtime.close()
    assert_equal(bytes_to_str(result.stdout_bytes), "etxtbsy-recovered\n")
    assert_equal(bytes_to_str(result.stderr_bytes), "")
    assert_true(result.termination.is_exited(), String(result.termination))
    assert_equal(result.termination.value, 0)
    assert_false(result.stdout_truncated)
    assert_false(result.stderr_truncated)
    # A clean exit alone cannot tell "recovered from two injected faults" apart
    # from "no fault ever fired": the adapter's occurrence counters live in the
    # forked child, so the parent cannot read them back. Each faulted attempt
    # costs one _RETRY_DELAY_MS backoff, and poll's timeout is a MINIMUM, so two
    # faults put a hard floor of _MIN_RECOVERED_MS under the run. A regression
    # that stopped honoring the secondary occurrence, or that remapped the
    # ETXTBSY constant, would exec on the first attempt and land far below it.
    assert_true(
        result.duration_ms >= _MIN_RECOVERED_MS, String(result.duration_ms)
    )


def _wait_before_first_post_open_clock_read() raises:
    """Let both the 20 ms deadline and child exit precede loop observation."""
    # The first monotonic call captures run_supervised's start time. The second
    # is the first loop-top deadline reading after process_open. At that exact
    # call the test adapter waits, without consuming the child, until the one
    # 50 ms ETXTBSY backoff reaches its terminal EIO and the child is waitable.
    # That exit necessarily also follows the 20 ms deadline.
    configure_monotonic_wait(_CLOCK_WAIT_OCCURRENCE, _CLOCK_WAIT_MAX_MS)


def _reap_helper(helper: Int32) raises:
    """Reap one exact test helper without consuming a supervised child.

    Naming the helper's exact pid, rather than -1, is what keeps this off the
    supervised child: `waitpid` can only return the process it was asked for.
    """
    var reaped = reap_child(helper, Int32(0))
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
    _wait_before_first_post_open_clock_read()
    var t = target("etxtbsy_target.sh")
    var argv = List[String]()
    argv.append(t)
    var r = run_supervised(runtime, ProcessSpec.command(argv^, 20))
    var wait_fired = monotonic_wait_fired()
    reset_native_faults()
    assert_true(wait_fired, "first post-open clock wait did not fire")
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
    reset_native_faults()
    runtime.close()
    assert_true(r.termination.is_timed_out(), String(r.termination))
    assert_true(r.termination.final_is_exited(), String(r.termination))
    # As above, nonzero discriminates the EIO setup failure from target exit 0
    # without coupling this correctness test to a memory tool's error-exit value.
    assert_true(r.termination.final_value != 0, String(r.termination))


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
