#!/usr/bin/env python3
"""Hold every command and output on the documentation site to its README source.

The site exists to navigate a reader to documents that are already gated: the
command-line contract, the event-stream specification, the release runbook.
Five pages cannot do their job by navigation alone — a landing page has to
show how the package is installed, a five-minute path has to show a test file
and the run it produces, the continuous-integration page has to show the
workflow to paste, the run-report page has to show what the document it
describes actually looks like, and the shell-completion page has to show where
each shell wants the script written — and each of those is a command or a
captured output living somewhere other than the surface that owns it.

A second copy of a command is the defect this repository keeps finding. A copy
on a site page is executed by nothing and reviewed against nothing: it agrees
with the original on the day it is written and silently stops agreeing on the
day the original is corrected. Nothing would report it, because a page that
renders plausible output looks exactly like a page that renders true output.

So the site never gets a copy. It gets a declared mirror: `PARITY_BLOCKS` names
each fenced block on a page together with the README section and ordinal that
owns it, and this gate compares the two byte for byte, info string included, on
every policy run. Declaring the mirror is what buys the right to show the block
at all.

Parity is agreement with the README, which is a weaker claim than truth and is
stated that way deliberately. Only two parts of the README are executed against
a real binary: its command-line listing, compared to the built binary's own
help output, and its assertion example, run and matched against its documented
outcome. The install block and the first-run transcripts these pages mirror are
not among them, so this gate proves a page cannot drift from the README — not
that the README is right. Read a page's claim about its own guarantee against
that boundary.

Four further assertions stop the gate from being defeated by simply not using
it:

- every fenced block on every site page must be declared, so a block added to a
  page without a declaration fails rather than passing unexamined, and the two
  ways of reaching a reader with code that carries no fence — an unfenced
  indented block and a raw-HTML `<pre>`, `<code>` or `<textarea>` — are refused
  outright, because neither offers anything to declare;
- an index that names nothing — a page ordinal past the end, a README section
  that was renamed, an ordinal past the end of that section — fails rather than
  silently matching no block;
- every tracked page under `docs/` must be a declared site page or a named
  reference document, so a new page cannot be ungated from birth; and
- the site configuration must still exclude the internal working directories,
  must not re-include one through a gitignore-style negation, and must navigate
  only to declared pages.

The last two exist because a hand-written list gates only what someone
remembered. Inverting the question against the tracked-file inventory is the
same move `scripts/checks/version.py` makes for version literals, and for the
same reason: a page nobody declared is exactly the page nobody gated.

Scope boundary, stated rather than left to accident: this module reads fenced
blocks and indented code blocks. A command written into prose as an inline code
span is deliberately out of scope. Inline spans name flags, files and syntaxes
constantly (`--json`, `mtest.toml`, `hash:M/N`), and gating them would make
every sentence that names a flag a mirror declaration while catching nothing a
reader would copy and run. A command a reader is meant to execute belongs in a
block, and the blocks are what this gate covers.

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
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
README_PATH = Path("README.md")
MKDOCS_PATH = Path("mkdocs.yml")
DOCS_DIR = Path("docs")

SITE_PAGES = (
    Path("docs/index.md"),
    Path("docs/getting-started.md"),
    Path("docs/ci.md"),
    Path("docs/reports.md"),
    Path("docs/completions.md"),
)
"""Every documentation-site page allowed to render a command or an output.

A page here is a copy: it exists to walk a reader somewhere and shows blocks
that live elsewhere, so each of those blocks is declared in `PARITY_BLOCKS` and
compared to its source. Every page listed here must declare at least one, which
is what stops a page from being emptied of both its blocks and its declarations
and still passing.
"""

REFERENCE_PAGES = (
    Path("docs/cli-contract.md"),
    Path("docs/json-stream.md"),
    Path("docs/collect-stream.md"),
    Path("docs/compatibility.md"),
    Path("docs/releasing.md"),
)
"""Documents the site navigates to, which are originals rather than copies.

Excluded from parity by this explicit rule, not by being forgotten: parity is
agreement between a copy and the source it copied, and these five copy
nothing. Each is the surface that owns its own content — the frozen
command-line contract (whose documented behaviors the contract gate executes),
the two machine-format specifications, the toolchain-compatibility page that
describes what the compatibility canary probes and what its classifications
mean, and the release runbook — and the contract is a version-transcript site
in its own right.

