"""The interrupt path: exit 2 and the not-yet-run files as NOT_RUN.

An interrupt is never a TIMEOUT verdict. When the interrupt flag is already set,
the session stops scheduling before it starts the next file, marks every
not-yet-completed file NOT_RUN, and resolves exit 2 regardless of anything else.
Kept in its own module because the interrupt flag latches for the process life,
so this test installs handlers, self-signals, asserts, and resets the flag.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.exec import ExecRuntime, interrupt_requested
from mtest.exec.signals import _raise_self, _reset_interrupt
from mtest.model import (
    EventKind,
    Outcome,
    SessionFinishedPayload,
    WarningPayload,
)
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_session

from session_fixtures import SRC_PASS, base_config, temp_root, write_file

comptime _SIGINT = 2


def test_interrupt_before_files_is_exit_2_all_not_run() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)

    # Install the handlers, then self-signal so the flag is already set when the
    # session reaches its first pre-file interrupt check.
    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    _raise_self(_SIGINT)
    assert_true(interrupt_requested(), "flag must be set before the session")

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(runtime, base_config(), root, comp)
    _reset_interrupt()
    runtime.close()

    assert_equal(code, 2, "an interrupt resolves to exit 2, never a TIMEOUT")
    ref rec = comp.composite.reporters[0]
    # The COMPLETE sequence, asserted by kind: no file starts, none finishes,
    # and nothing else happens either. The middle event is not incidental and is
    # not a race — the build cache spawns `<compiler> --version` to key the
    # session, and with the interrupt flag already set the Supervisor kills
    # every active slot on its first sweep, so that child can never report
    # cleanly, the cache is switched off, and the once-per-session `cache-off`
    # warning is emitted between the two frame events. Naming the whole sequence
    # keeps the "and nothing else" half of this case's claim, which a count of
    # file events alone would quietly give up.
    var expected: List[EventKind] = [
        EventKind.SESSION_STARTED,
        EventKind.WARNING,
        EventKind.SESSION_FINISHED,
    ]
    assert_equal(rec.count(), len(expected), "the exact event count")
    for i in range(len(expected)):
        assert_true(
            rec.kind_at(i) == expected[i],
            "event " + String(i) + " has the wrong kind",
        )
    assert_equal(
        rec.event_at(1).data[WarningPayload].warning_kind,
        "cache-off",
        "the one warning is the cache switching itself off, nothing else",
    )
    var last = rec.event_at(rec.count() - 1)
    assert_equal(last.data[SessionFinishedPayload].exit_code, 2)
    # Both discovered files are accounted for as NOT_RUN, none as TIMEOUT.
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 2
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.TIMEOUT), 0
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
