#!/usr/bin/env python3
"""Build the production native exec adapter object with the pinned compiler."""

from __future__ import annotations

from pathlib import Path
import sys

import native_abi_check


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "build" / "native" / "mtest_exec_native.o"
TEST_OUTPUT = ROOT / "build" / "native" / "mtest_exec_native_test.o"


def main() -> int:
    """Compile the strict production-only object consumed by Mojo link steps."""
    cc = native_abi_check.compiler()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    native_abi_check.compile_variant(cc, OUTPUT, testing=False)
    native_abi_check.compile_variant(cc, TEST_OUTPUT, testing=True)
    symbols = native_abi_check.defined_symbols(OUTPUT)
    native_abi_check.require(
        symbols == native_abi_check.PRODUCTION_SYMBOLS,
        "production build exported an unexpected symbol set",
    )
    test_symbols = native_abi_check.defined_symbols(TEST_OUTPUT)
    native_abi_check.require(
        test_symbols
        == native_abi_check.PRODUCTION_SYMBOLS
        | native_abi_check.TEST_ONLY_SYMBOLS,
        "testing build exported an unexpected symbol set",
    )
    print(
        "build-native: OK -- "
        f"{OUTPUT.relative_to(ROOT)} + {TEST_OUTPUT.relative_to(ROOT)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
