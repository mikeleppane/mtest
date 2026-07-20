#!/usr/bin/env python3
"""Regression tests for native lifecycle build command construction."""

from __future__ import annotations

from pathlib import Path
import unittest
from unittest import mock

from scripts.checks import native as native_check


class NativeCheckCommandTests(unittest.TestCase):
    """Keep Darwin lifecycle links independent of the pinned Clang driver."""

    def test_repository_root_is_exact(self) -> None:
        root = Path(__file__).resolve().parents[2]
        self.assertEqual(native_check.ROOT, root)

    def test_source_inventory_is_nonempty_and_exact(self) -> None:
        root = Path(__file__).resolve().parents[2]
        self.assertEqual(
            tuple(path.relative_to(root).as_posix() for path in native_check.TEST_SOURCES),
            (
                "tests/native/test_exec_native.c",
                "tests/native/test_exec_native_signals.c",
            ),
        )
        self.assertGreater(len(native_check.TEST_SOURCES), 0)

    def test_empty_source_inventory_is_rejected(self) -> None:
        with mock.patch.object(native_check, "TEST_SOURCES", ()):
            with self.assertRaisesRegex(SystemExit, "source inventory is empty"):
                native_check.main()

    def test_darwin_link_uses_system_driver_and_precompiled_objects(self) -> None:
        command = native_check.link_command(
            "clang",
            (Path("adapter.o"), Path("lifecycle.o")),
            Path("lifecycle"),
            platform="darwin",
        )

        self.assertEqual(command[0], "/usr/bin/cc")
        self.assertEqual(
            command,
            ["/usr/bin/cc", "adapter.o", "lifecycle.o", "-o", "lifecycle"],
        )

    def test_linux_link_retains_pinned_driver(self) -> None:
        command = native_check.link_command(
            "/pinned/clang",
            (Path("adapter.o"), Path("lifecycle.o")),
            Path("lifecycle"),
            platform="linux",
        )

        self.assertEqual(command[0], "/pinned/clang")


if __name__ == "__main__":
    unittest.main()