Naming them is what lets the sweep below invert the question. Without an
explicit list, "not a site page" and "not gated at all" would be the same
answer, and a new page would be indistinguishable from a reference document.
"""

EXCLUDED_DOC_DIRECTORIES = ("plans/", "superpowers/")
"""Directories under `docs/` the site configuration must refuse to publish.

Both hold internal working material. `.gitignore` names them, but git ignores
only what is not already tracked, and one document under `docs/superpowers/`
predates the entry and is tracked to this day. mkdocs also builds from the
working tree rather than the index, so it would publish the ignored ones too.
The configuration's exclusion is therefore the only thing keeping either off a
public site, and this module asserts it rather than trusting it.
"""

NEGATION_PREFIX = "!"
"""How a gitignore-style pattern re-includes what an earlier one excluded.

`exclude_docs` is a gitignore-style list, so `plans/` followed by `!plans/`
excludes the directory and then puts it back. Checking only that the two
directory names appear leaves that one-line bypass open, and it reads as an
addition rather than as a deletion in a diff. This configuration has no use for
a re-inclusion at all, so any entry beginning with this prefix is refused
rather than analysed for which path it re-admits.
"""

FENCE_RE = re.compile(r"^(?P<indent>[ \t]*)(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
"""One fence line, opening or closing, at any indentation.

Indentation is captured rather than rejected. CommonMark accepts a fence
indented up to three spaces, and a fence inside a mkdocs-material admonition or
content tab MUST be indented four, which is the idiomatic way to put a command
inside a tip. Anchoring at column zero would have made every such block render
on the published page while remaining invisible here — a hole exactly the shape
of the one this module exists to close.
"""

INDENTED_CODE_INDENT = 4
"""Leading spaces that turn an unfenced line into a rendered code block."""

CONTAINER_OPENERS = ("!!!", "???", '=== "', "==- ", "==+ ")
"""Block-container openers whose indented body is content, not a code block.

An admonition, a collapsible block or a content tab indents everything it
contains. That indentation is the container's, so the body is ordinary
content; a command inside one still has to be fenced, and the fence is found
wherever it sits because `FENCE_RE` accepts indentation.
"""

CONTAINER_BODY_INDENT = 4
"""Leading spaces a block container gives its own body.

A container absorbs exactly this much indentation and no more. Anything deeper
is indentation the author added *inside* the body, which renders as a code
block there exactly as it would at the top level, so the two have to be told
apart rather than both waved through as "content".
"""

LIST_MARKER_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")
"""A list item, whose indented continuation lines are content, not code."""

RAW_HTML_CODE_RE = re.compile(r"(?i)<\s*(?:pre|code|textarea)\b")
"""A raw-HTML element that renders as code without being a fenced block.

Markdown passes raw HTML through, so `<pre>` reaches a reader as a code block
while carrying no fence for the scanner to find and no info string to declare —
the same hole an indented block opens, spelled differently. No site page uses
one today, so refusing them outright costs nothing and closes the shape.
"""

H2_RE = re.compile(r"^## (?P<heading>.+?)\s*$")
"""One README H2 heading, whose text names the section owning a source block."""

NAV_PAGE_RE = re.compile(r"(?P<page>[A-Za-z0-9_./-]+\.md)\s*$")
"""One page reference in the site configuration's navigation tree."""


@dataclass(frozen=True)
class _Fence:
    """One matched fence pair, as located by the single shared scanner.

    Attributes:
        open_index: Zero-based index of the opening fence line.
        close_index: Zero-based index of the closing fence line.
        info: The opening fence's info string, stripped.
        indent: The opening fence's exact leading whitespace, which the
            renderer removes from the body and which this module removes too.
    """

    open_index: int
    close_index: int
    info: str
    indent: str


