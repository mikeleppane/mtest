#!/usr/bin/env python3
r"""Window-recording `--mojo` stand-in that proves builds overlap under the pool.

Test-only toolchain shim. Passing this file to `mtest --mojo` routes every child
`mojo build`/`mojo precompile` spawn through this script first, as the adjacent
`logging_mojo.py` does. That wrapper `os.execv`s and can therefore stamp only the
start of a build; proving two builds overlapped needs both edges of the window,
so this shim spawns and waits on the real compiler instead:

1. `MTEST_WINDOW_LOG` names an append log. On a `build`/`precompile` subcommand it
   appends `build\t<target>\t<start_monotonic>` before the compile and
   `build\t<target>\t<end_monotonic>\t<returncode>` after it. When unset, the
   shim is a transparent passthrough that records nothing.
2. A build floor (`MTEST_WINDOW_BUILD_FLOOR` seconds, see
   `DEFAULT_FLOOR_SECONDS`) keeps every window observably wide. It floors the
   wall time from the start stamp to the end stamp, so only a fast build is
   padded and a slow real one is never charged twice.
3. SIGTERM/SIGINT are forwarded to the spawned child, then the shim exits with the
   signal-derived code (128 + signo), so the pool's process-group sweep tears the
   shim and its real-`mojo` child down together and leaves no orphan.

`run` and every other subcommand pass through untouched. mtest executes runs
directly rather than via `--mojo`, so run windows come from the fixtures.

Stdlib only: this is build-time harness code, outside the pure-Mojo product.
"""

from __future__ import annotations

import contextlib
import os
import shutil
import signal
import subprocess
import sys
import time


LOG_ENV_VAR = "MTEST_WINDOW_LOG"
FLOOR_ENV_VAR = "MTEST_WINDOW_BUILD_FLOOR"
DEFAULT_FLOOR_SECONDS = 0.3

# The child the signal handler must tear down alongside this shim. Set once the
# real compiler is spawned; read by the handler installed for that window.
_child: subprocess.Popen[bytes] | None = None


def _append(log_path: str, line: str) -> None:
    """Append one already-newline-terminated record to the window log."""
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(line)


def _build_floor() -> float:
    """The minimum wall time a build window spans, from the env or the default."""
    raw = os.environ.get(FLOOR_ENV_VAR)
    if not raw:
        return DEFAULT_FLOOR_SECONDS
    try:
        return float(raw)
    except ValueError:
        return DEFAULT_FLOOR_SECONDS


def _forward_signal(signum: int, _frame: object) -> None:
    """Forward the signal to the spawned child, then exit 128 + signo.

    Waits for the child to fall, so the pool's group sweep reaps a clean tree
    rather than an orphaned compiler.
    """
    child = _child
    if child is not None and child.poll() is None:
        try:
            child.send_signal(signum)
            child.wait(timeout=5.0)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            with contextlib.suppress(ProcessLookupError):
                child.kill()
    os._exit(128 + signum)


def _run_build(real_mojo: str, _subcommand: str, args: list[str]) -> int:
    """Spawn the real compiler, stamp both window edges, and floor the window.

    Both compile subcommands are stamped under the single literal `build` tag,
    which is what `scripts.e2e.scenarios.parallel` filters records on, so the
    caller's subcommand word is accepted and deliberately not recorded.

    Args:
        real_mojo: Absolute path to the real compiler to spawn and wait on.
        _subcommand: The `build`/`precompile` word, unused by design (see above).
        args: The wrapper's argv tail, passed to the real compiler untouched.
            `args[1]`, when present, is the target source path used as the
            window's key in the log.

    Returns:
        The real compiler's exit code.
    """
    # The signal handler installed below must reach the spawned child, and a
    # handler can only see module state.
    global _child  # noqa: PLW0603
    log_path = os.environ.get(LOG_ENV_VAR)
    target = args[1] if len(args) > 1 else ""

    signal.signal(signal.SIGTERM, _forward_signal)
    signal.signal(signal.SIGINT, _forward_signal)

    start = time.monotonic()
    if log_path:
        _append(log_path, f"build\t{target}\t{start:.6f}\n")

    _child = subprocess.Popen([real_mojo, *args])
    returncode = _child.wait()

    # Floor the whole window (start stamp to end stamp), so a fast build is
    # padded but a slow real build is never charged twice.
    remaining = _build_floor() - (time.monotonic() - start)
    if remaining > 0:
        time.sleep(remaining)

    end = time.monotonic()
    if log_path:
        _append(log_path, f"build\t{target}\t{end:.6f}\t{returncode}\n")
    return returncode


def main() -> int:
    """Record a window around a compile, or exec the real compiler untouched.

    Returns:
        127 when no real `mojo` is on PATH, or the real compiler's exit code for
        a `build`/`precompile` window. Every other subcommand `os.execv`s the
        real compiler, so this function does not return for those.
    """
    args = sys.argv[1:]
    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("fake_window_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    if len(args) > 0 and args[0] in ("build", "precompile"):
        return _run_build(real_mojo, args[0], args)

    os.execv(real_mojo, [real_mojo, *args])
    # typeshed types os.execv as NoReturn, so mypy sees this as dead. Kept as
    # the fallback if that ever changes.
    return 1  # type: ignore[unreachable]


if __name__ == "__main__":
    sys.exit(main())
