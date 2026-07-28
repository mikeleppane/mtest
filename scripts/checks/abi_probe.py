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

The generated entrypoint imports each module by its bare stem off an include
path (`-I tests/unit -I tests/integration`, plus the directory of any nested
module being co-linked, then `import test_foo`), the same way the classified
suites themselves import `exec_helpers` and `session_fixtures` off
`-I tests/support`. It cannot import them as
`tests.unit.test_foo`: that spelling requires `tests/unit` to be a Mojo
package, and `tests/unit/__init__.mojo` cannot exist, because every classified
module declares `main()` and Mojo 1.0.0b2 refuses to `mojo precompile` a
package containing one (`error: 'main()' is not supported within packages`).
The two spellings are strictly exclusive, measured on this checkout: with a
marker present, `-I tests/unit` + `import test_foo` fails with "unable to
locate module"; with it absent, `-I .` + `import tests.unit.test_foo` fails
with "'unit' does not refer to a nested package".

Resolving by stem has one sharp edge. `-I tests/unit` precedes
`-I tests/integration`, and Mojo takes the first include path that matches
without reporting any ambiguity, so two classified modules sharing a stem
would make one silently shadow the other: `import test_foo` would compile the
`tests/unit` twin while this probe's own output named the `tests/integration`
one. An arity drift declared only in the shadowed twin would then co-link
clean and this gate would print OK. `classified_sources` therefore requires
every stem to be distinct across the whole classified universe -- which the
scan walks RECURSIVELY, so nested directories are inside it, and a nested
twin collides with a top-level one exactly as a cross-root twin does -- and
over that universe rather than over one co-link list, because shadowing needs
only ONE twin in the list and the other merely present on disk.

