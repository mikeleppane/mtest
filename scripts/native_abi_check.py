#!/usr/bin/env python3
"""Compile and verify the exact native exec adapter ABI variants."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
SOURCE = NATIVE / "mtest_exec_native.c"
HEADER = NATIVE / "mtest_exec_native.h"
TEST_HEADER = NATIVE / "mtest_exec_native_test.h"

PRODUCTION_SYMBOLS = {
    "mtest_exec_interrupt_requested",
    "mtest_exec_monotonic_ms",
    "mtest_exec_native_abi_version",
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
    "mtest_exec_test_asan_leak",
    "mtest_exec_test_asan_oob",
    "mtest_exec_test_asan_uaf",
    "mtest_exec_test_fault_configure",
    "mtest_exec_test_fault_configure_secondary",
    "mtest_exec_test_fault_reset",
    "mtest_exec_test_fault_seen",
    "mtest_exec_test_deliver_interrupt_after",
    "mtest_exec_test_memcheck_fd_leak",
    "mtest_exec_test_memcheck_invalid",
    "mtest_exec_test_memcheck_undefined",
    "mtest_exec_test_reset_interrupt",
}

STRICT_FLAGS = (
    "-std=c17",
    "-O2",
    "-DNDEBUG",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wpedantic",
    "-fPIC",
    "-fvisibility=hidden",
)


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


def compile_variant(cc: str, output: Path, *, testing: bool) -> None:
    """Compile one strict production or test adapter object."""
    command = [
        cc,
        *STRICT_FLAGS,
        f"-DMTEST_EXEC_TESTING={1 if testing else 0}",
        "-I",
        str(NATIVE),
        "-c",
        str(SOURCE),
        "-o",
        str(output),
    ]
    proc = run(command)
    require(proc.returncode == 0, f"native compile failed:\n{proc.stdout}")


def defined_symbols(object_path: Path) -> set[str]:
    """Return normalized externally visible definitions on Linux or Darwin."""
    nm = os.environ.get("NM", "nm")
    command = [nm, "-gU", str(object_path)] if sys.platform == "darwin" else [
        nm,
        "-g",
        "--defined-only",
        str(object_path),
    ]
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


def main() -> int:
    """Verify files, strict compilation, layouts, and symbol isolation."""
    for path in (SOURCE, HEADER, TEST_HEADER):
        require(path.is_file(), f"missing required file: {path.relative_to(ROOT)}")

    cc = compiler()
    with tempfile.TemporaryDirectory(prefix="mtest-native-abi-") as raw_tmp:
        tmp = Path(raw_tmp)
        production = tmp / "mtest_exec_native.o"
        testing = tmp / "mtest_exec_native_test.o"
        compile_variant(cc, production, testing=False)
        compile_variant(cc, testing, testing=True)

        production_got = defined_symbols(production)
        require(
            production_got == PRODUCTION_SYMBOLS,
            "production symbols differ:\n"
            f"  missing={sorted(PRODUCTION_SYMBOLS - production_got)}\n"
            f"  extra={sorted(production_got - PRODUCTION_SYMBOLS)}",
        )
        expected_testing = PRODUCTION_SYMBOLS | TEST_ONLY_SYMBOLS
        testing_got = defined_symbols(testing)
        require(
            testing_got == expected_testing,
            "test symbols differ:\n"
            f"  missing={sorted(expected_testing - testing_got)}\n"
            f"  extra={sorted(testing_got - expected_testing)}",
        )

    print("native-abi-check: OK -- ABI v1 layouts and 15/27 symbols exact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
