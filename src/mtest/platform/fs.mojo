"""Atomic filesystem promotion and narrow permission operations.

Part of the narrow platform-I/O boundary. `rename_path` lets publishers replace
a file indivisibly, and `publish_new_file` is its opposite number: a
publication that can only ever create, never replace. `set_permissions`
supports explicit mode changes, while `prepare_directory_for_rename` makes an
identity-checked damaged cache directory movable on Darwin without following
substituted symlinks. `destination_identity` answers the adjacent question of
whether two spellings name one file that does not exist yet.

The pinned standard library does not expose these operations with the required
semantics. Its `link` wrapper is the closest, and it is not close enough: it
folds every failure into one message whose only distinguishing mark is
`strerror` prose, so a caller cannot tell "the destination already exists" —
the answer a never-overwrite publication is entirely about — from a full disk
without matching on locale-dependent text. Their foreign calls stay proven and
centralized here instead of being redeclared in session or tests.
"""
from std.ffi import external_call
from std.memory import alloc, memset_zero
from std.os import remove
from std.os.path import basename, dirname, realpath
from std.sys.info import CompilationTarget

from mtest.platform.cstring import c_string_bytes
from mtest.platform.stream import close_fd, errno_now


comptime _EINTR = 4
comptime _EEXIST = 17
"""`EEXIST`, identical on Linux and Darwin: the destination name is taken."""
comptime _EPERM = 1
comptime _EXDEV = 18
comptime _EOPNOTSUPP = 45 if CompilationTarget.is_macos() else 95
"""`EOPNOTSUPP`, which unlike the three above is not the same number on both."""
comptime _CREATE_MODE = 0o666
"""The mode `open(2)` is given for a new ordinary file, before the umask."""
comptime _STAT_BYTES = 144
comptime _S_IFMT = 0o170000
comptime _S_IFDIR = 0o40000
comptime _DARWIN_AT_SYMLINK_NOFOLLOW_ANY = 0x0800
comptime _DARWIN_ANCHOR_OPEN_FLAGS = (
    0x40000000  # O_EXEC, making O_SEARCH with O_DIRECTORY
    | 0x00100000  # O_DIRECTORY
    | 0x01000000  # O_CLOEXEC
    | 0x20000000  # O_NOFOLLOW_ANY
)


def destination_identity(path: String) -> String:
    """The key two not-yet-created output destinations compare equal on.

    Canonicalizing `path` itself is not available: `realpath(3)` resolves every
    component and fails on a final one that does not exist, which is the normal
    state of a destination about to be written. The parent does exist (a
    missing one is refused earlier, as a usage error), so the parent is
    resolved and the basename appended verbatim. Two spellings of one file —
    `out.md` and `./out.md`, a `..` segment, or a symlinked parent directory —
    therefore produce one key, while two different names never do.

    An empty `dirname` is normalized to `.` first, so a bare filename resolves
    against the working directory instead of joining onto the filesystem root.

    Deliberately total rather than raising: an unresolvable parent falls back to
    the lexical spelling, which keeps the key comparable for a destination whose
    real failure is reported by whichever check owns it.

    Args:
        path: The destination as its own layer spelled it.

    Returns:
        A freshly allocated comparison key. Meaningful only against another key
        from this same function; never a path to open.

    Examples:

    ```mojo
    from mtest.platform import destination_identity

    var same = destination_identity("out.md") == destination_identity(
        "./out.md"
    )
    ```
    """
    var parent = String(dirname(path))
    if parent == "":
        parent = String(".")
    var resolved = parent.copy()
    try:
        resolved = realpath(parent)
    except:
        pass
    return resolved + "/" + String(basename(path))


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


def _replace_umask(mask: Int) -> Int:
    """Install `mask` as the process file-creation mask and return the old one.

    Args:
        mask: The permission bits to withhold from newly created files.

    Returns:
        The mask that was in effect. Allocates nothing and cannot fail —
        `umask(2)` has no error return.
    """
    comptime if CompilationTarget.is_macos():
        # SAFETY: Darwin libc `umask` has the exact fixed ABI
        # `mode_t umask(mode_t)`, with `mode_t` a UInt16, and the caller's
        # permission-only value fits it exactly. There is no pointer to
        # provide, alias, or retain, nothing is allocated on either side, and
        # the call cannot fail. The one effect is process-global: the
        # file-creation mask is replaced, which every caller here restores on
        # the next line, and mtest is single-threaded at both call sites, so
        # no concurrent creation can observe the intermediate mask.
        return Int(external_call["umask", UInt16](UInt16(mask)))
    else:
        # SAFETY: Linux libc `umask` has the exact fixed ABI
        # `mode_t umask(mode_t)`, with `mode_t` a UInt32, and the caller's
        # permission-only value fits it exactly. There is no pointer to
        # provide, alias, or retain, nothing is allocated on either side, and
        # the call cannot fail. The one effect is process-global: the
        # file-creation mask is replaced, which every caller here restores on
        # the next line, and mtest is single-threaded at both call sites, so
        # no concurrent creation can observe the intermediate mask.
        return Int(external_call["umask", UInt32](UInt32(mask)))


