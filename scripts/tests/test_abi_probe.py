#!/usr/bin/env python3
"""Fast, fully mocked unit tests for the cross-module external_call ABI probe.

No `mojo` invocation here: `classified_sources`, `declared_symbols`, and
`shared_symbol_files` are exercised over disposable fixture files, and `main`
is exercised with `run` and `aggregate.write_entrypoint` both patched out. The
probe's actual load-bearing property -- that a real arity/signature drift
between two declarations of a shared symbol fails a real `mojo build` -- is
proven by mutation, live, in `scripts/checks/abi_probe.py`'s own docstring
history and the task report; a fake compiler cannot stand in for that.
"""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts.checks import abi_probe


class DeclaredSymbolsTests(unittest.TestCase):
    def test_real_call_sites_are_counted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            source = Path(raw_tmp) / "test_example.mojo"
            source.write_text(
                "def test_one() raises:\n"
                '    _ = external_call["mtest_exec_test_fault_reset", NoneType]()\n'
                "\n"
                "def test_two() raises:\n"
                '    var r = external_call["mtest_exec_test_constant", Int32](\n'
                "        UInt32(1)\n"
                "    )\n",
                encoding="utf-8",
            )
            self.assertEqual(
                abi_probe.declared_symbols(source),
                {"mtest_exec_test_fault_reset", "mtest_exec_test_constant"},
            )

    def test_string_literal_occurrences_are_not_counted(self) -> None:
        """A generated-fixture string is data, never a real declaration.

        Several classified suites build a throwaway fixture source as a
        sequence of string literals to write out and compile elsewhere. A
        naive text search matches `external_call["sym"` inside that string
        too, but the module that contains it never compiles it as code, so it
        carries no ABI risk. This is the exact shape that made a prior
        reviewer's shared-symbol table wrong -- see the task report.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            source = Path(raw_tmp) / "test_example.mojo"
            source.write_text(
                "def test_generates_fixture() raises:\n"
                "    var fixture = (\n"
                "        '        _ = external_call[\"abort\", Int32]()\\n'\n"
                "    )\n",
                encoding="utf-8",
            )
            self.assertEqual(abi_probe.declared_symbols(source), set())

    def test_mixed_real_and_literal_lines_keep_only_the_real_one(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            source = Path(raw_tmp) / "test_example.mojo"
            source.write_text(
                "def test_mixed() raises:\n"
                '    _ = external_call["kill", Int32](self_pid, Int32(2))\n'
                "    var fixture = (\n"
                '        \'    _ = external_call["kill", Int32]'
                "(Int32(1), Int32(2))\\n'\n"
                "    )\n",
                encoding="utf-8",
            )
            self.assertEqual(abi_probe.declared_symbols(source), {"kill"})


class ClassifiedSourcesTests(unittest.TestCase):
    def test_empty_search_roots_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            empty_unit = Path(raw_tmp) / "unit"
            empty_integration = Path(raw_tmp) / "integration"
            empty_unit.mkdir()
            empty_integration.mkdir()
            with (
                patch.object(
                    abi_probe, "SEARCH_ROOTS", (empty_unit, empty_integration)
                ),
                self.assertRaisesRegex(SystemExit, "no classified test_.*mojo"),
            ):
                abi_probe.classified_sources()

    def test_real_search_roots_are_nonempty(self) -> None:
        self.assertGreater(len(abi_probe.classified_sources()), 0)


class SharedSymbolFilesTests(unittest.TestCase):
    def test_a_symbol_declared_once_is_excluded(self) -> None:
        a = Path("a.mojo")
        b = Path("b.mojo")
        with patch.object(
            abi_probe,
            "declared_symbols",
            side_effect=lambda source: {"only_here"} if source == a else set(),
        ):
            self.assertEqual(abi_probe.shared_symbol_files([a, b]), {})

    def test_a_symbol_declared_by_two_modules_is_grouped(self) -> None:
        a = Path("a.mojo")
        b = Path("b.mojo")
        c = Path("c.mojo")
        symbols = {a: {"shared", "solo_a"}, b: {"shared"}, c: set()}
        with patch.object(abi_probe, "declared_symbols", side_effect=symbols.get):
            shared = abi_probe.shared_symbol_files([a, b, c])
        self.assertEqual(shared, {"shared": [a, b]})

    def test_affected_sources_is_the_deduplicated_sorted_union(self) -> None:
        a, b, c = Path("a.mojo"), Path("b.mojo"), Path("c.mojo")
        shared = {"sym1": [b, a], "sym2": [a, c]}
        self.assertEqual(abi_probe.affected_sources(shared), [a, b, c])

    def test_no_affected_sources_from_no_shared_symbols(self) -> None:
        self.assertEqual(abi_probe.affected_sources({}), [])


class MainTests(unittest.TestCase):
    def test_no_shared_symbol_is_rejected(self) -> None:
        with (
            patch.object(
                abi_probe, "classified_sources", return_value=[Path("a.mojo")]
            ),
            patch.object(abi_probe, "shared_symbol_files", return_value={}),
            self.assertRaisesRegex(SystemExit, "currently guarding nothing"),
        ):
            abi_probe.main()

    def test_a_failed_colinked_build_is_reported_as_abi_drift(self) -> None:
        a = abi_probe.ROOT / "tests" / "integration" / "a.mojo"
        b = abi_probe.ROOT / "tests" / "integration" / "b.mojo"
        failed = subprocess.CompletedProcess(
            args=["mojo"], returncode=1, stdout="conflicting signature"
        )
        with (
            patch.object(abi_probe, "classified_sources", return_value=[a, b]),
            patch.object(
                abi_probe, "shared_symbol_files", return_value={"shared_sym": [a, b]}
            ),
            patch.object(abi_probe, "build_probe", return_value=failed) as mocked_build,
            self.assertRaisesRegex(SystemExit, "ABI drift"),
        ):
            abi_probe.main()
        mocked_build.assert_called_once_with([a, b])

    def test_a_clean_colinked_build_passes(self) -> None:
        a = abi_probe.ROOT / "tests" / "integration" / "a.mojo"
        b = abi_probe.ROOT / "tests" / "integration" / "b.mojo"
        clean = subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout="")
        with (
            patch.object(abi_probe, "classified_sources", return_value=[a, b]),
            patch.object(
                abi_probe, "shared_symbol_files", return_value={"shared_sym": [a, b]}
            ),
            patch.object(abi_probe, "build_probe", return_value=clean),
        ):
            self.assertEqual(abi_probe.main(), 0)


class BuildProbeCommandTests(unittest.TestCase):
    def test_build_command_includes_every_required_include_path(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp) / "out"
            completed = subprocess.CompletedProcess(
                args=["mojo"], returncode=0, stdout=""
            )
            with (
                patch.object(abi_probe, "OUT", out),
                patch.object(abi_probe, "run", return_value=completed) as mocked_run,
            ):
                abi_probe.build_probe(
                    [
                        abi_probe.ROOT / "tests" / "unit" / "test_config.mojo",
                    ]
                )

            command = mocked_run.call_args_list[0].args[0]
            self.assertIn(".", command)
            self.assertIn("build", command)
            self.assertIn("tests/support", command)
            self.assertIn(str(abi_probe.NATIVE_TEST_OBJECT), command)
            entrypoint = out / "abi_probe_main.mojo"
            self.assertTrue(entrypoint.is_file())
            self.assertIn(
                "import tests.unit.test_config as _mtest_module_0",
                entrypoint.read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main()
