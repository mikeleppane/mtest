#!/usr/bin/env python3
"""Verify authoritative native objects and compiler-hardening evidence."""

from __future__ import annotations

from itertools import pairwise
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

from scripts.build.profiles import (
    ProductionProfile,
    host_profile,
    load_profiles,
)
from scripts.checks.native_sources import tracked_native_sources


ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "native"
SOURCE = NATIVE / "mtest_exec_native.c"
HEADER = NATIVE / "mtest_exec_native.h"
TEST_HEADER = NATIVE / "mtest_exec_native_test.h"
SOURCE_FILES = tracked_native_sources(ROOT)
PRODUCTION_OBJECT = ROOT / "build" / "native" / "mtest_exec_native.o"
TESTING_OBJECT = ROOT / "build" / "native" / "mtest_exec_native_test.o"
CANARY_SOURCE = ROOT / "tests" / "native" / "stack_protector_canary.c"

# The strict production C flags are single-sourced in this file so the Python
# checks here and the bash production-build entrypoint
# (scripts/build/production_build.sh, which the recipe env runs without Python)
# read one identical inventory and cannot drift.
STRICT_FLAGS_FILE = ROOT / "scripts" / "build" / "native_strict_flags.txt"

CURATED_WARNING_FLAGS = (
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wpedantic",
    "-Wconversion",
    "-Wsign-conversion",
    "-Wshadow",
    "-Wstrict-prototypes",
    "-Wmissing-prototypes",
    "-Wformat=2",
    "-Wundef",
    "-Wcast-qual",
    "-Wwrite-strings",
    "-Wvla",
    "-Wimplicit-fallthrough",
    "-Wdouble-promotion",
    "-Wnull-dereference",
    "-Wswitch-enum",
    "-Wswitch-default",
    "-Wcast-align",
    "-Wbad-function-cast",
    "-Wmissing-noreturn",
    "-Wredundant-decls",
    "-Walloca",
    "-Warray-bounds",
    "-Wconditional-uninitialized",
    "-Wunreachable-code-aggressive",
)

PRODUCTION_SYMBOLS = {
    "mtest_exec_fd_limit",
    "mtest_exec_interrupt_count",
    "mtest_exec_interrupt_requested",
    "mtest_exec_monotonic_ms",
    "mtest_exec_native_abi_version",
    "mtest_exec_poll_set",
    "mtest_exec_process_abort",
    "mtest_exec_process_channel_close",
    "mtest_exec_process_close",
    "mtest_exec_process_group",
    "mtest_exec_process_observe",
    "mtest_exec_process_open",
    "mtest_exec_process_poll",
    "mtest_exec_process_read",
    "mtest_exec_process_reap",
    "mtest_exec_process_setup_drain",
    "mtest_exec_runtime_close",
    "mtest_exec_runtime_open",
}

TEST_ONLY_SYMBOLS = {
    "mtest_exec_test_arm_interrupt_reentry",
    "mtest_exec_test_asan_leak",
    "mtest_exec_test_asan_oob",
    "mtest_exec_test_asan_uaf",
    "mtest_exec_test_constant",
    "mtest_exec_test_fault_configure",
    "mtest_exec_test_fault_configure_handle",
    "mtest_exec_test_fault_configure_secondary",
    "mtest_exec_test_fault_handle_seen",
    "mtest_exec_test_fault_reset",
    "mtest_exec_test_fault_seen",
    "mtest_exec_test_group_signal_eperm_configure",
    "mtest_exec_test_group_signal_eperm_seen",
    "mtest_exec_test_invoke_interrupt",
    "mtest_exec_test_monotonic_wait_configure",
    "mtest_exec_test_monotonic_wait_fired",
    "mtest_exec_test_nested_interrupt_count",
    "mtest_exec_test_deliver_interrupt_after",
    "mtest_exec_test_memcheck_fd_leak",
    "mtest_exec_test_memcheck_invalid",
    "mtest_exec_test_memcheck_undefined",
    "mtest_exec_test_reset_interrupt",
}


