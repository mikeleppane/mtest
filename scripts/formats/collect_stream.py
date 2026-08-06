#!/usr/bin/env python3
"""The strict collect-stream consumer: `collect --format json`'s ORACLE.

The reference reader for the newline-delimited JSON listing mtest writes under
`mtest collect --format json`; the normative shape lives in
`docs/collect-stream.md`. It mirrors the run stream's consumer
(`scripts/formats/json_stream.py`) rule for rule, because the two
formats make the same promises and a consumer of one should not have to learn
a second discipline:

STRICT
  * `json.loads` gets a `parse_constant` that REJECTS the non-finite tokens
    (`Infinity`, `-Infinity`, `NaN`). The stream carries no floating-point
    value, so any such token is corruption.
  * an `object_pairs_hook` REJECTS a duplicate key in any object. A well-formed
    record never repeats a key, and a last-wins parse would hide a forger.
  * every NEWLINE-TERMINATED line must parse as a JSON object; a committed line
    that does not parse is CORRUPTION and fails loudly.
  * line 1 must be the frozen header with the known integer `version`.
  * at most ONE `collect_finished` record may appear, and it must be the LAST
    committed record, since collection emits exactly one terminal at the end.

LENIENT (the forward-compatibility obligation)
  * UNKNOWN event kinds and object fields are ACCEPTED and ignored, because a
    v1 consumer must tolerate additive v-next fields and kinds.
  * the `generator` label is never pinned. It carries the release version, so a
    consumer that checked it would break on every bump.
  * a single trailing UNTERMINATED fragment is classified as a TORN tail, the
    truncation signal for a writer that died mid-line, never as corruption.

Run directly (`python -m scripts.formats.collect_stream`) to self-test
against the forward-compatibility and corruption fixtures under
`scripts/fixtures/collect_stream/`.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import json
from pathlib import Path
import sys


COLLECT_STREAM_VERSION = 1
"""The frozen collect-stream version carried on the header line."""

FIXTURE_DIR = Path(__file__).resolve().parents[1] / "fixtures" / "collect_stream"


class CollectStreamError(Exception):
    """A strict-consumer rejection: corruption, a framing break, or a bad header.

    A TORN tail is NOT a CollectStreamError. Truncation is a normal outcome of
    an interrupted or killed collection and is reported as data, not raised.
    """


def _reject_non_finite(token: str) -> object:
    raise CollectStreamError(
        f"non-finite JSON token is forbidden in the collect stream: {token!r}"
    )


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise CollectStreamError(f"duplicate key {key!r} in a stream record")
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
        raise CollectStreamError(f"line does not parse as JSON: {exc}") from exc


@dataclass
class CollectStreamReport:
    """The result of consuming a collect stream: its records and its state."""

    records: list[dict[str, object]] = field(default_factory=list)
    """Every committed (newline-terminated) record, in order."""
    version: int | None = None
    """The header's `version` integer, or `None` when the header was absent."""
    terminal: dict[str, object] | None = None
    """The single `collect_finished` record, or `None` when the stream was torn.
    """
    torn_tail: bool = False
    """Whether a trailing UNTERMINATED fragment was present (a truncation signal).
    """

    @property
    def node_ids(self) -> list[str]:
        """Every `node` record's `node_id`, in stream order.

        A record whose `node_id` is not a string is skipped rather than
        coerced: this list is compared element-for-element against a real
        listing, so a forged non-string must not enter it wearing a value.
        """
        ids: list[str] = []
        for record in self.records:
            if record.get("event") != "node":
                continue
            node_id = record.get("node_id")
            if isinstance(node_id, str):
                ids.append(node_id)
        return ids

    @property
    def exit_code(self) -> int | None:
        """The terminal record's `exit_code`, or None when it is absent.

        None also covers a torn stream (no terminal record at all) and a
        terminal whose `exit_code` is not an integer, so a caller can never
        read a forged non-integer as a process exit status.
        """
        if self.terminal is None:
            return None
        code = self.terminal.get("exit_code")
        return code if isinstance(code, int) and not isinstance(code, bool) else None

    @property
    def nodes(self) -> int | None:
        """The terminal record's declared `nodes` count, or None when absent."""
        if self.terminal is None:
            return None
        count = self.terminal.get("nodes")
        return count if isinstance(count, int) and not isinstance(count, bool) else None


def _require_string(record: dict[str, object], key: str, where: str) -> str:
    """Read one frozen string field off a known record, or reject the record."""
    if key not in record:
        raise CollectStreamError(f"{where} is missing the required field {key!r}")
    value = record[key]
    if not isinstance(value, str):
        raise CollectStreamError(f"{where} field {key!r} is not a string: {value!r}")
    return value


