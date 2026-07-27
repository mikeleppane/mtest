#!/usr/bin/env python3
"""Generate one Mojo entrypoint for a deterministic set of test modules."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import re
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
TEST_DEF_RE = re.compile(r"(?m)^def (test_[A-Za-z0-9_]+)\s*\(")
MODULE_PART_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


@dataclass(frozen=True)
class TestModule:
    """One root-relative Mojo module and its declared test functions."""

    path: Path
    test_functions: list[str]


def _validated_root(repo_root: Path, root: Path) -> Path:
    absolute = root if root.is_absolute() else repo_root / root
    absolute = absolute.resolve()
    tests_root = (repo_root / "tests").resolve()
    try:
        absolute.relative_to(tests_root)
    except ValueError as exc:
        raise ValueError(f"suite root must be tests/ or below: {root}") from exc
    if not absolute.exists() or absolute.is_symlink():
        raise ValueError(f"suite root is not a real file or directory: {root}")
    return absolute


def discover_test_files(repo_root: Path, roots: list[Path]) -> list[Path]:
    """Return the unique bytewise-sorted test modules beneath validated roots."""
    found: set[Path] = set()
    for raw_root in roots:
        root = _validated_root(repo_root, raw_root)
        if root.is_file():
            if root.name.startswith("test_") and root.suffix == ".mojo":
                found.add(root.relative_to(repo_root))
            continue
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            current = Path(dirpath)
            dirnames[:] = sorted(
                (name for name in dirnames if not (current / name).is_symlink()),
                key=os.fsencode,
            )
            for name in sorted(filenames, key=os.fsencode):
                if name.startswith("test_") and name.endswith(".mojo"):
                    found.add((current / name).relative_to(repo_root))
    if not found:
        joined = " ".join(str(root) for root in roots)
        raise ValueError(f"no test_*.mojo suites under: {joined}")
    return sorted(found, key=lambda path: os.fsencode(str(path)))


def test_function_names(source: str) -> list[str]:
    """Extract declared test functions from a module's source.

    A module may also declare `main()` (mtest's classified runner requires
    every test module to be independently executable); that declaration is
    irrelevant here; the aggregate only imports the module and calls its
    `test_*` functions directly; it never invokes `main()`. Mojo's real
    constraint is on *packaging* a `main()`-declaring module (`mojo
    precompile`), not on importing one, and the aggregate only imports.
    """
    names = TEST_DEF_RE.findall(source)
    if not names:
        raise ValueError("aggregate test module declares no test_* functions")
    if len(names) != len(set(names)):
        raise ValueError("aggregate test module repeats a test function name")
    return names


def load_modules(repo_root: Path, paths: list[Path]) -> list[TestModule]:
    """Read discovered modules and return their exact test declarations."""
    modules: list[TestModule] = []
    for path in paths:
        source = (repo_root / path).read_text(encoding="utf-8")
        try:
            names = test_function_names(source)
        except ValueError as exc:
            raise ValueError(f"{path}: {exc}") from exc
        modules.append(TestModule(path, names))
    return modules


def _module_name(path: Path) -> str:
    parts = path.with_suffix("").parts
    if not all(MODULE_PART_RE.fullmatch(part) for part in parts):
        raise ValueError(f"not a valid Mojo module path: {path}")
    return ".".join(parts)


MODULE_MARKER_PREFIX = "==> "
"""The default introducer for a generated per-module progress marker.

Callers that must be able to tell their own marker apart from a line a test
body printed pass a longer prefix carrying a per-run nonce; see
`scripts/harness/classified.py`.
"""


def render_entrypoint(
    modules: list[TestModule], marker_prefix: str = MODULE_MARKER_PREFIX
) -> str:
    """Render an aggregate executable with one explicit TestSuite per module.

    Args:
        modules: The validated modules to import, register, and run, in order.
        marker_prefix: The introducer each per-module progress marker is
            printed behind. The caller owns this string; a caller that parses
            the markers back out of the child's stdout should make it
            unguessable, because everything else on that stream is written by
            test bodies.

    Returns:
        The complete Mojo source of the aggregate entrypoint.
    """
    lines = [
        '"""Generated aggregate runner; edit scripts/harness/aggregate.py."""',
        "",
        "from std.testing import TestSuite",
        "",
    ]
    for index, module in enumerate(modules):
        lines.append(f"import {_module_name(module.path)} as _mtest_module_{index}")
    lines.extend(
        [
            "",
            "",
            "def main() raises:",
            '    """Run every generated module suite in deterministic order."""',
        ]
    )
    for index, module in enumerate(modules):
        alias = f"_mtest_module_{index}"
        lines.append(f'    print("{marker_prefix}{module.path}", flush=True)')
        lines.append(f"    var suite_{index} = TestSuite()")
        lines.extend(
            f"    suite_{index}.test[{alias}.{function}]()"
            for function in module.test_functions
        )
        lines.append(f"    suite_{index}^.run()")
        if index + 1 < len(modules):
            lines.append("")
    lines.append("")
    return "\n".join(lines)


def write_entrypoint(
    repo_root: Path,
    output: Path,
    roots: list[Path],
    marker_prefix: str = MODULE_MARKER_PREFIX,
) -> list[TestModule]:
    """Write an aggregate executable for validated roots and return its modules.

    Args:
        repo_root: Repository root the roots are resolved against.
        output: Path the generated entrypoint is written to.
        roots: The classified suite roots to discover modules under.
        marker_prefix: The introducer for each per-module progress marker; see
            `render_entrypoint`.

    Returns:
        The modules the generated entrypoint imports, in generated order.
    """
    paths = discover_test_files(repo_root, roots)
    modules = load_modules(repo_root, paths)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_entrypoint(modules, marker_prefix), encoding="utf-8")
    return modules


def main(argv: list[str]) -> int:
    """Generate the aggregate entrypoint for the roots named on the command line.

    Args:
        argv: Full process argv; `argv[0]` is skipped as the program name.

    Returns:
        0 once the entrypoint is written, or 2 when discovery or the write failed.
    """
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("roots", nargs="+", type=Path)
    args = parser.parse_args(argv[1:])
    try:
        modules = write_entrypoint(REPO_ROOT, args.output, args.roots)
    except (OSError, ValueError) as exc:
        print(f"FATAL: aggregate-tests: {exc}", file=sys.stderr)
        return 2
    print(
        f"aggregate-tests: generated {args.output} for {len(modules)} module(s), "
        f"{sum(len(module.test_functions) for module in modules)} test(s)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
