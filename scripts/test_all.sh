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
python scripts/build_native.py

# Tests build against the prebuilt package at -O0: correctness tests do not need
# optimized codegen, and -O0 dodges the LLVM grind on TestSuite discovery glue.
# `-I tests/support` puts shared non-test helper modules on the import path; the
# walk only builds files matching test_*.mojo.
INCLUDE=(
    --no-optimization
    -I build
    -I tests/support
    -Xlinker build/native/mtest_exec_native_test.o
)

mkdir -p build/tests

failed=0
count=0
watchdog_timeout_args=()
# Test-only harness probes may lower this without changing the production
# ceiling. Ordinary invocations always omit it and retain the hard 300-second
# watchdog default.
if [[ -n "${MTEST_TEST_ALL_TIMEOUT_SECONDS:-}" ]]; then
    watchdog_timeout_args=(--timeout-seconds "$MTEST_TEST_ALL_TIMEOUT_SECONDS")
fi
# Python is already a locked build-time tool. It gives both GNU/Linux and macOS
# the same bytewise ordering and NUL-delimited path handling; the set removes a
# duplicate if a caller supplies overlapping roots.
while IFS= read -r -d '' test_file; do
    relative="${test_file#tests/}"
    bin="build/tests/${relative%.mojo}"
    mkdir -p "$(dirname "$bin")"
    build_deadline_sentinel="${bin}.build-deadline"
    run_deadline_sentinel="${bin}.run-deadline"
    echo "==> building $test_file -> $bin"
    rm -f "$build_deadline_sentinel"
    : > "$build_deadline_sentinel"
    set +e
    python scripts/process_watchdog.py \
        --source "$test_file" \
        --step build \
        --deadline-sentinel "$build_deadline_sentinel" \
        "${watchdog_timeout_args[@]}" \
        -- mojo build "${INCLUDE[@]}" "$test_file" -o "$bin"
    status=$?
    set -e
    if [[ -e "$build_deadline_sentinel" ]]; then
        if [[ "$status" -eq 124 ]]; then
            echo "FATAL: test_all: stopping after timed-out build for $test_file" >&2
            exit 124
        fi
        echo "FATAL: test_all: watchdog/internal failure during build for $test_file (exit $status); deadline sentinel remains" >&2
        exit 70
    fi
    if [[ "$status" -ne 0 ]]; then
        echo "FAILED: $test_file (build exit $status)" >&2
        failed=1
        count=$((count + 1))
        continue
    fi
    echo "==> running $bin"
    rm -f "$run_deadline_sentinel"
    : > "$run_deadline_sentinel"
    set +e
    python scripts/process_watchdog.py \
        --source "$test_file" \
        --step run \
        --deadline-sentinel "$run_deadline_sentinel" \
        "${watchdog_timeout_args[@]}" \
        -- "$bin"
    status=$?
    set -e
    if [[ -e "$run_deadline_sentinel" ]]; then
        if [[ "$status" -eq 124 ]]; then
            echo "FATAL: test_all: stopping after timed-out run for $test_file" >&2
            exit 124
        fi
        echo "FATAL: test_all: watchdog/internal failure during run for $test_file (exit $status); deadline sentinel remains" >&2
        exit 70
    fi
    if [[ "$status" -ne 0 ]]; then
        echo "FAILED: $test_file (run exit $status)" >&2
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
