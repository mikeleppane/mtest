#!/usr/bin/env python3
"""Build the risk-weighted exec layer from source and run it under ASan/LSan."""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from scripts import aggregate_tests
from scripts import native_abi_check


ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "safety" / "asan"
NATIVE_SOURCE = ROOT / "native" / "mtest_exec_native.c"
NATIVE_PRODUCTION_OBJECT = OUT / "mtest_exec_native.o"
NATIVE_OBJECT = OUT / "mtest_exec_native_test.o"
TESTS = (
    ROOT / "tests" / "integration" / "test_exec_capture.mojo",
    ROOT / "tests" / "integration" / "test_exec_flood.mojo",
    ROOT / "tests" / "integration" / "test_exec_timeout.mojo",
    ROOT / "tests" / "integration" / "test_exec_interrupt.mojo",
    ROOT / "tests" / "integration" / "test_exec_etxtbsy.mojo",
    ROOT / "tests" / "integration" / "test_exec_reap.mojo",
    ROOT / "tests" / "integration" / "test_exec_fdhygiene.mojo",
)
ASAN_OPTIONS = "detect_leaks=1:halt_on_error=1:abort_on_error=1"
CONTROL_CASES = {
    "asan_oob_control": "heap-buffer-overflow",
    "asan_uaf_control": "heap-use-after-free",
    "asan_leak_control": "LeakSanitizer: detected memory leaks",
}


def run(
    command: list[str],
    *,
    env: dict[str, str] | None = None,
    timeout: int = 180,
) -> subprocess.CompletedProcess[str]:
    """Run one build or test command and capture its complete combined output."""
    return subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )


def require(condition: bool, message: str) -> None:
    """Fail the hard gate with one actionable diagnostic."""
    if not condition:
        raise SystemExit(f"asan-check: {message}")


def test_count(source: Path) -> int:
    """Count the TestSuite-discoverable top-level test functions in `source`."""
    return len(re.findall(r"(?m)^def test_[A-Za-z0-9_]+\(", source.read_text()))


def compile_native(cc: str) -> None:
    """Build the testing adapter and controls with matching ASan instrumentation."""
    flags = [
        "-std=c17",
        "-O1",
        "-g",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        "-fPIC",
        "-fvisibility=hidden",
        "-fno-omit-frame-pointer",
        "-fsanitize=address",
        "-DMTEST_EXEC_TESTING=1",
        "-I",
        str(ROOT / "native"),
    ]
    for testing, output in (
        (False, NATIVE_PRODUCTION_OBJECT),
        (True, NATIVE_OBJECT),
    ):
        variant_flags = [
            flag for flag in flags if not flag.startswith("-DMTEST_EXEC_TESTING=")
        ]
        variant_flags.append(f"-DMTEST_EXEC_TESTING={1 if testing else 0}")
        compiled = run(
            [cc, *variant_flags, "-c", str(NATIVE_SOURCE), "-o", str(output)]
        )
        require(
            compiled.returncode == 0,
            f"native compile failed for {output.name}:\n{compiled.stdout}",
        )
        symbols = run([os.environ.get("NM", "nm"), "-u", str(output)])
        require(symbols.returncode == 0, f"nm failed:\n{symbols.stdout}")
        require(
            "__asan_" in symbols.stdout,
            f"{output.name} is not ASan-instrumented",
        )


def check_cli(env: dict[str, str]) -> None:
    """Source-build and smoke-test the real CLI with ASan instrumentation."""
    binary = OUT / "mtest"
    compiled = run(
        [
            "mojo",
            "build",
            "--sanitize",
            "address",
            "-g",
            "-I",
            "src",
            "src/main.mojo",
            "-o",
            str(binary),
            "-Xlinker",
            str(NATIVE_PRODUCTION_OBJECT),
        ]
    )
    require(compiled.returncode == 0, f"ASan CLI build failed:\n{compiled.stdout}")
    symbols = run([os.environ.get("NM", "nm"), "-u", str(binary)])
    require(symbols.returncode == 0, f"nm failed for ASan CLI:\n{symbols.stdout}")
    require("__asan_" in symbols.stdout, "ASan CLI is not instrumented")
    executed = run([str(binary), "--help"], env=env)
    (OUT / "mtest-help.log").write_text(executed.stdout)
    require(executed.returncode == 0, f"ASan CLI smoke exited {executed.returncode}")
    require("usage: mtest" in executed.stdout, "ASan CLI smoke missed help output")
    print("asan-cli: --help: passed")


