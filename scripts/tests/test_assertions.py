"""Tests for the source-only assertion companion checker."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
import time
from typing import override
import unittest
from unittest import mock

from scripts.checks import assertions
from scripts.harness import watchdog


class AssertionCommandTests(unittest.TestCase):
    def test_assertion_execution_roster_is_exact(self) -> None:
        self.assertEqual(
            assertions.ASSERTION_OPTIMIZATIONS,
            (("-O0", "o0"), ("-O3", "o3")),
        )
        self.assertEqual(
            assertions.ASSERTION_CONSUMERS,
            ("api", "location", "example"),
        )
        self.assertEqual(
            assertions.PRIVATE_FACADE_HELPERS,
            (
                "BODY_BYTE_CAP",
                "BoundedWriter",
                "SourceLocation",
                "call_location",
            ),
        )

    def test_missing_consumer_optimization_pair_is_rejected(self) -> None:
        performed = (
            ("api", "-O0"),
            ("location", "-O0"),
            ("example", "-O0"),
            ("api", "-O3"),
            ("location", "-O3"),
        )
        with self.assertRaisesRegex(
            AssertionError,
            r"example.*-O3",
        ):
            assertions.verify_assertion_execution_roster(performed)

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
        with self.assertRaisesRegex(
            AssertionError,
            r"command exceeded .* seconds",
        ):
            assertions._run_checked(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                cwd=assertions.REPO_ROOT,
                timeout=0.05,
            )

    def test_run_checked_timeout_kills_descendants(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-assertions-test-") as raw:
            marker = Path(raw) / "survived"
            child = (
                "import pathlib,time;"
                "time.sleep(0.5);"
                f"pathlib.Path({str(marker)!r}).write_text('alive')"
            )
            parent = (
                "import subprocess,sys,time;"
                f"subprocess.Popen([sys.executable,'-c',{child!r}]);"
                "time.sleep(60)"
            )
            with self.assertRaisesRegex(AssertionError, "command exceeded"):
                assertions._run_checked(
                    [sys.executable, "-c", parent],
                    cwd=assertions.REPO_ROOT,
                    timeout=0.1,
                )
            time.sleep(0.7)
            self.assertFalse(marker.exists())

    def test_run_checked_bounds_flood_capture(self) -> None:
        result = assertions._run_checked(
            [
                sys.executable,
                "-c",
                (
                    "import sys;"
                    f"sys.stdout.write('x'*{assertions.PROCESS_CAPTURE_BYTE_CAP * 2})"
                ),
            ],
            cwd=assertions.REPO_ROOT,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0)
        self.assertLessEqual(
            len(result.stdout.encode("utf-8")),
            assertions.PROCESS_CAPTURE_BYTE_CAP
            + len(assertions.PROCESS_CAPTURE_MARKER.encode("utf-8")),
        )
        self.assertTrue(result.stdout.endswith(assertions.PROCESS_CAPTURE_MARKER))

    def test_run_checked_rejects_signal_death_structurally(self) -> None:
        with (
            mock.patch.object(
                watchdog,
                "run_captured_command",
                return_value=watchdog.CapturedCommand(
                    watchdog.Signaled(11),
                    "expected semantic diagnostic",
                    "",
                ),
            ),
            self.assertRaisesRegex(AssertionError, "signal 11"),
        ):
            assertions._run_checked(
                ["mojo", "build"],
                cwd=assertions.REPO_ROOT,
                timeout=5,
            )

    def test_run_checked_rejects_incomplete_pipe_drain(self) -> None:
        with (
            mock.patch.object(
                watchdog,
                "run_captured_command",
                return_value=watchdog.CapturedCommand(
                    watchdog.Exited(0),
                    "",
                    "",
                    capture_complete=False,
                ),
            ),
            self.assertRaisesRegex(AssertionError, "capture was incomplete"),
        ):
            assertions._run_checked(
                ["mojo", "build"],
                cwd=assertions.REPO_ROOT,
                timeout=5,
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

    def test_successful_compile_must_have_complete_capture(self) -> None:
        result = subprocess.CompletedProcess(
            args=["mojo", "build"],
            returncode=0,
            stdout=assertions.PROCESS_CAPTURE_MARKER,
            stderr="",
        )
        with self.assertRaisesRegex(AssertionError, "output was truncated"):
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

    def test_rejects_duplicate_pass_rows(self) -> None:
        with self.assertRaisesRegex(AssertionError, "PASS rows differ"):
            assertions._validate_api_run(
                subprocess.CompletedProcess(
                    args=["api-o0"],
                    returncode=0,
                    stdout=(
                        "Running 1 tests for api_consumer.mojo\n"
                        "    PASS [ T ] test_one\n"
                        "    PASS [ T ] test_one\n"
                        "--------\n"
                        "Summary [ T ] 1 tests run: 1 passed , 0 failed , "
                        "0 skipped\n"
                    ),
                    stderr="",
                ),
                {"test_one"},
            )

    def test_rejects_more_than_one_testsuite_summary(self) -> None:
        with self.assertRaisesRegex(AssertionError, "exactly one TestSuite summary"):
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
                assertions.validate_unicode_category_tables(source)

    def test_unicode_enclosing_mark_table_is_checked_independently(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-assertions-test-") as raw:
            source = Path(raw) / "_display.mojo"
            real_source = (
                assertions.ASSERTION_SOURCE_ROOT
                / "mtest"
                / "assertions"
                / "_display.mojo"
            ).read_text(encoding="utf-8")
            source.write_text(
                real_source.replace(
                    "or (value >= 0xA670 and value <= 0xA672)",
                    "",
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "enclosing mark"):
                assertions.validate_unicode_category_tables(source)

    def test_dictionary_key_rendering_must_follow_the_equal_return(self) -> None:
        broken = """
