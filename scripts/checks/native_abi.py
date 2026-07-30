#!/usr/bin/env python3
"""Verify authoritative native objects and compiler-hardening evidence."""

from __future__ import annotations

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
PROTECTED_FUNCTION = "mtest_exec_process_open"

# The strict production C flags are single-sourced in this file so the Python
# checks here and the bash production-build entrypoint
# (scripts/build/production_build.sh, which the recipe env runs without Python)
# read one identical inventory and cannot drift.
STRICT_FLAGS_FILE = ROOT / "scripts" / "build" / "native_strict_flags.txt"

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


def _function_region(
    disassembly: str,
    *,
    function: str,
    platform_name: str,
) -> str | None:
    if platform_name == "darwin":
        label = f"_{function}:"
        lines = disassembly.splitlines()
        starts = [index for index, line in enumerate(lines) if line.strip() == label]
        if len(starts) != 1:
            return None
        start = starts[0]
        end = len(lines)
        for index in range(start + 1, len(lines)):
            if re.fullmatch(r"_[A-Za-z_$][A-Za-z0-9_.$]*:", lines[index].strip()):
                end = index
                break
        return "\n".join(lines[start:end])
    if platform_name == "linux":
        linux_label = re.compile(rf"^[0-9A-Fa-f]+ <{re.escape(function)}>:$")
        global_label = re.compile(r"^[0-9A-Fa-f]+ <[^>]+>:$")
        lines = disassembly.splitlines()
        starts = [
            index
            for index, line in enumerate(lines)
            if linux_label.fullmatch(line.strip())
        ]
        if len(starts) != 1:
            return None
        start = starts[0]
        end = len(lines)
        for index in range(start + 1, len(lines)):
            if global_label.fullmatch(lines[index].strip()):
                end = index
                break
        return "\n".join(lines[start:end])
    raise SystemExit(
        f"native-abi-check: unsupported disassembly platform: {platform_name}"
    )


def function_references_symbol(
    disassembly: str,
    *,
    function: str,
    symbol: str,
    platform: str,
) -> bool:
    """Return whether ``symbol`` occurs inside exactly ``function``."""
    region = _function_region(
        disassembly,
        function=function,
        platform_name=platform,
    )
    return region is not None and symbol in region


def disassembly(object_path: Path) -> str:
    """Return platform disassembly with relocation/symbol references."""
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
) -> None:
    """Prove stack protection in the artifact and against a compiler control."""
    symbol = stack_check_symbol()
    require(
        symbol in undefined_symbols(production),
        f"production object does not reference {symbol}",
    )
    # The compiler-inserted failure branch is artifact evidence, not an
    # ordinary source-level post-fork call: it is reachable only after a stack
    # overwrite, when normal child execution is already impossible. Keep the
    # source call-graph allowlist unchanged.
    require(
        function_references_symbol(
            disassembly(production),
            function=PROTECTED_FUNCTION,
            symbol=symbol,
            platform=sys.platform,
        ),
        f"{PROTECTED_FUNCTION} does not reference {symbol}",
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
    verify_stack_protector(cc, profile, PRODUCTION_OBJECT)

    print(
        "native-abi-check: OK -- ABI v2 layouts and "
        f"{len(PRODUCTION_SYMBOLS)}/{len(expected_testing)} symbols exact"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
