"""The run report inside the session's terminal ordering (Layer 4).

Pins the seam where `finalize_reports` meets `resolve_exit_code`: a report sink
that could not publish is an undelivered terminal artifact, so it escalates an
otherwise green run to exit 3, and it does so at the FIRST resolve — the one
whose code rides `SessionFinished` — rather than at the delivery re-resolve
that follows the terminal writes.

Three of these are regression tests for the `console_dead` term of the single
`delivery_failed` variable. That variable is read twice: once as a fact the
model ranks, and once again as the guard on the delivery re-resolve. Dropping a
term from it would therefore both under-resolve the code and silently disarm
that guard, so a dead console and a dead report are exercised alone and
together, and every case asserts the code the session RETURNED alongside the
code `SessionFinished` carried. Those two agreeing is what proves the run
resolved once.
"""
from std.os import mkdir
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import ColorWhen, ShowOutput, Verbosity
from mtest.exec import ExecRuntime
from mtest.model import (
    EventKind,
    SessionFinishedPayload,
    WarningPayload,
)
from mtest.platform import close_checked_fd, create_unique_temp
from mtest.report import (
    REPORT_STYLE_CONCISE,
    AnnotationsReporter,
    CompositeReporter,
    ConsoleReporter,
    JsonStreamReporter,
    JunitReporter,
    RecordingCoordinator,
    RecordingReporter,
    ReportArtifact,
    ReportCoordinator,
    ReportHeaderFacts,
    ReportWriter,
    StandardReportCoordinator,
    close_json_fd,
    open_json_fd,
)
from mtest.session import run_session

from session_fixtures import SRC_PASS, base_config, temp_root, write_file

comptime _SUMMARY_TABLE_HEADER = (
    "| Path | Outcome | Duration (s) | Passed | Failed | Skipped | Attempts |"
)
"""The Markdown summary table's header row, as `md_summary_table_header` emits
it. Pinned here so the healthy path proves a real document was published rather
than that some file appeared at the target."""


def _facts() -> ReportHeaderFacts:
    """Fixed build-time header facts: the session never names a version."""
    return ReportHeaderFacts("x.y.z", "linux-64")


def _off() -> Optional[ReportArtifact]:
    """An inactive sink."""
    return Optional[ReportArtifact](None)


def _stub_failed_writer() -> ReportWriter:
    """A writer whose Markdown sink reports a finalize failure, and nothing else.

    The Markdown artifact arrives already latched with its descriptor released
    (`fd == -1`), which is the shape `finalize_reports` answers from its
    recorded outcome: it streams nothing, closes nothing, renames nothing, and
    returns `md_failed=True, md_detail="stub"`. No file is touched anywhere, so
    the test observes the session's response to a failed sink and not the
    writer's own publishing machinery, which `test_report_writer` owns.
    """
    return ReportWriter(
        _facts(),
        REPORT_STYLE_CONCISE,
        Optional[ReportArtifact](ReportArtifact("", "", -1, True, "stub")),
        _off(),
        "",
        "",
    )


def _md_writer(
    target: String, spool: String, root: String
) raises -> ReportWriter:
    """A real writer publishing Markdown to `target`, with HTML off."""
    var created = create_unique_temp(target + ".XXXXXX")
    return ReportWriter(
        _facts(),
        REPORT_STYLE_CONCISE,
        Optional[ReportArtifact](
            ReportArtifact(target, created.path, created.fd, False, "")
        ),
        _off(),
        spool,
        root,
    )


def _console() -> ConsoleReporter:
    """A real console reporter, so the coordinator actually drains bytes."""
    return ConsoleReporter(
        "x.y.z",
        ColorWhen.NEVER,
        False,
        False,
        Verbosity.NORMAL,
        ShowOutput.FAILURES,
        "",
        0,
    )


def _read(path: String) raises -> String:
    """Read a whole file back."""
    var body: String
    with open(path, "r") as f:
        body = f.read()
    return body^


def _session_finished_code(rec: RecordingReporter) raises -> Int:
    """The exit code the session's terminal record carried.

    Raises:
        Error: When no `SessionFinished` was recorded at all.
    """
    for i in range(rec.count()):
        var e = rec.event_at(i)
        if e.kind == EventKind.SESSION_FINISHED:
            return e.data[SessionFinishedPayload].exit_code
    raise Error("no SessionFinished event was recorded")


def _warning_index(rec: RecordingReporter, kind: String) raises -> Int:
    """The position of the first warning tagged `kind`, or -1 when absent."""
    for i in range(rec.count()):
        var e = rec.event_at(i)
        if e.kind == EventKind.WARNING:
            if e.data[WarningPayload].warning_kind == kind:
                return i
    return -1


