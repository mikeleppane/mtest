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
_PINNED_VERSION_PATTERN = re.compile(r"(?<![0-9.])18\.1\.8(?![0-9.])")
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
    production = tuple(
        source
        for source in sources
        if source.relative_to(root.resolve()).as_posix() == "native/mtest_exec_native.c"
    )
    if len(production) != 1:
        raise SystemExit(
            "clang-tidy-check: expected exactly one tracked native/mtest_exec_native.c"
        )
    tests = tuple(
        source
        for source in sources
        if source.relative_to(root.resolve()).as_posix().startswith("tests/native/")
        and source.suffix == ".c"
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
    for executable in (cc, "clang-tidy"):
        version = run([executable, "--version"])
        output = version.stdout + version.stderr
        if version.returncode != 0 or _PINNED_VERSION_PATTERN.search(output) is None:
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
    values = [
        arguments[index + 1]
        for index, argument in enumerate(arguments[:-1])
        if argument == flag
    ]
    valid_count = len(values) <= 1 if optional else len(values) == 1
    if not valid_count:
        expected = f"at most one {flag}" if optional else f"one {flag}"
        raise SystemExit(
            f"clang-tidy-check: compiler context requires {expected}, "
            f"found {len(values)}"
        )
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
