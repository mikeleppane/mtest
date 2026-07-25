#!/usr/bin/env python3
"""Descriptor-frugal `--mojo` stand-in — the live RLIMIT_NOFILE clamp's compiler.

Stands in for the real `mojo` binary the way the adjacent `logging_mojo.py`
does, but it is STRICT rather than transparent: it never execs the real
compiler. `build` is the only subcommand it serves, and anything else is an
error it refuses loudly.

That strictness is the whole point. The fd-clamp scenario lowers the child's
`RLIMIT_NOFILE` soft limit to a number chosen so mtest's OWN pool arithmetic
clamps — a ceiling far below what LLVM needs to link a Mojo binary. Handing that
ceiling to a real `mojo build` would prove nothing about the pool: the run would
die in the compiler, not in the scheduler. So this stand-in produces the build
product itself, at a cost of a few descriptors, and the low limit reaches the
native pool and the scheduler exactly as the scenario claims.

For each `build <source> -o <out>` it:

1. reads the source's `def test_*` names, in source order, so the fabricated
   report names the file's real tests rather than invented ones;
2. writes a directly executable pass actor at `<out>` (a `#!`-headed script, so
   the kernel runs it under mtest's plain `execve` with no shell in between);
3. exits 0, the way a successful compile does.

The actor prints one report block in the pinned grammar for the source's
CANONICAL path — the same string `mojo build` bakes into a real binary — so
mtest's parser reads it as VALID and the file lands PASS. It answers
`--skip-all` with an all-SKIP listing, so a collection probe of a fabricated
binary reads as a collection listing rather than a suite that ran its bodies.

Trailing spaces in the header and summary lines are load-bearing grammar, not
formatting.

Stdlib only, no third-party imports — this is build-time harness code, not part
of the pure-Mojo product.
"""

from __future__ import annotations

import os
import re
import stat
import sys

TEST_DEF_RE = re.compile(r"^def[ \t]+(test_[A-Za-z0-9_]*)[ \t]*\(", re.MULTILINE)
"""Matches a module-level `def test_...(` — the shape `TestSuite.discover_tests`
collects, anchored at column zero so a nested or commented definition cannot
inflate the fabricated listing."""

ACTOR_TEMPLATE = '''#!{interpreter}
"""A pass actor fabricated by fake_fd_mojo.py; never a compiled Mojo binary."""
import sys

CANONICAL = {canonical!r}
NAMES = {names!r}

SKIPPING = "--skip-all" in sys.argv[1:]
OUTCOME = "SKIP" if SKIPPING else "PASS"
ROWS = "".join("    " + OUTCOME + " [ 0.00s ] " + name + "\\n" for name in NAMES)
PASSED = 0 if SKIPPING else len(NAMES)
SKIPPED = len(NAMES) if SKIPPING else 0
sys.stdout.write(
    "\\nRunning "
    + str(len(NAMES))
    + " tests for "
    + CANONICAL
    + " \\n"
    + ROWS
    + "--------\\n"
    + "Summary [ 0.00s ] "
    + str(len(NAMES))
    + " tests run: "
    + str(PASSED)
    + " passed , 0 failed , "
    + str(SKIPPED)
    + " skipped \\n"
)
'''
"""The fabricated actor's source. The `\\n` escapes survive this template so the
generated script writes real newlines, and the two trailing spaces (after the
header path and after `skipped`) are the toolchain's own grammar."""


def _output_path(args: list[str]) -> str:
    """The `-o` operand of a build argv.

    Args:
        args: The wrapper's argv with the program name stripped, i.e. exactly
            what real `mojo` would receive.

    Returns:
        The output path following `-o`.

    Raises:
        ValueError: If `-o` is absent or carries no operand — a build argv this
            stand-in refuses rather than guesses at.
    """
    if "-o" not in args:
        raise ValueError("build argv carries no -o output path")
    index = args.index("-o") + 1
    if index >= len(args):
        raise ValueError("build argv ends with a bare -o")
    return args[index]


def _test_names(source: str) -> list[str]:
    """The module-level `test_*` function names of a Mojo source, in order.

    Args:
        source: The path of the file being "compiled".

    Returns:
        Every module-level test name, in source order.

    Raises:
        ValueError: If the file declares no test at all. A zero-test report is
            a different verdict class (NO-TESTS), so fabricating one silently
            would change the scenario's accounting instead of failing it.
    """
    with open(source, encoding="utf-8") as handle:
        names = TEST_DEF_RE.findall(handle.read())
    if not names:
        raise ValueError(f"{source} declares no module-level test function")
    return names


def _write_actor(out: str, canonical: str, names: list[str]) -> None:
    """Write the directly executable pass actor for one source.

    Args:
        out: Where the build product goes, exactly as mtest asked for it.
        canonical: The absolute, symlink-resolved source path the report's
            header must byte-equal for mtest to match the report to the file.
        names: The test names the report lists.
    """
    parent = os.path.dirname(out)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(
            ACTOR_TEMPLATE.format(
                interpreter=sys.executable, canonical=canonical, names=names
            )
        )
    mode = os.stat(out).st_mode
    os.chmod(out, mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def main() -> int:
    """Fabricate one build product, or refuse anything that is not a build."""
    args = sys.argv[1:]
    if not args or args[0] != "build":
        print(
            f"fake_fd_mojo.py: refusing {args!r}: this stand-in serves only "
            "`build` and never execs the real compiler",
            file=sys.stderr,
        )
        return 2
    if len(args) < 2:
        print("fake_fd_mojo.py: build argv names no source", file=sys.stderr)
        return 2
    source = args[1]
    try:
        out = _output_path(args)
        names = _test_names(source)
    except (OSError, ValueError) as error:
        print(f"fake_fd_mojo.py: {error}", file=sys.stderr)
        return 2
    _write_actor(out, os.path.realpath(source), names)
    return 0


if __name__ == "__main__":
    sys.exit(main())
