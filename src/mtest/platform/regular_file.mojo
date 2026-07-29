"""Bounded reads from opened regular-file descriptors.

Part of the narrow platform-I/O boundary (Layer 0). The path is opened
nonblocking and close-on-exec before its file type is inspected, so a pathname
replacement cannot turn a prior regular-file check into a blocking FIFO or
device read.

Two readers sit on one core. `read_bounded_regular_file` decodes UTF-8 and is
what the config and state readers want; `read_regular_file_bytes` hands back the
raw bytes and is what a cache digest wants, because a compiled binary is not
text. They share `_read_opened_regular_file_bytes`, which owns the descriptor
lifetime and the single `open`/`fstat`/`read` declaration shape this binary
emits for those symbols — a second shape for any of them is a link-time
conflict raised from an unrelated file.

`fsync_path` sits beside them because it needs exactly the same open: it flushes
a path rather than reading it, which the build cache's publication protocol
needs for the binary, its record, and their containing directory before the one
rename that commits them. It reuses the same three-argument `open` shape and
adds the binary's only `fsync` declaration.
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
comptime _READ_CHUNK = 1 << 16
"""The staging buffer's size, in bytes. Bounds resident memory independently of
the caller's ceiling: a 512 MiB cap and a 4 KiB file must not cost a gigabyte."""


@fieldwise_init
struct BoundedRegularFileRead(Copyable, Movable):
    """The bounded bytes and opened-descriptor regular-file verdict."""

    var is_regular: Bool
    """Whether the opened descriptor identified a regular file."""
    var text: String
    """At most the requested byte limit plus one, copied into owned UTF-8."""


@fieldwise_init
struct _OpenedRegularFileBytes(Copyable, Movable):
    """The undecoded result of the shared open-fstat-read core.

    The raw counterpart of `BoundedRegularFileRead`: the same verdict, but the
    payload is still bytes. Text is a decision the callers above make — one
    validates UTF-8 and the other must not — so the core stops one step short of
    it and hands back exactly what the descriptor produced.
    """

    var is_regular: Bool
    """Whether the opened descriptor identified a regular file."""
    var data: List[UInt8]
    """At most the requested byte limit plus one, verbatim. Empty when
    `is_regular` is False, in which case nothing was read at all."""

    def take_data(deinit self) -> List[UInt8]:
        """Consume this verdict and hand the bytes to the caller.

        Returns:
            The owned bytes, moved rather than copied. The verdict is gone
            afterwards, so read `is_regular` first.
        """
        return self.data^


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


def _opened_size_hint(
    storage: UnsafePointer[UInt64, MutUntrackedOrigin],
) -> Int:
    """Read `st_size` out of a filled `struct stat` as a SIZING HINT ONLY.

    Nothing about the read's correctness may depend on this number, and nothing
    here does: it only decides how much the byte list reserves up front. `st_size`
    is a snapshot taken at `fstat` time, so it under-reports a file being appended
    to and reads zero for the procfs-style regular files whose contents are
    generated at read time. The read loop therefore keeps its own count and grows
    the list when the hint proves short — the hint saves reallocations, it does
    not bound anything.

    Args:
        storage: The 144 initialized bytes `fstat` filled, aligned to 8.

    Returns:
        The recorded size in bytes, or a value the caller must clamp. A negative
        or absurd number is not an error here; the caller clamps it into range.
    """
    comptime if CompilationTarget.is_macos():
        comptime assert (
            not CompilationTarget.is_x86()
        ), "platform regular-file reads support macOS arm64 only"
        # SAFETY: the caller supplies 144 initialized bytes aligned to 8 that
        # `fstat` has filled as Darwin arm64 `struct stat`. Darwin's `st_size` is
        # a fully initialized `off_t` (Int64) at byte offset 96 — element twelve
        # of this aligned Int64 view — which the 144-byte struct fully contains.
        # The read stays inside the allocation, the typed pointer is read once
        # while `storage` is live and does not escape, and the caller retains and
        # frees the allocation. A wrong value could only mis-size a reservation,
        # never a bound: the caller clamps it and the read loop ignores it.
        return Int(storage.bitcast[Int64]()[12])
    else:
        comptime assert (
            CompilationTarget.is_linux()
        ), "platform regular-file reads support Linux or macOS only"
        comptime assert (
            CompilationTarget.is_x86()
        ), "platform regular-file reads support Linux x86_64 only"
        # SAFETY: the caller supplies 144 initialized bytes aligned to 8 that
        # `fstat` has filled as Linux x86_64 `struct stat`. Linux's `st_size` is
        # a fully initialized `off_t` (Int64) at byte offset 48 — element six of
        # this aligned Int64 view — which the 144-byte struct fully contains. The
        # read stays inside the allocation, the pointer remains live and local,
        # and the caller owns and frees it. A wrong value could only mis-size a
        # reservation, never a bound: the caller clamps it and the read loop
        # ignores it.
        return Int(storage.bitcast[Int64]()[6])


