#!/usr/bin/env python3
"""Fast, fully mocked unit tests for the cross-module external_call ABI probe.

No `mojo` invocation here: `classified_sources`, `declared_symbols`,
`shared_symbol_files` and the entrypoint renderer are exercised over
disposable fixture files, and `main` is exercised with `build_probe` patched
out. The probe's actual load-bearing property -- that a real arity/signature
drift between two declarations of a shared symbol fails a real `mojo build` --
is proven by mutation, live, in `scripts/checks/abi_probe.py`'s own docstring
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

    def test_multiline_declaration_symbol_on_a_continuation_line_is_counted(
        self,
    ) -> None:
        """A real declaration may wrap across lines, symbol and all.

        `external_call[` need not share a line with its symbol.
        `tests/integration/test_exec_etxtbsy.mojo` genuinely writes
        `mtest_exec_test_monotonic_wait_configure` this way. A scanner that
        requires `external_call["sym"` on one physical line never sees it:
        the opening line has no quote at all, and the symbol's own line has
        no `external_call[` on it -- each line individually looks unmatched.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            source = Path(raw_tmp) / "test_example.mojo"
            source.write_text(
                "def test_wraps() raises:\n"
                "    var status = external_call[\n"
                '        "mtest_exec_test_monotonic_wait_configure", Int32\n'
                "    ](UInt32(1), UInt32(2))\n",
                encoding="utf-8",
            )
            self.assertEqual(
                abi_probe.declared_symbols(source),
                {"mtest_exec_test_monotonic_wait_configure"},
            )

    def test_multiline_fixture_literal_span_is_still_excluded(self) -> None:
        """A wrapped fixture declaration must stay excluded too.

        This codebase's fixture-generation convention writes every physical
        line of a throwaway generated source as its own quoted string
        literal -- including, here, the line that would otherwise OPEN a
        real `external_call[` span. Checking only that opening line is
        enough to exclude the whole multi-line fixture span, however many
        lines it happens to spread across.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            source = Path(raw_tmp) / "test_example.mojo"
            source.write_text(
                "def test_generates_fixture() raises:\n"
                "    var fixture = (\n"
                "        '        var status = external_call[\\n'\n"
                "        '            \"mtest_exec_test_fixture_only\", Int32\\n'\n"
                "        '        ](args)\\n'\n"
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

    def test_the_real_tree_has_no_cross_root_stem_collision(self) -> None:
        """The live tree must satisfy the property, not just the fixtures."""
        stems = [path.stem for path in abi_probe.classified_sources()]
        self.assertEqual(len(stems), len(set(stems)))

    def test_a_cross_root_stem_collision_is_rejected(self) -> None:
        """Two roots holding the same stem must fail, not silently shadow.

        `-I tests/unit` precedes `-I tests/integration` and Mojo resolves a
        bare stem against the first match with no ambiguity error, so the
        second module would never be compiled by the probe at all. A drift
        declared only in the shadowed twin would co-link clean.

        Note this is checked over the whole classified universe, not over one
        co-link list: shadowing needs only ONE twin in the list, so
        `render_entrypoint`'s within-list check cannot see this case.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            unit = root / "unit"
            integration = root / "integration"
            unit.mkdir()
            integration.mkdir()
            for directory in (unit, integration):
                (directory / "test_twin.mojo").write_text(
                    "def test_one():\n    pass\n", encoding="utf-8"
                )

            with (
                patch.object(abi_probe, "SEARCH_ROOTS", (unit, integration)),
                patch.object(abi_probe, "ROOT", root),
                self.assertRaisesRegex(SystemExit, "share a stem"),
            ):
                abi_probe.classified_sources()

    def test_distinct_stems_across_roots_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            unit = root / "unit"
            integration = root / "integration"
            unit.mkdir()
            integration.mkdir()
            (unit / "test_alpha.mojo").write_text("", encoding="utf-8")
            (integration / "test_beta.mojo").write_text("", encoding="utf-8")

            with (
                patch.object(abi_probe, "SEARCH_ROOTS", (unit, integration)),
                patch.object(abi_probe, "ROOT", root),
            ):
                found = abi_probe.classified_sources()

        self.assertEqual([path.stem for path in found], ["test_alpha", "test_beta"])


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

    def test_a_failed_colinked_build_is_reported_without_overclaiming_cause(
        self,
    ) -> None:
        """The failure message must state what was observed, not diagnose it.

        `main` cannot tell a real shared-symbol arity/signature disagreement
        apart from an unrelated compile error in one of the co-linked
        modules -- both look like the same nonzero `mojo build` exit. The
        message must say the build failed and name the shared symbols
        involved, without asserting a cause it cannot actually distinguish.
        """
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
            self.assertRaises(SystemExit) as raised,
        ):
            abi_probe.main()
        mocked_build.assert_called_once_with([a, b])
        message = str(raised.exception)
        self.assertIn("failed to build", message)
        self.assertIn("shared_sym", message)
        # Must not assert a certainty this function cannot have: an unrelated
        # compile error in a co-linked module produces the identical nonzero
        # exit, so the wording has to hedge rather than flatly diagnose the
        # cause as a symbol disagreement.
        self.assertIn("unrelated compile error", message)

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


