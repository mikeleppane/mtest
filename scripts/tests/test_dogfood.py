#!/usr/bin/env python3
"""Unit tests for the focused self-host dogfood inventory and command."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts.harness import dogfood


class DogfoodTests(unittest.TestCase):
    def test_repository_paths_track_the_nested_module_location(self) -> None:
        repo_root = Path(__file__).resolve().parents[2]
        self.assertEqual(dogfood.REPO_ROOT_PATH, repo_root)
        self.assertEqual(Path(dogfood.REPO_ROOT), repo_root)
        self.assertEqual(Path(dogfood.MTEST), repo_root / "build" / "mtest")
        self.assertEqual(
            Path(dogfood.NATIVE_OBJECT),
            repo_root / "build" / "native" / "mtest_exec_native_test.o",
        )

    def test_command_names_each_probe_explicitly(self) -> None:
        command = dogfood._mtest_argv("/tmp/mtest", "/tmp/native.o")

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
                "-n",
                "2",
                "--serial",
                "tests/dogfood/exec_probe.mojo",
                "tests/dogfood/exec_probe.mojo",
                "tests/dogfood/model_probe.mojo",
                "tests/dogfood/session_probe.mojo",
            ],
        )

    def test_verify_accepts_exact_pass_row_membership(self) -> None:
        output = (
            "root: /repo   selected: 3 files   excluded: 0 files\n"
            "PASS tests/dogfood/exec_probe.mojo 0.01s\n"
            "PASS tests/dogfood/model_probe.mojo 0.01s\n"
            "PASS tests/dogfood/session_probe.mojo 0.01s\n"
        )
        exact_files = [
            "tests/dogfood/exec_probe.mojo",
            "tests/dogfood/model_probe.mojo",
            "tests/dogfood/session_probe.mojo",
        ]
        with (
            patch.object(dogfood, "dogfood_test_files", return_value=exact_files),
            patch.object(
                dogfood,
                "run_mtest_over_own_suite",
                return_value=(0, output),
            ),
            redirect_stdout(StringIO()),
            redirect_stderr(StringIO()),
        ):
            result = dogfood.verify("/tmp/mtest", "/tmp/native.o")

        self.assertEqual(result, 0)

    def test_verify_rejects_a_missing_pass_row(self) -> None:
        output = (
            "root: /repo   selected: 3 files   excluded: 0 files\n"
            "PASS tests/dogfood/exec_probe.mojo 0.01s\n"
            "PASS tests/dogfood/model_probe.mojo 0.01s\n"
        )
        exact_files = [
            "tests/dogfood/exec_probe.mojo",
            "tests/dogfood/model_probe.mojo",
            "tests/dogfood/session_probe.mojo",
        ]
        with (
            patch.object(dogfood, "dogfood_test_files", return_value=exact_files),
            patch.object(
                dogfood,
                "run_mtest_over_own_suite",
                return_value=(0, output),
            ),
            redirect_stdout(StringIO()),
            redirect_stderr(StringIO()),
        ):
            result = dogfood.verify("/tmp/mtest", "/tmp/native.o")

        self.assertEqual(result, 1)

    def test_inventory_accepts_exact_declared_probe_set(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            for relative in dogfood.DOGFOOD_TEST_FILES:
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("probe\n", encoding="utf-8")

            found = dogfood.dogfood_test_files(repo)

        self.assertEqual(found, list(dogfood.DOGFOOD_TEST_FILES))

    def test_inventory_rejects_an_undeclared_mojo_probe(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            for relative in dogfood.DOGFOOD_TEST_FILES:
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("probe\n", encoding="utf-8")
            extra = repo / "tests/dogfood/extra_probe.mojo"
            extra.write_text("probe\n", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "inventory mismatch"):
                dogfood.dogfood_test_files(repo)

    def test_inventory_rejects_a_missing_declared_probe(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            dogfood_dir = repo / "tests/dogfood"
            dogfood_dir.mkdir(parents=True)

            with self.assertRaisesRegex(RuntimeError, "inventory mismatch"):
                dogfood.dogfood_test_files(repo)


if __name__ == "__main__":
    unittest.main()