def _require_int(record: dict[str, object], key: str, where: str) -> int:
    """Read one frozen integer field off a known record, or reject the record.

    A JSON `true`/`false` is an `int` to Python and is refused here, so a
    boolean can never be read as a count or an exit status.
    """
    if key not in record:
        raise CollectStreamError(f"{where} is missing the required field {key!r}")
    value = record[key]
    if not isinstance(value, int) or isinstance(value, bool):
        raise CollectStreamError(f"{where} field {key!r} is not an integer: {value!r}")
    return value


def _check_known_records(records: list[dict[str, object]]) -> None:
    """Validate the frozen shape of every record whose kind version 1 defines.

    Unknown kinds are skipped entirely and unknown FIELDS on known kinds are
    ignored, because forward compatibility is the one property that must never
    tighten. What is checked is the frozen half: that a `node` and a
    `collect_finished` carry their documented fields at their documented types,
    and that a `node`'s three fields agree with each other.

    The `node` rules are the ones with teeth, and they take two clauses rather
    than one. `node_id`, `path`, and `name` are three views of one split, so a
    producer that splits at the wrong separator emits a triple that is
    individually well-typed, correctly counted, and correctly ordered —
    invisible to every other check here, and to any check built on top of this
    module. Concatenation alone does not catch it either: splitting a
    multi-separator `node_id` at the FIRST separator instead of the last still
    concatenates back to the right string. The second clause is what closes
    that: `name` is a test function's bare identifier and can never contain
    `::`, so a `name` carrying a separator is a mis-split whatever the `path`
    was.

    That clause is deliberately the only one, and `path` stays unconstrained
    here. mtest itself never emits a `path` containing `::` — §5 of the CLI
    contract refuses such files, so they are never collected — but this module
    validates a WIRE FORMAT rather than one producer, and forward
    compatibility is the property that must never tighten.

    Raises:
        CollectStreamError: The first violation found, naming the record's
            position and the field at fault.
    """
    for index, record in enumerate(records):
        kind = record.get("event")
        where = f"the {kind!r} record at position {index}"
        if kind == "collect":
            _require_int(record, "version", where)
            _require_string(record, "generator", where)
        elif kind == "node":
            node_id = _require_string(record, "node_id", where)
            path = _require_string(record, "path", where)
            name = _require_string(record, "name", where)
            if node_id != f"{path}::{name}":
                raise CollectStreamError(
                    f"{where} does not decompose: node_id {node_id!r} is not "
                    f"path {path!r} + '::' + name {name!r}"
                )
            if "::" in name:
                raise CollectStreamError(
                    f"{where} does not decompose: name {name!r} contains "
                    "'::', so node_id was split at the wrong separator"
                )
        elif kind == "collect_finished":
            _require_int(record, "nodes", where)
            _require_int(record, "exit_code", where)


def parse_collect_stream(
    text: str, *, require_header: bool = True
) -> CollectStreamReport:
    """Strictly consume a `collect --format json` stream, returning its report.

    Args:
        text: The whole stream as written to stdout.
        require_header: Whether line 1 must be the frozen header. False is for
            a caller inspecting a fragment that legitimately has no header. A
            header that IS present is still held to being unique and first.

    Returns:
        The parsed records, the header version, the terminal record when one
        was committed, and the torn-tail flag.

    Raises:
        CollectStreamError: On corruption — a committed line that does not
            parse, a blank committed line, a non-object record, a bad, missing,
            repeated or misplaced header, a duplicate key, a non-finite token,
            a known record whose frozen fields are missing, mistyped, or
            mutually inconsistent, a second terminal, a terminal that is not
            last, or a terminal whose count disagrees with the nodes present. A
            single trailing unterminated fragment is reported as a torn tail,
            not raised.
    """
    if text == "":
        if require_header:
            raise CollectStreamError("empty stream: no header line")
        return CollectStreamReport()

    segments = text.split("\n")
    committed = segments[:-1]
    tail = segments[-1]

    report = CollectStreamReport(torn_tail=(tail != ""))

    for index, segment in enumerate(committed):
        if segment == "":
            raise CollectStreamError(f"blank committed line at position {index}")
        record = strict_loads(segment)
        if not isinstance(record, dict):
            raise CollectStreamError(f"record at position {index} is not a JSON object")
        report.records.append(record)

    _check_known_records(report.records)

    headers = [
        index
        for index, record in enumerate(report.records)
        if record.get("event") == "collect"
    ]
    if len(headers) > 1:
        raise CollectStreamError(
            f"more than one collect header ({len(headers)}) — two streams "
            "spliced together, or a producer that restarted mid-listing"
        )
    if headers and headers[0] != 0:
        raise CollectStreamError(
            f"the collect header is not the first record (position {headers[0]})"
        )
    if headers:
        version = report.records[0]["version"]
        if version != COLLECT_STREAM_VERSION:
            raise CollectStreamError(
                f"unknown collect-stream version {version} (this consumer speaks "
                f"v{COLLECT_STREAM_VERSION})"
            )
        report.version = COLLECT_STREAM_VERSION
    elif require_header:
        if not report.records:
            raise CollectStreamError("stream has no committed header line")
        raise CollectStreamError(
            "first record is not the collect header: "
            f"event={report.records[0].get('event')!r}"
        )

    finishes = [
        index
        for index, record in enumerate(report.records)
        if record.get("event") == "collect_finished"
    ]
    if len(finishes) > 1:
        raise CollectStreamError(
            f"more than one collect_finished record ({len(finishes)}) — a "
            "collection emits exactly one terminal"
        )
    if finishes and finishes[0] != len(report.records) - 1:
        raise CollectStreamError(
            "the collect_finished record is not the last committed record "
            f"(position {finishes[0]} of {len(report.records) - 1})"
        )
    report.terminal = report.records[finishes[0]] if finishes else None
    if report.terminal is not None and report.nodes != len(report.node_ids):
        raise CollectStreamError(
            f"the terminal counts {report.nodes} nodes but the stream carries "
            f"{len(report.node_ids)}"
        )
    return report


