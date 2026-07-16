"""Exclusive process-global interrupt/runtime ownership (Layer 3).

`ExecRuntime` is the non-copyable token that owns mtest's saved SIGINT and
SIGTERM dispositions. The native adapter uses the platform's own headers and a
`volatile sig_atomic_t` latch; Mojo never lays out `struct sigaction`, invents a
callback pointer, maps a fixed address, or reads libc's private errno storage.

Construction is transactional and rejects a second active runtime. `close()` is
explicit and fallible so restoration failure can never be reported as success.
The destructor is only a last-resort retry for exceptional unwinding; callers
must use `close()` on every ordinary path.
"""
from std.ffi import external_call
from std.memory import alloc, memset_zero


comptime _ERROR_BYTES = 32
"""Size of ABI-v1 `struct mtest_exec_error` (alignment 8)."""


def _runtime_error(prefix: String, operation: Int, error_number: Int) -> Error:
    """Build one named native-runtime machinery error. Allocates."""
    return Error(
        prefix
        + " (operation "
        + String(operation)
        + ", errno "
        + String(error_number)
        + ")"
    )


struct ExecRuntime(Movable):
    """Exclusive ownership of mtest's process-global exec/signal state.

    Construct once around a session or direct supervision group, pass it by
    mutable borrow to child operations, and call `close()` explicitly. A second
    simultaneously active instance raises `EBUSY` through the native error
    record. Sequential construct/use/close cycles are supported.
    """

    var active: Bool
    """Whether this token still owns the native runtime."""

    def __init__(out self) raises:
        """Transactionally install native interrupt handlers and take ownership.

        Raises:
            Error: A named `exec: runtime open failed` machinery error containing
                the adapter operation and errno.
        """
        self.active = False
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
            # before returning. ABI-v1 fixes operation at byte 0 and errno at 4.
            var operation = Int(error.bitcast[UInt32]()[0])
            var error_number = Int(error.bitcast[Int32]()[1])
            # SAFETY: `error` is still the unique allocation owner and C did not
            # retain it; this frees it exactly once before the raising path.
            error.free()
            raise _runtime_error(
                "exec: runtime open failed", operation, error_number
            )
        # SAFETY: `error` remains uniquely owned and non-escaping after the
        # successful non-retaining ABI call; free it exactly once.
        error.free()
        self.active = True

    def close(mut self) raises:
        """Restore saved dispositions and release runtime ownership explicitly.

        Idempotent after success. On restoration failure the token remains
        active so the caller can report the error and retry; a new child/runtime
        remains rejected by the native state machine.

        Raises:
            Error: A named `exec: runtime close failed` machinery error containing
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
            # operation and errno at the first two 32-bit slots.
            var operation = Int(error.bitcast[UInt32]()[0])
            var error_number = Int(error.bitcast[Int32]()[1])
            # SAFETY: the non-retained allocation still has one owner; free once
            # while leaving `self.active` true for an explicit retry.
            error.free()
            raise _runtime_error(
                "exec: runtime close failed", operation, error_number
            )
        # SAFETY: successful close did not retain the uniquely-owned record.
        error.free()
        self.active = False

    def __del__(deinit self):
        """Best-effort last-resort restoration; explicit `close()` is required.
        """
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
    """Whether SIGINT or SIGTERM has latched since runtime construction."""
    # SAFETY: the ABI takes no pointers and returns exactly 0 or 1. The native
    # handler communicates only through its `volatile sig_atomic_t` cell.
    return external_call["mtest_exec_interrupt_requested", Int32]() != 0


def _reset_interrupt():
    """Clear the native interrupt latch. Test-only; absent from production ABI.
    """
    # SAFETY: direct-test binaries link the isolated testing adapter object; the
    # function takes no pointer, retains nothing, and only clears sig_atomic_t.
    external_call["mtest_exec_test_reset_interrupt", NoneType]()


def _raise_self(signo: Int):
    """Deliver `signo` to this process for interrupt integration tests."""
    # SAFETY: `getpid` has no arguments and returns the current pid; `kill` takes
    # that live pid plus the test's valid signal number and retains no pointer.
    var pid = external_call["getpid", Int32]()
    _ = external_call["kill", Int32](pid, Int32(signo))
