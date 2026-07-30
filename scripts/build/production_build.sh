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
# which produces a compiled package. Checkout-owned artifacts use the supported
# .mojoc extension; the vendored parser is precompiled first, then `-I build`
# resolves it while precompiling mtest and resolves both packages while linking
# main.
#
# Usage:  production_build.sh [precompile|native|link|all]   (default: all)
# The test-only native variant and its symbol verification are dev/CI artifacts
# and deliberately live in scripts/build/native.py + scripts/checks/native_abi.py,
# NOT here: the published build compiles only the production variant.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
flags_file="$here/native_strict_flags.txt"
profiles_file="${profiles_file:-$here/production_profiles.txt}"
script_self="$here/$(basename "${BASH_SOURCE[0]}")"
cd "$repo_root"

# The exact two argv vectors stage_precompile runs, held as arrays (not a
# string) so they can be both EXECUTED and RENDERED into the input digest
# below from one definition -- a hand-duplicated command line in the digest
# input could drift from the one actually run and never be noticed.
PRECOMPILE_CMD_TOML=(
  mojo precompile --Werror vendor/mojo-toml/toml -o build/toml.mojoc
)
PRECOMPILE_CMD_MTEST=(
  mojo precompile --Werror -I build src/mtest -o build/mtest.mojoc
)

# The precompile stage's stamp: proves nothing feeding `mojo precompile`
# changed since the last successful run, so a second `pixi run build` can skip
# it entirely. `mojo precompile` is NOT byte-reproducible on this toolchain
# (two identical inputs measured at 43fcef41... and eb81d1f7... on this
# branch), so re-running the stage on unchanged inputs would rewrite the
# .mojoc with different bytes for no reason -- the stamp is what makes a
# second build a no-op instead of a fresh, differently-byte-identical one.
PRECOMPILE_STAMP="build/.precompile.stamp"

# What actually pins the toolchain in this repo: `pixi.lock` resolves the
# exact `mojo` build, and `mojo --version` reports what is ACTUALLY on PATH
# right now (a relock without a version bump still changes the lockfile; a
# version bump changes the `--version` line). Both feed the input digest, so
# a toolchain swap invalidates a stamp that no tracked source file's content
# would otherwise touch -- the same hazard Layer 1's file cache already
# guards against by digesting the compiler binary's own content into every
# key. Skipping either one would leave `pixi run build` able to ship a
# `build/mtest.mojoc` compiled by a DIFFERENT compiler than the one the
# stamp was written under, while reporting a match.
PIXI_LOCK_REL="pixi.lock"

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
# file moved), the toolchain identity ($1: a `mojo --version` line, plus
# `pixi.lock`'s bytes if it exists -- a relock without a version bump still
# changes the lockfile), and every file under the two source trees the stage
# reads. The file list goes through `find -print0 | LC_ALL=C sort -z |
# xargs -0` so the digest is stable regardless of filesystem iteration order
# -- `test_source_order_permutation_stable` pins exactly this.
#
# Assumes `_resolve_digest_cmd` has already populated `DIGEST_CMD` in the
# CALLING shell (never inside this function): command substitution runs in a
# subshell, so a `_resolve_digest_cmd` call made only here would set `DIGEST_CMD`
# in a subshell that vanishes the instant `$(_precompile_input_digest)`
# returns, leaving the caller's own `DIGEST_CMD` empty for every call after.
_precompile_input_digest() {
  local mojo_version="$1"
  {
    cat -- "$script_self"
    printf 'cmd:%s\n' "${PRECOMPILE_CMD_TOML[*]}"
    printf 'cmd:%s\n' "${PRECOMPILE_CMD_MTEST[*]}"
    printf 'toolchain:%s\n' "$mojo_version"
    if [[ -f "$PIXI_LOCK_REL" ]]; then
      cat -- "$PIXI_LOCK_REL"
    fi
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
          build/toml.mojoc)
            [[ $seen_toml -eq 0 ]] || return 1 # duplicate out row
            seen_toml=1
            ;;
          build/mtest.mojoc)
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
  h_toml="$(_hash_file build/toml.mojoc)" || return 1
  h_mtest="$(_hash_file build/mtest.mojoc)" || return 1
  {
    printf 'in:%s\n' "$input_digest"
    printf 'out:build/toml.mojoc %s\n' "$h_toml"
    printf 'out:build/mtest.mojoc %s\n' "$h_mtest"
  } >"$stamp"
}

