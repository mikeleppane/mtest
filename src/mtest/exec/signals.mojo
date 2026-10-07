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

from mtest.platform import FfiRecord, process_id


comptime ERROR_BYTES = 32
"""Size of ABI-v1 `struct mtest_exec_error` (alignment 8)."""


def native_error(prefix: String, error: FfiRecord) -> String:
    """Render a native error record, keeping any cleanup failure.

    ABI-v1 fixes the primary operation/errno at UInt32/Int32 fields 0/1 and the
    cleanup operation/errno at fields 2/3. A nonzero cleanup operation means
    the rollback failed too, and is appended to the message.

    Args:
        prefix: The machinery-error label, e.g. `exec: poll failed`.
        error: The record a failing native call initialized.

    Returns:
        The named error message.
    """
    var message = (
        prefix
        + " (operation "
        + String(error.load[UInt32](0))
        + ", errno "
        + String(error.load[Int32](1))
        + ")"
    )
    var cleanup_operation = error.load[UInt32](2)
    if cleanup_operation != 0:
        message += (
            "; cleanup operation "
            + String(cleanup_operation)
            + " failed with errno "
            + String(error.load[Int32](3))
        )
    return message^


struct ExecRuntime(Movable):
    """Exclusive ownership of mtest's process-global exec and signal state.

    Materialize once around a session or direct supervision group, call
    `open()`, pass it by mutable borrow to child operations, then call `close()`
    explicitly. A second simultaneously active instance raises `EBUSY` through
    the native error record. Sequential open/use/close cycles are supported.

    Examples:

    ```mojo
    from mtest.exec import ExecRuntime
    from mtest.exec import ProcessSpec
    from mtest.exec import run_supervised

    var runtime = ExecRuntime()
    runtime.open()
    var result = run_supervised(runtime, ProcessSpec.command(["/bin/true"]))
    runtime.close()
    ```
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
        var error = FfiRecord(bytes=ERROR_BYTES)
        # SAFETY: `error` is a complete zeroed ABI-v1 error record that outlives
        # this synchronous call; `mtest_exec_runtime_open` does not retain it.
        var result = external_call["mtest_exec_runtime_open", Int32](
            error.ptr()
        )
        if result != 0:
            # A nonzero cleanup operation on runtime-open means native state is
            # RESTORE_REQUIRED and this live token must own the explicit
            # restoration retry.
            if error.load[UInt32](2) != 0:
                self.active = True
            raise Error(native_error("exec: runtime open failed", error))
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
        var error = FfiRecord(bytes=ERROR_BYTES)
        # SAFETY: `error` is a complete zeroed ABI-v1 error record that outlives
        # this synchronous call; the close call writes but never retains it.
        var result = external_call["mtest_exec_runtime_close", Int32](
            error.ptr()
        )
        if result != 0:
            # `self.active` stays true for an explicit retry.
            raise Error(native_error("exec: runtime close failed", error))
        self.active = False

    def __deinit__(deinit self):
        """Last-resort restoration; explicit `close()` is required."""
        if not self.active:
            return
        var error = FfiRecord(bytes=ERROR_BYTES)
        # SAFETY: as in `close`. Failure cannot be raised from a destructor;
        # explicit close is the only success-reporting path.
        _ = external_call["mtest_exec_runtime_close", Int32](error.ptr())


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
