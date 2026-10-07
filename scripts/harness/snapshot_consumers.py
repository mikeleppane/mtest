#!/usr/bin/env python3
"""Run every classified module that reads the protocol snapshots.

`pixi run transcripts` rewrites tests/snapshots/protocol/ in place, and the
modules that parse those files go red only when the full suite next runs. This
runs them straight after regeneration. Membership is derived from the sources;
a module that merely names the directory is included too, which costs one
extra run and never misses a reader.
"""

from __future__ import annotations

from pathlib import Path
import sys

from scripts.harness import selfhost


ROOTS = (Path("tests/unit"), Path("tests/integration"))
MARKERS = ("tests/snapshots/protocol/", "transcript_cases")


def consumers(roots: tuple[Path, ...] = ROOTS) -> list[Path]:
    """Return the classified modules whose source names a snapshot marker."""
    return sorted(
        path
        for root in roots
        for path in root.glob("test_*.mojo")
        if any(marker in path.read_text(encoding="utf-8") for marker in MARKERS)
    )


def main() -> int:
    """Self-host the snapshot consumers; fail closed when none are found."""
    modules = consumers()
    if not modules:
        print(
            "FATAL: snapshot_consumers: no module reads the snapshots",
            file=sys.stderr,
        )
        return 2
    return selfhost.main([str(path) for path in modules])


if __name__ == "__main__":
    raise SystemExit(main())
