#!/usr/bin/env python3
"""Unit tests for the ASan gate's classified-suite compilation."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import asan_check


class AsanCheckTests(unittest.TestCase):
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