def _run_with_console[
    C: ReportCoordinator
](mut coord: C, root: String, console_fd: Int) raises -> Int:
    """Run one in-process session against a borrowed console descriptor.

    Parameters:
        C: The coordinator the session drives.

    Args:
        coord: The coordinator receiving the event stream.
        root: The invocation root.
        console_fd: The console destination the session writes its rendered
            report to.

    Returns:
        The session's resolved exit code.
    """
    var runtime = ExecRuntime()
    runtime.open()
    var code = run_session(runtime, base_config(), root, coord, console_fd)
    runtime.close()
    return code


def test_failed_report_finalize_escalates_a_green_run_to_exit_3() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter())), _stub_failed_writer()
    )
    var code = run_session(base_config(), root, comp)

    assert_equal(code, 3, "an undelivered run report escalates 0 to 3")
    ref rec = comp.composite.reporters[0]
    assert_equal(
        _session_finished_code(rec),
        3,
        "the terminal record must carry the escalated code, not 0",
    )
    var warned = _warning_index(rec, "report-finalize")
    assert_true(warned >= 0, "no report-finalize warning was emitted")
    assert_true(
        warned < rec.count() - 1,
        "the warning must precede the terminal record",
    )


def test_report_publishes_markdown_on_a_green_run() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    var target = root + "/run-report.md"
    var spool = root + "/report-spool"
    mkdir(spool, 0o700)

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter())),
        _md_writer(target, spool, root),
    )
    var code = run_session(base_config(), root, comp)

    assert_equal(code, 0, "a delivered report leaves the green code alone")
    assert_true(exists(target), "the report was never published")
    var body = _read(target)
    assert_true(
        _SUMMARY_TABLE_HEADER in body, "the summary table header is missing"
    )
    assert_true(
        "| tests/test_a.mojo | PASS |" in body, "the verdict row is missing"
    )


def test_dead_console_escalates_at_the_first_resolve() raises:
    # A descriptor opened for READING is the portable way to force a write
    # failure: it reports EBADF on Linux and Darwin alike, and unlike a closed
    # descriptor it keeps the slot occupied, so nothing the run opens later can
    # land on it and absorb the bytes this test needs to see fail.
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "unwritable-console", "opened read-only\n")
    var events = root + "/events.ndjson"
    var json_fd = open_json_fd(events)

    var code: Int
    var coord = StandardReportCoordinator(
        _console(),
        JsonStreamReporter(json_fd, "x.y.z", True),
        JunitReporter.inert(),
        AnnotationsReporter.inert(),
        ReportWriter.inert(),
    )
    with open(root + "/unwritable-console", "r") as ro:
        code = _run_with_console(coord, root, ro._get_raw_fd())
    _ = close_json_fd(json_fd)

    assert_equal(code, 3, "a console that would not take the report is exit 3")
    var stream = _read(events)
    assert_true(
        '"exit_code":3' in stream,
        (
            "the terminal record must carry 3: console_dead is a first-resolve"
            " fact"
        ),
    )
    assert_false('"exit_code":0' in stream, "the run must not report 0")


def test_dead_console_and_failed_report_resolve_once_to_exit_3() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "unwritable-console", "opened read-only\n")
    var events = root + "/events.ndjson"
    var json_fd = open_json_fd(events)

    var code: Int
    var coord = StandardReportCoordinator(
        _console(),
        JsonStreamReporter(json_fd, "x.y.z", True),
        JunitReporter.inert(),
        AnnotationsReporter.inert(),
        _stub_failed_writer(),
    )
    with open(root + "/unwritable-console", "r") as ro:
        code = _run_with_console(coord, root, ro._get_raw_fd())
    _ = close_json_fd(json_fd)

    assert_equal(code, 3, "two delivery failures still resolve to one 3")
    var stream = _read(events)
    assert_true('"exit_code":3' in stream, "the terminal record must carry 3")
    assert_false('"exit_code":0' in stream, "the run must not report 0")


def test_failed_report_alone_skips_the_delivery_re_resolve() raises:
    # The console here is a REAL writable file, so the only delivery failure is
    # the report. The re-resolve after the terminal writes is guarded by the
    # same named `delivery_failed` the first resolve read: already true, so it
    # is skipped, and the returned code is the one SessionFinished carried.
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    var console_path = root + "/console.txt"
    var console = create_unique_temp(console_path + ".XXXXXX")
    var events = root + "/events.ndjson"
    var json_fd = open_json_fd(events)

    var coord = StandardReportCoordinator(
        _console(),
        JsonStreamReporter(json_fd, "x.y.z", True),
        JunitReporter.inert(),
        AnnotationsReporter.inert(),
        _stub_failed_writer(),
    )
    var code = _run_with_console(coord, root, console.fd)
    _ = close_json_fd(json_fd)
    close_checked_fd(console.fd)

    assert_equal(code, 3, "an undelivered report alone still resolves to 3")
    var rendered = _read(console.path)
    assert_true(
        rendered.byte_length() > 0, "the console must have taken the report"
    )
    var stream = _read(events)
    assert_true(
        '"exit_code":3' in stream,
        "the code was resolved once, before the terminal record",
    )
    assert_false('"exit_code":0' in stream, "the run must not report 0")


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
