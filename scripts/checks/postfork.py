#!/usr/bin/env python3
"""Audit every call reachable in the native adapter's post-fork child region.

The platform allowlist is deliberately exact: sigaction, setpgid, chdir, dup2,
close, execve, poll, write, and _exit, plus the compiler-visible errno accessor
(`__errno_location` on Linux or `__error` on Darwin). Every entry is on POSIX's
async-signal-safe list; `sigaction` is permitted because the child restores its
pre-runtime SIGPIPE disposition before execve (a `sigaction` call POSIX
guarantees is async-signal-safe). Repository-defined helpers are never opaque
allowlist entries; their bodies are traversed.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import subprocess
import sys
from typing import Iterator

from scripts.checks import native_abi as native_abi_check


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "native" / "mtest_exec_native.c"
ROOT_FUNCTION = "mtest_child_exec"
OPEN_FUNCTION = "mtest_exec_process_open"
_PLATFORM_ENTRY_POINTS = frozenset(
    {
        "sigaction",
        "setpgid",
        "chdir",
        "dup2",
        "close",
        "execve",
        "poll",
        "write",
        "_exit",
    }
)
_ERRNO_ACCESSOR = {
    "linux": "__errno_location",
    "darwin": "__error",
}
_TRANSPARENT_CALLEE_NODES = frozenset(
    {"ImplicitCastExpr", "ParenExpr", "CStyleCastExpr"}
)


class AuditFailure(RuntimeError):
    """A fail-closed post-fork compiler or call-graph finding."""


@dataclass(frozen=True)
class AuditResult:
    """One compiler variant's complete reachable post-fork call inventory."""

    testing: bool
    local_functions: tuple[str, ...]
    platform_calls: tuple[str, ...]


@dataclass(frozen=True)
class _Call:
    callee_id: str | None
    callee_name: str
    line: int


def platform_allowlist() -> frozenset[str]:
    """Return the exact reviewed external calls for the current platform."""
    try:
        errno_accessor = _ERRNO_ACCESSOR[sys.platform]
    except KeyError as exc:
        raise AuditFailure(
            f"unsupported platform for post-fork audit: {sys.platform}"
        ) from exc
    return _PLATFORM_ENTRY_POINTS | {errno_accessor}


def _walk(node: dict[str, object]) -> Iterator[dict[str, object]]:
    yield node
    for child in node.get("inner", []):
        if isinstance(child, dict):
            yield from _walk(child)


def _has_body(node: dict[str, object]) -> bool:
    return any(
        isinstance(child, dict) and child.get("kind") == "CompoundStmt"
        for child in node.get("inner", [])
    )


def _is_source_definition(node: dict[str, object], source: Path) -> bool:
    """Return whether Clang locates a function body in the audited source."""
    source = source.resolve()
    for location in (node.get("loc", {}), node.get("range", {}).get("begin", {})):
        if "spellingLoc" in location:
            location = location["spellingLoc"]
        if "includedFrom" in location:
            return False
        filename = location.get("file")
        if filename is not None and Path(str(filename)).resolve() != source:
            return False
    return True


def _line(node: dict[str, object], source_text: str) -> int:
    begin = node.get("range", {}).get("begin", {})
    if "expansionLoc" in begin:
        begin = begin["expansionLoc"]
    offset = begin.get("offset")
    if isinstance(offset, int) and 0 <= offset <= len(source_text):
        return source_text.count("\n", 0, offset) + 1
    return int(begin.get("line", 0))


def _offset(node: dict[str, object], *, end: bool = False) -> int:
    location = node.get("range", {}).get("end" if end else "begin", {})
    if "expansionLoc" in location:
        location = location["expansionLoc"]
    offset = location.get("offset")
    if not isinstance(offset, int):
        return -1
    if end:
        token_length = location.get("tokLen", 0)
        if isinstance(token_length, int):
            offset += token_length
    return offset


def _source_segment(node: dict[str, object], source_text: str) -> str:
    begin = _offset(node)
    end = _offset(node, end=True)
    if begin < 0 or end < begin or end > len(source_text):
        return ""
    return source_text[begin:end]


def _direct_callee(call: dict[str, object]) -> tuple[str | None, str]:
    inner = call.get("inner", [])
    if not inner or not isinstance(inner[0], dict):
        return None, "<unresolved-call>"
    expression = inner[0]
    while expression.get("kind") in _TRANSPARENT_CALLEE_NODES:
        children = [
            child
            for child in expression.get("inner", [])
            if isinstance(child, dict)
        ]
        if len(children) != 1:
            return None, "<indirect-call>"
        expression = children[0]
    if expression.get("kind") != "DeclRefExpr":
        return None, "<indirect-call>"
    declaration = expression.get("referencedDecl")
    if not isinstance(declaration, dict):
        return None, "<unresolved-call>"
    if declaration.get("kind") != "FunctionDecl":
        return None, "<indirect-call>"
    identifier = str(declaration.get("id", ""))
    name = str(declaration.get("name", ""))
    if not identifier or not name:
        return None, "<unresolved-call>"
    return identifier, name


