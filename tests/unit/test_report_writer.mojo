"""The stateful run-report writer: accumulate, spool, stream, publish (Layer 2).

`ReportWriter` is the report layer's second spool-then-assemble shell, the
sibling of `JunitReporter`: it accumulates per-file typed state from the event
stream, renders and spools one fragment per finished file per ACTIVE format, and
stream-assembles each document at finalize through the artifact's borrowed
descriptor. These tests pin what the writer decides rather than what the
renderers already pin: which files earn a section under each style, which
not-run records survive the row-index filter, that a section's assembly order is
the sorted row order, and that a failing sink never publishes while its sibling
still does.
"""
from std.os import listdir, mkdir
from std.os.path import exists, isdir
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.model import (
    Event,
    NodeId,
    NotRunRecord,
    NotRunReason,
    Outcome,
    TestResult,
    not_run_reason_label,
)
from mtest.platform import create_unique_temp, set_permissions
from mtest.report import (
    REPORT_STYLE_CONCISE,
    REPORT_STYLE_FULL,
    ReportArtifact,
    ReportFinalizeContext,
    ReportFinalizeResult,
    ReportHeaderFacts,
    ReportWriter,
    open_report_spool,
)

from tmptree import remove_tree, temp_root


def _facts() -> ReportHeaderFacts:
    """The build-time header facts, fixed so document bytes stay comparable."""
    return ReportHeaderFacts("x.y.z", "linux-64")


def _ctx() -> ReportFinalizeContext:
    """A run-wide context whose every conditional fact is off."""
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
        wall_seconds=1.5,
        interrupted=False,
        drift=False,
        workers=1,
        shuffle=False,
        shuffle_seed=0,
        shard_label="",
    )


def _artifact(target: String) raises -> Optional[ReportArtifact]:
    """One active sink: the target plus a freshly created unique temp beside it.
    """
    var created = create_unique_temp(target + ".XXXXXX")
    return Optional[ReportArtifact](
        ReportArtifact(target, created.path, created.fd, False, "")
    )


def _off() -> Optional[ReportArtifact]:
    """The inactive sink."""
    return Optional[ReportArtifact](None)


def _read(path: String) raises -> String:
    """Read a whole published document back."""
    var body: String
    with open(path, "r") as f:
        body = f.read()
    return body^


def _bytes() -> List[UInt8]:
    """An empty captured stream."""
    return List[UInt8]()


def _pass_file(mut w: ReportWriter, path: String):
    """Drive one passing file end to end."""
    w.handle(Event.file_started(path))
    w.handle(
        Event.test_reported(TestResult(NodeId(path, "test_ok"), Outcome.PASS))
    )
    w.handle(
        Event.file_finished(
            path,
            Outcome.PASS,
            0.25,
            ["mojo", "build", path],
            1.0,
            _bytes(),
            _bytes(),
            passed_tests=1,
        )
    )


def _fail_file(mut w: ReportWriter, path: String):
    """Drive one failing file end to end, with one failing test row."""
    w.handle(Event.file_started(path))
    w.handle(
        Event.test_reported(
            TestResult(NodeId(path, "test_bad"), Outcome.FAIL, "boom", "")
        )
    )
    w.handle(
        Event.file_finished(
            path,
            Outcome.FAIL,
            0.5,
            ["mojo", "build", path],
            1.0,
            _bytes(),
            _bytes(),
            failed_tests=1,
        )
    )


def _md_writer(
    target: String, spool: String, style: Int
) raises -> ReportWriter:
    """A writer with the Markdown sink active and the HTML sink off."""
    return ReportWriter(
        _facts(), style, _artifact(target), _off(), spool, "/run/root"
    )


def test_concise_green_run_renders_rows_without_any_section() raises:
    # The concise style's whole point: a file that needs no second look earns a
    # summary row and nothing else, so a green run's report stays a table.
    var dir = temp_root()
    var target = dir + "/report.md"
    var w = _md_writer(target, temp_root(), REPORT_STYLE_CONCISE)
    _pass_file(w, "tests/test_a.mojo")
    _pass_file(w, "tests/test_b.mojo")
    var result = w.finalize_reports(_ctx())

    assert_false(result.md_failed, "a clean markdown finalize must not fail")
    assert_equal(result.md_detail, "")
    var body = _read(target)
    assert_true("| tests/test_a.mojo | PASS |" in body, "row a is missing")
    assert_true("| tests/test_b.mojo | PASS |" in body, "row b is missing")
    assert_false("## " in body, "a green concise run must render no section")


