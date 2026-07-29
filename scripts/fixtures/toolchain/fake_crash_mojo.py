#!/usr/bin/env python3
"""Crashing-compiler `--mojo` stand-in for the compiler crash-retry paths.

Stands in for the real `mojo` binary the way the adjacent `logging_mojo.py` and
`fake_slow_mojo.py` do, routing every child mtest spawns through this script
first and splitting by subcommand:

* `precompile`: truncates its `-o` output path, prints a compiler-crash banner to
  stderr, then dies by SIGSEGV, the way a real compiler ICE ends. That is the
  crash class `--retries` exists for: mtest must retry it (quarantined, on a
  fresh temp path) and, when the budget runs out, report PRECOMPILE-ERROR naming
  the signal in words. The half-written package left at `-o` means a pre-existing
  OUT survives only if mtest never pointed the compiler at OUT.
* `build`, only when `MTEST_FAKE_BUILD_CRASH` is set: fails the build by exiting
  nonzero (never by a signal), with stderr chosen by the variable:
    - `signature`: an LLVM/Mojo ICE banner ("PLEASE submit a bug report ...",
      "Stack dump:", a stack frame). A compiler that crashed but still exited
      under its own control, so crash-class and retryable.
    - `plain`: an ordinary diagnostic, no banner. Deterministic, so mtest must
      not retry it.
  The two modes differ only in the stderr text (same argv, same exit status, no
  `-o` either way), so the pair proves that the crash-signature scan, rather than
  the nonzero exit alone, decides retry eligibility.
* anything else (an unkeyed `build`, `--version`, ...): execs the real `mojo`
  found on PATH with the untouched argv, so this wrapper stays a transparent
  stand-in outside the paths it exists to fail on. The precompile scenarios rely
  on that, leaving `MTEST_FAKE_BUILD_CRASH` unset to get real builds.

Dying by a real signal on `precompile` keeps that fixture honest: the supervisor
must observe a SIGNALED termination rather than a status this script chose.

Stdlib only: this is build-time harness code, outside the pure-Mojo product.
"""

from __future__ import annotations

import os
import shutil
import signal
import sys


BUILD_CRASH_ENV_VAR = "MTEST_FAKE_BUILD_CRASH"

# The two stderr texts of the discriminating pair. Everything else about the two
# modes is identical, so this text is the only input that can move the retry
# decision. `signature` carries the markers `has_crash_signature` pins (the ICE
# banner, a `Stack dump` header, a symbol-less frame); `plain` carries a mundane
# compile diagnostic that must never look like a crash.
BUILD_CRASH_STDERR = {
    "signature": (
        "fake_crash_mojo.py: build: lowering module\n"
        "PLEASE submit a bug report to https://example.invalid/ and include the"
        " crash backtrace.\n"
        "Stack dump:\n"
        "0\tfake-mojo   0x000000010049beef\n"
    ),
    "plain": (
        "fake_crash_mojo.py: build: lowering module\n"
        "e2e/suite/test_passing.mojo:1:1: error: fabricated ordinary compile"
        " error (no crash banner)\n"
        "fake_crash_mojo.py: build: 1 error emitted\n"
    ),
}
BUILD_CRASH_EXIT = 1


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
    # Own the output path first: the damage a real compiler would do is why the
    # promotion contract exists.
    _clobber_output(args)
    # Emit before dying, and flush: the bytes must be in mtest's capture pipe
    # when the process disappears, so the banner can render them verbatim.
    sys.stderr.write("fake_crash_mojo.py: precompile: lowering module\n")
    sys.stderr.write("PLEASE submit a bug report to https://example.invalid/\n")
    sys.stderr.flush()
    # Die by a real signal: the supervisor must see SIGNALED, not a chosen exit.
    os.kill(os.getpid(), signal.SIGSEGV)
    signal.pause()
    return 1  # unreachable: the SIGSEGV above never returns


def _fail_build_nonzero(mode: str) -> int:
    """Fail `build` by a chosen nonzero exit, with the mode's stderr text.

    No signal and no `-o` written: a compile that produced no binary and said so
    on stderr, leaving the retry decision to rest on the stderr text alone.
    """
    text = BUILD_CRASH_STDERR.get(mode)
    if text is None:
        known = ", ".join(sorted(BUILD_CRASH_STDERR))
        sys.stderr.write(
            f"fake_crash_mojo.py: unknown {BUILD_CRASH_ENV_VAR}={mode!r}"
            f" (expected one of: {known})\n"
        )
        return 2
    sys.stderr.write(text)
    sys.stderr.flush()
    return BUILD_CRASH_EXIT


def main() -> int:
    """Crash the requested compile phase, or exec the real compiler untouched.

    A `precompile` always takes the crash path. A `build` crashes only when the
    mode env var is set, so one shim serves both the precompile-crash and the
    build-failure scenarios without either leaking into the other.

    Returns:
        The mode's chosen exit code, 2 for an unknown mode word, or 127 when no
        real `mojo` is on PATH. An uninstrumented subcommand `os.execv`s the real
        compiler, so this function does not return for those.
    """
    args = sys.argv[1:]
    if len(args) > 0 and args[0] == "precompile":
        return _crash_precompile(args)
    if len(args) > 0 and args[0] == "build":
        mode = os.environ.get(BUILD_CRASH_ENV_VAR)
        if mode is not None:
            return _fail_build_nonzero(mode)

    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("fake_crash_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    os.execv(real_mojo, [real_mojo, *args])
    # typeshed types os.execv as NoReturn, so mypy sees this as dead. Kept as
    # the fallback if that ever changes.
    return 1  # type: ignore[unreachable]


if __name__ == "__main__":
    sys.exit(main())
