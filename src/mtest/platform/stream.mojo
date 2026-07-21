"""The raw streaming descriptor primitives: errno, write, create, close.

Part of the narrow platform-I/O boundary. A live-writing reporter cannot promote
its output atomically the way a whole-file writer can — it appends to a
descriptor as events arrive — so it needs the raw `write(2)`/`creat(2)`/
`close(2)` calls plus a reading of `errno` to tell a retryable interruption from
a real failure. The standard library expresses none of these with the exact
error semantics that caller needs: `FileDescriptor.write` returns nothing, so it
surfaces neither a short write nor the `errno` a partial-write loop must branch
on, and there is no stdlib wrapper for `creat`, `close`, or the thread-local
`errno` slot at the pinned toolchain. So these stay foreign calls, proven here
and shared, rather than redeclared in the report layer.

Each function returns the raw libc result and reads no policy into it. The
caller decides what a short write, a negative return, or a given `errno` means —
whether an `EINTR` is a retry or a failure, what exit code an open failure maps
to — because those are report-layer decisions, not platform facts.

The `write` declaration deliberately takes an opaque `NoneType` pointer and
returns `Int`, matching the standard library's own `write` external declaration
exactly. A second, differently-typed declaration of the same C symbol in one
binary is a link-time attribute conflict the toolchain rejects — the same trap
`tty.mojo` documents for `isatty` — so this reuses the stdlib's declaration
shape instead of shadowing it.
"""
from std.ffi import external_call
from std.sys.info import CompilationTarget

# Darwin's `mode_t` is UInt16; Linux's is UInt32. `creat` is a fixed-parameter
# call (unlike variadic `open(2)`), so its mode argument is passed by value in a
# register, and the exact width must be selected at compile time — Darwin arm64
# does not place a fixed argument in the variadic stack area.
comptime _CREATE_MODE = 0o644


def errno_now() -> Int:
    """Return the calling thread's current `errno`.

    Reads the thread-local `errno` slot through the platform accessor chosen at
    compile time: `__errno_location` on Linux (glibc), `__error` on Darwin. Call
    it immediately after a failed `write`, `creat`, or `close`, before anything
    else can overwrite the slot.

    Returns:
        The `errno` value. Allocates nothing and cannot fail.
    """
    comptime if CompilationTarget.is_macos():
        # SAFETY: Darwin libc `__error` has the ABI `int* __error(void)`. It
        # takes no argument, so there is no pointer to supply or alias, and it
        # returns a non-null pointer to this thread's private `errno` int that
        # stays valid for the lifetime of the thread — far longer than this
        # synchronous read. The pointer is owned by libc, never freed here, and
        # does not escape: it is dereferenced once, on the next line, to read a
        # live, correctly-typed, fully-initialized `int` (`errno` is always
        # initialized to 0 at thread start). No memory this process owns is
        # written, nothing is retained past the call, and there is no partial or
        # error path to clean up.
        var loc = external_call["__error", UnsafePointer[Int32, MutAnyOrigin]]()
        return Int(loc[])
    else:
        # SAFETY: Linux glibc `__errno_location` has the ABI
        # `int* __errno_location(void)`. It takes no argument, so there is no
        # pointer to supply or alias, and it returns a non-null pointer to this
        # thread's private `errno` int that stays valid for the lifetime of the
        # thread — far longer than this synchronous read. The pointer is owned
        # by glibc, never freed here, and does not escape: it is dereferenced
        # once, on the next line, to read a live, correctly-typed,
        # fully-initialized `int` (`errno` is always initialized to 0 at thread
        # start). No memory this process owns is written, nothing is retained
        # past the call, and there is no partial or error path to clean up.
        var loc = external_call[
            "__errno_location", UnsafePointer[Int32, MutAnyOrigin]
        ]()
        return Int(loc[])


def write_fd[o: Origin](fd: Int, ptr: UnsafePointer[UInt8, o], n: Int) -> Int:
    """Write up to `n` bytes at `ptr` to descriptor `fd`; return the raw result.

    The pointer is passed as an opaque byte pointer to match the stdlib's own
    `write` external declaration, so the symbol is not declared twice in one
    binary. This performs no retry and interprets no error: a short or negative
    return is the caller's to handle.

    Parameters:
        o: The origin of the byte buffer `ptr` points into.

    Args:
        fd: The destination descriptor.
        ptr: The first of `n` initialized bytes to write.
        n: How many bytes to write.

    Returns:
        The number of bytes written, which may be short of `n`, or a negative
        value on error with `errno` set. Allocates nothing.
    """
    # SAFETY: libc `write` has the ABI `ssize_t write(int, const void*, size_t)`.
    # `ptr` is a caller-owned pointer, borrowed for this call only, addressing
    # `n` initialized bytes that the caller guarantees outlive this synchronous
    # call; the caller owns and frees that buffer, not this function. The bitcast
    # to an opaque `NoneType` pointer only reinterprets the address to match the
    # stdlib's `write` declaration shape and reads no bytes itself. `write` reads
    # at most `n` bytes through the pointer and retains no reference past its
    # return, so nothing escapes; it writes no memory this process owns. `fd` is
    # a plain descriptor value, not a pointer. On both success and error the
    # result is a plain scalar the caller inspects; there is no allocation to
    # free and no partial state to unwind here.
    return external_call["write", Int](fd, ptr.bitcast[NoneType](), n)


