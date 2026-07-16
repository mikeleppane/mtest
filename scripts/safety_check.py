#!/usr/bin/env python3
"""Require local SAFETY arguments beside mechanically unsafe Mojo operations.

This lexical check inventories comment presence. It cannot establish that a
SAFETY argument is correct; that remains a code-review responsibility.
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


MAX_COVERAGE_LINES = 8


@dataclass(frozen=True)
class Finding:
    path: Path
    line: int
    family: str


@dataclass(frozen=True)
class InventoryItem:
    path: Path
    line: int
    kind: str


_CANDIDATES = (
    (
        "UnsafePointer construction",
        re.compile(r"\bUnsafePointer\s*(?:\[[^\n]*\])?\s*\("),
    ),
    ("raw allocation", re.compile(r"\balloc\s*\[")),
    ("manual free", re.compile(r"\.free\s*\(")),
    (
        "unsafe constructor",
        re.compile(r"\bunsafe_from_[A-Za-z0-9_]+\s*(?:=|\()"),
    ),
    ("unsafe pointer escape", re.compile(r"\.unsafe_ptr\s*\(")),
    ("raw initialization", re.compile(r"\bmemset_[A-Za-z0-9_]*\s*\(")),
    ("pointer bitcast", re.compile(r"\.bitcast\s*\[")),
    ("FFI call", re.compile(r"\bexternal_call\s*\[")),
)

_SAFETY = re.compile(r"^\s*#\s*SAFETY:\s*\S")
_COMMENT = re.compile(r"^\s*#")
_POSSIBLE_ARITHMETIC = re.compile(
    r"\b([a-z_][A-Za-z0-9_]*)\s*\+\s*(?:[a-z_][A-Za-z0-9_]*|\d+)"
)
_POSSIBLE_DEREFERENCE = re.compile(r"\b([a-z_][A-Za-z0-9_]*)\s*\[[^\]\n]+\]")
_DERIVED_POINTER_ARITHMETIC = re.compile(
    r"\)\s*\+\s*(?:[a-z_][A-Za-z0-9_]*|\d+)"
)
_DERIVED_POINTER_DEREFERENCE = re.compile(r"\)\s*\[[^\]\n]+\]")
_NON_POINTER_BRACKETS = {
    "alloc",
    "bitcast",
    "external_call",
    "range",
}
_ALLOCATED_NAME = re.compile(
    r"\bvar\s+([A-Za-z_]\w*)\s*=\s*(?:alloc\s*\[|UnsafePointer\s*(?:\[|\())"
)
_POINTER_PARAMETER = re.compile(
    r"\b([A-Za-z_]\w*)\s*:\s*(?:UnsafePointer\b|[A-Za-z_]\w*Ptr\b)"
)


def _sanitize(source: str) -> str:
    """Blank comments and quoted strings while preserving lines and columns."""
    out: list[str] = []
    i = 0
    quote = ""
    triple = False
    escaped = False
    while i < len(source):
        ch = source[i]
        if quote:
            if ch == "\n":
                out.append("\n")
                escaped = False
                i += 1
                continue
            if escaped:
                out.append(" ")
                escaped = False
                i += 1
                continue
            if ch == "\\":
                out.append(" ")
                escaped = True
                i += 1
                continue
            marker = quote * (3 if triple else 1)
            if source.startswith(marker, i):
                out.extend(" " for _ in marker)
                i += len(marker)
                quote = ""
                triple = False
                continue
            out.append(" ")
            i += 1
            continue

        if ch == "#":
            while i < len(source) and source[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if ch in ("'", '"'):
            triple = source.startswith(ch * 3, i)
            marker = ch * (3 if triple else 1)
            quote = ch
            out.extend(" " for _ in marker)
            i += len(marker)
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _delimiter_delta(line: str) -> int:
    return sum(line.count(ch) for ch in "([{") - sum(
        line.count(ch) for ch in ")]}"
    )


def _has_candidate(line: str) -> bool:
    return any(pattern.search(line) for _, pattern in _CANDIDATES)


def _covered_lines(source: str, sanitized: str) -> set[int]:
    original_lines = source.splitlines()
    code_lines = sanitized.splitlines()
    statements: list[tuple[int, int, bool]] = []
    index = 0
    while index < len(code_lines):
        if not code_lines[index].strip():
            index += 1
            continue
        start = index
        depth = _delimiter_delta(code_lines[index])
        while depth > 0 and index + 1 < len(code_lines):
            index += 1
            depth += _delimiter_delta(code_lines[index])
        end = index
        statements.append(
            (start, end, any(_has_candidate(line) for line in code_lines[start : end + 1]))
        )
        index += 1

    covered: set[int] = set()

    for statement_index, (start, _, has_candidate) in enumerate(statements):
        if not has_candidate:
            continue
        cursor = start - 1
        has_safety = False
        while cursor >= 0 and _COMMENT.match(original_lines[cursor]):
            if _SAFETY.match(original_lines[cursor]):
                has_safety = True
            cursor -= 1
        if not has_safety:
            continue

        first_line = start
        previous_end = start - 1
        for block_start, block_end, block_has_candidate in statements[statement_index:]:
            if not block_has_candidate:
                break
            if block_start - first_line >= MAX_COVERAGE_LINES:
                break
            if any(
                not original_lines[line].strip()
                for line in range(previous_end + 1, block_start)
            ):
                break
            coverage_end = min(
                block_end + 2, first_line + MAX_COVERAGE_LINES + 1
            )
            covered.update(range(block_start + 1, coverage_end))
            previous_end = block_end

    return covered


def _manual_inventory(path: Path, lines: list[str]) -> list[InventoryItem]:
    names: set[str] = set()
    arithmetic_names: set[str] = set()
    dereference_names: set[str] = set()
    for line in lines:
        names.update(_ALLOCATED_NAME.findall(line))
        names.update(_POINTER_PARAMETER.findall(line))
        arithmetic_names.update(_POSSIBLE_ARITHMETIC.findall(line))
        dereference_names.update(
            name
            for name in _POSSIBLE_DEREFERENCE.findall(line)
            if name not in _NON_POINTER_BRACKETS
        )
    names.update(arithmetic_names & dereference_names)

    items: list[InventoryItem] = []
    for line_number, line in enumerate(lines, start=1):
        arithmetic = _POSSIBLE_ARITHMETIC.search(line)
        if (
            arithmetic and arithmetic.group(1) in names
        ) or _DERIVED_POINTER_ARITHMETIC.search(line):
            items.append(
                InventoryItem(path, line_number, "possible pointer arithmetic")
            )
        dereference = _POSSIBLE_DEREFERENCE.search(line)
        if (
            dereference and dereference.group(1) in names
        ) or _DERIVED_POINTER_DEREFERENCE.search(line):
            items.append(
                InventoryItem(path, line_number, "possible typed dereference")
            )
    return items


def scan_text(path: Path, source: str) -> tuple[list[Finding], list[InventoryItem]]:
    """Scan one Mojo source string for undocumented candidates and review hints."""
    sanitized = _sanitize(source)
    lines = sanitized.splitlines()
    covered = _covered_lines(source, sanitized)
    findings: list[Finding] = []
    for line_number, line in enumerate(lines, start=1):
        for family, pattern in _CANDIDATES:
            if pattern.search(line) and line_number not in covered:
                findings.append(Finding(path, line_number, family))
    return findings, _manual_inventory(path, lines)


def mojo_files(roots: Iterable[Path]) -> list[Path]:
    """Return deterministic Mojo inputs beneath existing roots."""
    return sorted(
        path
        for root in roots
        if root.exists()
        for path in root.rglob("*.mojo")
        if path.is_file()
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("roots", nargs="*", type=Path, default=[])
    args = parser.parse_args()
    roots = args.roots or [Path("src"), Path("tests"), Path("e2e")]

    findings: list[Finding] = []
    inventory: list[InventoryItem] = []
    for path in mojo_files(roots):
        current_findings, current_inventory = scan_text(
            path, path.read_text(encoding="utf-8")
        )
        findings.extend(current_findings)
        inventory.extend(current_inventory)

    for finding in findings:
        print(
            f"{finding.path}:{finding.line}: missing SAFETY: {finding.family}"
        )
    print("Manual-review inventory (non-gating lexical hints):")
    if inventory:
        for item in inventory:
            print(f"{item.path}:{item.line}: {item.kind}")
    else:
        print("(none)")

    if findings:
        print(f"SAFETY check failed: {len(findings)} undocumented candidate(s)")
        return 1
    print("SAFETY check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
