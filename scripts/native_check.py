#!/usr/bin/env python3
"""Build and run the native exec adapter's normal lifecycle tests."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

from scripts import native_abi_check


ROOT = Path(__file__).resolve().parent.parent
NATIVE_SOURCE = ROOT / "native" / "mtest_exec_native.c"
TEST_SOURCES = (
    ROOT / "tests" / "native" / "test_exec_native.c",
    ROOT / "tests" / "native" / "test_exec_native_signals.c",
)


def link_command(
    cc: str,
    objects: tuple[Path, ...],
    output: Path,
    *,
    platform: str = sys.platform,
) -> list[str]:
    """Return the platform link command for precompiled native test objects.

    The pinned conda-forge Clang 18 Darwin driver names a versioned libLTO
    file that newer Apple linkers reject. Compilation remains pinned; only the
    final object-file link uses Apple's platform driver.
    """
    linker = "/usr/bin/cc" if platform == "darwin" else cc
    return [linker, *(str(path) for path in objects), "-o", str(output)]


def main() -> int:
    """Run ABI verification, then strict native lifecycle executables."""
    native_abi_check.main()
    cc = native_abi_check.compiler()
    with tempfile.TemporaryDirectory(prefix="mtest-native-check-") as raw_tmp:
        tmp = Path(raw_tmp)
        adapter = tmp / "mtest_exec_native_test.o"
        adapter_command = [
            cc,
            *native_abi_check.STRICT_FLAGS,
            "-DMTEST_EXEC_TESTING=1",
            "-I",
            str(ROOT / "native"),
            "-c",
            str(NATIVE_SOURCE),
            "-o",
            str(adapter),
        ]
        compiled_adapter = subprocess.run(
            adapter_command,
            cwd=ROOT,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if compiled_adapter.returncode != 0:
            raise SystemExit(
                "native-check: compile failed for native/mtest_exec_native.c:\n"
                + compiled_adapter.stdout
            )
        for source in TEST_SOURCES:
            output = tmp / source.stem
            test_object = tmp / f"{source.stem}.o"
            command = [
                cc,
                *native_abi_check.STRICT_FLAGS,
                "-DMTEST_EXEC_TESTING=1",
                "-I",
                str(ROOT / "native"),
                "-c",
                str(source),
                "-o",
                str(test_object),
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
            linked = subprocess.run(
                link_command(cc, (adapter, test_object), output),
                cwd=ROOT,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            if linked.returncode != 0:
                raise SystemExit(
                    f"native-check: link failed for {source.relative_to(ROOT)}:\n"
                    + linked.stdout
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
