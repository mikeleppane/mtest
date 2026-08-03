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
    md_not_run_line,
    md_summary_row,
    md_summary_table_header,
)
from mtest.report.report_model import (
    ReportFinalizeContext,
    ReportHeaderFacts,
    ReportRow,
    ReportSectionInput,
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
) -> ReportFinalizeContext:
    return ReportFinalizeContext(
        counts=_zero_counts(),
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
    return md_file_section(section, root_note=False)


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
    var out = md_file_section(section, root_note=True)
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


def test_file_section_root_note_is_conditional() raises:
    var with_note = md_file_section(_plain_section(), root_note=True)
    var without_note = md_file_section(_plain_section(), root_note=False)
    assert_true(with_note.find("root-relative") != -1)
    assert_true(without_note.find("root-relative") == -1)


def test_file_section_marks_truncated_streams() raises:
    var section = ReportSectionInput(
        path="tests/b.mojo",
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
    var out = md_file_section(section, root_note=False)
    assert_true(out.find("*(stdout truncated)*") != -1)
    assert_true(out.find("*(stderr truncated)*") != -1)
    # An empty reproduce_node renders neither line.
    assert_true(out.find("reproduce:") == -1)
    assert_true(out.find("debug:") == -1)


def test_not_run_line_escapes_a_hostile_leading_dash() raises:
    var record = NotRunRecord("-danger.mojo", NotRunReason.LIMIT_REACHED)
    assert_equal(
        md_not_run_line(record),
        "- \\-danger.mojo: stopped early (-x/--maxfail)\n",
    )


def test_header_names_shuffle_seed_only_when_shuffled() raises:
    var facts = ReportHeaderFacts(version="1.0.0", platform="Linux x86_64")
    var shuffled = md_header(facts, _ctx(shuffle=True, shuffle_seed=42))
    var plain = md_header(facts, _ctx(shuffle=False, shuffle_seed=42))
    assert_true(shuffled.find("shuffle seed: 42") != -1)
    assert_true(plain.find("shuffle seed:") == -1)


def test_header_omits_every_optional_line_for_a_minimal_run() raises:
    var facts = ReportHeaderFacts(version="1.0.0", platform="Linux x86_64")
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
    var facts = ReportHeaderFacts(version="1.0.0", platform="Linux x86_64")
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


def test_machine_index_lists_exactly_non_green_rows() raises:
    var rows = List[ReportRow]()
    rows.append(_row("a.mojo", Outcome.PASS.code))
    rows.append(_row("b.mojo", Outcome.FAIL.code))
    rows.append(_row("c.mojo", Outcome.SKIP.code))
    rows.append(_row("d.mojo", Outcome.NOT_RUN.code))
    var nodes = List[String]()
    nodes.append("a.mojo")
    nodes.append("b.mojo")
    nodes.append("c.mojo")
    nodes.append("d.mojo")
    assert_equal(
        md_machine_index(rows, nodes),
        (
            "## Machine index\n\n"
            "- `b.mojo` — FAIL\n"
            "- `c.mojo` — SKIP\n"
            "- `d.mojo` — NOT_RUN\n"
        ),
    )


def test_machine_index_is_empty_when_every_row_is_green() raises:
    var rows = List[ReportRow]()
    rows.append(_row("a.mojo", Outcome.PASS.code))
    var nodes = List[String]()
    nodes.append("a.mojo")
    assert_equal(md_machine_index(rows, nodes), "")


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
