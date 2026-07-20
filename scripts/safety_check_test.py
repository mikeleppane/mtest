#!/usr/bin/env python3
"""Mutation tests for the local Mojo SAFETY-comment checker."""

from __future__ import annotations

import unittest
from pathlib import Path

from scripts import safety_check


class SafetyCheckTests(unittest.TestCase):
    def assert_clean(self, source: str) -> None:
        findings, _ = safety_check.scan_text(Path("fixture.mojo"), source)
        self.assertEqual(findings, [])

    def assert_undocumented(self, source: str, family: str, line: int = 1) -> None:
        findings, _ = safety_check.scan_text(Path("fixture.mojo"), source)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].family, family)
        self.assertEqual(findings[0].line, line)

    def test_recognizes_each_unsafe_syntax_family(self) -> None:
        cases = {
            "UnsafePointer construction": "var p = UnsafePointer[Int](to=x)\n",
            "raw allocation": "var p = alloc[Int](1)\n",
            "manual free": "p.free()\n",
            "unsafe constructor": "StringSlice(unsafe_from_utf8=data)\n",
            "unsafe pointer escape": "value.unsafe_ptr()\n",
            "raw initialization": "memset_zero(p, 8)\n",
            "pointer bitcast": "p.bitcast[UInt8]()\n",
            "FFI call": 'external_call["read", Int](fd, p, n)\n',
        }
        for family, source in cases.items():
            with self.subTest(family=family):
                self.assert_undocumented(source, family)

    def test_adjacent_safety_clause_covers_candidate(self) -> None:
        self.assert_clean(
            "# SAFETY: `p` owns one initialized Int slot here.\n"
            "p.free()\n"
        )

    def test_one_clause_covers_a_contiguous_unsafe_block(self) -> None:
        self.assert_clean(
            "# SAFETY: both buffers are initialized before reads and freed once.\n"
            "var first = alloc[Int](1)\n"
            "var second = alloc[Int](1)\n"
            "first.free()\n"
            "second.free()\n"
        )

    def test_nonadjacent_safety_clause_does_not_cover_candidate(self) -> None:
        self.assert_undocumented(
            "# SAFETY: This clause is too far from the operation.\n"
            "var unrelated = 1\n"
            "var still_unrelated = 2\n"
            "p.free()\n",
            "manual free",
            line=4,
        )

    def test_multiline_ffi_call_uses_opening_line(self) -> None:
        self.assert_undocumented(
            "var rc = external_call[\n"
            '    "read", Int,\n'
            "](fd, p, n)\n",
            "FFI call",
        )

    def test_clause_does_not_cover_past_maximum_line_distance(self) -> None:
        source = (
            "# SAFETY: covers the opening FFI call only.\n"
            "var rc = external_call[\n"
            '    "read",\n'
            "    Int,\n"
            "    # one\n"
            "    # two\n"
            "    # three\n"
            "    # four\n"
            "    # five\n"
            "](fd, p.bitcast[UInt8](), n)\n"
        )
        findings, _ = safety_check.scan_text(Path("fixture.mojo"), source)
        self.assertEqual(
            [(finding.family, finding.line) for finding in findings],
            [("pointer bitcast", 10)],
        )

    def test_ignores_comments_imports_and_type_annotations(self) -> None:
        self.assert_clean(
            "# external_call[\"abort\", Int32]()\n"
            "from std.ffi import external_call\n"
            "from std.memory import UnsafePointer, alloc\n"
            "def consume(p: UnsafePointer[Int, origin]):\n"
            "    pass\n"
        )

    def test_ignores_ordinary_and_triple_quoted_strings(self) -> None:
        self.assert_clean(
            "var ordinary = 'external_call[\"abort\", Int32]()'\n"
            'var generated = """\n'
            "from std.ffi import external_call\n"
            "def main():\n"
            "    _ = external_call[\"abort\", Int32]()\n"
            '"""\n'
        )

    def test_reports_manual_review_inventory_separately(self) -> None:
        findings, inventory = safety_check.scan_text(
            Path("fixture.mojo"),
            "# SAFETY: bounded inside a two-element allocation.\n"
            "var second = p + 1\n"
            "# SAFETY: bounded inside a two-element allocation.\n"
            "var value = p[1]\n",
        )
        self.assertEqual(findings, [])
        self.assertEqual([item.kind for item in inventory], [
            "possible pointer arithmetic",
            "possible typed dereference",
        ])

    def test_inventory_includes_derived_pointer_operations(self) -> None:
        findings, inventory = safety_check.scan_text(
            Path("fixture.mojo"),
            "# SAFETY: the bitcast retains p's live allocation and bounds.\n"
            "var byte = p.bitcast[UInt8]() + offset\n"
            "var value = make_ptr()[0]\n",
        )
        self.assertEqual(findings, [])
        self.assertEqual(
            [item.kind for item in inventory],
            ["possible pointer arithmetic", "possible typed dereference"],
        )


if __name__ == "__main__":
    unittest.main()
