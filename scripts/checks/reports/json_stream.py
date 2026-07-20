#!/usr/bin/env python3
"""The strict machine-event-stream consumer: mtest's own `--json` ORACLE.

This is the reference reader for the newline-delimited JSON event stream mtest
writes under `--json` (the normative shape lives in `docs/json-stream.md`). It is
deliberately STRICT where a real consumer must be strict, and deliberately
LENIENT exactly where the versioning contract demands forward-compatibility:

STRICT
  * `json.loads` is configured with `parse_constant` that REJECTS the non-finite
    tokens (`Infinity`, `-Infinity`, `NaN`) — the v1 stream carries no
    floating-point values at all, so any such token is corruption, not data.
  * an `object_pairs_hook` REJECTS a duplicate key in any object — a well-formed
    record never repeats a key, and a permissive last-wins parse would hide a
    forger.
  * every NEWLINE-TERMINATED line must parse as a JSON object; a committed line
    that does not parse is CORRUPTION and fails loudly.
  * line 1 must be the frozen stream header with the known integer `version`.
  * at most ONE `session_finished` record may appear (the session dispatches
    exactly one terminal event); two would mean a forged or doubled terminal.

LENIENT (the forward-compatibility obligation)
  * UNKNOWN event kinds and UNKNOWN object fields are ACCEPTED and ignored — a
    v1 consumer must tolerate additive v-next fields and kinds (§ versioning).
  * a single trailing UNTERMINATED fragment is classified as a TORN tail (a
    truncation signal — the writer died mid-line), never as corruption. Its
    ABSENCE of a terminal record is how a consumer learns the run was cut short.

Run directly (`python -m scripts.checks.reports.json_stream`) to self-test against the
forward-compatibility and truncation fixtures under `scripts/fixtures/`.
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

STREAM_VERSION = 1
"""The frozen v1 stream version carried on the header line."""

FIXTURE_DIR = Path(__file__).resolve().parents[2] / "fixtures" / "json_stream"


class StreamError(Exception):
    """A strict-consumer rejection: corruption, a framing break, or a bad header.

    A TORN tail is NOT a StreamError — truncation is a normal, expected outcome
    of an interrupted or killed run and is reported as data, not raised.
    """


def _reject_non_finite(token: str) -> object:
    raise StreamError(f"non-finite JSON token is forbidden in the v1 stream: {token!r}")


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise StreamError(f"duplicate key {key!r} in a stream record")
        result[key] = value
    return result


def strict_loads(line: str) -> object:
    """Parse one line under the strict configuration; raise on any violation."""
    try:
        return json.loads(
            line,
            parse_constant=_reject_non_finite,
            object_pairs_hook=_reject_duplicate_keys,
        )
    except json.JSONDecodeError as exc:
        raise StreamError(f"line does not parse as JSON: {exc}") from exc


@dataclass
class StreamReport:
    """The result of consuming a stream: its records and its truncation state."""

    records: list[dict] = field(default_factory=list)
    """Every committed (newline-terminated) record, in order."""
    version: int | None = None
    """The header's `version` integer, or `None` when the header was absent."""
    terminal: dict | None = None
    """The single `session_finished` record, or `None` when the stream was torn."""
    torn_tail: bool = False
    """Whether a trailing UNTERMINATED fragment was present (a truncation signal).
    """

    @property
    def exit_code(self) -> int | None:
        if self.terminal is None:
            return None
        code = self.terminal.get("exit_code")
        return code if isinstance(code, int) else None


