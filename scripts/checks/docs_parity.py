#!/usr/bin/env python3
"""Hold every command and output on the documentation site to its README source.

The site exists to navigate a reader to documents that are already gated: the
command-line contract, the event-stream specification, the release runbook.
Three pages cannot do their job by navigation alone — a landing page has to
show how the package is installed, a five-minute path has to show a test file
and the run it produces, and the continuous-integration page has to show the
workflow to paste — and each of those is a command or a captured output living
somewhere other than the surface that owns it.

A second copy of a command is the defect this repository keeps finding. The
README's blocks are executed against the built binary before they are
committed; a copy on a site page is executed by nothing, agrees with the
original on the day it is written, and silently stops agreeing on the day the
original is corrected. Nothing would report it, because a page that renders
plausible output looks exactly like a page that renders true output.

So the site never gets a copy. It gets a declared mirror: `PARITY_BLOCKS` names
each fenced block on a page together with the README section and ordinal that
owns it, and this gate compares the two byte for byte, info string included, on
every policy run. Declaring the mirror is what buys the right to show the block
at all.

Two further assertions stop the gate from being defeated by simply not using
it. Every fenced block on every site page must be declared, so a block added to
a page without a declaration fails rather than passing unexamined; and an index
that names nothing — a page ordinal past the end, a README section that was
renamed, an ordinal past the end of that section — fails rather than silently
matching no block. A gate that can be satisfied by removing a declaration is
not a gate.

Rendered version literals inside a mirrored block are a separate concern with a
separate owner: `scripts/checks/version.py` sweeps every tracked file and fails
on any that renders one without being declared a site there. The two gates are
complementary. This one proves a mirrored block still says what the README
says; that one proves the version those blocks render is the version this
repository ships.
"""

from __future__ import annotations

from dataclasses import dataclass
from itertools import zip_longest
from pathlib import Path
import re
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
README_PATH = Path("README.md")

SITE_PAGES = (
    Path("docs/index.md"),
    Path("docs/getting-started.md"),
    Path("docs/ci.md"),
)
"""Every documentation-site page allowed to render a command or an output.

The reference documents the site navigates to (`docs/cli-contract.md`,
`docs/json-stream.md`, `docs/releasing.md`) are not listed: they are the
originals their own gates already cover, not copies of anything, and declaring
them here would invert the relationship this module exists to express.
"""

