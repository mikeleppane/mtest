"""The atomic filesystem promotion primitive: `rename_path`.

Part of the narrow platform-I/O boundary. Two callers publish a file by
replacing another indivisibly: the precompile step promotes a package onto its
output path only once the compiler exited 0, so a killed or crashed attempt can
never damage a good package an earlier run left behind, and the JUnit reporter
promotes its assembled document onto the `--junit-xml` target, so a prior report
survives a run that dies mid-write. A copy would leave a window in which the
destination is half a file. `rename(2)` has no such window: within one directory
it either replaces the destination completely or leaves it entirely alone, with
no intermediate state a concurrent reader — or a SIGKILLed mtest — can observe.

The standard library has no rename at the pinned toolchain. `std.os` offers
`link`, `unlink`, `remove`, `rmdir`, `makedirs`, and `listdir`, but nothing that
moves a path, and `link` followed by `unlink` is not a substitute: `link` refuses
an existing destination, so it cannot replace one, and the two-call sequence is
interruptible where the single syscall is not. That leaves one foreign call,
proven here and shared by both callers, in place of the two identical copies
this replaces.
"""
from std.ffi import external_call

from mtest.platform.cstring import c_string_bytes


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
