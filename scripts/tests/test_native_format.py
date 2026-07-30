#!/usr/bin/env python3
"""Regression tests for native source formatting controls."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts.checks import native_format
from scripts.checks.native_sources import require_ascii, tracked_native_sources


ROOT = Path(__file__).resolve().parents[2]
EXPECTED_NATIVE_SOURCES = (
    "native/mtest_exec_native.c",
    "native/mtest_exec_native.h",
    "native/mtest_exec_native_test.h",
    "tests/native/e2e_config_open_fault.c",
    "tests/native/e2e_json_terminal_write_fault.c",
    "tests/native/e2e_state_persistence_fault.c",
    "tests/native/main_open_fault.c",
    "tests/native/native_controls.c",
    "tests/native/stack_protector_canary.c",
    "tests/native/test_exec_native.c",
    "tests/native/test_exec_native_signals.c",
)


class NativeFormatTests(unittest.TestCase):
    """Keep the native source inventory and formatter pin exact."""

    def test_tracked_native_sources_are_sorted_and_complete(self) -> None:
        got = tracked_native_sources(ROOT)
        self.assertEqual(
            tuple(path.relative_to(ROOT).as_posix() for path in got),
            EXPECTED_NATIVE_SOURCES,
        )

    def test_require_ascii_rejects_first_non_ascii_byte(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            source = Path(raw_tmp) / "bad.c"
            source.write_bytes(b"int main(void) { return 0; }\n\xc3\xa4\n")
            with self.assertRaisesRegex(SystemExit, r"bad\.c:.*byte 29"):
                require_ascii((source,), label="native-format")

    def test_formatter_rejects_wrong_version(self) -> None:
        completed = subprocess.CompletedProcess(
            ["clang-format", "--version"], 0, "clang-format version 19.1.0\n", ""
        )
        with (
            mock.patch.object(native_format, "run", return_value=completed),
            self.assertRaisesRegex(SystemExit, "expected clang-format 18.1.8"),
        ):
            native_format.require_clang_format()

    def test_new_tracked_c_flows_through_format_and_ascii_checks(self) -> None:
        sources = (
            ROOT / "native" / "mtest_exec_native.c",
            ROOT / "tests" / "native" / "new_fault_driver.c",
        )
        completed = subprocess.CompletedProcess(["clang-format"], 0, "", "")
        with (
            mock.patch.object(native_format, "require_clang_format"),
            mock.patch.object(
                native_format,
                "tracked_native_sources",
                return_value=sources,
            ),
            mock.patch.object(native_format, "require_ascii") as require_ascii_check,
            mock.patch.object(
                native_format,
                "run",
                return_value=completed,
            ) as run,
        ):
            self.assertEqual(native_format.main(), 0)

        self.assertEqual(
            run.call_args.args[0],
            [
                "clang-format",
                "-i",
                "--style=file",
                "--fallback-style=none",
                *(str(source) for source in sources),
            ],
        )
        self.assertEqual(
            require_ascii_check.call_args_list,
            [
                mock.call(sources, label="native-format"),
                mock.call(sources, label="native-format"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
