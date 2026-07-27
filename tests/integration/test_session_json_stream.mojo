"""The seam status-latch and the fatal-abort it drives.

The session polls the machine stream's write latch through the report
coordinator's named `stream_failed`. When that stream's destination dies, the run's
product can no longer be delivered, so the session performs a FATAL ABORT: it
stops scheduling and resolves exit 3, while STILL dispatching exactly one
`SessionFinished` through the seam (its terminal record is absent from the dead
stream itself — that absence is the truncation signal — but the OTHER composed
reporters, here a recorder standing in for the console, still receive it).

The stream is forced dead the honest way: a real descriptor is opened and then
closed out from under the reporter, so its very first write (the header) fails
and latches before the session schedules anything.

The second case applies the same technique MID-RUN, to a POPULATED parallel
batch: a sibling reporter closes the descriptor on the first file's verdict, so
the stream dies with real work in flight and real work still pending. That pins
the abort's shape rather than just its exit code — the in-flight files still
settle, no further file is ever dispatched, the remainder is accounted NOT-RUN,
and the terminal record is NOT written to the dead stream even though it is
still dispatched through the seam.
"""
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.model import Event, EventKind, Outcome, SessionFinishedPayload
from mtest.report import (
    AnnotationsReporter,
    CompositeReporter,
    JsonStreamReporter,
    JunitReporter,
    RecordingCoordinator,
    RecordingReporter,
    Reporter,
    close_json_fd,
    open_json_fd,
)
from mtest.session import run_session

from session_fixtures import SRC_PASS, base_config, temp_root, write_file

comptime _PEER_RUNNING = "peer_running"
"""The marker the lingering file drops as its run begins."""

# The pair that pins WHICH files are in flight when the stream dies. The waiter
# cannot settle until the linger file's RUN has started, and the linger file
# stays in its run well past that, so the first verdict — the one that kills the
# stream — always lands with a sibling RUN genuinely in flight.
comptime _SRC_WAITS_FOR_PEER = (
    "from std.os.path import exists\n"
    "from std.testing import TestSuite, assert_true\n"
    "from std.time import sleep\n\n\n"
    "def test_waits() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    for _ in range(2000):\n"
    '        if exists("'
    + _PEER_RUNNING
    + '"):\n'
    "            break\n"
    "        sleep(0.01)\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
comptime _SRC_ANNOUNCE_THEN_LINGER = (
    "from std.testing import TestSuite, assert_true\n"
    "from std.time import sleep\n\n\n"
    "def test_lingers() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    '    with open("'
    + _PEER_RUNNING
    + '", "w") as f:\n'
    '        f.write("1")\n'
    "    sleep(3.0)\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)


struct _StreamKiller(Reporter):
    """Closes the machine stream's descriptor on the first file verdict.

    The recording coordinator fans each event to its reporter pack BEFORE the
    machine stream, so closing here means the stream's write of that very
    `FileFinished` is the one that fails and latches — a mid-run death with a
    populated batch around it, not a dead stream the session never got to use.
    """

    var fd: Int
    """The machine stream's descriptor, borrowed for the close."""

    var closed: Bool
    """Whether the descriptor has already been closed; the close fires once."""

    def __init__(out self, fd: Int):
        """Arm the killer over one borrowed descriptor.

        Args:
            fd: The machine stream's descriptor to close on the first verdict.
        """
        self.fd = fd
        self.closed = False

    def handle(mut self, e: Event):
        """Close the descriptor the first time a file settles.

        Args:
            e: The event to inspect, in emission order.
        """
        if not self.closed and e.kind == EventKind.FILE_FINISHED:
            self.closed = True
            _ = close_json_fd(self.fd)


def _read_text(path: String) raises -> String:
    """The whole file at `path`, decoded as text.

    Args:
        path: The file to read.

    Returns:
        The file's contents.

    Raises:
        Error: When the file cannot be opened or read.
    """
    with open(path, "r") as f:
        return f.read()


def test_dead_stream_forces_fatal_abort_exit_3_with_terminal_dispatch() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    var config = base_config()

    # A descriptor opened then closed: the reporter's header write hits a closed
    # fd (EBADF) at construction and latches immediately.
    var dead_fd = open_json_fd(root + "/stream.ndjson")
    _ = close_json_fd(dead_fd)
    var stream = JsonStreamReporter(dead_fd, "0.6.0", True)
    assert_true(stream.status().failed, "precondition: the stream is latched")

    # A recorder stands in for the console; the real machine stream answers the
    # coordinator's stream-health channel, which the session polls by name.
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter())),
        stream^,
        JunitReporter.inert(),
        AnnotationsReporter.inert(),
    )
    var code = run_session(config, root, comp)

    # A latched stream is a fatal abort: exit 3, outranking the 1/5/0 a plain
    # run would resolve to.
    assert_equal(code, 3, "a dead stream must resolve to the fatal exit 3")

    # Exactly ONE SessionFinished is still dispatched through the seam, carrying
    # the final resolved code, and the other reporter observes it.
    ref rec = comp.composite.reporters[0]
    var n = rec.count()
    assert_true(n > 0)
    var finishes = 0
    for i in range(n):
        if rec.kind_at(i) == EventKind.SESSION_FINISHED:
            finishes += 1
            assert_equal(
                rec.event_at(i).data[SessionFinishedPayload].exit_code,
                3,
                "the dispatched terminal carries the fatal exit code",
            )
    assert_equal(finishes, 1, "exactly one SessionFinished is dispatched")
    assert_true(
        rec.kind_at(n - 1) == EventKind.SESSION_FINISHED,
        "SessionFinished is the last event dispatched",
    )


