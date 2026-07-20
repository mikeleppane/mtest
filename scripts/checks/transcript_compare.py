#!/usr/bin/env python3
"""Byte-exact directory comparison for generated protocol snapshots."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import difflib
from pathlib import Path
import sys


@dataclass(frozen=True)
class DirectoryComparison:
    """Result of comparing two generated-snapshot directories."""

    ok: bool
    changed_files: tuple[str, ...]
    errors: tuple[str, ...]


def _files(root: Path) -> tuple[dict[str, bytes], list[str]]:
    errors: list[str] = []
    found: dict[str, bytes] = {}
    if not root.is_dir():
        return found, [f"snapshot directory does not exist: {root}"]
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            errors.append(f"snapshot tree contains a symlink: {relative}")
        elif path.is_file():
            found[relative] = path.read_bytes()
        elif not path.is_dir():
            errors.append(f"snapshot tree contains a non-file entry: {relative}")
    return found, errors


def _byte_diff(name: str, expected: bytes, actual: bytes) -> str:
    expected_text = expected.decode("utf-8", errors="surrogateescape").splitlines(
        keepends=True
    )
    actual_text = actual.decode("utf-8", errors="surrogateescape").splitlines(
        keepends=True
    )
    diff = "".join(
        difflib.unified_diff(
            expected_text,
            actual_text,
            fromfile=f"expected/{name}",
            tofile=f"actual/{name}",
        )
    )
    return diff or f"byte mismatch in {name}"


def compare_directories(
    expected_root: Path,
    actual_root: Path,
    *,
    replacement: tuple[bytes, bytes] | None = None,
) -> DirectoryComparison:
    """Compare directory membership and bytes, optionally allowing one rewrite.

    With ``replacement=(old, new)``, each expected file is transformed by the
    exact byte replacement before comparison. No other content difference is
    accepted.
    """
    expected, errors = _files(expected_root)
    actual, actual_errors = _files(actual_root)
    errors.extend(actual_errors)
    if replacement is not None and replacement[0] == b"":
        errors.append("replacement source must not be empty")

    expected_names = set(expected)
    actual_names = set(actual)
    missing = sorted(expected_names - actual_names)
    extra = sorted(actual_names - expected_names)
    if missing:
        errors.append(f"missing snapshot files: {missing}")
    if extra:
        errors.append(f"unexpected snapshot files: {extra}")

    changed: list[str] = []
    for name in sorted(expected_names & actual_names):
        original = expected[name]
        wanted = original
        if replacement is not None:
            wanted = original.replace(replacement[0], replacement[1])
        if wanted != original:
            changed.append(name)
        if actual[name] != wanted:
            errors.append(_byte_diff(name, wanted, actual[name]))

    return DirectoryComparison(not errors, tuple(changed), tuple(errors))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("expected", type=Path)
    parser.add_argument("actual", type=Path)
    parser.add_argument("--replace-old")
    parser.add_argument("--replace-new")
    parser.add_argument("--require-change", action="store_true")
    args = parser.parse_args()

    if (args.replace_old is None) != (args.replace_new is None):
        parser.error("--replace-old and --replace-new must be supplied together")
    replacement = None
    if args.replace_old is not None:
        replacement = (
            args.replace_old.encode("utf-8"),
            args.replace_new.encode("utf-8"),
        )

    result = compare_directories(
        args.expected, args.actual, replacement=replacement
    )
    errors = list(result.errors)
    if args.require_change and not result.changed_files:
        errors.append("the approved replacement changed no snapshot file")
    if errors:
        for error in errors:
            print(error, file=sys.stderr, end="" if error.endswith("\n") else "\n")
        return 1
    print(
        "snapshot comparison: OK — "
        f"{len(result.changed_files)} path-rewritten file(s), no other changes"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