def load_strict_flags(path: Path = STRICT_FLAGS_FILE) -> tuple[str, ...]:
    """Return the shared strict production flag inventory read from `path`.

    The file lists one flag per line; blank lines and lines beginning with '#'
    are ignored so the same inventory can carry documentation for both readers.
    """
    flags = tuple(
        stripped
        for line in path.read_text(encoding="utf-8").splitlines()
        if (stripped := line.strip()) and not stripped.startswith("#")
    )
    if not flags:
        raise SystemExit(f"native-abi-check: strict flag inventory is empty: {path}")
    if flags.count("-fstack-protector-strong") != 1:
        raise SystemExit(
            f"native-abi-check: missing required flag -fstack-protector-strong: {path}"
        )
    if "-fstack-protector" in flags:
        raise SystemExit(
            f"native-abi-check: forbidden weak flag -fstack-protector: {path}"
        )
    warning_flags = tuple(flag for flag in flags if flag.startswith("-W"))
    if warning_flags != CURATED_WARNING_FLAGS:
        missing = tuple(
            flag for flag in CURATED_WARNING_FLAGS if flag not in warning_flags
        )
        unexpected = tuple(
            flag for flag in warning_flags if flag not in CURATED_WARNING_FLAGS
        )
        raise SystemExit(
            "native-abi-check: curated warning flags differ: "
            f"missing={missing}, unexpected={unexpected}, "
            f"got={warning_flags}: {path}"
        )
    return flags


STRICT_FLAGS = load_strict_flags()


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    """Run one command from the repository root and capture diagnostics."""
    return subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def require(condition: bool, message: str) -> None:
    """Exit red with `message` unless `condition` holds."""
    if not condition:
        raise SystemExit(f"native-abi-check: {message}")


def compiler() -> str:
    """Return the configured pinned compiler after verifying its version."""
    cc = os.environ.get("CC", "clang")
    version = run([cc, "--version"])
    require(version.returncode == 0, f"cannot execute {cc}:\n{version.stdout}")
    require(
        "clang version 18.1.8" in version.stdout,
        f"wrong compiler:\n{version.stdout}",
    )
    return cc


def current_profile() -> ProductionProfile:
    """Return the strict profile selected for the current production host."""
    return host_profile(
        system=platform.system(),
        machine=platform.machine(),
        profiles=load_profiles(),
    )


def variant_compile_command(
    cc: str,
    output: Path,
    *,
    testing: bool,
    profile: ProductionProfile,
) -> list[str]:
    """Return one exact adapter compile command."""
    return [
        cc,
        *STRICT_FLAGS,
        *profile.c_flags,
        f"-DMTEST_EXEC_TESTING={1 if testing else 0}",
        "-I",
        str(NATIVE),
        "-c",
        str(SOURCE),
        "-o",
        str(output),
    ]


def compile_variant(
    cc: str,
    output: Path,
    *,
    testing: bool,
    profile: ProductionProfile,
) -> None:
    """Compile one strict adapter object for build-time use."""
    command = variant_compile_command(
        cc,
        output,
        testing=testing,
        profile=profile,
    )
    proc = run(command)
    require(proc.returncode == 0, f"native compile failed:\n{proc.stdout}")


def defined_symbols(object_path: Path) -> set[str]:
    """Return normalized externally visible definitions on Linux or Darwin."""
    nm = os.environ.get("NM", "nm")
    command = (
        [nm, "-gU", str(object_path)]
        if sys.platform == "darwin"
        else [
            nm,
            "-g",
            "--defined-only",
            str(object_path),
        ]
    )
    proc = run(command)
    require(proc.returncode == 0, f"nm failed for {object_path}:\n{proc.stdout}")
    symbols: set[str] = set()
    for line in proc.stdout.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        symbol = fields[-1]
        if sys.platform == "darwin" and symbol.startswith("_"):
            symbol = symbol[1:]
        symbols.add(symbol)
    return symbols


def undefined_symbols(object_path: Path) -> set[str]:
    """Return the undefined symbol spellings reported by the platform nm."""
    nm = os.environ.get("NM", "nm")
    proc = run([nm, "-u", str(object_path)])
    require(proc.returncode == 0, f"nm -u failed for {object_path}:\n{proc.stdout}")
    return {line.split()[-1] for line in proc.stdout.splitlines() if line.split()}


def _function_regions(
    disassembly: str,
    *,
    platform_name: str,
) -> dict[str, str]:
    """Return normalized function names mapped to their disassembly regions."""
    lines = disassembly.splitlines()
    if platform_name == "darwin":
        label = re.compile(r"^_(?P<name>[A-Za-z_$][A-Za-z0-9_.$]*):$")
    elif platform_name == "linux":
        label = re.compile(r"^[0-9A-Fa-f]+ <(?P<name>[^>]+)>:$")
    else:
        raise SystemExit(
            f"native-abi-check: unsupported disassembly platform: {platform_name}"
        )

    starts: list[tuple[int, str]] = []
    for index, line in enumerate(lines):
        match = label.fullmatch(line.strip())
        if match is not None:
            starts.append((index, match.group("name")))

    regions: dict[str, str] = {}
    for position, (start, name) in enumerate(starts):
        require(
            name not in regions,
            f"duplicate disassembly function label: {name}",
        )
        end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        regions[name] = "\n".join(lines[start:end])
    return regions


