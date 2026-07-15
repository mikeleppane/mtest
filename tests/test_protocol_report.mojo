"""Golden-driven tests for `parse_report` (Layer 2): the four report verdicts.

Every report-bearing golden under `goldens/transcripts/` is the oracle here: the
frozen bytes `std.testing.TestSuite` emits at the pinned toolchain. Each test
drives `parse_report` over a golden's stdout region (via `transcript_cases`) and
pins the verdict, the parsed rows, the counts, and — for the FAIL cases — the
verbatim detail. A crash or a usage-error golden carries no report block, so it
must classify ABSENT, never a partial VALID.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.model import Outcome
from mtest.protocol import ParsedReport, ReportVerdict, parse_report

from transcript_cases import (
    read_golden,
    read_manifest,
    stdout_region,
    source_path_for,
)


def _parse(name: String) raises -> ParsedReport:
    return parse_report(stdout_region(read_golden(name)), source_path_for(name))


def _expected_valid() -> List[String]:
    """Goldens that carry one well-formed report for their source path."""
    return [
        "passing--default.txt",
        "passing--skip-all.txt",
        "passing--only-many.txt",
        "empty--default.txt",
        "empty--skip-all.txt",
        "skipped--default.txt",
        "skipped--skip-all.txt",
        "skipped--only-native.txt",
        "mixed--default.txt",
        "mixed--skip-one.txt",
        "mixed--only-selected-fail.txt",
        "twofail--default.txt",
        "raising--default.txt",
        "noisy--default.txt",
    ]


def _expected_absent() -> List[String]:
    """Goldens that carry no matching-path report (crash or usage error)."""
    return [
        "crashing--default.txt",
        "passing--only-unknown.txt",
        "passing--flag-unknown.txt",
        "passing--no-compose.txt",
        "passing--only-noargs.txt",
        "passing--skip-all-args.txt",
        "passing--skip-unknown.txt",
    ]


def _contains(names: List[String], target: String) -> Bool:
    for n in names:
        if n == target:
            return True
    return False


def test_manifest_enumerates_every_scenario_verdict() raises:
    # Enumerate via MANIFEST.txt, not a hard-coded list: every golden is either
    # asserted VALID-with-expectations or ASSERTED ABSENT, and the two buckets
    # partition the manifest exactly, so a newly added golden cannot silently
    # escape parser coverage.
    var manifest = read_manifest()
    var valid = _expected_valid()
    var absent = _expected_absent()

    # Airtight partition length: a duplicate WITHIN one bucket (e.g. the same
    # name listed twice in `_expected_valid`) would still satisfy the
    # per-name completeness loop below while silently dropping coverage of
    # some other manifest entry — this catches it directly.
    assert_equal(len(valid) + len(absent), len(manifest))

    # Completeness: each manifest name is classified by exactly one bucket.
    for name in manifest:
        var in_valid = _contains(valid, String(name))
        var in_absent = _contains(absent, String(name))
        assert_true(in_valid or in_absent)
        assert_false(in_valid and in_absent)

    # No expectation names a golden absent from the manifest.
    for name in valid:
        assert_true(_contains(manifest, String(name)))
    for name in absent:
        assert_true(_contains(manifest, String(name)))

    # Drive the parser over every enumerated scenario and pin its verdict.
    for name in valid:
        assert_true(_parse(String(name)).verdict == ReportVerdict.VALID)
    for name in absent:
        assert_true(_parse(String(name)).verdict == ReportVerdict.ABSENT)


def test_passing_default_three_pass_rows() raises:
    var r = _parse("passing--default.txt")
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(r.declared_count, 3)
    assert_equal(len(r.rows), 3)
    assert_equal(r.rows[0].name, "test_zeta_passes")
    assert_equal(r.rows[1].name, "test_alpha_passes")
    assert_equal(r.rows[2].name, "test_mid_passes")
    for i in range(3):
        assert_true(r.rows[i].outcome == Outcome.PASS)
        assert_equal(r.rows[i].detail, "")
        assert_equal(r.rows[i].timing, "T")
    assert_equal(r.summary_passed, 3)
    assert_equal(r.summary_failed, 0)
    assert_equal(r.summary_skipped, 0)
    assert_false(r.has_trailer)


def test_empty_reports_declare_zero_rows() raises:
    for name in ["empty--default.txt", "empty--skip-all.txt"]:
        var r = _parse(String(name))
        assert_true(r.verdict == ReportVerdict.VALID)
        assert_equal(r.declared_count, 0)
        assert_equal(len(r.rows), 0)
        assert_equal(r.summary_passed, 0)
        assert_equal(r.summary_failed, 0)
        assert_equal(r.summary_skipped, 0)
        assert_false(r.has_trailer)


def test_skipped_goldens_are_valid_with_skip_rows() raises:
    for name in [
        "skipped--default.txt",
        "skipped--skip-all.txt",
        "skipped--only-native.txt",
    ]:
        var r = _parse(String(name))
        assert_true(r.verdict == ReportVerdict.VALID)
        assert_equal(r.declared_count, 2)
        assert_equal(len(r.rows), 2)
        assert_false(r.has_trailer)
        # Every scenario here ends with at least one SKIP row and no failure.
        assert_equal(r.summary_failed, 0)
        assert_true(r.summary_skipped >= 1)


def test_mixed_default_valid_with_fail_detail() raises:
    var r = _parse("mixed--default.txt")
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(r.declared_count, 3)
    assert_equal(len(r.rows), 3)
    assert_true(r.rows[0].outcome == Outcome.PASS)
    assert_true(r.rows[1].outcome == Outcome.FAIL)
    assert_true(r.rows[2].outcome == Outcome.PASS)
    assert_equal(r.rows[1].name, "test_second_fails")
    assert_true("At <REPO>/fixtures/mixed.mojo:14:17:" in r.rows[1].detail)
    assert_true("left: 1" in r.rows[1].detail)
    assert_true("right: 2" in r.rows[1].detail)
    assert_equal(r.summary_passed, 2)
    assert_equal(r.summary_failed, 1)
    assert_equal(r.summary_skipped, 0)
    assert_true(r.has_trailer)


def test_mixed_selection_variants_valid() raises:
    var one = _parse("mixed--skip-one.txt")
    assert_true(one.verdict == ReportVerdict.VALID)
    assert_equal(len(one.rows), 3)
    assert_true(one.rows[1].outcome == Outcome.SKIP)
    assert_equal(one.summary_skipped, 1)
    assert_false(one.has_trailer)

    var sel = _parse("mixed--only-selected-fail.txt")
    assert_true(sel.verdict == ReportVerdict.VALID)
    assert_equal(len(sel.rows), 3)
    assert_true(sel.rows[0].outcome == Outcome.SKIP)
    assert_true(sel.rows[1].outcome == Outcome.FAIL)
    assert_true(sel.rows[2].outcome == Outcome.SKIP)
    assert_equal(sel.summary_passed, 0)
    assert_equal(sel.summary_failed, 1)
    assert_equal(sel.summary_skipped, 2)
    assert_true(sel.has_trailer)


def test_twofail_detail_is_verbatim() raises:
    var r = _parse("twofail--default.txt")
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(len(r.rows), 2)
    assert_true(r.rows[0].outcome == Outcome.FAIL)
    assert_true(r.rows[1].outcome == Outcome.FAIL)
    # Detail is joined verbatim, indentation preserved, not reindented.
    assert_equal(
        r.rows[0].detail,
        (
            "      At <REPO>/fixtures/twofail.mojo:10:17: AssertionError:"
            " `left == right` comparison failed:\n         left: 10\n     "
            "   right: 11"
        ),
    )
    assert_equal(r.summary_failed, 2)
    assert_true(r.has_trailer)


def test_raising_detail_has_no_at_line() raises:
    var r = _parse("raising--default.txt")
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(len(r.rows), 1)
    assert_true(r.rows[0].outcome == Outcome.FAIL)
    # A raised error carries a plain message, no `At <path>:l:c` assertion line.
    assert_equal(r.rows[0].detail, "      boom:\n        fake detail line")
    assert_false("At <REPO>" in r.rows[0].detail)
    assert_equal(r.summary_failed, 1)
    assert_true(r.has_trailer)


def test_noisy_impostor_row_is_ignored() raises:
    var r = _parse("noisy--default.txt")
    assert_true(r.verdict == ReportVerdict.VALID)
    assert_equal(r.declared_count, 3)
    assert_equal(len(r.rows), 3)
    # The pre-header `PASS [ 0.001 ] fake_impostor` must NOT appear as a row.
    for i in range(len(r.rows)):
        assert_true(r.rows[i].name != "fake_impostor")
    assert_equal(r.rows[0].name, "test_prints_and_passes")
    assert_equal(r.rows[1].name, "test_prints_then_fails")
    assert_true(r.rows[1].outcome == Outcome.FAIL)
    assert_true("At <REPO>/fixtures/noisy.mojo:32:17:" in r.rows[1].detail)
    assert_equal(r.rows[2].name, "test_prints_timing_lookalike")
    assert_equal(r.summary_passed, 2)
    assert_equal(r.summary_failed, 1)
    assert_true(r.has_trailer)


def test_passing_skip_and_only_variants_valid() raises:
    var all_skipped = _parse("passing--skip-all.txt")
    assert_true(all_skipped.verdict == ReportVerdict.VALID)
    assert_equal(len(all_skipped.rows), 3)
    assert_equal(all_skipped.summary_skipped, 3)
    for i in range(3):
        assert_true(all_skipped.rows[i].outcome == Outcome.SKIP)

    var many = _parse("passing--only-many.txt")
    assert_true(many.verdict == ReportVerdict.VALID)
    assert_equal(len(many.rows), 3)
    assert_equal(many.summary_passed, 2)
    assert_equal(many.summary_skipped, 1)
    assert_true(many.rows[1].outcome == Outcome.SKIP)


def test_crashing_has_no_report_absent() raises:
    var r = _parse("crashing--default.txt")
    assert_true(r.verdict == ReportVerdict.ABSENT)
    assert_equal(len(r.rows), 0)
    assert_equal(r.declared_count, 0)


def test_usage_error_goldens_are_absent() raises:
    # These carry only an `Unhandled exception ...` phrase, no report block —
    # a session concern, not the parser's; the parser sees no matching header.
    for name in [
        "passing--only-unknown.txt",
        "passing--flag-unknown.txt",
        "passing--no-compose.txt",
        "passing--only-noargs.txt",
        "passing--skip-all-args.txt",
        "passing--skip-unknown.txt",
    ]:
        var r = _parse(String(name))
        assert_true(r.verdict == ReportVerdict.ABSENT)
        assert_equal(len(r.rows), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
