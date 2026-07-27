#!/usr/bin/env python3
r"""Catch cross-module `external_call` arity/signature drift at build time.

Splitting the 101 classified modules under `tests/unit` and `tests/integration`
into 101 independently built binaries lost a property the old single aggregate
binary provided for free: whenever two classified modules declared the same
`external_call` symbol, they were always co-linked into ONE binary regardless,
so a signature or arity drift between the two declarations was an ARCHIVE-TIME
compiler error. Built alone, each module is now the only declaration of its own
symbols in its translation unit -- a drift between two modules' declarations of
the same symbol compiles, links, and produces silent garbage at the ABI
boundary instead of failing. This is a recorded defect class in this project;
see `.agents/lessons.md` ("Mojo language, pinned toolchain": two call sites for
the same libc symbol must match arity, and the error surfaces at archive time
from an unrelated file). `scripts/checks/memory/asan.py` and
`scripts/checks/memory/valgrind.py` do not close this gap either -- they always
built one classified file at a time, even before the aggregate wrapper was
removed from them.

This probe re-creates the co-linked property for exactly the modules that need
it, without recreating the full 101-module aggregate: it scans every classified
`test_*.mojo` module for real `external_call["symbol", ...]` declarations,
groups them by symbol name, and -- for every symbol two or more modules
declare -- generates one small entrypoint that imports every one of those
modules, registers each of their `test_*` functions so nothing is dropped as
unreferenced, and builds it. Mojo's own compiler is the oracle: if any two
declarations of a shared symbol disagree, the build fails with a specific,
compiler-authored diagnostic naming the conflict. The binary is never
executed -- the archive-time link is the whole proof, and this probe has
nothing to say about runtime behavior.

The entrypoint generator lives here rather than in a shared harness module
because this probe is its only consumer.

A declaration is matched over its complete bracketed span
(`external_call[...]`), not one line: the symbol name legitimately sits on a
continuation line in this codebase (`external_call[\n    "sym", Int32\n]`),
and a scan that required the symbol on the same line as `external_call[`
would silently miss it. A span is counted as a real declaration only if the
line that OPENS it is not itself string data: several classified suites embed
generated Mojo source as line-by-line string literals to write out and
compile as a throwaway fixture elsewhere (the same pattern
`asan.py`/`valgrind.py`'s own `CLI_PROBE_SOURCE` uses), and by that same
convention every physical line of such a fixture is its own quoted literal --
including the line that would otherwise open a real span -- so checking only
the opening line is sufficient to exclude the whole fixture span, however
many lines it happens to spread across. A naive text search over
`external_call["sym"` matches those lines too, but they are never compiled as
part of the module that contains them, so co-linking on their account would
prove nothing. See `_is_string_literal_line` and `_bracket_span`.
"""

from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build" / "safety" / "abi_probe"
NATIVE_TEST_OBJECT = ROOT / "build" / "native" / "mtest_exec_native_test.o"
SEARCH_ROOTS = (ROOT / "tests" / "unit", ROOT / "tests" / "integration")

_EXTERNAL_CALL_OPEN_RE = re.compile(r"external_call\[")
_SYMBOL_IN_SPAN_RE = re.compile(r'"([A-Za-z0-9_]+)"')
_TEST_DEF_RE = re.compile(r"(?m)^def (test_[A-Za-z0-9_]+)\s*\(")
_MODULE_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def require(condition: bool, message: str) -> None:
    """Fail the gate with one actionable diagnostic."""
    if not condition:
        raise SystemExit(f"abi-probe-check: {message}")


def _is_string_literal_line(line: str) -> bool:
    """Whether `line` opens (once stripped) with a quote -- string data, not code.

    A real `external_call` invocation's opening line always starts with code:
    `_ = external_call[...]`, `var x = external_call[...]`, and
    `return external_call[...]` are the three shapes this project uses, and
    none of them opens with a quote character. A line that IS one fragment of
    a hand-built string literal (used elsewhere to write out a throwaway
    fixture source) opens with the quote that starts or continues the
    literal -- and, by that same fixture-writing convention, so does every
    other physical line the fixture spans, which is why checking only the
    line that opens an `external_call[` span is enough. This is a per-line
    heuristic, not a parser, and it is only asked to distinguish these two
    shapes -- it is not a general Mojo string detector.
    """
    return line.strip()[:1] in ("'", '"')


def _opening_line(text: str, index: int) -> str:
    """Return the complete physical line of `text` containing offset `index`."""
    line_start = text.rfind("\n", 0, index) + 1
    line_end = text.find("\n", index)
    if line_end == -1:
        line_end = len(text)
    return text[line_start:line_end]