def default_file_mode() -> Int:
    """The permission bits an ordinary new file would get from this process.

    A file created through `mkstemp(3)` is `0600` by contract, which is the
    right mode for a temporary and the wrong one for source code a person is
    about to edit and commit. This answers what any other tool would have
    produced instead: the `0666` an `open(2)` asks for, minus the process
    umask.

    `umask(2)` can only be read by replacing it, so this installs a mask and
    puts the old one straight back. That is safe here and only here: mtest
    creates no file from another thread, and every caller of this runs before
    any concurrent work exists — the scaffolders before a session exists at
    all, and `main`'s report-destination setup before the first file is built.

    Returns:
        The permission bits, `0600` at worst. Allocates nothing, cannot fail,
        and leaves the process umask exactly as it found it.

    Examples:

    ```mojo
    from mtest.platform import default_file_mode, set_permissions

    set_permissions("draft.txt", default_file_mode())  # 0644 under umask 022
    ```
    """
    var previous = _replace_umask(0)
    _ = _replace_umask(previous)
    return _CREATE_MODE & ~previous


def prepare_directory_for_rename(
    anchor: String, relative: String, expected_dev: Int, expected_ino: Int
) raises:
    """Make one observed directory movable where Darwin requires owner access.

    Linux rename authorization comes entirely from the parent directory, so
    this is a no-op there. On Darwin the accessible store directory is
    canonicalized and opened as an anchor. `fstatat` then rejects a symlink in
    any component below that anchor and checks the directory's device/inode pair
    against the observation before `fchmodat` grants owner-only `0700` through
    the same relative no-follow-any path policy.

    Args:
        anchor: An accessible directory containing the observed directory.
        relative: The observed directory's path relative to `anchor`.
        expected_dev: The device captured before the failed directory read.
        expected_ino: The inode captured before the failed directory read.

    Raises:
        Error: On Darwin, if the path cannot be identified as the observed
            directory or its mode cannot be replaced. Callers may still attempt
            the rename because its authorization can differ.
    """
    comptime if CompilationTarget.is_macos():
        var canonical_anchor = realpath(anchor)
        var anchor_c = c_string_bytes(canonical_anchor)
        var raw_fd: Int32
        var open_errno = 0
        while True:
            # SAFETY: Darwin libc `open` has ABI
            # `int open(const char*, int, ...)`. No creation flag is set, so
            # libc reads no variadic mode. `anchor_c` uniquely owns a complete
            # initialized NUL-terminated canonical path and stays live through
            # the synchronous call. O_SEARCH requests only directory search,
            # O_NOFOLLOW_ANY rejects any unexpected remaining symlink,
            # O_DIRECTORY requires the anchor type, and O_CLOEXEC prevents
            # descriptor escape. Success transfers one descriptor here;
            # failure owns none, and libc retains no pointer on either path.
            raw_fd = external_call["open", Int32](
                anchor_c.unsafe_ptr().bitcast[NoneType](),
                Int32(_DARWIN_ANCHOR_OPEN_FLAGS),
                UInt32(0),
            )
            if raw_fd >= 0:
                break
            open_errno = errno_now()
            if open_errno != _EINTR:
                break
        _ = anchor_c^
        if raw_fd < 0:
            raise Error(
                "platform: could not open damaged-directory anchor '"
                + anchor
                + "' (errno "
                + String(open_errno)
                + ")"
            )
        var fd = Int(raw_fd)
        var path = anchor + "/" + relative
        var c = c_string_bytes(relative)
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
            # writable Darwin struct region. `fd` is the live canonical anchor
            # descriptor and AT_SYMLINK_NOFOLLOW_ANY rejects a symlink in any
            # relative component. The call writes only within the allocation,
            # retains no pointer, and owns neither resource.
            stat_rc = external_call["fstatat", Int32](
                Int32(fd),
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
            _ = close_fd(fd)
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
            _ = close_fd(fd)
            raise Error("platform: damaged directory identity changed")

        var chmod_rc: Int32
        var chmod_errno = 0
        while True:
            # SAFETY: Darwin libc `fchmodat` has the fixed ABI
            # `int fchmodat(int, const char*, mode_t, int)`. `c` remains the
            # unique live owner of the complete initialized path. Darwin arm64
            # passes both UInt16 `mode_t` and UInt32 in the same `w2` register;
            # the callee reads the low 16 bits and `0700` fits there exactly.
            # `fd` is the live canonical anchor descriptor, and
            # AT_SYMLINK_NOFOLLOW_ANY makes the kernel reject a symlink in any
            # relative component during the same lookup that selects the vnode
            # to modify. The synchronous call retains no pointer and owns
            # nothing.
            chmod_rc = external_call["fchmodat", Int32](
                Int32(fd),
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
        var close_rc = close_fd(fd)
        if chmod_rc != 0:
            raise Error(
                "platform: fchmodat failed for damaged directory '"
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


def _link_failure_cause(err: Int) -> String:
    """Name what a failing `link(2)` errno means, when the name is actionable.

    Args:
        err: The errno the failed `link(2)` reported.

    Returns:
        A clause to append to the failure message, or an empty string when the
        errno speaks for itself.
    """
    if err == _EPERM or err == _EOPNOTSUPP:
        return (
            "; this filesystem does not support hard links, so a file cannot"
            " be published here without replacing what is already there"
        )
    if err == _EXDEV:
        return "; the two paths are on different filesystems"
    return String("")


def publish_new_file(temp_path: String, dst: String) raises -> Bool:
    """Publish `temp_path` at `dst` without ever replacing what is there.

    `link(2)` is what makes that a promise rather than an intention: it fails
    with `EEXIST` when `dst` already names something, so the refusal is decided
    by the filesystem in the same indivisible step that would have created the
    file. A check-then-`rename_path` cannot say the same, because `rename`
    replaces its destination and a file created between the check and the
    rename would be destroyed by it.

    Both paths must live on the same filesystem; callers derive `temp_path`
    from `dst`'s own directory, so they always share one.

    The published file keeps the temporary's permission bits, because both
    names share one inode; a caller that wants a mode other than the one its
    temporary carries has to set it before publishing, not after.

    Args:
        temp_path: An existing file, in `dst`'s directory, whose bytes are
            published. Its removal is ATTEMPTED once the link succeeds; on
            every other path, and on a removal that itself fails, the
            temporary is left for the caller's own cleanup to retire.
        dst: The path to create. Never opened, truncated, or modified when it
            already exists.

    Returns:
        True when `dst` was created, False when it already existed and nothing
        was written. Allocates only the two transient path copies.

    Raises:
        Error: If the link failed for any reason other than an occupied
            destination — naming the errno, and what it means where that is
            actionable — or if the temporary could not be removed after a
            successful link. In that last case `dst` exists and is complete;
            only the temporary beside it is left over, and the message names
            both paths so the caller can say which is which.
    """
    var s = c_string_bytes(temp_path)
    var d = c_string_bytes(dst)
    # SAFETY: libc `link` has the exact fixed ABI
    # `int link(const char*, const char*)` on both supported targets, so this
    # one declaration matches each of them, and it is the only declaration of
    # `link` in this repository's Mojo sources. `s` and `d` point at complete,
    # fully initialized, NUL-terminated byte copies this frame uniquely owns —
    # `c_string_bytes` allocates them here and nothing else references them —
    # so provenance is local and neither buffer aliases the other. Both are
    # still live locals at the call and are consumed only after it returns,
    # which keeps the pointers valid for the whole synchronous call. Neither
    # escapes: `link` reads the two path strings, writes through neither, and
    # retains no pointer past its return. Every byte read is inside the
    # terminated region. The callee allocates nothing for this frame to free,
    # and creates a directory entry only on success, so there is no partial
    # state to unwind — on both paths the only cleanup is releasing the two
    # lists, which Mojo does where they are consumed below. The result is a
    # plain scalar status.
    var rc = external_call["link", Int32](s.unsafe_ptr(), d.unsafe_ptr())
    # Read `errno` while the failed `link` is still the last call: releasing
    # the two lists below could overwrite the slot.
    var err = errno_now() if rc != 0 else 0
    _ = s^
    _ = d^
    if rc != 0:
        if err == _EEXIST:
            return False
        raise Error(
            "platform: link failed: '"
            + temp_path
            + "' -> '"
            + dst
            + "' (errno "
            + String(err)
            + ")"
            + _link_failure_cause(err)
        )
    # The bytes now live under both names, so the temporary one is the only
    # thing left to retire. A failure here is reported rather than swallowed:
    # the publication succeeded, and the caller is owed the fact that a stray
    # file was left beside its new one. It is left where it is rather than
    # retried, because the caller's own cleanup already owns exactly that
    # path on every other failure.
    try:
        remove(temp_path)
    except e:
        raise Error(
            "platform: published '"
            + dst
            + "' but could not remove the temporary '"
            + temp_path
            + "': "
            + String(e)
        )
    return True
