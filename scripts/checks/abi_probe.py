#!/usr/bin/env python3
r"""Forbid two test-tree files from declaring the same `external_call` symbol.

Building the classified modules under `tests/unit` and `tests/integration` as
independent binaries lost a property the old single aggregate binary gave for
free. Two modules declaring the same `external_call` symbol were always
co-linked, so a signature or arity drift between them was an archive-time
compiler error. Built alone, each module holds the only declaration of its own
symbols in its translation unit, and a drift now compiles, links, and produces
silent garbage at the ABI boundary. This is a recorded defect class here; see
`.agents/lessons.md` ("Mojo language, pinned toolchain"). The ASan and Valgrind
lanes do not close the gap either, since they always built one classified file
at a time.

An earlier version of this gate re-created the lost co-link: it grouped the
modules sharing a symbol, generated an entrypoint importing all of them, and let
the compiler report a disagreement as a link error. That worked, at the cost of
a real `mojo`, the precompiled package, and the native test object on the hosted
preflight path, to establish a property about text.

It now forbids the shape instead of compiling it. Every foreign symbol more than
one suite needs is declared once, in `tests/support/foreign_abi.mojo`, and each
suite calls it through that wrapper. The check fails when any symbol is declared
in two files anywhere under `tests/`, `tests/support` included. The guarantee
changes with it: co-linking proved that N declarations AGREED and said nothing
about whether all N were wrong the same way, whereas requiring N to be one
leaves a single declaration to review against the C header. A symbol exactly one
file declares is left alone, because nothing can drift from it.

The universe is the whole test tree rather than the classified roots;
`declaring_sources` records what went wrong when it was not. `e2e/` stays out of
scope, as that corpus is standalone hostile programs rather than test-tree code
and holds duplicate declarations of its own this gate has never covered.

A declaration is matched over its complete bracketed span (`external_call[...]`)
rather than one line, since the symbol name legitimately sits on a continuation
line in this codebase (`external_call[\n    "sym", Int32\n]`). A span counts
only when no quote is still open AT THE OFFSET where it begins, which is what
excludes the generated Mojo source several suites embed as line-by-line string
literals. See `_opens_inside_string_literal` and `_bracket_span`.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
SEARCH_ROOT = ROOT / "tests"
# Repo-relative on purpose: it appears only in a diagnostic, and resolving it
# against ROOT would break the moment a test points ROOT at a fixture tree.
SHARED_HOME = "tests/support/foreign_abi.mojo"

_EXTERNAL_CALL_OPEN_RE = re.compile(r"external_call\[")
_SYMBOL_IN_SPAN_RE = re.compile(r'"([A-Za-z0-9_]+)"')


def require(condition: bool, message: str) -> None:
    """Fail the gate with one actionable diagnostic."""
    if not condition:
        raise SystemExit(f"abi-probe-check: {message}")


def _opens_inside_string_literal(line: str, column: int) -> bool:
    r"""Whether `line[column]` sits inside a quoted literal rather than code.

    Decided at the match offset by tracking quotes to its left, rather than from
    the line's first character. A first-character test drops a real declaration
    that merely follows a complete string on its line:

        "expected", String(external_call["getpid", Int32]()),

    Equivalent to an odd-quote count over `line[:column]`, but scanned so it
    agrees with the language where a raw count would not: a quote of the other
    kind inside a literal (`"it's"`) opens nothing, and a backslash-escaped
    quote (`\"`) closes nothing.

    A lexical test over one line, not a Mojo parser. It does not model
    triple-quoted strings, which no `external_call` in this tree sits inside; a
    declaration written inside one reads as code, which can only make this check
    stricter than the language.

    Args:
        line: One complete physical line, without its newline.
        column: The offset within `line` of the `external_call` match.

    Returns:
        True when a quote is still open at `column`.
    """
    quote: str | None = None
    index = 0
    limit = min(column, len(line))
    while index < limit:
        char = line[index]
        if quote is not None:
            if char == "\\":
                index += 2
                continue
            if char == quote:
                quote = None
        elif char in ("'", '"'):
            quote = char
        index += 1
    return quote is not None


def _line_and_column(text: str, index: int) -> tuple[str, int]:
    """Return the physical line of `text` at `index`, and the offset within it.

    Args:
        text: The complete file text.
        index: An offset into `text`.

    Returns:
        The complete line containing `index`, without its newline, and the
        zero-based column of `index` within that line.
    """
    line_start = text.rfind("\n", 0, index) + 1
    line_end = text.find("\n", index)
    if line_end == -1:
        line_end = len(text)
    return text[line_start:line_end], index - line_start


def _bracket_span(text: str, open_index: int) -> str:
    """Return the bracketed span of `text` starting at `text[open_index] == "["`.

    Depth-counts `[`/`]` rather than stopping at the first `]`, so a nested
    bracket inside the parameter list (a generic return type, say) does not
    truncate the scan before the declaration's own closing bracket.

    Args:
        text: The complete file text.
        open_index: The offset of one `external_call[`'s opening `[`.

    Returns:
        The substring from `open_index` through its matching `]`, inclusive,
        however many physical lines it spans.

    Raises:
        ValueError: No matching `]` appears before EOF. An unbalanced
            declaration is a source-file defect worth failing loudly on.
    """
    depth = 0
    for offset in range(open_index, len(text)):
        char = text[offset]
        if char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return text[open_index : offset + 1]
    raise ValueError(f"unbalanced external_call[ at offset {open_index}")


def declared_symbols(source: Path) -> set[str]:
    r"""Return every symbol `source` declares as a real `external_call` site.

    Matches each occurrence's complete bracketed span rather than one line, so a
    declaration whose symbol sits on a continuation line is still found. Only
    the offset that OPENS the span is checked for string-literal exclusion; see
    `_opens_inside_string_literal`.

    Args:
        source: A classified `test_*.mojo` module.

    Returns:
        The distinct `external_call["symbol", ...]` names invoked as real code
        in `source`, excluding any span whose opening line is fixture data.
    """
    text = source.read_text(encoding="utf-8")
    symbols: set[str] = set()
    for match in _EXTERNAL_CALL_OPEN_RE.finditer(text):
        line, column = _line_and_column(text, match.start())
        if _opens_inside_string_literal(line, column):
            continue
        span = _bracket_span(text, match.end() - 1)
        symbol_match = _SYMBOL_IN_SPAN_RE.search(span)
        if symbol_match is not None:
            symbols.add(symbol_match.group(1))
    return symbols


def declaring_sources() -> list[Path]:
    """Return every Mojo file under `tests/`, bytewise sorted by path.

    The WHOLE test tree, not the classified roots alone. Scanning only
    `tests/unit` and `tests/integration` left `tests/support/foreign_abi.mojo`
    outside the comparison, so a suite that re-declared a symbol that file
    already owns was the only declarer among the modules compared, and passed.
    Verified on this checkout by appending a second `waitpid` declaration to a
    classified module and watching this gate print OK.

    `e2e/` stays outside: hostile standalone programs, unreachable from
    `tests/support`, holding duplicate declarations of their own.

    Every `.mojo` file counts, not only `test_*.mojo`. A support module, a
    protocol fixture, or a native control program can each hold a declaration.

    Raises:
        SystemExit: The test tree holds no Mojo file at all, which would mean it
            has moved out from under this check.
    """
    found = sorted(SEARCH_ROOT.rglob("*.mojo"))
    require(bool(found), "no Mojo sources found under tests/")
    return found


def shared_symbol_files(sources: list[Path]) -> dict[str, list[Path]]:
    """Group classified sources by every `external_call` symbol 2+ declare.

    Args:
        sources: Every test-tree Mojo file to scan.

    Returns:
        Only the violations: symbols with two or more declaring files, each
        mapped to its sorted list of sources. A symbol one file declares carries
        no cross-file drift risk, since nothing else can disagree with it.
    """
    by_symbol: dict[str, list[Path]] = {}
    for source in sources:
        for symbol in declared_symbols(source):
            by_symbol.setdefault(symbol, []).append(source)
    return {
        symbol: sorted(files) for symbol, files in by_symbol.items() if len(files) > 1
    }


def violation_report(shared: dict[str, list[Path]]) -> str:
    """Render every multiply-declared symbol as one actionable diagnostic.

    Args:
        shared: The violations, as `shared_symbol_files` returns them.

    Returns:
        A message naming each symbol, the modules that declare it, and where
        the single declaration belongs instead.
    """
    headline = (
        "an external_call symbol is declared in more than one test-tree "
        "file. Two files that are never compiled into one binary have their "
        "declarations compared by nothing, so a disagreement in arity or "
        "parameter type between them is silent garbage at the ABI boundary "
        "rather than a compile error. Declare each of these exactly once in "
        f"{SHARED_HOME}, with its own SAFETY proof, and call it from every "
        "suite that needs it:"
    )
    lines = [headline]
    for symbol, files in sorted(shared.items()):
        names = ", ".join(source.relative_to(ROOT).as_posix() for source in files)
        lines.append(f"  {symbol}: {names}")
    return "\n".join(lines)


def main() -> int:
    """Require every `external_call` symbol to have exactly one declarer.

    Returns:
        0 when no test-tree file declares a symbol another one also declares.

    Raises:
        SystemExit: The test tree holds no Mojo source, or a symbol is
            declared in two or more files.
    """
    sources = declaring_sources()
    shared = shared_symbol_files(sources)
    require(not shared, violation_report(shared))

    declared = sorted(
        {symbol for source in sources for symbol in declared_symbols(source)}
    )
    print(
        f"abi-probe-check: OK -- {len(sources)} test-tree module(s) scanned, "
        f"{len(declared)} external_call symbol(s) declared, none twice"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
