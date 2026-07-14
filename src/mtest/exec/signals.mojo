"""The interrupt primitive: SIGINT/SIGTERM handlers over a latching flag (L3).

`install_signal_handlers` installs async-signal-safe SIGINT and SIGTERM handlers
via `sigaction`; each handler does nothing but set a process-wide flag.
`interrupt_requested` reads that flag, and the supervision loop polls it so an
interrupt group-kills the active child promptly instead of waiting out the
deadline. Once set the flag LATCHES — an interrupt is not forgotten.

The flag needs storage a bare C handler can reach, and this toolchain has no
module-global `var` (and its `_Global` helper miscompiles), so the flag lives in
a one-page anonymous mapping at a fixed, compile-time address. Anonymous pages
are zero-filled, so the flag reads False until a handler fires — which makes
reading it safe even when no handlers were installed. All of this is confined
here; callers see only the two functions.
"""
from std.ffi import external_call
from std.memory import UnsafePointer, memset_zero, alloc

comptime _FLAG_ADDR = 0x100000000000
"""A fixed high address for the one-page interrupt-flag mapping."""

comptime _SIGINT = 2
comptime _SIGTERM = 15

# mmap: PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE.
comptime _PROT_RW = 0x3
comptime _MAP_FLAGS = 0x2 | 0x20 | 0x100000
comptime _MAP_FAILED = 0xFFFFFFFFFFFFFFFF

# sigaction: a fixed struct buffer (>= the 152-byte glibc layout) whose first 8
# bytes hold the handler code pointer; glibc fills the restorer itself.
comptime _SA_SIZE = 160
comptime _SA_RESTART = 0x10000000


def _flag_ptr() -> UnsafePointer[Int32, MutAnyOrigin]:
    """A pointer to the interrupt flag cell. Pure."""
    return UnsafePointer[Int32, MutAnyOrigin](unsafe_from_address=_FLAG_ADDR)


def _ensure_flag_page() raises:
    """Map the flag page if it is not already mapped; leave the flag untouched.

    The mapping is anonymous, so a fresh page reads zero. Idempotent: a second
    call finds the page present and returns. Raises only if a fixed mapping at
    the chosen address is impossible.

    Raises:
        Error: `exec: could not map interrupt flag page` if mmap places the page
            at an unexpected address on this kernel.
    """
    var addr = external_call["mmap", UInt64](
        UInt64(_FLAG_ADDR),
        UInt64(4096),
        Int32(_PROT_RW),
        Int32(_MAP_FLAGS),
        Int32(-1),
        Int64(0),
    )
    if addr == UInt64(_FLAG_ADDR):
        # Freshly mapped and zero-filled.
        return
    if addr == UInt64(_MAP_FAILED):
        # Already mapped by a prior call (EEXIST) — reuse it.
        return
    # An unexpected placement: undo it and fail loudly.
    _ = external_call["munmap", Int32](addr, UInt64(4096))
    raise Error("exec: could not map interrupt flag page")


def _on_interrupt(signo: Int32):
    """The installed handler: set the latching flag and return. Async-safe."""
    _flag_ptr()[0] = 1


def _install_one(
    signo: Int32,
    act: UnsafePointer[UInt8, MutUntrackedOrigin],
    old: UnsafePointer[UInt8, MutUntrackedOrigin],
):
    """Install `_on_interrupt` for `signo` via the prepared sigaction buffer."""
    # The function value is itself the code pointer; taking its address yields a
    # stack slot holding it, so read that slot to get the real entry address.
    act.bitcast[UInt64]()[0] = UnsafePointer(to=_on_interrupt).bitcast[
        UInt64
    ]()[0]
    _ = external_call["sigaction", Int32](signo, act, old)


def install_signal_handlers() raises:
    """Install SIGINT and SIGTERM handlers that set the latching interrupt flag.

    Maps the flag page if needed, then installs an async-signal-safe handler for
    both signals via `sigaction`. Safe to call once at startup; the handlers only
    set the flag, so they do no work that is unsafe in signal context.

    Raises:
        Error: `exec: could not map interrupt flag page` if the flag page cannot
            be mapped.
    """
    _ensure_flag_page()
    var act = alloc[UInt8](_SA_SIZE)
    memset_zero(act, _SA_SIZE)
    var old = alloc[UInt8](_SA_SIZE)
    memset_zero(old, _SA_SIZE)
    # sa_flags lives at byte offset 136 on the glibc linux-64 layout (136/4=34).
    act.bitcast[Int32]()[34] = Int32(_SA_RESTART)
    _install_one(Int32(_SIGINT), act, old)
    _install_one(Int32(_SIGTERM), act, old)
    act.free()
    old.free()


def interrupt_requested() -> Bool:
    """Whether an interrupt (SIGINT/SIGTERM) has been requested since startup.

    Reads the latching flag; ensures the flag page exists first so it is safe to
    call even when no handlers were installed (in which case it reads False).
    Does not mutate; does not raise in practice (the page map is idempotent).
    """
    try:
        _ensure_flag_page()
    except:
        return False
    return _flag_ptr()[0] != 0


def _reset_interrupt() raises:
    """Clear the latched interrupt flag. For tests and re-arming; not public."""
    _ensure_flag_page()
    _flag_ptr()[0] = 0


def _raise_self(signo: Int):
    """Send signal `signo` to our own process. For the self-signal test; internal.
    """
    var pid = external_call["getpid", Int32]()
    _ = external_call["kill", Int32](pid, Int32(signo))
