#!/usr/bin/env bash
# Run every Mojo test in tests/ against a PRECOMPILED mtest package.
#
# This runner practices the exact discipline the mtest product enforces: for
# each test file, BUILD a binary and EXECUTE it directly. `mojo run` is banned
# from the gate — it masks a crashing process's exit code to 1 (so a crash is
# indistinguishable from a failure) and can itself JIT-crash in CI (Mojo #6413).
# Building and running the binary is the only way the process exit code is
# truthful, which is the whole point of the tool.
#
# Ordering: the package build runs first (fail-fast on a broken toolchain or a
# package that no longer compiles), then a sorted glob loop so new tests are
# picked up automatically — no hand-maintained list to drift.
#
# NOTE: mojo 1.0.0b2 has a #6554-class TestSuite compile stall that grows with a
# module's function count. Keep test modules small; no current test trips it.
#
# Usage:  pixi run test
#         bash scripts/test_all.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# Build the package first — the compile gate for src/mtest.
bash scripts/build_pkg.sh

# Tests build against the prebuilt package at -O0: correctness tests do not need
# optimized codegen, and -O0 dodges the LLVM grind on TestSuite discovery glue.
# `-I tests` puts shared non-test helper modules on the import path; the glob
# only builds files matching test_*.mojo.
INCLUDE=(--no-optimization -I build -I tests)

mkdir -p build/tests

shopt -s nullglob
failed=0
# Bash expands globs in sorted order, so this iterates deterministically and is
# safe for paths with spaces (no word-splitting via $()).
for test_file in tests/test_*.mojo; do
    name="$(basename "${test_file%.mojo}")"
    bin="build/tests/$name"
    echo "==> building $test_file -> $bin"
    mojo build "${INCLUDE[@]}" "$test_file" -o "$bin"
    echo "==> running $bin"
    if ! "$bin"; then
        echo "FAILED: $test_file" >&2
        failed=1
    fi
done

if [[ "$failed" -ne 0 ]]; then
    echo "Some tests failed." >&2
    exit 1
fi

echo "All tests passed."
