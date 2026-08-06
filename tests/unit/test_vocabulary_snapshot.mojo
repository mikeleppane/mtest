"""The runner's side of the report-vocabulary reconciliation.

`scripts/formats/vocabulary.txt` is the one machine-readable copy of the
outcome, exit-code and event vocabulary. This module rebuilds every section of
it from the runner's own tables and compares the two, in both directions, per
section. `scripts/tests/test_vocabulary.py` reconciles the harness side against
the same file, so neither side owns it.

Three surfaces spell one outcome three ways on purpose, and each row carries
all three: `console._verdict_token` prints `COMPILE-ERROR`,
`report_model.outcome_label` labels it `COMPILE_ERROR`, and
`json_stream._outcome_token` emits `compile_error` on the wire. The two private
token tables are imported directly because they are the tables under test;
going through a rendered console line or an NDJSON record would prove the
renderer instead.

The wire event set is derived rather than listed: `serialize_event` returns an
empty string for `PROGRESS`, so the kinds that reach a consumer are the ones
whose serialization is non-empty, and the runner itself decides which those
are. The model-kind and exit-code *names* are the one thing written out here,
because a `comptime` discriminant has no runtime spelling; their arity and
order are still pinned against `EventKind.COUNT` and the `EXIT_*` constants.

The file is read from the current working directory, which every runner of a
classified module sets to the repository root. A missing file fails loudly
rather than skipping: an oracle that quietly does nothing is worse than no
oracle.
"""
from std.pathlib import cwd
from std.testing import assert_equal, assert_true, TestSuite

from mtest.model.attribution import AttributionDisposition
from mtest.model.events import Event, EventKind, Summary, TerminationKind
from mtest.model.exit_code import (
    EXIT_FAILURE,
    EXIT_INTERNAL_ERROR,
    EXIT_INTERRUPTED,
    EXIT_NOTHING_RAN,
    EXIT_SUCCESS,
    EXIT_USAGE_ERROR,
)
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome
from mtest.model.test_result import TestResult
from mtest.report.console import _verdict_token
from mtest.report.json_stream import (
    _outcome_token,
    serialize_event,
    stream_header,
)
from mtest.report.report_model import outcome_label


comptime _VOCABULARY_PATH = "scripts/formats/vocabulary.txt"


def _model_event_names() -> List[String]:
    """The `EventKind` discriminants by name, in discriminant order.

    A `comptime` discriminant has no runtime spelling, so the names are written
    out. The product still pins them: one name per `EventKind.COUNT`, each at
    its own `.code`, and every name that reaches the wire equal to the
    uppercased token `serialize_event` emits — the
    `"event":"<snake_case_kind>"` rule `json_stream` documents.

    Returns:
        The twelve names in discriminant order. Allocates.
    """
    return [
        String("SESSION_STARTED"),
        String("WARNING"),
        String("PRECOMPILE_FAILED"),
        String("FILE_STARTED"),
        String("FILE_FINISHED"),
        String("SESSION_FINISHED"),
        String("INTERNAL_ERROR"),
        String("TEST_REPORTED"),
        String("COLLECTION_KNOWN"),
        String("ATTEMPT_FINISHED"),
        String("CRASH_ATTRIBUTION"),
        String("PROGRESS"),
    ]


def _sample_event(code: Int) -> Event:
    """One event of the kind whose discriminant is `code`.

    Args:
        code: An `EventKind.code` value in `0..<EventKind.COUNT`.

    Returns:
        The smallest event of that kind. Allocates its payload.
    """
    if code == EventKind.SESSION_STARTED.value:
        return Event.session_started("root", "mojo", 1, 0)
    if code == EventKind.WARNING.value:
        return Event.warning("stale", "p")
    if code == EventKind.PRECOMPILE_FAILED.value:
        return Event.precompile_failed("precompile", "", 0)
    if code == EventKind.FILE_STARTED.value:
        return Event.file_started("p")
    if code == EventKind.FILE_FINISHED.value:
        return Event.file_finished(
            "p",
            Outcome.PASS,
            0.0,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
        )
    if code == EventKind.SESSION_FINISHED.value:
        var counts = List[Int]()
        for _ in range(Outcome.COUNT):
            counts.append(0)
        return Event.session_finished(Summary(counts^), 0.0, 0)
    if code == EventKind.INTERNAL_ERROR.value:
        return Event.internal_error("run", "p", 0)
    if code == EventKind.TEST_REPORTED.value:
        return Event.test_reported(TestResult(NodeId("p", "n"), Outcome.PASS))
    if code == EventKind.COLLECTION_KNOWN.value:
        return Event.collection_known(0, 0)
    if code == EventKind.ATTEMPT_FINISHED.value:
        return Event.attempt_finished(
            "p",
            "run",
            1,
            2,
            TerminationKind.EXITED,
            0,
            TerminationKind.EXITED,
            0,
            False,
            False,
            "signal",
            0.0,
            List[UInt8](),
            List[UInt8](),
            False,
            False,
            List[String](),
        )
    if code == EventKind.CRASH_ATTRIBUTION.value:
        return Event.crash_attribution(
            "p", AttributionDisposition.ATTRIBUTED, "n", 0, 0.0
        )
    return Event.progress(0, 1, List[String](), List[Float64]())


