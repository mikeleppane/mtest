"""The seam status-latch and the fatal-abort it drives.

The session polls the concrete `JsonStreamReporter`'s write latch through a
fixed comptime tuple index (`run_session[1]`, matching `main`'s composition of
`(console, json_stream)`). When that stream's destination dies, the run's
product can no longer be delivered, so the session performs a FATAL ABORT: it
stops scheduling and resolves exit 3, while STILL dispatching exactly one
`SessionFinished` through the seam (its terminal record is absent from the dead
stream itself — that absence is the truncation signal — but the OTHER composed
reporters, here a recorder standing in for the console, still receive it).

The stream is forced dead the honest way: a real descriptor is opened and then
closed out from under the reporter, so its very first write (the header) fails
and latches before the session schedules anything.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.model import EventKind
from mtest.report import (
    CompositeReporter,
    JsonStreamReporter,
    RecordingReporter,
    close_json_fd,
    open_json_fd,
)
from mtest.session import run_session

from session_fixtures import SRC_PASS, base_config, temp_root, write_file


def test_dead_stream_forces_fatal_abort_exit_3_with_terminal_dispatch() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    var config = base_config()

    # A descriptor opened then closed: the reporter's header write hits a closed
    # fd (EBADF) at construction and latches immediately.
    var dead_fd = open_json_fd(root + "/stream.ndjson")
    close_json_fd(dead_fd)
    var stream = JsonStreamReporter(dead_fd, "0.4.0", True)
    assert_true(stream.status().failed, "precondition: the stream is latched")

    # Fixed composition order: index 0 the recorder (the console's stand-in),
    # index 1 the machine stream the session polls via `run_session[1]`.
    var comp = CompositeReporter(Tuple(RecordingReporter(), stream^))
    var code = run_session[1](config, root, comp)

    # A latched stream is a fatal abort: exit 3, outranking the 1/5/0 a plain
    # run would resolve to.
    assert_equal(code, 3, "a dead stream must resolve to the fatal exit 3")

    # Exactly ONE SessionFinished is still dispatched through the seam, carrying
    # the final resolved code, and the other reporter observes it.
    ref rec = comp.reporters[0]
    var n = rec.count()
    assert_true(n > 0)
    var finishes = 0
    for i in range(n):
        if rec.kind_at(i) == EventKind.SESSION_FINISHED:
            finishes += 1
            assert_equal(
                rec.event_at(i).exit_code,
                3,
                "the dispatched terminal carries the fatal exit code",
            )
    assert_equal(finishes, 1, "exactly one SessionFinished is dispatched")
    assert_true(
        rec.kind_at(n - 1) == EventKind.SESSION_FINISHED,
        "SessionFinished is the last event dispatched",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