@fieldwise_init
struct CreatResult(Copyable, Movable):
    """The outcome of a `create_truncate_fd` call: descriptor and captured errno.

    `err` is meaningful only when `fd` is negative; on success it is a filler
    `0` the caller must not consult. Bundling the two lets `create_truncate_fd`
    snapshot `errno` while it still owns the fresh error, before its transient
    C-string is freed, so a caller need not — and must not — re-read `errno`
    after the call, when an intervening `free` may already have clobbered it.
    """

    var fd: Int
    """The open descriptor, or a negative value on error."""
    var err: Int32
    """The `errno` captured at the failing `creat`; only valid when `fd < 0`."""


def create_truncate_fd(path: String) -> CreatResult:
    """Create or truncate `path` write-only; return the descriptor and errno.

    Wraps `creat(2)`, which opens `path` write-only, creating it with mode 0o644
    when absent and truncating it when present. Performs no error interpretation.
    On failure `creat` sets `errno`; this function snapshots it before releasing
    its transient C-string, because `free` is not guaranteed to preserve `errno`,
    and returns it in the result so the caller forms its message without a
    post-call `errno_now` read.

    Args:
        path: The destination file to create or truncate.

    Returns:
        A `CreatResult` whose `fd` is the open descriptor, or a negative value on
        error, and whose `err` holds the failing `creat`'s `errno` when `fd < 0`
        (a filler `0` on success). Allocates a transient C-string copy that is
        freed before returning.
    """
    var c = path.as_bytes()
    var terminated = List[UInt8]()
    for b in c:
        terminated.append(b)
    terminated.append(0)
    var fd: Int32
    comptime if CompilationTarget.is_macos():
        # SAFETY: Darwin libc `creat` has the fixed ABI
        # `int creat(const char*, mode_t)`, with `mode_t` a UInt16. `terminated`
        # is a complete, fully-initialized NUL-terminated byte copy this function
        # uniquely owns; nothing else references it, so its pointer does not
        # alias. It stays live across the call (it is consumed only after the
        # branch returns) and does not escape — `creat` reads the path bytes and
        # retains no pointer. The bytes read stop at the terminator, inside the
        # initialized region. The mode is a plain scalar. On both the success and
        # the error path the only owned resource is `terminated`, released when
        # it is consumed below; the returned fd, when non-negative, is owned by
        # the caller, not freed here.
        fd = external_call["creat", Int32](
            terminated.unsafe_ptr().bitcast[NoneType](), UInt16(_CREATE_MODE)
        )
    else:
        # SAFETY: Linux libc `creat` has the fixed ABI
        # `int creat(const char*, mode_t)`, with `mode_t` a UInt32. `terminated`
        # is a complete, fully-initialized NUL-terminated byte copy this function
        # uniquely owns; nothing else references it, so its pointer does not
        # alias. It stays live across the call (it is consumed only after the
        # branch returns) and does not escape — `creat` reads the path bytes and
        # retains no pointer. The bytes read stop at the terminator, inside the
        # initialized region. The mode is a plain scalar. On both the success and
        # the error path the only owned resource is `terminated`, released when
        # it is consumed below; the returned fd, when non-negative, is owned by
        # the caller, not freed here.
        fd = external_call["creat", Int32](
            terminated.unsafe_ptr().bitcast[NoneType](), UInt32(_CREATE_MODE)
        )
    # Snapshot `errno` while the failing `creat` is still the last syscall, before
    # `terminated^` frees the C-string: `free` may overwrite `errno`, so a read
    # after it could report a stale or zeroed value. On success `errno` is
    # meaningless, so it is only captured on the error branch.
    var err = errno_now() if fd < 0 else 0
    _ = terminated^
    return CreatResult(Int(fd), Int32(err))


def close_fd(fd: Int) -> Int:
    """Close descriptor `fd`; return the raw `close(2)` result.

    Performs no error interpretation: a signal-interrupted close still released
    the descriptor on Linux, and whether that or any other `errno` counts as a
    failure is the caller's decision.

    Args:
        fd: The descriptor to close.

    Returns:
        `0` on success, or a negative value on error with `errno` set. Allocates
        nothing.
    """
    # SAFETY: libc `close` has the ABI `int close(int)`. The single argument is
    # a plain descriptor value, not a pointer, so nothing is aliased, borrowed,
    # kept live, or freed here. The call retains nothing past its return and
    # writes no memory this process owns. The result is a plain scalar the caller
    # inspects; there is no partial state to unwind on either path.
    return Int(external_call["close", Int32](Int32(fd)))
