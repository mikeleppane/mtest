"""Atomic filesystem promotion and permission replacement.

Part of the narrow platform-I/O boundary. `rename_path` lets publishers replace
a file indivisibly, and `set_permissions` lets cache cleanup make a damaged
directory movable before Darwin's `rename(2)` write-permission check.

The pinned standard library exposes neither operation. Each stays one foreign
call, proven here and shared by every caller instead of being redeclared in
session or tests.
"""
from std.ffi import external_call

from mtest.platform.cstring import c_string_bytes


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
    # SAFETY: libc `chmod` has the exact ABI `int chmod(const char*, mode_t)` on
    # both Linux and Darwin — a fixed arity of two with no variadic tail, so the
    # non-variadic call `external_call` emits is correct on both targets. The
    # pointer names a complete, initialized, NUL-terminated byte copy uniquely
    # owned by this function; `c` remains live through the synchronous call and
    # is consumed only afterward. `chmod` reads the path, retains no pointer,
    # and writes through none. The mode is passed in the same UInt32 register
    # shape already used repo-wide: Linux reads its full `mode_t`, while
    # Darwin's UInt16 `mode_t` reads the same low bits. Callers pass only the
    # nine POSIX permission bits, so the narrowing preserves the complete
    # value. The callee allocates and retains nothing, and every path releases
    # `c` after the scalar result is captured.
    var rc = external_call["chmod", Int32](c.unsafe_ptr(), UInt32(mode))
    _ = c^
    if rc != 0:
        raise Error(
            "platform: chmod failed for '" + path + "' to mode " + String(mode)
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
