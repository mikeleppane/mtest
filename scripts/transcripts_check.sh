#!/usr/bin/env bash
# CI gate: regenerate every transcript into a temp dir and diff against what is
# committed under goldens/transcripts/ — byte-identical or red. This is strictly
# stronger than a hash check (it shows WHICH bytes moved) and is the protocol
# pin: the generator stamps the resolved mojo version and os/arch into every
# header, so a toolchain re-pin diffs loudly and the diff IS the protocol
# changelog.
#
# It is hermetic: the generator builds the committed fixtures and runs them; no
# network is touched.
#
# TRANSCRIPT LIFECYCLE: a red diff after a repo change indicts THE CHANGE, not
# the goldens. Regenerating (pixi run transcripts) is legitimate ONLY when the
# oracle side visibly changed — a mojo pin bump (visible in every header) or a
# deliberate fixture/matrix edit. Never hand-edit a transcript. When it goes red,
# suspect in order: (1) generator nondeterminism (ordering, environment leakage,
# an un-normalized absolute path), (2) a resolved-toolchain mismatch vs the
# header, (3) byte mangling from a missing .gitattributes entry on a new path.
#
# Usage:  pixi run transcripts-check
set -euo pipefail

cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python scripts/gen_transcripts.py --out "$TMP" >/dev/null

if ! diff -ru goldens/transcripts "$TMP"; then
    echo "" >&2
    echo "transcripts-check: committed transcripts differ from a fresh" >&2
    echo "  regeneration. A repo change must not move these bytes. If the" >&2
    echo "  TOOLCHAIN genuinely changed (check the mojo version in the header)," >&2
    echo "  run 'pixi run transcripts' and commit the result with that reason." >&2
    echo "  Never hand-edit a transcript to make this pass." >&2
    exit 1
fi

echo "transcripts-check: OK — transcripts match a fresh regeneration"