# Copies the stamp completely into a private file before inspecting it. `cat`'s
# checked status proves the original read reached EOF, and the checked
# `tr | cmp` pipeline rejects any NUL before bytes enter a Bash variable (whose
# command substitution would otherwise discard NUL). Only then is the private
# snapshot emitted for parsing.
#
# The subshell-local EXIT trap covers every branch after `mktemp`, including a
# signal or a failed explicit removal. `mktemp`, `tr`, and `cmp` are system
# utilities on both supported hosts; this keeps the recipe free of Python and
# new package dependencies.
_capture_complete_stamp() (
  local source="$1"
  local snapshot=""
  local capture_status=1
  snapshot="$(mktemp "${TMPDIR:-/tmp}/mtest-legacy-stamp.XXXXXX")" || return 1
  trap 'rm -f -- "$snapshot"' EXIT
  trap 'exit 1' HUP INT TERM

  if cat -- "$source" >"$snapshot"; then
    if LC_ALL=C tr -d '\000' <"$snapshot" | cmp -s "$snapshot" -; then
      if cat -- "$snapshot"; then
        capture_status=0
      fi
    fi
  fi

  if rm -f -- "$snapshot"; then
    snapshot=""
    trap - EXIT HUP INT TERM
  else
    capture_status=1
  fi

  [[ $capture_status -eq 0 ]] || return 1
  # Preserve trailing newlines through command substitution. This framing byte
  # is removed by position, never searched for or treated as an ownership
  # sentinel.
  printf 'x'
)

