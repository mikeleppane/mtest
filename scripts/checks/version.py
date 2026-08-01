#!/usr/bin/env python3
"""Verify every place this repository states which version it is.

`src/mtest/cli/parser.mojo` defines `MTEST_VERSION`, the single source of
truth `main.mojo` reuses for `--version` and the JSON stream header.
`pixi.toml` carries an independent `version` field consumed by packaging
tooling, and `recipe/recipe.yaml` carries its own `version` that names the
built conda package. Nothing else keeps the three in sync; this script is that
gate: parse all three, assert they are byte-identical, and assert the agreed
value is the version this repo is currently shipping.

Six further surfaces state a version to a reader rather than to a tool, and
they were gated by nothing until this script took them on: `README.md`,
`docs/cli-contract.md` and two documentation-site pages carry captured CLI
transcripts, and the two banner SVGs under `docs/assets/` carry the same text
inside the image, where nobody reading the rendered page can tell the output is
not live. Until this gate covered them a stale literal in any of the six
shipped to the repository page unnoticed.
Each site is checked twice over: every literal it renders must equal the
release, and it must still render at least one, because a restructure that
dropped the transcripts would otherwise pass this gate vacuously. The gate
deliberately does not count literals; a count would have to be revised by every
content commit while proving nothing about the version.

Naming those six is not enough on its own, because the list is hand-written
and a documentation page added tomorrow would be ungated from birth. So the
gate also sweeps every tracked file for a rendered literal and fails on any it
was not told about, forcing each new surface to be declared a site or an
explicit exemption. That is what makes the list a decision rather than a
memory.

Eight files restate which Mojo toolchain this release uses: both conda recipes,
the recipe build script, and the prose in the README (including its support
matrix cell), the contract, the changelog, the contributing guide, and the
agent guide. Every claim in them is compared against the one pin in
`pixi.toml`. The recipes are the ones that ship, and nothing held either
against the manifest before, so a toolchain bump that stopped at the manifest
left the published package asking for a compiler this repository no longer
builds against.

Wired into `pixi run ci`, so an edit to any one of these files that forgets the
others fails loudly instead of shipping a mislabeled artifact or a false public
claim.
"""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
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
    Path("docs/index.md"),
    Path("docs/getting-started.md"),
    Path("docs/assets/mtest-run.svg"),
    Path("docs/assets/mtest-flaky.svg"),
)
"""Every public surface that renders `mtest <version>` for a reader.

The four Markdown files carry captured CLI transcripts; the two SVGs carry the
same text inside the README banners, where no reader of the rendered page can
tell the output is not live. Two of the Markdown files are documentation-site
pages, and their transcripts are not retyped copies: the docs-parity gate holds
each of them byte-identical to the README block it mirrors. That gate proves a
page still says what the README says; this one proves what they both say is the
version being shipped. `docs/ci.md` is a site page too and is deliberately
absent, because its two mirrored workflows render no version literal, and a
listed site that renders none fails this gate.

`scripts/release/bump.py` writes exactly this set, importing it from here so
the writer and this gate cannot disagree about what a site is. Files that pin a
deliberately arbitrary version are NOT sites:
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

TRANSCRIPT_EXEMPT = (
    Path("scripts/checks/version.py"),
    Path("scripts/tests/test_version.py"),
    Path("scripts/qa/contract.py"),
    Path("scripts/fixtures/json_stream/corrupt_midline.ndjson"),
    Path("scripts/fixtures/json_stream/forward_compat.ndjson"),
    Path("scripts/fixtures/json_stream/torn_tail.ndjson"),
    Path("scripts/tests/test_package_consumption.py"),
    Path("scripts/tests/test_public_verify.py"),
    Path("scripts/tests/test_selfhost.py"),
    Path("scripts/tests/test_valgrind.py"),
    Path("src/mtest/report/json_stream.mojo"),
    Path("tests/unit/test_report_composite.mojo"),
    Path("tests/unit/test_report_console.mojo"),
)
"""Tracked files that render `mtest <version>` and are deliberately not sites.

Such files do exist, so the sweep needs somewhere to put them rather than a
rule that pretends they cannot occur. Three kinds:

- This module and `scripts/tests/test_version.py`. Both quote the malformed
  literal `mtest 1.0.01` while documenting and testing `TRANSCRIPT_RE`, and the
  tests fabricate a stale `mtest 0.9.9`. Exempted deliberately and named here
  rather than skipped by some rule about the checker's own directory, because a
  rule wide enough to cover this file would also cover any future public
  surface written beside it.
- Fixtures and unit tests that pin a deliberately arbitrary version
  (`scripts/fixtures/json_stream/*.ndjson`, the report tests, the
  `stream_header` docstring, the harness suites). They assert against a version
  chosen to be *not* the release, and `bump` must leave them alone; rewriting
  them would erase the very difference they test.
