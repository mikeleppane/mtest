#!/usr/bin/env python3
"""Regression tests for native lifecycle build command construction."""

from __future__ import annotations

from pathlib import Path
import unittest

from scripts import native_check


class NativeCheckCommandTests(unittest.TestCase):
    """Keep Darwin lifecycle links independent of the pinned Clang driver."""

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
