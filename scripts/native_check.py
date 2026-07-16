#!/usr/bin/env python3
"""Build and run the native exec adapter's normal lifecycle tests."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

import native_abi_check


ROOT = Path(__file__).resolve().parent.parent
NATIVE_SOURCE = ROOT / "native" / "mtest_exec_native.c"
TEST_SOURCES = (
    ROOT / "tests" / "native" / "test_exec_native.c",
    ROOT / "tests" / "native" / "test_exec_native_signals.c",
)


def main() -> int:
    """Run ABI verification, then strict native lifecycle executables."""
    native_abi_check.main()
    cc = native_abi_check.compiler()
    with tempfile.TemporaryDirectory(prefix="mtest-native-check-") as raw_tmp:
        tmp = Path(raw_tmp)
        for source in TEST_SOURCES:
            output = tmp / source.stem
            command = [
                cc,
                *native_abi_check.STRICT_FLAGS,
                "-DMTEST_EXEC_TESTING=1",
                "-I",
                str(ROOT / "native"),
                str(NATIVE_SOURCE),
                str(source),
                "-o",
                str(output),
            ]
            compiled = subprocess.run(
                command,
                cwd=ROOT,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            if compiled.returncode != 0:
                raise SystemExit(
                    f"native-check: compile failed for {source.relative_to(ROOT)}:\n"
                    + compiled.stdout
                )
            executed = subprocess.run(
                [str(output)],
                cwd=ROOT,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=20,
            )
            if executed.returncode != 0:
                raise SystemExit(
                    f"native-check: {source.relative_to(ROOT)} exited "
                    f"{executed.returncode}:\n{executed.stdout}"
                )
            print(executed.stdout, end="")
    print("native-check: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
