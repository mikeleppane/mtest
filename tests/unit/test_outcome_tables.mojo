"""Each report-layer outcome table pinned to the domain it actually means.

Five surfaces map an `Outcome` to text, and they do not share a domain. Three
are total over the whole vocabulary: `console._verdict_token`,
`report_model.outcome_label`, and `json_stream._outcome_token`. Two answer only
the subset their payload can carry: `annotations._outcome_words` speaks for the
file-level crash class, and `junit_reporter._outcome_diag` for the failing
outcomes a `FileFinished` can hold. Forcing the last two to all thirteen values
would invent wording for outcomes that never reach them, so each is pinned to
its own domain, derived here from the same predicate the product uses rather
than restated as a list.

Every loop is anchored to `Outcome.COUNT`, so a fourteenth outcome reds this
module instead of silently narrowing its proof. That anchor is what guards
`json_stream._outcome_token` in particular: its final branch returns the real
token `not_run` rather than an obviously-wrong sentinel, so an unmapped outcome
would serialize as a plausible lie no consumer could detect. The per-code
expected tokens below are what makes that lie fail a test.

The private tables are imported directly because they are the tables under
test; going through a rendered console line or an NDJSON record would prove the
renderer instead.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.model import Event, FileFinishedPayload, Outcome, ParseDisposition
from mtest.report.annotations import _is_file_level_crash_class, _outcome_words
from mtest.report.console import _verdict_token
from mtest.report.json_stream import _outcome_token
from mtest.report.junit_reporter import _outcome_diag
from mtest.report.report_model import outcome_label


def _finished(outcome: Outcome) -> FileFinishedPayload:
    """A `FileFinished` payload carrying `outcome` and every per-outcome datum.

    Args:
        outcome: The outcome the payload reports.

    Returns:
        The payload, with a signal, an exit status and a deadline populated so
        each table renders its outcome-specific wording. Allocates.
    """
    var e = Event.file_finished(
        "tests/test_a.mojo",
        outcome,
        0.5,
        List[String](),
        0.0,
        List[UInt8](),
        List[UInt8](),
        signal_number=11,
        exit_status=3,
        timeout_seconds=600,
        parse_disposition=ParseDisposition.NO_REPORT,
    )
    return e.data[FileFinishedPayload].copy()


def _has_duplicate(values: List[String]) -> Bool:
    """Whether any two entries of `values` are equal."""
    for i in range(len(values)):
        for j in range(i + 1, len(values)):
            if values[i] == values[j]:
                return True
    return False


# --- The three total tables --------------------------------------------------


def test_console_verdict_token_answers_every_outcome() raises:
    var tokens = List[String]()
    for code in range(Outcome.COUNT):
        var token = _verdict_token(Outcome(code))
        assert_true(
            token != "?",
            "outcome " + String(code) + " fell through to the '?' fallback",
        )
        tokens.append(token^)
    assert_false(_has_duplicate(tokens), "two outcomes share one verdict token")


def test_console_verdict_token_marks_an_outcome_it_does_not_know() raises:
    # The fallback is reachable and obviously wrong, which is what makes the
    # assertion above able to fail.
    assert_equal(_verdict_token(Outcome(Outcome.COUNT)), "?")


def test_report_label_answers_every_outcome() raises:
    var labels = List[String]()
    for code in range(Outcome.COUNT):
        var label = outcome_label(code)
        assert_true(
            label != "OUTCOME(" + String(code) + ")",
            "outcome " + String(code) + " fell through to the code fallback",
        )
        labels.append(label^)
    assert_false(_has_duplicate(labels), "two outcomes share one label")


def test_report_label_names_the_code_it_does_not_know() raises:
    assert_equal(outcome_label(Outcome.COUNT), "OUTCOME(13)")


def _expected_wire_tokens() -> List[String]:
    """The frozen lowercase wire token of each outcome, in discriminant order.
    """
    return [
        String("pass"),
        String("fail"),
        String("skip"),
        String("crash"),
        String("timeout"),
        String("compile_error"),
        String("compile_timeout"),
        String("malformed_suite"),
        String("precompile_error"),
        String("flaky"),
        String("deselected"),
        String("excluded"),
        String("not_run"),
    ]


def test_json_outcome_token_answers_every_outcome() raises:
    # This table's last branch returns `not_run`, a real token, so an outcome
    # that fell through would serialize as a plausible wrong value. The exact
    # per-code expectation is what catches that; a fallback check cannot,
    # because `not_run` is also the correct answer for the last code.
    var expected = _expected_wire_tokens()
    assert_equal(
        len(expected),
        Outcome.COUNT,
        "the wire vocabulary and the outcome vocabulary have different arity",
    )
    var tokens = List[String]()
    for code in range(Outcome.COUNT):
        var token = String(_outcome_token(Outcome(code)))
        assert_equal(
            token,
            expected[code],
            "outcome " + String(code) + " serializes as the wrong token",
        )
        tokens.append(token^)
    assert_false(_has_duplicate(tokens), "two outcomes share one wire token")


# --- The annotations diagnostic map: the file-level crash class ---------------


def test_annotations_words_cover_the_file_level_crash_class() raises:
    # Narrower than `Outcome` on purpose: an annotation exists only for a file
    # whose whole run went abnormal. FAIL is carried by the per-test rows and
    # PRECOMPILE_ERROR is a step-level fact with its own row, so neither is in
    # this domain. The domain is derived from the product's own predicate, so a
    # new crash-class outcome joins it here rather than going unnoticed.
    var domain = List[Outcome]()
    for code in range(Outcome.COUNT):
        if _is_file_level_crash_class(Outcome(code)):
            domain.append(Outcome(code))
    assert_equal(len(domain), 5, "the file-level crash class changed size")

    var words = List[String]()
    for o in domain:
        var w = _outcome_words(_finished(o))
        assert_true(
            w != "failed",
            "outcome " + String(o.code) + " fell through to the bare 'failed'",
        )
        words.append(w^)
    assert_false(
        _has_duplicate(words), "two crash-class outcomes read the same"
    )


def test_annotations_words_fall_back_outside_that_domain() raises:
    # Reachable and deliberately unspecific: a row is only ever built for the
    # domain above, so anything else has no wording to be right about.
    assert_false(_is_file_level_crash_class(Outcome.FAIL))
    assert_equal(_outcome_words(_finished(Outcome.FAIL)), "failed")


# --- The JUnit diagnostic map: the failing outcomes a file can carry ----------


def _junit_domain() -> List[Outcome]:
    """The failing outcomes a `FileFinished` can carry.

    `_outcome_diag` runs only under an `is_failing()` guard, and
    PRECOMPILE_ERROR is never assigned to a file: a precompile failure travels
    as its own event. Derived rather than listed, so a new failing outcome
    joins the domain here.

    Returns:
        The domain in discriminant order. Allocates.
    """
    var out = List[Outcome]()
    for code in range(Outcome.COUNT):
        var o = Outcome(code)
        if o.is_failing() and o != Outcome.PRECOMPILE_ERROR:
            out.append(o)
    return out^


def test_junit_diag_covers_every_failing_outcome_a_file_can_carry() raises:
    var domain = _junit_domain()
    assert_equal(len(domain), 6, "the file-level failing class changed size")

    var labels = List[String]()
    for o in domain:
        var d = _outcome_diag(_finished(o), "captured stderr")
        assert_true(
            d.type_label != "Error",
            "outcome "
            + String(o.code)
            + " fell through to the generic 'Error' descriptor",
        )
        assert_true(
            d.message != "",
            "outcome " + String(o.code) + " carries no diagnostic message",
        )
        labels.append(d.type_label.copy())
    assert_false(
        _has_duplicate(labels), "two failing outcomes share one type label"
    )


def test_junit_diag_falls_back_for_the_outcome_no_file_carries() raises:
    # PRECOMPILE_ERROR is in the failing class but is never assigned to a file,
    # so the default stands as a guard rather than as a claim about a case.
    var d = _outcome_diag(_finished(Outcome.PRECOMPILE_ERROR), "boom")
    assert_equal(d.type_label, "Error")
    assert_equal(d.message, "run error")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
