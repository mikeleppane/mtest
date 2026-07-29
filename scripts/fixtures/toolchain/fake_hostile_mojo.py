#!/usr/bin/env python3
"""Strict `--mojo` stand-in that builds the hostile report actor.

Like `fake_fd_mojo.py` this never execs the real compiler, and it is strict about
the whole argv rather than just its first word. It serves exactly
`build <source.mojo> -o <out>`, because the scenarios it backs
(`hostile-console` for the terminal surface, `hostile-reporters` for the NDJSON
and JUnit ones) assert on exact bytes and byte counts. An unexpected flag or
operand would change what the run does while those scenarios went on asserting
about the old shape, so refusing loudly makes that visible.

The build product is an executable copy of
`tests/fixtures/exec/hostile_report_actor.py` with two substitutions: the
interpreter on the shebang line, so the kernel can run it under mtest's plain
`execve` with no shell in between, and the canonical source path, so the report
header the actor prints byte-equals the path a real `mojo build` would have baked
into the binary. Without that second substitution mtest's parser finds no report
for the file and the run never reaches the console surfaces under test.

Stdlib only: this is build-time harness code, outside the pure-Mojo product.
"""

from __future__ import annotations

import os
import stat
import sys


REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
"""The repository root, four levels up from `scripts/fixtures/toolchain/`."""

ACTOR = os.path.join(REPO_ROOT, "tests", "fixtures", "exec", "hostile_report_actor.py")
"""The committed actor this stand-in copies. The hostile bytes live in the
fixture and are never duplicated into this file."""

CANONICAL_PLACEHOLDER = '"@MTEST_CANONICAL_SOURCE@"'
"""The exact token the actor assigns to `CANONICAL`, replaced with a real path
literal. Quoted in the pattern so a bare mention in the actor's prose cannot be
substituted by accident."""


def _reject(message: str) -> int:
    """Report a refused invocation on stderr and yield the failing exit code.

    Args:
        message: What was refused, and why.

    Returns:
        `2`, the exit code this stand-in uses for every refusal.
    """
    print(f"fake_hostile_mojo.py: {message}", file=sys.stderr)
    return 2


def _write_actor(out: str, canonical: str) -> None:
    """Write the executable actor copy for one source.

    Args:
        out: Where the build product goes, exactly as mtest asked for it.
        canonical: The absolute, symlink-resolved source path to embed.

    Raises:
        OSError: The actor could not be read, or the product not written.
        ValueError: The actor no longer carries the canonical placeholder, which
            would produce a product whose report matches no file.
    """
    with open(ACTOR, encoding="utf-8") as handle:
        source = handle.read()
    if CANONICAL_PLACEHOLDER not in source:
        raise ValueError(
            f"{ACTOR} no longer contains {CANONICAL_PLACEHOLDER}; the build "
            "product would report for a path mtest never asked about"
        )
    source = source.replace(CANONICAL_PLACEHOLDER, repr(canonical), 1)
    lines = source.split("\n")
    if not lines or not lines[0].startswith("#!"):
        raise ValueError(f"{ACTOR} has no shebang line to redirect")
    lines[0] = f"#!{sys.executable}"
    parent = os.path.dirname(out)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    mode = os.stat(out).st_mode
    # S103 is expected: mtest spawns this build product as a binary, so the
    # execute bits are what makes the fixture mean anything.
    os.chmod(out, mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)  # noqa: S103


def main() -> int:
    """Serve exactly one expected build argv, or refuse it loudly.

    Returns:
        `0` after writing the build product, `2` for any refused invocation.
    """
    args = sys.argv[1:]
    if len(args) != 4:
        return _reject(
            f"refusing {args!r}: this stand-in serves exactly "
            "`build <source.mojo> -o <out>` and nothing else"
        )
    if args[0] != "build":
        return _reject(f"refusing subcommand {args[0]!r}: only `build` is served")
    if args[2] != "-o":
        return _reject(f"refusing {args!r}: expected `-o` as the third argument")
    source, out = args[1], args[3]
    if not source.endswith(".mojo"):
        return _reject(f"refusing source {source!r}: not a .mojo file")
    if not os.path.isfile(source):
        return _reject(f"refusing source {source!r}: no such file")
    try:
        _write_actor(out, os.path.realpath(source))
    except (OSError, ValueError) as error:
        return _reject(str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