remove_owned_legacy_packages() {
  local legacy_toml="build/toml.mojopkg"
  local legacy_mtest="build/mtest.mojopkg"
  local has_toml=0 has_mtest=0
  [[ -e "$legacy_toml" || -L "$legacy_toml" ]] && has_toml=1
  [[ -e "$legacy_mtest" || -L "$legacy_mtest" ]] && has_mtest=1
  [[ $has_toml -eq 1 || $has_mtest -eq 1 ]] || return 0

  local owned=1
  local seen_toml=0 seen_mtest=0 out_ok=0
  local first=1
  local line head_digest rest path recorded actual
  local stamp_snapshot=""
  if [[ ${#DIGEST_CMD[@]} -eq 0 || ! -f "$PRECOMPILE_STAMP" ]]; then
    owned=0
  elif ! stamp_snapshot="$(_capture_complete_stamp "$PRECOMPILE_STAMP")"; then
    owned=0
  else
    stamp_snapshot="${stamp_snapshot%?}"
    while [[ -n "$stamp_snapshot" ]]; do
      if [[ "$stamp_snapshot" == *$'\n'* ]]; then
        line="${stamp_snapshot%%$'\n'*}"
        stamp_snapshot="${stamp_snapshot#*$'\n'}"
      else
        line="$stamp_snapshot"
        stamp_snapshot=""
      fi
      if [[ $first -eq 1 ]]; then
        first=0
        head_digest="${line#in:}"
        if [[ "$line" != in:* || ${#head_digest} -ne 64 || "$head_digest" == *[!0-9a-f]* ]]; then
          owned=0
        fi
        continue
      fi
      case "$line" in
        out:*)
          rest="${line#out:}"
          if [[ "$rest" != *" "* ]]; then
            owned=0
            continue
          fi
          path="${rest%% *}"
          recorded="${rest#* }"
          if [[ ${#recorded} -ne 64 || "$recorded" == *[!0-9a-f]* ]]; then
            owned=0
            continue
          fi
          case "$path" in
            "$legacy_toml")
              [[ $seen_toml -eq 0 ]] || owned=0
              seen_toml=1
              ;;
            "$legacy_mtest")
              [[ $seen_mtest -eq 0 ]] || owned=0
              seen_mtest=1
              ;;
            *)
              owned=0
              ;;
          esac
          if actual="$(_hash_file "$path")"; then
            [[ "$actual" == "$recorded" ]] || owned=0
          else
            owned=0
          fi
          out_ok=$((out_ok + 1))
          ;;
        *)
          owned=0
          ;;
      esac
    done
  fi

  if [[ $owned -eq 1 && $out_ok -eq 2 && $seen_toml -eq 1 && $seen_mtest -eq 1 ]]; then
    rm -f -- build/toml.mojopkg build/mtest.mojopkg
    return 0
  fi

  local ambiguous=""
  [[ $has_toml -eq 1 ]] && ambiguous="$legacy_toml"
  if [[ $has_mtest -eq 1 ]]; then
    [[ -n "$ambiguous" ]] && ambiguous="$ambiguous, "
    ambiguous="${ambiguous}${legacy_mtest}"
  fi
  echo "production-build: legacy package path is not proven to be an owned checkout artifact: $ambiguous; move or remove it before building" >&2
  return 1
}

read_strict_flags() {
  STRICT_FLAGS=()
  local line trimmed
  local strong_count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]] && continue
    if [[ "$trimmed" == "-fstack-protector-strong" ]]; then
      strong_count=$((strong_count + 1))
    elif [[ "$trimmed" == "-fstack-protector" ]]; then
      echo "production-build: forbidden weak stack-protector flag: $flags_file" >&2
      exit 1
    fi
    STRICT_FLAGS+=("$trimmed")
  done <"$flags_file"
  if [[ ${#STRICT_FLAGS[@]} -eq 0 ]]; then
    echo "production-build: strict flag inventory is empty: $flags_file" >&2
    exit 1
  fi
  if [[ $strong_count -ne 1 ]]; then
    echo "production-build: strict flag inventory must contain exactly one -fstack-protector-strong: $flags_file" >&2
    exit 1
  fi
}

_profile_error() {
  local line_number="$1"
  shift
  echo "production-build: $profiles_file:$line_number: $*" >&2
  return 1
}

select_profile() {
  local selected_system="$1"
  local selected_machine="$2"
  local line_number=0
  local line trimmed key value name
  local current_name=""
  local current_line=0
  local current_system="" current_machine="" current_mojo_cpu=""
  local current_mojo_triple="" current_deployment_target=""
  local seen_system=0 seen_machine=0 seen_mojo_cpu=0
  local seen_mojo_triple=0 seen_deployment_target=0
  local selected_count=0
  local index
  local current_c_flag_count=0
  local seen_name_count=0
  local seen_platform_count=0
  local -a current_c_flags
  local -a seen_names
  local -a seen_platform_systems
  local -a seen_platform_machines

  PROFILE_NAME=""
  PROFILE_SYSTEM=""
  PROFILE_MACHINE=""
  MOJO_CPU=""
  MOJO_TRIPLE=""
  DEPLOYMENT_TARGET=""
  PROFILE_C_FLAGS=()

  _finish_profile() {
    [[ -n "$current_name" ]] || return 0
    if [[ $seen_system -eq 0 || $seen_machine -eq 0 || $seen_mojo_cpu -eq 0 ||
      $current_c_flag_count -eq 0 ]]; then
      _profile_error "$current_line" "profile '$current_name' missing required key" || return 1
    fi
    for ((index = 0; index < seen_platform_count; index++)); do
      if [[ "${seen_platform_systems[index]}" == "$current_system" &&
        "${seen_platform_machines[index]}" == "$current_machine" ]]; then
        _profile_error "$current_line" \
          "duplicate production platform $current_system/$current_machine" || return 1
      fi
    done
    seen_platform_systems[seen_platform_count]="$current_system"
    seen_platform_machines[seen_platform_count]="$current_machine"
    seen_platform_count=$((seen_platform_count + 1))
    if [[ "$current_system" == "$selected_system" &&
      "$current_machine" == "$selected_machine" ]]; then
      selected_count=$((selected_count + 1))
      PROFILE_NAME="$current_name"
      PROFILE_SYSTEM="$current_system"
      PROFILE_MACHINE="$current_machine"
      MOJO_CPU="$current_mojo_cpu"
      MOJO_TRIPLE="$current_mojo_triple"
      DEPLOYMENT_TARGET="$current_deployment_target"
      PROFILE_C_FLAGS=()
      for ((index = 0; index < current_c_flag_count; index++)); do
        PROFILE_C_FLAGS[index]="${current_c_flags[index]}"
      done
    fi
  }

  _start_profile() {
    name="$1"
    for ((index = 0; index < seen_name_count; index++)); do
      if [[ "${seen_names[index]}" == "$name" ]]; then
        _profile_error "$line_number" "duplicate profile section '$name'" || return 1
      fi
    done
    seen_names[seen_name_count]="$name"
    seen_name_count=$((seen_name_count + 1))
    current_name="$name"
    current_line="$line_number"
    current_system=""
    current_machine=""
    current_mojo_cpu=""
    current_mojo_triple=""
    current_deployment_target=""
    seen_system=0
    seen_machine=0
    seen_mojo_cpu=0
    seen_mojo_triple=0
    seen_deployment_target=0
    current_c_flag_count=0
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]] && continue
    if [[ "${trimmed:0:1}" == "[" ]]; then
      if [[ ! "$trimmed" =~ ^\[([^][]+)\]$ ]]; then
        _profile_error "$line_number" "malformed profile section" || return 1
      fi
      _finish_profile || return 1
      name="${BASH_REMATCH[1]}"
      name="${name#"${name%%[![:space:]]*}"}"
      name="${name%"${name##*[![:space:]]}"}"
      if [[ -z "$name" ]]; then
        _profile_error "$line_number" "empty profile section" || return 1
      fi
      _start_profile "$name" || return 1
      continue
    fi
    if [[ -z "$current_name" ]]; then
      _profile_error "$line_number" "key before profile section" || return 1
    fi
    if [[ "$trimmed" != *"="* ]]; then
      _profile_error "$line_number" "malformed profile row" || return 1
    fi
    key="${trimmed%%=*}"
    value="${trimmed#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
      system)
        [[ -n "$value" ]] || {
          _profile_error "$line_number" "empty value for 'system'"
          return 1
        }
        [[ $seen_system -eq 0 ]] || {
          _profile_error "$line_number" "duplicate key 'system'"
          return 1
        }
        current_system="$value"
        seen_system=1
        ;;
      machine)
        [[ -n "$value" ]] || {
          _profile_error "$line_number" "empty value for 'machine'"
          return 1
        }
        [[ $seen_machine -eq 0 ]] || {
          _profile_error "$line_number" "duplicate key 'machine'"
          return 1
        }
        current_machine="$value"
        seen_machine=1
        ;;
      mojo_cpu)
        [[ -n "$value" ]] || {
          _profile_error "$line_number" "empty value for 'mojo_cpu'"
          return 1
        }
        [[ $seen_mojo_cpu -eq 0 ]] || {
          _profile_error "$line_number" "duplicate key 'mojo_cpu'"
          return 1
        }
        current_mojo_cpu="$value"
        seen_mojo_cpu=1
        ;;
      mojo_triple)
        [[ -n "$value" ]] || {
          _profile_error "$line_number" "empty value for 'mojo_triple'"
          return 1
        }
        [[ $seen_mojo_triple -eq 0 ]] || {
          _profile_error "$line_number" "duplicate key 'mojo_triple'"
          return 1
        }
        current_mojo_triple="$value"
        seen_mojo_triple=1
        ;;
      deployment_target)
        [[ -n "$value" ]] || {
          _profile_error "$line_number" "empty value for 'deployment_target'"
          return 1
        }
        [[ $seen_deployment_target -eq 0 ]] || {
          _profile_error "$line_number" "duplicate key 'deployment_target'"
          return 1
        }
        current_deployment_target="$value"
        seen_deployment_target=1
        ;;
      c_flag)
        [[ -n "$value" ]] || {
          _profile_error "$line_number" "empty value for 'c_flag'"
          return 1
        }
        current_c_flags[current_c_flag_count]="$value"
        current_c_flag_count=$((current_c_flag_count + 1))
        ;;
      *)
        _profile_error "$line_number" "unknown key '$key'" || return 1
        ;;
    esac
  done <"$profiles_file"

  _finish_profile || return 1
  if [[ $seen_name_count -eq 0 ]]; then
    _profile_error 1 "profile inventory is empty" || return 1
  fi
  if [[ $selected_count -ne 1 ]]; then
    echo "production-build: unsupported production host $selected_system/$selected_machine" >&2
    return 1
  fi
}

