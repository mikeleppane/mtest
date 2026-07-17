#!/usr/bin/env python3
"""Slow-compiler `--mojo` stand-in — drives the COMPILE-TIMEOUT path.

Stands in for the real `mojo` binary the same way `scripts/logging_mojo.py`
does: `mtest --mojo scripts/fake_slow_mojo.py ...` routes every child mtest
spawns through this script first. It splits by subcommand:

* `build` — writes one progress line to stderr (so the COMPILE-TIMEOUT banner has
  real compiler output to render verbatim), then sleeps far longer than any
  deadline the scenario sets. It NEVER finishes on its own; mtest's
  `--compile-timeout` is the only thing that ends it.
* anything else (`precompile`, `--version`, ...) — EXECS the real `mojo` found on
  PATH with the untouched argv, exactly like `logging_mojo.py`, so this wrapper
  stays a transparent stand-in outside the one path it exists to slow down.

SIGTERM is handled and exits PROMPTLY — well inside mtest's 5-second compile
grace. That is deliberate on both counts: it keeps the e2e fast (no waiting out
the grace, no SIGKILL escalation), and it exercises the GRACEFUL half of the
supervised kill protocol, which is the half a real compiler flushing its module
cache would take. A shim that ignored SIGTERM would only ever prove the SIGKILL
fallback.

Stdlib only, no third-party imports — this is build-time harness code, not part
of the pure-Mojo product.
"""

from __future__ import annotations

import os
import shutil
import signal
import sys
import time

# Longer than any deadline the e2e sets, and longer than the harness's own
# per-scenario timeout: the build must never complete by racing the clock, or
# the scenario would silently stop testing the timeout at all.
SLEEP_SECONDS = 300.0

# The exit status a SIGTERMed process conventionally reports. mtest never reads
# it — the supervisor reports the file as TimedOut because IT did the killing —
# but exiting on a plain code keeps the shim honest under manual invocation.
SIGTERM_EXIT = 128 + signal.SIGTERM


def _on_sigterm(_signum: int, _frame: object) -> None:
    """Exit promptly, well within mtest's compile grace."""
    sys.stderr.write("fake_slow_mojo.py: SIGTERM received; exiting\n")
    sys.stderr.flush()
    os._exit(SIGTERM_EXIT)


def _slow_build() -> int:
    signal.signal(signal.SIGTERM, _on_sigterm)
    # Emit BEFORE sleeping and flush: the bytes must already be in mtest's
    # capture pipe when the deadline fires, so the banner can show them.
    sys.stderr.write("fake_slow_mojo.py: lowering module (this will not finish)\n")
    sys.stderr.flush()
    time.sleep(SLEEP_SECONDS)
    # Only reachable if nothing ever killed us — i.e. the deadline did not fire.
    sys.stderr.write("fake_slow_mojo.py: slept the full sleep; no deadline fired\n")
    return 1


def main() -> int:
    args = sys.argv[1:]
    if len(args) > 0 and args[0] == "build":
        return _slow_build()

    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("fake_slow_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    os.execv(real_mojo, [real_mojo, *args])
    return 1  # unreachable: a successful os.execv never returns


if __name__ == "__main__":
    sys.exit(main())
