#!/usr/bin/env python3
"""Crashing-compiler `--mojo` stand-in — drives the PRECOMPILE crash-retry path.

Stands in for the real `mojo` binary the same way `scripts/logging_mojo.py` and
`scripts/fake_slow_mojo.py` do: `mtest --mojo scripts/fake_crash_mojo.py ...`
routes every child mtest spawns through this script first. It splits by
subcommand:

* `precompile` — TRUNCATES its `-o` output path, prints a compiler-crash banner to
  stderr, and then DIES BY SIGSEGV, the way a real compiler ICE ends. That is the
  crash class `--retries` exists for: mtest must retry it (quarantined, on a fresh
  temp path) and, when the budget runs out, report PRECOMPILE-ERROR naming the
  signal in words. It leaves a half-written package behind at `-o`, exactly as a
  compiler killed mid-write would — so a pre-existing OUT survives ONLY if mtest
  never pointed the compiler at OUT in the first place.
* anything else (`build`, `--version`, ...) — EXECS the real `mojo` found on PATH
  with the untouched argv, so this wrapper stays a transparent stand-in outside
  the one path it exists to crash on.

Dying by a real signal (rather than exiting nonzero) keeps the fixture honest:
the supervisor must observe a SIGNALED termination, not a status this script
chose. It is instant, so the e2e stays fast.

Stdlib only, no third-party imports — this is build-time harness code, not part
of the pure-Mojo product.
"""

from __future__ import annotations

import os
import shutil
import signal
import sys


def _clobber_output(args: list[str]) -> None:
    """Truncate the `-o` path, the way a real compile does before it finishes."""
    if "-o" not in args:
        return
    out = args[args.index("-o") + 1]
    parent = os.path.dirname(out)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(out, "wb") as handle:
        handle.write(b"fake_crash_mojo.py: PARTIAL OUTPUT, CRASHED MID-WRITE\n")


def _crash_precompile(args: list[str]) -> int:
    # Own the output path first: the damage a real compiler would do is the whole
    # reason the promotion contract exists.
    _clobber_output(args)
    # Emit BEFORE dying and flush: the bytes must be in mtest's capture pipe
    # when the process disappears, so the banner can render them verbatim.
    sys.stderr.write("fake_crash_mojo.py: precompile: lowering module\n")
    sys.stderr.write("PLEASE submit a bug report to https://example.invalid/\n")
    sys.stderr.flush()
    # Die by a real signal — the supervisor must see SIGNALED, not a chosen exit.
    os.kill(os.getpid(), signal.SIGSEGV)
    signal.pause()
    return 1  # unreachable: the SIGSEGV above never returns


def main() -> int:
    args = sys.argv[1:]
    if len(args) > 0 and args[0] == "precompile":
        return _crash_precompile(args)

    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("fake_crash_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    os.execv(real_mojo, [real_mojo, *args])
    return 1  # unreachable: a successful os.execv never returns


if __name__ == "__main__":
    sys.exit(main())
