"""The live-writing `JsonStreamReporter`: header, line framing, and the latch.

These tests drive the reporter against a real, owned file descriptor (a temp
file it opens, or a descriptor closed out from under it) so the write path,
the header-first invariant, and the status latch are all exercised end to end,
never mocked. The pure serializer (`mtest.report.json_stream`) is trusted; this
suite proves the SINK — that lines reach the fd, that a write failure latches
and turns every later `handle` into a no-op, and that an inert reporter writes
nothing at all.
"""
from std.os import getenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.model import Event, Summary
from mtest.report import (
    JsonStreamReporter,
    close_json_fd,
    open_json_fd,
    serialize_event,
    stream_header,
)


def _scratch(name: String) -> String:
    """A unique-ish scratch path under the clean gate TMPDIR."""
    var base = getenv("TMPDIR", "/tmp")
    return base + "/mtest_jsonrep_" + name


def _read_file(path: String) raises -> String:
    """The whole file at `path`, decoded as text."""
    with open(path, "r") as f:
        return f.read()


def _lines(content: String) -> List[String]:
    """Split file content into lines, dropping the trailing empty element."""
    var out = List[String]()
    for ln in content.split("\n"):
        out.append(String(ln))
    if len(out) > 0 and out[len(out) - 1] == "":
        _ = out.pop()
    return out^


def test_header_is_emitted_first_on_construction() raises:
    var path = _scratch("header.ndjson")
    var fd = open_json_fd(path)
    var rep = JsonStreamReporter(fd, "0.4.0", True)
    close_json_fd(fd)
    var content = _read_file(path)
    var lines = _lines(content)
    assert_equal(len(lines), 1)
    assert_equal(lines[0], stream_header("0.4.0"))


def test_events_are_written_as_ndjson_lines() raises:
    var path = _scratch("events.ndjson")
    var fd = open_json_fd(path)
    var rep = JsonStreamReporter(fd, "0.4.0", True)
    rep.handle(Event.file_started("tests/test_a.mojo"))
    rep.handle(Event.session_finished(Summary.zeros(), 0.0, 0))
    close_json_fd(fd)
    var lines = _lines(_read_file(path))
    assert_equal(len(lines), 3)
    assert_equal(lines[0], stream_header("0.4.0"))
    assert_equal(
        lines[1], serialize_event(Event.file_started("tests/test_a.mojo"))
    )
    assert_equal(
        lines[2],
        serialize_event(Event.session_finished(Summary.zeros(), 0.0, 0)),
    )


def test_active_reporter_status_starts_clean() raises:
    var path = _scratch("clean.ndjson")
    var fd = open_json_fd(path)
    var rep = JsonStreamReporter(fd, "0.4.0", True)
    var st = rep.status()
    close_json_fd(fd)
    assert_false(st.failed)


def test_write_failure_latches_and_later_handles_noop() raises:
    # Open a temp file, then close the fd BEFORE handing it to the reporter:
    # the header write hits a closed descriptor (EBADF) and must latch.
    var path = _scratch("latch.ndjson")
    var fd = open_json_fd(path)
    close_json_fd(fd)
    var rep = JsonStreamReporter(fd, "0.4.0", True)
    var st = rep.status()
    assert_true(st.failed)
    assert_true(st.errno != 0)
    # Every later handle is a no-op; the reporter never writes or crashes again.
    rep.handle(Event.file_started("x"))
    rep.handle(Event.session_finished(Summary.zeros(), 0.0, 0))
    var st2 = rep.status()
    assert_true(st2.failed)
    assert_equal(st2.errno, st.errno)


def test_inert_reporter_writes_nothing_and_never_latches() raises:
    var rep = JsonStreamReporter.inert()
    rep.handle(Event.file_started("x"))
    rep.handle(Event.session_finished(Summary.zeros(), 0.0, 0))
    assert_false(rep.status().failed)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
