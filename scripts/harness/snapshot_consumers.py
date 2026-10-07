#!/usr/bin/env python3
"""Run every test that reads the protocol snapshots.

`pixi run transcripts` rewrites tests/snapshots/protocol/ in place, and the
tests that parse those files go red only when the full suite next runs. This
runs them straight after regeneration. Membership is derived from the sources:
a classified Mojo module that names the snapshot directory, or imports a
`tests/support` module that does, and a `scripts/tests` module that names it.
Naming the directory only in a string still counts; that costs one extra run
and never misses a reader.
"""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys

from scripts.harness import selfhost


SNAPSHOTS = re.compile(r"snapshots\W+protocol")
MOJO_ROOTS = ("tests/unit", "tests/integration")
SUPPORT_ROOT = "tests/support"
PYTHON_ROOT = "scripts/tests"


def _reads_snapshots(path: Path) -> bool:
    return SNAPSHOTS.search(path.read_text(encoding="utf-8")) is not None


def mojo_consumers(repo_root: Path = Path()) -> list[Path]:
    """Return the classified Mojo modules that read the snapshots.

    Args:
        repo_root: Repository root the roots are resolved against.

    Returns:
        Each module naming the snapshot directory or importing a support
        module that names it, sorted, relative to `repo_root`.
    """
    helpers = [
        path.stem
        for path in (repo_root / SUPPORT_ROOT).rglob("*.mojo")
        if _reads_snapshots(path)
    ]
    imports = [
        re.compile(rf"^\s*(?:from|import)\s+{re.escape(stem)}\b", re.MULTILINE)
        for stem in helpers
    ]
    found: list[Path] = []
    for root in MOJO_ROOTS:
        for path in (repo_root / root).rglob("test_*.mojo"):
            text = path.read_text(encoding="utf-8")
            if SNAPSHOTS.search(text) or any(i.search(text) for i in imports):
                found.append(path.relative_to(repo_root))
    return sorted(found)


def python_consumers(repo_root: Path = Path()) -> list[str]:
    """Return the `scripts/tests` modules that read the snapshots, as modules.

    Args:
        repo_root: Repository root the root is resolved against.

    Returns:
        Dotted module names, sorted.
    """
    return sorted(
        f"scripts.tests.{path.stem}"
        for path in (repo_root / PYTHON_ROOT).glob("test_*.py")
        if _reads_snapshots(path)
    )


def main() -> int:
    """Run both reader sets; fail closed when either is empty."""
    mojo = mojo_consumers()
    python = python_consumers()
    if not mojo or not python:
        print(
            "FATAL: snapshot_consumers: no snapshot reader found "
            f"(mojo={len(mojo)}, python={len(python)})",
            file=sys.stderr,
        )
        return 2
    for module in python:
        if subprocess.run([sys.executable, "-m", module], check=False).returncode:
            return 1
    return selfhost.main([str(path) for path in mojo])


if __name__ == "__main__":
    raise SystemExit(main())