def _calls(node: dict[str, object], source_text: str) -> tuple[_Call, ...]:
    calls: list[_Call] = []
    for descendant in _walk(node):
        if descendant.get("kind") != "CallExpr":
            continue
        callee_id, callee_name = _direct_callee(descendant)
        calls.append(
            _Call(
                callee_id,
                callee_name,
                _line(descendant, source_text),
            )
        )
    return tuple(calls)


def _compiler_ast(source: Path, *, testing: bool, cc: str) -> dict[str, object]:
    command = [
        cc,
        *native_abi_check.STRICT_FLAGS,
        f"-DMTEST_EXEC_TESTING={1 if testing else 0}",
        "-I",
        str(ROOT / "native"),
        "-Xclang",
        "-ast-dump=json",
        "-fsyntax-only",
        str(source),
    ]
    compiled = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    variant = int(testing)
    if compiled.returncode != 0:
        diagnostic = compiled.stderr.strip() or compiled.stdout.strip()
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={variant}: post-fork AST compile failed:\n"
            + diagnostic
        )
    try:
        parsed = json.loads(compiled.stdout)
    except json.JSONDecodeError as exc:
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={variant}: Clang emitted invalid AST JSON: {exc}"
        ) from exc
    if not isinstance(parsed, dict):
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={variant}: Clang AST root is not an object"
        )
    return parsed


