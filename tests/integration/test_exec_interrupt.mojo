"""The R4 interrupt primitive for `exec`: sigaction handlers over a latch flag.

Proves the one new FFI surface end to end: installing SIGINT/SIGTERM handlers via
`sigaction`, self-signaling, and observing the latching flag flip; then that a
supervised run bails out promptly when the interrupt is already set instead of
waiting out a deadline.

Kept in its own module because the interrupt flag latches until explicit reset
or the next runtime open, so these tests share no state with the others.
"""
from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.exec import (
    ProcessSpec,
    run_supervised,
    ExecRuntime,
    interrupt_requested,
)
from mtest.exec.signals import _reset_interrupt, _raise_self

from exec_helpers import target, py_spec

comptime _SIGINT = 2
comptime _EIO = 5
comptime _EPERM = 1
comptime _OP_INSTALL_TERM = 5
comptime _OP_RESTORE_INT = 6
comptime _OP_POLL = 26
comptime _OP_GROUP_TERM = 32
comptime _OP_GROUP_KILL = 33


def _reset_faults():
    """Clear the isolated testing adapter's native fault table."""
    # SAFETY: this test-only ABI takes no pointer, retains nothing, and mutates
    # only the testing adapter's single-threaded fault configuration.
    external_call["mtest_exec_test_fault_reset", NoneType]()


def _configure_fault(operation: Int, error_number: Int) raises:
    """Fail the first occurrence of one native adapter operation."""
    # SAFETY: the test-only ABI takes scalar discriminators only. Both values
    # are exact enum/errno constants, and no pointer or state escapes the call.
    var result = external_call["mtest_exec_test_fault_configure", Int32](
        UInt32(operation), UInt32(1), Int32(error_number), Int64(0)
    )
    assert_equal(result, Int32(0), "could not configure native fault")


def test_sigaction_self_signal_flips_flag() raises:
    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    assert_false(interrupt_requested(), "flag should start clear")
    _raise_self(_SIGINT)
    # The async-signal-safe handler set the latching flag; we observe it.
    assert_true(interrupt_requested(), "SIGINT handler did not set the flag")
    _reset_interrupt()
    runtime.close()


def test_run_supervised_bails_out_promptly_on_interrupt() raises:
    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    _raise_self(_SIGINT)
    assert_true(interrupt_requested())
    # No deadline at all, but the pending interrupt must group-kill and return.
    var argv = List[String]()
    argv.append(target("sleeper.py"))
    var r = run_supervised(runtime, py_spec(argv^, 0))
    assert_true(r.termination.is_timed_out(), String(r.termination))
    assert_true(r.duration_ms < 5000, String(r.duration_ms))
    _reset_interrupt()
    runtime.close()


def test_inactive_runtime_rejects_supervision() raises:
    var runtime = ExecRuntime()
    assert_false(runtime.active, "new token must not claim native ownership")
    var argv = [String("/bin/true")]
    var message = String("")
    try:
        _ = run_supervised(runtime, ProcessSpec.command(argv^))
    except e:
        message = String(e)
    runtime.close()
    assert_equal(
        message,
        "exec: run_supervised requires an active ExecRuntime",
    )


def test_second_active_runtime_is_rejected_without_ownership() raises:
    var first = ExecRuntime()
    first.open()
    var second = ExecRuntime()
    var message = String("")
    try:
        second.open()
    except e:
        message = String(e)
    var second_active = second.active
    first.close()
    second.close()
    assert_equal(message, "exec: runtime open failed (operation 0, errno 16)")
    assert_false(second_active, "rejected token must not claim ownership")


def test_install_failure_with_rollback_leaves_token_inactive() raises:
    _reset_faults()
    _configure_fault(_OP_INSTALL_TERM, _EIO)
    var runtime = ExecRuntime()
    var message = String("")
    try:
        runtime.open()
    except e:
        message = String(e)
    var owned_after_failure = runtime.active
    _reset_faults()
    runtime.open()
    runtime.close()
    assert_equal(message, "exec: runtime open failed (operation 5, errno 5)")
    assert_false(
        owned_after_failure,
        "successful rollback must leave no native ownership",
    )


