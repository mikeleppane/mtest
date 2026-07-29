#!/usr/bin/env python3
"""Identity-logging `mojo` wrapper: the executable-precedence witness.

Three copies of this file stand in for the compiler at once, one per resolution
source mtest must rank: `--mojo` beats `MTEST_MOJO`, which beats a plain `mojo`
found on `PATH`. Each copy is installed as `<dir>/mojo`, and its parent
directory names it:

    <root>/flag/mojo   the `--mojo` candidate
    <root>/env/mojo    the `MTEST_MOJO` candidate
    <root>/path/mojo   the `PATH` candidate

A copy logs to the file named by `MTEST_PATH_MOJO_LOG_<DIR>`, uppercased from
that parent directory, so all three log paths can be armed on one run and the
run's choice is stated by which log came into existence. Each record is one JSON
object carrying the exact argument vector mtest spawned plus this copy's own
absolute path, taken from `__file__` rather than `argv[0]` so the identity is the
file the kernel executed.

The e2e parent resolves the real compiler once, before prepending the wrapper
directory to `PATH`, and passes that absolute path in `MTEST_REAL_MOJO`. This
wrapper refuses to run if that variable is unset, is relative, or names this very
file: the `PATH` candidate is itself called `mojo`, so a wrapper that searched
`PATH` for the "real" one would exec itself forever.

With the record durable the wrapper `execv`s the real compiler directly, so exit
code, stdout, and stderr are byte-for-byte the real compiler's.

Stdlib only: this is build-time harness code, outside the pure-Mojo product.
"""

from __future__ import annotations

import json
import os
import sys


REAL_MOJO_ENV_VAR = "MTEST_REAL_MOJO"
"""The absolute real compiler, resolved once by the e2e parent."""
LOG_ENV_PREFIX = "MTEST_PATH_MOJO_LOG_"
"""Prefix of the per-copy log variable; the parent directory completes it."""


def log_env_var(wrapper: str) -> str:
    """The log-path variable one installed copy reads.

    Args:
        wrapper: The copy's own absolute path, `<root>/<source>/mojo`.

    Returns:
        `MTEST_PATH_MOJO_LOG_` followed by the uppercased parent directory
        name, so the three copies never share a log.
    """
    source = os.path.basename(os.path.dirname(wrapper))
    return LOG_ENV_PREFIX + source.upper()


def _record(wrapper: str, argv: list[str]) -> None:
    """Append this invocation's identity and exact argv to the copy's log.

    A no-op when the copy's variable is unset, so the wrapper stays a
    transparent `mojo` stand-in outside the precedence scenario.

    Args:
        wrapper: The copy's own absolute path.
        argv: The complete argument vector, `argv[0]` included. For the `PATH`
            candidate that first element is the bare word mtest searched for.
    """
    log_path = os.environ.get(log_env_var(wrapper))
    if not log_path:
        return
    line = json.dumps({"wrapper": wrapper, "argv": argv}, sort_keys=True)
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def _real_mojo(wrapper: str) -> str:
    """The real compiler this copy execs, validated against PATH recursion.

    Args:
        wrapper: The copy's own absolute path.

    Returns:
        The absolute real compiler path.

    Raises:
        ValueError: If `MTEST_REAL_MOJO` is unset, is not absolute, or resolves
            to this very file.
    """
    real = os.environ.get(REAL_MOJO_ENV_VAR, "")
    if not real:
        raise ValueError(
            f"{REAL_MOJO_ENV_VAR} is unset; the e2e parent must resolve the real"
            " compiler before it prepends this wrapper's directory to PATH"
        )
    if not os.path.isabs(real):
        raise ValueError(f"{REAL_MOJO_ENV_VAR}={real!r} is not an absolute path")
    if os.path.realpath(real) == wrapper:
        raise ValueError(
            f"{REAL_MOJO_ENV_VAR}={real!r} names this wrapper; execing it would"
            " recurse through PATH forever"
        )
    return real


def main() -> int:
    """Record this invocation, then exec the real compiler with the same argv."""
    wrapper = os.path.realpath(__file__)
    _record(wrapper, list(sys.argv))
    try:
        real = _real_mojo(wrapper)
    except ValueError as error:
        print(f"path_mojo.py: {error}", file=sys.stderr)
        return 127
    os.execv(real, [real, *sys.argv[1:]])
    # typeshed types os.execv as NoReturn, so mypy sees this as dead. Kept as
    # the fallback if that ever changes.
    return 1  # type: ignore[unreachable]


if __name__ == "__main__":
    sys.exit(main())
