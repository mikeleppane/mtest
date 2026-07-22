#!/usr/bin/env python3
"""Unit tests for the ASan gate's classified-suite compilation."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts.checks.memory import asan as asan_check


class AsanCheckTests(unittest.TestCase):
    def test_repository_root_is_exact(self) -> None:
        self.assertEqual(asan_check.ROOT, Path(__file__).resolve().parents[2])

    def test_source_inventory_is_nonempty_and_exact(self) -> None:
        self.assertEqual(
            tuple(path.relative_to(asan_check.ROOT).as_posix() for path in asan_check.TESTS),
            (
                "tests/integration/test_exec_capture.mojo",
                "tests/integration/test_exec_flood.mojo",
                "tests/integration/test_exec_timeout.mojo",
                "tests/integration/test_exec_interrupt.mojo",
                "tests/integration/test_exec_etxtbsy.mojo",
                "tests/integration/test_exec_reap.mojo",
                "tests/integration/test_exec_fdhygiene.mojo",
                "tests/integration/test_exec_pool.mojo",
            ),
        )
        self.assertGreater(len(asan_check.TESTS), 0)

    def test_empty_source_inventory_is_rejected(self) -> None:
        with patch.object(asan_check, "TESTS", ()):
            with self.assertRaisesRegex(SystemExit, "source inventory is empty"):
                asan_check.main()

    def test_classified_suite_builds_generated_entrypoint(self) -> None:
        source = asan_check.ROOT / "tests" / "unit" / "test_config.mojo"
        expected = asan_check.test_count(source)
        results = [
            subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout=""),
            subprocess.CompletedProcess(args=["nm"], returncode=0, stdout="__asan_"),
            subprocess.CompletedProcess(
                args=["test_config"],
                returncode=0,
                stdout=f"{expected} tests run: {expected} passed\n",
            ),
        ]
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(asan_check, "OUT", out),
                patch.object(asan_check, "run", side_effect=results) as mocked_run,
            ):
                asan_check.compile_and_run_test(source, {})

            entrypoint = out / "test_config_main.mojo"
            compile_command = mocked_run.call_args_list[0].args[0]
            self.assertIn(str(entrypoint), compile_command)
            self.assertNotIn(
                str(source.relative_to(asan_check.ROOT)), compile_command
            )
            self.assertIn(
                "import tests.unit.test_config as _mtest_module_0",
                entrypoint.read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main()
