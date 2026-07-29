#!/usr/bin/env python3
"""Logging `--mojo` wrapper that proves the single-build reuse guarantee.

Passing this file to `mtest --mojo` routes every child mtest spawns
(`mojo build <file> ...`, `mojo precompile <file> ...`) through this script
first. It:

1. Reads a log file path from the `MTEST_MOJO_LOG` environment variable.
2. Appends one line recording the subcommand (`build`/`precompile`/...) and the
   target source path, plus the full argv for debugging.
   `scripts.e2e.scenarios.selection` parses the first two fields to count how
   many times a given file was built.
3. Execs the real `mojo` found on `PATH` with the untouched argv. `os.execv`
   replaces this process image outright, so exit code, stdout, and stderr are
   byte-for-byte what the real compiler produces, and the logging side effect is
   the only difference mtest could observe.

An unset `MTEST_MOJO_LOG` skips step 2 only; the exec in step 3 still runs, so
the wrapper is a transparent `mojo` stand-in outside the logging scenarios.

Stdlib only: this is build-time harness code, outside the pure-Mojo product.
"""

from __future__ import annotations

import os
import shutil
import sys


LOG_ENV_VAR = "MTEST_MOJO_LOG"


def _log_invocation(args: list[str]) -> None:
    r"""Append `<subcommand>\t<target>\t<full argv>` to MTEST_MOJO_LOG.

    A no-op when the env var is unset. `args` is the wrapper's own argv with the
    program name stripped, i.e. exactly what real `mojo` would receive: `args[0]`
    is the subcommand and `args[1]`, when present, is the target source path.
    """
    log_path = os.environ.get(LOG_ENV_VAR)
    if not log_path:
        return
    subcommand = args[0] if len(args) > 0 else ""
    target = args[1] if len(args) > 1 else ""
    line = f"{subcommand}\t{target}\t{' '.join(args)}\n"
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(line)


def main() -> int:
    """Log the invocation, then exec the real compiler with the untouched argv.

    Returns:
        127 when no real `mojo` is on PATH. Otherwise `os.execv` replaces this
        process image, so this function does not return.
    """
    args = sys.argv[1:]
    _log_invocation(args)

    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("logging_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    os.execv(real_mojo, [real_mojo, *args])
    # typeshed types os.execv as NoReturn, so mypy sees this as dead. Kept as
    # the fallback if that ever changes.
    return 1  # type: ignore[unreachable]


if __name__ == "__main__":
    sys.exit(main())
