"""The report coordinator contract, driven through BOTH its conformers (Layer 2).

`ReportCoordinator` names the lifecycle interactions the session needs — event
fan-out, machine-stream health, JUnit not-run synthesis and finalize, the
annotation tail, and the console's rendered output and fence token — so the
session never reaches a concrete reporter at a tuple index. These tests drive
the production coordinator and the recording one through the SAME generic
consumer, and pin that routing a stream through the coordinator renders bytes
byte-identical to the composite fan-out it replaces.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import ColorWhen, ShowOutput, Verbosity
from mtest.model import (
    Event,
    EventKind,
    NodeId,
    NotRunRecord,
    NotRunReason,
    Outcome,
    Summary,
    TestCounts,
    TestResult,
)
from mtest.platform import create_unique_temp
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
    ReportFinalizeContext,
    ReportHeaderFacts,
    ReportWriter,
    StandardReportCoordinator,
)

from tmptree import temp_root


def _console() -> ConsoleReporter:
    """A console reporter with every rendering knob fixed, for byte equality."""
    return ConsoleReporter(
        "0.6.0",
        ColorWhen.NEVER,
        is_tty=False,
        no_color=False,
        verbosity=Verbosity.NORMAL,
        show_output=ShowOutput.FAILURES,
        mtest_build_flags="",
        durations=0,
    )


def _stream() -> List[Event]:
    """One event of every kind, including a real failure the tail annotates."""
    var s = Summary.zeros()
    s.counts[Outcome.PASS.code] = 1
    s.counts[Outcome.COMPILE_ERROR.code] = 1
    return [
        Event.session_started("tests", "mojo 1.0.0b2", 2, 1),
        Event.warning("stale-exclusion", "old_*"),
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
        Event.file_started("tests/test_beta.mojo"),
        Event.file_finished(
            "tests/test_beta.mojo",
            Outcome.COMPILE_ERROR,
            0.62,
            ["mojo", "build", "tests/test_beta.mojo"],
            1.0,
            List[UInt8](),
            List[UInt8](),
        ),
        Event.session_finished(
            s^,
            302.4,
            1,
            test_counts=TestCounts(passed=1, failed=0, skipped=0, deselected=0),
        ),
    ]


def _drive[C: ReportCoordinator](mut c: C, events: List[Event]) -> Bool:
    """Push a stream through any coordinator and poll its stream health.

    Generic over the trait, so a call proves the trait is actually usable as the
    session's dependency rather than a shape only one struct satisfies.
    """
    for ref e in events:
        c.handle(e)
    return c.stream_failed()


def test_standard_coordinator_console_bytes_match_the_composite() raises:
    # The byte-equality guard: the SAME stream through the coordinator and
    # through the composite fan-out it replaces must render identical console
    # bytes. Compared exactly, never by substring.
    var coord = StandardReportCoordinator(
        _console(),
        JsonStreamReporter.inert(),
        JunitReporter.inert(),
        AnnotationsReporter(active=True),
    )
    var comp = CompositeReporter(
        Tuple(
            _console(),
            JsonStreamReporter.inert(),
            JunitReporter.inert(),
            AnnotationsReporter(active=True),
        )
    )

    var events = _stream()
    _ = _drive(coord, events)
    for ref e in events:
        comp.handle(e)

    assert_equal(
        coord.console_output(),
        comp.reporters[0].output(),
        "coordinator console bytes diverged from the composite fan-out",
    )
    assert_true(
        coord.console_output().byte_length() > 0,
        "a byte-equality guard over two empty strings proves nothing",
    )


def test_standard_coordinator_incremental_drain_reconstructs_output() raises:
    # The chunk-queue invariant: draining the console incrementally after each
    # dispatch, then one closing drain for the tail, must concatenate to the
    # exact bytes `console_output()` renders in a single shot. This is what lets
    # a driver flush the console as the run progresses without moving a single
    # output byte. The fixture ends on a COMPILE-ERROR file, so `_sections` is
    # non-empty and the closing drain exercises the sections-and-summary tail.
    var coord = StandardReportCoordinator(
        _console(),
        JsonStreamReporter.inert(),
        JunitReporter.inert(),
        AnnotationsReporter.inert(),
    )
    var events = _stream()
    var drained = String("")
    for ref e in events:
        coord.handle(e)
        drained += coord.drain_console(closing=False)
    drained += coord.drain_console(closing=True)

    assert_equal(
        drained,
        coord.console_output(),
        "incremental drains plus the closing tail diverged from console_output",
    )
    assert_true(
        coord.console_output().byte_length() > 0,
        "an equality guard over two empty strings proves nothing",
    )


def test_standard_coordinator_annotation_tail_matches_the_composite() raises:
    var coord = StandardReportCoordinator(
        _console(),
        JsonStreamReporter.inert(),
        JunitReporter.inert(),
        AnnotationsReporter(active=True),
    )
    var comp = CompositeReporter(
        Tuple(
            _console(),
            JsonStreamReporter.inert(),
            JunitReporter.inert(),
            AnnotationsReporter(active=True),
        )
    )

    var events = _stream()
    _ = _drive(coord, events)
    for ref e in events:
        comp.handle(e)

    var tail = coord.annotation_tail()
    var expected = comp.reporters[3].render()
    assert_equal(len(tail), len(expected), "annotation tail length diverged")
    assert_true(len(tail) > 0, "the fixture must produce a non-empty tail")
    for i in range(len(tail)):
        assert_equal(tail[i], expected[i], "an annotation line diverged")


def test_standard_coordinator_reports_inert_lifecycle_channels() raises:
    var coord = StandardReportCoordinator(
        _console(),
        JsonStreamReporter.inert(),
        JunitReporter.inert(),
        AnnotationsReporter.inert(),
    )
    var events = _stream()
    assert_false(
        _drive(coord, events), "an inert stream must never latch a failure"
    )
    # An inert JUnit reporter is a no-op success on both lifecycle channels.
    coord.note_not_run(["tests/test_gamma.mojo"])
    assert_false(coord.finalize_junit(0, 0).failed)
    assert_equal(len(coord.annotation_tail()), 0)
    assert_equal(coord.fence_token(), "")


def test_standard_coordinator_note_not_run_records_reaches_an_inert_writer() raises:
    # The records go to the report writer's slot and nowhere else: with the
    # inert writer the old four-argument constructor installs, they are
    # absorbed silently and every other coordinator surface stays untouched.
    var coord = StandardReportCoordinator(
        _console(),
        JsonStreamReporter.inert(),
        JunitReporter.inert(),
        AnnotationsReporter.inert(),
    )
    coord.note_not_run_records(
        [NotRunRecord("tests/test_gamma.mojo", NotRunReason.LIMIT_REACHED)]
    )
    assert_equal(coord.console_output(), "")
    assert_false(coord.finalize_junit(0, 0).failed)
    var fin = coord.finalize_reports(_report_ctx())
    assert_false(fin.md_failed, "an inert writer finalizes clean")
    assert_false(fin.html_failed, "an inert writer finalizes clean")


def _report_ctx() -> ReportFinalizeContext:
    """A run-wide report context whose every conditional fact is off."""
    var counts = List[Int]()
    for _ in range(Outcome.COUNT):
        counts.append(0)
    return ReportFinalizeContext(
        counts^,
        tests_passed=0,
        tests_failed=0,
        tests_skipped=0,
        flaky_files=0,
        built_files=0,
        cached_files=0,
        wall_seconds=0.5,
        interrupted=False,
        drift=False,
        workers=1,
        shuffle=False,
        shuffle_seed=0,
        shard_label="",
    )


def _md_writer(target: String) raises -> ReportWriter:
    """A writer with only the Markdown sink active, publishing at `target`."""
    var created = create_unique_temp(target + ".XXXXXX")
    return ReportWriter(
        ReportHeaderFacts("x.y.z", "linux-64"),
        REPORT_STYLE_CONCISE,
        Optional[ReportArtifact](
            ReportArtifact(target, created.path, created.fd, False, "")
        ),
        Optional[ReportArtifact](None),
        temp_root(),
        "/run/root",
    )


def _published(path: String) raises -> String:
    """Read a published report back."""
    var body: String
    with open(path, "r") as f:
        body = f.read()
    return body^


def test_standard_coordinator_fans_events_and_records_to_the_writer() raises:
    # The production coordinator drives the writer from the SAME event stream
    # it fans everywhere else, and routes the classified not-run records to it.
    var target = temp_root() + "/report.md"
    var coord = StandardReportCoordinator(
        _console(),
        JsonStreamReporter.inert(),
        JunitReporter.inert(),
        AnnotationsReporter.inert(),
        _md_writer(target),
    )
    var events = _stream()
    _ = _drive(coord, events)
    coord.note_not_run_records(
        [NotRunRecord("tests/test_gamma.mojo", NotRunReason.LIMIT_REACHED)]
    )
    var fin = coord.finalize_reports(_report_ctx())

    assert_false(fin.md_failed, "the markdown sink must publish")
    assert_equal(fin.md_detail, "")
    var body = _published(target)
    assert_true(
        "| tests/test_alpha.mojo | PASS |" in body, "no row for the passed file"
    )
    assert_true(
        "| tests/test_beta.mojo | COMPILE_ERROR |" in body,
        "no row for the failed file",
    )
    assert_true(
        "| tests/test_gamma.mojo | NOT_RUN |" in body,
        "the not-run record never reached the writer",
    )


def test_recording_coordinator_wires_a_report_writer() raises:
    # The driver shape: a recorder stands in for the console while a REAL
    # writer answers the report channel. The records still accumulate for the
    # driver to read AND reach the writer.
    var target = temp_root() + "/report.md"
    var coord = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter())), _md_writer(target)
    )
    var events = _stream()
    _ = _drive(coord, events)
    coord.note_not_run_records(
        [NotRunRecord("tests/test_gamma.mojo", NotRunReason.LIMIT_REACHED)]
    )
    var fin = coord.finalize_reports(_report_ctx())

    assert_equal(coord.composite.reporters[0].count(), len(events))
    assert_equal(len(coord.not_run_records), 1)
    assert_false(fin.md_failed, "the markdown sink must publish")
    var body = _published(target)
    assert_true("| tests/test_alpha.mojo | PASS |" in body, "no summary row")
    assert_true(
        "| tests/test_gamma.mojo | NOT_RUN |" in body,
        "the not-run record never reached the writer",
    )


def test_recording_coordinator_wires_every_lifecycle_channel_and_a_writer() raises:
    # The widest overload: the pack plus all four lifecycle reporters.
    var target = temp_root() + "/report.md"
    var coord = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter())),
        JsonStreamReporter.inert(),
        JunitReporter.inert(),
        AnnotationsReporter(active=True),
        _md_writer(target),
    )
    var events = _stream()
    _ = _drive(coord, events)
    var fin = coord.finalize_reports(_report_ctx())

    assert_false(fin.md_failed)
    assert_true(len(coord.annotation_tail()) > 0, "the tail must still render")
    assert_true(
        "| tests/test_beta.mojo | COMPILE_ERROR |" in _published(target),
        "the writer saw no events",
    )


def test_recording_coordinator_without_a_writer_finalizes_clean() raises:
    var coord = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var fin = coord.finalize_reports(_report_ctx())
    assert_false(fin.md_failed, "an inert writer finalizes clean")
    assert_equal(fin.md_detail, "")
    assert_false(fin.html_failed, "an inert writer finalizes clean")
    assert_equal(fin.html_detail, "")


def test_recording_coordinator_records_not_run_records() raises:
    var coord = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    coord.note_not_run_records(
        [
            NotRunRecord("tests/test_a.mojo", NotRunReason.LIMIT_REACHED),
            NotRunRecord("tests/test_b.mojo", NotRunReason.GATE_CASUALTY),
        ]
    )
    assert_equal(len(coord.not_run_records), 2)
    assert_equal(coord.not_run_records[0].path, "tests/test_a.mojo")
    assert_true(coord.not_run_records[0].reason == NotRunReason.LIMIT_REACHED)
    assert_equal(coord.not_run_records[1].path, "tests/test_b.mojo")
    assert_true(coord.not_run_records[1].reason == NotRunReason.GATE_CASUALTY)


def test_recording_coordinator_note_not_run_records_accumulates_across_calls() raises:
    # A second call must not overwrite the first: both batches survive, in
    # call order, exactly as the field's own docstring promises.
    var coord = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    coord.note_not_run_records(
        [NotRunRecord("tests/test_a.mojo", NotRunReason.LIMIT_REACHED)]
    )
    coord.note_not_run_records(
        [
            NotRunRecord("tests/test_b.mojo", NotRunReason.GATE_CASUALTY),
            NotRunRecord("tests/test_c.mojo", NotRunReason.INTERRUPTED),
        ]
    )
    assert_equal(len(coord.not_run_records), 3)
    assert_equal(coord.not_run_records[0].path, "tests/test_a.mojo")
    assert_true(coord.not_run_records[0].reason == NotRunReason.LIMIT_REACHED)
    assert_equal(coord.not_run_records[1].path, "tests/test_b.mojo")
    assert_true(coord.not_run_records[1].reason == NotRunReason.GATE_CASUALTY)
    assert_equal(coord.not_run_records[2].path, "tests/test_c.mojo")
    assert_true(coord.not_run_records[2].reason == NotRunReason.INTERRUPTED)


def test_recording_coordinator_records_the_whole_stream() raises:
    # The second conformer: a recording pack standing in for the console, with
    # every lifecycle channel inert. This is what the session's own drivers use.
    var coord = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter(), RecordingReporter()))
    )
    var events = _stream()
    assert_false(_drive(coord, events), "a bare recording pack never latches")

    # Both recorders observed the identical stream.
    comptime for slot in range(2):
        ref rec = coord.composite.reporters[slot]
        assert_equal(rec.count(), len(events))
        assert_true(rec.kind_at(0) == EventKind.SESSION_STARTED)
        assert_true(rec.kind_at(rec.count() - 1) == EventKind.SESSION_FINISHED)

    # Every lifecycle channel is inert, so a bare driver needs no real reporter.
    coord.note_not_run(["tests/test_gamma.mojo"])
    assert_false(coord.finalize_junit(0, 0).failed)
    assert_equal(len(coord.annotation_tail()), 0)
    assert_equal(coord.console_output(), "")
    assert_equal(coord.fence_token(), "")


def test_recording_coordinator_wires_a_real_annotations_reporter() raises:
    # The lifecycle-bearing driver shape: a recorder stands in for the console
    # while a REAL reporter answers its lifecycle channel.
    var coord = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter())),
        JsonStreamReporter.inert(),
        JunitReporter.inert(),
        AnnotationsReporter(active=True),
    )
    var events = _stream()
    _ = _drive(coord, events)

    assert_equal(coord.composite.reporters[0].count(), len(events))
    var tail = coord.annotation_tail()
    assert_true(len(tail) > 0, "a real annotations reporter must render a tail")
    assert_true(tail[0].startswith("::error "), "the error block is not first")
    assert_true("test_beta" in tail[0], "the failing file is not annotated")
    assert_true(
        tail[len(tail) - 1].startswith("::notice::"),
        "the single notice is not last",
    )


def test_coordinator_folds_live_state_delta_from_events() raises:
    var coord = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    coord.configure_state_gates(
        ["tests/test_gate.mojo", "tests/test_gate_pass.mojo"]
    )
    coord.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_run.mojo", "test_bad"),
                Outcome.FAIL,
                "boom",
                "",
            )
        )
    )
    coord.handle(
        Event.file_finished(
            "tests/test_run.mojo",
            Outcome.FAIL,
            0.1,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
            failed_tests=1,
        )
    )
    coord.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_gate.mojo", "test_gate"),
                Outcome.FAIL,
                "boom",
                "",
            )
        )
    )
    coord.handle(
        Event.file_finished(
            "tests/test_gate.mojo",
            Outcome.FAIL,
            0.1,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
            failed_tests=1,
        )
    )
    coord.handle(
        Event.precompile_failed(
            "precompile",
            "boom",
            1,
            casualties=["tests/test_casualty.mojo"],
        )
    )
    coord.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_partial.mojo", "test_selected"),
                Outcome.PASS,
                "",
                "",
            )
        )
    )
    coord.handle(
        Event.file_finished(
            "tests/test_partial.mojo",
            Outcome.PASS,
            0.1,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
            passed_tests=1,
            deselected_tests=1,
        )
    )
    coord.handle(
        Event.file_finished(
            "tests/test_crash.mojo",
            Outcome.CRASH,
            0.1,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
            signal_number=11,
        )
    )
    coord.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_gate_pass.mojo", "test_gate"),
                Outcome.PASS,
                "",
                "",
            )
        )
    )
    coord.handle(
        Event.file_finished(
            "tests/test_gate_pass.mojo",
            Outcome.PASS,
            0.1,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
            passed_tests=1,
        )
    )
    coord.handle(
        Event.file_finished(
            "tests/test_not_run.mojo",
            Outcome.NOT_RUN,
            0.0,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
        )
    )
    coord.handle(
        Event.file_finished(
            "tests/test_excluded.mojo",
            Outcome.EXCLUDED,
            0.0,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
        )
    )

    var delta = coord.state_delta()
    assert_equal(len(delta.failures), 4)
    assert_equal(delta.failures[0].identifier, "tests/test_run.mojo::test_bad")
    assert_equal(delta.failures[1].identifier, "tests/test_gate.mojo")
    assert_equal(delta.failures[2].identifier, "tests/test_casualty.mojo")
    assert_equal(delta.failures[3].identifier, "tests/test_crash.mojo")
    assert_equal(len(delta.observed_tests), 2)
    assert_equal(delta.observed_tests[0], "tests/test_run.mojo::test_bad")
    assert_equal(
        delta.observed_tests[1], "tests/test_partial.mojo::test_selected"
    )
    assert_equal(len(delta.observed_files), 6)
    assert_equal(delta.observed_files[0], "tests/test_run.mojo")
    assert_equal(delta.observed_files[1], "tests/test_gate.mojo")
    assert_equal(delta.observed_files[2], "tests/test_casualty.mojo")
    assert_equal(delta.observed_files[3], "tests/test_partial.mojo")
    assert_equal(delta.observed_files[4], "tests/test_crash.mojo")
    assert_equal(delta.observed_files[5], "tests/test_gate_pass.mojo")
    assert_equal(len(delta.fully_observed_files), 2)
    assert_equal(delta.fully_observed_files[0], "tests/test_run.mojo")
    assert_equal(delta.fully_observed_files[1], "tests/test_gate_pass.mojo")
    assert_equal(len(delta.terminal_files), 3)
    assert_equal(delta.terminal_files[0], "tests/test_gate.mojo")
    assert_equal(delta.terminal_files[1], "tests/test_casualty.mojo")
    assert_equal(delta.terminal_files[2], "tests/test_crash.mojo")


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
