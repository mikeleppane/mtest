#!/usr/bin/env python3
"""Logging `--mojo` wrapper — proves the single-build reuse guarantee.

Stands in for the real `mojo` binary: `mtest --mojo scripts/logging_mojo.py
...` routes every child mtest spawns (`mojo build <file> ...`, `mojo
precompile <file> ...`) through this script first. It:

1. Reads a log file path from the `MTEST_MOJO_LOG` environment variable.
2. Appends one line recording the subcommand (`build`/`precompile`/...) and
   the target source path — the first two tokens after the subcommand — plus
   the full argv for debugging. `scripts/e2e_check.py` parses the first two
   fields to count how many times a given file was built.
3. EXECS the real `mojo` found on `PATH` with the untouched argv. `os.execv`
   replaces this process image outright, so exit code, stdout, and stderr are
   byte-for-byte what the real compiler produces — mtest cannot tell the
   difference between calling `mojo` directly and calling this wrapper, aside
   from the logging side effect.

`MTEST_MOJO_LOG` unset skips step 2 only; the exec in step 3 still runs, so the
wrapper is a transparent `mojo` stand-in even outside the logging scenarios.
Stdlib only, no third-party imports — this is build-time harness code, not
part of the pure-Mojo product.
"""

from __future__ import annotations

import os
import shutil
import sys

LOG_ENV_VAR = "MTEST_MOJO_LOG"


def _log_invocation(args: list[str]) -> None:
    """Append `<subcommand>\\t<target>\\t<full argv>` to MTEST_MOJO_LOG.

    A no-op when the env var is unset. `args` is the wrapper's own argv with
    the program name stripped, i.e. exactly what real `mojo` would receive:
    `args[0]` is the subcommand, `args[1]` (when present) is the target source
    path mtest passes as the first positional argument after it.
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
    args = sys.argv[1:]
    _log_invocation(args)

    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("logging_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    os.execv(real_mojo, [real_mojo, *args])
    return 1  # unreachable: a successful os.execv never returns


if __name__ == "__main__":
    sys.exit(main())
