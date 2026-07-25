"""Bounded reads from opened regular-file descriptors.

Part of the narrow platform-I/O boundary. The path is opened nonblocking and
close-on-exec before its file type is inspected, so a pathname replacement
cannot turn a prior regular-file check into a blocking FIFO or device read.
"""
from std.ffi import external_call
from std.memory import Span, alloc, memset_zero
from std.sys.info import CompilationTarget

from mtest.platform.cstring import c_string_bytes
from mtest.platform.stream import close_fd, errno_now, read_fd


comptime _EINTR = 4
comptime _STAT_BYTES = 144
comptime _S_IFMT = 0o170000
comptime _S_IFREG = 0o100000


@fieldwise_init
struct BoundedRegularFileRead(Copyable, Movable):
    """The bounded bytes and opened-descriptor regular-file verdict."""

    var is_regular: Bool
    """Whether the opened descriptor identified a regular file."""
    var text: String
    """At most the requested byte limit plus one, copied into owned UTF-8."""


def _open_read_flags() -> Int32:
    comptime if CompilationTarget.is_macos():
        comptime assert (
            not CompilationTarget.is_x86()
        ), "platform regular-file reads support macOS arm64 only"
        return Int32(0x4 | 0x1000000)
    else:
        comptime assert (
            CompilationTarget.is_linux()
        ), "platform regular-file reads support Linux or macOS only"
        comptime assert (
            CompilationTarget.is_x86()
        ), "platform regular-file reads support Linux x86_64 only"
        return Int32(0o4000 | 0o2000000)


def _opened_mode(
    storage: UnsafePointer[UInt64, MutUntrackedOrigin],
) -> Int:
    comptime if CompilationTarget.is_macos():
        comptime assert (
            not CompilationTarget.is_x86()
        ), "platform regular-file reads support macOS arm64 only"
        # SAFETY: the caller supplies 144 initialized bytes aligned to 8 that
        # `fstat` has filled as Darwin arm64 `struct stat`. Darwin's `st_mode`
        # is a fully initialized UInt16 at byte offset 4. Adding four stays
        # within the allocation and preserves the two-byte alignment required
        # by UInt16; the typed pointer is read once while `storage` is live and
        # does not escape. The caller retains and frees the allocation.
        return Int((storage.bitcast[UInt8]() + 4).bitcast[UInt16]()[0])
    else:
        comptime assert (
            CompilationTarget.is_linux()
        ), "platform regular-file reads support Linux or macOS only"
        comptime assert (
            CompilationTarget.is_x86()
        ), "platform regular-file reads support Linux x86_64 only"
        # SAFETY: the caller supplies 144 initialized bytes aligned to 8 that
        # `fstat` has filled as Linux x86_64 `struct stat`. Linux's `st_mode`
        # is a fully initialized UInt32 at byte offset 24, which is element six
        # of this aligned UInt32 view. The read stays inside the allocation,
        # the pointer remains live and local, and the caller owns and frees it.
        return Int(storage.bitcast[UInt32]()[6])


