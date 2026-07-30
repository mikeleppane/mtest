#!/usr/bin/env python3
"""Verify the shipped binary's production CPU, debug, and deployment profile."""

from __future__ import annotations

from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

from scripts.build.profiles import ProductionProfile, host_profile, load_profiles


REPO_ROOT = Path(__file__).resolve().parents[2]
TARGET_PROBE = REPO_ROOT / "tests" / "fixtures" / "build_profile" / "target_probe.mojo"
MAIN_SOURCE = REPO_ROOT / "src" / "main.mojo"
MTEST_BINARY = REPO_ROOT / "build" / "mtest"

EXPECTED_TARGETS = {
    "linux-x86_64": (
        "x86-64",
        "+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87",
    ),
    "darwin-arm64": (
        "apple-m1",
        (
            "+aes,+altnzcv,+ccdp,+complxnum,+crc,+dotprod,+fp-armv8,+fp16fml,"
            "+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,"
            "+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs"
        ),
    ),
}

_LLVM_ATTRIBUTE_GROUP = re.compile(r"^attributes #\d+ = \{(?P<body>.*)\}\s*$")
_LLVM_CPU = re.compile(r'"target-cpu"="([^"]+)"')
_LLVM_FEATURES = re.compile(r'"target-features"="([^"]+)"')
_ELF_SECTION = re.compile(r"^\s*\[\s*\d+\]\s+(\.\S+)")
_MACHO_COMMAND = re.compile(r"^\s*cmd\s+(LC_[A-Z0-9_]+)\s*$")
_MACHO_BUILD_MINIMUM = re.compile(r"^\s*minos\s+(\S+)\s*$")
_MACHO_LEGACY_MINIMUM = re.compile(r"^\s*version\s+(\S+)\s*$")


class BuildProfileError(RuntimeError):
    """The compiler or artifact did not prove the selected release profile."""


def parse_llvm_target_attributes(text: str) -> tuple[tuple[str, str], ...]:
    """Return every complete LLVM target CPU/features attribute pair.

    Args:
        text: LLVM IR emitted by the pinned Mojo compiler.

    Returns:
        Target pairs in attribute-group order.

    Raises:
        BuildProfileError: No target attributes exist, or a group is incomplete.
    """
    targets: list[tuple[str, str]] = []
    for line in text.splitlines():
        if "target-cpu" not in line and "target-features" not in line:
            continue
        group = _LLVM_ATTRIBUTE_GROUP.fullmatch(line.strip())
        if group is None:
            raise BuildProfileError(f"malformed LLVM target attribute group: {line!r}")
        body = group.group("body")
        cpus = _LLVM_CPU.findall(body)
        features = _LLVM_FEATURES.findall(body)
        if len(cpus) != 1 or len(features) != 1:
            raise BuildProfileError(
                "LLVM target attribute group must contain exactly one "
                f"target-cpu and target-features pair: {line!r}"
            )
        targets.append((cpus[0], features[0]))
    if not targets:
        raise BuildProfileError("LLVM output contains no target attribute group")
    return tuple(targets)


def parse_elf_debug_sections(text: str) -> tuple[str, ...]:
    """Return `.debug_*` section names from `readelf -S` output."""
    sections: list[str] = []
    for line in text.splitlines():
        match = _ELF_SECTION.match(line)
        if match is not None and match.group(1).startswith(".debug_"):
            sections.append(match.group(1))
    return tuple(sections)


def _parse_version(value: str, command: str) -> tuple[int, int, int]:
    parts = value.split(".")
    if not 1 <= len(parts) <= 3 or any(
        not part or not part.isdecimal() for part in parts
    ):
        raise BuildProfileError(
            f"Mach-O {command} carries malformed minimum version {value!r}"
        )
    numbers = [int(part) for part in parts]
    numbers.extend([0] * (3 - len(numbers)))
    return numbers[0], numbers[1], numbers[2]


def parse_macho_minimum_versions(text: str) -> tuple[tuple[int, int, int], ...]:
    """Return every macOS minimum in Mach-O load-command order.

    Args:
        text: `otool -l` output.

    Returns:
        Normalized three-component minimum versions.

    Raises:
        BuildProfileError: No supported minimum command exists, or one lacks
            its required version field.
    """
    versions: list[tuple[int, int, int]] = []
    command = ""
    version: str | None = None

    def finish_command() -> None:
        if command not in ("LC_BUILD_VERSION", "LC_VERSION_MIN_MACOSX"):
            return
        if version is None:
            field = "minos" if command == "LC_BUILD_VERSION" else "version"
            raise BuildProfileError(f"Mach-O {command} is missing {field}")
        versions.append(_parse_version(version, command))

    for line in text.splitlines():
        command_match = _MACHO_COMMAND.match(line)
        if command_match is not None:
            finish_command()
            command = command_match.group(1)
            version = None
            continue
        if command == "LC_BUILD_VERSION":
            match = _MACHO_BUILD_MINIMUM.match(line)
            if match is not None:
                version = match.group(1)
        elif command == "LC_VERSION_MIN_MACOSX":
            match = _MACHO_LEGACY_MINIMUM.match(line)
            if match is not None:
                version = match.group(1)
    finish_command()
    if not versions:
        raise BuildProfileError(
            "Mach-O output contains no LC_BUILD_VERSION or "
            "LC_VERSION_MIN_MACOSX minimum"
        )
    return tuple(versions)


