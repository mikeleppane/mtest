"""`TerminationKind` and the report-layer decoders that read it.

Five phrase builders across four reporters turn one termination into words:
`console._term_phrase` and `console._precompile_ending_phrase`,
`report_writer._termination_phrase`, `junit_reporter._attempt_diag`, and
`annotations._precompile_ending_words`. Each is asserted over the whole
vocabulary, anchored to `TerminationKind.COUNT`, so a fifth kind reds this
module rather than quietly joining whichever branch a decoder ends on.

Every one of these decoders ends on EXITED as its default, which is also
EXITED's correct answer. What proves no other kind slipped into that default is
that the four phrases are distinct and each names its own kind, which is what
these tests assert.

`exec.Termination` declares the same four discriminants independently, and the
session converts one to the other when it builds an event. The JSON stream
encodes whichever integer survives that conversion, on a wire whose version
cannot move, so the two declarations agreeing is a wire property and is pinned
here rather than left to inspection.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.exec import Termination
from mtest.model import Event, PrecompileFailedPayload, TerminationKind
from mtest.report.annotations import _precompile_ending_words
from mtest.report.console import _precompile_ending_phrase, _term_phrase
from mtest.report.junit_reporter import _AttemptRec, _attempt_diag
from mtest.report.report_writer import _termination_phrase


def _all_kinds() -> List[TerminationKind]:
    """Every value in the vocabulary, once each, in discriminant order."""
    return [
        TerminationKind.EXITED,
        TerminationKind.SIGNALED,
        TerminationKind.TIMED_OUT,
        TerminationKind.SPAWN_FAILED,
    ]


def _has_duplicate(values: List[String]) -> Bool:
    """Whether any two entries of `values` are equal."""
    for i in range(len(values)):
        for j in range(i + 1, len(values)):
            if values[i] == values[j]:
                return True
    return False


def _assert_distinct_over_the_vocabulary(
    phrases: List[String], surface: String
) raises:
    """Every kind produced its own phrase, and no kind is missing.

    Args:
        phrases: One phrase per kind, in discriminant order.
        surface: The decoder's name, for the failure message.

    Raises:
        Error: The arity disagrees with `TerminationKind.COUNT`, or two kinds
            share a phrase, which means one fell into another's branch.
    """
    assert_equal(len(phrases), TerminationKind.COUNT)
    assert_false(_has_duplicate(phrases), surface + ": two kinds read the same")


def test_vocabulary_is_complete_and_distinct() raises:
    var all = _all_kinds()
    assert_equal(len(all), TerminationKind.COUNT)
    for i in range(len(all)):
        for j in range(len(all)):
            if i == j:
                assert_true(all[i] == all[j])
            else:
                assert_true(all[i] != all[j])


def test_model_kinds_carry_the_exec_discriminants() raises:
    # The session converts an `exec.Termination` into the model vocabulary by
    # its integer, and the JSON stream then encodes that integer verbatim. If
    # the two declarations ever disagreed, a supervised child's ending would
    # serialize as another kind on a wire whose version cannot move.
    assert_equal(Termination.EXITED, TerminationKind.EXITED.code)
    assert_equal(Termination.SIGNALED, TerminationKind.SIGNALED.code)
    assert_equal(Termination.TIMED_OUT, TerminationKind.TIMED_OUT.code)
    assert_equal(Termination.SPAWN_FAILED, TerminationKind.SPAWN_FAILED.code)


def test_console_term_phrase_names_each_kind() raises:
    var phrases = List[String]()
    for kind in _all_kinds():
        phrases.append(_term_phrase(kind, 11, False))
    _assert_distinct_over_the_vocabulary(phrases, "_term_phrase")
    assert_equal(phrases[TerminationKind.EXITED.code], "exit 11")
    assert_equal(
        phrases[TerminationKind.SIGNALED.code],
        "signal 11 — SIGSEGV, segmentation fault",
    )
    assert_equal(phrases[TerminationKind.TIMED_OUT.code], "timed out")
    assert_equal(
        phrases[TerminationKind.SPAWN_FAILED.code],
        "spawn failed (errno 11)",
    )


def test_console_precompile_ending_phrase_names_each_kind() raises:
    var phrases = List[String]()
    for kind in _all_kinds():
        phrases.append(_precompile_ending_phrase(kind, 11, False, 600))
    _assert_distinct_over_the_vocabulary(phrases, "_precompile_ending_phrase")
    assert_equal(phrases[TerminationKind.EXITED.code], "exited 11")
    assert_equal(
        phrases[TerminationKind.SIGNALED.code],
        "died by signal 11 (SIGSEGV, segmentation fault)",
    )
    assert_equal(
        phrases[TerminationKind.TIMED_OUT.code], "timed out after 600s"
    )
    assert_equal(
        phrases[TerminationKind.SPAWN_FAILED.code],
        "could not be spawned (errno 11)",
    )


def test_report_writer_termination_phrase_names_each_kind() raises:
    var phrases = List[String]()
    for kind in _all_kinds():
        phrases.append(_termination_phrase(kind, 11, False))
    _assert_distinct_over_the_vocabulary(phrases, "_termination_phrase")
    assert_equal(phrases[TerminationKind.EXITED.code], "exited with status 11")
    assert_equal(phrases[TerminationKind.SIGNALED.code], "killed by signal 11")
    assert_equal(phrases[TerminationKind.TIMED_OUT.code], "timed out")
    assert_equal(
        phrases[TerminationKind.SPAWN_FAILED.code],
        "spawn failed (errno 11)",
    )


def test_junit_attempt_diag_names_each_kind() raises:
    var labels = List[String]()
    var messages = List[String]()
    for kind in _all_kinds():
        var d = _attempt_diag(_AttemptRec(kind, 11, False, "out", "err"))
        labels.append(d.type_label.copy())
        messages.append(d.message.copy())
    _assert_distinct_over_the_vocabulary(labels, "_attempt_diag type")
    _assert_distinct_over_the_vocabulary(messages, "_attempt_diag message")
    assert_equal(labels[TerminationKind.EXITED.code], "ExitFailure")
    assert_equal(labels[TerminationKind.SIGNALED.code], "Signal")
    assert_equal(labels[TerminationKind.TIMED_OUT.code], "Timeout")
    assert_equal(labels[TerminationKind.SPAWN_FAILED.code], "SpawnError")


def _precompile(kind: TerminationKind) -> PrecompileFailedPayload:
    """A `PrecompileFailed` payload whose step ended with `kind`."""
    var e = Event.precompile_failed(
        "src/pkg",
        "",
        0,
        ending_known=True,
        term_kind=kind,
        term_value=11,
        timeout_seconds=600,
    )
    return e.data[PrecompileFailedPayload].copy()


def test_annotations_precompile_ending_words_name_each_kind() raises:
    var phrases = List[String]()
    for kind in _all_kinds():
        phrases.append(_precompile_ending_words(_precompile(kind)))
    _assert_distinct_over_the_vocabulary(phrases, "_precompile_ending_words")
    assert_equal(phrases[TerminationKind.EXITED.code], "exited 11")
    assert_equal(
        phrases[TerminationKind.SIGNALED.code],
        "died by signal 11 (SIGSEGV, segmentation fault)",
    )
    assert_equal(
        phrases[TerminationKind.TIMED_OUT.code], "timed out after 600s"
    )
    assert_equal(
        phrases[TerminationKind.SPAWN_FAILED.code],
        "could not be spawned (errno 11)",
    )


def test_annotations_precompile_ending_words_stay_silent_when_unknown() raises:
    # A caller that knows no ending leaves `ending_known` False, and the row
    # then says nothing about it rather than reading as "exited 0".
    var e = Event.precompile_failed("src/pkg", "", 0)
    assert_equal(_precompile_ending_words(e.data[PrecompileFailedPayload]), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
