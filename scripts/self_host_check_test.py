#!/usr/bin/env python3
"""Unit tests for the focused self-host dogfood inventory and command."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

import self_host_check


class SelfHostDogfoodTests(unittest.TestCase):
    def test_command_names_each_probe_explicitly(self) -> None:
        command = self_host_check._mtest_argv("/tmp/mtest", "/tmp/native.o")

        self.assertEqual(
            command,
            [
                "/tmp/mtest",
                "-I",
                "build",
                "-I",
                "tests/support",
                "--build-arg=-Xlinker",
                "--build-arg=/tmp/native.o",
                *self_host_check.DOGFOOD_TEST_FILES,
            ],
        )

    def test_inventory_accepts_exact_declared_probe_set(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            for relative in self_host_check.DOGFOOD_TEST_FILES:
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("probe\n", encoding="utf-8")

            found = self_host_check.dogfood_test_files(repo)

        self.assertEqual(found, list(self_host_check.DOGFOOD_TEST_FILES))

    def test_inventory_rejects_an_undeclared_mojo_probe(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            for relative in self_host_check.DOGFOOD_TEST_FILES:
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("probe\n", encoding="utf-8")
            extra = repo / "tests/dogfood/extra_probe.mojo"
            extra.write_text("probe\n", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "inventory mismatch"):
                self_host_check.dogfood_test_files(repo)

    def test_inventory_rejects_a_missing_declared_probe(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            dogfood = repo / "tests/dogfood"
            dogfood.mkdir(parents=True)

            with self.assertRaisesRegex(RuntimeError, "inventory mismatch"):
                self_host_check.dogfood_test_files(repo)


if __name__ == "__main__":
    unittest.main()
