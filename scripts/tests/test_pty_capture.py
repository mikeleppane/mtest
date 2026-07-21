#!/usr/bin/env python3
"""Focused non-writing tests for the manual PTY capture tool."""

from __future__ import annotations

import importlib
from pathlib import Path
import unittest


def _file_state(root: Path) -> dict[str, tuple[bytes, int]]:
    """Return relative bytes and mtimes for every committed capture file."""
    return {
        path.relative_to(root).as_posix(): (
            path.read_bytes(),
            path.stat().st_mtime_ns,
        )
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


class PtyCapturePathTests(unittest.TestCase):
    def test_nested_module_paths_are_repo_anchored_without_writing(self) -> None:
        repo_root = Path(__file__).resolve().parents[2]
        capture_root = repo_root / "notes" / "console-captures"
        before = _file_state(capture_root)

        module = importlib.import_module("scripts.maintenance.pty_capture")

        self.assertEqual(module.REPO_ROOT, repo_root)
        self.assertEqual(module.MTEST, repo_root / "build" / "mtest")
        self.assertEqual(module.OUTPUT_DIR, capture_root)
        self.assertEqual(_file_state(capture_root), before)


if __name__ == "__main__":
    unittest.main()
