#!/usr/bin/env python3
"""Build authoritative production and testing native adapter objects."""

from __future__ import annotations

from pathlib import Path
import platform
import subprocess
import sys

from scripts.build.profiles import ProductionProfile, host_profile, load_profiles
from scripts.checks import native_abi as native_abi_check


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = native_abi_check.PRODUCTION_OBJECT
TEST_OUTPUT = native_abi_check.TESTING_OBJECT


def testing_compile_command(
    cc: str,
    profile: ProductionProfile,
) -> list[str]:
    """Return the testing-object command without ambient compiler flags."""
    return native_abi_check.variant_compile_command(
        cc,
        TEST_OUTPUT,
        testing=True,
        profile=profile,
    )


def main() -> int:
    """Stage production through Bash and compile the testing-only variant."""
    profile = host_profile(
        system=platform.system(),
        machine=platform.machine(),
        profiles=load_profiles(),
    )
    subprocess.run(
        ["bash", "scripts/build/production_build.sh", "native"],
        cwd=ROOT,
        check=True,
    )
    cc = native_abi_check.compiler()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    native_abi_check.compile_variant(
        cc,
        TEST_OUTPUT,
        testing=True,
        profile=profile,
    )
    symbols = native_abi_check.defined_symbols(OUTPUT)
    native_abi_check.require(
        symbols == native_abi_check.PRODUCTION_SYMBOLS,
        "production build exported an unexpected symbol set",
    )
    test_symbols = native_abi_check.defined_symbols(TEST_OUTPUT)
    native_abi_check.require(
        test_symbols
        == native_abi_check.PRODUCTION_SYMBOLS | native_abi_check.TEST_ONLY_SYMBOLS,
        "testing build exported an unexpected symbol set",
    )
    print(
        "build-native: OK -- "
        f"{OUTPUT.relative_to(ROOT)} + {TEST_OUTPUT.relative_to(ROOT)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
