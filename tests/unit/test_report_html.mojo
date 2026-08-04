"""Tests for the pure HTML fragment renderer (Layer 2).

The HTML sibling of `test_report_md.mojo`: exact-output tests over the same
fragment boundaries, adjusted for HTML syntax instead of Markdown's. The
security-focused cases pin the brief's own two invariants — a hostile value
cannot close the document's one `<style>` block or escape a `<details>`
section — the control-byte scalarization policy shared with the console and
Markdown renderer (a C0 byte, a raw ESC, and a bare CR must render as
visible escape text, never a browser line break or a silent replacement
character), and the structural invariant the renderer's design leans on: the
summary table stays one continuous, balanced `<table>`/`<tbody>` from
`html_document_open` to `html_document_close`, however many rows, file
sections, not-run lines, or a machine index land in between.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.model import NodeId, NotRunRecord, NotRunReason, Outcome, TestResult
from mtest.report.report_html import (
    html_document_close,
    html_document_open,
    html_file_section,
    html_machine_index,
    html_not_run_heading,
    html_not_run_line,
    html_summary_row,
)
from mtest.report.report_model import (
    ReportFinalizeContext,
    ReportHeaderFacts,
    ReportRow,
    ReportSectionInput,
    needs_action,
    outcome_label,
)


def _count_occurrences(haystack: String, needle: String) -> Int:
    return len(haystack.split(needle)) - 1


def _zero_counts() -> List[Int]:
    var c = List[Int]()
    for _ in range(Outcome.COUNT):
        c.append(0)
    return c^


def _facts() -> ReportHeaderFacts:
    return ReportHeaderFacts(version="x.y.z", platform="Linux x86_64")


def _ctx(
    shuffle: Bool = False,
    shuffle_seed: Int = 0,
    workers: Int = 1,
    built_files: Int = 0,
    cached_files: Int = 0,
    flaky_files: Int = 0,
    shard_label: String = "",
    interrupted: Bool = False,
    drift: Bool = False,
    wall_seconds: Float64 = 0.0,
    counts: List[Int] = _zero_counts(),
) -> ReportFinalizeContext:
    return ReportFinalizeContext(
        counts=counts.copy(),
        tests_passed=0,
        tests_failed=0,
        tests_skipped=0,
        flaky_files=flaky_files,
        built_files=built_files,
        cached_files=cached_files,
        wall_seconds=wall_seconds,
        interrupted=interrupted,
        drift=drift,
        workers=workers,
        shuffle=shuffle,
        shuffle_seed=shuffle_seed,
        shard_label=shard_label,
    )


def _ctx_fixture() -> ReportFinalizeContext:
    return _ctx()


def _row(path: String, outcome_code: Int) -> ReportRow:
    return ReportRow(
        path=path,
        outcome_code=outcome_code,
        duration_seconds=0.0,
        passed=0,
        failed=0,
        skipped=0,
        attempts=1,
    )


def _plain_section() -> ReportSectionInput:
    return ReportSectionInput(
        path="tests/a.mojo",
        root="",
        outcome_code=Outcome.FAIL.code,
        tests=List[TestResult](),
        stdout_text="",
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="",
        reproduce_node="tests/a.mojo::test_x",
    )


def _section_with_node(node: String) -> String:
    """A minimal FAIL section whose reproduce target is `node`."""
    var section = ReportSectionInput(
        path="tests/a.mojo",
        root="",
        outcome_code=Outcome.FAIL.code,
        tests=List[TestResult](),
        stdout_text="",
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="",
        reproduce_node=node,
    )
    return html_file_section(section)


def _hostile_section() -> ReportSectionInput:
    """A section whose path carries a `<script>` tag and no other content."""
    return ReportSectionInput(
        path="tests/<script>alert(1)</script>.mojo",
        root="",
        outcome_code=Outcome.FAIL.code,
        tests=List[TestResult](),
        stdout_text="",
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="",
        reproduce_node="",
    )


# --- The brief's two verbatim invariants ------------------------------------


def test_document_has_one_style_and_no_script() raises:
    var doc = (
        html_document_open(_facts(), _ctx_fixture())
        + html_file_section(_hostile_section())
        + html_document_close()
    )
    assert_equal(_count_occurrences(doc, "<script"), 0)
    assert_equal(_count_occurrences(doc, "</style"), 1)


def test_hostile_name_cannot_close_style_or_details() raises:
    var out = html_file_section(_hostile_section())
    assert_true(out.find("</style") == -1)
    assert_true(out.find("&lt;script&gt;") != -1)


# --- Control-byte scalarization ---------------------------------------------
#
# An inline value must pass through `console_text.escape_scalar` before
# `html_escape_text`, exactly as the Markdown renderer's `md_escape_cell`
# does, so a C0 byte, a raw ESC, and a bare CR render as the same visible
# `\xHH` text the console shows rather than a browser line break (CR) or a
# bare U+FFFD (any other C0 byte) from HTML's own control-byte policy alone.


def test_not_run_path_scalarizes_a_c0_byte_esc_and_bare_cr() raises:
    var hostile = "a" + chr(0x07) + "b" + chr(0x1B) + "c" + chr(0x0D) + "d.mojo"
    var record = NotRunRecord(hostile, NotRunReason.LIMIT_REACHED)
    assert_equal(
        html_not_run_line(record),
        (
            '<tr class="not-run"><td colspan="7"><code>'
            "a\\x07b\\x1Bc\\x0Dd.mojo</code>: stopped early"
            " (-x/--maxfail)</td></tr>\n"
        ),
    )
    # The raw control bytes must not survive into the document.
    assert_true(html_not_run_line(record).find(chr(0x1B)) == -1)
    assert_true(html_not_run_line(record).find(chr(0x0D)) == -1)


def test_reproduce_target_scalarizes_control_bytes_before_shell_quoting() raises:
    var hostile = "tests/a" + chr(0x1B) + "b" + chr(0x0D) + ".mojo"
    var out = _section_with_node(hostile)
    assert_true(
        out.find(
            "<p>reproduce: <code>mtest 'tests/a\\x1Bb\\x0D.mojo'</code></p>"
        )
        != -1
    )
    assert_true(out.find(chr(0x1B)) == -1)


def test_stream_pre_preserves_lf_tab_but_escapes_other_controls() raises:
    # A block position (`<pre>`) keeps LF and Tab literal, matching
    # `escape_multiline`'s console/Markdown policy, while a C0 byte that is
    # neither (here BEL) and a bare CR both still render as visible escape
    # text rather than a raw control byte or a silent line break.
    var hostile_stream = "line1\n\tindented" + chr(0x07) + chr(0x0D) + "line2"
    var section = ReportSectionInput(
        path="tests/g.mojo",
        root="",
        outcome_code=Outcome.FAIL.code,
        tests=List[TestResult](),
        stdout_text=hostile_stream,
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="",
        reproduce_node="",
    )
    var out = html_file_section(section)
    assert_true(out.find("<pre>\nline1\n\tindented\\x07\\x0Dline2</pre>") != -1)
    assert_true(out.find(chr(0x07)) == -1)
    assert_true(out.find(chr(0x0D)) == -1)


# --- Document shell ----------------------------------------------------------


def test_document_open_ends_with_unclosed_tbody() raises:
    var out = html_document_open(_facts(), _ctx())
    assert_true(out.endswith("<tbody>\n"))
    assert_true(out.find("</tbody") == -1)


def test_document_close_closes_table_and_shell() raises:
    assert_equal(
        html_document_close(), "</tbody>\n</table>\n</body>\n</html>\n"
    )


def test_document_open_states_that_paths_are_root_relative() raises:
    # The Markdown renderer's head note in this document's syntax, and above
    # the summary table for the same reason: a note under the table is a note
    # a reader meets after every path it explains.
    var out = html_document_open(_facts(), _ctx())
    assert_true(out.find("relative to the run root") != -1)
    assert_true(out.find("relative to the run root") < out.find("<table"))
    # And it claims only what the report composes: a section's `build:` line
    # is the build argv verbatim and a captured stream is the child's own
    # bytes, so neither is rewritten against the root.
    assert_true(out.find("captured output") != -1)
    assert_true(out.find("<code>build:</code>") != -1)


def test_document_open_has_meta_charset() raises:
    var out = html_document_open(_facts(), _ctx())
    assert_true(out.find('<meta charset="utf-8">') != -1)


def test_document_has_no_external_urls() raises:
    var doc = (
        html_document_open(_facts(), _ctx_fixture()) + html_document_close()
    )
    assert_true(doc.find("http://") == -1)
    assert_true(doc.find("https://") == -1)
    assert_true(doc.find("url(") == -1)
    assert_true(doc.find("@import") == -1)
    assert_true(doc.find("@font-face") == -1)


def test_summary_table_header_is_exact() raises:
    var out = html_document_open(_facts(), _ctx())
    assert_true(
        out.find(
            '<table class="report">\n<thead>\n<tr>'
            "<th>Path</th><th>Outcome</th><th>Duration (s)</th>"
            "<th>Passed</th><th>Failed</th><th>Skipped</th><th>Attempts</th>"
            "</tr>\n</thead>\n<tbody>\n"
        )
        != -1
    )


def test_full_document_assembly_has_balanced_table_and_shell() raises:
    var doc = html_document_open(_facts(), _ctx())
    doc += html_summary_row(_row("a.mojo", Outcome.PASS.code))
    doc += html_file_section(_plain_section())
    doc += html_not_run_line(NotRunRecord("b.mojo", NotRunReason.LIMIT_REACHED))
    var rows = List[ReportRow]()
    rows.append(_row("a.mojo", Outcome.FAIL.code))
    var nodes = List[String]()
    nodes.append("a.mojo")
    doc += html_machine_index(rows, nodes)
    doc += html_document_close()
    assert_equal(_count_occurrences(doc, "<table"), 1)
    assert_equal(_count_occurrences(doc, "</table"), 1)
    assert_equal(_count_occurrences(doc, "<tbody"), 1)
    assert_equal(_count_occurrences(doc, "</tbody"), 1)
    assert_equal(_count_occurrences(doc, "<html"), 1)
    assert_equal(_count_occurrences(doc, "</html"), 1)


def test_the_heading_hierarchy_descends_without_skipping_a_level() raises:
    """A document outline is a real consumer: assistive technology and every
    table-of-contents generator read it, and a skipped level breaks both."""
    var tests = List[TestResult]()
    tests.append(
        TestResult(NodeId("tests/a.mojo", "test_x"), Outcome.FAIL, "boom", "")
    )
    var section = ReportSectionInput(
        path="tests/a.mojo",
        root="",
        outcome_code=Outcome.FAIL.code,
        tests=tests^,
        stdout_text="",
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="",
        reproduce_node="tests/a.mojo::test_x",
    )
    var rows = List[ReportRow]()
    rows.append(_row("a.mojo", Outcome.FAIL.code))
    var nodes = List[String]()
    nodes.append("a.mojo")
    var doc = html_document_open(_facts(), _ctx())
    doc += html_summary_row(_row("a.mojo", Outcome.FAIL.code))
    doc += html_file_section(section)
    doc += html_not_run_heading()
    doc += html_not_run_line(NotRunRecord("b.mojo", NotRunReason.LIMIT_REACHED))
    doc += html_machine_index(rows, nodes)
    doc += html_document_close()
    # Exactly one document title, sections one level under the h2 bands, and
    # nothing below: a level that appears without its parent is the skip.
    assert_equal(_count_occurrences(doc, "<h1>"), 1)
    assert_equal(_count_occurrences(doc, "<h2>"), 3)
    assert_equal(_count_occurrences(doc, "<h3>"), 1)
    assert_equal(_count_occurrences(doc, "<h4>"), 0)
    assert_equal(_count_occurrences(doc, "<h5>"), 0)
    assert_equal(_count_occurrences(doc, "<h6>"), 0)


# --- Summary row ---------------------------------------------------------


def test_summary_row_escapes_untrusted_path() raises:
    var row = ReportRow(
        path="tests/<b>&rd.mojo",
        outcome_code=Outcome.PASS.code,
        duration_seconds=1.5,
        passed=3,
        failed=0,
        skipped=0,
        attempts=1,
    )
    assert_equal(
        html_summary_row(row),
        (
            '<tr class="outcome-PASS"><td><code>'
            "tests/&lt;b&gt;&amp;rd.mojo</code></td><td>PASS</td>"
            "<td>1.500</td><td>3</td><td>0</td><td>0</td><td>1</td></tr>\n"
        ),
    )


# --- File section ----------------------------------------------------------


def test_file_section_open_for_non_green_closed_for_pass() raises:
    var fail_out = html_file_section(_plain_section())
    assert_true(fail_out.find('<details class="file" open>') != -1)

    var pass_section = ReportSectionInput(
        path="tests/a.mojo",
        root="",
        outcome_code=Outcome.PASS.code,
        tests=List[TestResult](),
        stdout_text="",
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="",
        reproduce_node="",
    )
    var pass_out = html_file_section(pass_section)
    assert_true(pass_out.find('<details class="file">') != -1)
    assert_true(pass_out.find('<details class="file" open>') == -1)


def test_file_section_fences_detail_and_names_reproduce() raises:
    var tests = List[TestResult]()
    tests.append(
        TestResult(
            NodeId("tests/a.mojo", "test_x"),
            Outcome.FAIL,
            "  boom ``` here",
            "",
        )
    )
    var section = ReportSectionInput(
        path="tests/a.mojo",
        root="",
        outcome_code=Outcome.FAIL.code,
        tests=tests^,
        stdout_text="",
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="",
        reproduce_node="tests/a.mojo::test_x",
    )
    var out = html_file_section(section)
    assert_true(out.find("<pre>\nboom ``` here</pre>") != -1)
    assert_true(
        out.find("<p>reproduce: <code>mtest tests/a.mojo::test_x</code></p>")
        != -1
    )
    assert_true(
        out.find("<p>debug: <code>mtest debug tests/a.mojo::test_x</code></p>")
        != -1
    )


def test_reproduce_quotes_a_hostile_node() raises:
    # A node containing a space MUST come out shell-quoted:
    var out = _section_with_node("tests/a b.mojo::test_x")
    assert_true(
        out.find(
            "<p>reproduce: <code>mtest 'tests/a b.mojo::test_x'</code></p>"
        )
        != -1
    )


def test_reproduce_escapes_a_hostile_html_node() raises:
    var out = _section_with_node("tests/<a>.mojo")
    assert_true(
        out.find("<p>reproduce: <code>mtest 'tests/&lt;a&gt;.mojo'</code></p>")
        != -1
    )
    assert_true(out.find("<a>.mojo") == -1)


def test_file_section_leaves_the_root_note_to_the_document_head() raises:
    # Sections are spooled at file-finish and assembled in sorted path order,
    # so "the first section" is not a position any section can know it is in.
    # `html_document_open` states it once, and repeating it per section would
    # put it on the page as many times as the run had files.
    assert_true(
        html_file_section(_plain_section()).find("relative to the run root")
        == -1
    )


def test_file_section_marks_truncated_streams() raises:
    var section = ReportSectionInput(
        path="tests/b.mojo",
        root="",
        outcome_code=Outcome.FAIL.code,
        tests=List[TestResult](),
        stdout_text="partial out",
        stderr_text="partial err",
        stdout_truncated=True,
        stderr_truncated=True,
        attempts=List[String](),
        build_line="",
        reproduce_node="",
    )
    var out = html_file_section(section)
    assert_true(out.find("<p><em>(stdout truncated)</em></p>") != -1)
    assert_true(out.find("<p><em>(stderr truncated)</em></p>") != -1)
    # An empty reproduce_node renders neither line.
    assert_true(out.find("reproduce:") == -1)
    assert_true(out.find("debug:") == -1)


def test_stream_pre_holds_hostile_content() raises:
    var section = ReportSectionInput(
        path="tests/c.mojo",
        root="",
        outcome_code=Outcome.FAIL.code,
        tests=List[TestResult](),
        stdout_text="closes </pre> fence & <tag>",
        stderr_text="also </details> hostile",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="",
        reproduce_node="",
    )
    var out = html_file_section(section)
    assert_true(
        out.find("<pre>\ncloses &lt;/pre&gt; fence &amp; &lt;tag&gt;</pre>")
        != -1
    )
    assert_true(out.find("also &lt;/details&gt; hostile") != -1)
    assert_true(out.find("<tag>") == -1)
    assert_true(out.find("</details> hostile") == -1)


def test_attempts_are_escaped_and_cannot_open_a_tag() raises:
    var attempts = List[String]()
    attempts.append("# fake heading <b>&amp;</b>")
    var section = ReportSectionInput(
        path="tests/d.mojo",
        root="",
        outcome_code=Outcome.FAIL.code,
        tests=List[TestResult](),
        stdout_text="",
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=attempts^,
        build_line="",
        reproduce_node="",
    )
    var out = html_file_section(section)
    assert_true(
        out.find("<li># fake heading &lt;b&gt;&amp;amp;&lt;/b&gt;</li>") != -1
    )
    assert_true(out.find("<b>") == -1)


def test_build_line_is_escaped() raises:
    var section = ReportSectionInput(
        path="tests/f.mojo",
        root="",
        outcome_code=Outcome.COMPILE_ERROR.code,
        tests=List[TestResult](),
        stdout_text="",
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="mojo build `-o` a|b <tag>&x # trailing",
        reproduce_node="",
    )
    var out = html_file_section(section)
    assert_true(
        out.find(
            "<p>build: <code>mojo build `-o` a|b &lt;tag&gt;&amp;x #"
            " trailing</code></p>"
        )
        != -1
    )


def test_detail_backtrace_is_relativized_against_section_root() raises:
    var tests = List[TestResult]()
    tests.append(
        TestResult(
            NodeId("tests/a.mojo", "test_x"),
            Outcome.FAIL,
            "  At /abs/root/tests/a.mojo:3: assertion failed",
            "",
        )
    )
    var section = ReportSectionInput(
        path="tests/a.mojo",
        root="/abs/root",
        outcome_code=Outcome.FAIL.code,
        tests=tests^,
        stdout_text="",
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="",
        reproduce_node="",
    )
    var out = html_file_section(section)
    assert_true(out.find("At tests/a.mojo:3: assertion failed") != -1)
    assert_true(out.find("/abs/root/tests/a.mojo") == -1)


# --- Not-run line ------------------------------------------------------------


def test_not_run_heading_is_exact_and_spans_the_table() raises:
    # The Markdown heading in this document's syntax: one self-contained row
    # spanning every column, so it nests inside the same open `<tbody>`.
    assert_equal(
        html_not_run_heading(),
        (
            '<tr class="not-run-heading"><td colspan="7">\n'
            "<h2>Not run</h2>\n</td></tr>\n"
        ),
    )


def test_not_run_line_escapes_a_hostile_path() raises:
    var record = NotRunRecord("<script>bad.mojo", NotRunReason.LIMIT_REACHED)
    assert_equal(
        html_not_run_line(record),
        (
            '<tr class="not-run"><td colspan="7"><code>'
            "&lt;script&gt;bad.mojo</code>: stopped early"
            " (-x/--maxfail)</td></tr>\n"
        ),
    )


# --- Header ------------------------------------------------------------------


def test_header_version_and_platform_line_is_escaped() raises:
    var facts = ReportHeaderFacts(
        version="x.y.z<script>", platform="Linux & x86_64"
    )
    var out = html_document_open(facts, _ctx())
    assert_true(
        out.find("<p>mtest x.y.z&lt;script&gt; (Linux &amp; x86_64)</p>") != -1
    )
    assert_true(out.find("<script>") == -1)


def test_header_names_shuffle_seed_only_when_shuffled() raises:
    var shuffled = html_document_open(
        _facts(), _ctx(shuffle=True, shuffle_seed=42)
    )
    var plain = html_document_open(
        _facts(), _ctx(shuffle=False, shuffle_seed=42)
    )
    assert_true(shuffled.find("shuffle seed: 42") != -1)
    assert_true(plain.find("shuffle seed:") == -1)


def test_header_omits_every_optional_line_for_a_minimal_run() raises:
    var out = html_document_open(_facts(), _ctx())
    assert_true(out.find("files:") == -1)
    assert_true(out.find("builds:") == -1)
    assert_true(out.find("flaky:") == -1)
    assert_true(out.find("workers:") == -1)
    assert_true(out.find("shuffle seed:") == -1)
    assert_true(out.find("shard:") == -1)
    assert_true(out.find("interrupted:") == -1)
    assert_true(out.find("drift:") == -1)


def test_header_names_every_fact_when_all_apply() raises:
    var out = html_document_open(
        _facts(),
        _ctx(
            shuffle=True,
            shuffle_seed=7,
            workers=4,
            built_files=2,
            cached_files=3,
            flaky_files=1,
            shard_label="2/5",
            interrupted=True,
            drift=True,
        ),
    )
    assert_true(out.find("builds: 2 built, 3 cached") != -1)
    assert_true(out.find("flaky: 1") != -1)
    assert_true(out.find("workers: 4") != -1)
    assert_true(out.find("shuffle seed: 7") != -1)
    assert_true(out.find("shard: 2/5") != -1)
    assert_true(out.find("interrupted: yes") != -1)
    assert_true(out.find("drift: yes") != -1)


def test_header_shard_label_is_escaped() raises:
    var out = html_document_open(_facts(), _ctx(shard_label="# 2/5 <script>&x"))
    assert_true(out.find("shard: # 2/5 &lt;script&gt;&amp;x</li>") != -1)
    assert_true(out.find("<script>") == -1)


def test_header_files_line_lists_nonzero_counts() raises:
    var counts = _zero_counts()
    counts[Outcome.PASS.code] = 3
    counts[Outcome.FAIL.code] = 1
    counts[Outcome.NOT_RUN.code] = 2
    var out = html_document_open(_facts(), _ctx(counts=counts))
    assert_true(out.find("files: 3 PASS, 1 FAIL, 2 NOT_RUN") != -1)


# --- Machine index -----------------------------------------------------------


def test_machine_index_lists_exactly_rows_that_need_action() raises:
    var rows = List[ReportRow]()
    rows.append(_row("a.mojo", Outcome.PASS.code))
    rows.append(_row("b.mojo", Outcome.FAIL.code))
    rows.append(_row("c.mojo", Outcome.SKIP.code))
    rows.append(_row("d.mojo", Outcome.NOT_RUN.code))
    rows.append(_row("e.mojo", Outcome.DESELECTED.code))
    rows.append(_row("f.mojo", Outcome.EXCLUDED.code))
    var nodes = List[String]()
    nodes.append("a.mojo")
    nodes.append("b.mojo")
    nodes.append("c.mojo")
    nodes.append("d.mojo")
    nodes.append("e.mojo")
    nodes.append("f.mojo")
    assert_equal(
        html_machine_index(rows, nodes),
        (
            '<tr class="machine-index"><td colspan="7">\n'
            "<h2>Machine index</h2>\n<ul>\n"
            "<li><code>b.mojo</code> — FAIL</li>\n"
            "<li><code>d.mojo</code> — NOT_RUN</li>\n"
            "</ul>\n</td></tr>\n"
        ),
    )


def test_machine_index_is_empty_when_nothing_needs_action() raises:
    var rows = List[ReportRow]()
    rows.append(_row("a.mojo", Outcome.PASS.code))
    rows.append(_row("b.mojo", Outcome.SKIP.code))
    rows.append(_row("c.mojo", Outcome.DESELECTED.code))
    rows.append(_row("d.mojo", Outcome.EXCLUDED.code))
    var nodes = List[String]()
    nodes.append("a.mojo")
    nodes.append("b.mojo")
    nodes.append("c.mojo")
    nodes.append("d.mojo")
    assert_equal(html_machine_index(rows, nodes), "")


def test_machine_index_outcome_inclusion_is_total() raises:
    # Pointed at the hoisted `report_model.needs_action`, the single source
    # of truth both renderers call, so a drift between this renderer's
    # filtering and the shared ruling shows up here rather than only in
    # report_md's own suite.
    for code in range(Outcome.COUNT):
        var rows = List[ReportRow]()
        rows.append(_row("only.mojo", code))
        var nodes = List[String]()
        nodes.append("only.mojo")
        var out = html_machine_index(rows, nodes)
        if not needs_action(code):
            assert_equal(out, "")
        else:
            assert_true(out.find(outcome_label(code)) != -1)


def test_machine_index_guards_a_short_nodes_list() raises:
    var rows = List[ReportRow]()
    rows.append(_row("a.mojo", Outcome.FAIL.code))
    var nodes = List[String]()
    assert_equal(
        html_machine_index(rows, nodes),
        (
            '<tr class="machine-index"><td colspan="7">\n'
            "<h2>Machine index</h2>\n<ul>\n"
            "<li><code>''</code> — FAIL</li>\n"
            "</ul>\n</td></tr>\n"
        ),
    )


def test_machine_index_quotes_a_hostile_node() raises:
    var rows = List[ReportRow]()
    rows.append(_row("tests/a b.mojo", Outcome.CRASH.code))
    var nodes = List[String]()
    nodes.append("tests/a b.mojo")
    assert_equal(
        html_machine_index(rows, nodes),
        (
            '<tr class="machine-index"><td colspan="7">\n'
            "<h2>Machine index</h2>\n<ul>\n"
            "<li><code>'tests/a b.mojo'</code> — CRASH</li>\n"
            "</ul>\n</td></tr>\n"
        ),
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
