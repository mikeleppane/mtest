#!/usr/bin/env python3
"""Rewrite every version literal in one edit so the gates cannot disagree.

Nine files carry the release version, in four syntaxes plus rendered CLI
transcripts in prose and SVG. Only three of them are covered by
`scripts/checks/version.py`; `scripts/qa/contract.py` fails at a different
gate, and the transcripts in `README.md`, `docs/cli-contract.md`, and the two
banner SVGs are gated by nothing at all. Bumping by hand means nine edits, and
the ones that go unnoticed are exactly the ones no gate is watching.

The site list derives from what the 1.0.0 bump changed, not from a search over
likely file types: such a search is what misses the SVGs. That bump also
touched `tests/unit/test_cli_parse.mojo`, which no longer belongs here because
it composes the string from `MTEST_VERSION` instead of pinning a literal.
Files that pin a deliberately arbitrary version are excluded for the same
reason; see `TRANSCRIPT_RE`.

Rewriting `EXPECTED_VERSION` from here is deliberate, not an oversight. That
pin exists so a coordinated hand-edit of the other files cannot reach main
unreviewed; invoking this tool is itself the deliberate act, and the pin still
catches any bump made without it. Nothing here weakens the gate: it refuses to
run at all unless every site already agrees, so a tree that has drifted must be
repaired before it can be bumped.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import re
import shutil
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]

# Deliberately the same shape as release.yml's `version` input guard, so this
# tool cannot mint a version the release workflow would turn away: no leading
# `v`, no pre-release suffix, no zero-padded component.
VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}\Z")

# Every rendered `mtest <version>` the repository commits, in prose and in SVG.
# The trailing guard stops `1.0.0` from matching inside `1.0.01`. Fixtures that
# pin a deliberately arbitrary version (`scripts/fixtures/json_stream/*.ndjson`,
# the report unit tests, and the `stream_header` docstring, all still on 0.6.0)
# are NOT sites: they inject their version explicitly and must not move with the
# release.
TRANSCRIPT_RE = re.compile(r"mtest (\d+\.\d+\.\d+)(?![\d.])")


@dataclass(frozen=True)
class Site:
    """One file and the pattern locating each version literal inside it.

    Attributes:
        path: Absolute path to the file holding the literal.
        pattern: Pattern whose first group is the version text itself, so the
            surrounding syntax is matched for anchoring but never rewritten.
    """

    path: Path
    pattern: re.Pattern[str]


SITES = (
    # The source of truth `main.mojo` reuses for `--version` and the JSON
    # stream header. Every other site below exists to agree with this one.
    Site(
        REPO_ROOT / "src" / "mtest" / "cli" / "parser.mojo",
        re.compile(r'comptime MTEST_VERSION = "([^"]*)"'),
    ),
    # The workspace version packaging tooling reads, and the value release.yml
    # checks against the version it was dispatched with.
    Site(
        REPO_ROOT / "pixi.toml",
        re.compile(r'(?m)^version = "([^"]*)"'),
    ),
    # The conda recipe's context var, which names the built package.
    Site(
        REPO_ROOT / "recipe" / "recipe.yaml",
        re.compile(r'(?m)^\s*version:\s*"([^"]*)"'),
    ),
    # The version-drift gate's own pin. See the module docstring.
    Site(
        REPO_ROOT / "scripts" / "checks" / "version.py",
        re.compile(r'(?m)^EXPECTED_VERSION = "([^"]*)"'),
    ),
    # The CLI contract's assertion that `mtest version` prints this release.
    Site(
        REPO_ROOT / "scripts" / "qa" / "contract.py",
        re.compile(r'out_has=\["mtest ([^"]*)"\]'),
    ),
    # The CLI contract document, whose transcripts are the spec the qa gate
    # renders against.
    Site(
        REPO_ROOT / "docs" / "cli-contract.md",
        TRANSCRIPT_RE,
    ),
    # Committed CLI transcripts. Ungated, so a stale one ships unnoticed into
    # the first thing anyone reads on the repository page.
    Site(
        REPO_ROOT / "README.md",
        TRANSCRIPT_RE,
    ),
    # The two README banners. Text inside SVG, so no reader of the rendered
    # page can tell these are not live output.
    Site(
        REPO_ROOT / "docs" / "assets" / "mtest-run.svg",
        TRANSCRIPT_RE,
    ),
    Site(
        REPO_ROOT / "docs" / "assets" / "mtest-flaky.svg",
        TRANSCRIPT_RE,
    ),
)


def _site_versions(site: Site) -> list[str]:
    """Return every version literal the site's pattern captures, in order.

    Args:
        site: The file and pattern to scan.

    Returns:
        The captured version strings, one per match.

    Raises:
        ValueError: If the pattern matches nothing, which means the file was
            restructured and this tool would silently skip it.
    """
    text = site.path.read_text(encoding="utf-8")
    versions = [match.group(1) for match in site.pattern.finditer(text)]
    if not versions:
        raise ValueError(f"no version literal found in {site.path}")
    return versions


def current_version() -> str:
    """Return the version every site agrees on.

    Returns:
        The single version string shared by all sites.

    Raises:
        ValueError: If any site disagrees. Bumping a drifted tree would bury
            the drift under a passing gate, so this refuses instead.
    """
    seen: dict[str, list[Path]] = {}
    for site in SITES:
        for version in _site_versions(site):
            seen.setdefault(version, []).append(site.path)
    if len(seen) != 1:
        detail = "; ".join(
            f"{version!r} in " + ", ".join(sorted({str(p) for p in paths}))
            for version, paths in sorted(seen.items())
        )
        raise ValueError(f"version drift, repair before bumping: {detail}")
    return next(iter(seen))


def _rewrite(text: str, pattern: re.Pattern[str], new_version: str) -> tuple[str, int]:
    """Replace each captured version with `new_version`, right to left.

    Args:
        text: The file contents to rewrite.
        pattern: Pattern whose first group spans the version text.
        new_version: The replacement version.

    Returns:
        The rewritten text and the number of literals replaced. Iterating in
        reverse keeps every earlier match span valid as the text changes length.
    """
    matches = list(pattern.finditer(text))
    for match in reversed(matches):
        start, end = match.span(1)
        text = text[:start] + new_version + text[end:]
    return text, len(matches)


def _invalidate_bytecode(path: Path) -> None:
    """Drop any cached bytecode for a rewritten Python source file.

    CPython accepts a `.pyc` as current when it records the source's mtime and
    size, which have one-second and one-byte granularity. This tool rewrites
    `scripts/checks/version.py` to a version string that is almost always the
    same length, so a bump landing in the same second as an earlier import
    leaves the cache looking valid, and the next `version-check` reads the old
    version straight out of bytecode. That gate exists precisely to prove the
    bump landed, and a stale answer is wrong in both directions: it can pass a
    bump that never happened and fail one that did.

    Args:
        path: The file just rewritten. Does nothing unless it is `.py` source.
    """
    if path.suffix != ".py":
        return
    for stale in (path.parent / "__pycache__").glob(f"{path.stem}.*.pyc"):
        stale.unlink(missing_ok=True)


def _atomic_write(path: Path, text: str) -> None:
    """Replace a file's contents without ever leaving it partially written.

    `Path.write_text` truncates before it writes, so a failure partway through
    leaves a half-written file that no gate can tell apart from a deliberate
    edit. Writing a sibling temporary file and renaming it over the original
    makes each replacement atomic; `os.replace` is atomic within a filesystem,
    and a sibling is always on the same one.

    Args:
        path: The file to overwrite.
        text: The complete new contents.

    Raises:
        OSError: If the temporary file cannot be written, have its mode copied,
            or be moved into place. The original file is left untouched and the
            temporary file is removed.
    """
    temp = path.with_name(f"{path.name}.bump-tmp")
    try:
        temp.write_text(text, encoding="utf-8")
        shutil.copymode(path, temp)
        os.replace(temp, path)
    except OSError:
        temp.unlink(missing_ok=True)
        raise
    _invalidate_bytecode(path)


def bump(new_version: str) -> list[tuple[Path, int]]:
    """Rewrite every version literal in the repository to `new_version`.

    Args:
        new_version: The target version, without a leading `v`.

    Returns:
        One `(path, count)` pair per site, in declaration order.

    Raises:
        ValueError: If `new_version` is malformed, matches the current version,
            or the tree has drifted. Nothing is written in any of these cases.
        OSError: If a file cannot be read, or cannot be replaced once writing
            has begun. Files already replaced keep their new version.
    """
    if VERSION_RE.fullmatch(new_version) is None:
        raise ValueError(f"{new_version!r} is not a stable MAJOR.MINOR.PATCH version")
    old_version = current_version()
    if new_version == old_version:
        raise ValueError(f"already at {old_version}")

    # Read and rewrite everything in memory before the first write, so a
    # malformed argument or a drifted tree is rejected with the tree untouched.
    rewritten: list[tuple[Site, str, int]] = []
    for site in SITES:
        text = site.path.read_text(encoding="utf-8")
        new_text, count = _rewrite(text, site.pattern, new_version)
        rewritten.append((site, new_text, count))

    # Each file's replacement is atomic, so none can be left truncated. The set
    # of them is still not one transaction: an OSError partway through leaves
    # the earlier files bumped and the rest not. That state is inconsistent but
    # never corrupt, `version-check` names it, and `git checkout` undoes it.
    changed: list[tuple[Path, int]] = []
    for site, new_text, count in rewritten:
        _atomic_write(site.path, new_text)
        changed.append((site.path, count))
    return changed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument(
        "version",
        help="target version without a leading v, for example 1.1.0",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """Bump every version literal and report what changed.

    Returns:
        0 after every site is rewritten, printing one line per file. 1 after
        printing the reason to stderr, having written nothing.
    """
    args = _parser().parse_args(argv)
    try:
        old_version = current_version()
        changed = bump(args.version)
    except (OSError, ValueError) as exc:
        print(f"bump: FAIL: {exc}", file=sys.stderr)
        return 1
    for path, count in changed:
        literals = "literal" if count == 1 else "literals"
        print(f"  {path.relative_to(REPO_ROOT)}: {count} {literals}")
    print(f"bump: OK ({old_version} -> {args.version})")
    print("Review the diff, then run `pixi run version-check`.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
