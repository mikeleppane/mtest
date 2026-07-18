#!/usr/bin/env python3
"""Canonicalize a JUnit XML artifact for cross-run DETERMINISM comparison.

The schema/arithmetic oracle (`junit_check.py`) proves ONE artifact is valid.
This proves TWO artifacts of the same suite are the SAME up to the volatile
bits: wall-clock `time` and embedded TEXT. Structure, identity, classification,
and counts are preserved — the `<testsuite>`/`<testcase>` shape, node-id names,
`classname`, the `message`/`type` attributes on outcome children, and the
`tests`/`failures`/`errors`/`skipped` aggregates — while everything that
legitimately varies between two runs of the same suite is masked:

- every `time` attribute (the runner's wall clock), and
- the TEXT CONTENT of `system-out`/`system-err`, `failure`/`error`,
  `stackTrace`, and the `flakyFailure`/`flakyError`/`rerunFailure`/`rerunError`
  children — captured child output, assertion detail, and crash stack traces.
  Their `message`/`type` ATTRIBUTES are kept (they are classification, not
  wall-clock or address noise).

Masking the embedded text as well as `time` is load-bearing: a crash artifact
carries ASLR-randomized addresses in its stack text, so masking `time` alone
would leave two runs' byte streams unequal. Raw masked-`time`-only byte equality
holding anywhere a crash appears would therefore be a bug this masking prevents.

The canonical form is then emitted through C14N so attribute ordering and
whitespace are stable, and two runs' canonical bytes are compared directly.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from xml.etree import ElementTree as ET


_MASK_TIME = "0.000"
"""The single value every `time` attribute is collapsed to."""
_MASK_TEXT = "«masked»"
"""The single value every volatile text body is collapsed to."""
# Elements whose TEXT bodies are volatile between two runs of the same suite
# (captured output, assertion detail, crash stack with ASLR addresses). Their
# `message`/`type` ATTRIBUTES are classification and are deliberately kept.
_MASKED_TEXT_TAGS = frozenset(
    {
        "system-out",
        "system-err",
        "failure",
        "error",
        "stackTrace",
        "flakyFailure",
        "flakyError",
        "rerunFailure",
        "rerunError",
    }
)


class CanonicalizeError(RuntimeError):
    """A parse failure while canonicalizing a JUnit artifact."""


def canonical_bytes(xml_text: str) -> bytes:
    """Return the canonical, volatility-masked byte form of a JUnit document.

    Masks every `time` attribute and the text body of every volatile-text
    element, then serializes through C14N for stable attribute ordering and
    whitespace. Two runs of the same suite produce byte-identical output; a
    change in structure, identity, classification, or counts does not.
    """
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:
        raise CanonicalizeError(f"could not parse JUnit XML: {exc}") from exc
    for element in root.iter():
        if "time" in element.attrib:
            element.set("time", _MASK_TIME)
        if element.tag in _MASKED_TEXT_TAGS and element.text is not None:
            element.text = _MASK_TEXT
    raw = ET.tostring(root, encoding="unicode")
    return ET.canonicalize(raw).encode("utf-8")


def canonical_bytes_of_file(path: Path) -> bytes:
    """Canonicalize the JUnit artifact at `path`."""
    return canonical_bytes(path.read_text(encoding="utf-8"))


def assert_equal_runs(first: Path, second: Path) -> None:
    """Raise CanonicalizeError unless two artifacts share a canonical form."""
    a = canonical_bytes_of_file(first)
    b = canonical_bytes_of_file(second)
    if a != b:
        raise CanonicalizeError(
            f"canonical forms differ between {first} and {second}:\n"
            f"--- {first} ---\n{a.decode('utf-8', 'replace')}\n"
            f"--- {second} ---\n{b.decode('utf-8', 'replace')}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path, help="a JUnit XML artifact")
    parser.add_argument(
        "other",
        type=Path,
        nargs="?",
        help="a second artifact; when given, assert canonical byte equality",
    )
    args = parser.parse_args()
    try:
        if args.other is None:
            sys.stdout.buffer.write(canonical_bytes_of_file(args.artifact))
            return 0
        assert_equal_runs(args.artifact, args.other)
    except CanonicalizeError as exc:
        print(f"junit-canonicalize: FAIL: {exc}", file=sys.stderr)
        return 1
    print("junit-canonicalize: OK: canonical forms are byte-identical")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
