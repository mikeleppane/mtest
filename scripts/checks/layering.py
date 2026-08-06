#!/usr/bin/env python3
"""Enforce the one-directional layering doctrine over `src/`."""

from __future__ import annotations

from pathlib import Path
import re
import sys
from typing import NamedTuple


REPO_ROOT = Path(__file__).resolve().parents[2]

SOURCE_ROOT = Path("src")
PACKAGE_ROOT = SOURCE_ROOT / "mtest"
COMPOSITION_ROOT = SOURCE_ROOT / "main.mojo"
FACADE_NAME = "__init__.mojo"

RANK = {
    "model": 0,
    "platform": 0,
    "config": 1,
    "discover": 2,
    "protocol": 2,
    "report": 2,
    "select": 2,
    "cache": 2,
    "exec": 3,
    "session": 4,
    "cli": 5,
}
"""Every package under `src/mtest` and the layer it sits in.

A package may import strictly below itself, or from itself, and never sideways
or upward. A directory carrying Mojo source that is absent from this table is a
finding rather than an unranked free agent, so a new package cannot arrive
without someone placing it.
"""

LAYER_TWO_RANK = 2
"""The rank whose members are siblings: they may never import each other."""

COMPOSITION_ROOT_PACKAGE = "cli"
"""Where `src/main.mojo` sits for the facade rule.

The composition root is above every layer for the rank rule, but it is the
caller `cli` exists to serve: a `cli` support module it reaches for directly is
an internal call within one package, not a facade bypass. Its rank stays
unconstrained, since composing every layer is what it exists to do.
"""

NATIVE_ABI_PREFIX = "mtest_exec_"
"""The private C17 adapter's symbol prefix, which `exec` alone may call.

AGENTS.md's exec-boundary clause makes `exec` the sole consumer of the
`mtest_exec_*` ABI: the fork/exec, pipe-supervision and signal machinery that
has to be C to stay async-signal-safe after a fork.
"""

EXEC_LIBC_ALLOWANCE = {
    "src/mtest/exec/signals.mojo": frozenset({"kill"}),
}
"""Raw libc symbols `exec` may declare, beyond the native-adapter ABI.

Read off AGENTS.md's exec-boundary clause, which sanctions "the residual
test-only `kill(2)` in the exec signal helper" alongside the `mtest_exec_*`
calls. `signals.mojo`'s `_raise_self` delivers a signal to the runner's own
process so the interrupt integration tests can exercise the latch; it is the
only call under `exec` that is not adapter machinery.

It goes away when those tests stop needing the runner to signal itself, either
through a native `mtest_exec_test_*` entry point like the reset hook beside it,
or by signalling from the harness. Delete this entry with the call:
`check_foreign_allowance_is_live` fails on an entry that permits nothing.
"""

EXTERNAL_CALL_PACKAGES = frozenset({"platform", "exec"})
"""The packages that may import `external_call` at all.

`platform` is the foreign-call boundary, and `exec` needs the intrinsic for the
native-adapter ABI and the allowance above. Anywhere else the import is itself
a finding: an alias binds a second spelling for the same intrinsic, and a call
written through a spelling this file never saw bound cannot be matched.
"""

_FROM_RE = re.compile(r"^\s*from\s+([\w.]+)\s+import\s+(.*)$")
_IMPORT_RE = re.compile(r"^\s*import\s+(.+)$")
_EXIT_SYMBOL = "exit"
_EXTERNAL_CALL_SYMBOL = "external_call"
_TRIPLE_QUOTES = ('"""', "'''")


class Binding(NamedTuple):
    """One name an import statement binds.

    Attributes:
        imported: The name as the module it comes from spells it. The facade
            and private-name rules judge this one, because it names the entity
            being reached.
        bound: The name the importing module writes, which is the alias when
            `as` renames it. A facade's exports are these, because the alias is
            what a caller can ask the facade for.
    """

    imported: str
    bound: str


class Import(NamedTuple):
    """One import statement, read from stripped source.

    Attributes:
        line: The physical line the statement starts on.
        module: The dotted module the statement imports from, or imports.
        names: The bindings the statement makes, both spellings each. Empty for
            the bare `import mtest.<pkg>.<module>` form, which binds no symbol
            this checker can see.
    """

    line: int
    module: str
    names: tuple[Binding, ...]


class Report(NamedTuple):
    """What one scan found.

    Attributes:
        violations: Findings that fail the gate.
        infos: Cross-package deep imports of names no facade exports. A name a
            facade does not export cannot have been reached through that
            facade, so these do not fail the gate; they are printed because
            they are the list facade repair works from.
    """

    violations: tuple[str, ...]
    infos: tuple[str, ...]