def test_concise_failing_file_renders_a_section_with_reproduce_lines() raises:
    var dir = temp_root()
    var target = dir + "/report.md"
    var w = _md_writer(target, temp_root(), REPORT_STYLE_CONCISE)
    _pass_file(w, "tests/test_a.mojo")
    _fail_file(w, "tests/test_b.mojo")
    var result = w.finalize_reports(_ctx())

    assert_false(result.md_failed)
    var body = _read(target)
    assert_true("| tests/test_b.mojo | FAIL |" in body, "the row is missing")
    assert_true("## `tests/test_b.mojo` — FAIL" in body, "no failing section")
    assert_false("## `tests/test_a.mojo`" in body, "the green file got one")
    assert_true(
        "### FAIL `tests/test_b.mojo::test_bad`" in body,
        "the failing test heading is missing",
    )
    assert_true(
        "reproduce: `mtest tests/test_b.mojo::test_bad`" in body,
        "the single-failure reproduce target is missing",
    )
    assert_true(
        "debug: `mtest debug tests/test_b.mojo::test_bad`" in body,
        "the debug line is missing",
    )
    assert_true("## Machine index" in body, "the machine index is missing")


def test_full_style_renders_a_section_for_a_passing_file() raises:
    var dir = temp_root()
    var target = dir + "/report.md"
    var w = _md_writer(target, temp_root(), REPORT_STYLE_FULL)
    _pass_file(w, "tests/test_a.mojo")
    var result = w.finalize_reports(_ctx())

    assert_false(result.md_failed)
    var body = _read(target)
    assert_true("## `tests/test_a.mojo` — PASS" in body, "no passed section")
    assert_false(
        "## Machine index" in body, "a green run needs no machine index"
    )


def test_not_run_records_drop_paths_that_already_produced_a_row() raises:
    # One record per SELECTED file arrives, the file that ran included. The row
    # index is the filter: a path with a verdict is dropped, a never-seen path
    # becomes a NOT_RUN row plus a rendered reason line.
    var dir = temp_root()
    var target = dir + "/report.md"
    var w = _md_writer(target, temp_root(), REPORT_STYLE_CONCISE)
    _pass_file(w, "tests/test_a.mojo")
    w.note_not_run_records(
        [
            NotRunRecord("tests/test_a.mojo", NotRunReason.LIMIT_REACHED),
            NotRunRecord("tests/test_b.mojo", NotRunReason.LIMIT_REACHED),
        ]
    )
    var result = w.finalize_reports(_ctx())

    assert_false(result.md_failed)
    var body = _read(target)
    assert_true("| tests/test_a.mojo | PASS |" in body, "the verdict row went")
    assert_false(
        "| tests/test_a.mojo | NOT_RUN |" in body,
        "a file with a verdict must not gain a NOT_RUN row",
    )
    assert_true(
        "| tests/test_b.mojo | NOT_RUN |" in body,
        "the never-seen file must gain a NOT_RUN row",
    )
    var label = not_run_reason_label(NotRunReason.LIMIT_REACHED)
    assert_true(
        "## Not run\n\n- tests/test_b.mojo: " + label in body,
        "the reason line is missing, or floats without its heading",
    )
    assert_false(
        "- tests/test_a.mojo: " in body,
        "a file with a verdict must render no reason line",
    )


def test_duplicate_not_run_records_yield_exactly_one_row() raises:
    # The same index check deduplicates a repeated record, so a drift
    # FILE_FINISHED row and a record for the same path never double.
    var dir = temp_root()
    var target = dir + "/report.md"
    var w = _md_writer(target, temp_root(), REPORT_STYLE_CONCISE)
    w.note_not_run_records(
        [NotRunRecord("tests/test_b.mojo", NotRunReason.INTERRUPTED)]
    )
    w.note_not_run_records(
        [NotRunRecord("tests/test_b.mojo", NotRunReason.INTERRUPTED)]
    )
    _ = w.finalize_reports(_ctx())

    var body = _read(target)
    var first = body.find("| tests/test_b.mojo | NOT_RUN |")
    assert_true(first >= 0, "the NOT_RUN row is missing")
    assert_equal(
        body.rfind("| tests/test_b.mojo | NOT_RUN |"),
        first,
        "the NOT_RUN row was rendered twice",
    )


def test_finalize_failure_leaves_a_prior_report_byte_identical() raises:
    # The target directory is made unwritable AFTER construction, so the rename
    # that publishes the document fails while everything before it succeeds. The
    # report already at the target must survive untouched.
    var dir = temp_root()
    var target = dir + "/report.md"
    var prior = String("PRIOR REPORT\n")
    with open(target, "w") as f:
        f.write(prior)
    var w = _md_writer(target, temp_root(), REPORT_STYLE_CONCISE)
    _fail_file(w, "tests/test_b.mojo")

    set_permissions(dir, 0o500)
    var result: ReportFinalizeResult
    try:
        result = w.finalize_reports(_ctx())
    finally:
        set_permissions(dir, 0o700)

    assert_true(result.md_failed, "a failed rename must report the sink failed")
    assert_true(
        result.md_detail.startswith("run report (markdown) could not be"),
        "the diagnostic must name the markdown sink and the failed step: "
        + result.md_detail,
    )
    assert_true(
        "published" in result.md_detail,
        "the diagnostic must name the failed publish, not another step: "
        + result.md_detail,
    )
    assert_equal(_read(target), prior, "the prior report was not preserved")


