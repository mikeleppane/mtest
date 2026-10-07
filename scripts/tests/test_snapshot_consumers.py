#!/usr/bin/env python3
"""Membership tests for the snapshot-reader inventory."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from scripts.harness import snapshot_consumers


def _write(root: Path, rel: str, text: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


class SnapshotConsumerTests(unittest.TestCase):
    def test_finds_nested_and_support_imported_readers(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            snapshots = '"tests/snapshots/protocol/"\n'
            _write(root, "tests/support/cases.mojo", "comptime D = " + snapshots)
            nested = "tests/integration/deep/test_nested.mojo"
            _write(root, nested, "var d = " + snapshots)
            _write(root, "tests/unit/test_via_support.mojo", "from cases import x\n")
            _write(root, "tests/unit/test_unrelated.mojo", "from other import x\n")
            reader = 'R / "snapshots" / "protocol"\n'
            _write(root, "scripts/tests/test_reader.py", reader)
            _write(root, "scripts/tests/test_other.py", "pass\n")

            self.assertEqual(
                snapshot_consumers.mojo_consumers(root),
                [
                    Path("tests/integration/deep/test_nested.mojo"),
                    Path("tests/unit/test_via_support.mojo"),
                ],
            )
            self.assertEqual(
                snapshot_consumers.python_consumers(root),
                ["scripts.tests.test_reader"],
            )

    def test_repository_has_readers_of_both_kinds(self) -> None:
        self.assertIn(
            Path("tests/integration/test_protocol_collection.mojo"),
            snapshot_consumers.mojo_consumers(),
        )
        self.assertIn(
            "scripts.tests.test_protocol_compare",
            snapshot_consumers.python_consumers(),
        )


if __name__ == "__main__":
    unittest.main()