def _bracket_span(text: str, open_index: int) -> str:
    """Return the bracketed span of `text` starting at `text[open_index] == "["`.

    Depth-counts `[`/`]` rather than stopping at the first `]`, so a nested
    bracket inside the parameter list (a generic return type, say) does not
    truncate the scan before the declaration's own closing bracket.

    Args:
        text: The complete file text.
        open_index: The offset of one `external_call[`'s opening `[`.

    Returns:
        The substring from `open_index` through its matching `]`, inclusive
        -- regardless of how many physical lines it spans.

    Raises:
        ValueError: No matching `]` appears before EOF. An unbalanced
            declaration is a source-file defect worth failing loudly on, not
            silently scanning past.
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

    Matches over each occurrence's complete bracketed span rather than one
    line, so a declaration whose symbol sits on a continuation line --
    `external_call[\\n    "sym", Int32\\n](...)`, a real, legitimate shape in
    this codebase -- is still found. Only the line that OPENS the span is
    checked for string-literal exclusion; see `_is_string_literal_line`.

    Args:
        source: A classified `test_*.mojo` module.

    Returns:
        The distinct `external_call["symbol", ...]` names invoked as real
        code in `source`, excluding any span whose opening line is itself
        string-literal fixture data.
    """
    text = source.read_text(encoding="utf-8")
    symbols: set[str] = set()
    for match in _EXTERNAL_CALL_OPEN_RE.finditer(text):
        if _is_string_literal_line(_opening_line(text, match.start())):
            continue
        span = _bracket_span(text, match.end() - 1)
        symbol_match = _SYMBOL_IN_SPAN_RE.search(span)
        if symbol_match is not None:
            symbols.add(symbol_match.group(1))
    return symbols


def classified_sources() -> list[Path]:
    """Return every classified `test_*.mojo` module, bytewise sorted.

    Raises:
        SystemExit: Neither search root has a single classified module. That
            would mean the tree has moved out from under this probe, not that
            there is genuinely nothing to guard.
    """
    found = [
        path
        for root in SEARCH_ROOTS
        for path in sorted(root.glob("test_*.mojo"), key=lambda p: p.name)
    ]
    require(bool(found), "no classified test_*.mojo modules found")
    return found


def shared_symbol_files(sources: list[Path]) -> dict[str, list[Path]]:
    """Group classified sources by every `external_call` symbol 2+ declare.

    Args:
        sources: Every classified module to scan.

    Returns:
        Only the symbols with two or more declaring modules, each mapped to
        its sorted list of declaring sources. A symbol only one module
        declares carries no cross-module drift risk: nothing else can
        disagree with it.
    """
    by_symbol: dict[str, list[Path]] = {}
    for source in sources:
        for symbol in declared_symbols(source):
            by_symbol.setdefault(symbol, []).append(source)
    return {
        symbol: sorted(files) for symbol, files in by_symbol.items() if len(files) > 1
    }


def affected_sources(shared: dict[str, list[Path]]) -> list[Path]:
    """Return the deduplicated, sorted union of every module in any group."""
    union: set[Path] = set()
    for files in shared.values():
        union.update(files)
    return sorted(union)


def test_function_names(source: str) -> list[str]:
    """Return every top-level `test_*` function declared in `source`, in order.

    Registering these is what keeps each co-linked module's code reachable:
    an `external_call` declaration sits inside a function body, and a body
    nothing references need never be compiled at all, which would make the
    co-link prove nothing about it.

    There is deliberately no rejection of a module that declares zero test
    functions here. That property belongs to the real suite and
    `scripts/harness/selfhost.py`'s oracle owns it, reconciling mtest's report
    against a source-derived inventory per file and per test name. This probe
    only needs to co-link, and a module with no test functions is a module
    with no `external_call` in a test body, so it never reaches this scan.

    Args:
        source: The complete text of one classified `test_*.mojo` module.

    Returns:
        The declared function names in source order, possibly empty.
    """
    return _TEST_DEF_RE.findall(source)


def _module_name(source: Path) -> str:
    """Return the dotted Mojo module name for one classified source.

    The generated entrypoint is built with `-I .` from the repository root,
    so a module is named by its repository-relative path with separators
    turned into dots: `tests/unit/test_config.mojo` is `tests.unit.test_config`.

    Args:
        source: A classified `test_*.mojo` module, inside the repository.

    Returns:
        The dotted module name an `import` statement can name.

    Raises:
        SystemExit: The path lies outside the repository, or a path component
            is not a legal Mojo identifier, so no import could name it.
    """
    try:
        relative = source.resolve().relative_to(ROOT)
    except ValueError:
        raise SystemExit(
            f"abi-probe-check: classified module outside the repository: {source}"
        ) from None
    parts = relative.with_suffix("").parts
    require(
        all(_MODULE_NAME_RE.fullmatch(part) for part in parts),
        f"not an importable Mojo module path: {relative}",
    )
    return ".".join(parts)


