"""Tests for the source-only assertion companion checker."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
from typing import override
import unittest
from unittest import mock

from scripts.checks import assertions


class AssertionCommandTests(unittest.TestCase):
    def test_compile_command_uses_only_the_public_source_root(self) -> None:
        repo = Path("/checkout")
        self.assertEqual(
            assertions.compile_command(
                Path("/toolchain/bin/mojo"),
                repo,
                repo / "tests/assertions/api_consumer.mojo",
                repo / "build/assertions-check/api-o0",
                "-O0",
            ),
            [
                "/toolchain/bin/mojo",
                "build",
                "-O0",
                "-I",
                "/checkout/assertions-src",
                "/checkout/tests/assertions/api_consumer.mojo",
                "-o",
                "/checkout/build/assertions-check/api-o0",
            ],
        )

    def test_reset_build_root_removes_a_stale_executable(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-assertions-test-") as raw:
            build_root = Path(raw) / "assertions-check"
            build_root.mkdir()
            stale = build_root / "api-o0"
            stale.write_text("stale", encoding="utf-8")

            assertions.reset_build_root(build_root)

            self.assertTrue(build_root.is_dir())
            self.assertFalse(stale.exists())

    def test_run_checked_turns_timeout_into_a_bounded_failure(self) -> None:
        timeout = subprocess.TimeoutExpired(["mojo", "build"], 7)
        with (
            mock.patch(
                "scripts.checks.assertions.subprocess.run",
                side_effect=timeout,
            ),
            self.assertRaisesRegex(
                AssertionError,
                r"command exceeded 7 seconds: mojo build",
            ),
        ):
            assertions._run_checked(
                ["mojo", "build"],
                cwd=Path("/checkout"),
                timeout=7,
            )

    def test_successful_compile_must_be_warning_free(self) -> None:
        result = subprocess.CompletedProcess(
            args=["mojo", "build"],
            returncode=0,
            stdout="",
            stderr="source.mojo:1:1: warning: leaked warning\n",
        )
        with self.assertRaisesRegex(AssertionError, "compiler warning"):
            assertions.validate_clean_compile(result, "-O0", "source.mojo")


class AssertionApiValidationTests(unittest.TestCase):
    def test_accepts_a_zero_failed_testsuite_summary(self) -> None:
        assertions._validate_api_run(
            subprocess.CompletedProcess(
                args=["api-o0"],
                returncode=0,
                stdout=(
                    "Running 1 tests for api_consumer.mojo\n"
                    "    PASS [ T ] test_one\n"
                    "--------\n"
                    "Summary [ T ] 1 tests run: 1 passed , 0 failed , "
                    "0 skipped\n"
                ),
                stderr="",
            ),
            {"test_one"},
        )

    def test_public_surface_includes_traits_and_exact_signatures(self) -> None:
        declaration = {
            "functions": [
                {
                    "name": "assert_equal",
                    "overloads": [
                        {"signature": "def assert_equal(actual: Int)"},
                        {"signature": "def assert_equal(actual: String)"},
                    ],
                }
            ],
            "structs": [],
            "aliases": [],
            "traits": [{"name": "AccidentalTrait"}],
        }
        self.assertEqual(
            assertions.public_api_surface(declaration),
            {
                "functions": [
                    {
                        "name": "assert_equal",
                        "overloads": [
                            "def assert_equal(actual: Int)",
                            "def assert_equal(actual: String)",
                        ],
                    }
                ],
                "structs": [],
                "aliases": [],
                "traits": ["AccidentalTrait"],
            },
        )

    def test_export_rejection_requires_the_compiler_absence_message(self) -> None:
        echoed_only = (
            "error: unable to locate module 'mtest'\n"
            "from mtest.assertions import BoundedWriter\n"
        )
        with self.assertRaisesRegex(AssertionError, "wrong reason"):
            assertions.validate_export_rejection(echoed_only, "BoundedWriter")
        assertions.validate_export_rejection(
            "error: package 'assertions' does not contain 'BoundedWriter'\n",
            "BoundedWriter",
        )

    def test_unicode_mark_table_rejects_an_incomplete_range_set(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-assertions-test-") as raw:
            source = Path(raw) / "_display.mojo"
            source.write_text(
                'comptime _MARK_RANGES: StaticString = "00030000036f"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "Unicode mark ranges"):
                assertions.validate_unicode_mark_table(source)

    def test_dictionary_key_rendering_must_follow_the_equal_return(self) -> None:
        broken = """
def write_dictionary_difference[V](actual: V) -> Bool:
    if not _key_projection_fits("key"):
        pass
    if not missing.total and not unexpected.total and not changed.total:
        return True
"""
        with self.assertRaisesRegex(AssertionError, "success path"):
            assertions.validate_dictionary_success_path(broken)

        fixed = """
def write_dictionary_difference[V](actual: V) -> Bool:
    if not missing.total and not unexpected.total and not changed.total:
        return True
    if not _key_projection_fits("key"):
        pass
        """
        assertions.validate_dictionary_success_path(fixed)

    def test_dictionary_selection_rejects_raw_oversized_keys_before_copy(
        self,
    ) -> None:
        broken = """
def consider(mut self, key: String) -> Bool:
    self.keys.append(key)
    return True
"""
        with self.assertRaisesRegex(AssertionError, "retained"):
            assertions.validate_dictionary_selection_bound(broken)

        fixed = """
def consider(mut self, key: String) -> Bool:
    if key.byte_length() > DICTIONARY_KEY_BYTE_CAP:
        return False
    self.keys.append(key)
    return True
