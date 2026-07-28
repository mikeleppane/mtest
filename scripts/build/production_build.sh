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
# which produces the same .mojopkg. The vendored parser is precompiled first;
# then `-I build` resolves it while precompiling mtest and resolves both
# packages while linking main.
#
# Usage:  production_build.sh [precompile|native|link|all]   (default: all)
# The test-only native variant and its symbol verification are dev/CI artifacts
# and deliberately live in scripts/build/native.py + scripts/checks/native_abi.py,
# NOT here: the published build compiles only the production variant.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
flags_file="$here/native_strict_flags.txt"
script_self="$here/$(basename "${BASH_SOURCE[0]}")"
cd "$repo_root"

# The exact two argv vectors stage_precompile runs, held as arrays (not a
# string) so they can be both EXECUTED and RENDERED into the input digest
# below from one definition -- a hand-duplicated command line in the digest
# input could drift from the one actually run and never be noticed.
PRECOMPILE_CMD_TOML=(mojo precompile vendor/mojo-toml/toml -o build/toml.mojopkg)
PRECOMPILE_CMD_MTEST=(mojo precompile -I build src/mtest -o build/mtest.mojopkg)

# The precompile stage's stamp: proves nothing feeding `mojo precompile`
# changed since the last successful run, so a second `pixi run build` can skip
# it entirely. `mojo precompile` is NOT byte-reproducible on this toolchain
# (two identical inputs measured at 43fcef41... and eb81d1f7... on this
# branch), so re-running the stage on unchanged inputs would rewrite the
# .mojopkg with different bytes for no reason -- the stamp is what makes a
# second build a no-op instead of a fresh, differently-byte-identical one.
PRECOMPILE_STAMP="build/.precompile.stamp"

# Populated by _resolve_digest_cmd: the digest command as an argv array
# (`sha256sum` is one word, `shasum -a 256` is three), empty when neither
# tool is on PATH.
DIGEST_CMD=()

_resolve_digest_cmd() {
  DIGEST_CMD=()
  if command -v sha256sum >/dev/null 2>&1; then
    DIGEST_CMD=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    DIGEST_CMD=(shasum -a 256)
  fi
}

# Reads one digest command's own output ("<hex>  <name>") from stdin and
# prints just the hex field. Works for both a single-file invocation and a
# stdin ("-") invocation; the format is identical.
_first_field() {
  local line
  IFS= read -r line || return 1
  printf '%s\n' "${line%% *}"
}

_hash_file() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  "${DIGEST_CMD[@]}" -- "$path" | _first_field
}

_hash_stdin() {
  "${DIGEST_CMD[@]}" | _first_field
}

# The precompile stage's input digest: the script itself (so an edit to the
# stamping logic or the compile commands invalidates every stamp), the exact
# stage command lines (so a flag change invalidates it even though no source
# file moved), and every file under the two source trees the stage reads.
# The file list goes through `find -print0 | LC_ALL=C sort -z | xargs -0` so
# the digest is stable regardless of filesystem iteration order --
# `test_source_order_permutation_stable` pins exactly this.
#
# Assumes `_resolve_digest_cmd` has already populated `DIGEST_CMD` in the
# CALLING shell (never inside this function): command substitution runs in a
# subshell, so a `_resolve_digest_cmd` call made only here would set `DIGEST_CMD`
# in a subshell that vanishes the instant `$(_precompile_input_digest)`
# returns, leaving the caller's own `DIGEST_CMD` empty for every call after.
_precompile_input_digest() {
  {
    cat -- "$script_self"
    printf 'cmd:%s\n' "${PRECOMPILE_CMD_TOML[*]}"
    printf 'cmd:%s\n' "${PRECOMPILE_CMD_MTEST[*]}"
    find src/mtest vendor/mojo-toml -type f -print0 |
      LC_ALL=C sort -z |
      xargs -0 "${DIGEST_CMD[@]}" --
  } | _hash_stdin
}

