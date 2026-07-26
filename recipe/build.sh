#!/usr/bin/env bash
# Builds mtest FROM SOURCE inside rattler-build's isolated build environment and
# installs it into the recipe prefix.
#
# The build itself is delegated to scripts/build/production_build.sh, the single
# production-build authority shared with the repo's own build -> build-native ->
# build-bin pipeline, so the published artifact is produced by exactly the same
# precompile + production native object + link definition the checkout builds and
# tests. That entrypoint runs with only bash + mojo + clang, which is all this
# isolated env provides: requirements.build is `mojo ==1.0.0b2` and
# `clang ==18.1.8` (no Python), both resolving on PATH without extra plumbing.
#
# Runs with $SRC_DIR as the working directory (the recipe's `source: path: ..`
# copy of this repository). Only the $PREFIX/bin install below is recipe-specific
# — the checkout build does not install — so it stays here rather than in the
# shared entrypoint.
set -euo pipefail

bash scripts/build/production_build.sh all

echo "==> installing build/mtest -> \$PREFIX/bin/mtest"
mkdir -p "$PREFIX/bin"
install -m 755 build/mtest "$PREFIX/bin/mtest"

echo "==> installing source-only assertion companion"
assertion_root="$PREFIX/share/mtest/assertions-src/mtest"
install -d -m 755 "$PREFIX/share/mtest"
install -d -m 755 "$PREFIX/share/mtest/assertions-src"
install -d -m 755 "$assertion_root"
install -d -m 755 "$assertion_root/assertions"
install -m 644 assertions-src/mtest/__init__.mojo \
  "$assertion_root/__init__.mojo"
install -m 644 assertions-src/mtest/assertions/__init__.mojo \
  "$assertion_root/assertions/__init__.mojo"
install -m 644 assertions-src/mtest/assertions/_display.mojo \
  "$assertion_root/assertions/_display.mojo"
install -m 644 assertions-src/mtest/assertions/_mapping.mojo \
  "$assertion_root/assertions/_mapping.mojo"
install -m 644 assertions-src/mtest/assertions/_sequence.mojo \
  "$assertion_root/assertions/_sequence.mojo"
install -m 644 assertions-src/mtest/assertions/_text.mojo \
  "$assertion_root/assertions/_text.mojo"