# --- self-test against the committed fixtures --------------------------------


def _selftest() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    # Forward-compatibility: an unknown event kind, an unknown field on a known
    # `node`, and an unknown field on the terminal are all ACCEPTED; the nodes,
    # the version, and the terminal still read cleanly. The fixture's generator
    # is deliberately version-neutral, which both proves this consumer never
    # pins that label and keeps the fixture out of the release version sweep.
    fc = (FIXTURE_DIR / "forward_compat.ndjson").read_text(encoding="utf-8")
    report = parse_collect_stream(fc)
    check(
        "forward_compat.version",
        report.version == COLLECT_STREAM_VERSION,
        str(report.version),
    )
    check("forward_compat.terminal", report.terminal is not None, "no terminal")
    check("forward_compat.exit_code", report.exit_code == 0, str(report.exit_code))
    check(
        "forward_compat.node_ids",
        report.node_ids
        == ["tests/test_a.mojo::test_one", "tests/test_b.mojo::test_two"],
        str(report.node_ids),
    )
    check(
        "forward_compat.count_agrees",
        report.nodes == len(report.node_ids),
        f"{report.nodes} vs {len(report.node_ids)}",
    )
    check(
        "forward_compat.unknown_kind_accepted",
        any(r.get("event") == "quantum_flux" for r in report.records),
        "unknown kind was dropped",
    )
    check("forward_compat.not_torn", not report.torn_tail, "unexpected torn tail")

    # Corruption: a committed (newline-terminated) line that does not parse must
    # RAISE, never be silently classified as torn.
    corrupt = (FIXTURE_DIR / "corrupt_midline.ndjson").read_text(encoding="utf-8")
    raised = False
    try:
        parse_collect_stream(corrupt)
    except CollectStreamError:
        raised = True
    check("corrupt_midline.raises", raised, "corruption did not raise")

    # A duplicate key anywhere is corruption.
    raised = False
    try:
        parse_collect_stream('{"event":"collect","version":1,"version":2}\n')
    except CollectStreamError:
        raised = True
    check("duplicate_key.raises", raised, "duplicate key did not raise")

    # A non-finite token is corruption (the stream carries no floats).
    naninf = (
        '{"event":"collect","version":1,"generator":"mtest x.y.z"}\n'
        '{"event":"node","node_id":NaN}\n'
    )
    raised = False
    try:
        parse_collect_stream(naninf)
    except CollectStreamError:
        raised = True
    check("non_finite.raises", raised, "NaN token did not raise")

    if failures:
        for line in failures:
            print(f"FAIL {line}", file=sys.stderr)
        return 1
    print("collect_stream_check: OK (forward-compat + corruption fixtures)")
    return 0


def main(argv: list[str]) -> int:
    """Summarize one stream file, or run the fixture self-test.

    Args:
        argv: The process argv. With a path in `argv[1]`, that stream is
            consumed and summarized; with no path, the committed
            forward-compatibility and corruption fixtures are replayed instead.

    Returns:
        0 when the summary printed or every self-test case held, 1 when a
        self-test case failed. A `CollectStreamError` from a supplied file
        propagates, since corruption is not a summarizable outcome.
    """
    if len(argv) > 1:
        text = Path(argv[1]).read_text(encoding="utf-8")
        report = parse_collect_stream(text)
        print(
            f"records={len(report.records)} version={report.version} "
            f"nodes={len(report.node_ids)} "
            f"terminal={'yes' if report.terminal else 'no'} "
            f"torn_tail={report.torn_tail} exit_code={report.exit_code}"
        )
        return 0
    return _selftest()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