def test_a_latched_sink_fails_while_its_sibling_publishes() raises:
    # A fragment write that cannot land latches only ITS sink: the Markdown
    # spool path is occupied by a directory, so every Markdown fragment write
    # fails while the HTML sink spools and publishes normally.
    var dir = temp_root()
    var spool = temp_root()
    mkdir(spool + "/md-0.md", 0o700)
    var md_target = dir + "/report.md"
    var html_target = dir + "/report.html"
    var w = ReportWriter(
        _facts(),
        REPORT_STYLE_CONCISE,
        _artifact(md_target),
        _artifact(html_target),
        spool,
        "/run/root",
    )
    _fail_file(w, "tests/test_b.mojo")
    var result = w.finalize_reports(_ctx())

    assert_true(result.md_failed, "the latched markdown sink must fail")
    assert_true(
        result.md_detail.startswith(
            "run report (markdown) section spool failed: section"
            " tests/test_b.mojo:"
        ),
        "the diagnostic must name the sink and the section that could not be"
        " spooled: "
        + result.md_detail,
    )
    assert_false(exists(md_target), "a latched sink must publish nothing")
    # A second finalize repeats the FIRST call's diagnostic verbatim rather
    # than the raw latch text underneath it.
    var again = w.finalize_reports(_ctx())
    assert_true(again.md_failed, "the latch does not clear")
    assert_equal(
        again.md_detail, result.md_detail, "a second finalize changed the story"
    )
    assert_false(result.html_failed, "the healthy html sink must publish")
    assert_equal(result.html_detail, "", "a clean sink carries no diagnostic")
    var body = _read(html_target)
    assert_true(body.startswith("<!doctype html>"), "no html document open")
    assert_true(body.endswith("</html>\n"), "no html document close")
    assert_true('<tr class="file-section">' in body, "no html file section")


def test_html_sink_publishes_a_closed_document() raises:
    var dir = temp_root()
    var target = dir + "/report.html"
    var w = ReportWriter(
        _facts(),
        REPORT_STYLE_CONCISE,
        _off(),
        _artifact(target),
        temp_root(),
        "/run/root",
    )
    _pass_file(w, "tests/test_a.mojo")
    _fail_file(w, "tests/test_b.mojo")
    w.note_not_run_records(
        [NotRunRecord("tests/test_c.mojo", NotRunReason.INTERRUPTED)]
    )
    var result = w.finalize_reports(_ctx())

    assert_false(result.html_failed)
    var body = _read(target)
    assert_true(body.startswith("<!doctype html>"))
    assert_true(body.endswith("</tbody>\n</table>\n</body>\n</html>\n"))
    assert_true("<code>tests/test_a.mojo</code>" in body, "no summary row")
    assert_true('<tr class="not-run">' in body, "no not-run row")
    assert_true('<tr class="machine-index">' in body, "no machine index row")


def _pad3(i: Int) -> String:
    """Zero-pad an index to three digits so lexical order is numeric order."""
    var s = String(i)
    var out = String("")
    for _ in range(3 - s.byte_length()):
        out += "0"
    return out + s


def test_section_order_is_the_sorted_row_order() raises:
    # Files finish in whatever order the run produced them; the document is
    # assembled in sorted path order for BOTH the rows and the spooled sections.
    var dir = temp_root()
    var target = dir + "/report.md"
    var w = _md_writer(target, temp_root(), REPORT_STYLE_FULL)
    for i in range(200):
        _pass_file(w, "tests/test_" + _pad3(199 - i) + ".mojo")
    var result = w.finalize_reports(_ctx())

    assert_false(result.md_failed)
    var body = _read(target)
    var previous = -1
    for i in range(200):
        var heading = "## `tests/test_" + _pad3(i) + ".mojo` — PASS"
        var at = body.find(heading)
        assert_true(at >= 0, "a section is missing: " + heading)
        assert_true(at > previous, "sections are out of sorted order")
        previous = at


def test_precompile_failure_earns_its_own_section() raises:
    var dir = temp_root()
    var target = dir + "/report.md"
    var w = _md_writer(target, temp_root(), REPORT_STYLE_CONCISE)
    w.handle(
        Event.precompile_failed(
            "src/pkg",
            "error: cannot compile",
            1,
            casualties=["tests/test_a.mojo"],
        )
    )
    var result = w.finalize_reports(_ctx())

    assert_false(result.md_failed)
    var body = _read(target)
    assert_true(
        "## `src/pkg` — PRECOMPILE_ERROR" in body, "no precompile section"
    )
    assert_true("error: cannot compile" in body, "no compiler output")


