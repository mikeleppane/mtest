#!/usr/bin/env python3
"""Analyze every native C translation unit with pinned Clang-Tidy."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
from typing import TYPE_CHECKING

from scripts.checks import native_abi as native_abi_check
from scripts.checks.native_sources import tracked_native_sources


if TYPE_CHECKING:
    from scripts.build.profiles import ProductionProfile


ROOT = Path(__file__).resolve().parents[2]
PINNED_VERSION = "18.1.8"
_CLANG_VERSION_LINE = re.compile(rf"clang version {re.escape(PINNED_VERSION)}(?:\s.*)?")
_TIDY_VERSION_LINE = re.compile(rf"LLVM version {re.escape(PINNED_VERSION)}(?:\s.*)?")
STRICT_FLAGS = native_abi_check.STRICT_FLAGS


@dataclass(frozen=True)
class TranslationUnit:
    """One native C source and the adapter variant it is compiled against."""

    source: Path
    testing: bool


@dataclass(frozen=True)
class CompilerContext:
    """The implicit compiler context Clang-Tidy must reproduce."""

    target: str
    resource_dir: Path
    sysroot: Path | None


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    """Run one native analysis command from the repository root."""
    return subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        text=True,
        capture_output=True,
    )


def translation_units(root: Path = ROOT) -> tuple[TranslationUnit, ...]:
    """Return the production adapter and every tracked native C test unit."""
    sources = tracked_native_sources(root)
    resolved_root = root.resolve()
    c_sources = tuple(source for source in sources if source.suffix == ".c")
    production = tuple(
        source
        for source in c_sources
        if source.relative_to(resolved_root).parts[0] == "native"
    )
    expected_production = (resolved_root / "native" / "mtest_exec_native.c",)
    if production != expected_production:
        missing = tuple(
            path.relative_to(resolved_root).as_posix()
            for path in expected_production
            if path not in production
        )
        unexpected = tuple(
            path.relative_to(resolved_root).as_posix()
            for path in production
            if path not in expected_production
        )
        raise SystemExit(
            "clang-tidy-check: production C units differ: "
            f"missing={list(missing)}, unexpected={list(unexpected)}"
        )
    tests = tuple(
        source
        for source in c_sources
        if source.relative_to(resolved_root).parts[:2] == ("tests", "native")
    )
    if not tests:
        raise SystemExit("clang-tidy-check: native test unit inventory is empty")
    return (
        TranslationUnit(production[0], testing=False),
        *(TranslationUnit(source, testing=True) for source in tests),
    )


def _diagnostic(completed: subprocess.CompletedProcess[str]) -> str:
    return (completed.stderr.strip() or completed.stdout.strip()) + "\n"


def require_toolchain(cc: str) -> None:
    """Fail unless Clang and Clang-Tidy both report the pinned version."""
    tools = (
        (cc, _CLANG_VERSION_LINE, True),
        ("clang-tidy", _TIDY_VERSION_LINE, False),
    )
    for executable, pattern, first_line_only in tools:
        version = run([executable, "--version"])
        output = version.stdout + version.stderr
        lines = tuple(line.strip() for line in output.splitlines() if line.strip())
        candidates = lines[:1] if first_line_only else lines
        canonical = any(pattern.fullmatch(line) is not None for line in candidates)
        if version.returncode != 0 or not canonical:
            raise SystemExit(
                f"clang-tidy-check: expected {executable} {PINNED_VERSION}, got:\n"
                + output
            )


def _single_value(
    arguments: list[str],
    flag: str,
    *,
    optional: bool = False,
) -> str | None:
    indexes = tuple(
        index for index, argument in enumerate(arguments) if argument == flag
    )
    values: list[str] = []
    malformed: list[str] = []
    for index in indexes:
        if index + 1 == len(arguments):
            malformed.append(f"argv[{index}] is missing a value")
            continue
        value = arguments[index + 1]
        if not value:
            malformed.append(f"argv[{index}] value is empty")
        elif value.startswith("-"):
            malformed.append(f"argv[{index}] value is option {value!r}")
        else:
            values.append(value)

    valid_count = len(indexes) <= 1 if optional else len(indexes) == 1
    if not valid_count or malformed:
        expected = f"at most one {flag}" if optional else f"exactly one {flag}"
        message = f"clang-tidy-check: {flag}: found {len(indexes)} occurrence(s)"
        if malformed:
            message += "; malformed " + ", ".join(malformed)
        raise SystemExit(message + f"; expected {expected}")
    return values[0] if values else None


def parse_compiler_context(output: str) -> CompilerContext:
    """Parse the unique cc1 target, resource directory, and optional sysroot."""
    invocations = []
    for line in output.splitlines():
        try:
            arguments = shlex.split(line)
        except ValueError as exc:
            raise SystemExit(
                f"clang-tidy-check: malformed compiler context: {exc}"
            ) from exc
        if "-cc1" in arguments:
            invocations.append(arguments)
    if len(invocations) != 1:
        raise SystemExit(
            "clang-tidy-check: compiler context requires one cc1 invocation, "
            f"found {len(invocations)}"
        )
    arguments = invocations[0]
    target = _single_value(arguments, "-triple")
    resource_dir = _single_value(arguments, "-resource-dir")
    sysroot = _single_value(arguments, "-isysroot", optional=True)
    if target is None or resource_dir is None:
        raise SystemExit("clang-tidy-check: incomplete required compiler context")
    return CompilerContext(
        target=target,
        resource_dir=Path(resource_dir),
        sysroot=None if sysroot is None else Path(sysroot),
    )


def compiler_context(cc: str, profile: ProductionProfile) -> CompilerContext:
    """Query the pinned Clang driver for its implicit host compilation context."""
    with tempfile.TemporaryDirectory(prefix="mtest-clang-context-") as raw_tmp:
        source = Path(raw_tmp) / "empty.c"
        source.write_text("", encoding="ascii")
        command = [
            cc,
            "-###",
            "-fsyntax-only",
            *profile.c_flags,
            "-x",
            "c",
            str(source),
        ]
        completed = run(command)
    if completed.returncode != 0:
        raise SystemExit(
            "clang-tidy-check: compiler context failed:\n" + _diagnostic(completed)
        )
    return parse_compiler_context(completed.stdout + completed.stderr)


def _compiler_arguments(
    unit: TranslationUnit,
    profile: ProductionProfile,
    context: CompilerContext,
) -> list[str]:
    arguments = [
        *STRICT_FLAGS,
        *profile.c_flags,
        f"--target={context.target}",
        "-resource-dir",
        str(context.resource_dir),
    ]
    if context.sysroot is not None:
        arguments.extend(("-isysroot", str(context.sysroot)))
    arguments.extend(
        (
            f"-DMTEST_EXEC_TESTING={1 if unit.testing else 0}",
            "-I",
            str(ROOT / "native"),
        )
    )
    return arguments


def parse_command(
    cc: str,
    unit: TranslationUnit,
    profile: ProductionProfile,
    context: CompilerContext,
) -> list[str]:
    """Return the pinned Clang parse-smoke command for one translation unit."""
    return [
        cc,
        *_compiler_arguments(unit, profile, context),
        "-fsyntax-only",
        str(unit.source),
    ]


def tidy_command(
    unit: TranslationUnit,
    profile: ProductionProfile,
    context: CompilerContext,
) -> list[str]:
    """Return the analyzer command that leaves check ownership to `.clang-tidy`."""
    return [
        "clang-tidy",
        str(unit.source),
        "--quiet",
        "--",
        *_compiler_arguments(unit, profile, context),
    ]


def analyze_units(
    cc: str,
    units: tuple[TranslationUnit, ...],
    profile: ProductionProfile,
    context: CompilerContext,
) -> None:
    """Parse-smoke then analyze each translation unit in deterministic order."""
    for unit in units:
        parsed = run(parse_command(cc, unit, profile, context))
        if parsed.returncode != 0:
            raise SystemExit(
                "clang-tidy-check: parse smoke failed for "
                f"{unit.source.relative_to(ROOT)}:\n{_diagnostic(parsed)}"
            )
        analyzed = run(tidy_command(unit, profile, context))
        if analyzed.returncode != 0:
            raise SystemExit(
                "clang-tidy-check: analysis failed for "
                f"{unit.source.relative_to(ROOT)}:\n{_diagnostic(analyzed)}"
            )


def main() -> int:
    """Verify the toolchain context and analyze the complete native C matrix."""
    cc = os.environ.get("CC", "clang")
    require_toolchain(cc)
    profile = native_abi_check.current_profile()
    context = compiler_context(cc, profile)
    analyze_units(cc, translation_units(), profile, context)
    print("clang-tidy-check: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