def check_controls(env: dict[str, str]) -> None:
    """Prove OOB, UAF, and leak findings make the harness fail closed."""
    for case, marker in CONTROL_CASES.items():
        source = ROOT / "tests" / "native" / f"{case}.mojo"
        binary = OUT / case
        compiled = run(
            [
                "mojo",
                "build",
                "--sanitize",
                "address",
                "-g",
                str(source.relative_to(ROOT)),
                "-o",
                str(binary),
                "-Xlinker",
                str(NATIVE_OBJECT),
            ]
        )
        require(
            compiled.returncode == 0,
            f"negative control {case} failed to build:\n{compiled.stdout}",
        )
        result = run([str(binary)], env=env, timeout=30)
        log = OUT / f"control-{case}.log"
        log.write_text(result.stdout)
        require(result.returncode != 0, f"negative control {case} returned success")
        require(marker in result.stdout, f"negative control {case} missed {marker!r}")
        require(
            "CONTROL RETURNED" not in result.stdout,
            f"negative control {case} continued after corruption",
        )
        print(f"asan-control: {case}: detected")


def compile_and_run_test(source: Path, env: dict[str, str]) -> None:
    """Build one Mojo suite from product sources and execute it directly."""
    binary = OUT / source.stem
    entrypoint = OUT / f"{source.stem}_main.mojo"
    aggregate_tests.write_entrypoint(ROOT, entrypoint, [source])
    compiled = run(
        [
            "mojo",
            "build",
            "--sanitize",
            "address",
            "-g",
            "-I",
            ".",
            "-I",
            "src",
            "-I",
            "tests/support",
            str(entrypoint),
            "-o",
            str(binary),
            "-Xlinker",
            str(NATIVE_OBJECT),
        ]
    )
    require(compiled.returncode == 0, f"build failed for {source.name}:\n{compiled.stdout}")
    symbols = run([os.environ.get("NM", "nm"), "-u", str(binary)])
    require(symbols.returncode == 0, f"nm failed for {source.name}:\n{symbols.stdout}")
    require("__asan_" in symbols.stdout, f"{source.name} is not ASan-instrumented")

    executed = run([str(binary)], env=env)
    (OUT / f"{source.stem}.log").write_text(executed.stdout)
    expected = test_count(source)
    sentinel = f"{expected} tests run: {expected} passed"
    require(
        executed.returncode == 0,
        f"{source.name} exited {executed.returncode}:\n{executed.stdout}",
    )
    require(sentinel in executed.stdout, f"{source.name} missed completion sentinel {sentinel!r}")
    require(
        "ERROR: AddressSanitizer" not in executed.stdout,
        f"{source.name} reported an ASan error",
    )
    require("LeakSanitizer: detected" not in executed.stdout, f"{source.name} reported a leak")
    print(f"asan-test: {source.name}: {expected}/{expected} passed")


def main() -> int:
    """Run live controls followed by the source-built exec risk subset."""
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    cc = native_abi_check.compiler()
    compile_native(cc)
    env = os.environ.copy()
    env["ASAN_OPTIONS"] = ASAN_OPTIONS
    env.pop("LSAN_OPTIONS", None)
    check_controls(env)
    check_cli(env)
    for source in TESTS:
        compile_and_run_test(source, env)
    (OUT / "summary.log").write_text(
        "ASan/LSan controls: OOB, UAF, leak detected\n"
        "ASan CLI smoke: passed\n"
        f"Source-built exec suites: {len(TESTS)}/{len(TESTS)} passed\n"
    )
    print(f"asan-check: OK -- {len(TESTS)} source-built exec suites")
    return 0


if __name__ == "__main__":
    sys.exit(main())
