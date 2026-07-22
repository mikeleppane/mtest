"""The process-identity probe: `process_id`.

Part of the narrow platform-I/O boundary. `getpid(2)` has no standard-library
wrapper at the pinned toolchain — `std.os` offers `getuid` but nothing that
answers for the calling process — so it stays one raw foreign call, proven once
here and reused, rather than redeclared in each module that wants it.

Callers want it as a nonce. Two mtest processes over one checkout, which
`--shard` makes plausible, must never collide on a disposable path one of them
is still writing. The process id is stable within a run and distinct across
concurrent runs, so it keys each invocation's scratch apart.
"""
from std.ffi import external_call


def process_id() -> Int:
    """Return this process's id.

    Returns:
        The value of `getpid(2)`, always positive. Allocates nothing, mutates
        nothing, and cannot fail.
    """
    # SAFETY: libc `getpid` has the exact ABI `pid_t getpid(void)`, and `pid_t`
    # is a 32-bit signed integer on both supported targets (linux-64 and
    # osx-arm64), which is what the declared `Int32` return type encodes. The
    # call takes no arguments, so there is no pointer to provide, alias, keep
    # live, or free, and nothing can escape it. It reads kernel-held process
    # state only: it writes no memory this process owns and retains nothing past
    # the call. POSIX specifies no error condition for `getpid`, so there is no
    # failure, timeout, or partial path to clean up after; the result is a plain
    # scalar with no ownership obligation.
    return Int(external_call["getpid", Int32]())
