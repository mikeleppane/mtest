#!/usr/bin/env python3
"""Format every Mojo source one at a time in deterministic order.

Mojo 1.0.0b2 can stall when ``mojo format`` receives several directories in
one invocation. Per-file invocations cover the same tree without triggering
that toolchain behavior.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
FORMAT_ROOTS = ("src", "assertions-src", "tests", "e2e")


def mojo_sources(repo_root: Path = REPO_ROOT) -> list[Path]:
    """Return all real Mojo files under the fixed format roots, bytewise-sorted."""
    found: list[Path] = []
    for relative_root in FORMAT_ROOTS:
        root = repo_root / relative_root
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            current = Path(dirpath)
            dirnames[:] = [
                name for name in dirnames if not (current / name).is_symlink()
            ]
            for name in filenames:
                path = current / name
                if path.suffix == ".mojo" and not path.is_symlink():
                    found.append(path.relative_to(repo_root))
    return sorted(found, key=lambda path: os.fsencode(str(path)))


def main() -> int:
    """Format every discovered Mojo source with one `mojo format` call each.

    Returns:
        0 once every source formatted cleanly. 1 when discovery found no Mojo
        source at all, which means the format roots moved and the gate would
        otherwise pass by formatting nothing. Otherwise the non-zero exit of
        the first failing `mojo format`, with its merged output on stderr.
    """
    sources = mojo_sources()
    if not sources:
        print("FATAL: format-all: no Mojo sources found", file=sys.stderr)
        return 1
    for source in sources:
        result = subprocess.run(
            ["mojo", "format", "--quiet", str(source)],
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            if result.stdout:
                print(result.stdout, end="", file=sys.stderr)
            print(f"FATAL: format-all: failed on {source}", file=sys.stderr)
            return result.returncode
    print(f"format-all: formatted {len(sources)} Mojo source(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