FENCE_RE = re.compile(r"^(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
"""One fence line, opening or closing, at the left margin.

Only column zero counts. Every fence in the README and on the site pages starts
there, and requiring it keeps a fence-like line inside an indented block from
being read as a real fence.
"""

H2_RE = re.compile(r"^## (?P<heading>.+?)\s*$")
"""One README H2 heading, whose text names the section owning a source block."""


@dataclass(frozen=True)
class FencedBlock:
    """One fenced block, as written.

    Attributes:
        info: The opening fence's info string, stripped of surrounding
            whitespace. Compared along with the body, because a block that
            changed language changed what it claims to be.
        body: The exact text between the fences, line endings included.
        line: One-based line number of the opening fence, so a failure names a
            position a reader can open.
    """

    info: str
    body: str
    line: int


@dataclass(frozen=True)
class ParityBlock:
    """One fenced block that exists on the site and must mirror the README.

    Attributes:
        page: Site page holding the copy, relative to the repository root.
        page_index: Zero-based ordinal of the fenced block within `page`.
        readme_section: README H2 heading text owning the source block.
        readme_index: Zero-based ordinal of the fenced block within that
            section.
    """

    page: Path
    page_index: int
    readme_section: str
    readme_index: int


PARITY_BLOCKS = (
    # The landing page's install block: the channel and package commands, and
    # the version the installed binary prints back.
    ParityBlock(Path("docs/index.md"), 0, "Installation", 0),
    # The five-minute path: the test file a reader saves, the passing run, and
    # the compile error a wrong import produces.
    ParityBlock(Path("docs/getting-started.md"), 0, "Your first test", 0),
    ParityBlock(Path("docs/getting-started.md"), 1, "Your first test", 1),
    ParityBlock(Path("docs/getting-started.md"), 2, "Your first test", 2),
    # The workflow to paste, and the sharded variant of it.
    ParityBlock(Path("docs/ci.md"), 0, "Run it in CI", 0),
    ParityBlock(Path("docs/ci.md"), 1, "Run it in CI", 1),
)
"""Every mirrored block, paired with the README block that owns it.

Read this as the site's permission slip: a block appears here because a page
genuinely cannot do its job without showing it, and appearing here is what
subjects it to the comparison below.
"""


def _read_text(path: Path) -> str:
    """Read one gated document, reporting a vanished file as a gate failure.

    Args:
        path: Absolute path to the file to read.

    Returns:
        The file's contents, decoded as UTF-8.

    Raises:
        AssertionError: If the file cannot be read or decoded. `main()` catches
            only `AssertionError`, so a page that was deleted or renamed must
            arrive as a named failure rather than as a traceback.
    """
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise AssertionError(f"cannot read {path}: {exc}") from exc
    except UnicodeDecodeError as exc:
        raise AssertionError(f"{path} is not UTF-8 text: {exc}") from exc


def fenced_blocks(
    text: str, label: str, first_line: int = 1
) -> tuple[FencedBlock, ...]:
    """Return every fenced block in one document, in order.

    Args:
        text: The document text to scan.
        label: How to name the document in a failure message.
        first_line: One-based line number `text` starts at, so a block found
            inside a section still reports its position in the whole file.

    Returns:
        One `FencedBlock` per fence pair, in document order.

    Raises:
        AssertionError: If a fence is opened and never closed. An unterminated
            fence makes every later ordinal mean something different, so the
            gate refuses rather than compare against a shifted list.
    """
    blocks: list[FencedBlock] = []
    lines = text.splitlines(keepends=True)
    opening: re.Match[str] | None = None
    opened_at = 0
    body_start = 0
    for index, raw in enumerate(lines):
        match = FENCE_RE.match(raw.rstrip("\r\n"))
        if match is None:
            continue
        if opening is None:
            opening = match
            opened_at = index
            body_start = index + 1
            continue
        marker = opening.group("fence")
        closes = match.group("fence")
        if closes[0] != marker[0] or len(closes) < len(marker):
            continue
        if match.group("info").strip():
            continue
        blocks.append(
            FencedBlock(
                info=opening.group("info").strip(),
                body="".join(lines[body_start:index]),
                line=first_line + opened_at,
            )
        )
        opening = None
    if opening is not None:
        raise AssertionError(
            f"{label}: fence opened at line {first_line + opened_at} is never closed"
        )
    return tuple(blocks)


def readme_section_blocks(
    readme_text: str, heading: str, label: str
) -> tuple[FencedBlock, ...]:
    """Return every fenced block inside one README H2 section.

    Args:
        readme_text: The whole README text.
        heading: Exact H2 heading text owning the section.
        label: How to name the README in a failure message.

    Returns:
        The section's fenced blocks, in document order.

    Raises:
        AssertionError: If the section is absent or appears more than once.
            Either means a declaration names something the README no longer
            has, and matching nothing must fail rather than pass vacuously.
    """
    lines = readme_text.splitlines(keepends=True)
    starts: list[int] = []
    boundaries: list[int] = []
    fence: str | None = None
    for index, raw in enumerate(lines):
        stripped = raw.rstrip("\r\n")
        fence_match = FENCE_RE.match(stripped)
        if fence_match is not None:
            marker = fence_match.group("fence")
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence):
                fence = None
            continue
        if fence is not None:
            continue
        heading_match = H2_RE.match(stripped)
        if heading_match is None:
            continue
        boundaries.append(index)
        if heading_match.group("heading") == heading:
            starts.append(index)
    if len(starts) != 1:
        raise AssertionError(
            f"{label}: expected exactly one `## {heading}` section, found {len(starts)}"
        )
    start = starts[0]
    following = [index for index in boundaries if index > start]
    end = following[0] if following else len(lines)
    return fenced_blocks(
        "".join(lines[start:end]), f"{label} `## {heading}`", first_line=start + 1
    )


def _first_difference(copy: FencedBlock, origin: FencedBlock) -> str:
    """Describe the first way a mirrored block departs from its source.

    Args:
        copy: The block as written on the site page.
        origin: The README block it declares itself a mirror of.

    Returns:
        A one-line description of the first difference, so a red gate says what
        drifted instead of only that something did.
    """
    if copy.info != origin.info:
        return f"info string {copy.info!r} != README {origin.info!r}"
    pairs = zip_longest(copy.body.splitlines(), origin.body.splitlines())
    for number, (mirrored, source) in enumerate(pairs, start=1):
        if mirrored != source:
            return f"body line {number}: {mirrored!r} != README {source!r}"
    return "line endings differ"


