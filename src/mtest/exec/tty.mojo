"""The terminal probe: `stdout_isatty` (Layer 3).

`--color auto` colorizes only when stdout is a real terminal, and answering that
needs the `isatty(2)` syscall. Every FFI call in the runner is confined to this
layer, so `main` asks `stdout_isatty()` rather than reaching for a raw syscall of
its own — a syscall above `exec` would be a layering break. This is the whole of
the addition: one `isatty` call, no state.
"""
from std.ffi import external_call


def stdout_isatty() -> Bool:
    """Whether standard output (fd 1) is connected to a terminal.

    Wraps the libc `isatty(2)` syscall so callers above `exec` never touch FFI.
    Returns `False` for a pipe, a file, or any non-terminal fd. Pure with respect
    to the program's own state; performs no allocation and never raises.

    Returns:
        `True` iff fd 1 is a terminal.
    """
    return external_call["isatty", Int32](Int32(1)) == 1
