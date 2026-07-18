"""Tests for the pure GitHub Actions annotations renderer (Layer 2).

Drives typed event streams through `render_annotations` and asserts EXACT
rendered workflow-command lines: the frozen per-shape templates (per-test FAIL
with/without a `line=` property, crash/file-level, FLAKY, the single notice,
precompile with no `file=`), the node-id sort, the 4096-escaped-byte per-message
bound with its truncation marker, the 10-error/10-warning per-run caps with the
cap-minus-one + aggregate-line collapse, and both GH escaping contexts (message
vs property) over hostile input — including a would-be forged `::error` inside
a message, neutralized because the CR/LF that would start a new output line is
escaped away.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.model.events import Event
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome
from mtest.model.parse_disposition import ParseDisposition
from mtest.model.test_counts import TestCounts
from mtest.model.test_result import TestResult
from mtest.model.events import Summary
from mtest.report.annotations import render_annotations
from mtest.report.annotations_reporter import AnnotationsReporter


def _fail(path: String, name: String, detail: String) -> Event:
    return Event.test_reported(
        TestResult(NodeId(path, name), Outcome.FAIL, detail, "")
    )


def _file_finished(
    path: String,
    outcome: Outcome,
    signal_number: Int = 0,
    timeout_seconds: Int = 0,
    escalated: Bool = False,
    parse_disposition: ParseDisposition = ParseDisposition.NO_REPORT,
    attempts_used: Int = 1,
    flaky: Bool = False,
) -> Event:
    return Event.file_finished(
        path,
        outcome,
        0.1,
        List[String](),
        0.0,
        List[UInt8](),
        List[UInt8](),
        signal_number=signal_number,
        timeout_seconds=timeout_seconds,
        escalated=escalated,
        parse_disposition=parse_disposition,
        attempts_used=attempts_used,
        flaky=flaky,
    )


def _attempt(path: String, attempts_planned: Int) -> Event:
    return Event.attempt_finished(
        path,
        "run",
        1,
        attempts_planned,
        1,
        11,
        1,
        11,
        False,
        True,
        "signal",
        0.1,
        List[UInt8](),
        List[UInt8](),
        False,
        False,
        List[String](),
    )


def _session_finished(
    passed: Int,
    failed: Int,
    skipped: Int,
    excluded: Int,
    not_run: Int,
    wall_time_seconds: Float64,
) -> Event:
    var s = Summary.zeros()
    s.counts[Outcome.EXCLUDED.code] = excluded
    s.counts[Outcome.NOT_RUN.code] = not_run
    return Event.session_finished(
        s^,
        wall_time_seconds,
        0,
        test_counts=TestCounts(
            passed=passed, failed=failed, skipped=skipped, deselected=0
        ),
    )


# --- Per-test FAIL, with a `line=` property ---------------------------------


def test_per_test_fail_with_line() raises:
    var events = List[Event]()
    events.append(
        _fail(
            "tests/test_x.mojo",
            "test_x",
            "At tests/test_x.mojo:12:5: AssertionError: nope",
        )
    )
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    assert_equal(
        out[0],
        (
            "::error file=tests/test_x.mojo,line=12::tests/test_x.mojo::test_x:"
            " At tests/test_x.mojo:12:5: AssertionError: nope"
        ),
    )


# --- Per-test FAIL, no location line -> NO `line=` property (honesty) ------


def test_per_test_fail_without_line() raises:
    var events = List[Event]()
    events.append(
        _fail("tests/test_y.mojo", "test_y", "boom:\n  fake detail line")
    )
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    assert_equal(
        out[0],
        "::error file=tests/test_y.mojo::tests/test_y.mojo::test_y: boom:",
    )


def test_per_test_fail_leading_indent_before_at_line_still_finds_line() raises:
    var events = List[Event]()
    events.append(
        _fail(
            "tests/test_z.mojo",
            "test_z",
            "      At tests/test_z.mojo:7:3: AssertionError: nope",
        )
    )
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    assert_true("line=7" in out[0])


# --- Crash-class / file-level failure: `::error file=<f>::<path>: <words>` -


def test_crash_class_row_names_the_signal_in_words() raises:
    var events = List[Event]()
    events.append(
        _file_finished("tests/test_c.mojo", Outcome.CRASH, signal_number=11)
    )
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    assert_equal(
        out[0],
        (
            "::error file=tests/test_c.mojo::tests/test_c.mojo: crashed (signal"
            " 11 — SIGSEGV, segmentation fault)"
        ),
    )


def test_crash_class_row_never_carries_a_line_property() raises:
    var events = List[Event]()
    events.append(
        _file_finished("tests/test_c.mojo", Outcome.CRASH, signal_number=11)
    )
    var out = render_annotations(events)
    assert_false("line=" in out[0])


def test_timeout_row_names_deadline_and_escalation() raises:
    var events = List[Event]()
    events.append(
        _file_finished(
            "tests/test_t.mojo",
            Outcome.TIMEOUT,
            timeout_seconds=30,
            escalated=True,
        )
    )
    var out = render_annotations(events)
    assert_equal(
        out[0],
        (
            "::error file=tests/test_t.mojo::tests/test_t.mojo: timed out after"
            " 30s, escalated to SIGKILL"
        ),
    )


def test_compile_error_row() raises:
    var events = List[Event]()
    events.append(_file_finished("tests/test_e.mojo", Outcome.COMPILE_ERROR))
    var out = render_annotations(events)
    assert_equal(
        out[0],
        "::error file=tests/test_e.mojo::tests/test_e.mojo: compile error",
    )


def test_malformed_suite_row_names_ambiguous_vs_no_report() raises:
    var events = List[Event]()
    events.append(
        _file_finished(
            "tests/test_m.mojo",
            Outcome.MALFORMED_SUITE,
            parse_disposition=ParseDisposition.AMBIGUOUS,
        )
    )
    var out = render_annotations(events)
    assert_equal(
        out[0],
        (
            "::error file=tests/test_m.mojo::tests/test_m.mojo: malformed suite"
            " (ambiguous report)"
        ),
    )


def test_plain_fail_file_finished_yields_no_file_level_row() raises:
    # A plain per-test FAIL file is covered by its TEST_REPORTED rows; the
    # FileFinished(FAIL) itself must not ALSO produce a file-level ::error.
    var events = List[Event]()
    events.append(_file_finished("tests/test_p.mojo", Outcome.FAIL))
    var out = render_annotations(events)
    assert_equal(len(out), 0)


# --- FLAKY: `::warning file=<f>::<path>: flaky — passed on attempt K of N` -


def test_flaky_row_names_attempt_k_of_n() raises:
    var events = List[Event]()
    events.append(_attempt("tests/test_f.mojo", 3))
    events.append(
        _file_finished(
            "tests/test_f.mojo", Outcome.PASS, attempts_used=2, flaky=True
        )
    )
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    assert_equal(
        out[0],
        (
            "::warning file=tests/test_f.mojo::tests/test_f.mojo: flaky —"
            " passed on attempt 2 of 3"
        ),
    )


def test_flaky_reconciliation_resets_between_files() raises:
    # The attempts_planned fact must not leak from an earlier file's attempt
    # into a LATER file's flaky row.
    var events = List[Event]()
    events.append(_attempt("tests/test_a.mojo", 5))
    events.append(_file_finished("tests/test_a.mojo", Outcome.PASS))
    events.append(Event.file_started("tests/test_b.mojo"))
    events.append(_attempt("tests/test_b.mojo", 2))
    events.append(
        _file_finished(
            "tests/test_b.mojo", Outcome.PASS, attempts_used=2, flaky=True
        )
    )
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    assert_true("attempt 2 of 2" in out[0])


# --- Exactly one `::notice`, never capped -----------------------------------


def test_exactly_one_notice_from_session_finished() raises:
    var events = List[Event]()
    events.append(_session_finished(5, 1, 2, 1, 0, 12.3))
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    assert_equal(
        out[0],
        (
            "::notice::5 passed, 1 failed, 2 skipped (1 excluded, 0 not run) in"
            " 12.3s"
        ),
    )


def test_no_session_finished_yields_no_notice() raises:
    var events = List[Event]()
    var out = render_annotations(events)
    assert_equal(len(out), 0)


# --- The stateful AnnotationsReporter shell ---------------------------------


def _mixed_stream() -> List[Event]:
    """One error row (file z), one flaky warning (file a), and a notice."""
    var events = List[Event]()
    events.append(Event.file_started("tests/test_zzz.mojo"))
    events.append(_fail("tests/test_zzz.mojo", "test_boom", "boom"))
    events.append(_file_finished("tests/test_zzz.mojo", Outcome.FAIL))
    events.append(Event.file_started("tests/test_aaa.mojo"))
    events.append(_attempt("tests/test_aaa.mojo", 2))
    events.append(
        _file_finished(
            "tests/test_aaa.mojo", Outcome.FLAKY, attempts_used=2, flaky=True
        )
    )
    events.append(_session_finished(1, 1, 0, 0, 0, 3.0))
    return events^


def _feed(mut rep: AnnotationsReporter, events: List[Event]):
    for e in events:
        rep.handle(e)


def test_active_reporter_matches_the_pure_renderer() raises:
    var events = _mixed_stream()
    var rep = AnnotationsReporter(active=True)
    _feed(rep, events)
    var got = rep.render()
    var want = render_annotations(events)
    assert_equal(len(got), len(want), "reporter and renderer disagree on count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], "reporter line differs from renderer")


def test_inactive_reporter_renders_nothing() raises:
    var events = _mixed_stream()
    var rep = AnnotationsReporter.inert()
    _feed(rep, events)
    assert_equal(len(rep.render()), 0)


def test_reporter_tail_is_per_kind_grouped_not_globally_interleaved() raises:
    # The error is on node id "tests/test_zzz.mojo::test_boom"; the warning is on
    # file "tests/test_aaa.mojo". A GLOBAL node-id interleave would put the "a"
    # warning before the "z" error; per-kind grouping keeps the WHOLE ::error
    # block first, then the WHOLE ::warning block, then the single ::notice.
    var rep = AnnotationsReporter(active=True)
    _feed(rep, _mixed_stream())
    var lines = rep.render()
    assert_equal(len(lines), 3, "expected one error, one warning, one notice")
    assert_true(lines[0].startswith("::error "), "error block is not first")
    assert_true(
        lines[1].startswith("::warning "), "warning block is not second"
    )
    assert_true(lines[2].startswith("::notice::"), "notice is not last")
    assert_true("test_zzz" in lines[0])
    assert_true("test_aaa" in lines[1])


# --- Precompile: one `::error` with NO `file=` property ---------------------


def test_precompile_error_carries_no_file_property() raises:
    var events = List[Event]()
    events.append(
        Event.precompile_failed(
            "build-support",
            "compiler said things",
            3,
            ending_known=True,
            term_kind=1,
            term_value=11,
        )
    )
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    assert_false("file=" in out[0])
    assert_equal(
        out[0],
        (
            "::error::build-support: precompile failed (died by signal 11"
            " (SIGSEGV, segmentation fault)); 3 file(s) could not run"
        ),
    )


def test_precompile_error_names_retry_count_when_retried() raises:
    var events = List[Event]()
    events.append(
        Event.precompile_failed(
            "build-support",
            "",
            1,
            ending_known=True,
            term_kind=2,
            term_value=0,
            timeout_seconds=600,
            attempts_used=2,
        )
    )
    var out = render_annotations(events)
    assert_true("2 attempts" in out[0])
    assert_true("timed out after 600s" in out[0])


# --- Node-id sort order ------------------------------------------------------


def test_error_rows_are_node_id_sorted() raises:
    var events = List[Event]()
    events.append(_fail("tests/b.mojo", "test_1", "boom"))
    events.append(_fail("tests/a.mojo", "test_2", "boom"))
    events.append(_fail("tests/a.mojo", "test_1", "boom"))
    var out = render_annotations(events)
    assert_equal(len(out), 3)
    assert_true("tests/a.mojo::test_1:" in out[0])
    assert_true("tests/a.mojo::test_2:" in out[1])
    assert_true("tests/b.mojo::test_1:" in out[2])


# --- 4096-escaped-byte per-message bound + truncation marker ---------------


def test_message_is_bounded_at_4096_escaped_bytes_with_marker() raises:
    var long_first_line = String("")
    for _ in range(5000):
        long_first_line += "x"
    var events = List[Event]()
    events.append(_fail("tests/big.mojo", "test_big", long_first_line))
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    var prefix = "::error file=tests/big.mojo::"
    assert_true(out[0].startswith(prefix))
    var message = String(out[0].removeprefix(prefix))
    assert_equal(message.byte_length(), 4096)
    assert_true(message.endswith(" …[truncated]"))


def test_short_message_is_not_truncated() raises:
    var events = List[Event]()
    events.append(_fail("tests/small.mojo", "test_small", "short"))
    var out = render_annotations(events)
    assert_false("[truncated]" in out[0])


# --- 10-error cap with cap-minus-one + aggregate collapse -------------------


def test_error_cap_collapses_overflow_into_aggregate_line() raises:
    var events = List[Event]()
    for i in range(12):
        var n = String(i)
        var padded = n if n.byte_length() == 2 else "0" + n
        events.append(_fail("tests/t" + padded + ".mojo", "test", "boom"))
    var out = render_annotations(events)
    assert_equal(len(out), 10)
    for i in range(9):
        var n = String(i)
        var padded = n if n.byte_length() == 2 else "0" + n
        assert_true(("tests/t" + padded + ".mojo") in out[i])
    assert_equal(out[9], "::error::... and 3 more errors")


def test_error_count_at_exactly_the_cap_is_not_collapsed() raises:
    var events = List[Event]()
    for i in range(10):
        var n = String(i)
        var padded = n if n.byte_length() == 2 else "0" + n
        events.append(_fail("tests/t" + padded + ".mojo", "test", "boom"))
    var out = render_annotations(events)
    assert_equal(len(out), 10)
    for i in range(10):
        assert_false("more errors" in out[i])


# --- 10-warning cap with cap-minus-one + aggregate collapse -----------------


def test_warning_cap_collapses_overflow_into_aggregate_line() raises:
    var events = List[Event]()
    for i in range(12):
        var n = String(i)
        var padded = n if n.byte_length() == 2 else "0" + n
        var path = "tests/f" + padded + ".mojo"
        events.append(_attempt(path, 2))
        events.append(
            _file_finished(path, Outcome.PASS, attempts_used=2, flaky=True)
        )
        events.append(Event.file_started("tests/next.mojo"))
    var out = render_annotations(events)
    assert_equal(len(out), 10)
    assert_equal(out[9], "::warning::... and 3 more warnings")


# --- Both escaping contexts over hostile input ------------------------------


def test_message_context_escapes_percent_and_crlf_but_not_colon_or_comma() raises:
    var events = List[Event]()
    events.append(_fail("tests/w.mojo", "test_w", "bad%line:with,commas\rend"))
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    assert_equal(
        out[0],
        (
            "::error file=tests/w.mojo::tests/w.mojo::test_w: bad%25line:with,"
            "commas%0Dend"
        ),
    )


def test_property_context_escapes_colon_comma_and_percent_in_path() raises:
    var events = List[Event]()
    events.append(
        _file_finished("tests/weird:name,here%.mojo", Outcome.COMPILE_ERROR)
    )
    var out = render_annotations(events)
    assert_true("file=tests/weird%3Aname%2Chere%25.mojo::" in out[0])


def test_control_bytes_other_than_percent_crlf_pass_through_unchanged() raises:
    var detail = String("bad") + chr(1) + "tail"
    var events = List[Event]()
    events.append(_fail("tests/ctl.mojo", "test_ctl", detail))
    var out = render_annotations(events)
    assert_true("bad" in out[0])
    assert_true("tail" in out[0])


# --- A forged `::error` inside message text is neutralized -----------------


def test_forged_error_command_inside_message_is_neutralized() raises:
    var events = List[Event]()
    events.append(
        _fail(
            "tests/evil.mojo",
            "test_evil",
            "boom\r::error file=evil::pwned::injected",
        )
    )
    var out = render_annotations(events)
    assert_equal(len(out), 1)
    # No raw CR survives — the only way a forged `::error` could start a NEW
    # output line is a literal line break, and none exists in the rendered
    # text.
    assert_false("\r" in out[0])
    assert_true("%0D" in out[0])
    assert_equal(len(out[0].split("\n")), 1)
    assert_equal(
        out[0],
        (
            "::error file=tests/evil.mojo::tests/evil.mojo::test_evil: boom%0D"
            "::error file=evil::pwned::injected"
        ),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
