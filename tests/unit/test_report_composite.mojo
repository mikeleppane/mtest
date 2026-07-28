"""The composition proof for the reporter seam (Layer 2).

1.0.0b2 polymorphism is static, so the fan-out from one event to many reporters
is a comptime variadic type-parameter pack, not a runtime trait-object list.
These tests build a `CompositeReporter` of TWO stateful reporters, fan EVERY
event kind through it, and assert BOTH reporters observed all events and updated
their own independent state — the runtime proof the seam works at N=2.

The expected stream is derived from the closed `EventKind` vocabulary rather
than a hand-counted subset, so a kind added to the model without a matching
composite emission fails here instead of silently escaping the fan-out proof.
The stream is ordered by discriminant, not by session chronology: this is a
dispatch proof, and every reporter must accept every kind independently of the
order a real session would produce.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.config import ColorWhen, Verbosity, ShowOutput
from mtest.model import (
    AttributionDisposition,
    EventKind,
    Summary,
    Event,
    NodeId,
    Outcome,
    TestCounts,
    TestResult,
)
from mtest.report import RecordingReporter, ConsoleReporter, CompositeReporter


def _closed_event_vocabulary() -> List[EventKind]:
    """Every `EventKind` in the closed set, in discriminant order.

    Anchored to `EventKind.COUNT` by its caller, so a kind added to the model
    cannot leave this transcription — and the fan-out proof built on it —
    quietly covering less than the whole vocabulary.
    """
    return [
        EventKind.SESSION_STARTED,
        EventKind.WARNING,
        EventKind.PRECOMPILE_FAILED,
        EventKind.FILE_STARTED,
        EventKind.FILE_FINISHED,
        EventKind.SESSION_FINISHED,
        EventKind.INTERNAL_ERROR,
        EventKind.TEST_REPORTED,
        EventKind.COLLECTION_KNOWN,
        EventKind.ATTEMPT_FINISHED,
        EventKind.CRASH_ATTRIBUTION,
        EventKind.PROGRESS,
    ]


def _one_of_every_kind() -> List[Event]:
    """A stream carrying exactly one event of every kind, in discriminant order.
    """
    var s = Summary.zeros()
    s.counts[Outcome.PASS.code] = 1
    var attempt_argv: List[String] = ["mojo", "run", "tests/test_alpha.mojo"]
    return [
        Event.session_started("tests", "mojo 1.0.0b2", 1, 1),
        Event.warning("stale-exclusion", "old_*"),
        Event.precompile_failed("precompile src/mtest", "error: boom\n", 3),
        Event.file_started("tests/test_alpha.mojo"),
        Event.file_finished(
            "tests/test_alpha.mojo",
            Outcome.PASS,
            0.41,
            ["mojo", "build", "tests/test_alpha.mojo"],
            1.0,
            List[UInt8](),
            List[UInt8](),
        ),
        Event.session_finished(
            s^,
            302.4,
            0,
            test_counts=TestCounts(passed=1, failed=0, skipped=0, deselected=0),
        ),
        Event.internal_error("run", "/usr/bin/mojo", 2),
        Event.test_reported(
            TestResult(
                NodeId("tests/test_alpha.mojo", "test_one"), Outcome.PASS
            )
        ),
        Event.collection_known(selected_test_total=1, deselected_test_total=0),
        Event.attempt_finished(
            "tests/test_alpha.mojo",
            "run",
            attempt_index=1,
            attempts_planned=2,
            term_kind=1,
            term_value=11,
            term_final_kind=0,
            term_final_value=0,
            escalated=False,
            retry_eligible=True,
            classification="signal",
            duration_seconds=0.12,
            captured_stdout=List[UInt8](),
            captured_stderr=List[UInt8](),
            stdout_truncated=False,
            stderr_truncated=False,
            attempt_argv=attempt_argv^,
        ),
        Event.crash_attribution(
            "tests/test_alpha.mojo",
            AttributionDisposition.ATTRIBUTED,
            culprit_test="test_boom",
            isolation_reruns=2,
            attribution_seconds=0.5,
        ),
        Event.progress(1, 1, ["tests/test_alpha.mojo"], [0.4]),
    ]


def test_the_emitted_stream_covers_the_closed_event_vocabulary() raises:
    # The fan-out proof is only exhaustive if the stream itself is: one event
    # per kind, in the vocabulary's own order, over contiguous discriminants.
    # The length is anchored to the model's own COUNT, so a thirteenth kind
    # turns this red instead of leaving a stale twelve agreeing with itself.
    var expected = _closed_event_vocabulary()
    assert_equal(len(expected), EventKind.COUNT)
    var stream = _one_of_every_kind()
    assert_equal(len(stream), len(expected))
    for i in range(len(expected)):
        assert_equal(expected[i].value, i)
        assert_true(stream[i].kind == expected[i])


def test_two_recorders_both_see_every_kind_independently() raises:
    # Two reporters of the SAME type, to make "independent state" unambiguous:
    # each must record every kind on its own.
    var comp = CompositeReporter(
        Tuple(RecordingReporter(), RecordingReporter())
    )
    var expected = _closed_event_vocabulary()
    var stream = _one_of_every_kind()
    for ref e in stream:
        comp.handle(e)

    # Both reporters saw every kind, in order, in their own storage.
    assert_equal(comp.reporters[0].count(), len(expected))
    assert_equal(comp.reporters[1].count(), len(expected))
    for i in range(len(expected)):
        assert_true(comp.reporters[0].kind_at(i) == expected[i])
        assert_true(comp.reporters[1].kind_at(i) == expected[i])


def test_heterogeneous_composite_fans_to_recorder_and_console() raises:
    # The real seam: a recorder and a console reporter, different types, composed
    # at comptime. Each processes the same stream into its own independent state.
    var comp = CompositeReporter(
        Tuple(
            RecordingReporter(),
            ConsoleReporter(
                "0.6.0",
                ColorWhen.NEVER,
                is_tty=False,
                no_color=False,
                verbosity=Verbosity.NORMAL,
                show_output=ShowOutput.FAILURES,
                mtest_build_flags="",
                durations=0,
            ),
        )
    )
    var expected = _closed_event_vocabulary()
    var stream = _one_of_every_kind()
    for ref e in stream:
        comp.handle(e)

    # The recorder saw every kind, first and last included.
    assert_equal(comp.reporters[0].count(), len(expected))
    assert_true(comp.reporters[0].kind_at(0) == EventKind.SESSION_STARTED)
    assert_true(
        comp.reporters[0].kind_at(len(expected) - 1) == EventKind.PROGRESS
    )

    # The console independently rendered facts from the SAME stream: the header
    # (SessionStarted), a verdict token (FileFinished), and the summary band
    # (SessionFinished).
    var rendered = comp.reporters[1].output()
    assert_true("mtest 0.6.0 (mojo 1.0.0b2)" in rendered)
    assert_true("PASS" in rendered)
    assert_true("tests/test_alpha.mojo" in rendered)
    assert_true("1 passed" in rendered)
    assert_true("in 302.4s" in rendered)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