def _require_nonempty(name: str, values: object) -> None:
    """Reject an accidentally disabled intended inventory.

    Args:
        name: What the inventory holds, for the failure message.
        values: The inventory itself.

    Raises:
        AssertionError: The inventory is empty.
    """
    if not values:
        raise AssertionError(f"{name} intended inventory is empty")


def strip_docstrings_and_comments(text: str) -> list[tuple[int, str]]:
    """Blank out triple-quoted blocks and comment tails, keeping line numbers.

    Every rule below matches text that also appears in prose: this tree's
    `Examples:` blocks hold hundreds of indented `from mtest.` lines, and module
    docstrings discuss `exit()` and `external_call` by name. Scanning raw source
    reports all of them.

    Single-line string literals keep their contents, because a foreign symbol
    name is one: `external_call["kill", ...]` is only classifiable while the
    symbol is still there. Their quoting is tracked so a `#` inside a literal
    does not read as a comment. The cost is that a literal spelling `exit(` or
    `external_call["...` as data would be reported as a call site; that is the
    price of reading the symbol out of the literal, and it is a false positive
    to be argued with, not a bug to be fixed by dropping the contents.

    One known blind spot: a docstring that escapes a triple quote inside itself
    closes the block there, and its remaining lines are then read as code.
    Nothing in this tree writes one, and a full Mojo lexer is a steep price for
    a policy gate.

    Args:
        text: One Mojo source file.

    Returns:
        One `(line number, code)` pair per physical line, in order, with
        docstring and comment text removed and everything else intact.
    """
    stripped: list[tuple[int, str]] = []
    block: str | None = None
    for number, line in enumerate(text.splitlines(), start=1):
        kept: list[str] = []
        quote: str | None = None
        index = 0
        while index < len(line):
            character = line[index]
            if block is not None:
                if line.startswith(block, index):
                    index += len(block)
                    block = None
                else:
                    index += 1
                continue
            if quote is not None:
                kept.append(character)
                if character == "\\" and index + 1 < len(line):
                    kept.append(line[index + 1])
                    index += 2
                    continue
                if character == quote:
                    quote = None
                index += 1
                continue
            opener = next(
                (mark for mark in _TRIPLE_QUOTES if line.startswith(mark, index)),
                None,
            )
            if opener is not None:
                block = opener
                index += 3
                continue
            if character == "#":
                break
            if character in "\"'":
                quote = character
            kept.append(character)
            index += 1
        stripped.append((number, "".join(kept)))
    return stripped


def stripped_code(text: str) -> str:
    """Return one file's code with prose removed, line positions preserved.

    Args:
        text: One Mojo source file.

    Returns:
        The stripped lines rejoined, so a match's offset still maps back to its
        physical line and a statement spanning lines can be matched whole.
    """
    return "\n".join(line for _number, line in strip_docstrings_and_comments(text))


def _bound_names(clause: str) -> tuple[Binding, ...]:
    """Return the names an import clause binds into the importing module.

    Both spellings are kept. Dropping the imported name would leave every rule
    reading the alias: `run_session as invoke` would look like a name no facade
    exports, and `_slot as slot` would look like a public one.

    Args:
        clause: Everything after `import`, with any grouping parentheses.

    Returns:
        One binding per imported entity.
    """
    names: list[Binding] = []
    for piece in clause.replace("(", " ").replace(")", " ").split(","):
        words = piece.split()
        if not words:
            continue
        aliased = len(words) > 2 and words[1] == "as"
        names.append(Binding(words[0], words[2] if aliased else words[0]))
    return tuple(names)


def _aliases(statements: list[Import], symbol: str) -> frozenset[str]:
    """Return every local spelling one file's imports give a primitive.

    Args:
        statements: The file's import statements.
        symbol: The primitive's own name.

    Returns:
        `symbol` itself and every alias bound to it, so a call written through
        the alias reads as a call to the primitive.
    """
    return frozenset({symbol}) | {
        binding.bound
        for statement in statements
        for binding in statement.names
        if binding.imported == symbol
    }


def _call_re(names: frozenset[str]) -> re.Pattern[str]:
    """Return a pattern matching a call to any of `names`.

    Args:
        names: Local spellings of one primitive, its aliases included.

    Returns:
        A pattern whose match starts at the callee.
    """
    spellings = "|".join(re.escape(name) for name in sorted(names))
    return re.compile(rf"\b(?:{spellings})\s*\(")


