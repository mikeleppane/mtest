#!/usr/bin/env python3
"""Unit tests for deterministic aggregate Mojo test-source generation."""

from __future__ import annotations

import os
from pathlib import Path
import tempfile
import unittest

from scripts import aggregate_tests


class AggregateDiscoveryTests(unittest.TestCase):
    def test_discovery_is_recursive_sorted_deduplicated_and_no_follow(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            tests = repo / "tests"
            first = tests / "unit" / "test_z.mojo"
            second = tests / "unit" / "nested" / "test_a.mojo"
            ignored = tests / "unit" / "helper.mojo"
            second.parent.mkdir(parents=True)
            first.write_text("def test_z():\n    pass\n", encoding="utf-8")
            second.write_text("def test_a():\n    pass\n", encoding="utf-8")
            ignored.write_text("def test_no():\n    pass\n", encoding="utf-8")
            os.symlink(second.parent, tests / "unit" / "linked")

            found = aggregate_tests.discover_test_files(
                repo, [tests / "unit", second.parent]
            )

        self.assertEqual(
            found,
            [
                Path("tests/unit/nested/test_a.mojo"),
                Path("tests/unit/test_z.mojo"),
            ],
        )

    def test_root_outside_tests_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            outside = repo / "src"
            outside.mkdir()

            with self.assertRaisesRegex(ValueError, "must be tests/ or below"):
                aggregate_tests.discover_test_files(repo, [outside])

    def test_empty_inventory_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            root = repo / "tests" / "unit"
            root.mkdir(parents=True)

            with self.assertRaisesRegex(ValueError, "no test_\\*\\.mojo"):
                aggregate_tests.discover_test_files(repo, [root])


class AggregateRenderingTests(unittest.TestCase):
    def test_test_function_parser_is_exact_and_rejects_main(self) -> None:
        source = (
            "def _helper():\n    pass\n\n"
            "def test_first() raises:\n    pass\n\n"
            "def test_second(value: Int = 1) raises:\n    pass\n"
        )
        self.assertEqual(
            aggregate_tests.test_function_names(source),
            ["test_first", "test_second"],
        )

        with self.assertRaisesRegex(ValueError, "must not define main"):
            aggregate_tests.test_function_names(source + "\ndef main():\n    pass\n")

    def test_entrypoint_imports_and_registers_each_module_in_order(self) -> None:
        modules = [
            aggregate_tests.TestModule(
                Path("tests/integration/test_same.mojo"), ["test_beta"]
            ),
            aggregate_tests.TestModule(
                Path("tests/unit/test_same.mojo"), ["test_alpha", "test_gamma"]
            ),
        ]

        rendered = aggregate_tests.render_entrypoint(modules)

        self.assertIn(
            "import tests.integration.test_same as _mtest_module_0",
            rendered,
        )
        self.assertIn(
            "import tests.unit.test_same as _mtest_module_1", rendered
        )
        integration_marker = rendered.index(
            'print("==> tests/integration/test_same.mojo", flush=True)'
        )
        unit_marker = rendered.index(
            'print("==> tests/unit/test_same.mojo", flush=True)'
        )
        self.assertLess(integration_marker, unit_marker)
        self.assertIn(
            "suite_0.test[_mtest_module_0.test_beta]()", rendered
        )
        self.assertIn(
            "suite_1.test[_mtest_module_1.test_alpha]()", rendered
        )
        self.assertIn("suite_1^.run()", rendered)

    def test_invalid_mojo_module_path_is_rejected(self) -> None:
        module = aggregate_tests.TestModule(
            Path("tests/bad-directory/test_probe.mojo"), ["test_probe"]
        )

        with self.assertRaisesRegex(ValueError, "valid Mojo module path"):
            aggregate_tests.render_entrypoint([module])


if __name__ == "__main__":
    unittest.main()
