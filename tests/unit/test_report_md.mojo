"""Tests for the pure Markdown fragment renderer (Layer 2).

Exact-output tests: a Markdown fragment renderer is a text transform with no
tolerance for "close enough" — a mis-escaped `|` corrupts a table, and a
mis-sized code fence lets untrusted content escape it. Several cases here
also drive `report_model`'s `outcome_label`, since the two modules are one
concern split across two files for the reasons `report_model.mojo`'s module
docstring states.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.model import NodeId, NotRunRecord, NotRunReason, Outcome, TestResult
from mtest.report.report_md import (
    md_file_section,
    md_header,
    md_machine_index,
    md_not_run_heading,
    md_not_run_line,
    md_summary_row,
    md_summary_table_header,
)
from mtest.report.report_model import (
    ReportFinalizeContext,
    ReportHeaderFacts,
    ReportRow,
    ReportSectionInput,
    needs_action,
    outcome_label,
)


def _zero_counts() -> List[Int]:
    var c = List[Int]()
    for _ in range(Outcome.COUNT):
        c.append(0)
    return c^


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


def _section_with_node(node: String) -> String:
    """A minimal FAIL section whose reproduce target is `node`."""
    var tests = List[TestResult]()
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
        reproduce_node=node,
    )
    return md_file_section(section)


def test_summary_row_escapes_untrusted_path() raises:
    var row = ReportRow(
        path="tests/we|rd.mojo",
        outcome_code=Outcome.PASS.code,
        duration_seconds=1.5,
        passed=3,
        failed=0,
        skipped=0,
        attempts=1,
    )
    assert_equal(
        md_summary_row(row),
        "| tests/we\\|rd.mojo | PASS | 1.500 | 3 | 0 | 0 | 1 |\n",
    )


def test_summary_table_header_exact() raises:
    assert_equal(
        md_summary_table_header(),
        (
            "| Path | Outcome | Duration (s) | Passed | Failed | Skipped |"
            " Attempts |\n"
            "| --- | --- | --- | --- | --- | --- | --- |\n"
        ),
    )


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
    var out = md_file_section(section)
    assert_true(out.find("````") != -1)
    assert_true(out.find("reproduce: `mtest tests/a.mojo::test_x`") != -1)
    assert_true(out.find("debug: `mtest debug tests/a.mojo::test_x`") != -1)


def test_reproduce_quotes_a_hostile_node() raises:
    # A node containing a space MUST come out shell-quoted:
    var out = _section_with_node("tests/a b.mojo::test_x")
    assert_true(out.find("reproduce: `mtest 'tests/a b.mojo::test_x'`") != -1)


def test_reproduce_grows_the_span_past_an_embedded_backtick() raises:
    # A node carrying its own backtick must not be able to close the code
    # span early: the fence grows to two backticks around it.
    var out = _section_with_node("tests/a.mojo::test`x")
    assert_true(out.find("reproduce: ``mtest 'tests/a.mojo::test`x'``") != -1)


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


def test_file_section_leaves_the_root_note_to_the_document_head() raises:
    # Sections are spooled at file-finish and assembled in sorted path order,
    # so "the first section" is not a position any section can know it is in.
    # The note is stated once by `md_header` instead, and repeating it per
    # section would put it on the page as many times as the run had files.
    assert_true(
        md_file_section(_plain_section()).find("relative to the run root") == -1
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
    var out = md_file_section(section)
    assert_true(out.find("*(stdout truncated)*") != -1)
    assert_true(out.find("*(stderr truncated)*") != -1)
    # An empty reproduce_node renders neither line.
    assert_true(out.find("reproduce:") == -1)
    assert_true(out.find("debug:") == -1)


def test_stream_fences_hold_hostile_content() raises:
    # Structural Markdown inside a captured stream must stay inert: it rides
    # through the fence rather than being interpreted, and a run of three
    # backticks in the content forces the fence itself to grow to four.
    var section = ReportSectionInput(
        path="tests/c.mojo",
        root="",
        outcome_code=Outcome.FAIL.code,
        tests=List[TestResult](),
        stdout_text="closes ``` fence & <tag>",
        stderr_text="also </style> hostile",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="",
        reproduce_node="",
    )
    var out = md_file_section(section)
    assert_true(out.find("````\ncloses ``` fence & <tag>\n````") != -1)
    assert_true(out.find("also </style> hostile") != -1)


def test_attempts_are_cell_escaped_and_cannot_break_the_bullet() raises:
    # A leading '-' or '#' in an attempt summary must not be readable as a
    # second list marker or a heading, and a bare '<'/'&' must not survive
    # as HTML.
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
    var out = md_file_section(section)
    # Only '<' and '&' are escaped; a bare '>' is inert, matching
    # md_escape_cell's own contract.
    assert_true(out.find("- \\# fake heading &lt;b>&amp;amp;&lt;/b>\n") != -1)
    # The raw, unescaped forms must not appear anywhere in the output.
    assert_true(out.find("\n# fake heading") == -1)
    assert_true(out.find("<b>") == -1)


def test_build_line_is_a_code_target() raises:
    var section = ReportSectionInput(
        path="tests/e.mojo",
        root="",
        outcome_code=Outcome.COMPILE_ERROR.code,
        tests=List[TestResult](),
        stdout_text="",
        stderr_text="",
        stdout_truncated=False,
        stderr_truncated=False,
        attempts=List[String](),
        build_line="mojo build tests/e.mojo",
        reproduce_node="",
    )
    var out = md_file_section(section)
    assert_true(out.find("build: `mojo build tests/e.mojo`\n") != -1)


def test_build_line_hostile_sweep_stays_inside_the_code_span() raises:
    # A code-target position has different rules than a table cell: nothing
    # here is a cell-structural character, so a pipe, a leading '#', and a
    # bare '<'/'&' all ride through the span verbatim by Markdown's own
    # rule for code-span content. The only thing this position must defend
    # against is an embedded backtick prematurely closing the span, which is
    # why the fence must grow from one backtick to two.
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
    var out = md_file_section(section)
    assert_true(
        out.find("build: ``mojo build `-o` a|b <tag>&x # trailing``\n") != -1
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
    var out = md_file_section(section)
    assert_true(out.find("At tests/a.mojo:3: assertion failed") != -1)
    assert_true(out.find("/abs/root/tests/a.mojo") == -1)


def test_not_run_heading_is_exact() raises:
    # The bullets a caller emits below this must not float unlabelled between
    # the last file section and the machine index.
    assert_equal(md_not_run_heading(), "## Not run\n\n")


def test_not_run_line_escapes_a_hostile_leading_dash() raises:
    var record = NotRunRecord("-danger.mojo", NotRunReason.LIMIT_REACHED)
    assert_equal(
        md_not_run_line(record),
        "- \\-danger.mojo: stopped early (-x/--maxfail)\n",
    )


def test_header_states_that_paths_are_root_relative() raises:
    # The paths the report composes are root-relative, including the `At`
    # line rewritten inside a failure detail. Saying so once at the head is
    # what makes those paths readable from a checkout of the run root.
    var facts = ReportHeaderFacts(version="x.y.z", platform="Linux x86_64")
    # Assembled the way the writer assembles it, because the ordering is the
    # property under test: a note below the summary table is a note a reader
    # meets after every path it explains.
    var document = md_header(facts, _ctx()) + md_summary_table_header()
    var note = document.find("relative to the run root")
    assert_true(note != -1)
    assert_true(note < document.find("| Path |"))


def test_header_note_does_not_claim_the_reproduced_text() raises:
    # A section's `build:` line is the build argv verbatim and a captured
    # stream is the child's own bytes; neither is rewritten, so a note
    # promising the whole document would be false as written.
    var facts = ReportHeaderFacts(version="x.y.z", platform="Linux x86_64")
    var out = md_header(facts, _ctx())
    assert_true(out.find("captured output") != -1)
    assert_true(out.find("`build:`") != -1)


def test_header_names_shuffle_seed_only_when_shuffled() raises:
    var facts = ReportHeaderFacts(version="x.y.z", platform="Linux x86_64")
    var shuffled = md_header(facts, _ctx(shuffle=True, shuffle_seed=42))
    var plain = md_header(facts, _ctx(shuffle=False, shuffle_seed=42))
    assert_true(shuffled.find("shuffle seed: 42") != -1)
    assert_true(plain.find("shuffle seed:") == -1)


def test_header_omits_every_optional_line_for_a_minimal_run() raises:
    var facts = ReportHeaderFacts(version="x.y.z", platform="Linux x86_64")
    var out = md_header(facts, _ctx())
    assert_true(out.find("files:") == -1)
    assert_true(out.find("builds:") == -1)
    assert_true(out.find("flaky:") == -1)
    assert_true(out.find("workers:") == -1)
    assert_true(out.find("shuffle seed:") == -1)
    assert_true(out.find("shard:") == -1)
    assert_true(out.find("interrupted:") == -1)
    assert_true(out.find("drift:") == -1)


def test_header_names_every_fact_when_all_apply() raises:
    var facts = ReportHeaderFacts(version="x.y.z", platform="Linux x86_64")
    var out = md_header(
        facts,
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


def test_header_shard_label_is_cell_escaped() raises:
    var facts = ReportHeaderFacts(version="x.y.z", platform="Linux x86_64")
    var out = md_header(facts, _ctx(shard_label="# 2/5 <script>&x"))
    assert_true(out.find("shard: \\# 2/5 &lt;script>&amp;x\n") != -1)
    # The raw, unescaped forms must not appear anywhere in the output.
    assert_true(out.find("<script>") == -1)
    assert_true(out.find("\nshard: #") == -1)


def test_header_files_line_lists_nonzero_counts() raises:
    var counts = _zero_counts()
    counts[Outcome.PASS.code] = 3
    counts[Outcome.FAIL.code] = 1
    counts[Outcome.NOT_RUN.code] = 2
    var facts = ReportHeaderFacts(version="x.y.z", platform="Linux x86_64")
    var out = md_header(facts, _ctx(counts=counts))
    assert_true(out.find("files: 3 PASS, 1 FAIL, 2 NOT_RUN") != -1)


def test_outcome_label_is_total() raises:
    assert_equal(outcome_label(Outcome.PASS.code), "PASS")
    assert_equal(outcome_label(Outcome.FAIL.code), "FAIL")
    assert_equal(outcome_label(Outcome.SKIP.code), "SKIP")
    assert_equal(outcome_label(Outcome.CRASH.code), "CRASH")
    assert_equal(outcome_label(Outcome.TIMEOUT.code), "TIMEOUT")
    assert_equal(outcome_label(Outcome.COMPILE_ERROR.code), "COMPILE_ERROR")
    assert_equal(outcome_label(Outcome.COMPILE_TIMEOUT.code), "COMPILE_TIMEOUT")
    assert_equal(outcome_label(Outcome.MALFORMED_SUITE.code), "MALFORMED_SUITE")
    assert_equal(
        outcome_label(Outcome.PRECOMPILE_ERROR.code), "PRECOMPILE_ERROR"
    )
    assert_equal(outcome_label(Outcome.FLAKY.code), "FLAKY")
    assert_equal(outcome_label(Outcome.DESELECTED.code), "DESELECTED")
    assert_equal(outcome_label(Outcome.EXCLUDED.code), "EXCLUDED")
    assert_equal(outcome_label(Outcome.NOT_RUN.code), "NOT_RUN")
    assert_equal(outcome_label(99), "OUTCOME(99)")


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
        md_machine_index(rows, nodes),
        "## Machine index\n\n- `b.mojo` — FAIL\n- `d.mojo` — NOT_RUN\n",
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
    assert_equal(md_machine_index(rows, nodes), "")


def test_needs_action_is_total() raises:
    # The one hardcoded pin of the ruling itself: `report_model.needs_action`
    # is the single source of truth both `md_machine_index` and
    # `html_machine_index` call, so its own boolean per code is checked
    # here directly, against a literal restatement of the ruling, rather
    # than only indirectly through a renderer's output.
    for code in range(Outcome.COUNT):
        var excluded = (
            code == Outcome.PASS.code
            or code == Outcome.SKIP.code
            or code == Outcome.DESELECTED.code
            or code == Outcome.EXCLUDED.code
        )
        assert_equal(needs_action(code), not excluded)


def test_machine_index_outcome_inclusion_is_total() raises:
    # Walk every known outcome code and pin that md_machine_index's own
    # filtering agrees with the hoisted `needs_action` for every one of
    # them: PASS, SKIP, DESELECTED, and EXCLUDED are silent; every other
    # outcome, FLAKY and NOT_RUN included, gets a line.
    for code in range(Outcome.COUNT):
        var rows = List[ReportRow]()
        rows.append(_row("only.mojo", code))
        var nodes = List[String]()
        nodes.append("only.mojo")
        var out = md_machine_index(rows, nodes)
        if not needs_action(code):
            assert_equal(out, "")
        else:
            assert_true(out.find(outcome_label(code)) != -1)


def test_machine_index_guards_a_short_nodes_list() raises:
    # A `nodes` shorter than `rows` (a violated caller contract) must
    # degrade a target to '' rather than index out of bounds.
    var rows = List[ReportRow]()
    rows.append(_row("a.mojo", Outcome.FAIL.code))
    var nodes = List[String]()
    assert_equal(
        md_machine_index(rows, nodes), "## Machine index\n\n- `''` — FAIL\n"
    )


def test_machine_index_quotes_a_hostile_node() raises:
    var rows = List[ReportRow]()
    rows.append(_row("tests/a b.mojo", Outcome.CRASH.code))
    var nodes = List[String]()
    nodes.append("tests/a b.mojo")
    assert_equal(
        md_machine_index(rows, nodes),
        "## Machine index\n\n- `'tests/a b.mojo'` — CRASH\n",
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