# A stamp is valid only if its head line is `in:<the current input digest>`
# AND exactly the two expected `out:` rows are present below it, each one's
# recorded digest matching that file's CURRENT content digest. `out_ok` must
# land on exactly 2: a missing output, a duplicated row, or an unrecognized
# row (an extra/renamed output) all count as a miss, never a superset pass.
#
# Tracks the two known rows with plain flags rather than an associative array
# on purpose: macOS ships bash 3.2 as `/bin/bash` (no `local -A` support), and
# this script's own shebang invokes whatever `bash` resolves first on PATH.
_precompile_stamp_valid() {
  local stamp="$1" expected_digest="$2"
  [[ -f "$stamp" ]] || return 1

  local head
  IFS= read -r head <"$stamp" || return 1
  [[ "$head" == "in:$expected_digest" ]] || return 1

  local out_ok=0
  local seen_toml=0 seen_mtest=0
  local first=1
  local line rest path recorded actual
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $first -eq 1 ]]; then
      first=0
      continue
    fi
    case "$line" in
      out:*)
        rest="${line#out:}"
        path="${rest%% *}"
        recorded="${rest#* }"
        case "$path" in
          build/toml.mojopkg)
            [[ $seen_toml -eq 0 ]] || return 1 # duplicate out row
            seen_toml=1
            ;;
          build/mtest.mojopkg)
            [[ $seen_mtest -eq 0 ]] || return 1 # duplicate out row
            seen_mtest=1
            ;;
          *)
            return 1 # unknown out row
            ;;
        esac
        actual="$(_hash_file "$path")" || return 1 # output missing/unreadable
        [[ "$actual" == "$recorded" ]] || return 1
        out_ok=$((out_ok + 1))
        ;;
      *)
        return 1 # any row that isn't a recognized `out:` row
        ;;
    esac
  done <"$stamp"

  [[ $out_ok -eq 2 ]]
}

_precompile_write_stamp() {
  local stamp="$1" input_digest="$2"
  local h_toml h_mtest
  h_toml="$(_hash_file build/toml.mojopkg)" || return 1
  h_mtest="$(_hash_file build/mtest.mojopkg)" || return 1
  {
    printf 'in:%s\n' "$input_digest"
    printf 'out:build/toml.mojopkg %s\n' "$h_toml"
    printf 'out:build/mtest.mojopkg %s\n' "$h_mtest"
  } >"$stamp"
}

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
  _resolve_digest_cmd
  local input_digest=""
  if [[ ${#DIGEST_CMD[@]} -gt 0 ]]; then
    input_digest="$(_precompile_input_digest)"
    if _precompile_stamp_valid "$PRECOMPILE_STAMP" "$input_digest"; then
      echo "==> precompile stage skipped (stamp matches build/toml.mojopkg, build/mtest.mojopkg)"
      return 0
    fi
  else
    echo "production-build: no sha256sum or shasum on PATH -- skipping the precompile stamp, building unconditionally" >&2
  fi

  echo "==> precompiling vendor/mojo-toml/toml -> build/toml.mojopkg"
  "${PRECOMPILE_CMD_TOML[@]}"
  echo "==> precompiling src/mtest -> build/mtest.mojopkg"
  "${PRECOMPILE_CMD_MTEST[@]}"

  if [[ -n "$input_digest" ]]; then
    _precompile_write_stamp "$PRECOMPILE_STAMP" "$input_digest"
  fi
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

# Guarded so `test_source_order_permutation_stable` (and any other test) can
# `source` this file to call `_precompile_input_digest` and friends directly
# against a sandboxed tree without also triggering a real build: when sourced,
# `$0` is the sourcing shell, never this file's own path, so the dispatch
# below is skipped. Normal invocation (`bash production_build.sh precompile`)
# is unaffected -- there `$0` and `${BASH_SOURCE[0]}` are the same path.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
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
fi
