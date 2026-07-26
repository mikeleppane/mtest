"""Exclusive temporary-file creation and descriptor completion primitives.

Part of the narrow platform-I/O boundary. `create_unique_temp` wraps POSIX
`mkstemp(3)` so a caller receives the exact same-directory path and the already
open mode-0600 descriptor atomically, without ever reopening an attacker-
replaceable pathname. The write and close helpers preserve the descriptor
lifecycle needed before an atomic rename.
"""
from std.ffi import external_call

from mtest.platform.cstring import c_string_bytes
from mtest.platform.stream import close_fd, errno_now, write_fd


comptime _EINTR = 4


@fieldwise_init
struct UniqueTempFile(Movable):
    """One exclusively created path and its sole owned descriptor."""

    var path: String
    """The actual path selected by `mkstemp`, owned by the caller."""
    var fd: Int
    """The open write descriptor, owned by the caller until one close."""


def create_unique_temp(template: String) raises -> UniqueTempFile:
    """Atomically create one mode-0600 temporary file from `template`.

    Args:
        template: A path ending in exactly six `X` bytes. It should share its
            directory with the eventual rename target.

    Returns:
        The actual unique path and its already-open descriptor. The caller owns
        both, must close the descriptor exactly once, and may unlink only this
        returned path on failure.

    Raises:
        Error: If the template is invalid or `mkstemp(3)` cannot create a file.

    Examples:

    ```mojo
    from mtest.platform.temp_file import (
        close_checked_fd,
        create_unique_temp,
        write_all_fd,
    )

    var created = create_unique_temp("build/state.XXXXXX")
    write_all_fd(created.fd, "{}")
    close_checked_fd(created.fd)
    ```
    """
    if not template.endswith("XXXXXX"):
        raise Error(
            "platform: mkstemp failed: template must end in XXXXXX: '"
            + template
            + "'"
        )
    for byte in template.as_bytes():
        if byte == UInt8(0):
            raise Error("platform: mkstemp failed: template contains NUL")
    var buffer = c_string_bytes(template)
    # SAFETY: libc `mkstemp` has the exact ABI `int mkstemp(char*)`. `buffer`
    # uniquely owns a fully initialized writable copy of `template` plus its
    # NUL terminator, and validation above proves the visible bytes end in six
    # `X` bytes with no earlier NUL. The pointer has this local list's mutable
    # origin, stays live across the synchronous call, and does not escape:
    # `mkstemp` mutates only those six initialized `X` bytes in place, reads no
    # byte beyond the terminator, and retains no pointer. On success the return
    # is the sole descriptor for a newly created mode-0600 regular file, which
    # transfers to the caller; on failure no descriptor or file is created.
    # The list remains owned here on both paths and is released after errno/path
    # extraction, so partial initialization and foreign ownership cannot leak.
    var raw_fd = external_call["mkstemp", Int32](
        buffer.unsafe_ptr().bitcast[NoneType]()
    )
    var err = errno_now() if raw_fd < 0 else 0
    if raw_fd < 0:
        _ = buffer^
        raise Error(
            "platform: mkstemp failed for '"
            + template
            + "' (errno "
            + String(err)
            + ")"
        )
    _ = buffer.pop()
    # SAFETY: `template` was valid UTF-8 and `mkstemp` replaced only its final
    # six ASCII `X` bytes with filename-safe ASCII bytes. Removing the one NUL
    # terminator leaves exactly the initialized, valid UTF-8 path bytes.
    # `String` copies the span before `buffer` is consumed; the borrow neither
    # escapes nor outlives its owner.
    var path = String(StringSlice(unsafe_from_utf8=Span(buffer)))
    _ = buffer^
    return UniqueTempFile(path^, Int(raw_fd))


def write_all_fd(fd: Int, text: String) raises:
    """Write every byte of `text` to `fd`, handling shorts and `EINTR`.

    Args:
        fd: An open descriptor owned by the caller.
        text: The complete bytes to write. Not mutated.

    Raises:
        Error: On a non-interrupted error or zero/impossible progress. The
            descriptor stays owned by the caller and must still be closed.
    """
    var bytes = text.as_bytes()
    var total = len(bytes)
    var offset = 0
    while offset < total:
        # SAFETY: `bytes` borrows `text` for this whole loop. `offset` is in
        # `[0, total)`, so the derived pointer addresses exactly the remaining
        # `total - offset` initialized bytes. `write_fd` retains no pointer and
        # mutates no input bytes; `text` outlives every synchronous call.
        var count = write_fd(fd, bytes.unsafe_ptr() + offset, total - offset)
        if count < 0:
            var err = errno_now()
            if err == _EINTR:
                continue
            raise Error(
                "platform: write failed for temporary file descriptor (errno "
                + String(err)
                + ")"
            )
        if count == 0 or count > total - offset:
            raise Error(
                "platform: write failed for temporary file descriptor:"
                " impossible progress"
            )
        offset += count
    _ = bytes


def close_checked_fd(fd: Int) raises:
    """Close one owned temporary-file descriptor exactly once.

    Args:
        fd: The descriptor to consume. The caller must not use or close it
            again, including when this function raises.

    Raises:
        Error: If `close(2)` reports any failure. It is never retried because
            the descriptor may already have been released and reused.
    """
    if close_fd(fd) != 0:
        var err = errno_now()
        raise Error(
            "platform: close failed for temporary file descriptor (errno "
            + String(err)
            + ")"
        )
