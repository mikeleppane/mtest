#!/usr/bin/env python3
"""Invocation-counting `mojo` wrapper — the precompile-skip witness.

The build cache's claim about a configured precompile step is that an unchanged
step is not RUN a second time. Nothing in mtest's own output can prove that: a
result field saying "skipped" is written by the very code under test, so a bug
that sets the field and then compiles anyway reads as a pass. The only witness
outside that code is the compiler itself, and the honest question to ask it is
"how many times were you started".

So this shim counts. Every `mojo precompile <...>` invocation appends one line
to `<cwd>/.mtest-precompile-invocations` before the real compiler is reached;
every other subcommand — `build`, `--version` — passes through untouched and
uncounted, so a test can separate "the step ran" from "a test file was built".
A test then asserts on the LINE COUNT across two sessions: one line after a cold
run and still one line after a warm one is the step not running, proven by a
process that never started.

The counter lives in the process's CURRENT DIRECTORY, which mtest sets to the
invocation root for every compile child it spawns — so it lands inside the
calling test's own `temp_root()` and dies with it. That is deliberate and it is
the one thing to preserve when copying this shim: the adjacent
`fake_retry_crash_mojo.py` keys its behaviour off a marker under the REPO root,
which is shared state that leaks between runs and has to be cleared on both
sides of every test that touches it. A per-root counter cannot leak, needs no
cleanup, and lets two suites run concurrently without either seeing the other's
compiles. The name is dot-prefixed so the cache's own include walks skip it
(they skip every dot entry) and the counter can never feed the key it is
measuring.

With the record durable the wrapper `execv`s the real `mojo` found on PATH with
the untouched argv, exactly as `fake_slow_mojo.py` does for its pass-through
subcommands, so exit code, stdout, and stderr are byte-for-byte the real
compiler's and the step under test genuinely builds.

Stdlib only, no third-party imports — this is build-time harness code, not part
of the pure-Mojo product.
"""

from __future__ import annotations

import os
import shutil
import sys


COUNTER_NAME = ".mtest-precompile-invocations"
"""The counter file, relative to the compile child's current directory.

Dot-prefixed on purpose: `walk_include_root` skips every dot entry, so a counter
sitting in the invocation root can never become part of the cache key whose
effect it is measuring.
"""

COUNTED_SUBCOMMAND = "precompile"
"""The one subcommand that leaves a record; everything else passes through."""


def _count_invocation() -> None:
    """Append one line to the counter in the current directory.

    Opened in append mode and closed before the exec below, so the record is
    durable no matter what the real compiler does next — including being killed
    at a deadline.
    """
    path = os.path.join(os.getcwd(), COUNTER_NAME)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("precompile\n")


def main() -> int:
    """Count a precompile, then exec the real compiler with the same argv.

    Returns:
        127 when no real `mojo` is on PATH. Every other path `os.execv`s the
        real compiler, so this function does not return.
    """
    args = sys.argv[1:]
    if len(args) > 0 and args[0] == COUNTED_SUBCOMMAND:
        _count_invocation()

    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        print("counting_mojo.py: no real 'mojo' found on PATH", file=sys.stderr)
        return 127

    os.execv(real_mojo, [real_mojo, *args])
    # Kept as defence in depth: typeshed types os.execv as NoReturn, so mypy
    # sees this as dead. Deleting it would remove the fallback if that ever
    # changes.
    return 1  # type: ignore[unreachable]


if __name__ == "__main__":
    sys.exit(main())