def check_declarations(repo_root: Path = REPO_ROOT) -> None:
    """Assert the declaration table itself is well formed.

    Args:
        repo_root: Repository root the declarations are relative to.

    Raises:
        AssertionError: If a declaration names a page outside `SITE_PAGES`, if
            two declarations claim the same block on the same page, or if a
            declared page does not exist. A table that pairs one copy with two
            sources, or that names a page nothing else covers, would make the
            comparisons below mean less than they appear to.
    """
    seen: set[tuple[Path, int]] = set()
    for block in PARITY_BLOCKS:
        if block.page not in SITE_PAGES:
            raise AssertionError(
                f"{block.page} declares a parity block but is not a site page; "
                "add it to SITE_PAGES so its undeclared blocks are swept too"
            )
        key = (block.page, block.page_index)
        if key in seen:
            raise AssertionError(
                f"{block.page} block {block.page_index} is declared twice"
            )
        seen.add(key)
    for page in SITE_PAGES:
        path = repo_root / page
        if not path.is_file():
            raise AssertionError(f"site page {path} does not exist")


def check_parity_blocks(repo_root: Path = REPO_ROOT) -> None:
    """Assert every declared mirror still equals the README block it copies.

    Args:
        repo_root: Repository root holding the README and the site pages.

    Raises:
        AssertionError: If a mirrored block differs from its source in its info
            string or in any byte of its body, if the README section named by a
            declaration is missing, or if either ordinal names no block.
    """
    readme_path = repo_root / README_PATH
    readme_text = _read_text(readme_path)
    page_blocks: dict[Path, tuple[FencedBlock, ...]] = {}
    for block in PARITY_BLOCKS:
        if block.page not in page_blocks:
            page_blocks[block.page] = fenced_blocks(
                _read_text(repo_root / block.page), str(block.page)
            )
        mirrored = page_blocks[block.page]
        if block.page_index >= len(mirrored):
            raise AssertionError(
                f"{block.page} declares block {block.page_index} but holds only "
                f"{len(mirrored)}"
            )
        source = readme_section_blocks(
            readme_text, block.readme_section, str(README_PATH)
        )
        if block.readme_index >= len(source):
            raise AssertionError(
                f"{README_PATH} `## {block.readme_section}` holds only "
                f"{len(source)} blocks, but {block.page} declares its block "
                f"{block.page_index} a mirror of block {block.readme_index}"
            )
        copy = mirrored[block.page_index]
        origin = source[block.readme_index]
        if (copy.info, copy.body) != (origin.info, origin.body):
            raise AssertionError(
                f"documentation drift: {block.page}:{copy.line} (block "
                f"{block.page_index}) no longer mirrors {README_PATH}:"
                f"{origin.line}, block {block.readme_index} of "
                f"`## {block.readme_section}`: {_first_difference(copy, origin)}"
            )


def check_site_blocks_are_all_declared(repo_root: Path = REPO_ROOT) -> None:
    """Assert no site page shows a command or an output nobody declared.

    Comparing only the declared blocks would leave the obvious bypass open: a
    page could grow a second, undeclared copy of a command and pass. Every
    fenced block on every site page is therefore required to appear in
    `PARITY_BLOCKS`, which makes not declaring a copy a failure rather than an
    escape.

    Args:
        repo_root: Repository root holding the site pages.

    Raises:
        AssertionError: If a site page holds a fenced block that no declaration
            names.
    """
    declared = {(block.page, block.page_index) for block in PARITY_BLOCKS}
    for page in SITE_PAGES:
        blocks = fenced_blocks(_read_text(repo_root / page), str(page))
        undeclared = [
            f"{page}:{block.line} (block {index})"
            for index, block in enumerate(blocks)
            if (page, index) not in declared
        ]
        if undeclared:
            raise AssertionError(
                "undeclared fenced block on a site page: "
                + ", ".join(undeclared)
                + "; declare it in PARITY_BLOCKS as a mirror of the README block "
                "that owns it, or link to that section instead of copying it"
            )


def main() -> int:
    """Assert the site copies nothing it has not declared, and nothing stale.

    Returns:
        0 once every declaration is well formed, every declared mirror equals
        its README source byte for byte, and no site page holds an undeclared
        fenced block; printing how many mirrors were compared. 1 after printing
        the drift to stderr, so the policy run fails instead of publishing a
        page whose commands no longer match the ones this repository executes.
    """
    try:
        check_declarations()
        check_parity_blocks()
        check_site_blocks_are_all_declared()
    except AssertionError as exc:
        print(f"docs-parity-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"docs-parity-check: OK ({len(PARITY_BLOCKS)} mirrored blocks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
