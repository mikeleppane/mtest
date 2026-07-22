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