def _read_opened_regular_file_bytes(
    path: String, max_bytes: Int
) raises -> _OpenedRegularFileBytes:
    """Open, validate, and read at most `max_bytes + 1` raw bytes from `path`.

    The shared core beneath `read_bounded_regular_file` and
    `read_regular_file_bytes`. It owns the whole descriptor lifetime — the
    interrupt-retrying open, the file-type check on the already-open descriptor,
    the short-read loop, and the close — and interprets nothing about the bytes
    it produces. The single `open`/`fstat`/`read` declaration shape for those
    libc symbols lives here and is not repeated anywhere above.

    Args:
        path: The pathname to open. Symlinks are followed.
        max_bytes: The accepted payload ceiling, which must be nonnegative.

    Returns:
        An opened-descriptor regular-file verdict and the owned bytes. A regular
        file returns at most `max_bytes + 1` of them, so a caller can tell an
        exact-boundary file from an oversized one.

    Raises:
        Error: If open, fstat, read, close, or allocation fails. Every
            successfully opened descriptor is closed first.
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
    var size_hint = _opened_size_hint(stat_storage)
    # SAFETY: `_opened_mode` and `_opened_size_hint` each completed their one
    # bounded read and retained no pointer. This is the allocation's sole owner
    # and frees it exactly once; only the copied scalars remain live afterward.
    stat_storage.free()
    if mode & _S_IFMT != _S_IFREG:
        if close_fd(fd) != 0:
            raise Error("platform: close failed after regular-file validation")
        return _OpenedRegularFileBytes(False, List[UInt8]())

    # The READ CEILING is unchanged at `max_bytes + 1`: a caller tells a file of
    # exactly `max_bytes` from a longer one by whether that extra byte arrives.
    # What no longer scales with the ceiling is MEMORY. A ceiling-sized staging
    # buffer plus a ceiling-sized result made a 4 KiB file cost twice the cap,
    # which is invisible at the 64 KiB config cap and about a gigabyte at the cap
    # a build cache needs for compiled binaries. So bytes now land in a fixed
    # `_READ_CHUNK` staging buffer and are appended to a list reserved from
    # `st_size` — a hint, never a bound, since it is stale for a growing file and
    # zero for procfs-style regular files. The list grows itself when the hint is
    # short, so the ceiling alone still decides what is read.
    var capacity = max_bytes + 1
    var reserved = 1 if size_hint < 0 else size_hint + 1
    if reserved > capacity:
        reserved = capacity
    var data = List[UInt8](capacity=reserved)
    var chunk_len = capacity if capacity < _READ_CHUNK else _READ_CHUNK
    # SAFETY: `chunk_len` is in `[1, _READ_CHUNK]` because `capacity` is positive
    # (`max_bytes` is nonnegative). This allocation owns exactly `chunk_len`
    # writable UInt8 slots with a concrete mutable origin. No byte is read until
    # `read_fd` reports it initialized; the pointer remains live through every
    # synchronous read and every copy out of it, never escapes, and is freed on
    # every success or error path below.
    var buffer = alloc[UInt8](chunk_len)
    var total = 0
    while total < capacity:
        var room = capacity - total
        if room > chunk_len:
            room = chunk_len
        # SAFETY: `room` is in `[1, chunk_len]` because `total < capacity` here,
        # so the whole requested span lies inside the staging allocation, which
        # is rewritten from its start on every iteration — the bytes carried over
        # from the previous read were already copied out. `read_fd` initializes
        # at most `room` bytes, retains no pointer, and reports the initialized
        # count before Mojo inspects any content. The allocation and the
        # descriptor remain owned here.
        var count = read_fd(fd, buffer, room)
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
        if count > room:
            # SAFETY: this is the buffer's sole owner and `read_fd` retained no
            # pointer. No view was constructed, and the raising branch makes
            # this the allocation's only free with no subsequent access.
            buffer.free()
            var close_rc = close_fd(fd)
            _ = close_rc
            raise Error("platform: read reported impossible progress")
        # SAFETY: `read_fd` initialized exactly bytes `[0, count)` of the still
        # live staging allocation and `count <= room <= chunk_len`. `Span`
        # preserves that precise bound, and `List` copies every byte out of it
        # eagerly; the view is a temporary that cannot outlive this statement,
        # let alone the buffer.
        data.extend(Span(ptr=buffer, length=count))
        total += count

    # SAFETY: every byte the staging allocation ever held was copied into `data`
    # in the loop above, and no view of it survived the statement that copied it.
    # This is its sole owner and final use, so freeing exactly once here leaves
    # only the independent owned `data`; no path below touches the buffer.
    buffer.free()
    if close_fd(fd) != 0:
        raise Error("platform: close failed after bounded regular-file read")
    return _OpenedRegularFileBytes(True, data^)


def fsync_path(path: String) raises:
    """Flush `path`'s contents and metadata to durable storage.

    The durability half of an atomic publication. `rename(2)` is atomic against
    a crash of the process, but not against a crash of the MACHINE: without this
    a power loss can leave a directory entry pointing at a file whose bytes
    never reached the disk, and the next run would then read a generation whose
    binary is zeros while its recorded digest says otherwise. Flushing the
    payload files first and their containing directory last is what makes the
    subsequent rename a promise rather than a hope.

    Works on a directory as well as a regular file, which is why it takes a
    path rather than a descriptor: the caller has no descriptor for either, and
    the read flags this module already uses — `O_RDONLY|O_NONBLOCK|O_CLOEXEC` —
    are valid for both. Nothing is read through the descriptor, so a pathname
    swapped for a FIFO cannot block and a swapped device cannot be consumed.

    Args:
        path: The file or directory to flush.

    Raises:
        Error: If the path cannot be opened, if `fsync(2)` reports a failure, or
            if the descriptor cannot be closed. A successfully opened descriptor
            is always closed first, and the primary errno is preserved when
            cleanup also fails.

    Examples:

    ```mojo
    from mtest.platform import fsync_path, rename_path

    fsync_path("staging/bin")
    fsync_path("staging")
    rename_path("staging", "final")
    ```
    """
    var path_bytes = c_string_bytes(path)
    var raw_fd: Int32
    var open_errno = 0
    while True:
        # SAFETY: libc `open` has ABI `int open(const char*, int, ...)`, and
        # this is the same three-argument shape the reader above emits — one
        # declaration shape per symbol, so no link-time conflict can arise from
        # here. Neither O_CREAT nor O_TMPFILE is present, so libc never
        # `va_arg`s the trailing mode and the ignored `UInt32(0)` is sound on
        # Darwin arm64 as well as Linux. `path_bytes` uniquely owns a complete,
        # initialized NUL-terminated copy with a concrete local origin; it is
        # live across this synchronous call and libc neither retains nor frees
        # it. The guarded flags are O_RDONLY|O_NONBLOCK|O_CLOEXEC, so opening a
        # replaced FIFO cannot block and the descriptor cannot cross an exec.
        # Failure owns no descriptor; success transfers exactly one here.
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
            "platform: could not open '"
            + path
            + "' to flush it (errno "
            + String(open_errno)
            + ")"
        )
    var fd = Int(raw_fd)
    var sync_rc: Int32
    var sync_errno = 0
    while True:
        # SAFETY: libc `fsync` has the exact ABI `int fsync(int)`. This is the
        # only declaration of the symbol in the binary. The argument is a plain
        # scalar — the descriptor this function opened above and owns until the
        # single close below — so there is no pointer to keep live, alias,
        # bound, or free, and nothing can escape the call. `fsync` writes only
        # kernel-held state associated with that descriptor and neither
        # allocates nor retains anything on this process's behalf. It is
        # synchronous and returns a plain scalar status; on failure the
        # descriptor remains open and owned here, and the branch below closes it
        # exactly once before raising, so no path leaks or double-closes it.
        sync_rc = external_call["fsync", Int32](Int32(fd))
        if sync_rc == 0:
            break
        sync_errno = errno_now()
        if sync_errno != _EINTR:
            break
    if sync_rc != 0:
        # Inspect close to discharge ownership, but preserve fsync's primary
        # errno deterministically if cleanup also reports an error.
        var close_rc = close_fd(fd)
        _ = close_rc
        raise Error(
            "platform: fsync failed for '"
            + path
            + "' (errno "
            + String(sync_errno)
            + ")"
        )
    if close_fd(fd) != 0:
        raise Error("platform: close failed after flushing '" + path + "'")


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

    Examples:

    ```mojo
    from mtest.platform import read_bounded_regular_file

    var opened = read_bounded_regular_file("mtest.toml", 65536)
    if not opened.is_regular:
        raise Error("mtest.toml is not a regular file")
    var text = opened.text.copy()
    ```
    """
    var opened = _read_opened_regular_file_bytes(path, max_bytes)
    if not opened.is_regular:
        return BoundedRegularFileRead(False, "")
    var text: String
    try:
        text = String(StringSlice(from_utf8=Span(opened.data)))
    except:
        raise Error("platform: regular file is not valid UTF-8")
    return BoundedRegularFileRead(True, text^)


