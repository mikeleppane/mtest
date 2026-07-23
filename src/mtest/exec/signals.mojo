"""Exclusive process-global interrupt and runtime ownership.

`ExecRuntime` is the non-copyable token that owns mtest's saved SIGINT,
SIGTERM, SIGCHLD, and SIGPIPE dispositions. The SIGPIPE save backs a
process-wide `SIG_IGN` carve-out that keeps mtest's own writes to a dead
`--json` pipe from killing the runner; it is restored first on close, and each
child restores it before `execve` so an exec'd test binary cannot inherit the
ignore and turn a real SIGPIPE crash into a false pass. The native adapter uses
the platform's own headers and a `volatile sig_atomic_t` latch; Mojo never lays
out `struct sigaction`, invents a callback pointer, maps a fixed address, or
reads libc's private errno storage.

A token is materialized inactive before `open()` transactionally installs the
handlers and rejects a second active runtime, so a live owner exists even when
native installation and its rollback both fail. `close()` is explicit and
fallible, so a restoration failure can never be reported as success. The
destructor is only a last-resort retry for exceptional unwinding; callers must
use `close()` on every ordinary path.
"""
from std.ffi import external_call
from std.memory import alloc, memset_zero

from mtest.platform import process_id


comptime _ERROR_BYTES = 32
"""Size of ABI-v1 `struct mtest_exec_error` (alignment 8)."""


def _runtime_error(
    prefix: String,
    operation: Int,
    error_number: Int,
    cleanup_operation: Int,
    cleanup_error: Int,
) -> Error:
    """Build one named native-runtime machinery error.

    A nonzero `cleanup_operation` means the rollback failed too, and appends
    that operation and errno to the message.
    """
    var message = (
        prefix
        + " (operation "
        + String(operation)
        + ", errno "
        + String(error_number)
        + ")"
    )
    if cleanup_operation != 0:
        message += (
            "; cleanup operation "
            + String(cleanup_operation)
            + " failed with errno "
            + String(cleanup_error)
        )
    return Error(message^)