class EntrypointRenderingTests(unittest.TestCase):
    """The generated entrypoint imports each module and references every test."""

    def _module(self, root: Path, name: str, functions: tuple[str, ...]) -> Path:
        """Write one fixture module under a disposable classified root."""
        source = root / f"{name}.mojo"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(
            "".join(
                f"def {function}() raises:\n    pass\n\n" for function in functions
            ),
            encoding="utf-8",
        )
        return source

    def test_modules_are_imported_by_stem_not_by_package_path(self) -> None:
        """`tests/unit` is not a Mojo package and cannot be imported as one.

        Every classified module declares `main()`, which Mojo 1.0.0b2 refuses
        to package, so `tests/unit/__init__.mojo` cannot exist and
        `import tests.unit.test_alpha` cannot resolve. The include-path
        spelling is what keeps the probe working over a marker-free tree.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp).resolve()
            source = self._module(root, "test_alpha", ("test_one", "test_two"))
            rendered = abi_probe.render_entrypoint([source])

        self.assertIn("import test_alpha as _mtest_module_0", rendered)
        self.assertNotIn("import tests.", rendered)
        self.assertIn("    suite_0.test[_mtest_module_0.test_one]()", rendered)
        self.assertIn("    suite_0.test[_mtest_module_0.test_two]()", rendered)

    def test_every_module_gets_its_own_suite_and_alias(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp).resolve()
            first = self._module(root, "test_alpha", ("test_one",))
            second = self._module(root, "test_beta", ("test_two",))
            rendered = abi_probe.render_entrypoint([first, second])

        self.assertIn("import test_beta as _mtest_module_1", rendered)
        self.assertIn("    suite_1.test[_mtest_module_1.test_two]()", rendered)

    def test_two_modules_sharing_a_stem_are_rejected(self) -> None:
        """A shared stem would silently drop one module from the co-link.

        Both would resolve to one name off the include path, so the probe
        would guard fewer modules than its own output claims -- the exact
        silent narrowing this gate exists to prevent.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp).resolve()
            unit = root / "unit"
            integration = root / "integration"
            unit.mkdir()
            integration.mkdir()
            first = self._module(unit, "test_clash", ("test_one",))
            second = self._module(integration, "test_clash", ("test_two",))

            with self.assertRaisesRegex(SystemExit, "share an importable name"):
                abi_probe.render_entrypoint([first, second])

    def test_an_unimportable_module_name_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp).resolve()
            source = self._module(root, "test-dashed", ("test_one",))

            with self.assertRaisesRegex(SystemExit, "not an importable Mojo module"):
                abi_probe.render_entrypoint([source])

    def test_declared_main_is_not_mistaken_for_a_test(self) -> None:
        source = "def main() raises:\n    pass\n\ndef test_one():\n    pass\n"
        self.assertEqual(abi_probe.test_function_names(source), ["test_one"])


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
            # Both classified roots must be on the include path, or a module
            # imported by its bare stem cannot be resolved at all.
            for root in abi_probe.SEARCH_ROOTS:
                self.assertIn(str(root), command)
            entrypoint = out / "abi_probe_main.mojo"
            self.assertTrue(entrypoint.is_file())
            self.assertIn(
                "import test_config as _mtest_module_0",
                entrypoint.read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main()