def read_regular_file_bytes(path: String, cap: Int) raises -> List[UInt8]:
    """Read `path`'s bytes verbatim, refusing anything larger than `cap`.

    The undecoded sibling of `read_bounded_regular_file`, sharing its whole
    descriptor discipline: the same interrupt-retrying open, the same file-type
    check performed on the already-open descriptor rather than on the pathname,
    the same short-read loop. What it drops is the UTF-8 validation. A cache key
    digests compiled binaries and whatever a test file happens to contain, so a
    reader that raises on invalid UTF-8 cannot serve it.

    It is also stricter about its ceiling than the bounded reader, which reports
    an overlong file by handing back `max_bytes + 1` bytes. There is no useful
    truncated prefix of a digest input, so an oversized file raises here instead.

    Args:
        path: The file to read. Symlinks are followed.
        cap: The largest accepted payload in bytes, which must be nonnegative.
            A file of exactly `cap` bytes is accepted.

    Returns:
        Exactly the file's bytes, in order, uninterpreted. Empty for an empty
        file.

    Raises:
        Error: If `path` is missing or cannot be opened, is not a regular file,
            holds more than `cap` bytes, or if fstat, read, close, or allocation
            fails. Every successfully opened descriptor is closed first.

    Examples:

    ```mojo
    from mtest.platform import read_regular_file_bytes

    var bytes = read_regular_file_bytes("build/bin/tests_test_ok", 1 << 26)
    ```
    """
    var opened = _read_opened_regular_file_bytes(path, cap)
    if not opened.is_regular:
        raise Error("platform: '" + path + "' is not a regular file")
    if len(opened.data) > cap:
        raise Error(
            "platform: '"
            + path
            + "' exceeds the byte cap of "
            + String(cap)
            + " for a raw read"
        )
    return opened^.take_data()