struct ExecRuntime(Movable):
    """Exclusive ownership of mtest's process-global exec and signal state.

    Materialize once around a session or direct supervision group, call
    `open()`, pass it by mutable borrow to child operations, then call `close()`
    explicitly. A second simultaneously active instance raises `EBUSY` through
    the native error record. Sequential open/use/close cycles are supported.
    """

    var active: Bool
    """Whether this token still owns the native runtime."""

    def __init__(out self):
        """Materialize an inactive token before any fallible native call."""
        self.active = False

    def open(mut self) raises:
        """Install native interrupt handlers and take transactional ownership.

        On an install failure whose rollback also fails, this token stays active
        and owns the native restoration-required state. The caller can inspect
        the raised primary-plus-cleanup error and explicitly retry `close()` on
        the same live value.

        Raises:
            Error: A named `exec: runtime open failed` machinery error carrying
                the adapter operation and errno plus any rollback failure.
        """
        # SAFETY: `alloc[UInt64](4)` owns 32 bytes aligned to 8, exactly ABI-v1's
        # error record. Zeroing initializes every byte before C may write it;
        # `mtest_exec_runtime_open` does not retain the pointer.
        var error = alloc[UInt64](4)
        memset_zero(error.bitcast[UInt8](), _ERROR_BYTES)
        var result = external_call["mtest_exec_runtime_open", Int32](
            error.bitcast[UInt8]()
        )
        if result != 0:
            # SAFETY: the adapter initialized the complete aligned error record
            # before returning. ABI-v1 fixes primary operation/errno at 0/4 and
            # cleanup operation/errno at 8/12; a nonzero cleanup operation on
            # runtime-open means native state is RESTORE_REQUIRED and this live
            # token must own the explicit restoration retry.
            var operation = Int(error.bitcast[UInt32]()[0])
            var error_number = Int(error.bitcast[Int32]()[1])
            var cleanup_operation = Int(error.bitcast[UInt32]()[2])
            var cleanup_error = Int(error.bitcast[Int32]()[3])
            if cleanup_operation != 0:
                self.active = True
            # SAFETY: `error` is still the unique allocation owner and C did not
            # retain it; this frees it exactly once before the raising path.
            error.free()
            raise _runtime_error(
                "exec: runtime open failed",
                operation,
                error_number,
                cleanup_operation,
                cleanup_error,
            )
        # SAFETY: `error` remains uniquely owned and non-escaping after the
        # successful non-retaining ABI call; free it exactly once.
        error.free()
        self.active = True

    def close(mut self) raises:
        """Repair any retained child, then restore dispositions and ownership.

        Idempotent after success. If machinery cleanup retained a child handle,
        close retries its group sweep and reap before restoring signals. On a
        cleanup or restoration failure the token stays active so the caller can
        report the error and retry; the native state machine keeps rejecting a
        new child or runtime until then.

        Raises:
            Error: A named `exec: runtime close failed` machinery error carrying
                the first restoration operation and errno.
        """
        if not self.active:
            return
        # SAFETY: this is the same complete, aligned, uniquely-owned ABI-v1 error
        # record used by construction. The close call writes but never retains it.
        var error = alloc[UInt64](4)
        memset_zero(error.bitcast[UInt8](), _ERROR_BYTES)
        var result = external_call["mtest_exec_runtime_close", Int32](
            error.bitcast[UInt8]()
        )
        if result != 0:
            # SAFETY: C initialized the record before returning; ABI-v1 fixes
            # primary and cleanup values at the first four 32-bit slots.
            var operation = Int(error.bitcast[UInt32]()[0])
            var error_number = Int(error.bitcast[Int32]()[1])
            var cleanup_operation = Int(error.bitcast[UInt32]()[2])
            var cleanup_error = Int(error.bitcast[Int32]()[3])
            # SAFETY: the non-retained allocation still has one owner; free once
            # while leaving `self.active` true for an explicit retry.
            error.free()
            raise _runtime_error(
                "exec: runtime close failed",
                operation,
                error_number,
                cleanup_operation,
                cleanup_error,
            )
        # SAFETY: successful close did not retain the uniquely-owned record.
        error.free()
        self.active = False

    def __del__(deinit self):
        """Last-resort restoration; explicit `close()` is required."""
        if not self.active:
            return
        # SAFETY: destructor fallback owns this aligned 32-byte record, fully
        # initializes it, passes it to a non-retaining ABI call, then frees it.
        # Failure cannot be raised from a destructor; explicit close is the only
        # success-reporting path and is enforced by callers/tests.
        var error = alloc[UInt64](4)
        memset_zero(error.bitcast[UInt8](), _ERROR_BYTES)
        _ = external_call["mtest_exec_runtime_close", Int32](
            error.bitcast[UInt8]()
        )
        error.free()


def interrupt_requested() -> Bool:
    """Whether SIGINT or SIGTERM has latched since the latest runtime open."""
    # SAFETY: the ABI takes no pointers and returns exactly 0 or 1. The native
    # handler communicates only through its lock-free atomic activation cell.
    return external_call["mtest_exec_interrupt_requested", Int32]() != 0


def interrupt_count() -> Int:
    """Observed interrupt activations, saturating at 2 (0, 1, or escalate-2)."""
    # SAFETY: the ABI takes no pointers and returns exactly 0, 1, or 2 from the
    # native saturating atomic activation counter; it retains nothing.
    return Int(external_call["mtest_exec_interrupt_count", Int32]())


def _reset_interrupt():
    """Clear the native interrupt latch; absent from the production ABI."""
    # SAFETY: direct-test binaries link the isolated testing adapter object; the
    # function takes no pointer, retains nothing, and only clears sig_atomic_t.
    external_call["mtest_exec_test_reset_interrupt", NoneType]()


def _raise_self(signo: Int):
    """Deliver `signo` to this process for interrupt integration tests."""
    # SAFETY: libc `kill` has the exact ABI `int kill(pid_t, int)`, with `pid_t`
    # a 32-bit signed integer on both supported targets. Neither argument is a
    # pointer, so nothing is aliased, borrowed, or freed here: the target is this
    # live process's own id from the platform boundary, and the signal number is
    # supplied by the calling test. The call retains nothing past its return and
    # leaves no partial state to clean up on either the success or the error
    # path; the status is discarded because delivery to self cannot fail for the
    # signals the interrupt tests use.
    _ = external_call["kill", Int32](Int32(process_id()), Int32(signo))
