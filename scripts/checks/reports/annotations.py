#!/usr/bin/env python3
"""Validate mtest's GitHub Actions annotation surface: the workflow-command
GRAMMAR, both escaping contexts, and the collision-proof stop-commands FENCING
(including fence TERMINATION) of echoed child output.

This is the LOCAL proxy for what GitHub itself would do with mtest's stdout under
Actions. It has two independent jobs, exercised together by the e2e hostile-console
cell and available standalone over a captured-output file:

  * `check_tail(lines)` — the annotation TAIL mtest emits after the console band:
    a per-kind-GROUPED sequence (every `::error` line, then every `::warning`
    line, then exactly one `::notice`), each block node-id-sorted, every payload
    escaped (message `%25`/`%0D`/`%0A`; `file=` property additionally `%3A`/`%2C`),
    and never carrying a raw CR/LF that could forge a second command line.

  * `check_fencing(text, ...)` — the stop-commands fences wrapping echoed child
    output: modelled EXACTLY as GitHub processes them (once `::stop-commands::T`
    disables commands, ONLY `::T::` re-enables them — any other `::stop-commands::X`
    in between is inert text), so a forged `::error` sealed inside a fence can
    never land, every opener has its matching resume (no unterminated fence), and
    the real per-run token is high-entropy and distinct from any token a child
    seeded into its own output.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys


class AnnotationsCheckError(RuntimeError):
    """One grammar, escaping, ordering, or fencing violation."""


# A workflow-command annotation line: `::error [props]::message`,
# `::warning [props]::message`, or `::notice::message`. Props (when present) are a
# space then comma-separated key=value pairs; the message runs to end of line.
_ANNOTATION_RE = re.compile(r"^::(error|warning|notice)(?: ([^:]*))?::(.*)$")
_STOP_RE = re.compile(r"^::stop-commands::(\S+)$")
# A per-run fence token: lowercase hex, at least 128 bits (32 hex chars).
_TOKEN_RE = re.compile(r"^[0-9a-f]{32,}$")
_NODE_ID_KEY = "__nodeid__"


@dataclass(frozen=True)
class Annotation:
    """One parsed annotation line."""

    kind: str  # error | warning | notice
    props: str  # raw property segment ("" when none)
    message: str


def parse_annotation(line: str) -> Annotation | None:
    """Parse one annotation line, or None if it is not one."""
    m = _ANNOTATION_RE.match(line)
    if m is None:
        return None
    return Annotation(kind=m.group(1), props=m.group(2) or "", message=m.group(3))


def _is_aggregate(message: str, kind: str) -> bool:
    """Whether `message` is the cap-minus-one rollup line for this kind."""
    return message.startswith("... and ") and message.endswith(
        "more " + kind + "s"
    )


def _node_id_key(message: str) -> str:
    """The node-id-ish sort key: the message up to the first ': ' separator."""
    return message.split(": ", 1)[0]


def _check_escaping(ann: Annotation) -> list[str]:
    """Every escaping invariant a single annotation payload must satisfy."""
    findings: list[str] = []
    # A raw CR or LF in the message would forge a second workflow-command line.
    if "\r" in ann.message or "\n" in ann.message:
        findings.append(f"{ann.kind} message carries a raw CR/LF: {ann.message!r}")
    # The property segment uses `:` and `,` as separators, so a `file=` VALUE must
    # never contain a raw one — they escape to %3A / %2C. We check each value.
    if ann.props:
        for pair in ann.props.split(","):
            if "=" not in pair:
                findings.append(f"{ann.kind} property is not key=value: {pair!r}")
                continue
            _key, value = pair.split("=", 1)
            if ":" in value or "," in value:
                findings.append(
                    f"{ann.kind} property value has an unescaped ':'/',': {value!r}"
                )
            if "%0a" in value.lower() or "%0d" in value.lower():
                # CR/LF should never reach a property value pre-escaped here; a
                # literal one is caught above. (Percent forms are acceptable.)
                pass
    return findings


def check_tail(lines: list[str]) -> dict:
    """Validate the annotation TAIL: grammar, escaping, per-kind grouping, sort.

    `lines` is the sequence of annotation lines mtest emitted (each already a
    single line). Returns a small summary dict; raises AnnotationsCheckError on
    any violation.
    """
    anns = [parse_annotation(ln) for ln in lines]
    for raw, ann in zip(lines, anns):
        if ann is None:
            raise AnnotationsCheckError(f"not a valid annotation line: {raw!r}")

    findings: list[str] = []
    for ann in anns:
        findings.extend(_check_escaping(ann))

    # Per-kind GROUPING: every ::error, then every ::warning, then the notices.
    kinds = [a.kind for a in anns]
    order = {"error": 0, "warning": 1, "notice": 2}
    ranks = [order[k] for k in kinds]
    if ranks != sorted(ranks):
        findings.append(
            "annotation tail is not per-kind grouped "
            f"(error* warning* notice), got kinds {kinds}"
        )
    notices = [a for a in anns if a.kind == "notice"]
    if len(notices) > 1:
        findings.append(f"more than one ::notice ({len(notices)})")

    # Each block is node-id-sorted. The node id is the message up to the first
    # ": " for a per-test/file row, else the whole message. The cap-minus-one
    # aggregate line ("... and N more errors/warnings") is a rollup that the
    # renderer always appends LAST, so it is excluded from the sort and asserted
    # to be terminal instead.
    for kind in ("error", "warning"):
        block = [a.message for a in anns if a.kind == kind]
        aggregates = [m for m in block if _is_aggregate(m, kind)]
        if len(aggregates) > 1:
            findings.append(f"::{kind} block has more than one aggregate line")
        if aggregates and block[-1] != aggregates[0]:
            findings.append(f"::{kind} aggregate line is not last: {block}")
        keys = [_node_id_key(m) for m in block if not _is_aggregate(m, kind)]
        if keys != sorted(keys):
            findings.append(f"::{kind} block is not node-id sorted: {keys}")

    if findings:
        raise AnnotationsCheckError("; ".join(findings))
    return {
        "errors": sum(1 for a in anns if a.kind == "error"),
        "warnings": sum(1 for a in anns if a.kind == "warning"),
        "notices": len(notices),
    }


@dataclass(frozen=True)
class Fence:
    """One stop-commands fence: its token and the [open, close] line span."""

    token: str
    open_line: int
    close_line: int


def scan_fences(text: str) -> tuple[list[Fence], bool]:
    """Scan `text` for stop-commands fences, EXACTLY as GitHub processes them.

    While commands are stopped by `::stop-commands::T`, ONLY the exact line
    `::T::` re-enables them; every other line — including another
    `::stop-commands::X` — is inert content. Returns the closed fences plus a flag
    that is True when a fence was opened and never terminated.
    """
    lines = text.split("\n")
    fences: list[Fence] = []
    active: str | None = None
    start = -1
    for idx, line in enumerate(lines):
        if active is None:
            m = _STOP_RE.match(line)
            if m is not None:
                active = m.group(1)
                start = idx
        elif line == f"::{active}::":
            fences.append(Fence(token=active, open_line=start, close_line=idx))
            active = None
            start = -1
    return fences, active is not None


def _line_index(text: str, needle: str) -> int:
    """The index of the first line CONTAINING `needle`, or -1."""
    for idx, line in enumerate(text.split("\n")):
        if needle in line:
            return idx
    return -1


def check_fencing(
    text: str,
    *,
    forged_needle: str | None = None,
    seeded_token: str | None = None,
    require_fence: bool = True,
) -> dict:
    """Validate the stop-commands fencing over `text`.

    Enforces: every opened fence is TERMINATED; every real token is high-entropy
    (>=128-bit lowercase hex); when `forged_needle` is given, every line carrying
    it is SEALED inside a fence (so the forged command cannot land); when
    `seeded_token` is given, no real fence token equals it (the real token is
    minted after the child exited and is unpredictable to it). Returns a summary;
    raises AnnotationsCheckError on any violation.
    """
    fences, dangling = scan_fences(text)
    findings: list[str] = []

    if dangling:
        findings.append("a stop-commands fence was opened but never terminated")
    if require_fence and not fences:
        findings.append("no stop-commands fence was emitted")

    for fence in fences:
        if not _TOKEN_RE.match(fence.token):
            findings.append(
                f"fence token is not >=128-bit lowercase hex: {fence.token!r}"
            )

    tokens = {f.token for f in fences}
    if seeded_token is not None and seeded_token in tokens:
        findings.append(
            "a real fence token equals the child-seeded token "
            f"{seeded_token!r} — the token was predictable to the child"
        )

    if forged_needle is not None:
        idx = _line_index(text, forged_needle)
        if idx < 0:
            findings.append(f"the forged marker {forged_needle!r} was not echoed")
        else:
            sealed = any(f.open_line < idx < f.close_line for f in fences)
            if not sealed:
                findings.append(
                    f"the forged marker {forged_needle!r} at line {idx} is NOT "
                    "sealed inside any stop-commands fence — it could forge a "
                    "workflow command"
                )

    if findings:
        raise AnnotationsCheckError("; ".join(findings))
    return {"fences": len(fences), "tokens": sorted(tokens)}


def extract_fence_tokens(text: str) -> list[str]:
    """Every terminated fence token in `text` (for per-run-uniqueness checks)."""
    fences, _ = scan_fences(text)
    return [f.token for f in fences]


def annotation_tail_outside_fences(text: str) -> list[str]:
    """mtest's OWN annotation tail: annotation lines NOT sealed in any fence.

    A `::error`/`::warning`/`::notice` line inside a stop-commands fence is echoed
    child output (inert to GitHub), not part of mtest's tail. This returns only
    the lines GitHub would actually process as workflow commands.
    """
    fences, _ = scan_fences(text)
    out: list[str] = []
    for idx, line in enumerate(text.split("\n")):
        if parse_annotation(line) is None:
            continue
        if any(f.open_line < idx < f.close_line for f in fences):
            continue
        out.append(line)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "capture",
        nargs="?",
        type=Path,
        help="a captured mtest stdout file to validate (fencing + any tail)",
    )
    args = parser.parse_args()
    if args.capture is None:
        print("annotations-check: no capture file given; nothing to do")
        return 0
    text = args.capture.read_text(encoding="utf-8", errors="replace")
    try:
        fence_summary = check_fencing(text, require_fence=False)
        tail = annotation_tail_outside_fences(text)
        tail_summary = check_tail(tail) if tail else {}
    except AnnotationsCheckError as exc:
        print(f"annotations-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"annotations-check: OK: {fence_summary} {tail_summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