def audit_source(source: Path, *, testing: bool, cc: str) -> AuditResult:
    """Audit one production/testing preprocessing variant of `source`."""
    source_text = source.read_text(encoding="utf-8")
    ast = _compiler_ast(source, testing=testing, cc=cc)
    definitions: dict[str, dict[str, object]] = {}
    roots: list[str] = []
    open_functions: list[dict[str, object]] = []
    for node in _walk(ast):
        if (
            node.get("kind") != "FunctionDecl"
            or not _has_body(node)
            or not _is_source_definition(node, source)
        ):
            continue
        identifier = str(node.get("id", ""))
        if not identifier:
            raise AuditFailure(
                f"MTEST_EXEC_TESTING={int(testing)}: local function lacks AST id"
            )
        definitions[identifier] = node
        if node.get("name") == ROOT_FUNCTION:
            roots.append(identifier)
        if node.get("name") == OPEN_FUNCTION:
            open_functions.append(node)
    if len(roots) != 1:
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: expected exactly one "
            f"{ROOT_FUNCTION} definition, found {len(roots)}"
        )
    if len(open_functions) != 1:
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: expected exactly one "
            f"{OPEN_FUNCTION} definition, found {len(open_functions)}"
        )

    open_function = open_functions[0]

    branch_candidates: list[dict[str, object]] = []
    for node in _walk(open_function):
        if node.get("kind") != "IfStmt":
            continue
        if any(
            call.callee_name == ROOT_FUNCTION
            for call in _calls(node, source_text)
        ):
            branch_candidates.append(node)
    if len(branch_candidates) != 1:
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: expected exactly one "
            f"post-fork branch calling {ROOT_FUNCTION}, found "
            f"{len(branch_candidates)}"
        )

    allowed = platform_allowlist()
    visited: set[str] = set()
    local_names: set[str] = set()
    platform_calls: set[str] = set()

    def visit_call_sequence(
        calls: tuple[_Call, ...], current_path: tuple[str, ...]
    ) -> None:
        for call in calls:
            call_path = (*current_path, call.callee_name)
            if call.callee_id is not None and call.callee_id in definitions:
                visit(call.callee_id, current_path)
                continue
            if call.callee_id is None:
                raise AuditFailure(
                    f"MTEST_EXEC_TESTING={int(testing)}: forbidden post-fork "
                    f"call at line {call.line}: {' -> '.join(call_path)}"
                )
            if call.callee_name not in allowed:
                raise AuditFailure(
                    f"MTEST_EXEC_TESTING={int(testing)}: forbidden post-fork "
                    f"call at line {call.line}: {' -> '.join(call_path)} "
                    f"(forbidden callee {call.callee_name})"
                )
            platform_calls.add(call.callee_name)

    def reject_implicit_cleanup(
        node: dict[str, object], current_path: tuple[str, ...]
    ) -> None:
        for descendant in _walk(node):
            if descendant.get("kind") != "CleanupAttr":
                continue
            raise AuditFailure(
                f"MTEST_EXEC_TESTING={int(testing)}: forbidden post-fork "
                f"implicit cleanup at line {_line(descendant, source_text)}: "
                f"{' -> '.join(current_path)}"
            )

    def visit_calls(
        node: dict[str, object], current_path: tuple[str, ...]
    ) -> None:
        reject_implicit_cleanup(node, current_path)
        visit_call_sequence(_calls(node, source_text), current_path)

    def visit(identifier: str, path: tuple[str, ...]) -> None:
        if identifier in visited:
            return
        visited.add(identifier)
        function = definitions[identifier]
        name = str(function.get("name", "<unnamed-local>"))
        local_names.add(name)
        current_path = (*path, name)
        visit_calls(function, current_path)

    body_candidates = [
        child
        for child in open_function.get("inner", [])
        if isinstance(child, dict) and child.get("kind") == "CompoundStmt"
    ]
    if len(body_candidates) != 1:
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: expected exactly one "
            f"{OPEN_FUNCTION} body, found {len(body_candidates)}"
        )
    body_statements = [
        child
        for child in body_candidates[0].get("inner", [])
        if isinstance(child, dict)
    ]
    fork_calls = [
        node
        for node in _walk(open_function)
        if node.get("kind") == "CallExpr"
        and _direct_callee(node)[1] == "fork"
    ]
    if len(fork_calls) != 1:
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: expected exactly one fork call "
            f"in {OPEN_FUNCTION}, found {len(fork_calls)}"
        )
    fork_call = fork_calls[0]

    def contains(parent: dict[str, object], target: dict[str, object]) -> bool:
        return any(descendant is target for descendant in _walk(parent))

    fork_indices = [
        index
        for index, statement in enumerate(body_statements)
        if contains(statement, fork_call)
    ]
    branch_indices = [
        index
        for index, statement in enumerate(body_statements)
        if contains(statement, branch_candidates[0])
    ]
    if len(fork_indices) != 1 or len(branch_indices) != 1:
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: could not isolate the "
            "fork-to-child-branch region"
        )
    fork_index = fork_indices[0]
    branch_index = branch_indices[0]
    if fork_index >= branch_index:
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: child branch does not follow fork"
        )

    reject_implicit_cleanup(body_statements[fork_index], ("post-fork-gap",))
    fork_statement_calls = tuple(
        call
        for call in _calls(body_statements[fork_index], source_text)
        if call.callee_name != "fork"
    )
    visit_call_sequence(fork_statement_calls, ("post-fork-gap",))
    for statement in body_statements[fork_index + 1 : branch_index]:
        if statement.get("kind") == "IfStmt":
            children = [
                child
                for child in statement.get("inner", [])
                if isinstance(child, dict)
            ]
            condition = children[0] if children else None
            compact_condition = (
                "".join(_source_segment(condition, source_text).split())
                if condition is not None
                else ""
            )
            if compact_condition == "leader<0":
                visit_calls(condition, ("post-fork-gap",))
                for child_executed_by_success_path in children[2:]:
                    visit_calls(
                        child_executed_by_success_path,
                        ("post-fork-gap",),
                    )
                continue
        visit_calls(statement, ("post-fork-gap",))

    child_parts = [
        child
        for child in branch_candidates[0].get("inner", [])
        if isinstance(child, dict)
    ]
    child_condition = child_parts[0] if child_parts else None
    compact_child_condition = (
        "".join(_source_segment(child_condition, source_text).split())
        if child_condition is not None
        else ""
    )
    if compact_child_condition != "leader==0":
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: post-fork child branch must "
            "be guarded by leader == 0"
        )
    if (
        len(child_parts) != 2
        or child_parts[1].get("kind") != "CompoundStmt"
    ):
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: post-fork child branch must "
            "have exactly one body and no else"
        )
    child_statements = [
        child
        for child in child_parts[1].get("inner", [])
        if isinstance(child, dict)
    ]
    terminal = child_statements[-1] if child_statements else None
    if (
        terminal is None
        or terminal.get("kind") != "CallExpr"
        or _direct_callee(terminal)[1] != "_exit"
    ):
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: post-fork child branch must "
            "end in _exit before parent-only code"
        )

    visit_calls(branch_candidates[0], ("post-fork-child-branch",))
    if (
        len(child_statements) != 2
        or child_statements[0].get("kind") != "CallExpr"
        or _direct_callee(child_statements[0])[1] != ROOT_FUNCTION
    ):
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: post-fork child branch must "
            "contain only mtest_child_exec then _exit"
        )

    if platform_calls != allowed:
        raise AuditFailure(
            f"MTEST_EXEC_TESTING={int(testing)}: reachable platform calls differ "
            "from the exact reviewed allowlist: "
            f"missing={sorted(allowed - platform_calls)}, "
            f"extra={sorted(platform_calls - allowed)}"
        )
    return AuditResult(
        testing=testing,
        local_functions=tuple(sorted(local_names)),
        platform_calls=tuple(sorted(platform_calls)),
    )


def audit_variants(
    source: Path = SOURCE, *, cc: str | None = None
) -> tuple[AuditResult, ...]:
    """Audit production and test variants through the same compiler path."""
    compiler = cc if cc is not None else native_abi_check.compiler()
    return (
        audit_source(source, testing=False, cc=compiler),
        audit_source(source, testing=True, cc=compiler),
    )


def main() -> int:
    """Run both post-fork audits and print their exact reachable inventories."""
    try:
        results = audit_variants()
    except AuditFailure as exc:
        print(f"postfork-check: FAIL: {exc}", file=sys.stderr)
        return 1
    for result in results:
        variant = "testing" if result.testing else "production"
        print(
            f"postfork-check: {variant}: "
            f"local={','.join(result.local_functions)}; "
            f"platform={','.join(result.platform_calls)}"
        )
    print("postfork-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