@dataclass(frozen=True)
class FencedBlock:
    """One fenced block, as rendered.

    Attributes:
        info: The opening fence's info string, stripped of surrounding
            whitespace. Compared along with the body, because a block that
            changed language changed what it claims to be.
        body: The text between the fences with the fence's own indentation
            removed, so a block hosted inside an admonition still compares
            equal to the unindented block it mirrors. That is what the renderer
            does with the same bytes.
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
    # The five-minute path: the test file a reader saves, the command that
    # writes it for them, the passing run, and the compile error a wrong
    # import produces.
    ParityBlock(Path("docs/getting-started.md"), 0, "Your first test", 0),
    ParityBlock(Path("docs/getting-started.md"), 1, "Your first test", 1),
    ParityBlock(Path("docs/getting-started.md"), 2, "Your first test", 2),
    ParityBlock(Path("docs/getting-started.md"), 3, "Your first test", 3),
    # The workflow to paste, the sharded variant of it, and the composite
    # action that replaces the invocation step in either.
    ParityBlock(Path("docs/ci.md"), 0, "Run it in CI", 0),
    ParityBlock(Path("docs/ci.md"), 1, "Run it in CI", 1),
    ParityBlock(Path("docs/ci.md"), 2, "Run it in CI", 2),
    # The run report: the invocation that writes both formats, and the three
    # parts of the document a reader is shown — the summary table, one file
    # section with its root-relative backtrace, and the machine index.
    ParityBlock(Path("docs/reports.md"), 0, "Run reports", 0),
    ParityBlock(Path("docs/reports.md"), 1, "Run reports", 1),
    ParityBlock(Path("docs/reports.md"), 2, "Run reports", 2),
    ParityBlock(Path("docs/reports.md"), 3, "Run reports", 3),
    # Installing a completion script: the two bash routes, the zsh file and
    # the `.zshrc` lines that put its directory on `$fpath` before `compinit`,
    # and the fish redirect.
    ParityBlock(Path("docs/completions.md"), 0, "Shell completion", 0),
    ParityBlock(Path("docs/completions.md"), 1, "Shell completion", 1),
    ParityBlock(Path("docs/completions.md"), 2, "Shell completion", 2),
    ParityBlock(Path("docs/completions.md"), 3, "Shell completion", 3),
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


def _tracked_files(repo_root: Path) -> tuple[Path, ...]:
    """List every file git tracks in one repository, as relative paths.

    Reads the index rather than walking the filesystem, so an untracked draft
    under `docs/` cannot make this gate red and a linked worktree cannot make
    it read one file set locally and another on CI.

    Args:
        repo_root: Repository root to enumerate.

    Returns:
        One relative path per tracked file.

    Raises:
        AssertionError: If git is unavailable or the directory is not a
            repository. Without an inventory the sweep cannot tell an
            undeclared page from an empty tree, so it fails closed.
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
    return tuple(Path(name) for name in completed.stdout.split("\0") if name)


