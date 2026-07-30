"""Atomic filesystem promotion and narrow permission operations.

Part of the narrow platform-I/O boundary. `rename_path` lets publishers replace
a file indivisibly. `set_permissions` supports explicit mode changes, while
`prepare_directory_for_rename` makes an identity-checked damaged cache
directory movable on Darwin without following substituted symlinks.

The pinned standard library does not expose these operations with the required
semantics. Their foreign calls stay proven and centralized here instead of
being redeclared in session or tests.
"""
from std.ffi import external_call
from std.memory import alloc, memset_zero
from std.sys.info import CompilationTarget

from mtest.platform.cstring import c_string_bytes
from mtest.platform.stream import errno_now


comptime _EINTR = 4
comptime _STAT_BYTES = 144
comptime _S_IFMT = 0o170000
comptime _S_IFDIR = 0o40000
comptime _DARWIN_AT_FDCWD = -2
comptime _DARWIN_AT_SYMLINK_NOFOLLOW_ANY = 0x0800


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
    this is a no-op there. On Darwin `fstatat` rejects a symlink in any path
    component and checks the directory's device/inode pair against the
    observation before `fchmodat` grants owner-only `0700` through the same
    no-follow-any path policy.

    Args:
        path: The observed directory that will next be renamed.
        expected_dev: The device captured before the failed directory read.
        expected_ino: The inode captured before the failed directory read.

    Raises:
        Error: On Darwin, if the path cannot be identified as the observed
            directory or its mode cannot be replaced. Callers may still attempt
            the rename because its authorization can differ.
    """
    comptime if CompilationTarget.is_macos():
        var c = c_string_bytes(path)
        # SAFETY: this allocation owns 144 initialized bytes aligned to eight,
        # the guarded Darwin arm64 `struct stat` size and alignment. It remains
        # live until every field read completes and is freed on every path.
        var stat_storage = alloc[UInt64](_STAT_BYTES // 8)
        memset_zero(stat_storage.bitcast[UInt8](), _STAT_BYTES)
        var stat_rc: Int32
        var stat_errno = 0
        while True:
            # SAFETY: Darwin libc `fstatat` has the exact fixed ABI
            # `int fstatat(int, const char*, struct stat*, int)`. `c` uniquely
            # owns a complete initialized NUL-terminated path and stays live
            # through the synchronous call. `stat_storage` is the complete
            # writable Darwin struct region. AT_FDCWD selects the absolute path
            # and AT_SYMLINK_NOFOLLOW_ANY rejects a symlink in any component.
            # The call writes only within the allocation, retains no pointer,
            # and owns neither resource.
            stat_rc = external_call["fstatat", Int32](
                Int32(_DARWIN_AT_FDCWD),
                c.unsafe_ptr(),
                stat_storage.bitcast[NoneType](),
                Int32(_DARWIN_AT_SYMLINK_NOFOLLOW_ANY),
            )
            if stat_rc == 0:
                break
            stat_errno = errno_now()
            if stat_errno != _EINTR:
                break
        if stat_rc != 0:
            # SAFETY: no view of the allocation exists and `fstatat` retained
            # no pointer, so this sole owner frees the complete allocation once.
            stat_storage.free()
            _ = c^
            raise Error(
                "platform: fstatat failed for damaged directory '"
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
            _ = c^
            raise Error("platform: damaged directory identity changed")

        var chmod_rc: Int32
        var chmod_errno = 0
        while True:
            # SAFETY: Darwin libc `fchmodat` has the fixed ABI
            # `int fchmodat(int, const char*, mode_t, int)`. `c` remains the
            # unique live owner of the complete initialized path. Darwin arm64
            # passes both UInt16 `mode_t` and UInt32 in the same `w2` register;
            # the callee reads the low 16 bits and `0700` fits there exactly.
            # AT_FDCWD selects the absolute path and
            # AT_SYMLINK_NOFOLLOW_ANY makes the kernel reject a symlink in any
            # component during the same lookup that selects the vnode to
            # modify. The synchronous call retains no pointer and owns nothing.
            chmod_rc = external_call["fchmodat", Int32](
                Int32(_DARWIN_AT_FDCWD),
                c.unsafe_ptr(),
                UInt32(0o700),
                Int32(_DARWIN_AT_SYMLINK_NOFOLLOW_ANY),
            )
            if chmod_rc == 0:
                break
            chmod_errno = errno_now()
            if chmod_errno != _EINTR:
                break
        _ = c^
        if chmod_rc != 0:
            raise Error(
                "platform: fchmodat failed for damaged directory '"
                + path
                + "' (errno "
                + String(chmod_errno)
                + ")"
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
