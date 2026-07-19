#!/usr/bin/env python3
"""Unit tests for self-host command construction and progress diagnostics."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

import self_host_check


class SelfHostProgressTests(unittest.TestCase):
    def test_ordinary_command_does_not_enable_json_reporting(self) -> None:
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
                "tests/",
            ],
        )

    def test_diagnostic_command_writes_json_progress_to_requested_path(self) -> None:
        command = self_host_check._mtest_argv(
            "/tmp/mtest", "/tmp/native.o", progress_path="/tmp/progress.ndjson"
        )

        self.assertEqual(
            command[-3:], ["--json", "/tmp/progress.ndjson", "tests/"]
        )

    def test_progress_snapshot_names_last_committed_event_and_path(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            stream = Path(raw_tmp) / "progress.ndjson"
            text = (
                '{"event":"stream","version":1,"generator":"mtest 0.4.0"}\n'
                '{"event":"session_started","selected_count":2}\n'
                '{"event":"file_started","path":"tests/unit/test_alpha.mojo"}\n'
            )
            stream.write_text(text, encoding="utf-8")

            snapshot = self_host_check._progress_snapshot(stream)

        self.assertEqual(
            snapshot,
            "records=3 last_event=file_started "
            "path=tests/unit/test_alpha.mojo",
        )

    def test_progress_snapshot_ignores_torn_tail(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            stream = Path(raw_tmp) / "progress.ndjson"
            text = (
                '{"event":"stream","version":1,"generator":"mtest 0.4.0"}\n'
                '{"event":"file_started","path":"tests/unit/test_alpha.mojo"}\n'
                '{"event":"file_finished","path":"tests/unit/test_alpha'
            )
            stream.write_text(text, encoding="utf-8")

            snapshot = self_host_check._progress_snapshot(stream)

        self.assertEqual(
            snapshot,
            "records=2 last_event=file_started "
            "path=tests/unit/test_alpha.mojo torn_tail=true",
        )

    def test_progress_snapshot_reports_absent_stream(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            stream = Path(raw_tmp) / "progress.ndjson"

            snapshot = self_host_check._progress_snapshot(stream)

        self.assertEqual(snapshot, "stream=not-created")


if __name__ == "__main__":
    unittest.main()
