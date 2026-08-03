"""The broken-pipe disposition: make a write to a closed pipe report `EPIPE`.

Part of the narrow platform-I/O boundary. A command that writes its whole
output straight to a descriptor — help, version, the doctor lines, the
scaffolding lines, the resolved configuration, the `collect` listing — has no
reporter and no exec runtime standing between it and the pipe. With the default
`SIGPIPE` disposition a consumer that stops reading (`mtest collect | head -1`)
therefore kills the writer at signal 13, which a shell reports as 141: a status
in no command's documented exit domain, for a command that produced everything
it was asked for.

Ignoring `SIGPIPE` turns that death into an `EPIPE` return the writer absorbs,
which is what lets each command exit with a code its own domain defines. The
`exec` runtime installs the same carve-out through the native adapter for its
own lifetime; this is the carve-out for the commands that never open one.

`signal(2)` rather than `sigaction(2)`, and here rather than behind the native
ABI, because the only disposition installed is the constant `SIG_IGN`: there is
no handler function to recover a code pointer from, no `sigaction` layout to
reproduce per platform, and nothing that runs between a fork and an exec. Those
are the three hazards that put every other signal decision in `native/`.
"""
from std.ffi import external_call


comptime _SIGPIPE = 13
"""`SIGPIPE`, 13 on both Linux and Darwin."""

comptime _SIG_IGN = 1
"""`SIG_IGN`, the handler sentinel `(void (*)(int)) 1` on both platforms."""


def ignore_broken_pipe():
    """Set this process's `SIGPIPE` disposition to `SIG_IGN`.

    Idempotent, and safe to call when the disposition is already ignored: the
    call installs a constant and discards what was there. Nothing restores it,
    because a restore would fight the exec runtime for the same setting; the
    runtime saves and restores around its own lifetime, and every caller here
    is a command that writes and exits without forking. Allocates nothing, and
    cannot fail for a valid signal number.
    """
    # SAFETY: libc `signal` has the ABI
    # `void (*signal(int, void (*)(int)))(int)`. Both arguments are compile-time
    # constants: `SIGPIPE` is a valid signal number on Linux and Darwin alike,
    # and `SIG_IGN` is the libc-defined sentinel `(void (*)(int)) 1`, a value
    # libc compares against and never calls, so no code is ever entered through
    # it and its address is never dereferenced by anyone. No memory this process
    # owns is passed, borrowed, retained, or freed, so there is no provenance,
    # lifetime, bounds, or alignment obligation to discharge. The returned
    # previous disposition is a code address libc owns; it is discarded without
    # being read. The call is atomic — it installs the disposition or returns
    # `SIG_ERR`, reachable only for an invalid signal number and so not for this
    # constant — leaving no partial state on any path. It runs in the parent
    # process only, never between a fork and an exec.
    _ = external_call["signal", UnsafePointer[NoneType, MutAnyOrigin]](
        Int32(_SIGPIPE),
        UnsafePointer[NoneType, MutAnyOrigin](unsafe_from_address=_SIG_IGN),
    )