- `scripts/qa/contract.py`, the one file `bump` does rewrite that is not a
  public surface. Its `out_has=["mtest 1.0.0"]` is an assertion about what the
  binary prints, not a transcript shown to a reader, so it carries its own
  pattern in `bump.SITES` and fails at the contract gate rather than here.

An entry that stops matching is an error, not a leftover: the sweep says so, so
this list cannot quietly accumulate exemptions for files that no longer need
one.
"""

MOJO_PIN_SITES = (
    Path("recipe/recipe.yaml"),
    Path("recipe/community/recipe.yaml.in"),
    Path("recipe/build.sh"),
    Path("README.md"),
    Path("CONTRIBUTING.md"),
    Path("CHANGELOG.md"),
    Path("docs/cli-contract.md"),
    Path("AGENTS.md"),
)
"""Every file that restates the pinned Mojo toolchain in prose or in a recipe.

The two recipes matter most because they ship: `recipe/recipe.yaml` names the
compiler the built conda package declares as its run dependency, and
`recipe/community/recipe.yaml.in` is what modular-community publishes. Nothing
compared either against `pixi.toml` before: `check_recipe_drift` holds the two
recipes against *each other*, which says nothing when both are stale together.
The rest are published claims a reader acts on when setting up a toolchain.

Two restatements live in code and are gated against the live toolchain instead,
so they are not listed here: `scripts/checks/coverage_capability.py` asserts its
own `PINNED_MOJO_VERSION` appears in this manifest's spec, and
`src/mtest/cli/doctor.mojo` compares `_PINNED_MOJO_IDENTITY` against what the
installed compiler actually reports. Passing mentions in build-script comments
are narration about how the pinned toolchain behaves, not claims about what
this release requires, and are deliberately out of scope.
"""

MOJO_PIN_CLAIM_RE = re.compile(
    r"(?i)\bmojo(?:-compiler)?[ -](?:`?==)?\s*`?(\d+\.\d+\.\d+[A-Za-z0-9]*)"
)
"""One claim about which Mojo toolchain this release uses.

Covers the forms the tree actually writes: a recipe's `- mojo ==1.0.0b2` and
`- mojo-compiler ==1.0.0b2`, Markdown's `` `mojo-compiler ==1.0.0b2` `` and
``Mojo `1.0.0b2` `` and ``Mojo `==1.0.0b2` ``, the package filename
`mojo-compiler-1.0.0b2-release`, and the rendered `Mojo 1.0.0b2 (2cf4d08a)`.
Requiring the word `mojo` immediately before the version is what keeps prose
about behavior at the pinned toolchain (`1.0.0b2 polymorphism is static`) out:
that text goes stale on a bump too, but it is not a claim about what to
install, and gating it would make every such sentence a version site.
"""


def _read_text(path: Path) -> str:
    """Read one gated file, reporting a vanished file as a gate failure.

    Args:
        path: Absolute path to the file to read.

    Returns:
        The file's contents, decoded as UTF-8.

    Raises:
        AssertionError: If the file cannot be read or decoded. `main()` catches
            only `AssertionError`, so a site that was deleted or renamed must
            arrive as a named failure rather than as a traceback.
    """
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise AssertionError(f"cannot read {path}: {exc}") from exc
    except UnicodeDecodeError as exc:
        raise AssertionError(f"{path} is not UTF-8 text: {exc}") from exc


def _parse_mtest_version() -> str:
    """Extract the `MTEST_VERSION` string literal from the parser source."""
    text = _read_text(PARSER_PATH)
    match = MTEST_VERSION_RE.search(text)
    if match is None:
        raise AssertionError(
            f'could not find `comptime MTEST_VERSION = "..."` in {PARSER_PATH}'
        )
    return match.group(1)


def _parse_pixi_version() -> str:
    """Extract the workspace `version` field from the pixi manifest."""
    text = _read_text(PIXI_PATH)
    match = PIXI_VERSION_RE.search(text)
    if match is None:
        raise AssertionError(f'could not find `version = "..."` in {PIXI_PATH}')
    return match.group(1)


def _parse_recipe_version() -> str:
    """Extract the quoted `version` context var from the conda recipe."""
    text = _read_text(RECIPE_PATH)
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
    versions = TRANSCRIPT_RE.findall(_read_text(path))
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
    text = _read_text(readme_path)
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
    text = _read_text(pixi_path)
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


def check_mojo_pin_sites(repo_root: Path = REPO_ROOT) -> None:
    """Assert every restatement of the Mojo pin matches the pixi manifest.

    The manifest is the single source; every site listed in `MOJO_PIN_SITES`
    repeats its value for a different audience, and a bump that updates the
    manifest alone leaves the shipped conda recipe requesting a compiler this
    repository no longer builds against.

    Args:
        repo_root: Repository root holding the sites and the pixi manifest.

    Raises:
        AssertionError: If any site claims another toolchain, if a site states
            none at all, or if the manifest pin cannot be read.
    """
    pinned = _manifest_mojo_pin(repo_root / "pixi.toml")
    for relative in MOJO_PIN_SITES:
        path = repo_root / relative
        claimed = MOJO_PIN_CLAIM_RE.findall(_read_text(path))
        if not claimed:
            raise AssertionError(f"no Mojo toolchain claim found in {path}")
        for claim in claimed:
            if claim != pinned:
                raise AssertionError(
                    f"stale toolchain claim: {path} names Mojo {claim!r}, but "
                    f"{repo_root / 'pixi.toml'} pins {pinned!r}"
                )


def _tracked_files(repo_root: Path) -> list[Path]:
    """List every file git tracks in one repository, as relative paths.

    Reads the index rather than walking the filesystem, so untracked scratch
    files, build output, and ignored trees cannot make this gate red, and so
    the sweep cannot miss a file by failing to guess a directory name.

    Args:
        repo_root: Repository root to enumerate.

    Returns:
        One relative path per tracked file.

    Raises:
        AssertionError: If git is unavailable or the directory is not a
            repository. The sweep fails closed: without an inventory it cannot
            tell an undeclared surface from an empty tree.
    """
    try:
        completed = subprocess.run(
            ["git", "-C", str(repo_root), "ls-files", "-z"],
            capture_output=True,
            check=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise AssertionError(
            f"cannot list tracked files under {repo_root}: {exc}"
        ) from exc
    return [Path(name) for name in completed.stdout.split("\0") if name]


def _renders_a_transcript(path: Path) -> bool:
    """Report whether one tracked file renders a `mtest <version>` literal.

    Args:
        path: Absolute path to a tracked file.

    Returns:
        True if the file is UTF-8 text holding at least one literal. Files that
        do not decode are binary and cannot render a literal to a reader, so
        they are not surfaces; the repository's one such file is a PNG logo.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    return TRANSCRIPT_RE.search(text) is not None


