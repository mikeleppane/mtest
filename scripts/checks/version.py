#!/usr/bin/env python3
"""Verify every place this repository states which version it is.

`src/mtest/cli/parser.mojo` defines `MTEST_VERSION`, the single source of
truth `main.mojo` reuses for `--version` and the JSON stream header.
`pixi.toml` carries an independent `version` field consumed by packaging
tooling, and `recipe/recipe.yaml` carries its own `version` that names the
built conda package. Nothing else keeps the three in sync; this script is that
gate: parse all three, assert they are byte-identical, and assert the agreed
value is the version this repo is currently shipping.

Four further surfaces state a version to a reader rather than to a tool, and
they were gated by nothing until this script took them on: `README.md` and
`docs/cli-contract.md` carry captured CLI transcripts, and the two banner SVGs
under `docs/assets/` carry the same text inside the image, where nobody reading
the rendered page can tell the output is not live. Until this gate covered them
a stale literal in any of the four shipped to the repository page unnoticed.
Each site is checked twice over: every literal it renders must equal the
release, and it must still render at least one, because a restructure that
dropped the transcripts would otherwise pass this gate vacuously. The gate
deliberately does not count literals; a count would have to be revised by every
content commit while proving nothing about the version.

The README's support matrix states the pinned Mojo toolchain in prose, which
readers take as a promise about what this release builds against. That cell has
no `mtest ` prefix, so the transcript pattern cannot see it; it is checked
against the real pin in `pixi.toml` instead of being maintained by hand.

Wired into `pixi run ci`, so an edit to any one of these files that forgets the
others fails loudly instead of shipping a mislabeled artifact or a false public
claim.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
PARSER_PATH = REPO_ROOT / "src" / "mtest" / "cli" / "parser.mojo"
PIXI_PATH = REPO_ROOT / "pixi.toml"
RECIPE_PATH = REPO_ROOT / "recipe" / "recipe.yaml"
EXPECTED_VERSION = "1.0.0"

MTEST_VERSION_RE = re.compile(r'comptime MTEST_VERSION = "([^"]*)"')
PIXI_VERSION_RE = re.compile(r'(?m)^version = "([^"]*)"')
# The recipe's quoted `version:` (its context var), not `schema_version:` nor
# the unquoted `version: ${{ version }}` template reference.
RECIPE_VERSION_RE = re.compile(r'(?m)^\s*version:\s*"([^"]*)"')

TRANSCRIPT_SITES = (
    Path("README.md"),
    Path("docs/cli-contract.md"),
    Path("docs/assets/mtest-run.svg"),
    Path("docs/assets/mtest-flaky.svg"),
)
"""Every public surface that renders `mtest <version>` for a reader.

The two Markdown files carry captured CLI transcripts; the two SVGs carry the
same text inside the README banners, where no reader of the rendered page can
tell the output is not live. `scripts/release/bump.py` writes exactly this set,
importing it from here so the writer and this gate cannot disagree about what a
site is. Files that pin a deliberately arbitrary version are NOT sites:
`scripts/fixtures/json_stream/*.ndjson`, the report unit tests, and the
`stream_header` docstring all inject their version explicitly and must not move
with the release.
"""

TRANSCRIPT_RE = re.compile(r"mtest (\d+\.\d+\.\d+)(?![\d.])")
"""One rendered version literal.

The trailing guard forbids a *prefix* match. On a malformed literal such as
`mtest 1.0.01` it does not suppress the match, it lengthens it: the capture is
`1.0.01` whole rather than a valid-looking `1.0.0`, so the literal is reported
as written instead of being read as a release that agrees.
"""

SUPPORT_MATRIX_HEADING = "### Supported toolchains"
"""The README section whose table states which Mojo toolchain this release
supports. Prose, not a transcript: `TRANSCRIPT_RE` cannot see it."""

SUPPORT_MATRIX_PIN_RE = re.compile(r"(?m)^\|[^|\n]*\|\s*`([^`\n]+)`\s*\|")
"""The support matrix's Mojo cell, the first backquoted cell in that table.

The header and separator rows carry no backquotes, so the first match inside
the section is the data row's second column.
"""

MOJO_PIN_RE = re.compile(r'(?m)^mojo = "==([^,"]+)')
"""The exact Mojo version pinned by the pixi manifest's dependency line."""


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


def _assert_versions_agree(
    mtest_version: str, pixi_version: str, recipe_version: str
) -> None:
    """Assert the three parsed versions agree with each other and the release.

    Args:
        mtest_version: The `MTEST_VERSION` literal from the Mojo parser source.
        pixi_version: The workspace `version` field from `pixi.toml`.
        recipe_version: The quoted `version` context var from the conda recipe.

    Raises:
        AssertionError: If any pair disagrees, or if the agreed value is not
            `EXPECTED_VERSION`. The pin against `EXPECTED_VERSION` is what stops
            a coordinated bump of all three files from sliding past this gate
            unreviewed.
    """
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


