#!/usr/bin/env python3
"""Unit tests for deterministic, no-follow Mojo format inventory."""

from __future__ import annotations

import os
from pathlib import Path
import tempfile
import unittest

from scripts import format_all


class FormatInventoryTests(unittest.TestCase):
    def test_inventory_covers_fixed_roots_sorted_without_following_links(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            expected = [
                Path("e2e/test_z.mojo"),
                Path("src/a.mojo"),
                Path("tests/nested/test_b.mojo"),
            ]
            for relative in expected:
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("def main():\n    pass\n", encoding="utf-8")
            ignored = repo / "tests" / "helper.py"
            ignored.write_text("pass\n", encoding="utf-8")
            os.symlink(repo / "tests" / "nested", repo / "tests" / "linked")

            actual = format_all.mojo_sources(repo)

        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