def parse_stream(text: str, *, require_header: bool = True) -> StreamReport:
    """Strictly consume a `--json` stream `text`, returning a `StreamReport`.

    Raises `StreamError` on corruption (a committed line that does not parse, a
    bad or missing header, a duplicate key, a non-finite token, or a second
    terminal record). A single trailing unterminated fragment is reported as a
    torn tail, not raised.
    """
    if text == "":
        if require_header:
            raise StreamError("empty stream: no header line")
        return StreamReport()

    segments = text.split("\n")
    committed = segments[:-1]
    tail = segments[-1]

    report = StreamReport(torn_tail=(tail != ""))

    for index, segment in enumerate(committed):
        if segment == "":
            raise StreamError(f"blank committed line at position {index}")
        record = strict_loads(segment)
        if not isinstance(record, dict):
            raise StreamError(f"record at position {index} is not a JSON object")
        report.records.append(record)

    if require_header:
        if not report.records:
            raise StreamError("stream has no committed header line")
        header = report.records[0]
        if header.get("event") != "stream":
            raise StreamError(
                f"first record is not the stream header: event="
                f"{header.get('event')!r}"
            )
        version = header.get("version")
        if not isinstance(version, int):
            raise StreamError(f"header version is not an integer: {version!r}")
        if version != STREAM_VERSION:
            raise StreamError(
                f"unknown stream version {version} (this consumer speaks "
                f"v{STREAM_VERSION})"
            )
        report.version = version

    finishes = [r for r in report.records if r.get("event") == "session_finished"]
    if len(finishes) > 1:
        raise StreamError(
            f"more than one session_finished record ({len(finishes)}) — a "
            "dispatched terminal is unique"
        )
    report.terminal = finishes[0] if finishes else None
    return report


# --- self-test against the committed fixtures --------------------------------


def _selftest() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    # Forward-compatibility: unknown fields on known events AND an unknown event
    # kind are ACCEPTED; the terminal and version still read cleanly.
    fc = (FIXTURE_DIR / "forward_compat.ndjson").read_text(encoding="utf-8")
    report = parse_stream(fc)
    check("forward_compat.version", report.version == STREAM_VERSION, str(report.version))
    check("forward_compat.terminal", report.terminal is not None, "no terminal")
    check("forward_compat.exit_code", report.exit_code == 0, str(report.exit_code))
    check(
        "forward_compat.unknown_kind_accepted",
        any(r.get("event") == "quantum_flux" for r in report.records),
        "unknown kind was dropped",
    )
    check("forward_compat.not_torn", not report.torn_tail, "unexpected torn tail")

    # A killed run: complete lines plus one torn, unterminated tail; no terminal.
    torn = (FIXTURE_DIR / "torn_tail.ndjson").read_text(encoding="utf-8")
    treport = parse_stream(torn)
    check("torn_tail.flagged", treport.torn_tail, "tail not flagged as torn")
    check("torn_tail.no_terminal", treport.terminal is None, "unexpected terminal")

    # Corruption: a committed (newline-terminated) line that does not parse must
    # RAISE, never be silently classified as torn.
    corrupt = (FIXTURE_DIR / "corrupt_midline.ndjson").read_text(encoding="utf-8")
    raised = False
    try:
        parse_stream(corrupt)
    except StreamError:
        raised = True
    check("corrupt_midline.raises", raised, "corruption did not raise")

    # A duplicate key anywhere is corruption.
    dup = '{"event":"stream","version":1,"version":2}\n'
    raised = False
    try:
        parse_stream(dup)
    except StreamError:
        raised = True
    check("duplicate_key.raises", raised, "duplicate key did not raise")

    # A non-finite token is corruption (no floats in the v1 stream).
    naninf = '{"event":"stream","version":1,"generator":"mtest x"}\n{"event":"file_finished","duration_us":NaN}\n'
    raised = False
    try:
        parse_stream(naninf)
    except StreamError:
        raised = True
    check("non_finite.raises", raised, "NaN token did not raise")

    if failures:
        for line in failures:
            print(f"FAIL {line}", file=sys.stderr)
        return 1
    print("json_stream_check: OK (forward-compat + truncation + corruption fixtures)")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        text = Path(argv[1]).read_text(encoding="utf-8")
        report = parse_stream(text)
        print(
            f"records={len(report.records)} version={report.version} "
            f"terminal={'yes' if report.terminal else 'no'} "
            f"torn_tail={report.torn_tail} exit_code={report.exit_code}"
        )
        return 0
    return _selftest()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