def _wire_token(line: String) raises -> String:
    """The `"event"` token of one serialized NDJSON record.

    Args:
        line: A `serialize_event` result. An empty line means the kind never
            reaches the wire.

    Returns:
        The token, or an empty string for an unserialized kind.

    Raises:
        Error: `line` is non-empty but carries no `"event":"…"` field.
    """
    if line == "":
        return String("")
    comptime OPEN = '{"event":"'
    if not line.startswith(OPEN):
        raise Error("vocabulary: no leading event field in: " + line)
    var rest = String(line[byte = OPEN.byte_length() :])
    var end = rest.find('"')
    if end < 0:
        raise Error("vocabulary: unterminated event field in: " + line)
    return String(rest[byte=:end])


def _expected() raises -> List[String]:
    """Every vocabulary line, rebuilt from the runner's own tables.

    Returns:
        The lines in file order. Allocates.

    Raises:
        Error: A serialized event carries no readable `"event"` field, or the
            stream header carries no readable version.
    """
    var lines = List[String]()

    for code in range(Outcome.COUNT):
        var o = Outcome(code)
        lines.append(
            String("outcome ")
            + String(code)
            + " "
            + _verdict_token(o)
            + " "
            + outcome_label(code)
            + " "
            + String(_outcome_token(o))
        )

    lines.append(String("exit SUCCESS ") + String(EXIT_SUCCESS))
    lines.append(String("exit FAILURE ") + String(EXIT_FAILURE))
    lines.append(String("exit INTERRUPTED ") + String(EXIT_INTERRUPTED))
    lines.append(String("exit INTERNAL_ERROR ") + String(EXIT_INTERNAL_ERROR))
    lines.append(String("exit USAGE_ERROR ") + String(EXIT_USAGE_ERROR))
    lines.append(String("exit NOTHING_RAN ") + String(EXIT_NOTHING_RAN))

    for name in _model_event_names():
        lines.append(String("event model ") + name)

    for code in range(EventKind.COUNT):
        var token = _wire_token(serialize_event(_sample_event(code)))
        if token != "":
            lines.append(String("event wire ") + token)

    lines.append(String("stream_version ") + String(_header_version()))
    return lines^


def _header_version() raises -> Int:
    """The stream version the frozen header line carries.

    Returns:
        The integer `version` field of `stream_header`.

    Raises:
        Error: The header does not carry a readable `version` field.
    """
    var head = stream_header("0")
    comptime OPEN = '"version":'
    var at = head.find(OPEN)
    if at < 0:
        raise Error("vocabulary: no version field in the stream header")
    var rest = String(head[byte = at + OPEN.byte_length() :])
    var end = rest.find(",")
    if end < 0:
        raise Error(
            "vocabulary: unterminated version field in the stream header"
        )
    return Int(String(rest[byte=:end]))


def _committed() raises -> List[String]:
    """The committed vocabulary file, comments and blank lines dropped.

    Returns:
        The meaningful lines in file order. Allocates.

    Raises:
        Error: The file is absent from the working directory, which the
            contract requires to be the repository root, or it is empty.
    """
    var path = String(cwd()) + "/" + _VOCABULARY_PATH
    var text: String
    try:
        with open(path, "r") as source:
            text = source.read()
    except e:
        raise Error(
            "vocabulary: cannot read "
            + path
            + " -- a classified module runs from the repository root: "
            + String(e)
        )
    var lines = List[String]()
    for raw in text.split("\n"):
        var line = String(raw.strip())
        if line == "" or line.startswith("#"):
            continue
        lines.append(line^)
    if len(lines) == 0:
        raise Error("vocabulary: " + path + " carries no vocabulary line")
    return lines^


def _section(lines: List[String], prefix: String) -> List[String]:
    """The lines of one section, in order.

    Args:
        lines: Vocabulary lines, from either side.
        prefix: The section's leading words, including the trailing space.

    Returns:
        Every matching line, prefix included. Allocates.
    """
    var out = List[String]()
    for line in lines:
        if line.startswith(prefix):
            out.append(line.copy())
    return out^


