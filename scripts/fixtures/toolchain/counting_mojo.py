#!/usr/bin/env python3
"""Invocation-counting `mojo` wrapper: the precompile-skip witness.

The build cache claims an unchanged precompile step is not run a second time.
mtest's own output cannot prove that: a result field saying "skipped" is written
by the code under test, so a bug that sets the field and compiles anyway reads as
a pass. The witness outside that code is the compiler, asked how many times it
was started.

So this shim counts. Every `mojo precompile <...>` invocation appends one line to
`<cwd>/.mtest-precompile-invocations` before the real compiler is reached; every
other subcommand (`build`, `--version`) passes through untouched and uncounted,
so a test can separate "the step ran" from "a test file was built". A test then
asserts on the line count across two sessions: one line after a cold run and
still one line after a warm one means the step did not run.

The counter lives in the process's current directory, which mtest sets to the
invocation root for every compile child, so it lands inside the calling test's
own `temp_root()` and dies with it. Preserve that when copying this shim: the
adjacent `fake_retry_crash_mojo.py` keys off a marker under the repo root, shared
state that leaks between runs and must be cleared around every test that touches
it, whereas a per-root counter needs no cleanup and lets two suites run
concurrently. The name is dot-prefixed so the cache's include walks skip it (they
skip every dot entry) and the counter can never feed the key it measures.

With the record durable the wrapper `execv`s the real `mojo` found on PATH with
the untouched argv, so the step under test genuinely builds.

Stdlib only: this is build-time harness code, outside the pure-Mojo product.
"""

from __future__ import annotations

import os
import shutil
import sys


COUNTER_NAME = ".mtest-precompile-invocations"
"""The counter file, relative to the compile child's current directory.

Dot-prefixed because `walk_include_root` skips every dot entry.
"""

COUNTED_SUBCOMMAND = "precompile"
"""The one subcommand that leaves a record; everything else passes through."""


def _count_invocation() -> None:
    """Append one line to the counter in the current directory.

    Opened in append mode and closed before the exec below, so the record is
    durable whatever the real compiler does next, including being killed at a
    deadline.
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
    # typeshed types os.execv as NoReturn, so mypy sees this as dead. Kept as
    # the fallback if that ever changes.
    return 1  # type: ignore[unreachable]


if __name__ == "__main__":
    sys.exit(main())