def _foreign_re(names: frozenset[str]) -> re.Pattern[str]:
    """Return a pattern matching an `external_call` through any of `names`.

    Args:
        names: Local spellings of the intrinsic, its aliases included.

    Returns:
        A pattern capturing the declared foreign symbol.
    """
    spellings = "|".join(re.escape(name) for name in sorted(names))
    return re.compile(rf"\b(?:{spellings})\s*\[\s*\"([^\"]*)\"")


def parse_imports(text: str) -> list[Import]:
    """Return every import statement in one file, prose excluded.

    Both spellings are read. A parenthesized `from X import (a, b)` list spans
    lines in this tree's style, so it is read to its closing parenthesis and
    reported at the line its `from` keyword sits on. The bare
    `import mtest.<pkg>.<module>` form binds no symbol name, and is recorded
    with no names: it still moves a package boundary, so the rank and sibling
    rules have to see it. Nothing in this tree writes it today, which is exactly
    why it has to be parsed — an unread spelling is a way around every rule
    here.

    Args:
        text: The file's source.

    Returns:
        The file's import statements, in source order.
    """
    stripped = strip_docstrings_and_comments(text)
    imports: list[Import] = []
    index = 0
    while index < len(stripped):
        number, code = stripped[index]
        index += 1
        match = _FROM_RE.match(code)
        if match is not None:
            clause = match.group(2)
            while clause.count("(") > clause.count(")") and index < len(stripped):
                clause += " " + stripped[index][1]
                index += 1
            imports.append(Import(number, match.group(1), _bound_names(clause)))
            continue
        bare = _IMPORT_RE.match(code)
        if bare is None:
            continue
        imports.extend(
            Import(number, module, ())
            for module in _bare_modules(bare.group(1))
            if module == "mtest" or module.startswith("mtest.")
        )
    return imports


def _bare_modules(clause: str) -> tuple[str, ...]:
    """Return the modules a bare `import` statement names.

    Args:
        clause: Everything after `import`.

    Returns:
        One dotted module per comma-separated entry, with any `as` alias
        dropped: the alias renames the binding, not the module being reached.
    """
    return tuple(piece.split()[0] for piece in clause.split(",") if piece.split())


def facade_exports(root: Path, package: str) -> frozenset[str]:
    """Return the names a package's `__init__.mojo` re-exports.

    Only imports from the package's own modules count. A facade that pulls a
    standard-library name in for its own use is not offering that name as this
    package's surface.

    Args:
        root: Repository root.
        package: Dotted package path under `mtest`, a subpackage such as
            `session.store` included.

    Returns:
        Every name reachable as `from mtest.<package> import <name>`, spelled
        the way the facade binds it: an aliased re-export offers the alias.
    """
    facade = root / PACKAGE_ROOT / Path(*package.split(".")) / FACADE_NAME
    if not facade.is_file():
        return frozenset()
    prefix = f"mtest.{package}."
    return frozenset(
        binding.bound
        for statement in parse_imports(facade.read_text(encoding="utf-8"))
        if statement.module.startswith(prefix)
        for binding in statement.names
    )


def facade_packages(files: list[Path]) -> frozenset[str]:
    """Return every package under `src/mtest` that carries a facade.

    Subpackages count. A subpackage with an `__init__.mojo` offers a surface of
    its own, so reaching past it is a bypass even though the package it sits in
    has a facade too — otherwise the deeper surface is invisible and every
    import through it is judged against the outer facade alone.

    Args:
        files: Repository-relative Mojo paths, as `source_files` returns them.

    Returns:
        Dotted paths relative to `mtest`. `mtest` itself is excluded: it is the
        distribution root, not a layer.
    """
    return frozenset(
        ".".join(path.parts[2:-1])
        for path in files
        if path.name == FACADE_NAME
        and path.parts[:2] == PACKAGE_ROOT.parts
        and len(path.parts) > 3
    )


def package_of(relative: Path) -> str | None:
    """Return the package a file's code belongs to, for the rank rule.

    Args:
        relative: Repository-relative path of a Mojo file under `src/`.

    Returns:
        The package directory name, or `None` for `src/main.mojo` and the
        `mtest` package facade, both of which sit above every layer.
    """
    parts = relative.parts
    if len(parts) < 4 or parts[:2] != PACKAGE_ROOT.parts:
        return None
    return parts[2]


