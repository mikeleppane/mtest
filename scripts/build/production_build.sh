#!/usr/bin/env bash
# The single production-build authority: precompile + production native object +
# link, producing the shipped build/mtest artifact from exactly ONE definition.
#
# Runnable with only bash + mojo + clang -- NO Python, no other tooling -- so it
# runs identically in a developer checkout (invoked by the pixi build tasks) and
# inside rattler-build's ISOLATED recipe environment, whose requirements.build is
# only `mojo ==1.0.0b2` and `clang ==18.1.8` (recipe/build.sh calls this script).
# Before this entrypoint existed the recipe hand-repeated all three stages with
# the C flags hardcoded inline, so the tested artifact and the published one
# could silently diverge; this removes that drift.
#
# Source-relative: it locates the repository from its own path (BASH_SOURCE),
# never from a pixi-provided variable, so the same invocation works in both
# environments regardless of the caller's working directory.
#
# The production C flags come from the shared inventory native_strict_flags.txt,
# the same file scripts/checks/native_abi.py reads for its symbol verification --
# the flags are defined in exactly one place.
#
# NOTE: mojo 1.0.0b2 has no `mojo package` subcommand -- only `mojo precompile`,
# which produces the same .mojopkg. The output is named mtest.mojopkg so
# `-I build` resolves `from mtest import ...`.
#
# Usage:  production_build.sh [precompile|native|link|all]   (default: all)
# The test-only native variant and its symbol verification are dev/CI artifacts
# and deliberately live in scripts/build/native.py + scripts/checks/native_abi.py,
# NOT here: the published build compiles only the production variant.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
flags_file="$here/native_strict_flags.txt"
cd "$repo_root"

read_strict_flags() {
  STRICT_FLAGS=()
  local line trimmed
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]] && continue
    STRICT_FLAGS+=("$trimmed")
  done <"$flags_file"
  if [[ ${#STRICT_FLAGS[@]} -eq 0 ]]; then
    echo "production-build: strict flag inventory is empty: $flags_file" >&2
    exit 1
  fi
}

stage_precompile() {
  mkdir -p build
  echo "==> precompiling src/mtest -> build/mtest.mojopkg"
  mojo precompile src/mtest -o build/mtest.mojopkg
}

stage_native() {
  read_strict_flags
  mkdir -p build/native
  echo "==> compiling native/mtest_exec_native.c -> build/native/mtest_exec_native.o"
  clang \
    "${STRICT_FLAGS[@]}" \
    -DMTEST_EXEC_TESTING=0 \
    -I native \
    -c native/mtest_exec_native.c \
    -o build/native/mtest_exec_native.o
}

stage_link() {
  echo "==> linking build/mtest"
  mojo build -I build src/main.mojo -o build/mtest \
    -Xlinker build/native/mtest_exec_native.o
}

stage="${1:-all}"
case "$stage" in
  precompile) stage_precompile ;;
  native) stage_native ;;
  link) stage_link ;;
  all)
    stage_precompile
    stage_native
    stage_link
    ;;
  *)
    echo "production-build: unknown stage '$stage' (want precompile|native|link|all)" >&2
    exit 2
    ;;
esac