def render_entrypoint(sources: list[Path]) -> str:
    """Render the Mojo source of a co-linked entrypoint over `sources`.

    Args:
        sources: The modules to co-link, in the order they are imported.

    Returns:
        The complete Mojo source of the entrypoint.

    Raises:
        SystemExit: A source is not an importable Mojo module; see
            `_module_name`.
        OSError: A source could not be read.
    """
    names = [_module_name(source) for source in sources]
    lines = [
        '"""Generated ABI co-link probe; edit scripts/checks/abi_probe.py."""',
        "",
        "from std.testing import TestSuite",
        "",
    ]
    lines.extend(
        f"import {name} as _mtest_module_{index}" for index, name in enumerate(names)
    )
    lines.extend(
        [
            "",
            "",
            "def main() raises:",
            '    """Reference every co-linked module\'s tests. Never executed."""',
        ]
    )
    for index, source in enumerate(sources):
        functions = test_function_names(source.read_text(encoding="utf-8"))
        lines.append(f"    var suite_{index} = TestSuite()")
        lines.extend(
            f"    suite_{index}.test[_mtest_module_{index}.{function}]()"
            for function in functions
        )
        lines.append(f"    suite_{index}^.run()")
        if index + 1 < len(sources):
            lines.append("")
    lines.append("")
    return "\n".join(lines)


def write_entrypoint(output: Path, sources: list[Path]) -> None:
    """Write the co-linked entrypoint for `sources` to `output`.

    Args:
        output: The path the generated Mojo source is written to.
        sources: The modules to co-link.

    Raises:
        SystemExit: See `render_entrypoint`.
        OSError: The entrypoint could not be written.
    """
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_entrypoint(sources), encoding="utf-8")


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    """Run one build command from the repository root, output captured."""
    return subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=180,
    )


def build_probe(sources_to_colink: list[Path]) -> subprocess.CompletedProcess[str]:
    """Generate and build the co-linked entrypoint for `sources_to_colink`.

    Args:
        sources_to_colink: Every module that shares an `external_call` symbol
            declaration with at least one other module in the list.

    Returns:
        The completed `mojo build` invocation. Its `returncode` is the whole
        verdict: nonzero means at least two declarations of a shared symbol
        disagree.
    """
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    entrypoint = OUT / "abi_probe_main.mojo"
    write_entrypoint(entrypoint, sources_to_colink)
    binary = OUT / "abi_probe"
    return run(
        [
            "mojo",
            "build",
            "-I",
            ".",
            "-I",
            "build",
            "-I",
            "tests/support",
            str(entrypoint),
            "-o",
            str(binary),
            "-Xlinker",
            str(NATIVE_TEST_OBJECT),
        ]
    )


def main() -> int:
    """Co-link every classified module that shares an `external_call` symbol.

    Returns:
        0 if every shared symbol's declarations agree well enough to co-link.

    Raises:
        SystemExit: No classified module inventory exists, no symbol is
            shared (the probe would then guard nothing), or the co-linked
            build itself failed -- the drift this probe exists to catch.
    """
    sources = classified_sources()
    shared = shared_symbol_files(sources)
    require(
        bool(shared),
        "no external_call symbol is declared by 2+ classified modules -- "
        "either the recorded shared-symbol table has been refactored away "
        "and this probe should be retired, or the scan itself broke; either "
        "way this probe is currently guarding nothing",
    )

    sources_to_colink = affected_sources(shared)
    compiled = build_probe(sources_to_colink)
    require(
        compiled.returncode == 0,
        f"co-linking {len(sources_to_colink)} module(s) that share an "
        f"external_call declaration ({', '.join(sorted(shared))}) failed to "
        "build. This is what the probe watches for when two declarations of "
        "the same shared symbol disagree in arity or parameter type -- but "
        "the failure below could also be an unrelated compile error in one "
        "of the co-linked modules; read the compiler output to tell which:\n"
        f"{compiled.stdout}",
    )

    for symbol, files in sorted(shared.items()):
        names = ", ".join(source.relative_to(ROOT).as_posix() for source in files)
        print(f"abi-probe-check: {symbol}: {len(files)} declarations agree ({names})")
    print(
        f"abi-probe-check: OK -- {len(sources_to_colink)} module(s) co-linked, "
        f"{len(shared)} shared symbol(s) verified"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
