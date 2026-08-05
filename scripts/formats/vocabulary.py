#!/usr/bin/env python3
"""The one machine-readable copy of mtest's report vocabulary.

Reads `vocabulary.txt` beside this module and exposes it as typed constants.
Every harness that needs an outcome token, an exit code, an event kind or the
stream version imports it from here instead of retyping the literal, and the
oracles that deliberately keep their own literals are reconciled against these
constants by `scripts/tests/test_vocabulary.py`.

The three outcome surfaces are separate mappings keyed by outcome code, never
one token set: the console prints `COMPILE-ERROR`, the report model labels it
`COMPILE_ERROR`, and the JSON wire emits `compile_error`. Collapsing them
would let a harness assert one surface's spelling against another's bytes.

The file is line-oriented rather than JSON because the Mojo side reads it too,
and this tree vendors no JSON parser.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Final


VOCABULARY_PATH: Final[Path] = Path(__file__).resolve().parent / "vocabulary.txt"


class VocabularyError(RuntimeError):
    """The vocabulary file is missing, malformed, or internally inconsistent."""


@dataclass(frozen=True)
class Vocabulary:
    """One parsed vocabulary file, before it is spread over module constants."""

    console: dict[int, str]
    labels: dict[int, str]
    json_tokens: dict[int, str]
    exits: dict[str, int]
    model: tuple[str, ...]
    wire: tuple[str, ...]
    version: int


def _int(field: str, what: str) -> int:
    """Parse one integer field, naming what failed.

    Args:
        field: The raw text.
        what: How to describe the field in a failure message.

    Returns:
        The parsed integer.

    Raises:
        VocabularyError: `field` is not a decimal integer.
    """
    try:
        return int(field)
    except ValueError as exc:
        raise VocabularyError(f"{what} is not an integer: {field!r}") from exc


def _rows(path: Path) -> list[list[str]]:
    """Split every meaningful line of `path` into its space-separated fields.

    Args:
        path: The vocabulary file to read.

    Returns:
        One field list per line, with blank and `#` lines dropped.

    Raises:
        VocabularyError: The file does not exist or cannot be decoded.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise VocabularyError(f"cannot read the vocabulary at {path}: {exc}") from exc
    return [
        stripped.split()
        for stripped in (line.strip() for line in text.splitlines())
        if stripped and not stripped.startswith("#")
    ]


def parse(path: Path = VOCABULARY_PATH) -> Vocabulary:
    """Parse the vocabulary file into its per-surface mappings.

    Args:
        path: The vocabulary file to read.

    Returns:
        The parsed sections. Outcome mappings are keyed by outcome code; the
        event tuples keep file order.

    Raises:
        VocabularyError: A line has the wrong arity or an unknown section, a
            key repeats, a section is empty, the outcome codes are not
            `0..n-1`, or an integer field does not parse.
    """
    console: dict[int, str] = {}
    labels: dict[int, str] = {}
    json_tokens: dict[int, str] = {}
    exits: dict[str, int] = {}
    model: list[str] = []
    wire: list[str] = []
    version: int | None = None

    for row in _rows(path):
        section = row[0]
        if section == "outcome":
            if len(row) != 5:
                raise VocabularyError(f"an outcome row wants 5 fields: {row}")
            code = _int(row[1], "an outcome code")
            if code in console:
                raise VocabularyError(f"outcome code {code} appears twice")
            console[code], labels[code], json_tokens[code] = row[2], row[3], row[4]
        elif section == "exit":
            if len(row) != 3:
                raise VocabularyError(f"an exit row wants 3 fields: {row}")
            if row[1] in exits:
                raise VocabularyError(f"exit name {row[1]!r} appears twice")
            exits[row[1]] = _int(row[2], "an exit code")
        elif section == "event":
            if len(row) != 3 or row[1] not in ("model", "wire"):
                raise VocabularyError(f"an event row wants `event model|wire X`: {row}")
            (model if row[1] == "model" else wire).append(row[2])
        elif section == "stream_version":
            if len(row) != 2 or version is not None:
                raise VocabularyError(f"stream_version must appear exactly once: {row}")
            version = _int(row[1], "the stream version")
        else:
            raise VocabularyError(f"unknown vocabulary section {section!r}")

    if sorted(console) != list(range(len(console))):
        raise VocabularyError(f"outcome codes are not 0..n-1: {sorted(console)}")
    if not console:
        raise VocabularyError("the outcome section is empty")
    if not exits:
        raise VocabularyError("the exit section is empty")
    if not model or not wire:
        raise VocabularyError("an event section is empty")
    if len(set(model)) != len(model) or len(set(wire)) != len(wire):
        raise VocabularyError("an event kind is listed twice")
    if version is None:
        raise VocabularyError("stream_version is missing")

    return Vocabulary(
        console, labels, json_tokens, exits, tuple(model), tuple(wire), version
    )


_VOCABULARY: Final[Vocabulary] = parse()

CONSOLE_TOKENS: Final[dict[int, str]] = _VOCABULARY.console
"""Outcome code -> the console's ASCII verdict token (`COMPILE-ERROR`)."""
REPORT_LABELS: Final[dict[int, str]] = _VOCABULARY.labels
"""Outcome code -> the report model's label (`COMPILE_ERROR`)."""
JSON_TOKENS: Final[dict[int, str]] = _VOCABULARY.json_tokens
"""Outcome code -> the frozen lowercase JSON wire token (`compile_error`)."""
CODE_BY_LABEL: Final[dict[str, int]] = {
    label: code for code, label in _VOCABULARY.labels.items()
}
"""Report label -> outcome code, so a caller can name an outcome to look it up."""
EXIT_CODES: Final[dict[str, int]] = _VOCABULARY.exits
"""Exit-code name without the `EXIT_` prefix -> the process exit status."""
MODEL_EVENT_KINDS: Final[tuple[str, ...]] = _VOCABULARY.model
"""Every `EventKind` the runner dispatches, in discriminant order."""
WIRE_EVENT_KINDS: Final[tuple[str, ...]] = _VOCABULARY.wire
"""The `"event"` tokens the `--json` stream carries: the model set less PROGRESS."""
STREAM_VERSION: Final[int] = _VOCABULARY.version
"""The frozen `--json` stream version on the header line."""

EXIT_SUCCESS: Final[int] = EXIT_CODES["SUCCESS"]
EXIT_FAILURE: Final[int] = EXIT_CODES["FAILURE"]
EXIT_INTERRUPTED: Final[int] = EXIT_CODES["INTERRUPTED"]
EXIT_INTERNAL: Final[int] = EXIT_CODES["INTERNAL_ERROR"]
EXIT_USAGE: Final[int] = EXIT_CODES["USAGE_ERROR"]
EXIT_NOTHING_RAN: Final[int] = EXIT_CODES["NOTHING_RAN"]