def read_bounded_regular_file(
    path: String, max_bytes: Int
) raises -> BoundedRegularFileRead:
    """Open, validate, and read at most `max_bytes + 1` bytes from `path`.

    Args:
        path: The selected configuration pathname. Symlinks are followed.
        max_bytes: The accepted payload ceiling, which must be nonnegative.

    Returns:
        An opened-descriptor regular-file verdict and owned UTF-8 text. A
        regular file returns at most `max_bytes + 1` bytes so the caller can
        distinguish an exact-boundary file from an oversized one.

    Raises:
        Error: If open, fstat, read, close, allocation, or UTF-8 validation
            fails. Every successfully opened descriptor is closed first.
    """
    if max_bytes < 0:
        raise Error("platform: bounded read requires a nonnegative limit")
    var path_bytes = c_string_bytes(path)
    var raw_fd: Int32
    var open_errno = 0
    while True:
        # SAFETY: libc `open` has ABI `int open(const char*, int, ...)`. Neither
        # O_CREAT nor O_TMPFILE is present, and the ignored zero mode matches
        # the stdlib's declaration. `path_bytes` uniquely owns a complete,
        # initialized NUL-terminated copy with a concrete local origin; it is
        # live across this synchronous call and libc neither retains nor frees
        # it. The guarded flags are O_RDONLY|O_NONBLOCK|O_CLOEXEC, so a swapped
        # FIFO cannot block and the descriptor cannot cross exec. Failure owns
        # no descriptor; success transfers exactly one descriptor here.
        raw_fd = external_call["open", Int32](
            path_bytes.unsafe_ptr().bitcast[NoneType](),
            _open_read_flags(),
            UInt32(0),
        )
        if raw_fd >= 0:
            break
        open_errno = errno_now()
        if open_errno != _EINTR:
            break
    _ = path_bytes^
    if raw_fd < 0:
        raise Error(
            "platform: could not open regular file '"
            + path
            + "' (errno "
            + String(open_errno)
            + ")"
        )
    var fd = Int(raw_fd)

    # SAFETY: `alloc[UInt64](18)` owns exactly 144 bytes aligned to 8, enough
    # for `struct stat` on both guarded targets. `memset_zero` initializes the
    # complete allocation before any foreign write or Mojo read. The pointer's
    # concrete mutable origin stays local and live until every mode read is
    # complete, and this function frees it on every path below.
    var stat_storage = alloc[UInt64](_STAT_BYTES // 8)
    memset_zero(stat_storage.bitcast[UInt8](), _STAT_BYTES)
    var stat_rc: Int32
    var stat_errno = 0
    while True:
        # SAFETY: libc `fstat` has ABI `int fstat(int, struct stat*)`. `fd` is
        # live; `stat_storage` is 144 initialized writable bytes aligned to 8,
        # exactly the guarded target's struct size. The synchronous call writes
        # only that region, retains no pointer, and owns neither resource. Both
        # remain owned here after failure; success initializes `st_mode`
        # according to the compile-time-selected ABI layout.
        stat_rc = external_call["fstat", Int32](
            Int32(fd), stat_storage.bitcast[NoneType]()
        )
        if stat_rc == 0:
            break
        stat_errno = errno_now()
        if stat_errno != _EINTR:
            break
    if stat_rc != 0:
        # SAFETY: this is the sole owner of the 144-byte allocation; `fstat`
        # returned and retained no pointer, no view exists, and no later path
        # can access or free the storage after this raising branch.
        stat_storage.free()
        # Inspect close to discharge ownership, but preserve fstat's primary
        # errno deterministically if cleanup also reports an error.
        var close_rc = close_fd(fd)
        _ = close_rc
        raise Error(
            "platform: fstat failed for '"
            + path
            + "' (errno "
            + String(stat_errno)
            + ")"
        )
    var mode = _opened_mode(stat_storage)
    # SAFETY: `_opened_mode` completed its one bounded read and retained no
    # pointer. This is the allocation's sole owner and frees it exactly once;
    # only the copied scalar `mode` remains live afterward.
    stat_storage.free()
    if mode & _S_IFMT != _S_IFREG:
        if close_fd(fd) != 0:
            raise Error("platform: close failed after regular-file validation")
        return BoundedRegularFileRead(False, "")

    var capacity = max_bytes + 1
    # SAFETY: `capacity` is positive because `max_bytes` is nonnegative. This
    # allocation owns exactly `capacity` writable UInt8 slots with a concrete
    # mutable origin. No byte is read until `read_fd` reports it initialized;
    # the pointer remains live through all synchronous reads and UTF-8 copying,
    # never escapes, and is freed on every success or error path below.
    var buffer = alloc[UInt8](capacity)
    var total = 0
    while total < capacity:
        # SAFETY: `total` is in `[0, capacity)`, so this pointer addresses the
        # first uninitialized byte and `capacity - total` is exactly the
        # writable remainder. `read_fd` initializes at most that many bytes,
        # retains no pointer, and reports the initialized count before Mojo
        # inspects any content. The allocation and descriptor remain owned here.
        var count = read_fd(fd, buffer + total, capacity - total)
        if count < 0:
            var read_errno = errno_now()
            if read_errno == _EINTR:
                continue
            # SAFETY: this is the buffer's sole owner; the failed synchronous
            # read retained no pointer, no byte view exists, and this raising
            # branch prevents any later access or second free.
            buffer.free()
            # Inspect close to discharge ownership, but preserve read's primary
            # errno deterministically if cleanup also reports an error.
            var close_rc = close_fd(fd)
            _ = close_rc
            raise Error(
                "platform: read failed for '"
                + path
                + "' (errno "
                + String(read_errno)
                + ")"
            )
        if count == 0:
            break
        if count > capacity - total:
            # SAFETY: this is the buffer's sole owner and `read_fd` retained no
            # pointer. No view was constructed, and the raising branch makes
            # this the allocation's only free with no subsequent access.
            buffer.free()
            var close_rc = close_fd(fd)
            _ = close_rc
            raise Error("platform: read reported impossible progress")
        total += count

    if close_fd(fd) != 0:
        # SAFETY: descriptor cleanup does not borrow the buffer. This is its
        # sole owner, no view exists, and the raising branch prevents reuse or
        # a second free after the allocation is released.
        buffer.free()
        raise Error("platform: close failed after bounded regular-file read")
    var text: String
    try:
        # SAFETY: the read loop initialized exactly bytes `[0, total)` in the
        # still-live allocation and `total <= capacity`. `Span` preserves that
        # precise bound. `StringSlice(from_utf8=...)` validates UTF-8 and
        # `String` copies it before `buffer` is freed; neither view escapes.
        var initialized = Span(ptr=buffer, length=total)
        text = String(StringSlice(from_utf8=initialized))
    except:
        # SAFETY: UTF-8 validation retained no pointer when it raised. The
        # temporary span cannot escape the `try`, this is the buffer's sole
        # owner, and the raising branch prevents access or a second free.
        buffer.free()
        raise Error("platform: regular file is not valid UTF-8")
    # SAFETY: `String` copied all `total` validated bytes and retained no view.
    # This is the buffer's sole owner and final use, so freeing exactly once
    # leaves only the independent owned `text`.
    buffer.free()
    return BoundedRegularFileRead(True, text^)