A declaration is matched over its complete bracketed span
(`external_call[...]`), not one line: the symbol name legitimately sits on a
continuation line in this codebase (`external_call[\n    "sym", Int32\n]`),
and a scan that required the symbol on the same line as `external_call[`
would silently miss it. A span is counted as a real declaration only if no
quote is still open AT THE OFFSET where it begins: several classified suites
embed generated Mojo source as line-by-line string literals to write out and
compile as a throwaway fixture elsewhere (the same pattern
`asan.py`/`valgrind.py`'s own `CLI_PROBE_SOURCE` uses), and by that same
convention every physical line of such a fixture is its own quoted literal --
including the line that would otherwise open a real span -- so testing only
the offset that opens an `external_call[` span is sufficient to exclude the
whole fixture span, however many lines it happens to spread across. A naive
text search over `external_call["sym"` matches those lines too, but they are
never compiled as part of the module that contains them, so co-linking on
their account would prove nothing. Testing the OFFSET rather than the line's
first character is what keeps a real declaration that merely follows a
complete string on its own line visible. See `_opens_inside_string_literal`
and `_bracket_span`.
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


def _opens_inside_string_literal(line: str, column: int) -> bool:
    r"""Whether `line[column]` sits inside a quoted literal -- data, not code.

    Decided at the MATCH OFFSET, by tracking quotes to its left, rather than
    from the line's first character. The first-character test this replaces
    asked whether the line *begins* with a quote, so a real declaration merely
    PRECEDED on its line by a complete string was read as fixture data and
    silently dropped from the co-link set:

        "expected", String(external_call["getpid", Int32]()),

    as the continuation line of a multi-argument call begins with a quote and
    is ordinary code. That is the same defect class as the multi-line span
    fixed in `746a0d7`, at a different instance: a positional proxy standing
    in for the property it is meant to test.

    Equivalent to an odd-quote count over `line[:column]`, but scanned rather
    than counted so it agrees with the language on the two points a raw count
    gets wrong: a quote of the other kind inside a literal (`"it's"`) opens
    nothing, and a backslash-escaped quote (`\"`) closes nothing.

    The fixture exclusion this exists for is unchanged. Several classified
    suites embed generated Mojo source as line-by-line string literals; by
    that convention each physical line is its own quoted literal, so at the
    offset where `external_call[` appears exactly one opening quote is still
    unclosed to its left and the span is excluded, as before.

    This is a lexical test over one line, not a Mojo parser. It does not model
    triple-quoted strings, which no `external_call` in this tree sits inside;
    a declaration written inside one would be read as code and co-linked,
    which fails loudly at build time rather than passing silently.

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
    this codebase -- is still found. Only the offset that OPENS the span is
    checked for string-literal exclusion; see `_opens_inside_string_literal`.

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
        line, column = _line_and_column(text, match.start())
        if _opens_inside_string_literal(line, column):
            continue
        span = _bracket_span(text, match.end() - 1)
        symbol_match = _SYMBOL_IN_SPAN_RE.search(span)
        if symbol_match is not None:
            symbols.add(symbol_match.group(1))
    return symbols


def classified_sources() -> list[Path]:
    """Return every classified `test_*.mojo` module, bytewise sorted.

    Walks RECURSIVELY, because everything else that reads the classified tree
    does: `scripts/harness/selfhost.py` (`os.walk`) discovers, builds and runs
    a nested module, and `scripts/checks/layout.py` reaches it with `rglob`.
    A non-recursive walk here meant a nested module declaring an existing
    foreign symbol at the wrong arity ran in the suite and was silently absent
    from the co-link set -- measured on this checkout as a recursive walk of
    102 against a probe inventory of 101.

    Also enforces that every classified module across BOTH roots has a
    distinct stem, because the generated entrypoint imports by stem off an
    include path and `-I tests/unit` precedes `-I tests/integration`. Mojo
    resolves a bare stem against the first include path that matches and
    raises no ambiguity error, so a cross-root collision means
    `import test_foo` silently compiles `tests/unit/test_foo.mojo` while the
    probe's own output names `tests/integration/test_foo.mojo`. A drift
    declared only in the shadowed twin then co-links clean and the gate
    reports OK -- reproduced end to end: a shadowed build returned 0 on real
    injected arity drift where the unshadowed control returned nonzero.

    Recursion widens exactly that hazard, which is why the two changes belong
    together: before it, a stem could only collide across the two roots; now
    `tests/unit/test_foo.mojo` and `tests/unit/nested/test_foo.mojo` collide
    as well, and `build_probe` puts BOTH directories on the include path. The
    guard needed no change -- it already compares stems over the whole
    universe rather than per directory -- but it did need re-proving against
    the nested shape, and it is what makes the added include paths safe.

    This is checked over the whole classified universe rather than over one
    co-link list, because shadowing does not require both twins to be in the
    list: one twin declaring the shared symbol is enough, and the other need
    only exist on disk ahead of it on the include path.

    Raises:
        SystemExit: Neither search root has a single classified module -- that
            would mean the tree has moved out from under this probe, not that
            there is genuinely nothing to guard -- or two classified modules
            share a stem, which would make this probe's coverage silently
            narrower than the report it prints.
    """
    found = [
        path
        for root in SEARCH_ROOTS
        for path in sorted(root.rglob("test_*.mojo"), key=lambda p: p.name)
    ]
    require(bool(found), "no classified test_*.mojo modules found")
    by_stem: dict[str, list[Path]] = {}
    for path in found:
        by_stem.setdefault(path.stem, []).append(path)
    collisions = {stem: paths for stem, paths in by_stem.items() if len(paths) > 1}
    require(
        not collisions,
        "classified modules share a stem, so an include-path import resolves "
        "to whichever comes first and silently shadows the other(s); this "
        "probe cannot co-link the shadowed module at all: "
        + "; ".join(
            f"{stem}: {[path.relative_to(ROOT).as_posix() for path in paths]}"
            for stem, paths in sorted(collisions.items())
        ),
    )
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
    """Return the include-path module name for one classified source.

    The generated entrypoint is built with each classified root on the include
    path, so a module is named by its bare stem: `tests/unit/test_config.mojo`
    is `test_config`. See this module's docstring for why the dotted package
    spelling is not available.

    Args:
        source: A classified `test_*.mojo` module.

    Returns:
        The file stem, which is how the module is named off an include path.

    Raises:
        SystemExit: The stem is not a legal Mojo identifier, so no import
            statement could name it.
    """
    stem = source.stem
    require(
        _MODULE_NAME_RE.fullmatch(stem) is not None,
        f"not an importable Mojo module name: {source}",
    )
    return stem


def render_entrypoint(sources: list[Path]) -> str:
    """Render the Mojo source of a co-linked entrypoint over `sources`.

    Args:
        sources: The modules to co-link, in the order they are imported.

    Returns:
        The complete Mojo source of the entrypoint.

    Raises:
        SystemExit: A stem is not importable, or two sources IN THIS LIST
            share a stem. Note what this second check does NOT cover: it sees
            only the modules handed to it, and stem shadowing does not need
            both twins in the list -- a twin that merely exists on disk
            earlier on the include path shadows a co-linked module just as
            effectively. `classified_sources` enforces stem uniqueness across
            the whole classified universe and is what actually closes that
            hole; this one is a local invariant on the rendered source, not
            the guard.
        OSError: A source could not be read.
    """
    names = [_module_name(source) for source in sources]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    require(
        not duplicates,
        f"two classified modules share an importable name: {duplicates}",
    )
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


def include_roots(sources_to_colink: list[Path]) -> list[str]:
    """Return the classified include paths one co-link build needs.

    The entrypoint imports each module by its bare stem, which only resolves
    when the module's own directory is on the include path. The two search
    roots alone were sufficient while the tree was flat; a nested module needs
    its own directory named too, or the generated `import` fails to locate it.

    Every stem across the whole classified universe is distinct
    (`classified_sources`), so widening the include path cannot make one
    module shadow another.

    Args:
        sources_to_colink: The modules the entrypoint will import.

    Returns:
        The search roots followed by any further directory holding one of
        `sources_to_colink`, deduplicated and ordered.
    """
    roots = [str(root) for root in SEARCH_ROOTS]
    for source in sources_to_colink:
        directory = str(source.parent)
        if directory not in roots:
            roots.append(directory)
    return roots


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
            *(
                argument
                for root in include_roots(sources_to_colink)
                for argument in ("-I", root)
            ),
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