def facade_home(relative: Path) -> str | None:
    """Return the package directory a file sits in, for the facade rule.

    Args:
        relative: Repository-relative path of a Mojo file under `src/`.

    Returns:
        The dotted package whose internals this file may reach directly, which
        is `cli` for the composition root (see `COMPOSITION_ROOT_PACKAGE`) and
        `None` for a file outside `src/mtest`.
    """
    if relative == COMPOSITION_ROOT:
        return COMPOSITION_ROOT_PACKAGE
    parts = relative.parts
    if len(parts) < 4 or parts[:2] != PACKAGE_ROOT.parts:
        return None
    return ".".join(parts[2:-1])


def source_files(root: Path) -> list[Path]:
    """Return every Mojo file the doctrine governs, in a stable order.

    `tests/` is outside the scan: an internal test legitimately imports the
    module it covers.

    A symlinked module IS scanned. It compiles into the package like any other
    file, so the doctrine binds it, and skipping it would be the one way to put
    a source file under `src/` beyond all five rules. Judging it where the link
    sits is right for the same reason: its package is where it is reachable
    from, not where its bytes live.

    Args:
        root: Repository root.

    Returns:
        Repository-relative paths under `src/`, sorted.
    """
    return sorted(
        path.relative_to(root)
        for path in (root / SOURCE_ROOT).rglob("*.mojo")
        if path.is_file()
    )


def _rank_findings(relative: Path, statement: Import) -> list[str]:
    """Check one import against the rank and sibling rules.

    Args:
        relative: Repository-relative path of the importing file.
        statement: The import to classify.

    Returns:
        Zero or one finding line.
    """
    home = package_of(relative)
    parts = statement.module.split(".")
    if home not in RANK or parts[0] != "mtest" or len(parts) < 2:
        # `home` is absent for the composition root and the `mtest` facade, both
        # of which sit above every layer, and for a package that has no rank —
        # already reported once against the package itself, where a reader can
        # act on it, rather than once per import it happens to write.
        return []
    target = parts[1]
    if target == home:
        return []
    where = f"{relative.as_posix()}:{statement.line}"
    if target not in RANK:
        return [
            (
                f"{where}: R1-rank: {home} imports {statement.module}, and "
                f"{target} is not a declared layer"
            )
        ]
    if RANK[target] < RANK[home]:
        return []
    if RANK[target] == RANK[home] == LAYER_TWO_RANK:
        return [
            (
                f"{where}: R2-sibling: {home} imports {statement.module}; "
                "Layer 2 packages never import each other"
            )
        ]
    return [
        (
            f"{where}: R1-rank: {home} (rank {RANK[home]}) imports "
            f"{statement.module} (rank {RANK[target]}), which is not below it"
        )
    ]


def _owning_facade(
    module: str, home: str | None, facades: dict[str, frozenset[str]]
) -> str | None:
    """Return the facade an import reaches past, or `None` for an inside reach.

    The packages an import `mtest.a.b.c` reaches into are `a.b` and `a`, and
    the deepest one wins: a subpackage's surface is the one a caller had to ask,
    and judging against its parent instead would call a bypass of the inner
    facade a name the outer one happens not to export.

    Args:
        module: The dotted module the import names.
        home: The importing file's own package directory, dotted.
        facades: Dotted package -> what that package's facade re-exports.

    Returns:
        The dotted package whose facade the import goes around; `None` when the
        importing file sits in that package or below it, which makes the import
        an internal reach, or when the module names no package's internals.
    """
    parts = module.split(".")
    if parts[0] != "mtest" or len(parts) < 3:
        return None
    reached = [".".join(parts[1:end]) for end in range(len(parts) - 1, 1, -1)]
    for candidate in reached:
        if home is not None and (home == candidate or home.startswith(f"{candidate}.")):
            return None
        if candidate in facades:
            return candidate
    return reached[-1]


