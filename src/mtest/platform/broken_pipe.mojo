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

`direct_write_failed` is the other half of that policy, and the reason the two
live together: absorbing a departed consumer is only correct because every
OTHER errno means the output was not delivered and no consumer chose that. A
closed descriptor or a full filesystem is a failure the command must report,
not a reader that walked away. `departed_consumer` is where "the reader went
away" is spelled out, so the ignored set is stated once — it is `EPIPE` on a
pipe and `ECONNRESET` on a stream socket, which are one event over two
transports.

`signal(2)` rather than `sigaction(2)`, and here rather than behind the native
ABI, because the only disposition installed is the constant `SIG_IGN`: there is
no handler function to recover a code pointer from, no `sigaction` layout to
reproduce per platform, and nothing that runs between a fork and an exec. Those
are the three hazards that put every other signal decision in `native/`.
"""
from std.ffi import external_call
from std.sys.info import CompilationTarget


comptime _SIGPIPE = 13
"""`SIGPIPE`, 13 on both Linux and Darwin."""

comptime _SIG_IGN = 1
"""`SIG_IGN`, the handler sentinel `(void (*)(int)) 1` on both platforms."""

comptime EPIPE = 32
"""`EPIPE`, 32 on both Linux and Darwin: the read end of the pipe is gone."""


comptime ECONNRESET = 54 if CompilationTarget.is_macos() else 104
"""`ECONNRESET`: the peer of a stream socket reset the connection.

Unlike `EPIPE` this one is NOT the same number on both platforms. Linux takes
it from `asm-generic/errno.h` (104); Darwin keeps the 4.4BSD numbering, where
the socket errnos start at `ENOTSOCK` 38 and reach `ECONNRESET` at 54. Selected
at compile time for the same reason `creat`'s `mode_t` width is.
"""


def departed_consumer(err: Int) -> Bool:
    """Whether `err` says the reader went away rather than the write failed.

    Two errnos mean it. `EPIPE` is a pipe whose read end closed. `ECONNRESET`
    is the same event one transport down: a stream socket whose peer reset the
    connection, which is what `mtest --help` writing to a socket-activated or
    `ssh`-forwarded stdout sees. §9's carve-out is about a consumer that chose
    to stop reading, and both of these are exactly that.

    Args:
        err: A `write_all_bytes_fd_status` result, or any raw `errno`.

    Returns:
        True when the failure is a departed consumer. Allocates nothing.
    """
    return err == EPIPE or err == ECONNRESET


def direct_write_failed(status: Int) -> Bool:
    """Whether a direct write's status is a failure its command must report.

    The one statement of the policy, so no caller re-derives it. A departed
    consumer is not a failure: the rest of the output is lost and nothing else
    changes, which is what lets `mtest --help | head -1` still exit 0. Every
    other nonzero status — a closed descriptor, a full filesystem, a write that
    made no progress — means the command's output was not delivered.

    Args:
        status: A `write_all_bytes_fd_status` result: `0`, an `errno`, or `-1`.

    Returns:
        True when the caller must treat the write as undelivered. Allocates
        nothing and cannot fail.

    Examples:

    ```mojo
    from mtest.platform import EPIPE, direct_write_failed

    print(direct_write_failed(EPIPE))  # False: the consumer left
    print(direct_write_failed(28))  # True: ENOSPC, nothing was written
    ```
    """
    return status != 0 and not departed_consumer(status)


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
