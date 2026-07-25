#!/usr/bin/env python3
"""Stubborn-compiler `--mojo` stand-in — the double-interrupt teardown witness.

Stands in for the real `mojo` binary the way the adjacent `logging_mojo.py`
does, and is transparent everywhere except one named target: any invocation
whose argv does NOT contain `MTEST_STUBBORN_TARGET` EXECS the real `mojo` with
the untouched argv, so the file before the target still builds, runs, and passes
for real.

For the named target's compile it becomes the live child group the interrupt
scenario needs, and it is the only actor in this repository that can WITNESS
mtest's polite teardown:

* it records its own process-group id, so the harness can prove that group gone;
* it catches SIGTERM and, instead of exiting, writes a teardown marker — mtest's
  polite signal cannot end it, exactly as a `SIG_IGN` fixture refuses it, but
  the arrival is observable, which is what tells the harness that teardown has
  actually begun;
* it announces readiness only once both are in place, then sleeps far past any
  deadline.

A Mojo fixture cannot do the middle step. Signal DISPOSITIONS are process-wide
but discard an ignored signal outright, while a signal MASK is per-thread and the
Mojo runtime holds several threads that would take the delivery instead. Python
owns its whole process here, so the witness lives on this side of the toolchain
boundary.

Compile steps get mtest's 5-second grace rather than the run step's 300 ms, so
the second interrupt has a wide, unambiguous margin in which to prove it is what
ended the group.

Stdlib only, no third-party imports — this is build-time harness code, not part
of the pure-Mojo product.
"""

from __future__ import annotations

import os
import shutil
import signal
import sys
import time

TARGET_ENV_VAR = "MTEST_STUBBORN_TARGET"
"""The repo-relative source path whose compile blocks instead of building."""
PGID_ENV_VAR = "MTEST_STUBBORN_PGID_FILE"
"""Where the blocked compile records its real process-group id."""
READY_ENV_VAR = "MTEST_STUBBORN_READY_FILE"
"""Where the blocked compile announces that it is armed and holding."""
TEARDOWN_ENV_VAR = "MTEST_STUBBORN_TEARDOWN_FILE"
"""Where the blocked compile announces that it observed mtest's SIGTERM."""

# Longer than any deadline the e2e sets and than the harness's own per-scenario
# budget: this compile must never finish by racing the clock, or the scenario
# would silently stop testing the interrupt at all.
SLEEP_SECONDS = 300.0


def _write(path: str, text: str) -> None:
    """Write one marker whole, creating its parent if needed."""
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def _on_sigterm(_signum: int, _frame: object) -> None:
    """Record mtest's polite teardown signal and REFUSE to die on it."""
    path = os.environ.get(TEARDOWN_ENV_VAR)
    if path:
        _write(path, "teardown\n")


def _hold() -> int:
    """Arm the witness, announce it, and block until something kills us."""
    signal.signal(signal.SIGTERM, _on_sigterm)
    pgid_path = os.environ.get(PGID_ENV_VAR)
    if pgid_path:
        _write(pgid_path, f"{os.getpgrp()}\n")
    sys.stderr.write("fake_stubborn_mojo.py: holding this compile open\n")
    sys.stderr.flush()
    # Announced LAST, so readiness implies the handler and the recorded group id
    # are both already in place and a harness signalling on it races neither.
    ready_path = os.environ.get(READY_ENV_VAR)
    if ready_path:
        _write(ready_path, "ready\n")
    deadline = time.monotonic() + SLEEP_SECONDS
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        # A caught SIGTERM interrupts the sleep; resume rather than return, so
        # only a SIGKILL can end this process.
        time.sleep(min(remaining, 1.0))
    sys.stderr.write("fake_stubborn_mojo.py: slept the full sleep; never killed\n")
    return 1


def main() -> int:
    """Hold the named target's compile open; exec the real `mojo` otherwise."""
    args = sys.argv[1:]
    target = os.environ.get(TARGET_ENV_VAR)
    if target and target in args:
        return _hold()

    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("fake_stubborn_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    os.execv(real_mojo, [real_mojo, *args])
    return 1  # unreachable: a successful os.execv never returns


if __name__ == "__main__":
    sys.exit(main())
