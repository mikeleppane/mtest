"""The terminal probes: `stdout_isatty`, `stderr_isatty`.

`--color auto` colorizes only when the console's destination is a real
terminal, and answering that needs the `isatty(2)` syscall. Every fd-facing
call in the runner is confined to this layer, so `main` asks `stdout_isatty()`
or `stderr_isatty()` rather than reaching for the fd itself; reading a fd's
terminal-ness above `exec` would be a layering break. Each probe names fd 1 or
fd 2 specifically, because the console's destination fd is resolved by its
caller, not guessed here.

`_fd_isatty` delegates to `std.io.FileDescriptor.isatty()` rather than a raw
`external_call["isatty", ...]` of its own. The stdlib's `TestSuite` already
declares that same libc symbol through `FileDescriptor`, and a second,
independently-attributed `external_call` declaration for the identical C symbol
in one compiled binary is a link-time attribute conflict the Mojo toolchain
rejects outright — it appears as soon as any unit test imports these probes
alongside `TestSuite`. Going through `FileDescriptor` reuses the stdlib's
declaration instead of shadowing it, which is also why this module carries no
`# SAFETY:` comment: there is no raw FFI call here to document.
"""
from std.io import FileDescriptor


def _fd_isatty(fd: Int32) -> Bool:
    """Whether file descriptor `fd` is connected to a terminal.

    The shared `isatty(2)` wrapper both public probes call.

    Args:
        fd: The file descriptor to probe.

    Returns:
        `True` iff `fd` is a terminal; `False` for a pipe, a file, a closed fd,
        or any other non-terminal fd.
    """
    return FileDescriptor(Int(fd)).isatty()


def stdout_isatty() -> Bool:
    """Whether standard output (fd 1) is connected to a terminal.

    Wraps `isatty(2)` so callers above `exec` never touch a raw fd themselves.

    Returns:
        `True` iff fd 1 is a terminal; `False` for a pipe, a file, or any other
        non-terminal fd.
    """
    return _fd_isatty(1)


def stderr_isatty() -> Bool:
    """Whether standard error (fd 2) is connected to a terminal.

    Wraps `isatty(2)` so callers above `exec` never touch a raw fd themselves.

    Returns:
        `True` iff fd 2 is a terminal; `False` for a pipe, a file, or any other
        non-terminal fd.
    """
    return _fd_isatty(2)