"""
        assertions.validate_dictionary_selection_bound(fixed)


class AssertionLocationValidationTests(unittest.TestCase):
    @override
    def setUp(self) -> None:
        self.source = Path("/checkout/tests/assertions/location_consumer.mojo")
        self.expected = {
            "test_generic_location": (12, 18),
            "test_string_location": (18, 18),
        }
        self.valid_output = (
            "Unhandled exception caught during execution:\n"
            "Running 2 tests for "
            "/checkout/tests/assertions/location_consumer.mojo\n"
            "    FAIL [ T ] test_generic_location\n"
            "      At "
            "/checkout/tests/assertions/location_consumer.mojo:12:18: "
            "values compare unequal\n"
            "    FAIL [ T ] test_string_location\n"
            "      At "
            "/checkout/tests/assertions/location_consumer.mojo:18:18: "
            "strings differ\n"
            "--------\n"
            "Summary [ T ] 2 tests run: 0 passed , 2 failed , 0 skipped\n"
        )

    def test_accepts_exact_rows_summary_and_consumer_locations(self) -> None:
        assertions.validate_location_run(
            subprocess.CompletedProcess(
                args=["location-o0"],
                returncode=1,
                stdout=self.valid_output,
                stderr="",
            ),
            self.source,
            self.expected,
        )

    def test_rejects_a_non_failure_exit(self) -> None:
        with self.assertRaisesRegex(AssertionError, "exact exit 1"):
            assertions.validate_location_run(
                subprocess.CompletedProcess(
                    args=["location-o0"],
                    returncode=0,
                    stdout=self.valid_output,
                    stderr="",
                ),
                self.source,
                self.expected,
            )

    def test_rejects_wrong_fail_row_membership(self) -> None:
        output = self.valid_output.replace(
            "test_string_location", "test_wrong_location", 1
        )
        with self.assertRaisesRegex(AssertionError, "FAIL rows"):
            assertions.validate_location_run(
                subprocess.CompletedProcess(
                    args=["location-o0"],
                    returncode=1,
                    stdout=output,
                    stderr="",
                ),
                self.source,
                self.expected,
            )

    def test_rejects_wrong_summary(self) -> None:
        output = self.valid_output.replace(
            "2 tests run: 0 passed , 2 failed",
            "2 tests run: 1 passed , 1 failed",
        )
        with self.assertRaisesRegex(AssertionError, "summary"):
            assertions.validate_location_run(
                subprocess.CompletedProcess(
                    args=["location-o0"],
                    returncode=1,
                    stdout=output,
                    stderr="",
                ),
                self.source,
                self.expected,
            )

    def test_rejects_provider_coordinates(self) -> None:
        output = self.valid_output.replace(
            "At /checkout/tests/assertions/location_consumer.mojo:12:18",
            "At /checkout/assertions-src/mtest/assertions/__init__.mojo:12:18",
        )
        with self.assertRaisesRegex(AssertionError, "provider coordinate"):
            assertions.validate_location_run(
                subprocess.CompletedProcess(
                    args=["location-o0"],
                    returncode=1,
                    stdout=output,
                    stderr="",
                ),
                self.source,
                self.expected,
            )

    def test_rejects_crash_classification(self) -> None:
        with self.assertRaisesRegex(AssertionError, "CRASH"):
            assertions.validate_location_run(
                subprocess.CompletedProcess(
                    args=["location-o0"],
                    returncode=1,
                    stdout=self.valid_output + "CRASH\n",
                    stderr="",
                ),
                self.source,
                self.expected,
            )

    def test_rejects_stderr(self) -> None:
        with self.assertRaisesRegex(AssertionError, "stderr"):
            assertions.validate_location_run(
                subprocess.CompletedProcess(
                    args=["location-o0"],
                    returncode=1,
                    stdout=self.valid_output,
                    stderr="unexpected",
                ),
                self.source,
                self.expected,
            )


class AssertionMarkerTests(unittest.TestCase):
    def test_extracts_argument_coordinates_from_marked_calls(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-assertions-test-") as raw:
            source = Path(raw) / "location_consumer.mojo"
            source.write_text(
                "def test_generic_location():\n"
                "    assert_equal(1, 2)  # ASSERT-LOCATION: "
                "test_generic_location\n",
                encoding="utf-8",
            )
            self.assertEqual(
                assertions.expected_locations(source),
                {"test_generic_location": (2, 17)},
            )

    def test_rejects_duplicate_markers(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-assertions-test-") as raw:
            source = Path(raw) / "location_consumer.mojo"
            source.write_text(
                "assert_equal(1, 2)  # ASSERT-LOCATION: duplicate\n"
                "assert_equal(2, 3)  # ASSERT-LOCATION: duplicate\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "duplicate"):
                assertions.expected_locations(source)

    def test_marker_may_follow_a_formatted_multiline_call(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-assertions-test-") as raw:
            source = Path(raw) / "location_consumer.mojo"
            source.write_text(
                "def test_multiline():\n"
                "    assert_equal(\n"
                "        1, 2\n"
                "    )  # ASSERT-LOCATION: test_multiline\n",
                encoding="utf-8",
            )
            self.assertEqual(
                assertions.expected_locations(source),
                {"test_multiline": (2, 17)},
            )

    def test_extracts_an_explicit_source_location_marker(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-assertions-test-") as raw:
            source = Path(raw) / "location_consumer.mojo"
            source.write_text(
                "def test_explicit():\n"
                "    var chosen = source_location()  "
                "# ASSERT-EXPLICIT-LOCATION: test_explicit\n"
                "    assert_equal(1, 2, location=chosen)\n",
                encoding="utf-8",
            )
            self.assertEqual(
                assertions.expected_locations(source),
                {"test_explicit": (2, 33)},
            )


if __name__ == "__main__":
    unittest.main()