def _normalized_target(pair: tuple[str, str]) -> tuple[str, tuple[str, ...]]:
    cpu, features = pair
    tokens = features.split(",")
    if any(not token for token in tokens):
        raise BuildProfileError(f"LLVM target-features is malformed: {features!r}")
    return cpu, tuple(sorted(tokens))


def _run(argv: list[str]) -> str:
    completed = subprocess.run(
        argv,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise BuildProfileError(
            f"`{' '.join(argv)}` exited {completed.returncode}: "
            f"{completed.stdout}{completed.stderr}"
        )
    return completed.stdout


def _llvm_command(
    profile: ProductionProfile,
    source: Path,
    output: Path,
    *,
    real_main: bool,
) -> list[str]:
    command = [
        "mojo",
        "build",
        "--emit=llvm",
        "-O3",
        "-g0",
        "--Werror",
        "--target-cpu",
        profile.mojo_cpu,
    ]
    if profile.mojo_triple is not None:
        command.extend(("--target-triple", profile.mojo_triple))
    if real_main:
        command.extend(("-I", "build"))
    command.extend((str(source.relative_to(REPO_ROOT)), "-o", str(output)))
    return command


def _verify_llvm_profile(profile: ProductionProfile, temp_dir: Path) -> None:
    expected = EXPECTED_TARGETS.get(profile.name)
    if expected is None:
        raise BuildProfileError(f"no independent target oracle for {profile.name!r}")
    expected_normalized = _normalized_target(expected)

    probe_ir = temp_dir / "target-probe.ll"
    _run(_llvm_command(profile, TARGET_PROBE, probe_ir, real_main=False))
    probe_targets = parse_llvm_target_attributes(probe_ir.read_text(encoding="utf-8"))
    for pair in probe_targets:
        if _normalized_target(pair) != expected_normalized:
            raise BuildProfileError(
                f"{profile.name} probe target differs from independent oracle: "
                f"expected={expected!r}, got={pair!r}"
            )

    main_ir = temp_dir / "main.ll"
    _run(_llvm_command(profile, MAIN_SOURCE, main_ir, real_main=True))
    main_targets = parse_llvm_target_attributes(main_ir.read_text(encoding="utf-8"))
    proven_probe = _normalized_target(probe_targets[0])
    for pair in main_targets:
        if _normalized_target(pair) != proven_probe:
            raise BuildProfileError(
                f"{profile.name} real-main target differs from proven probe: "
                f"probe={probe_targets[0]!r}, got={pair!r}"
            )
    print(
        f"build-profile: LLVM {profile.name} -- {expected[0]} "
        f"with {len(expected_normalized[1])} exact features "
        f"({len(probe_targets)} probe groups, {len(main_targets)} main groups)"
    )


def _verify_binary(profile: ProductionProfile) -> None:
    if not MTEST_BINARY.is_file():
        raise BuildProfileError(
            f"{MTEST_BINARY.relative_to(REPO_ROOT)} is missing; "
            "the gate requires its build-bin dependency"
        )
    if profile.system == "Linux":
        debug_sections = parse_elf_debug_sections(
            _run(["readelf", "-S", str(MTEST_BINARY)])
        )
        if debug_sections:
            raise BuildProfileError(
                f"Linux build/mtest contains debug sections: {debug_sections}"
            )
        print("build-profile: ELF build/mtest contains no .debug_* sections")
        return

    loads = _run(["otool", "-l", str(MTEST_BINARY)])
    if re.search(r"(?m)^\s*segname\s+__DWARF\s*$", loads):
        raise BuildProfileError("Darwin build/mtest contains a __DWARF segment")
    minimums = parse_macho_minimum_versions(loads)
    if any(version != (14, 0, 0) for version in minimums):
        raise BuildProfileError(
            f"Darwin build/mtest minimum is not exactly 14.0: {minimums!r}"
        )
    print(
        "build-profile: Mach-O build/mtest contains no __DWARF segment and "
        f"all {len(minimums)} minimum commands equal 14.0"
    )


def check() -> None:
    """Verify the current host's real compiler output and production binary."""
    profile = host_profile(
        system=platform.system(),
        machine=platform.machine(),
        profiles=load_profiles(),
    )
    with tempfile.TemporaryDirectory(prefix="mtest-build-profile-") as raw_tmp:
        _verify_llvm_profile(profile, Path(raw_tmp))
    _verify_binary(profile)


def main() -> int:
    """Run the production artifact-profile gate for the current host."""
    try:
        check()
    except (BuildProfileError, OSError) as exc:
        print(f"FATAL: build-profile: {exc}", file=sys.stderr)
        return 1
    print("build-profile: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
