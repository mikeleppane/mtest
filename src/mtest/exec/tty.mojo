"""The terminal probes: `stdout_isatty`, `stderr_isatty` (Layer 3).

`--color auto` colorizes only when the console's destination is a real
terminal, and answering that needs the `isatty(2)` syscall. Every fd-facing
call in the runner is confined to this layer, so `main` asks `stdout_isatty()`
or `stderr_isatty()` rather than reaching for the fd directly itself — reading
a fd's terminal-ness above `exec` would be a layering break. Both probe fd 1 or
fd 2 specifically because the console's destination fd is resolved by its
caller, not guessed here; this module answers "is THIS fd a terminal", nothing
more.

`_fd_isatty` delegates to `std.io.FileDescriptor.isatty()` rather than a raw
`external_call["isatty", ...]` of its own: the stdlib's `TestSuite` already
declares that same libc symbol through `FileDescriptor` (for its own
pass/fail output), and a second, independently-attributed `external_call`
declaration for the identical C symbol in the same compiled binary is a
link-time attribute conflict the Mojo toolchain rejects outright — reproduced
against the untouched, pre-existing `stdout_isatty()` the moment any unit test
imports it alongside `TestSuite`. Going through `FileDescriptor` reuses the
stdlib's own declaration instead of shadowing it, which is also why this probe
carries no `# SAFETY:` comment: there is no raw FFI call here for one to
document.
"""
from std.io import FileDescriptor


def _fd_isatty(fd: Int32) -> Bool:
    """Whether file descriptor `fd` is connected to a terminal.

    The shared `isatty(2)` wrapper both public probes call. Returns `False`
    for a pipe, a file, a closed fd, or any non-terminal fd. Pure with respect
    to the program's own state; performs no allocation and never raises.

    Args:
        fd: The file descriptor to probe.

    Returns:
        `True` iff `fd` is a terminal.
    """
    return FileDescriptor(Int(fd)).isatty()


def stdout_isatty() -> Bool:
    """Whether standard output (fd 1) is connected to a terminal.

    Wraps `isatty(2)` so callers above `exec` never touch a raw fd themselves.
    Returns `False` for a pipe, a file, or any non-terminal fd. Pure with respect
    to the program's own state; performs no allocation and never raises.

    Returns:
        `True` iff fd 1 is a terminal.
    """
    return _fd_isatty(1)


def stderr_isatty() -> Bool:
    """Whether standard error (fd 2) is connected to a terminal.

    Wraps `isatty(2)` so callers above `exec` never touch a raw fd themselves.
    Returns `False` for a pipe, a file, or any non-terminal fd. Pure with respect
    to the program's own state; performs no allocation and never raises.

    Returns:
        `True` iff fd 2 is a terminal.
    """
    return _fd_isatty(2)
