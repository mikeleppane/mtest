"""The composition proof for the reporter seam (Layer 2).

1.0.0b2 polymorphism is static, so the fan-out from one event to many reporters
is a comptime variadic type-parameter pack, not a runtime trait-object list.
These tests build a `CompositeReporter` of TWO stateful reporters, fan EVERY
event kind through it, and assert BOTH reporters observed all events and updated
their own independent state — the runtime proof the seam works at N=2.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.config import ColorWhen, Verbosity, ShowOutput
from mtest.model import EventKind, Summary, Event, Outcome, TestCounts
from mtest.report import RecordingReporter, ConsoleReporter, CompositeReporter


def _one_of_every_kind() -> List[Event]:
    """A stream carrying exactly one event of each of the six kinds, in order.
    """
    var s = Summary.zeros()
    s.counts[Outcome.PASS.code] = 1
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
    ]


def test_two_recorders_both_see_every_kind_independently() raises:
    # Two reporters of the SAME type, to make "independent state" unambiguous:
    # each must record all six on its own.
    var comp = CompositeReporter(
        Tuple(RecordingReporter(), RecordingReporter())
    )
    var stream = _one_of_every_kind()
    for ref e in stream:
        comp.handle(e)

    # Both reporters saw all six kinds, in order, in their own storage.
    var expected = [
        EventKind.SESSION_STARTED,
        EventKind.WARNING,
        EventKind.PRECOMPILE_FAILED,
        EventKind.FILE_STARTED,
        EventKind.FILE_FINISHED,
        EventKind.SESSION_FINISHED,
    ]
    assert_equal(comp.reporters[0].count(), 6)
    assert_equal(comp.reporters[1].count(), 6)
    for i in range(6):
        assert_true(comp.reporters[0].kind_at(i) == expected[i])
        assert_true(comp.reporters[1].kind_at(i) == expected[i])


def test_heterogeneous_composite_fans_to_recorder_and_console() raises:
    # The real seam: a recorder and a console reporter, different types, composed
    # at comptime. Each processes the same stream into its own independent state.
    var comp = CompositeReporter(
        Tuple(
            RecordingReporter(),
            ConsoleReporter(
                "0.4.0",
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
    var stream = _one_of_every_kind()
    for ref e in stream:
        comp.handle(e)

    # The recorder saw all six events.
    assert_equal(comp.reporters[0].count(), 6)
    assert_true(comp.reporters[0].kind_at(0) == EventKind.SESSION_STARTED)
    assert_true(comp.reporters[0].kind_at(5) == EventKind.SESSION_FINISHED)

    # The console independently rendered facts from the SAME stream: the header
    # (SessionStarted), a verdict token (FileFinished), and the summary band
    # (SessionFinished).
    var rendered = comp.reporters[1].output()
    assert_true("mtest 0.4.0 (mojo 1.0.0b2)" in rendered)
    assert_true("PASS" in rendered)
    assert_true("tests/test_alpha.mojo" in rendered)
    assert_true("1 passed" in rendered)
    assert_true("in 302.4s" in rendered)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