def test_rollback_failure_keeps_token_owning_until_explicit_repair() raises:
    _reset_faults()
    _configure_fault(_OP_INSTALL_TERM, _EIO)
    _configure_fault(_OP_RESTORE_INT, _EPERM)
    var runtime = ExecRuntime()
    var message = String("")
    try:
        runtime.open()
    except e:
        message = String(e)
    var owned_after_failure = runtime.active
    assert_true(
        owned_after_failure,
        "failed rollback must remain owned by the existing token",
    )
    _reset_faults()
    runtime.close()
    var owned_after_repair = runtime.active
    runtime.open()
    runtime.close()
    assert_equal(
        message,
        (
            "exec: runtime open failed (operation 5, errno 5); cleanup "
            "operation 6 failed with errno 1"
        ),
    )
    assert_false(
        owned_after_repair,
        "explicit repair must release native ownership",
    )


def test_failed_explicit_repair_remains_owned_for_retry() raises:
    _reset_faults()
    _configure_fault(_OP_INSTALL_TERM, _EIO)
    _configure_fault(_OP_RESTORE_INT, _EPERM)
    var runtime = ExecRuntime()
    try:
        runtime.open()
    except:
        pass
    _reset_faults()
    _configure_fault(_OP_RESTORE_INT, _EIO)
    var message = String("")
    try:
        runtime.close()
    except e:
        message = String(e)
    var owned_after_failed_repair = runtime.active
    _reset_faults()
    runtime.close()
    var owned_after_retry = runtime.active
    runtime.open()
    runtime.close()
    assert_equal(message, "exec: runtime close failed (operation 6, errno 5)")
    assert_true(
        owned_after_failed_repair,
        "failed explicit repair must retain ownership",
    )
    assert_false(owned_after_retry, "successful close retry must release it")


def test_cleanup_diagnostic_does_not_leak_native_child_slot() raises:
    _reset_faults()
    _configure_fault(_OP_POLL, _EIO)
    _configure_fault(_OP_GROUP_TERM, _EIO)
    var runtime = ExecRuntime()
    runtime.open()
    var sleeper = List[String]()
    sleeper.append(target("sleeper.py"))
    var message = String("")
    try:
        _ = run_supervised(runtime, py_spec(sleeper^, 0))
    except e:
        message = String(e)
    _reset_faults()

    var followup = List[String]()
    followup.append("/bin/true")
    var result = run_supervised(runtime, ProcessSpec.command(followup^))
    runtime.close()

    assert_equal(
        message,
        (
            "exec: poll failed (operation 26, errno 5); exec: cleanup failed "
            "(operation 0, errno 0); cleanup operation 32 failed with errno 5"
        ),
    )
    assert_true(result.termination.is_exited(), String(result.termination))
    assert_equal(result.termination.value, 0)


def test_runtime_close_retries_a_retained_native_child_handle() raises:
    """The runtime token repairs a failed abort sweep before releasing signals.
    """
    _reset_faults()
    _configure_fault(_OP_POLL, _EIO)
    _configure_fault(_OP_GROUP_TERM, _EIO)
    _configure_fault(_OP_GROUP_KILL, _EIO)
    var runtime = ExecRuntime()
    runtime.open()
    var sleeper = List[String]()
    sleeper.append(target("sleeper.py"))
    var message = String("")
    try:
        _ = run_supervised(runtime, py_spec(sleeper^, 0))
    except e:
        message = String(e)

    # The first abort could not prove the group sweep and deliberately retained
    # its native handle. Clear the one-shot faults, then require the existing
    # ExecRuntime owner to retry that exact handle before restoring dispositions.
    _reset_faults()
    runtime.close()
    assert_false(runtime.active, "successful repair must release the runtime")

    # A fresh lifecycle proves neither the child slot nor signal ownership leaked.
    runtime.open()
    var followup = List[String]()
    followup.append("/bin/true")
    var result = run_supervised(runtime, ProcessSpec.command(followup^))
    runtime.close()

    assert_equal(
        message,
        (
            "exec: poll failed (operation 26, errno 5); exec: cleanup failed "
            "(operation 0, errno 0); cleanup operation 32 failed with errno 5"
        ),
    )
    assert_true(result.termination.is_exited(), String(result.termination))
    assert_equal(result.termination.value, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