def _scan_fences(lines: list[str], label: str) -> tuple[_Fence, ...]:
    """Locate every fence pair in one document.

    One scanner, used by both the block reader and the section splitter, so the
    two can never disagree about which lines are inside a fence and therefore
    about where a section begins.

    Args:
        lines: The document's lines, line endings included.
        label: How to name the document in a failure message.

    Returns:
        One `_Fence` per pair, in document order.

    Raises:
        AssertionError: If a fence is opened and never closed. An unterminated
            fence makes every later ordinal mean something different, so the
            gate refuses rather than compare against a shifted list.
    """
    fences: list[_Fence] = []
    opening: re.Match[str] | None = None
    opened_at = 0
    for index, raw in enumerate(lines):
        match = FENCE_RE.match(raw.rstrip("\r\n"))
        if match is None:
            continue
        if opening is None:
            opening = match
            opened_at = index
            continue
        marker = opening.group("fence")
        closes = match.group("fence")
        # A closing fence is the same character, at least as long, and carries
        # no info string: ```` ```console ```` inside a block is content.
        if (
            closes[0] != marker[0]
            or len(closes) < len(marker)
            or match.group("info").strip()
        ):
            continue
        fences.append(
            _Fence(
                open_index=opened_at,
                close_index=index,
                info=opening.group("info").strip(),
                indent=opening.group("indent"),
            )
        )
        opening = None
    if opening is not None:
        raise AssertionError(
            f"{label}: fence opened at line {opened_at + 1} is never closed"
        )
    return tuple(fences)


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
        One `FencedBlock` per fence pair, in document order, each body dedented
        by its own fence's indentation.

    Raises:
        AssertionError: If a fence is opened and never closed.
    """
    lines = text.splitlines(keepends=True)
    return tuple(
        FencedBlock(
            info=fence.info,
            body="".join(
                line.removeprefix(fence.indent)
                for line in lines[fence.open_index + 1 : fence.close_index]
            ),
            line=first_line + fence.open_index,
        )
        for fence in _scan_fences(lines, label)
    )


def indented_code_lines(text: str, label: str) -> tuple[int, ...]:
    """Return the one-based line numbers of unfenced indented code blocks.

    Four spaces of indentation after a blank line render as a code block, so a
    command written that way reaches a reader exactly as a fenced one does
    while carrying no info string and no fence for the scanner to find. Rather
    than mirror-declare a construct that cannot state its own language, the
    site refuses it and the author writes a fence.

    Two indented constructs are content rather than code and are not reported:
    the continuation of a list item, and the body of a block container such as
    an admonition or a content tab. A command inside either still has to be
    fenced, and `FENCE_RE` finds that fence at whatever depth it sits.

    Each of those absorbs a known amount of indentation and no more — a list
    item as far as its own marker runs, a container `CONTAINER_BODY_INDENT` —
    which fixes a body column, and code is measured from that column rather
    than from column zero. The column belongs to the opener, not to the line
    before, so it survives the blank lines *inside* the body: a container's
    second and later paragraphs are content on exactly the terms its first one
    is. It is surrendered only when content appears to the left of it, which is
    where that body ended.

    Waving a line through for merely sitting under an opener is how an
    undeclared command reaches a reader, so the column is a floor and not an
    amnesty: four further spaces inside a list item or a container render as a
    code block on the published page just as they would at the top level, and
    are reported there too.

    Args:
        text: The document text to scan.
        label: How to name the document in a failure message.

    Returns:
        The one-based line number of each offending line, in document order.

    Raises:
        AssertionError: If a fence is opened and never closed.
    """
    lines = text.splitlines(keepends=True)
    fences = _scan_fences(lines, label)
    inside = {
        index
        for fence in fences
        for index in range(fence.open_index, fence.close_index + 1)
    }
    opener_indents = {fence.open_index: len(fence.indent) for fence in fences}
    offending: list[int] = []
    previous_blank = True
    body_indent = 0
    for index, raw in enumerate(lines):
        stripped = raw.rstrip("\r\n")
        if index in inside:
            # A fenced block's own lines are declared code and say nothing
            # about the surrounding body, but where its opening fence sits
            # does: a fence to the left of the current column closes the body
            # it was tracking, and skipping the whole block would carry a
            # stale column past the end of the container it came from.
            if index in opener_indents:
                body_indent = min(body_indent, opener_indents[index])
            previous_blank = False
            continue
        if not stripped.strip():
            previous_blank = True
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        if previous_blank and indent >= body_indent + INDENTED_CODE_INDENT:
            offending.append(index + 1)
        body_indent = _body_indent(stripped, body_indent)
        previous_blank = False
    return tuple(offending)


def _body_indent(line: str, current: int) -> int:
    """Return the body column in force after one content line.

    Args:
        line: A non-blank line outside every fence, with its line ending
            removed.
        current: The body column in force before this line.

    Returns:
        The column at which the enclosing body's content starts, so that
        `INDENTED_CODE_INDENT` beyond it renders as a code block. A list item
        and a block container each open a body and shift the column right by
        what they absorb. Any other line keeps the column while it stays
        inside that body, and gives it up for its own indentation when it sits
        to the left of it, because content there is no longer in the body the
        opener started.
    """
    marker = LIST_MARKER_RE.match(line)
    if marker is not None:
        return len(marker.group(0))
    indent = len(line) - len(line.lstrip(" "))
    if line.strip().startswith(CONTAINER_OPENERS):
        return indent + CONTAINER_BODY_INDENT
    return min(current, indent)


def raw_html_code_lines(text: str, label: str) -> tuple[int, ...]:
    """Return the one-based line numbers of raw-HTML code containers.

    Markdown passes raw HTML straight through, so `<pre>`, `<code>` and
    `<textarea>` reach the reader as code while the fence scanner sees nothing:
    no fence to locate, no info string to compare, nothing to declare. That is
    the same escape an indented block opens, in a spelling the indentation rule
    cannot see.

    Args:
        text: The document text to scan.
        label: How to name the document in a failure message.

    Returns:
        The one-based line number of each offending line, in document order.

    Raises:
        AssertionError: If a fence is opened and never closed. Raw HTML written
            *inside* a fenced block is that block's content, so the fences have
            to be located before anything can be reported.
    """
    lines = text.splitlines(keepends=True)
    inside = {
        index
        for fence in _scan_fences(lines, label)
        for index in range(fence.open_index, fence.close_index + 1)
    }
    return tuple(
        index + 1
        for index, raw in enumerate(lines)
        if index not in inside and RAW_HTML_CODE_RE.search(raw)
    )


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
    inside = {
        index
        for fence in _scan_fences(lines, label)
        for index in range(fence.open_index, fence.close_index + 1)
    }
    starts: list[int] = []
    boundaries: list[int] = []
    for index, raw in enumerate(lines):
        if index in inside:
            continue
        heading_match = H2_RE.match(raw.rstrip("\r\n"))
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
            two declarations claim the same block on the same page, if a site
            page declares no block or declares a non-contiguous run of them, or
            if a declared page does not exist. The floor matters as much as the
            table: without it, deleting a page's blocks together with their
            declarations would leave an empty page passing green.
    """
    declared: dict[Path, set[int]] = {}
    for block in PARITY_BLOCKS:
        if block.page not in SITE_PAGES:
            raise AssertionError(
                f"{block.page} declares a parity block but is not a site page; "
                "add it to SITE_PAGES so its undeclared blocks are swept too"
            )
        indices = declared.setdefault(block.page, set())
        if block.page_index in indices:
            raise AssertionError(
                f"{block.page} block {block.page_index} is declared twice"
            )
        indices.add(block.page_index)
    for page in SITE_PAGES:
        path = repo_root / page
        if not path.is_file():
            raise AssertionError(f"site page {path} does not exist")
        indices = declared.get(page, set())
        if not indices:
            raise AssertionError(
                f"{page} is a site page that declares no mirrored block; a page "
                "showing nothing gated has no reason to be a site page"
            )
        if indices != set(range(len(indices))):
            raise AssertionError(
                f"{page} declares block ordinals {sorted(indices)}, which are not "
                "the leading run 0..n-1 the page's blocks are numbered by"
            )


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
    escape, and the two constructs that render as code without being a fence —
    an unfenced indented block and a raw-HTML container — are refused outright
    because each reaches the reader the same way while offering nothing to
    declare.

    Args:
        repo_root: Repository root holding the site pages.

    Raises:
        AssertionError: If a site page holds a fenced block that no declaration
            names, an indented code block, or a raw-HTML code container.
    """
    declared = {(block.page, block.page_index) for block in PARITY_BLOCKS}
    for page in SITE_PAGES:
        text = _read_text(repo_root / page)
        blocks = fenced_blocks(text, str(page))
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
        indented = indented_code_lines(text, str(page))
        if indented:
            raise AssertionError(
                "indented code block on a site page: "
                + ", ".join(f"{page}:{number}" for number in indented)
                + "; it renders as code but carries no fence to declare, so write "
                "it as a fenced block and mirror it, or as ordinary prose"
            )
        raw_html = raw_html_code_lines(text, str(page))
        if raw_html:
            raise AssertionError(
                "raw-HTML code container on a site page: "
                + ", ".join(f"{page}:{number}" for number in raw_html)
                + "; markdown passes it through to the reader as code while this "
                "gate sees no fence and no info string, so write it as a fenced "
                "block and mirror it"
            )


def check_no_undeclared_pages(repo_root: Path = REPO_ROOT) -> None:
    """Assert every tracked page under `docs/` is declared as one kind or other.

    `SITE_PAGES` is hand-written, so on its own it gates the pages someone
    remembered. A page added tomorrow, navigated to and full of commands, would
    satisfy every check above by declaring nothing at all. This inverts the
    question the way the version gate does: each tracked Markdown document
    under `docs/` is either a site page whose blocks are mirrored, or a named
    reference document that owns its content, and anything else fails until
    someone decides which it is.

    Args:
        repo_root: Repository root to sweep.

    Raises:
        AssertionError: If a tracked page at the top level of `docs/` is
            neither a site page nor a reference document, if a declared page is
            no longer tracked, or if a tracked page in a subdirectory of
            `docs/` is not inside a directory the site configuration excludes.
    """
    declared = set(SITE_PAGES) | set(REFERENCE_PAGES)
    tracked = {
        path
        for path in _tracked_files(repo_root)
        if path.suffix == ".md" and path.parts[:1] == (DOCS_DIR.name,)
    }
    top_level = {path for path in tracked if len(path.parts) == 2}
    undeclared = top_level - declared
    if undeclared:
        raise AssertionError(
            "undeclared documentation page in "
            + ", ".join(sorted(str(path) for path in undeclared))
            + "; add it to SITE_PAGES and declare its blocks in PARITY_BLOCKS, or "
            "to REFERENCE_PAGES if it owns its content rather than copying any"
        )
    missing = declared - top_level
    if missing:
        raise AssertionError(
            "declared documentation page is not tracked: "
            + ", ".join(sorted(str(path) for path in missing))
        )
    published = sorted(
        str(path)
        for path in tracked - top_level
        if not any(
            str(path).startswith(f"{DOCS_DIR.name}/{excluded}")
            for excluded in EXCLUDED_DOC_DIRECTORIES
        )
    )
    if published:
        raise AssertionError(
            "tracked page under docs/ that the site would publish and nothing "
            "declares: " + ", ".join(published)
        )


def _site_configuration(repo_root: Path) -> tuple[dict[str, str], list[str], list[str]]:
    """Parse the site configuration without taking on a YAML dependency.

    Args:
        repo_root: Repository root holding the configuration.

    Returns:
        The top-level scalar settings, the entries of the `exclude_docs` block
        literal, and every page named in the navigation tree, in order.

    Raises:
        AssertionError: If the configuration cannot be read.
    """
    lines = _read_text(repo_root / MKDOCS_PATH).splitlines()
    scalars: dict[str, str] = {}
    excluded: list[str] = []
    nav: list[str] = []
    section = ""
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not raw[:1].isspace():
            key, _, value = stripped.partition(":")
            section = key
            if value.strip() and value.strip() != "|":
                scalars[key] = value.strip()
            continue
        if section == "exclude_docs":
            excluded.append(stripped)
        elif section == "nav":
            match = NAV_PAGE_RE.search(stripped)
            if match is not None:
                nav.append(match.group("page"))
    return scalars, excluded, nav


def check_site_configuration(repo_root: Path = REPO_ROOT) -> None:
    """Assert the site publishes the declared pages and nothing internal.

    Deleting two lines from the configuration republishes every internal
    working document under `docs/`, including one that is tracked and would
    therefore be published from a clean checkout. Nothing else in the tree
    would notice, so the exclusion is asserted here as content rather than
    trusted as configuration.

    Args:
        repo_root: Repository root holding the site configuration.

    Raises:
        AssertionError: If an internal directory is no longer excluded, if the
            build output would land outside the ignored build directory, or if
            the navigation names a page that is neither a site page nor a
            reference document, or omits a site page.
    """
    scalars, excluded, nav = _site_configuration(repo_root)
    if scalars.get("docs_dir") != DOCS_DIR.name:
        raise AssertionError(
            f"{MKDOCS_PATH} must build from {DOCS_DIR.name}/, not "
            f"{scalars.get('docs_dir')!r}"
        )
    site_dir = scalars.get("site_dir", "")
    if not site_dir.startswith("build/"):
        raise AssertionError(
            f"{MKDOCS_PATH} must build into build/, which is ignored; a build "
            f"into {site_dir!r} leaves the tree dirty for the format gate"
        )
    missing = [name for name in EXCLUDED_DOC_DIRECTORIES if name not in excluded]
    if missing:
        raise AssertionError(
            f"{MKDOCS_PATH} no longer excludes " + ", ".join(missing) + " from the "
            "built site; those directories hold internal working material and "
            "mkdocs builds from the working tree, so the site would publish it"
        )
    re_included = [name for name in excluded if name.startswith(NEGATION_PREFIX)]
    if re_included:
        raise AssertionError(
            f"{MKDOCS_PATH} re-includes " + ", ".join(re_included) + " into the "
            "built site; `exclude_docs` is gitignore-style, so a negation puts "
            "back what an earlier line excluded while leaving that line in place"
        )
    declared = {path.name for path in (*SITE_PAGES, *REFERENCE_PAGES)}
    unknown = [name for name in nav if name not in declared]
    if unknown:
        raise AssertionError(
            f"{MKDOCS_PATH} navigates to undeclared pages: " + ", ".join(unknown)
        )
    absent = [page.name for page in SITE_PAGES if page.name not in nav]
    if absent:
        raise AssertionError(
            f"{MKDOCS_PATH} does not navigate to site pages: " + ", ".join(absent)
        )


def main() -> int:
    """Assert the site copies nothing it has not declared, and nothing stale.

    Returns:
        0 once every declaration is well formed, every declared mirror equals
        its README source byte for byte, no site page holds an undeclared or
        unfenced block, every tracked page is declared, and the configuration
        still excludes the internal directories; printing how many mirrors were
        compared. 1 after printing the drift to stderr, so the policy run fails
        instead of publishing a page whose commands no longer match the ones
        this repository executes.
    """
    try:
        check_declarations()
        check_parity_blocks()
        check_site_blocks_are_all_declared()
        check_no_undeclared_pages()
        check_site_configuration()
    except AssertionError as exc:
        print(f"docs-parity-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"docs-parity-check: OK ({len(PARITY_BLOCKS)} mirrored blocks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
