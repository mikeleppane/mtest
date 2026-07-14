#!/usr/bin/env bash
# Precompile the src/mtest package into build/mtest.mojopkg.
#
# Two jobs: (1) it is the compile GATE — `test` and `ci` run this first, so an
# empty-but-broken package fails fast before any test does; (2) it produces the
# binary package that scripts/test_all.sh builds the tests against, so each test
# compiles only its own small file against a binary dependency instead of
# re-optimizing the whole source tree per run.
#
# NOTE: mojo 1.0.0b2 has no `mojo package` subcommand — only `mojo precompile`,
# which produces the same .mojopkg. The output must be named mtest.mojopkg so
# `-I build` resolves `from mtest import ...`.
#
# Usage:  pixi run build
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p build
echo "==> precompiling src/mtest -> build/mtest.mojopkg"
mojo precompile src/mtest -o build/mtest.mojopkg
echo "==> ok"