def test_mid_batch_stream_death_stops_dispatch_and_writes_no_terminal_record() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", _SRC_WAITS_FOR_PEER)
    write_file(root, "tests/test_b.mojo", _SRC_ANNOUNCE_THEN_LINGER)
    write_file(root, "tests/test_c.mojo", SRC_PASS)
    write_file(root, "tests/test_d.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2
    # The handshake below can wait on a real build, so the deadline must outlast
    # one; it is never reached.
    config.timeout_secs = 60

    var dest = root + "/stream.ndjson"
    var fd = open_json_fd(dest)
    var stream = JsonStreamReporter(fd, "0.6.0", True)
    assert_false(
        stream.status().failed, "precondition: the stream starts healthy"
    )

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter(), _StreamKiller(fd))),
        stream^,
        JunitReporter.inert(),
        AnnotationsReporter.inert(),
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 3, "a mid-run stream death is the fatal exit 3")
    # The waiter's readiness barrier has a bounded fallthrough, so assert what
    # it was there to guarantee: the marker exists only because the lingering
    # file's RUN wrote it, which is what makes "a sibling RUN was in flight when
    # the stream died" a fact rather than a hope.
    assert_true(
        exists(root + "/" + _PEER_RUNNING),
        "the lingering file must have reached its run before the first verdict",
    )
    ref rec = comp.composite.reporters[0]

    # At capacity two, exactly two files are ever dispatched: the pair in flight
    # when the stream died. The failure is observed at the next scheduling
    # boundary, so no THIRD dispatch happens — c and d never start.
    var started = List[String]()
    var finished = List[String]()
    var finishes = 0
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_STARTED:
            started.append(rec.path_at(i))
        if rec.kind_at(i) == EventKind.FILE_FINISHED:
            finished.append(rec.path_at(i))
            assert_true(
                rec.outcome_at(i) == Outcome.PASS,
                "an in-flight file still settles its real verdict",
            )
        if rec.kind_at(i) == EventKind.SESSION_FINISHED:
            finishes += 1
    assert_equal(len(started), 2, "only the in-flight pair was ever dispatched")
    assert_equal(started[0], "tests/test_a.mojo")
    assert_equal(started[1], "tests/test_b.mojo")
    # Both in-flight files finished: the abort drains rather than abandons. The
    # handshake guarantees b's RUN is live when a's verdict kills the stream, so
    # this pins draining rather than a scheduling accident.
    assert_equal(len(finished), 2)
    assert_equal(finished[0], "tests/test_a.mojo")
    assert_equal(finished[1], "tests/test_b.mojo")

    # Exactly one terminal record is dispatched through the seam, carrying 3.
    assert_equal(finishes, 1, "exactly one SessionFinished is dispatched")
    var last = rec.event_at(rec.count() - 1)
    assert_true(last.kind == EventKind.SESSION_FINISHED)
    ref fin = last.data[SessionFinishedPayload]
    assert_equal(fin.exit_code, 3)
    assert_equal(fin.summary.count_of(Outcome.PASS), 2)
    # c and d are the exact remainder, accounted NOT-RUN.
    assert_equal(fin.summary.count_of(Outcome.NOT_RUN), 2)

    # The stream itself carries no terminal record: the write that would have
    # delivered it is the one that died, and the absence IS the truncation
    # signal. The exit code is the out-of-band signal and must not claim
    # otherwise.
    assert_true(exists(dest), "the stream destination survives the abort")
    var written = _read_text(dest)
    assert_true('"event":"stream"' in written, "the header was written")
    assert_true('"event":"session_started"' in written)
    assert_true('"path":"tests/test_a.mojo"' in written)
    assert_true('"path":"tests/test_b.mojo"' in written)
    assert_false(
        '"event":"file_finished"' in written,
        "the verdict whose write died never reached the stream",
    )
    assert_false(
        '"event":"session_finished"' in written,
        "no terminal record may be reported written to a dead stream",
    )
    assert_false(
        '"path":"tests/test_c.mojo"' in written,
        "a file that was never dispatched has no stream identity",
    )
    assert_false('"path":"tests/test_d.mojo"' in written)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
