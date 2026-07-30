"""Atomic filesystem promotion and narrow permission operations.

Part of the narrow platform-I/O boundary. `rename_path` lets publishers replace
a file indivisibly. `set_permissions` supports explicit mode changes, while
`prepare_directory_for_rename` makes an identity-checked damaged cache
directory movable on Darwin without mutating a concurrently substituted
object.

The pinned standard library does not expose these operations with the required
semantics. Their foreign calls stay proven and centralized here instead of
being redeclared in session or tests.
"""
from std.ffi import external_call
from std.memory import alloc, memset_zero
from std.sys.info import CompilationTarget

from mtest.platform.cstring import c_string_bytes
from mtest.platform.stream import close_fd, errno_now


comptime _EINTR = 4
comptime _STAT_BYTES = 144
comptime _S_IFMT = 0o170000
comptime _S_IFDIR = 0o40000
comptime _DARWIN_REPAIR_OPEN_FLAGS = (
    0x00008000  # O_EVTONLY
    | 0x00100000  # O_DIRECTORY
    | 0x01000000  # O_CLOEXEC
    | 0x20000000  # O_NOFOLLOW_ANY
)
comptime _DARWIN_EVTONLY_POLICY_TYPE = 10
comptime _DARWIN_POLICY_SCOPE_PROCESS = 0
comptime _DARWIN_EVTONLY_DISALLOW_RW = 1


def set_permissions(path: String, mode: Int) raises:
    """Replace `path`'s POSIX permission bits.

    Allocates only the transient NUL-terminated path bytes used by `chmod(2)`.

    Args:
        path: An existing path whose permission bits are replaced.
        mode: The POSIX permission bits, limited to values representable by
            Darwin's `mode_t`.

    Raises:
        Error: If `chmod` reports a failure.
    """
    var c = c_string_bytes(path)
    var rc: Int32
    comptime if CompilationTarget.is_macos():
        # SAFETY: Darwin libc `chmod` has the exact fixed ABI
        # `int chmod(const char*, mode_t)`, with `mode_t` a UInt16. `c` uniquely
        # owns a complete, initialized, NUL-terminated path copy and stays live
        # through this synchronous call; `chmod` only reads it, retains no
        # pointer, and writes through none. The caller's permission-only value
        # fits UInt16 exactly. The callee allocates nothing, and `c` is released
        # after the scalar result is captured on every path.
        rc = external_call["chmod", Int32](c.unsafe_ptr(), UInt16(mode))
    else:
        # SAFETY: Linux libc `chmod` has the exact fixed ABI
        # `int chmod(const char*, mode_t)`, with `mode_t` a UInt32. `c` uniquely
        # owns a complete, initialized, NUL-terminated path copy and stays live
        # through this synchronous call; `chmod` only reads it, retains no
        # pointer, and writes through none. The caller's permission-only value
        # fits UInt32 exactly. The callee allocates nothing, and `c` is released
        # after the scalar result is captured on every path.
        rc = external_call["chmod", Int32](c.unsafe_ptr(), UInt32(mode))
    _ = c^
    if rc != 0:
        raise Error(
            "platform: chmod failed for '" + path + "' to mode " + String(mode)
        )