def _references_symbol(region: str, symbol: str) -> bool:
    """Return whether ``region`` contains ``symbol`` as one complete token."""
    identifier = r"A-Za-z0-9_.$"
    pattern = re.compile(rf"(?<![{identifier}]){re.escape(symbol)}(?![{identifier}])")
    return pattern.search(region) is not None


def _protected_names(regions: dict[str, str], symbol: str) -> tuple[str, ...]:
    """Return sorted names for regions that reference ``symbol``."""
    return tuple(
        sorted(
            name
            for name, region in regions.items()
            if _references_symbol(region, symbol)
        )
    )


def _darwin_function_ranges(
    disassembly: str,
) -> tuple[tuple[int, int, str], ...]:
    """Return strict ARM64 function address ranges from ``otool -tvV``."""
    lines = disassembly.splitlines()
    section_headers = [
        index
        for index, line in enumerate(lines)
        if line.strip() == "(__TEXT,__text) section"
    ]
    require(
        len(section_headers) == 1,
        "Darwin disassembly expected exactly one (__TEXT,__text) section",
    )
    text_lines = lines[section_headers[0] + 1 :]
    label = re.compile(r"^_(?P<name>[A-Za-z_$][A-Za-z0-9_.$]*):$")
    instruction = re.compile(r"^(?P<address>[0-9A-Fa-f]{8,16})\s+")
    labels: list[tuple[int, str]] = []
    for index, line in enumerate(text_lines):
        match = label.fullmatch(line.strip())
        if match is not None:
            labels.append((index, match.group("name")))

    require(bool(labels), "Darwin disassembly parsed no function ranges")
    ranges: list[tuple[int, int, str]] = []
    names: set[str] = set()
    for position, (start_line, name) in enumerate(labels):
        require(name not in names, f"duplicate disassembly function label: {name}")
        names.add(name)
        end_line = (
            labels[position + 1][0] if position + 1 < len(labels) else len(text_lines)
        )
        addresses = [
            int(match.group("address"), 16)
            for line in text_lines[start_line + 1 : end_line]
            if (match := instruction.match(line.strip())) is not None
        ]
        require(
            bool(addresses),
            f"Darwin function {name} has no parsed instructions",
        )
        require(
            addresses == sorted(set(addresses)),
            f"Darwin function {name} has non-increasing instruction addresses",
        )
        ranges.append((addresses[0], addresses[-1] + 4, name))

    by_start: dict[int, list[str]] = {}
    for start, _, name in ranges:
        by_start.setdefault(start, []).append(name)
    for start, aliases in by_start.items():
        require(
            len(aliases) == 1,
            f"ambiguous Darwin function start 0x{start:x}: "
            + ", ".join(sorted(aliases)),
        )

    ordered = tuple(sorted(ranges))
    for previous, current in pairwise(ordered):
        require(
            previous[1] <= current[0],
            "ambiguous Darwin function ranges: "
            f"{previous[2]} [0x{previous[0]:x},0x{previous[1]:x}) overlaps "
            f"{current[2]} [0x{current[0]:x},0x{current[1]:x})",
        )
    return ordered