def write_dictionary_difference[V](actual: V) -> Bool:
    for entry in expected.items():
        missing.consider(entry.key)
    if not missing.total and not unexpected.total and not changed.total:
        return True
"""
        with self.assertRaisesRegex(AssertionError, "classified differences"):
            assertions.validate_dictionary_success_path(broken)

        fixed = """
def write_dictionary_difference[V](actual: V) -> Bool:
    for entry in expected.items():
        if entry.key not in actual:
            missing.consider(entry.key)
        elif actual[entry.key] != entry.value:
            changed.consider(entry.key)
    for entry in actual.items():
        if entry.key not in expected:
            unexpected.consider(entry.key)
    if not missing.total and not unexpected.total and not changed.total:
        return True
        """
        assertions.validate_dictionary_success_path(fixed)

    def test_readme_example_requires_one_ordinary_failure(self) -> None:
        valid = subprocess.CompletedProcess(
            args=["example-o0"],
            returncode=1,
            stdout=(
                "Running 2 tests for test_diagnostics.mojo\n"
                "    PASS [ T ] test_standard_assertion_still_coexists\n"
                "    FAIL [ T ] test_text_difference_has_scalar_and_context\n"
                "text differs at scalar 6\n"
                "actual: U+0062 'b'\n"
                "expected: U+0042 'B'\n"
                "reason: configuration text changed\n"
                "Summary [ T ] 2 tests run: 1 passed , 1 failed , 0 skipped\n"
            ),
            stderr="",
        )
        assertions.validate_example_run(valid)
        with self.assertRaisesRegex(AssertionError, "exact exit 1"):
            assertions.validate_example_run(
                subprocess.CompletedProcess(
                    args=["example-o0"],
                    returncode=0,
                    stdout=valid.stdout,
                    stderr="",
                )
            )

    def test_check_rejects_a_dropped_execution_pair(self) -> None:
        expected_locations = dict.fromkeys(assertions.LOCATION_TESTS, (1, 1))
        performed = tuple(
            pair
            for pair in assertions.expected_assertion_execution_roster()
            if pair != ("example", "-O3")
        )
        with (
            mock.patch(
                "scripts.checks.assertions.shutil.which",
                return_value="/bin/mojo",
            ),
            mock.patch.object(assertions, "reset_build_root"),
            mock.patch.object(
                assertions,
                "expected_locations",
                return_value=expected_locations,
            ),
            mock.patch.object(
                assertions,
                "run_static_assertion_proofs",
                return_value=assertions.STATIC_PROOF_IDS,
            ),
            mock.patch.object(
                assertions,
                "run_assertion_consumers",
                return_value=performed,
            ),
            mock.patch.object(
                assertions,
                "_reject_accidental_public_helpers",
                return_value=assertions.PRIVATE_FACADE_HELPERS,
            ),
            self.assertRaisesRegex(AssertionError, r"example.*-O3"),
        ):
            assertions.check_assertions()

    def test_static_proof_roster_is_exact_and_every_proof_is_called(self) -> None:
        self.assertEqual(
            assertions.STATIC_PROOF_IDS,
            (
                "unicode-categories",
                "dictionary-success",
                "dictionary-selection",
                "public-api",
            ),
        )
        with (
            mock.patch.object(
                assertions,
                "validate_unicode_category_tables",
            ) as unicode_check,
            mock.patch.object(
                assertions,
                "validate_dictionary_success_path",
            ) as dictionary_success,
            mock.patch.object(
                assertions,
                "validate_dictionary_selection_bound",
            ) as dictionary_selection,
            mock.patch.object(
                assertions,
                "_validate_public_api_docs",
            ) as public_api,
        ):
            self.assertEqual(
                assertions.run_static_assertion_proofs(Path("/bin/mojo")),
                assertions.STATIC_PROOF_IDS,
            )
        unicode_check.assert_called_once()
        dictionary_success.assert_called_once()
        dictionary_selection.assert_called_once()
        public_api.assert_called_once_with(Path("/bin/mojo"))

    def test_dictionary_selection_rejects_raw_oversized_keys_before_copy(
        self,
    ) -> None:
        broken = """
def consider(mut self, key: String):
    self.keys.append(key)
"""
        with self.assertRaisesRegex(AssertionError, "retained"):
            assertions.validate_dictionary_selection_bound(broken)

        fixed = """
def consider(mut self, key: String):
    if key.byte_length() > DICTIONARY_KEY_BYTE_CAP:
        return
    var projection = _render_projection(key)
    if projection.truncated:
        return
    self.keys.append(key)
    self.projections.append(projection.text.copy())
"""
        assertions.validate_dictionary_selection_bound(fixed)

    def test_dictionary_keys_are_projected_once_before_retention(self) -> None:
        source = (
            assertions.ASSERTION_SOURCE_ROOT / "mtest" / "assertions" / "_mapping.mojo"
        ).read_text(encoding="utf-8")
        self.assertEqual(source.count("_render_projection(key)"), 1)
        self.assertNotIn("render_value(key)", source)


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

    def test_rejects_coordinates_swapped_between_test_names(self) -> None:
        output = (
            self.valid_output.replace(
                ":12:18:",
                ":99:99:",
                1,
            )
            .replace(
                ":18:18:",
                ":12:18:",
                1,
            )
            .replace(
                ":99:99:",
                ":18:18:",
                1,
            )
        )
        with self.assertRaisesRegex(AssertionError, "name-to-coordinate"):
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