def prepare_directory_for_rename(
    path: String, expected_dev: Int, expected_ino: Int
) raises:
    """Make one observed directory movable where Darwin requires owner access.

    Linux rename authorization comes entirely from the parent directory, so
    this is a no-op there. On Darwin the path is opened without following any
    symlink, the descriptor's device/inode pair is checked against the
    observation, and only that descriptor receives owner-only `0700`.

    Args:
        path: The observed directory that will next be renamed.
        expected_dev: The device captured before the failed directory read.
        expected_ino: The inode captured before the failed directory read.

    Raises:
        Error: On Darwin, if the path cannot be opened and identified as the
            observed directory, its mode cannot be replaced, or cleanup fails.
            Callers may still attempt the rename because its authorization can
            differ.
    """
    comptime if CompilationTarget.is_macos():
        # SAFETY: Darwin libc `setiopolicy_np` has the exact fixed ABI
        # `int setiopolicy_np(int, int, int)`. All arguments are plain Int32
        # scalars: the public VFS policy type 10, process scope 0, and policy 1.
        # The operation permanently makes O_EVTONLY descriptors in this process
        # request neither read nor write authorization, which is required to
        # open the mode-000 directory this helper repairs. Repeated and
        # concurrent calls are idempotent bit sets in XNU; mtest has no other
        # O_EVTONLY user whose semantics could change. The call retains no
        # pointer, allocates nothing, and leaves no partial resource on failure.
        var policy_rc = external_call["setiopolicy_np", Int32](
            Int32(_DARWIN_EVTONLY_POLICY_TYPE),
            Int32(_DARWIN_POLICY_SCOPE_PROCESS),
            Int32(_DARWIN_EVTONLY_DISALLOW_RW),
        )
        if policy_rc != 0:
            var policy_errno = errno_now()
            raise Error(
                "platform: could not enable event-only directory opens (errno "
                + String(policy_errno)
                + ")"
            )

        var c = c_string_bytes(path)
        var raw_fd: Int32
        var open_errno = 0
        while True:
            # SAFETY: Darwin libc `open` has ABI
            # `int open(const char*, int, ...)`, in the same three-argument
            # shape used elsewhere in this package. No creation flag is set, so
            # libc reads no variadic mode. `c` uniquely owns a complete,
            # initialized NUL-terminated path and stays live through the
            # synchronous call; libc retains nothing. O_NOFOLLOW_ANY rejects a
            # symlink in any component, O_DIRECTORY rejects a hard-linked file,
            # the process policy above makes O_EVTONLY request neither read nor
            # write authorization, so a mode-000 directory can open, and
            # O_CLOEXEC prevents descriptor escape. Success transfers one
            # descriptor here; failure owns none.
            raw_fd = external_call["open", Int32](
                c.unsafe_ptr().bitcast[NoneType](),
                Int32(_DARWIN_REPAIR_OPEN_FLAGS),
                UInt32(0),
            )
            if raw_fd >= 0:
                break
            open_errno = errno_now()
            if open_errno != _EINTR:
                break
        _ = c^
        if raw_fd < 0:
            raise Error(
                "platform: could not open damaged directory '"
                + path
                + "' (errno "
                + String(open_errno)
                + ")"
            )
        var fd = Int(raw_fd)

        # SAFETY: this allocation owns 144 initialized bytes aligned to eight,
        # the guarded Darwin arm64 `struct stat` size and alignment. It remains
        # live until every field read completes and is freed on every path.
        var stat_storage = alloc[UInt64](_STAT_BYTES // 8)
        memset_zero(stat_storage.bitcast[UInt8](), _STAT_BYTES)
        var stat_rc: Int32
        var stat_errno = 0
        while True:
            # SAFETY: Darwin libc `fstat` has ABI
            # `int fstat(int, struct stat*)`, matching the package's existing
            # declaration shape. `fd` is live and names the atomically opened
            # object. `stat_storage` is the complete writable Darwin struct
            # region; the synchronous call writes only within it, retains no
            # pointer, and owns neither resource.
            stat_rc = external_call["fstat", Int32](
                Int32(fd), stat_storage.bitcast[NoneType]()
            )
            if stat_rc == 0:
                break
            stat_errno = errno_now()
            if stat_errno != _EINTR:
                break
        if stat_rc != 0:
            # SAFETY: no view of the allocation exists and `fstat` retained no
            # pointer, so this sole owner frees the complete allocation once.
            stat_storage.free()
            _ = close_fd(fd)
            raise Error(
                "platform: fstat failed for damaged directory '"
                + path
                + "' (errno "
                + String(stat_errno)
                + ")"
            )

        # SAFETY: Darwin arm64 `struct stat` stores initialized `st_dev` as
        # Int32 at byte 0, `st_mode` as UInt16 at byte 4, and `st_ino` as UInt64
        # at byte 8. Each aligned read stays inside the live 144-byte
        # allocation, produces a copied scalar, and retains no pointer.
        var opened_dev = Int(stat_storage.bitcast[Int32]()[0])
        var opened_mode = Int(
            (stat_storage.bitcast[UInt8]() + 4).bitcast[UInt16]()[0]
        )
        var opened_ino = Int(stat_storage[1])
        # SAFETY: all three bounded field reads completed and retain no view;
        # this is the allocation's sole owner and frees it exactly once.
        stat_storage.free()
        if (
            opened_mode & _S_IFMT != _S_IFDIR
            or opened_dev != expected_dev
            or opened_ino != expected_ino
        ):
            _ = close_fd(fd)
            raise Error("platform: damaged directory identity changed")

        var chmod_rc: Int32
        var chmod_errno = 0
        while True:
            # SAFETY: Darwin libc `fchmod` has the fixed ABI
            # `int fchmod(int, mode_t)`. The standard library has already fixed
            # this symbol's Mojo declaration to `(Int32, UInt32)`, so this uses
            # that one link-compatible shape. Darwin arm64 passes both UInt16
            # `mode_t` and UInt32 in the same `w1` register; the callee reads the
            # low 16 bits, and `0700` fits there exactly. `fd` is the live
            # descriptor whose directory type and device/inode identity were
            # verified above, so pathname replacement cannot retarget it. The
            # call retains nothing and leaves descriptor ownership here on
            # success and failure.
            chmod_rc = external_call["fchmod", Int32](Int32(fd), UInt32(0o700))
            if chmod_rc == 0:
                break
            chmod_errno = errno_now()
            if chmod_errno != _EINTR:
                break
        var close_rc = close_fd(fd)
        if chmod_rc != 0:
            raise Error(
                "platform: fchmod failed for damaged directory '"
                + path
                + "' (errno "
                + String(chmod_errno)
                + ")"
            )
        if close_rc != 0:
            raise Error(
                "platform: close failed after directory permission repair"
            )


def rename_path(src: String, dst: String) raises:
    """Atomically rename `src` onto `dst`, replacing `dst` if it exists.

    Both paths must live on the same filesystem; each caller derives `src` from
    `dst`'s own directory, so they always share one. On success `dst` names what
    `src` named and `src` is gone; on failure neither path is modified. The
    promotion is all-or-nothing.

    Args:
        src: The existing path to promote.
        dst: The path to promote it onto; replaced atomically when it exists.

    Raises:
        Error: If the rename failed, for example because `src` does not exist,
            the paths straddle filesystems, or the destination directory became
            unwritable. Nothing here is retried or ignored; the caller decides
            what a failed promotion means.

    Examples:

    ```mojo
    from mtest.platform import rename_path
    from mtest.platform import close_checked_fd, create_unique_temp

    var created = create_unique_temp("build/report.xml.XXXXXX")
    close_checked_fd(created.fd)
    rename_path(created.path, "build/report.xml")  # replaces any prior report
    ```
    """
    var s = c_string_bytes(src)
    var d = c_string_bytes(dst)
    # SAFETY: libc `rename` has the exact ABI
    # `int rename(const char*, const char*)`. Both arguments point at complete,
    # fully initialized NUL-terminated byte copies that this function uniquely
    # owns — `c_string_bytes` allocates them here and nothing else holds a
    # reference — so provenance is local and neither buffer aliases the other.
    # `s` and `d` are still live locals at the call and are consumed only after
    # it returns, which keeps both pointers valid for the whole synchronous
    # call; neither pointer escapes, because `rename` is documented to read the
    # two path strings and retain nothing past its return, and it writes through
    # neither. The bytes read are exactly the terminated path bytes, so no read
    # runs past the initialized region. There is no allocation for the callee to
    # free and no descriptor or partial state to unwind: on both the success and
    # the failure path the only cleanup is releasing the two lists, which Mojo
    # does when they are consumed below. The result is a plain scalar status.
    var rc = external_call["rename", Int32](s.unsafe_ptr(), d.unsafe_ptr())
    _ = s^
    _ = d^
    if rc != 0:
        raise Error("platform: rename failed: '" + src + "' -> '" + dst + "'")
