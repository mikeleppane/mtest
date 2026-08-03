"""The process-image replacement: `exec_replace`.

Part of the narrow platform-I/O boundary. Handing the terminal to a single
binary means becoming it rather than supervising it: only a process that
replaces its own image lets the target own the controlling terminal, the
process group, and the exit status with nothing in between.

`execv(2)` is POSIX and has a fixed parameter list on both supported targets,
so one declaration serves Linux and macOS. The variadic `execl` family is
deliberately avoided: `external_call` emits a non-variadic call, and on Darwin
arm64 a consumed variadic argument is then read from the wrong place, which
would silently hand the target garbage arguments.

The argument vector is built as a list of addresses rather than a list of
pointers because `UnsafePointer` is non-nullable at the pinned toolchain, so
the NULL terminator `execv` requires cannot be expressed as an element of a
pointer list at all.
"""
from std.ffi import external_call
from std.time import sleep

from mtest.platform.cstring import c_string_bytes
from mtest.platform.stream import errno_now

comptime _ETXTBSY = 26
"""`ETXTBSY`, identical on Linux and Darwin: the image is still open for writing.
"""

comptime _ETXTBSY_RETRIES = 5
"""Retries of an `ETXTBSY` exec, matching the process adapter's own budget."""

comptime _ETXTBSY_DELAY_MS = 50
"""Pause between `ETXTBSY` retries, matching the process adapter's own delay."""


def _nul_position(value: String) -> Int:
    """Return the index of the first NUL byte in `value`, or `-1` if there is none.

    Args:
        value: The string to scan. Not mutated.

    Returns:
        The byte index of the first `0`, or `-1`. Allocates nothing.
    """
    var bytes = value.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == 0:
            return i
    return -1


def exec_replace(binary: String, argv: List[String]) raises:
    """Replace this process with `binary`, passing `argv` unchanged.

    On success this function never returns: the calling image is gone, and what
    runs on keeps this process id, its parent, its process group, its session
    and controlling terminal, the signal mask, and every open descriptor that
    is not marked `FD_CLOEXEC` — descriptors that are close on exec, including
    any the process adapter opened, are gone. Dispositions follow POSIX rather
    than intuition: a caught signal resets to `SIG_DFL`, while an IGNORED one
    survives. The process adapter's runtime ignores `SIGPIPE` for its lifetime,
    so a caller that still has it open hands the target an inherited
    `SIG_IGN` for `SIGPIPE`; shut that runtime down before calling this if the
    target must see the default disposition.

    A freshly written image can still be open for writing when the exec is
    attempted, which POSIX reports as `ETXTBSY`. That case is retried on a
    short fixed backoff, matching what the process adapter does for its own
    children; every other errno fails immediately.

    Allocates one NUL-terminated byte copy of the path, one per argument, and
    the address vector itself; all of them are released on the failure return.

    Args:
        binary: Path to the executable image; may not contain a NUL byte.
            Not mutated.
        argv: The complete argument vector, `argv[0]` included; never empty,
            and no element may contain a NUL byte. Not mutated.

    Raises:
        Error: If `argv` is empty, if `binary` or any argument carries a NUL
            byte, or if `execv` returned at all — which it does only on
            failure — carrying the path and the failing `errno`.
    """
    if len(argv) == 0:
        raise Error("exec: empty argv")
    # A C string ends at its first NUL, so a Mojo string carrying an interior
    # one would exec a DIFFERENT file than the caller named, or hand the target
    # a silently truncated argument. Both are refused here rather than
    # truncated, before anything is converted or called.
    var at = _nul_position(binary)
    if at >= 0:
        raise Error("exec: NUL byte in the binary path at byte " + String(at))
    for i in range(len(argv)):
        at = _nul_position(argv[i])
        if at >= 0:
            raise Error(
                "exec: NUL byte in argv["
                + String(i)
                + "] at byte "
                + String(at)
            )
    var cbin = c_string_bytes(binary)
    var carg = List[List[UInt8]]()
    for a in argv:
        carg.append(c_string_bytes(a))
    var addrs = List[UInt]()
    for i in range(len(carg)):
        # SAFETY: laundering an argument's address through an integer drops it
        # out of Mojo's lifetime tracking, so validity is argued here instead.
        # `carg[i]` is a heap buffer this frame uniquely owns and nothing else
        # references, so no address taken here aliases another, and the element
        # is live and fully initialized when its address is read. What the
        # address must survive is not the outer list moving — reallocating
        # `carg` relocates the element structs but never their heap buffers —
        # but the ELEMENT being destroyed, cleared, reassigned, or appended to;
        # no statement below does any of those, and the `carg^` transfer after
        # the call is what defers destruction of every element past `execv`
        # rather than letting the list die at its last ordinary use. Both
        # supported targets (linux-64 and osx-arm64) are LP64, where `UInt` is
        # a 64-bit word with the size and alignment of `char*`, so each address
        # round-trips through `UInt` without truncation and the accumulated
        # contiguous `UInt` array has exactly the layout of the
        # `char *const []` the callee indexes.
        addrs.append(UInt(Int(carg[i].unsafe_ptr())))
    addrs.append(UInt(0))
    var err: Int
    var retries = 0
    while True:
        # SAFETY: libc `execv` has the fixed ABI
        # `int execv(const char*, char* const argv[])` on both supported
        # targets, so the one declaration emitted here matches each of them.
        # `cbin` is a private, fully-initialized byte copy this frame uniquely
        # owns, and both it and `addrs` are kept live across every iteration by
        # the transfers below, which defer their destruction past the loop;
        # `addrs` holds exactly the still-valid element addresses argued for
        # above, in order, followed by the `0` appended before the loop — the
        # all-zero-bits null pointer that terminates a `char *const argv[]`,
        # which has to be written as an integer because `UnsafePointer` is
        # non-nullable at the pinned toolchain. Both pointers address complete
        # NUL-terminated data: `c_string_bytes` appends the terminator, and no
        # interior NUL can appear because every string was rejected above, so
        # each read stops at the intended terminator inside the initialized
        # region. Nothing escapes — on success the kernel has already copied
        # both vectors into the new image and this frame no longer exists; on
        # failure `execv` retains no pointer and writes no memory this process
        # owns, leaving the three lists as the only owned resources, freed by
        # their own destructors when this function raises.
        _ = external_call["execv", Int32](cbin.unsafe_ptr(), addrs.unsafe_ptr())
        # Snapshot `errno` while the failed `execv` is still the last call: any
        # allocation or string formatting in between could overwrite the slot.
        err = errno_now()
        if err != _ETXTBSY or retries >= _ETXTBSY_RETRIES:
            break
        retries += 1
        sleep(Float64(_ETXTBSY_DELAY_MS) / 1000.0)
    _ = cbin^
    _ = carg^
    _ = addrs^
    raise Error(
        "exec: execv failed for '" + binary + "' (errno " + String(err) + ")"
    )