stage_precompile() {
  mkdir -p build
  _resolve_digest_cmd
  remove_owned_legacy_packages
  local input_digest=""
  local mojo_version=""
  local can_stamp=1

  # Every precondition for stamping degrades the SAME way: print a notice and
  # build unconditionally, never fail the build. A toolchain that cannot even
  # report its own version is exactly as unstampable as a missing digest
  # tool -- there is no toolchain identity to fingerprint either way.
  if [[ ${#DIGEST_CMD[@]} -eq 0 ]]; then
    echo "production-build: no sha256sum or shasum on PATH -- skipping the precompile stamp, building unconditionally" >&2
    can_stamp=0
  elif ! mojo_version="$(mojo --version 2>&1)"; then
    echo "production-build: \`mojo --version\` did not run -- skipping the precompile stamp, building unconditionally" >&2
    can_stamp=0
  elif [[ ! -f "$PIXI_LOCK_REL" ]]; then
    echo "production-build: $PIXI_LOCK_REL not found -- skipping the precompile stamp, building unconditionally" >&2
    can_stamp=0
  fi

  if [[ $can_stamp -eq 1 ]]; then
    input_digest="$(_precompile_input_digest "$mojo_version")"
    if _precompile_stamp_valid "$PRECOMPILE_STAMP" "$input_digest"; then
      echo "==> precompile stage skipped (stamp matches build/toml.mojoc, build/mtest.mojoc)"
      return 0
    fi
  fi

  echo "==> precompiling vendor/mojo-toml/toml -> build/toml.mojoc"
  "${PRECOMPILE_CMD_TOML[@]}"
  echo "==> precompiling src/mtest -> build/mtest.mojoc"
  "${PRECOMPILE_CMD_MTEST[@]}"

  if [[ $can_stamp -eq 1 ]]; then
    _precompile_write_stamp "$PRECOMPILE_STAMP" "$input_digest"
  fi
}

stage_native() {
  select_profile "$(uname -s)" "$(uname -m)"
  read_strict_flags
  mkdir -p build/native
  echo "==> production profile $PROFILE_NAME ($PROFILE_SYSTEM/$PROFILE_MACHINE)"
  echo "==> compiling native/mtest_exec_native.c -> build/native/mtest_exec_native.o"
  clang \
    "${STRICT_FLAGS[@]}" \
    "${PROFILE_C_FLAGS[@]}" \
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
