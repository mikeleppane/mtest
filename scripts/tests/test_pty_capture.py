#!/usr/bin/env python3
"""Focused non-writing tests for the manual PTY capture tool."""

from __future__ import annotations

import importlib
from pathlib import Path
import unittest


def _file_state(root: Path) -> dict[str, tuple[bytes, int]]:
    """Return relative bytes and mtimes for every capture file under `root`.

    Args:
        root: The capture directory, which need not exist.

    Returns:
        One entry per file, empty when `root` is absent.
    """
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
        # `notes/` is untracked, so the capture directory is present in a
        # contributor's checkout and absent in a fresh clone. Both states have
        # to prove something, which is why the directory's existence is pinned
        # alongside its contents: absent must stay absent, so importing the
        # module cannot create even an empty directory (which a contents-only
        # comparison would miss), and present must stay byte-identical.
        repo_root = Path(__file__).resolve().parents[2]
        capture_root = repo_root / "notes" / "console-captures"
        existed = capture_root.exists()
        before = _file_state(capture_root)

        module = importlib.import_module("scripts.maintenance.pty_capture")

        self.assertEqual(module.REPO_ROOT, repo_root)
        self.assertEqual(module.MTEST, repo_root / "build" / "mtest")
        self.assertEqual(module.OUTPUT_DIR, capture_root)
        self.assertEqual(
            capture_root.exists(),
            existed,
            "importing the capture tool changed whether its output directory "
            "exists; import must never touch the filesystem",
        )
        self.assertEqual(_file_state(capture_root), before)


if __name__ == "__main__":
    unittest.main()
