#!/usr/bin/env python3
"""Build and exercise the real CLI main under test-only runtime-open faults."""

from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from scripts.checks import native_abi as native_abi_check


ROOT = Path(__file__).resolve().parent.parent
HELPER_SOURCE = ROOT / "tests" / "native" / "main_open_fault.c"
TEST_ADAPTER = ROOT / "build" / "native" / "mtest_exec_native_test.o"
MAIN_SOURCE = ROOT / "src" / "main.mojo"
BUILD_TIMEOUT = 120.0
RUN_TIMEOUT = 30.0


class MainOpenCheckError(RuntimeError):
    """A build or behavioral failure in the instrumented real-main check."""


def _run(command: list[str], *, timeout: float) -> subprocess.CompletedProcess[str]:
    """Run one hard-timeout-guarded command from the repository root."""
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        for signal_number in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, signal_number)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        stdout, stderr = process.communicate()
        raise MainOpenCheckError(
            f"command timed out after {timeout:.0f}s: {command}\n"
            + stdout
            + stderr
        ) from error
    return subprocess.CompletedProcess(
        command,
        process.returncode,
        stdout,
        stderr,
    )


def check_main_open_failure() -> str:
    """Prove real main reports and explicitly repairs a failed runtime open."""
    if not TEST_ADAPTER.is_file():
        raise MainOpenCheckError(
            f"missing {TEST_ADAPTER.relative_to(ROOT)}; run `pixi run build-native`"
        )
    cc = native_abi_check.compiler()
    with tempfile.TemporaryDirectory(prefix="mtest-main-open-") as raw_tmp:
        tmp = Path(raw_tmp)
        helper = tmp / "main_open_fault.o"
        binary = tmp / "mtest-main-open"
        compiled_helper = _run(
            [
                cc,
                *native_abi_check.STRICT_FLAGS,
                "-I",
                str(ROOT / "native"),
                "-c",
                str(HELPER_SOURCE),
                "-o",
                str(helper),
            ],
            timeout=BUILD_TIMEOUT,
        )
        if compiled_helper.returncode != 0:
            raise MainOpenCheckError(
                "helper compile failed:\n"
                + compiled_helper.stdout
                + compiled_helper.stderr
            )
        built_main = _run(
            [
                "mojo",
                "build",
                "-I",
                "build",
                str(MAIN_SOURCE),
                "-o",
                str(binary),
                "-Xlinker",
                str(TEST_ADAPTER),
                "-Xlinker",
                str(helper),
            ],
            timeout=BUILD_TIMEOUT,
        )
        if built_main.returncode != 0:
            raise MainOpenCheckError(
                "instrumented main build failed:\n"
                + built_main.stdout
                + built_main.stderr
            )
        run = _run([str(binary)], timeout=RUN_TIMEOUT)

    if run.returncode != 3:
        raise MainOpenCheckError(
            f"expected real main exit 3, got {run.returncode}:\n{run.stderr}"
        )
    primary = "exec: runtime open failed (operation 5, errno 5)"
    rollback = "cleanup operation 6 failed with errno 1"
    repair = "exec: runtime close failed (operation 6, errno 5)"
    marker = (
        "main-open-probe: restore-attempts-before-atexit=3 "
        "initial-reopen=0 repair=-2 final-reopen=0 reclose=0"
    )
    positions = [run.stderr.find(part) for part in (primary, rollback, repair)]
    if not (positions[0] >= 0 and positions[0] < positions[1] < positions[2]):
        raise MainOpenCheckError(
            "real main did not preserve primary -> rollback -> repair error "
            f"ordering:\n{run.stderr}"
        )
    if marker not in run.stderr:
        raise MainOpenCheckError(
            "real main did not attempt explicit repair before atexit retry:\n"
            + run.stderr
        )
    return (
        "real src/main.mojo exit 3; primary/rollback/repair order exact; "
        "explicit close observed and post-cleanup reopen lifecycle proven"
    )


def main() -> int:
    """Run the focused check and print one success line."""
    try:
        detail = check_main_open_failure()
    except MainOpenCheckError as error:
        print(f"main-open-check: FAILED: {error}", file=sys.stderr)
        return 1
    print(f"main-open-check: OK -- {detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
