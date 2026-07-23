#!/usr/bin/env python3
"""Verify MTEST_VERSION, the pixi manifest, and the conda recipe agree.

`src/mtest/cli/parser.mojo` defines `MTEST_VERSION`, the single source of
truth `main.mojo` reuses for `--version` and the JSON stream header.
`pixi.toml` carries an independent `version` field consumed by packaging
tooling, and `recipe/recipe.yaml` carries its own `version` that names the
built conda package. Nothing else keeps the three in sync — this script is that
gate: parse all three, assert they are byte-identical, and assert the agreed
value is the version this repo is currently shipping. Wired into `pixi run ci`
so a future edit to any one file that forgets the others fails loudly instead of
shipping a mislabeled artifact.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys

REPO_ROOT = Path(__file__).resolve().parents[2]
PARSER_PATH = REPO_ROOT / "src" / "mtest" / "cli" / "parser.mojo"
PIXI_PATH = REPO_ROOT / "pixi.toml"
RECIPE_PATH = REPO_ROOT / "recipe" / "recipe.yaml"
EXPECTED_VERSION = "0.5.0"

MTEST_VERSION_RE = re.compile(r'comptime MTEST_VERSION = "([^"]*)"')
PIXI_VERSION_RE = re.compile(r'(?m)^version = "([^"]*)"')
# The recipe's quoted `version:` (its context var), not `schema_version:` nor
# the unquoted `version: ${{ version }}` template reference.
RECIPE_VERSION_RE = re.compile(r'(?m)^\s*version:\s*"([^"]*)"')


def _parse_mtest_version() -> str:
    """Extract the `MTEST_VERSION` string literal from the parser source."""
    text = PARSER_PATH.read_text(encoding="utf-8")
    match = MTEST_VERSION_RE.search(text)
    if match is None:
        raise AssertionError(
            f'could not find `comptime MTEST_VERSION = "..."` in {PARSER_PATH}'
        )
    return match.group(1)


def _parse_pixi_version() -> str:
    """Extract the workspace `version` field from the pixi manifest."""
    text = PIXI_PATH.read_text(encoding="utf-8")
    match = PIXI_VERSION_RE.search(text)
    if match is None:
        raise AssertionError(f'could not find `version = "..."` in {PIXI_PATH}')
    return match.group(1)


def _parse_recipe_version() -> str:
    """Extract the quoted `version` context var from the conda recipe."""
    text = RECIPE_PATH.read_text(encoding="utf-8")
    match = RECIPE_VERSION_RE.search(text)
    if match is None:
        raise AssertionError(f'could not find `version: "..."` in {RECIPE_PATH}')
    return match.group(1)


def main() -> int:
    """Assert MTEST_VERSION, pixi.toml, and the conda recipe agree with each
    other and with the version this repo is currently shipping.
    """
    try:
        mtest_version = _parse_mtest_version()
        pixi_version = _parse_pixi_version()
        recipe_version = _parse_recipe_version()
        if mtest_version != pixi_version:
            raise AssertionError(
                "version drift: "
                f"MTEST_VERSION={mtest_version!r} ({PARSER_PATH}) != "
                f"pixi version={pixi_version!r} ({PIXI_PATH})"
            )
        if recipe_version != mtest_version:
            raise AssertionError(
                "version drift: "
                f"recipe version={recipe_version!r} ({RECIPE_PATH}) != "
                f"MTEST_VERSION={mtest_version!r} ({PARSER_PATH})"
            )
        if mtest_version != EXPECTED_VERSION:
            raise AssertionError(
                f"MTEST_VERSION and pixi version agree on {mtest_version!r} but "
                f"neither matches the expected release {EXPECTED_VERSION!r}"
            )
    except AssertionError as exc:
        print(f"version-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"version-check: OK ({mtest_version})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
