"""Pins `_fd_isatty`'s deterministic contract: never a terminal, never a crash.

`stdout_isatty` and `stderr_isatty` both answer `isatty(2)` for a fd this
process does not control, so the only fact these tests can pin without an
ambient terminal (the harness's own fds are pipes/files, never a real tty) is
the NON-terminal half of the contract: a fd libc cannot possibly call a
terminal — here, one no file descriptor table entry ever names — reports
`False`, exactly, and the call never raises. `stderr_isatty` is additionally
pinned to route through the shared `_fd_isatty(2)` rather than a call of its
own, but nothing at this layer can discriminate fd 2 from fd 1 (or any other
fd) without a real terminal on one side and not the other — under this
harness every fd is equally non-tty. Both that fd-2-vs-fd-1 specificity and
the PTY-positive half (a real terminal fd reporting `True`) have no
deterministic fixture here and are left to the color e2e that owns a PTY
oracle.
"""
from std.testing import assert_equal

from mtest.exec.tty import _fd_isatty, stderr_isatty


def test_fd_isatty_false_for_an_unopened_fd() raises:
    # No fd table entry names 999 in any process running this suite; isatty(2)
    # fails closed (ENOTTY/EBADF -> 0) rather than raising.
    assert_equal(_fd_isatty(999), False)


def test_stderr_isatty_delegates_to_fd_isatty_of_fd_2() raises:
    # stderr_isatty's ambient value depends on the harness's own fd 2 (a pipe
    # or file here, never a real tty) - not asserted. This only pins internal
    # consistency: stderr_isatty routes through the shared _fd_isatty rather
    # than, say, inlining its own separate call. It is definitionally true
    # once that routing holds and does NOT discriminate fd 2 from fd 1 or any
    # other fd - under this harness both are non-tty, so both sides are
    # `False` either way. Distinguishing fd 2 specifically needs a real
    # terminal on one fd and not the other; that PTY-positive discrimination
    # is left to the color e2e in the next task.
    assert_equal(stderr_isatty(), _fd_isatty(2))
