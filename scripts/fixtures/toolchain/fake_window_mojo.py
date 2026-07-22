#!/usr/bin/env python3
"""Window-recording `--mojo` stand-in — proves builds overlap under the pool.

Test-only toolchain shim. Passing this file to `mtest --mojo` routes every child
`mojo build`/`mojo precompile` spawn through this script first, exactly as the
adjacent `logging_mojo.py` does. Unlike that wrapper — which `os.execv`s and can
therefore only stamp the START of a build — this shim must record BOTH edges of a
build's wall-clock window so the harness can prove two builds ran concurrently.
So it SPAWN-AND-WAITs the real compiler instead of exec-replacing itself:

1. `MTEST_WINDOW_LOG` names an append log. On a `build`/`precompile` subcommand it
   appends `build\\t<target>\\t<start_monotonic>` before the compile and
   `build\\t<target>\\t<end_monotonic>\\t<returncode>` after it. Unset → the shim
   is a transparent passthrough that records nothing.
2. A BUILD FLOOR (`MTEST_WINDOW_BUILD_FLOOR` seconds, default 0.3) keeps every
   window observably wide. It floors the WALL time from the start stamp to the
   end stamp — a slow real build is not double-charged, only a fast one is padded.
3. SIGTERM/SIGINT are forwarded to the spawned child, then the shim exits with the
   signal-derived code (128 + signo), so the pool's process-group sweep tears the
   shim AND its real-`mojo` child down together and leaves no orphan.

`run` and every other subcommand are a transparent passthrough — runs are executed
by mtest directly, never via `--mojo`, so run windows come from the fixtures, not
this shim.

Stdlib only, no third-party imports — this is build-time harness code, not part of
the pure-Mojo product.
"""

from __future__ import annotations

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

    Waits briefly for the child to fall so the pool's group sweep reaps a clean
    tree rather than an orphaned compiler.
    """
    child = _child
    if child is not None and child.poll() is None:
        try:
            child.send_signal(signum)
            child.wait(timeout=5.0)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                child.kill()
            except ProcessLookupError:
                pass
    os._exit(128 + signum)


def _run_build(real_mojo: str, subcommand: str, args: list[str]) -> int:
    """Spawn the real compiler, stamp both window edges, and floor the window."""
    global _child
    log_path = os.environ.get(LOG_ENV_VAR)
    target = args[1] if len(args) > 1 else ""

    signal.signal(signal.SIGTERM, _forward_signal)
    signal.signal(signal.SIGINT, _forward_signal)

    start = time.monotonic()
    if log_path:
        _append(log_path, f"build\t{target}\t{start:.6f}\n")

    _child = subprocess.Popen([real_mojo, *args])
    returncode = _child.wait()

    # Floor the WHOLE window (start stamp to end stamp), so a fast build is padded
    # but a slow real build is never charged twice.
    remaining = _build_floor() - (time.monotonic() - start)
    if remaining > 0:
        time.sleep(remaining)

    end = time.monotonic()
    if log_path:
        _append(log_path, f"build\t{target}\t{end:.6f}\t{returncode}\n")
    return returncode


def main() -> int:
    args = sys.argv[1:]
    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("fake_window_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    if len(args) > 0 and args[0] in ("build", "precompile"):
        return _run_build(real_mojo, args[0], args)

    os.execv(real_mojo, [real_mojo, *args])
    return 1  # unreachable: a successful os.execv never returns


if __name__ == "__main__":
    sys.exit(main())