def _quoted(line: String) -> String:
    """`line` in single quotes, for a mismatch message."""
    return "'" + line + "'"


def _mismatch(
    section: String, expected: List[String], actual: List[String]
) -> String:
    """The first disagreement between two sections, in both directions.

    Args:
        section: The section's name, for the message.
        expected: What the runner's tables produce.
        actual: What the committed file carries.

    Returns:
        An empty string when the two agree, otherwise a message naming the
        section, the position and both sides. Allocates.
    """
    var shared = min(len(expected), len(actual))
    for i in range(shared):
        if expected[i] != actual[i]:
            return (
                section
                + " row "
                + String(i)
                + ": the runner produces "
                + _quoted(expected[i])
                + ", the file carries "
                + _quoted(actual[i])
            )
    if len(expected) > len(actual):
        return (
            section
            + ": the file is missing "
            + _quoted(expected[shared])
            + " and "
            + String(len(expected) - shared - 1)
            + " later row(s)"
        )
    if len(actual) > len(expected):
        return (
            section
            + ": the file carries an unproduced row "
            + _quoted(actual[shared])
            + " and "
            + String(len(actual) - shared - 1)
            + " later row(s)"
        )
    return String("")


def _all_mismatches(
    expected: List[String], actual: List[String]
) -> List[String]:
    """Every section's disagreement between two whole vocabularies.

    Args:
        expected: What the runner's tables produce.
        actual: What the committed file carries.

    Returns:
        One message per disagreeing section, plus one per line belonging to no
        section at all; empty when the two agree. Allocates.
    """
    var sections: List[String] = [
        String("outcome "),
        String("exit "),
        String("event model "),
        String("event wire "),
        String("stream_version "),
    ]
    var found = List[String]()
    for p in sections:
        var message = _mismatch(
            String(p.strip()), _section(expected, p), _section(actual, p)
        )
        if message != "":
            found.append(message^)
    # The section comparisons above only see lines they claim, so a line under
    # no section would be invisible to every one of them.
    for line in actual:
        var claimed = False
        for p in sections:
            if line.startswith(p):
                claimed = True
                break
        if not claimed:
            found.append("unknown section: " + _quoted(line))
    return found^


def test_event_kind_names_match_the_model_and_the_wire() raises:
    """The written kind names carry the product's arity, order and spelling."""
    var names = _model_event_names()
    assert_equal(len(names), EventKind.COUNT)
    for code in range(EventKind.COUNT):
        var e = _sample_event(code)
        assert_equal(
            e.kind.value,
            code,
            "the sample event for discriminant "
            + String(code)
            + " has another kind",
        )
        var token = _wire_token(serialize_event(e))
        if token != "":
            assert_equal(
                names[code],
                token.upper(),
                "the wire token and the model kind name disagree",
            )


def test_committed_vocabulary_matches_the_runner() raises:
    """Every section of the committed file equals what the runner produces."""
    var mismatches = _all_mismatches(_expected(), _committed())
    var report = String("")
    for message in mismatches:
        report += "\n  " + message
    assert_equal(
        len(mismatches),
        0,
        "scripts/formats/vocabulary.txt disagrees with the runner:" + report,
    )


def test_the_comparison_sees_a_perturbed_line() raises:
    """The oracle has teeth: one edited row is reported, per section."""
    var truth = _expected()

    var edited = truth.copy()
    edited[5] = String("outcome 5 COMPILE_ERROR COMPILE_ERROR compile_error")
    var found = _all_mismatches(truth, edited)
    assert_equal(len(found), 1)
    assert_true(
        "outcome row 5" in found[0] and "COMPILE-ERROR" in found[0],
        "a console token swapped for the report label went unreported: "
        + found[0],
    )

    var dropped = truth.copy()
    _ = dropped.pop(len(truth) - 1)
    var missing = _all_mismatches(truth, dropped)
    assert_equal(len(missing), 1)
    assert_true(
        "stream_version" in missing[0] and "missing" in missing[0],
        "a dropped stream_version row went unreported: " + missing[0],
    )

    var extra = truth.copy()
    extra.append(String("event wire progress"))
    var surplus = _all_mismatches(truth, extra)
    assert_equal(len(surplus), 1)
    assert_true(
        "unproduced row" in surplus[0] and "progress" in surplus[0],
        "a wire row the runner never emits went unreported: " + surplus[0],
    )

    var foreign = truth.copy()
    foreign.append(String("verdict 0 PASS"))
    var unknown = _all_mismatches(truth, foreign)
    assert_equal(len(unknown), 1)
    assert_true(
        "unknown section" in unknown[0] and "verdict 0 PASS" in unknown[0],
        "a line under no section went unreported: " + unknown[0],
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