def _facade_findings(
    relative: Path, statement: Import, exports: dict[str, frozenset[str]]
) -> tuple[list[str], list[str]]:
    """Check one import against the facade rule.

    An import is judged by the name the module it reaches into spells, not by
    the alias the importer binds: `run_session as invoke` reaches the same
    exported entity, and `_slot as slot` takes the same package-private one.

    An aliased re-export shadows: a facade writing `from mtest.x.y import Slot
    as Store` makes `Store` this package's surface, so a deep
    `from mtest.x.y import Store` is judged a bypass even though it reaches a
    different entity. That is conservatism about the NAME a caller writes, not
    a claim the two symbols are the same one; the alternative is resolving Mojo
    names, and the false positive is cheap to argue with while the false
    negative is silent.

    The bare `import mtest.<pkg>.<module>` form binds no name here, so it can
    only be reported as information: there is no symbol to compare against the
    facade's exports. Its rank and sibling consequences are judged elsewhere,
    where the module path is all that matters.

    Args:
        relative: Repository-relative path of the importing file.
        statement: The import to classify.
        exports: Dotted package -> what that package's facade re-exports.

    Returns:
        The violations and the informational findings, in that order.
    """
    package = _owning_facade(statement.module, facade_home(relative), exports)
    if package is None:
        return [], []
    exported = exports.get(package, frozenset())
    facade = f"mtest/{package.replace('.', '/')}/{FACADE_NAME}"
    where = f"{relative.as_posix()}:{statement.line}"
    violations: list[str] = []
    infos: list[str] = []
    if not statement.names:
        return [], [
            (
                f"{where}: R3-deep-import: {statement.module} is imported whole, "
                f"around {facade}"
            )
        ]
    for binding in statement.names:
        name = binding.imported
        if name.startswith("_"):
            violations.append(
                f"{where}: R3-facade-bypass: {statement.module} import {name} "
                "takes a package-private name across a package boundary"
            )
        elif name in exported:
            violations.append(
                f"{where}: R3-facade-bypass: {statement.module} import {name} "
                f"goes around {facade}, which exports {name}"
            )
        else:
            infos.append(
                f"{where}: R3-deep-import: {statement.module} import {name} "
                f"is not exported by {facade}"
            )
    return violations, infos


def _confinement_findings(
    relative: Path, text: str, statements: list[Import]
) -> list[str]:
    """Check one file against the `exit()` and `external_call` rules.

    Both primitives are followed through import aliases, and the import itself
    is refused wherever the primitive does not belong. The import rule is what
    makes the call scan complete: an alias the scanner never saw bound is a
    spelling it cannot match, so `exit as terminate` would otherwise carry a
    process exit into any layer under a name of the author's choosing.

    Both patterns are matched over the file's stripped code rejoined, because a
    foreign symbol sits on the line after its opening bracket often enough that
    a per-line match would read the call as having no symbol at all.

    A call spelled `_exit(` is not matched, deliberately: the underscore is part
    of an identifier, so a pattern loose enough to see it also reports every
    `resolve_exit`-shaped definition. The `_exit` spelling is not itself matched
    by either rule; the practical protection for the libc route is R5, which
    matches the declared foreign symbol inside `external_call[...]` regardless
    of the identifier around it.

    Args:
        relative: Repository-relative path of the file.
        text: The file's source.
        statements: The file's import statements.

    Returns:
        One finding per offending import and call site.
    """
    code = stripped_code(text)
    posix = relative.as_posix()
    package = package_of(relative)
    findings: list[str] = []
    if relative != COMPOSITION_ROOT:
        findings.extend(
            f"{posix}:{statement.line}: R4-exit-import: only "
            f"{COMPOSITION_ROOT.as_posix()} imports exit(); an alias binds a "
            "call site under another name"
            for statement in statements
            for binding in statement.names
            if binding.imported == _EXIT_SYMBOL
        )
        for match in _call_re(_aliases(statements, _EXIT_SYMBOL)).finditer(code):
            line = code.count("\n", 0, match.start()) + 1
            findings.append(
                f"{posix}:{line}: R4-exit: only {COMPOSITION_ROOT.as_posix()} "
                "calls exit(); every module below it returns a typed result"
            )
    if package not in EXTERNAL_CALL_PACKAGES:
        findings.extend(
            f"{posix}:{statement.line}: R5-external-call-import: "
            f"{_EXTERNAL_CALL_SYMBOL} is imported outside "
            f"{PACKAGE_ROOT.as_posix()}/platform and {PACKAGE_ROOT.as_posix()}/exec"
            for statement in statements
            for binding in statement.names
            if binding.imported == _EXTERNAL_CALL_SYMBOL
        )
    if package == "platform":
        return findings
    allowed = EXEC_LIBC_ALLOWANCE.get(posix, frozenset())
    foreign = _foreign_re(_aliases(statements, _EXTERNAL_CALL_SYMBOL))
    for match in foreign.finditer(code):
        symbol = match.group(1)
        if package == "exec" and (
            symbol.startswith(NATIVE_ABI_PREFIX) or symbol in allowed
        ):
            continue
        line = code.count("\n", 0, match.start()) + 1
        findings.append(
            f"{posix}:{line}: R5-external-call: {symbol} is declared outside "
            f"{PACKAGE_ROOT.as_posix()}/platform and outside the exec "
            "native-ABI boundary"
        )
    return findings