def _darwin_target_relocation_addresses(
    relocations: str,
    *,
    symbol: str,
) -> tuple[int, ...]:
    """Return exact external ARM64 branch relocations to ``symbol``."""
    section_header = re.compile(
        r"^Relocation information "
        r"\((?P<segment>[^,()\s]+),(?P<section>[^,()\s]+)\) "
        r"[0-9]+ entries$"
    )
    relocation = re.compile(
        r"^(?P<address>[0-9A-Fa-f]{8,16})\s+"
        r"(?P<pcrel>True|False)\s+"
        r"(?P<length>byte|word|long|quad)\s+"
        r"(?P<extern>True|False)\s+"
        r"(?P<type>[A-Z0-9_]+)\s+"
        r"(?P<scattered>True|False)\s+"
        r"(?P<symbol>\S+)$"
    )
    current_section: tuple[str, str] | None = None
    addresses: list[int] = []
    for raw_line in relocations.splitlines():
        line = raw_line.strip()
        header_match = section_header.fullmatch(line)
        if header_match is not None:
            current_section = (
                header_match.group("segment"),
                header_match.group("section"),
            )
            continue
        if line.startswith("Relocation information "):
            raise SystemExit(
                f"native-abi-check: unparsed Darwin relocation section header: {line}"
            )
        if not _references_symbol(line, symbol):
            continue
        require(
            current_section == ("__TEXT", "__text"),
            f"stack-check relocation for {symbol} is outside (__TEXT,__text): {line}",
        )
        match = relocation.fullmatch(line)
        if match is None:
            raise SystemExit(
                f"native-abi-check: unparsed Darwin relocation for {symbol}: {line}"
            )
        require(
            match.group("pcrel") == "True"
            and match.group("length") == "long"
            and match.group("extern") == "True"
            and match.group("type") == "BR26"
            and match.group("scattered") == "False"
            and match.group("symbol") == symbol,
            f"Darwin relocation for {symbol} is not exact external BR26: {line}",
        )
        address = int(match.group("address"), 16)
        require(
            address not in addresses,
            f"duplicate Darwin relocation address for {symbol}: 0x{address:x}",
        )
        addresses.append(address)
    return tuple(sorted(addresses))


