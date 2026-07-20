#!/usr/bin/env bash
# Build every selected Mojo test module into ONE aggregate executable, then run
# that binary directly. `mojo run` is forbidden because it masks crash status.
#
# Usage:  pixi run test-direct
#         pixi run test-file tests/unit/test_model_outcome.mojo
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$#" -eq 0 ]]; then
    roots=(tests/unit tests/integration)
else
    roots=("$@")
fi

# Keep the accepted surface narrow so a typo cannot turn this into an arbitrary
# repository walk. The generator repeats this validation before reading files.
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
    if [[ ! -e "$root" || -L "$root" ]]; then
        echo "FATAL: test_all: suite root is not a real file or directory: $root" >&2
        exit 2
    fi
    normalized_roots+=("$root")
done

bash scripts/build_pkg.sh
python -m scripts.build_native

mkdir -p build/tests
aggregate_source=build/tests/aggregate_main.mojo
aggregate_binary=build/tests/aggregate
python -m scripts.aggregate_tests \
    --output "$aggregate_source" "${normalized_roots[@]}"

include=(
    --no-optimization
    -I .
    -I build
    -I tests/support
    -Xlinker build/native/mtest_exec_native_test.o
)

watchdog_command=(python -m scripts.process_watchdog)
if [[ -n "${MTEST_TEST_ALL_TIMEOUT_SECONDS:-}" ]]; then
    watchdog_command=(
        python -m scripts.process_watchdog
        --timeout-seconds "$MTEST_TEST_ALL_TIMEOUT_SECONDS"
    )
fi

run_step() {
    local step="$1"
    shift
    local sentinel="build/tests/aggregate.${step}-deadline"
    rm -f "$sentinel"
    : > "$sentinel"
    set +e
    "${watchdog_command[@]}" \
        --source "aggregate suite" \
        --step "$step" \
        --deadline-sentinel "$sentinel" \
        -- "$@"
    local status=$?
    set -e
    if [[ -e "$sentinel" ]]; then
        if [[ "$status" -eq 124 ]]; then
            echo "FATAL: test_all: stopping after timed-out aggregate $step" >&2
            exit 124
        fi
        echo "FATAL: test_all: watchdog/internal failure during aggregate $step (exit $status); deadline sentinel remains" >&2
        exit 70
    fi
    if [[ "$status" -ne 0 ]]; then
        echo "FAILED: aggregate suite ($step exit $status)" >&2
        exit 1
    fi
}

echo "==> building aggregate test binary -> $aggregate_binary"
run_step build mojo build "${include[@]}" "$aggregate_source" -o "$aggregate_binary"

echo "==> running aggregate test binary"
run_step run "$aggregate_binary"

echo "All aggregate test modules passed."
