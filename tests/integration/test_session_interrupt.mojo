"""The interrupt path: exit 2 and the not-yet-run files as NOT_RUN.

An interrupt is never a TIMEOUT verdict. When the interrupt flag is already set,
the session stops scheduling before it starts the next file, marks every
not-yet-completed file NOT_RUN, and resolves exit 2 regardless of anything else.
Kept in its own module because the interrupt flag latches for the process life,
so this test installs handlers, self-signals, asserts, and resets the flag.
"""
from std.testing import assert_equal, assert_true

from mtest.exec import ExecRuntime, interrupt_requested
from mtest.exec.signals import _raise_self, _reset_interrupt
from mtest.model import EventKind, Outcome
from mtest.report import CompositeReporter, RecordingReporter
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

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(runtime, base_config(), root, comp)
    _reset_interrupt()
    runtime.close()

    assert_equal(code, 2, "an interrupt resolves to exit 2, never a TIMEOUT")
    ref rec = comp.reporters[0]
    # No file is started: only the session frame.
    assert_equal(rec.count(), 2)
    assert_true(rec.kind_at(0) == EventKind.SESSION_STARTED)
    var last = rec.event_at(1)
    assert_true(last.kind == EventKind.SESSION_FINISHED)
    assert_equal(last.exit_code, 2)
    # Both discovered files are accounted for as NOT_RUN, none as TIMEOUT.
    assert_equal(last.summary.count_of(Outcome.NOT_RUN), 2)
    assert_equal(last.summary.count_of(Outcome.TIMEOUT), 0)
