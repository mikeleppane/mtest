#!/usr/bin/env python3
"""Unit tests for the Valgrind gate's fail-closed diagnostics."""

from __future__ import annotations

import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import valgrind_check


class ValgrindCheckTests(unittest.TestCase):
    def test_startup_failure_reports_valgrind_diagnostic(self) -> None:
        result = subprocess.CompletedProcess(
            args=["valgrind"],
            returncode=1,
            stdout=(
                "valgrind:  Fatal error at startup: a function redirection\n"
                "valgrind:  Possible fixes: install libc6-dbg\n"
            ),
        )

        command = ["build/safety/valgrind/native_controls", "mem-undefined"]
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(valgrind_check, "OUT", out),
                patch.object(valgrind_check, "run", return_value=result),
            ):
                with self.assertRaises(SystemExit) as raised:
                    valgrind_check.valgrind(command, {}, quiet_child=False)

            log = out / "startup-failure.log"
            self.assertTrue(log.exists())
            self.assertEqual(log.read_text(), result.stdout)

        message = str(raised.exception)
        self.assertIn("Valgrind failed to start", message)
        self.assertIn("native_controls mem-undefined", message)
        self.assertIn("install libc6-dbg", message)


if __name__ == "__main__":
    unittest.main()
