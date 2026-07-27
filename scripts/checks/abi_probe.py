#!/usr/bin/env python3
"""Catch cross-module `external_call` arity/signature drift at build time.

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
declare -- generates one small entrypoint (via `scripts.harness.aggregate`)
that imports every one of those modules and builds it. Mojo's own compiler is
the oracle: if any two declarations of a shared symbol disagree, the build
fails with a specific, compiler-authored diagnostic naming the conflict. The
binary is never executed -- the archive-time link is the whole proof, and this
probe has nothing to say about runtime behavior.

A source line is counted as a real declaration only if it is not itself string
data: several classified suites embed generated Mojo source as line-by-line
string literals to write out and compile as a throwaway fixture elsewhere (the
same pattern `asan.py`/`valgrind.py`'s own `CLI_PROBE_SOURCE` uses). A naive
text search over `external_call["sym"` matches those lines too, but they are
never compiled as part of the module that contains them, so co-linking on
their account would prove nothing. See `_is_string_literal_line`.
"""

from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import sys

from scripts.harness import aggregate


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build" / "safety" / "abi_probe"
NATIVE_TEST_OBJECT = ROOT / "build" / "native" / "mtest_exec_native_test.o"
SEARCH_ROOTS = (ROOT / "tests" / "unit", ROOT / "tests" / "integration")

_SYMBOL_RE = re.compile(r'external_call\["([A-Za-z0-9_]+)"')


def require(condition: bool, message: str) -> None:
    """Fail the gate with one actionable diagnostic."""
    if not condition:
        raise SystemExit(f"abi-probe-check: {message}")


def _is_string_literal_line(stripped_line: str) -> bool:
    """Whether `stripped_line` opens with a quote -- string data, not code.

    A real `external_call` invocation's line always starts with code:
    `_ = external_call[...]`, `var x = external_call[...]`, and
    `return external_call[...]` are the three shapes this project uses, and
    none of them opens with a quote character. A line that IS one fragment of
    a hand-built string literal (used elsewhere to write out a throwaway
    fixture source) opens with the quote that starts or continues the
    literal. This is a per-line heuristic, not a parser, and it is only asked
    to distinguish these two shapes -- it is not a general Mojo string
    detector.
    """
    return stripped_line[:1] in ("'", '"')


def declared_symbols(source: Path) -> set[str]:
    """Return every symbol `source` declares as a real `external_call` site.

    Args:
        source: A classified `test_*.mojo` module.

    Returns:
        The distinct `external_call["symbol", ...]` names invoked as real
        code in `source`, excluding any match inside a string-literal line.
    """
    symbols: set[str] = set()
    for line in source.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if _is_string_literal_line(stripped):
            continue
        match = _SYMBOL_RE.search(line)
        if match is not None:
            symbols.add(match.group(1))
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
    aggregate.write_entrypoint(ROOT, entrypoint, sources_to_colink)
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
        "cross-module external_call ABI drift: co-linking "
        f"{len(sources_to_colink)} module(s) that share a symbol declaration "
        f"failed to build -- two declarations of the same symbol disagree:\n"
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
