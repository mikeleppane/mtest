#!/usr/bin/env bash
# Builds mtest FROM SOURCE inside rattler-build's isolated build environment,
# mirroring the repo's own build -> build-native -> build-bin pipeline
# (scripts/build/mojo_package.sh, scripts/build/native.py, and pixi.toml's
# build-bin task).
#
# Runs with $SRC_DIR as the working directory (the recipe's `source: path: ../`
# copy of this repository). $PREFIX is the isolated build env supplying
# `mojo` (mojo ==1.0.0b2, from requirements.build) and `clang` (the pinned C
# toolchain, also requirements.build); both resolve on PATH without extra
# plumbing.
set -euo pipefail

mkdir -p build/native

echo "==> precompiling src/mtest -> build/mtest.mojopkg"
mojo precompile src/mtest -o build/mtest.mojopkg

# Compile ONLY the production adapter variant (MTEST_EXEC_TESTING=0) with the
# exact flags scripts/native_abi_check.py uses for the shipped object — the
# test-only variant is a dev/CI artifact, never part of the installed package.
echo "==> compiling native/mtest_exec_native.c -> build/native/mtest_exec_native.o"
clang \
  -std=c17 -O2 -DNDEBUG -Wall -Wextra -Werror -Wpedantic -fPIC -fvisibility=hidden \
  -DMTEST_EXEC_TESTING=0 \
  -I native \
  -c native/mtest_exec_native.c \
  -o build/native/mtest_exec_native.o

echo "==> linking build/mtest"
mojo build -I build src/main.mojo -o build/mtest -Xlinker build/native/mtest_exec_native.o

echo "==> installing build/mtest -> \$PREFIX/bin/mtest"
mkdir -p "$PREFIX/bin"
install -m 755 build/mtest "$PREFIX/bin/mtest"