def transcript_versions(path: Path) -> list[str]:
    """Return every rendered version literal in one site, in order.

    Args:
        path: Absolute path to a gated site.

    Returns:
        The captured version strings, one per match.

    Raises:
        AssertionError: If the file holds no literal at all, which means it was
            restructured and this gate would otherwise pass vacuously.
    """
    versions = TRANSCRIPT_RE.findall(path.read_text(encoding="utf-8"))
    if not versions:
        raise AssertionError(f"no rendered version literal found in {path}")
    return versions


def check_transcript_sites(repo_root: Path = REPO_ROOT) -> None:
    """Assert every public transcript renders `EXPECTED_VERSION`.

    Args:
        repo_root: Repository root holding the gated sites.

    Raises:
        AssertionError: If any site renders another version, or renders none.
    """
    for relative in TRANSCRIPT_SITES:
        path = repo_root / relative
        for rendered in transcript_versions(path):
            if rendered != EXPECTED_VERSION:
                raise AssertionError(
                    f"stale public transcript: {path} renders "
                    f"{rendered!r}, expected {EXPECTED_VERSION!r}"
                )


def _support_matrix_mojo_pin(readme_path: Path) -> str:
    """Extract the Mojo cell from the README's support matrix.

    Args:
        readme_path: Absolute path to the README carrying the matrix.

    Returns:
        The toolchain string the matrix promises, without its backquotes.

    Raises:
        AssertionError: If the section or its table row is absent, which means
            the matrix moved and this check would otherwise pass vacuously.
    """
    text = readme_path.read_text(encoding="utf-8")
    start = text.find(SUPPORT_MATRIX_HEADING)
    if start < 0:
        raise AssertionError(
            f"could not find a `{SUPPORT_MATRIX_HEADING}` section in {readme_path}"
        )
    # Bound the search to the section, so a table further down the README
    # cannot stand in for a matrix that has lost its own.
    end = text.find("\n#", start + len(SUPPORT_MATRIX_HEADING))
    section = text[start:] if end < 0 else text[start:end]
    match = SUPPORT_MATRIX_PIN_RE.search(section)
    if match is None:
        raise AssertionError(
            f"the `{SUPPORT_MATRIX_HEADING}` section of {readme_path} states no "
            "Mojo toolchain"
        )
    return match.group(1)


def _manifest_mojo_pin(pixi_path: Path) -> str:
    """Extract the pinned Mojo version from the pixi manifest.

    Args:
        pixi_path: Absolute path to the pixi manifest.

    Returns:
        The exact version the `mojo` dependency pins.

    Raises:
        AssertionError: If the dependency line is absent or no longer pins an
            exact version, either of which leaves the matrix unverifiable.
    """
    text = pixi_path.read_text(encoding="utf-8")
    match = MOJO_PIN_RE.search(text)
    if match is None:
        raise AssertionError(f'could not find `mojo = "==..."` in {pixi_path}')
    return match.group(1)


def check_support_matrix(repo_root: Path = REPO_ROOT) -> None:
    """Assert the README's support matrix names the toolchain actually pinned.

    The matrix is a published claim about what this release builds against, and
    nothing else compares it to the manifest, so a toolchain bump that forgot
    the README would advertise support for a version the repo no longer uses.

    Args:
        repo_root: Repository root holding the README and the pixi manifest.

    Raises:
        AssertionError: If the matrix cell and the manifest pin disagree, or if
            either cannot be located.
    """
    readme_path = repo_root / "README.md"
    pixi_path = repo_root / "pixi.toml"
    advertised = _support_matrix_mojo_pin(readme_path)
    pinned = _manifest_mojo_pin(pixi_path)
    if advertised != pinned:
        raise AssertionError(
            f"stale support matrix: {readme_path} advertises Mojo "
            f"{advertised!r}, but {pixi_path} pins {pinned!r}"
        )


def main() -> int:
    """Assert every manifest, transcript, and published claim states one version.

    Returns:
        0 once the three parsed versions are byte-identical and equal to
        `EXPECTED_VERSION`, every public transcript renders that same version,
        and the support matrix names the pinned toolchain; printing the agreed
        version. 1 after printing the drift to stderr, so `pixi run ci` fails
        instead of building a mislabeled artifact or publishing a false claim.
    """
    try:
        mtest_version = _parse_mtest_version()
        pixi_version = _parse_pixi_version()
        recipe_version = _parse_recipe_version()
        _assert_versions_agree(mtest_version, pixi_version, recipe_version)
        check_transcript_sites()
        check_support_matrix()
    except AssertionError as exc:
        print(f"version-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"version-check: OK ({mtest_version})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
