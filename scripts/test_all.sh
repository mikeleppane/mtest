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
# package that no longer compiles), then a sorted recursive walk so new tests are
# picked up automatically — no hand-maintained list to drift.
#
# NOTE: mojo 1.0.0b2 has a #6554-class TestSuite compile stall that grows with a
# module's function count. Keep test modules small; no current test trips it.
#
# Usage:  pixi run test-direct
#         bash scripts/test_all.sh [SUITE_ROOT ...]
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$#" -eq 0 ]]; then
    roots=(tests)
else
    roots=("$@")
fi

# Suite roots are repository-relative directories beneath tests/. Keeping the
# accepted surface narrow makes output paths injective and prevents a typo from
# turning the direct gate into an arbitrary repository walk.
normalized_roots=()
for root in "${roots[@]}"; do
    while [[ "$root" == ./* ]]; do
        root="${root#./}"
    done
    root="${root%/}"
    if [[ -z "$root" || "$root" == /* || "$root" == "tests"/../* || \
        "$root" == ../* || "$root" == *"/../"* || "$root" == *"/.." ]]; then
        echo "FATAL: test_all: unsafe suite root: ${root:-<empty>}" >&2
        exit 2
    fi
    if [[ "$root" != "tests" && "$root" != tests/* ]]; then
        echo "FATAL: test_all: suite root must be tests/ or below: $root" >&2
        exit 2
    fi
    if [[ ! -d "$root" || -L "$root" ]]; then
        echo "FATAL: test_all: suite root is not a real directory: $root" >&2
        exit 2
    fi
    normalized_roots+=("$root")
done

# Build the package first — the compile gate for src/mtest.
bash scripts/build_pkg.sh

# Tests build against the prebuilt package at -O0: correctness tests do not need
# optimized codegen, and -O0 dodges the LLVM grind on TestSuite discovery glue.
# `-I tests` puts shared non-test helper modules on the import path; the walk
# only builds files matching test_*.mojo.
INCLUDE=(--no-optimization -I build -I tests)

mkdir -p build/tests

failed=0
count=0
# Python is already a locked build-time tool. It gives both GNU/Linux and macOS
# the same bytewise ordering and NUL-delimited path handling; the set removes a
# duplicate if a caller supplies overlapping roots.
while IFS= read -r -d '' test_file; do
    relative="${test_file#tests/}"
    bin="build/tests/${relative%.mojo}"
    mkdir -p "$(dirname "$bin")"
    echo "==> building $test_file -> $bin"
    mojo build "${INCLUDE[@]}" "$test_file" -o "$bin"
    echo "==> running $bin"
    set +e
    "$bin"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        echo "FAILED: $test_file (exit $status)" >&2
        failed=1
    fi
    count=$((count + 1))
done < <(
    python -c '
import os
import sys

found = set()
for root in sys.argv[1:]:
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(
            name
            for name in dirnames
            if not os.path.islink(os.path.join(dirpath, name))
        )
        for name in filenames:
            if name.startswith("test_") and name.endswith(".mojo"):
                found.add(os.path.join(dirpath, name))
for path in sorted(found, key=os.fsencode):
    sys.stdout.buffer.write(os.fsencode(path) + b"\0")
' "${normalized_roots[@]}"
)

if [[ "$count" -eq 0 ]]; then
    echo "FATAL: test_all: no test_*.mojo suites under: ${normalized_roots[*]}" >&2
    exit 1
fi

if [[ "$failed" -ne 0 ]]; then
    echo "Some tests failed." >&2
    exit 1
fi

echo "All tests passed."
