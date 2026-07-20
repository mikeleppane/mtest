#!/usr/bin/env python3
"""Unit tests for deterministic, no-follow Mojo format inventory."""

from __future__ import annotations

import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts.checks import format as format_check


class FormatInventoryTests(unittest.TestCase):
    def test_pixi_tasks_use_the_focused_formatter_module(self) -> None:
        pixi = (
            Path(__file__).resolve().parents[2] / "pixi.toml"
        ).read_text(encoding="utf-8")
        expected = {
            'fmt = "python -m scripts.checks.format"',
            'fmt-check = "python -m scripts.checks.format && git diff --exit-code"',
        }
        missing = sorted(line for line in expected if line not in pixi)
        self.assertEqual(missing, [])

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

            actual = format_check.mojo_sources(repo)

        self.assertEqual(actual, expected)

    def test_default_roots_are_exact(self) -> None:
        self.assertEqual(format_check.FORMAT_ROOTS, ("src", "tests", "e2e"))

    def test_repository_root_is_exact(self) -> None:
        self.assertEqual(
            format_check.REPO_ROOT,
            Path(__file__).resolve().parents[2],
        )

    def test_repository_inventory_is_nonempty(self) -> None:
        self.assertGreater(len(format_check.mojo_sources()), 0)

    def test_empty_inventory_is_rejected(self) -> None:
        with mock.patch.object(format_check, "mojo_sources", return_value=[]):
            self.assertEqual(format_check.main(), 1)


if __name__ == "__main__":
    unittest.main()
