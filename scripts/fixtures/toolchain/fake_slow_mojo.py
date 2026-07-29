#!/usr/bin/env python3
"""Slow-compiler `--mojo` stand-in for the COMPILE-TIMEOUT path.

Stands in for the real `mojo` binary the way the adjacent `logging_mojo.py`
does, routing every child mtest spawns through this script first and splitting by
subcommand:

* `build` and `precompile`: truncate the `-o` output path (see below), write one
  progress line to stderr (so the COMPILE-TIMEOUT / PRECOMPILE-ERROR banner has
  real compiler output to render verbatim), then sleep far longer than any
  deadline the scenario sets. They never finish on their own; mtest's
  `--compile-timeout` is the only thing that ends them, and it bounds both
  compile subcommands, so both are slowed here.
* anything else (`--version`, ...): execs the real `mojo` found on PATH with the
  untouched argv, as `logging_mojo.py` does, so this wrapper stays a transparent
  stand-in outside the paths it exists to slow down.

Clobbering `-o` before sleeping is what makes the precompile promotion scenario
discriminating. A real `mojo precompile` owns its output path from the moment it
starts, so a shim that ignored `-o` would leave a pre-existing OUT intact even
under eager promotion. Destroying it means the sentinel survives only because
mtest pointed the compiler at a temp path.

SIGTERM is handled and exits promptly, well inside mtest's compile grace, which
exercises the graceful half of the supervised kill protocol. A shim that ignored
SIGTERM would only ever prove the SIGKILL fallback.

Stdlib only: this is build-time harness code, outside the pure-Mojo product.
"""

from __future__ import annotations

import os
import shutil
import signal
import sys
import time


# Longer than any deadline the e2e sets, and longer than the harness's own
# per-scenario timeout: the build must never complete by racing the clock, or
# the scenario would stop testing the timeout at all.
SLEEP_SECONDS = 300.0

# The exit status a SIGTERMed process conventionally reports. mtest never reads
# it (the supervisor reports the file as TimedOut because it did the killing),
# but exiting on a plain code keeps the shim honest under manual invocation.
SIGTERM_EXIT = 128 + signal.SIGTERM


def _on_sigterm(_signum: int, _frame: object) -> None:
    """Exit promptly, well within mtest's compile grace."""
    sys.stderr.write("fake_slow_mojo.py: SIGTERM received; exiting\n")
    sys.stderr.flush()
    os._exit(SIGTERM_EXIT)


def _clobber_output(args: list[str]) -> None:
    """Truncate the `-o` path, the way a real compile does before it finishes."""
    if "-o" not in args:
        return
    out = args[args.index("-o") + 1]
    parent = os.path.dirname(out)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(out, "wb") as handle:
        handle.write(b"fake_slow_mojo.py: PARTIAL OUTPUT, NEVER COMPLETED\n")


def _slow_compile(subcommand: str, args: list[str]) -> int:
    signal.signal(signal.SIGTERM, _on_sigterm)
    # Destroy whatever is at `-o` before sleeping: a real compiler owns that path
    # from the moment it starts, and mtest's promotion contract is what keeps a
    # good OUT out of its reach.
    _clobber_output(args)
    # Emit before sleeping, and flush: the bytes must already be in mtest's
    # capture pipe when the deadline fires, so the banner can show them.
    sys.stderr.write(
        f"fake_slow_mojo.py: {subcommand}: lowering module (this will not finish)\n"
    )
    sys.stderr.flush()
    time.sleep(SLEEP_SECONDS)
    # Only reachable if nothing killed us, i.e. the deadline did not fire.
    sys.stderr.write("fake_slow_mojo.py: slept the full sleep; no deadline fired\n")
    return 1


def main() -> int:
    """Slow a compile past every deadline, or exec the real compiler untouched.

    Returns:
        1 if a `build`/`precompile` somehow slept its full sleep with no deadline
        firing, or 127 when no real `mojo` is on PATH. Every other subcommand
        `os.execv`s the real compiler, so this function does not return for
        those.
    """
    args = sys.argv[1:]
    if len(args) > 0 and args[0] in ("build", "precompile"):
        return _slow_compile(args[0], args)

    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("fake_slow_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    os.execv(real_mojo, [real_mojo, *args])
    # typeshed types os.execv as NoReturn, so mypy sees this as dead. Kept as
    # the fallback if that ever changes.
    return 1  # type: ignore[unreachable]


if __name__ == "__main__":
    sys.exit(main())
