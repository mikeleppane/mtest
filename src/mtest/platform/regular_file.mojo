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
from std.os import lstat
from std.sys.info import CompilationTarget, is_triple

from mtest.platform.cstring import c_string_bytes
from mtest.platform.ffi_record import FfiRecord
from mtest.platform.fs import S_IFMT, S_IFREG
from mtest.platform.stream import EINTR, close_fd, errno_now, read_fd


comptime _ENOENT = 2
comptime _ENOTDIR = 20
"""The two errnos that mean a name is genuinely free rather than unreadable.
Both carry these values on Linux and on Darwin, so no per-target branch is
needed to read them."""
comptime _STAT_BYTES = 144
comptime _READ_CHUNK = 1 << 16
"""The staging buffer's size, in bytes. Bounds resident memory independently of
the caller's ceiling: a 512 MiB cap and a 4 KiB file must not cost a gigabyte."""


@fieldwise_init
struct PathFacts(Copyable, Movable):
    """What one path names, observed without following a final symlink."""

    var present: Bool
    """Whether anything was there to observe. False only when the name is
    genuinely free: an observation that FAILED reports `present` False and a
    nonzero `error`, so read `error` before believing this."""

    var is_regular: Bool
    """Whether it is a regular file. False for a symlink, whose target is
    deliberately not consulted: a caller about to replace a name wants to know
    about the name, not about whatever it points at."""

    var mode: Int
    """Its permission bits, or zero when nothing was observed."""

    var error: Int
    """The `errno` that stopped the observation, or `0` when it succeeded or
    the name is genuinely absent. Nonzero means "unknown", never "free": a
    caller that treats it as absence would go on to create through a name it
    could not inspect."""


def observe_path(path: String) -> PathFacts:
    """Observe what `path` names right now, never following a final symlink.

    The observation a caller makes before deciding whether it may create or
    replace a name. `lstat(2)` rather than `stat(2)` is the whole point: a
    symlink must report as "not a regular file" so a publisher refuses it
    instead of writing through it.

    Absence and unreadability are separated rather than folded together.
    `ENOENT` and `ENOTDIR` are the two errnos that mean the name is free — no
    final component, or a non-directory somewhere along the way — and only
    those two report absence. Every other failure (`EACCES` on an unsearchable
    parent, `ELOOP`, `EIO`, `ENAMETOOLONG`) reports `error` instead, because
    "I could not look" and "nothing is there" lead a publisher to opposite
    decisions: the first must stop, the second may create.

    The errno is read through `errno_now` as the first operation after the
    failure, before anything else in this function runs. The pinned stdlib's
    `lstat` leaves the slot alone while it builds the error it raises, and
    `test_observe_path_reports_unreadable` is what would notice if that ever
    stopped being true.

    Args:
        path: The pathname to observe.

    Returns:
        Presence, regular-file-ness, the permission bits, and the errno that
        stopped the observation. Allocates nothing and cannot fail.

    Examples:

    ```mojo
    from mtest.platform import observe_path

    var facts = observe_path(".gitignore")
    if facts.error != 0:
        raise Error("could not inspect .gitignore")
    if facts.present and not facts.is_regular:
        raise Error("refusing to replace a non-regular .gitignore")
    ```
    """
    try:
        var raw = Int(lstat(path).st_mode)
        return PathFacts(True, raw & S_IFMT == S_IFREG, raw & 0o777, 0)
    except:
        var failed = errno_now()
        if failed == _ENOENT or failed == _ENOTDIR:
            return PathFacts(False, False, 0, 0)
        return PathFacts(False, False, 0, failed)


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
        comptime assert is_triple[
            "x86_64-unknown-linux-gnu"
        ](), "platform regular-file reads support Linux x86_64 only"
        return Int32(0o4000 | 0o2000000)


def _opened_mode(
    storage: FfiRecord,
) -> Int:
    comptime if CompilationTarget.is_macos():
        comptime assert (
            not CompilationTarget.is_x86()
        ), "platform regular-file reads support macOS arm64 only"
        # Darwin arm64 `st_mode` is a UInt16 at byte offset 4.
        return Int(storage.load[UInt16](2))
    else:
        comptime assert (
            CompilationTarget.is_linux()
        ), "platform regular-file reads support Linux or macOS only"
        comptime assert is_triple[
            "x86_64-unknown-linux-gnu"
        ](), "platform regular-file reads support Linux x86_64 only"
        # Linux x86_64 `st_mode` is a UInt32 at byte offset 24.
        return Int(storage.load[UInt32](6))


def _opened_size_hint(
    storage: FfiRecord,
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
        # Darwin arm64 `st_size` is an Int64 at byte offset 96.
        return Int(storage.load[Int64](12))
    else:
        comptime assert (
            CompilationTarget.is_linux()
        ), "platform regular-file reads support Linux or macOS only"
        comptime assert is_triple[
            "x86_64-unknown-linux-gnu"
        ](), "platform regular-file reads support Linux x86_64 only"
        # Linux x86_64 `st_size` is an Int64 at byte offset 48.
        return Int(storage.load[Int64](6))


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
        raw_fd = external_call["open", Int32, num_fixed_args=2](
            path_bytes.unsafe_ptr().unsafe_bitcast[NoneType](),
            _open_read_flags(),
            UInt32(0),
        )
        if raw_fd >= 0:
            break
        open_errno = errno_now()
        if open_errno != EINTR:
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

    # 144 bytes is `struct stat` on both guarded targets.
    var stat_storage = FfiRecord(bytes=_STAT_BYTES)
    var stat_rc: Int32
    var stat_errno = 0
    while True:
        # SAFETY: libc `fstat` has ABI `int fstat(int, struct stat*)`. `fd` is
        # live; `stat_storage` is 144 zeroed writable bytes aligned to 8,
        # exactly the guarded target's struct size. The synchronous call writes
        # only that region and retains no pointer.
        stat_rc = external_call["fstat", Int32](Int32(fd), stat_storage.ptr())
        if stat_rc == 0:
            break
        stat_errno = errno_now()
        if stat_errno != EINTR:
            break
    if stat_rc != 0:
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
    if mode & S_IFMT != S_IFREG:
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
    var buffer = List[UInt8](length=chunk_len, fill=0)
    var total = 0
    while total < capacity:
        var room = capacity - total
        if room > chunk_len:
            room = chunk_len
        var count = read_fd(fd, Span(buffer)[:room])
        if count < 0:
            var read_errno = errno_now()
            if read_errno == EINTR:
                continue
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
            var close_rc = close_fd(fd)
            _ = close_rc
            raise Error("platform: read reported impossible progress")
        data.extend(Span(buffer)[:count])
        total += count

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
        raw_fd = external_call["open", Int32, num_fixed_args=2](
            path_bytes.unsafe_ptr().unsafe_bitcast[NoneType](),
            _open_read_flags(),
            UInt32(0),
        )
        if raw_fd >= 0:
            break
        open_errno = errno_now()
        if open_errno != EINTR:
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
        if sync_errno != EINTR:
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
        text = String(from_utf8=opened.data)
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
