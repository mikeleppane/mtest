#!/usr/bin/env python3
"""Build and run the native exec adapter's normal lifecycle tests."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
from typing import TYPE_CHECKING

from scripts.checks import native_abi as native_abi_check
from scripts.checks.native_sources import tracked_native_sources


if TYPE_CHECKING:
    from scripts.build.profiles import ProductionProfile


ROOT = Path(__file__).resolve().parents[2]
NATIVE_SOURCES = tracked_native_sources(ROOT)
_TEST_SOURCE_NAMES = (
    "tests/native/test_exec_native.c",
    "tests/native/test_exec_native_signals.c",
)
TEST_SOURCES = tuple(
    source
    for source in NATIVE_SOURCES
    if source.relative_to(ROOT).as_posix() in _TEST_SOURCE_NAMES
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


def test_compile_command(
    cc: str,
    source: Path,
    output: Path,
    profile: ProductionProfile,
) -> list[str]:
    """Return one strict native lifecycle-test compile command."""
    return [
        cc,
        *native_abi_check.STRICT_FLAGS,
        *profile.c_flags,
        "-DMTEST_EXEC_TESTING=1",
        "-I",
        str(ROOT / "native"),
        "-c",
        str(source),
        "-o",
        str(output),
    ]


def main() -> int:
    """Run ABI verification, then strict native lifecycle executables."""
    if not TEST_SOURCES:
        raise SystemExit("native-check: source inventory is empty")
    native_abi_check.main()
    cc = native_abi_check.compiler()
    profile = native_abi_check.current_profile()
    with tempfile.TemporaryDirectory(prefix="mtest-native-check-") as raw_tmp:
        tmp = Path(raw_tmp)
        adapter = native_abi_check.TESTING_OBJECT
        for source in TEST_SOURCES:
            output = tmp / source.stem
            test_object = tmp / f"{source.stem}.o"
            command = test_compile_command(
                cc,
                source,
                test_object,
                profile,
            )
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