def scan(root: Path) -> Report:
    """Apply every layering rule to one source tree.

    Args:
        root: Repository root the `src/` tree sits under.

    Returns:
        The violations and the informational findings, each sorted.

    Raises:
        AssertionError: The rank table is empty, or the tree holds no Mojo
            source, which would make every rule vacuously true.
    """
    _require_nonempty("layer rank", RANK)
    files = source_files(root)
    if not files:
        raise AssertionError(f"no Mojo source to scan under {root / SOURCE_ROOT}")
    violations: list[str] = []
    infos: list[str] = []
    packages = sorted({owner for path in files if (owner := package_of(path))})
    exports = {
        package: facade_exports(root, package)
        for package in sorted(facade_packages(files))
    }
    violations.extend(
        f"{(PACKAGE_ROOT / package / FACADE_NAME).as_posix()}:1: R1-rank: "
        f"{package} carries Mojo source and has no declared layer"
        for package in packages
        if package not in RANK
    )
    for relative in files:
        text = (root / relative).read_text(encoding="utf-8")
        statements = parse_imports(text)
        violations.extend(_confinement_findings(relative, text, statements))
        for statement in statements:
            violations.extend(_rank_findings(relative, statement))
            found, noted = _facade_findings(relative, statement, exports)
            violations.extend(found)
            infos.extend(noted)
    return Report(tuple(sorted(violations)), tuple(sorted(infos)))


def check_rank_covers_the_tree(root: Path) -> None:
    """Every ranked package still exists on disk.

    The other direction — source under a package with no rank — is a scan
    finding, so a synthetic tree can be scanned without restating the whole
    table. This half catches the stale entry a rename or a deletion leaves
    behind, which would otherwise sit in `RANK` ranking nothing.

    Args:
        root: Repository root.

    Raises:
        AssertionError: The rank table is empty, or names a package that no
            longer exists.
    """
    _require_nonempty("layer rank", RANK)
    missing = sorted(name for name in RANK if not (root / PACKAGE_ROOT / name).is_dir())
    if missing:
        raise AssertionError(
            f"ranked package does not exist under {PACKAGE_ROOT.as_posix()}: {missing}"
        )


def check_foreign_allowance_is_live(root: Path) -> None:
    """Every allowed foreign symbol is still called where it is allowed.

    An allowance that permits nothing is worse than no allowance: it is a
    standing exemption nobody reads, granted for a call site that has moved or
    gone. `EXEC_LIBC_ALLOWANCE` names the exact file and symbol, which is what
    makes this reconciliation possible.

    Args:
        root: Repository root.

    Raises:
        AssertionError: An allowance is empty, names a file that is gone, or
            permits a symbol that file no longer calls.
    """
    _require_nonempty("exec libc allowance", EXEC_LIBC_ALLOWANCE)
    for posix, symbols in sorted(EXEC_LIBC_ALLOWANCE.items()):
        _require_nonempty(f"exec libc allowance for {posix}", symbols)
        path = root / posix
        if not path.is_file():
            raise AssertionError(f"exec libc allowance names a missing file: {posix}")
        text = path.read_text(encoding="utf-8")
        foreign = _foreign_re(_aliases(parse_imports(text), _EXTERNAL_CALL_SYMBOL))
        called = {match.group(1) for match in foreign.finditer(stripped_code(text))}
        stale = sorted(symbols - called)
        if stale:
            raise AssertionError(
                f"exec libc allowance for {posix} permits a symbol that file no "
                f"longer calls: {stale}"
            )


def main() -> int:
    """Report every layering violation in this repository.

    Returns:
        0 when the tree obeys the doctrine, 1 otherwise.
    """
    try:
        check_rank_covers_the_tree(REPO_ROOT)
        check_foreign_allowance_is_live(REPO_ROOT)
        report = scan(REPO_ROOT)
    except (AssertionError, OSError) as exc:
        print(f"layering-check: FAIL: {exc}", file=sys.stderr)
        return 1
    for line in report.infos:
        print(f"layering-check: info: {line}")
    if report.violations:
        for line in report.violations:
            print(line, file=sys.stderr)
        print(
            f"layering-check: FAIL: {len(report.violations)} violations",
            file=sys.stderr,
        )
        return 1
    print(f"layering-check: OK ({len(report.infos)} deep imports reported)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