def test_no_surviving_record_renders_no_not_run_heading() raises:
    # Every selected file produced a verdict, so the whole not-run block —
    # heading included — is absent rather than an empty section.
    var dir = temp_root()
    var md_target = dir + "/report.md"
    var html_target = dir + "/report.html"
    var w = ReportWriter(
        _facts(),
        REPORT_STYLE_CONCISE,
        _artifact(md_target),
        _artifact(html_target),
        temp_root(),
        "/run/root",
    )
    _pass_file(w, "tests/test_a.mojo")
    w.note_not_run_records(
        [NotRunRecord("tests/test_a.mojo", NotRunReason.LIMIT_REACHED)]
    )
    var result = w.finalize_reports(_ctx())

    assert_false(result.md_failed)
    assert_false(result.html_failed)
    assert_false("## Not run" in _read(md_target), "an empty not-run section")
    # The class name also appears in the stylesheet every document carries, so
    # this looks for the ROW rather than the selector.
    assert_false(
        '<tr class="not-run-heading">' in _read(html_target),
        "an empty not-run section",
    )


def test_not_run_heading_precedes_the_reason_rows_in_html() raises:
    var dir = temp_root()
    var target = dir + "/report.html"
    var w = ReportWriter(
        _facts(),
        REPORT_STYLE_CONCISE,
        _off(),
        _artifact(target),
        temp_root(),
        "/run/root",
    )
    w.note_not_run_records(
        [NotRunRecord("tests/test_c.mojo", NotRunReason.INTERRUPTED)]
    )
    _ = w.finalize_reports(_ctx())

    var body = _read(target)
    var heading = body.find('<tr class="not-run-heading">')
    var row = body.find('<tr class="not-run">')
    assert_true(heading >= 0, "the not-run heading row is missing")
    assert_true(row > heading, "the heading must precede its reason rows")


def test_a_second_finalize_neither_closes_nor_republishes() raises:
    # The exactly-one-close property, tested rather than argued. A second close
    # of the released descriptor would report EBADF as a sink failure, and a
    # second rename would put the document back over the sentinel written here.
    var dir = temp_root()
    var target = dir + "/report.md"
    var w = _md_writer(target, temp_root(), REPORT_STYLE_CONCISE)
    _fail_file(w, "tests/test_b.mojo")
    var first = w.finalize_reports(_ctx())
    assert_false(first.md_failed, "the first finalize must publish")

    var published = _read(target)
    assert_true(published.byte_length() > 0, "nothing was published")
    var sentinel = String("SENTINEL\n")
    with open(target, "w") as f:
        f.write(sentinel)

    var second = w.finalize_reports(_ctx())
    assert_false(
        second.md_failed,
        "a second finalize closed the released descriptor again: "
        + second.md_detail,
    )
    assert_equal(second.md_detail, "", "a clean sink carries no diagnostic")
    assert_equal(
        _read(target), sentinel, "a second finalize republished the document"
    )


def test_inert_writer_does_nothing_and_finalizes_clean() raises:
    var w = ReportWriter.inert()
    _pass_file(w, "tests/test_a.mojo")
    _fail_file(w, "tests/test_b.mojo")
    w.note_not_run_records(
        [NotRunRecord("tests/test_c.mojo", NotRunReason.INTERRUPTED)]
    )
    var result = w.finalize_reports(_ctx())
    assert_false(result.md_failed, "an inert sink never fails")
    assert_equal(result.md_detail, "")
    assert_false(result.html_failed, "an inert sink never fails")
    assert_equal(result.html_detail, "")


# --- The spool directory the writer is handed --------------------------------


def test_open_report_spool_creates_a_fresh_empty_directory() raises:
    var spool = open_report_spool()
    try:
        assert_true(
            isdir(spool), "the spool path names a real directory: " + spool
        )
        assert_equal(len(listdir(spool)), 0, "a fresh spool starts empty")
    finally:
        remove_tree(spool)


def test_open_report_spool_does_not_collide_within_one_process() raises:
    # One process opens one report spool per run, but the aggregate test binary
    # opens many; the per-attempt clock reading is what keeps them apart.
    var first = open_report_spool()
    var second = open_report_spool()
    try:
        assert_true(first != second, "two spools in one process differ")
    finally:
        remove_tree(first)
        remove_tree(second)


def test_open_report_spool_is_named_apart_from_the_junit_spool() raises:
    # A stray directory has to say which reporter left it, and two spools open
    # in one run must never be the same directory.
    var spool = open_report_spool()
    try:
        assert_true(
            "/mtest-run report-" in spool,
            "the spool carries its own run-identifying prefix: " + spool,
        )
    finally:
        remove_tree(spool)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
