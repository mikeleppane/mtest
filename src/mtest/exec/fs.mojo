"""The atomic filesystem promotion primitive: `rename_path`.

A precompile step builds its package to a temp path and promotes it onto the
real output only once the compiler exited 0, so a killed or crashed attempt can
never damage a good package an earlier run left behind. That promotion has to be
indivisible: a copy would leave a window in which the output is half a package.
`rename(2)` provides indivisibility — within one directory it either replaces
the destination completely or leaves it entirely alone, with no intermediate
state a concurrent reader (or a SIGKILLed mtest) can observe.

The stdlib offers no rename at the pinned toolchain (`std.os` has `remove`,
`rmdir`, `makedirs`, and `listdir`, but nothing that moves a path), so this is
one libc call. It lives here because `exec` is the runner's FFI floor: a syscall
above this layer would be a layering break, so the session asks for a promotion
rather than making a syscall of its own.
"""
from std.ffi import external_call


def _c_string_bytes(value: String) -> List[UInt8]:
    """An owned NUL-terminated byte copy of `value`, for one libc call."""
    var out = List[UInt8]()
    var b = value.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    out.append(0)
    return out^


def rename_path(src: String, dst: String) raises:
    """Atomically rename `src` onto `dst`, replacing `dst` if it exists.

    Both paths must live on the same filesystem; the caller derives `src` from
    `dst`, so they share a directory. On success `dst` names what `src` named
    and `src` is gone; on failure neither path is modified. The promotion is
    all-or-nothing.

    Args:
        src: The existing path to promote.
        dst: The path to promote it onto; replaced atomically when it exists.

    Raises:
        Error: If the rename failed, for example because `src` does not exist
            or the paths straddle filesystems. Nothing here is retried or
            ignored; the caller decides what a failed promotion means.
    """
    var s = _c_string_bytes(src)
    var d = _c_string_bytes(dst)
    # SAFETY: libc rename has the exact `int rename(const char*, const char*)`
    # ABI. Both arguments are complete NUL-terminated byte copies this function
    # uniquely owns; the borrowed pointers stay valid for the whole synchronous
    # call (both lists are used again below), and rename retains neither pointer
    # and writes through neither. The result is a plain scalar status.
    var rc = external_call["rename", Int32](s.unsafe_ptr(), d.unsafe_ptr())
    _ = s^
    _ = d^
    if rc != 0:
        raise Error("exec: rename failed: '" + src + "' -> '" + dst + "'")