def _darwin_protected_names(
    disassembly: str,
    relocations: str,
    *,
    symbol: str,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Map exact stack-check relocation addresses to Darwin function names."""
    ranges = _darwin_function_ranges(disassembly)
    protected: set[str] = set()
    parsed = tuple(sorted(name for _, _, name in ranges))
    for address in _darwin_target_relocation_addresses(
        relocations,
        symbol=symbol,
    ):
        matches = [name for start, end, name in ranges if start <= address < end]
        require(
            len(matches) == 1,
            f"Darwin relocation address 0x{address:x} for {symbol} does not "
            "map to exactly one function; parsed functions: " + ", ".join(parsed),
        )
        protected.add(matches[0])
    return tuple(sorted(protected)), parsed


def protected_function_names(
    disassembly: str,
    *,
    symbol: str,
    platform: str,
    relocations: str | None = None,
) -> tuple[str, ...]:
    """Return every normalized function region that references ``symbol``."""
    if platform == "darwin":
        if relocations is None:
            raise SystemExit(
                "native-abi-check: Darwin stack-protector evidence requires "
                "otool -rv relocations"
            )
        protected, _ = _darwin_protected_names(
            disassembly,
            relocations,
            symbol=symbol,
        )
        return protected
    regions = _function_regions(disassembly, platform_name=platform)
    return _protected_names(regions, symbol)


def require_protected_functions(
    disassembly: str,
    *,
    symbol: str,
    platform: str,
    relocations: str | None = None,
) -> tuple[str, ...]:
    """Require and return nonempty stack-protector artifact evidence."""
    if platform == "darwin":
        if relocations is None:
            raise SystemExit(
                "native-abi-check: Darwin stack-protector evidence requires "
                "otool -rv relocations"
            )
        protected, parsed_names = _darwin_protected_names(
            disassembly,
            relocations,
            symbol=symbol,
        )
        parsed = ", ".join(parsed_names) if parsed_names else "<none>"
        require(
            bool(protected),
            "production Darwin relocations have no stack-check relocations "
            f"mapped to functions for {symbol}; parsed functions: {parsed}",
        )
        return protected
    regions = _function_regions(disassembly, platform_name=platform)
    protected = _protected_names(regions, symbol)
    parsed = ", ".join(sorted(regions)) if regions else "<none>"
    require(
        bool(protected),
        f"production disassembly has no function region references {symbol}; "
        f"parsed functions: {parsed}",
    )
    return protected


def disassembly(object_path: Path) -> str:
    """Return platform disassembly used for function-range evidence."""
    if sys.platform == "linux":
        command = [os.environ.get("OBJDUMP", "objdump"), "-dr", str(object_path)]
    elif sys.platform == "darwin":
        command = [os.environ.get("OTOOL", "otool"), "-tvV", str(object_path)]
    else:
        raise SystemExit(
            f"native-abi-check: unsupported production host platform {sys.platform}"
        )
    proc = run(command)
    require(
        proc.returncode == 0,
        f"disassembly failed for {object_path}:\n{proc.stdout}",
    )
    return proc.stdout


def darwin_relocations(object_path: Path) -> str:
    """Return Darwin relocation records used for external-call evidence."""
    require(
        sys.platform == "darwin",
        f"Darwin relocations requested on unsupported platform {sys.platform}",
    )
    command = [os.environ.get("OTOOL", "otool"), "-rv", str(object_path)]
    proc = run(command)
    require(
        proc.returncode == 0,
        f"relocation inspection failed for {object_path}:\n{proc.stdout}",
    )
    return proc.stdout


def stack_check_symbol(platform_name: str = sys.platform) -> str:
    """Return the platform spelling of the stack-check failure symbol."""
    if platform_name == "linux":
        return "__stack_chk_fail"
    if platform_name == "darwin":
        return "___stack_chk_fail"
    raise SystemExit(
        f"native-abi-check: unsupported production host platform {platform_name}"
    )


def verify_stack_protector(
    cc: str,
    profile: ProductionProfile,
    production: Path,
) -> tuple[str, ...]:
    """Prove stack protection in the artifact and against a compiler control."""
    symbol = stack_check_symbol()
    require(
        symbol in undefined_symbols(production),
        f"production object does not reference {symbol}",
    )
    # The compiler-inserted failure branch is artifact evidence, not an
    # ordinary source-level post-fork call: it is reachable only after a stack
    # overwrite, when normal child execution is already impossible. Keep the
    # source call-graph allowlist unchanged. Strong protection chooses functions
    # by a target- and optimization-sensitive heuristic, so the portable
    # artifact contract is a nonempty measured set rather than one fixed name.
    protected = require_protected_functions(
        disassembly(production),
        symbol=symbol,
        platform=sys.platform,
        relocations=(
            darwin_relocations(production) if sys.platform == "darwin" else None
        ),
    )
    with tempfile.TemporaryDirectory(prefix="mtest-stack-canary-") as raw_tmp:
        tmp = Path(raw_tmp)
        positive = tmp / "positive.o"
        negative = tmp / "negative.o"
        positive_command = [
            cc,
            *STRICT_FLAGS,
            *profile.c_flags,
            "-c",
            str(CANARY_SOURCE),
            "-o",
            str(positive),
        ]
        positive_compile = run(positive_command)
        require(
            positive_compile.returncode == 0,
            f"stack canary compile failed:\n{positive_compile.stdout}",
        )
        negative_flags = tuple(
            flag for flag in STRICT_FLAGS if flag != "-fstack-protector-strong"
        )
        negative_command = [
            cc,
            *negative_flags,
            *profile.c_flags,
            "-c",
            str(CANARY_SOURCE),
            "-o",
            str(negative),
        ]
        negative_compile = run(negative_command)
        require(
            negative_compile.returncode == 0,
            f"negative stack canary compile failed:\n{negative_compile.stdout}",
        )
        require(
            symbol in undefined_symbols(positive),
            f"positive stack canary does not reference {symbol}",
        )
        require(
            symbol not in undefined_symbols(negative),
            f"negative stack canary unexpectedly references {symbol}",
        )
    return protected


def main(*, strict_flags_file: Path = STRICT_FLAGS_FILE) -> int:
    """Verify authoritative objects, stack protection, and symbol isolation."""
    require(
        load_strict_flags(strict_flags_file) == STRICT_FLAGS,
        "strict flag inventory changed after module load",
    )
    require(bool(SOURCE_FILES), "source inventory is empty")
    for path in SOURCE_FILES:
        require(path.is_file(), f"missing required file: {path.relative_to(ROOT)}")

    for object_path in (PRODUCTION_OBJECT, TESTING_OBJECT):
        require(
            object_path.is_file(),
            f"missing authoritative object: {object_path.relative_to(ROOT)}",
        )
    cc = compiler()
    profile = current_profile()
    production_got = defined_symbols(PRODUCTION_OBJECT)
    require(
        production_got == PRODUCTION_SYMBOLS,
        "production symbols differ:\n"
        f"  missing={sorted(PRODUCTION_SYMBOLS - production_got)}\n"
        f"  extra={sorted(production_got - PRODUCTION_SYMBOLS)}",
    )
    expected_testing = PRODUCTION_SYMBOLS | TEST_ONLY_SYMBOLS
    testing_got = defined_symbols(TESTING_OBJECT)
    require(
        testing_got == expected_testing,
        "test symbols differ:\n"
        f"  missing={sorted(expected_testing - testing_got)}\n"
        f"  extra={sorted(testing_got - expected_testing)}",
    )
    protected = verify_stack_protector(cc, profile, PRODUCTION_OBJECT)

    print("native-abi-check: stack-protected functions: " + ", ".join(protected))
    print(
        "native-abi-check: OK -- ABI v2 layouts and "
        f"{len(PRODUCTION_SYMBOLS)}/{len(expected_testing)} symbols exact"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
