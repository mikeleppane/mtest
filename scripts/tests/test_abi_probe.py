#!/usr/bin/env python3
"""Unit tests for the one-declarer-per-external_call-symbol rule.

The gate is a lexical statement about the classified sources, so every test is
a disposable fixture tree and an assertion about what the scan makes of it. The
cases deciding whether a match is real code or fixture data carry the weight:
mistaking one for the other misses a second declaration or rejects a string.
Two mutation cases keep the checker from quietly accepting everything, one over
fixtures and one over the live tree.
"""

from __future__ import annotations

from pathlib import Path
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
        """A fixture string literal carries no declaration.

        Several classified suites build a throwaway fixture source as string
        literals to compile elsewhere. A naive text search matches
        `external_call["sym"` inside that string, but the containing module
        never compiles it, so it carries no ABI risk.
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

        `tests/integration/test_exec_etxtbsy.mojo` writes
        `mtest_exec_test_monotonic_wait_configure` this way. A scanner
        requiring `external_call["sym"` on one physical line never sees it,
        because each line on its own looks unmatched.
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

        The fixture-generation convention writes every physical line of a
        generated source as its own quoted literal, including the line that
        OPENS the `external_call[` span, so checking that opening line
        excludes the whole span however far it spreads.
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

    def test_a_real_declaration_on_a_line_opening_with_a_quote_is_counted(
        self,
    ) -> None:
        """A line may begin with a complete string and still be code.

        The first-character test this replaces read any line starting with a
        quote as fixture data, so a declaration on a continuation line never
        entered the co-link set and an arity drift against it built clean.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            source = Path(raw_tmp) / "test_example.mojo"
            source.write_text(
                "def test_reports() raises:\n"
                "    assert_equal(\n"
                '        "expected", String(external_call["getpid", Int32]())\n'
                "    )\n",
                encoding="utf-8",
            )
            self.assertEqual(abi_probe.declared_symbols(source), {"getpid"})

    def test_a_quote_of_the_other_kind_inside_a_literal_opens_nothing(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            source = Path(raw_tmp) / "test_example.mojo"
            source.write_text(
                "def test_apostrophe() raises:\n"
                '        "it\'s fine", String(external_call["getppid", Int32]())\n',
                encoding="utf-8",
            )
            self.assertEqual(abi_probe.declared_symbols(source), {"getppid"})

    def test_an_escaped_quote_does_not_close_a_fixture_literal(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            source = Path(raw_tmp) / "test_example.mojo"
            source.write_text(
                "def test_generates_fixture() raises:\n"
                "    var fixture = (\n"
                '        "    var s = \\"x\\" + external_call'
                '[\\"abort\\", Int32]()\\n"\n'
                "    )\n",
                encoding="utf-8",
            )
            self.assertEqual(abi_probe.declared_symbols(source), set())

    def test_the_offset_test_agrees_with_an_odd_quote_count(self) -> None:
        cases = (
            ('    _ = external_call["sym", Int32]()', False),
            ("        '    _ = external_call[\"sym\", Int32]()\\n'", True),
            ('        "expected", String(external_call["sym", Int32]())', False),
            ('    "one" + "two" + String(external_call["sym", Int32]())', False),
        )
        for line, expected in cases:
            with self.subTest(line=line):
                column = line.index("external_call[")
                self.assertEqual(
                    abi_probe._opens_inside_string_literal(line, column), expected
                )


class DeclaringSourcesTests(unittest.TestCase):
    def test_an_empty_test_tree_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            empty = Path(raw_tmp) / "tests"
            empty.mkdir()
            with (
                patch.object(abi_probe, "SEARCH_ROOT", empty),
                self.assertRaisesRegex(SystemExit, "no Mojo sources"),
            ):
                abi_probe.declaring_sources()

    def test_the_real_test_tree_is_nonempty(self) -> None:
        self.assertGreater(len(abi_probe.declaring_sources()), 0)

    def test_the_shared_home_is_inside_the_scanned_universe(self) -> None:
        """The file holding the single declarations must itself be scanned.

        Scanning only the classified roots left `tests/support` out of the
        comparison, so a suite re-declaring a symbol the shared wrapper
        already owns looked like the lone declarer and passed.
        """
        found = {path.as_posix() for path in abi_probe.declaring_sources()}
        self.assertIn((abi_probe.ROOT / abi_probe.SHARED_HOME).as_posix(), found)

    def test_every_mojo_file_counts_not_only_test_prefixed_ones(self) -> None:
        """Support modules and fixtures hold declarations too.

        A `test_*.mojo` filter would exclude the shared home by name even
        after the root widened, and leave a fixture free to duplicate a
        declaration.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp) / "tests"
            (root / "support").mkdir(parents=True)
            (root / "unit").mkdir()
            (root / "unit" / "test_flat.mojo").write_text("", encoding="utf-8")
            (root / "support" / "helper.mojo").write_text("", encoding="utf-8")

            with patch.object(abi_probe, "SEARCH_ROOT", root):
                found = abi_probe.declaring_sources()

        self.assertEqual(
            [path.name for path in found], ["helper.mojo", "test_flat.mojo"]
        )

    def test_a_nested_module_is_discovered(self) -> None:
        """Everything else that reads this tree walks it recursively.

        `scripts/harness/selfhost.py` runs nested modules and
        `scripts/checks/layout.py` reaches them with `rglob`, so a
        non-recursive walk here would leave a nested module free to duplicate
        a declaration the suite still executes.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp) / "tests"
            (root / "unit" / "nested").mkdir(parents=True)
            (root / "unit" / "test_flat.mojo").write_text("", encoding="utf-8")
            (root / "unit" / "nested" / "test_ffi.mojo").write_text(
                "", encoding="utf-8"
            )

            with patch.object(abi_probe, "SEARCH_ROOT", root):
                found = abi_probe.declaring_sources()

        self.assertIn("test_ffi.mojo", [path.name for path in found])


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


class ViolationReportTests(unittest.TestCase):
    def test_the_report_names_every_symbol_module_and_the_single_home(
        self,
    ) -> None:
        """A violation must be fixable from the message alone."""
        a = abi_probe.ROOT / "tests" / "integration" / "test_a.mojo"
        b = abi_probe.ROOT / "tests" / "support" / "helper.mojo"
        message = abi_probe.violation_report({"waitpid": [a, b]})
        self.assertIn("waitpid", message)
        self.assertIn("tests/integration/test_a.mojo", message)
        self.assertIn("tests/support/helper.mojo", message)
        self.assertIn("tests/support/foreign_abi.mojo", message)


class MainTests(unittest.TestCase):
    def test_two_modules_declaring_one_symbol_is_rejected(self) -> None:
        """The mutation case: a real second declaration must fail the gate.

        Written as two fixture sources rather than a patched grouping, so the
        scan and the verdict run on the path a contributor would take to break
        this.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp) / "tests"
            unit = root / "unit"
            integration = root / "integration"
            unit.mkdir(parents=True)
            integration.mkdir()
            for directory in (unit, integration):
                (directory / f"test_{directory.name}.mojo").write_text(
                    "def test_one() raises:\n"
                    '    _ = external_call["waitpid", Int32](p, s, o)\n',
                    encoding="utf-8",
                )

            with (
                patch.object(abi_probe, "SEARCH_ROOT", root),
                patch.object(abi_probe, "ROOT", root),
                self.assertRaises(SystemExit) as raised,
            ):
                abi_probe.main()

        message = str(raised.exception)
        self.assertIn("waitpid", message)
        self.assertIn("more than one test-tree", message)

    def test_one_declarer_per_symbol_passes(self) -> None:
        """Distinct symbols, and a repeated call to one of them, are fine.

        Two modules may both CALL a shared wrapper; only two modules DECLARING
        one symbol is the failure.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp) / "tests"
            unit = root / "unit"
            integration = root / "integration"
            unit.mkdir(parents=True)
            integration.mkdir()
            (unit / "test_alpha.mojo").write_text(
                "def test_one() raises:\n"
                '    _ = external_call["getpid", Int32]()\n'
                '    _ = external_call["getpid", Int32]()\n',
                encoding="utf-8",
            )
            (integration / "test_beta.mojo").write_text(
                'def test_two() raises:\n    _ = external_call["chmod", Int32](p, m)\n',
                encoding="utf-8",
            )

            with (
                patch.object(abi_probe, "SEARCH_ROOT", root),
                patch.object(abi_probe, "ROOT", root),
            ):
                self.assertEqual(abi_probe.main(), 0)

    def test_a_fixture_literal_in_two_modules_is_not_a_violation(self) -> None:
        """Generated-fixture source is data, so it cannot collide.

        Two suites emitting a throwaway program that calls `abort` share no
        declaration: neither compiles that text, and the generated programs
        are separate binaries.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp) / "tests"
            unit = root / "unit"
            integration = root / "integration"
            unit.mkdir(parents=True)
            integration.mkdir()
            for directory in (unit, integration):
                (directory / f"test_{directory.name}.mojo").write_text(
                    "def test_one() raises:\n"
                    "    var fixture = (\n"
                    "        '    _ = external_call[\"abort\", Int32]()\\n'\n"
                    "    )\n",
                    encoding="utf-8",
                )

            with (
                patch.object(abi_probe, "SEARCH_ROOT", root),
                patch.object(abi_probe, "ROOT", root),
            ):
                self.assertEqual(abi_probe.main(), 0)

    def test_the_real_tree_has_no_multiply_declared_symbol(self) -> None:
        """The live tree must satisfy the rule, not just the fixtures."""
        self.assertEqual(
            abi_probe.shared_symbol_files(abi_probe.declaring_sources()), {}
        )


if __name__ == "__main__":
    unittest.main()