def check_no_undeclared_transcripts(repo_root: Path = REPO_ROOT) -> None:
    """Assert no tracked file renders a version without being declared.

    `TRANSCRIPT_SITES` is hand-written, so on its own it gates the surfaces
    someone remembered. A new documentation page carrying captured output would
    be ungated from the moment it lands, and `bump` would not rewrite it either.
    This sweep closes that by inverting the question: every tracked file that
    renders a literal must be either a site or a named exemption, and anything
    else fails until someone decides which it is.

    Args:
        repo_root: Repository root to sweep.

    Raises:
        AssertionError: If a tracked file renders a literal and is neither a
            site nor an exemption, or if an exemption no longer renders one and
            has become a hole rather than an exception.
    """
    overlap = set(TRANSCRIPT_SITES) & set(TRANSCRIPT_EXEMPT)
    if overlap:
        raise AssertionError(
            "a transcript site cannot also be exempt from the sweep: "
            + ", ".join(sorted(str(path) for path in overlap))
        )
    declared = set(TRANSCRIPT_SITES) | set(TRANSCRIPT_EXEMPT)
    rendering = {
        relative
        for relative in _tracked_files(repo_root)
        if _renders_a_transcript(repo_root / relative)
    }
    undeclared = rendering - declared
    if undeclared:
        raise AssertionError(
            "undeclared public version transcript in "
            + ", ".join(sorted(str(path) for path in undeclared))
            + "; add it to TRANSCRIPT_SITES so the release bumps and gates it, "
            "or to TRANSCRIPT_EXEMPT with the reason it must not move"
        )
    stale_exemptions = set(TRANSCRIPT_EXEMPT) - rendering
    if stale_exemptions:
        raise AssertionError(
            "TRANSCRIPT_EXEMPT names files that render no version literal: "
            + ", ".join(sorted(str(path) for path in stale_exemptions))
            + "; delete the entry rather than leaving a standing exemption"
        )


def main() -> int:
    """Assert every manifest, transcript, and published claim states one version.

    Returns:
        0 once the three parsed versions are byte-identical and equal to
        `EXPECTED_VERSION`, every public transcript renders that same version,
        no undeclared tracked file renders one, and every restatement of the
        Mojo pin matches the manifest; printing the agreed version. 1 after
        printing the drift to stderr, so `pixi run ci` fails instead of building
        a mislabeled artifact or publishing a false claim.
    """
    try:
        mtest_version = _parse_mtest_version()
        pixi_version = _parse_pixi_version()
        recipe_version = _parse_recipe_version()
        _assert_versions_agree(mtest_version, pixi_version, recipe_version)
        check_transcript_sites()
        check_no_undeclared_transcripts()
        check_support_matrix()
        check_mojo_pin_sites()
    except AssertionError as exc:
        print(f"version-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"version-check: OK ({mtest_version})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
