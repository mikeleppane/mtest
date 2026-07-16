"""Structural tests for the ConsoleReporter design language (Layer 2).

These feed a fixed event stream and assert the STRUCTURE of the rendered buffer,
not its exact bytes: one verdict line per FileFinished in order, the fixed
verdict-token vocabulary, per-TEST failure sections carrying a node id + verbatim
detail + a copy-pasteable repro line, the once-per-file file-scope captured-output
label, `-v` per-test rows, the NO-TESTS / MALFORMED-SUITE / DRIFT /
capture-overflow tokens, the TEST-count summary band, no escape codes when color
is off, signals named in words, and captured output rendered verbatim. The
console learns every printed fact from the events — only version and config are
passed in.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.config import ColorWhen, Verbosity, ShowOutput
from mtest.model import (
    EventKind,
    Summary,
    Event,
    Outcome,
    NodeId,
    ParseDisposition,
    TestCounts,
    TestResult,
)
from mtest.report import ConsoleReporter


def _bytes(s: String) -> List[UInt8]:
    """The raw UTF-8 bytes of `s` as an owned list, for captured-stream fields.
    """
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _argv(path: String) -> List[String]:
    """A representative `mojo build <path>` argv for the build-command field."""
    return ["mojo", "build", path]


def _count(haystack: String, needle: String) -> Int:
    """How many non-overlapping times `needle` occurs in `haystack`."""
    return len(haystack.split(needle)) - 1


def _console(
    color: ColorWhen = ColorWhen.NEVER,
    verbosity: Verbosity = Verbosity.NORMAL,
    show_output: ShowOutput = ShowOutput.FAILURES,
    is_tty: Bool = False,
    no_color: Bool = False,
    mtest_build_flags: String = "",
    durations: Int = 0,
) -> ConsoleReporter:
    """A console reporter with the mock's version and the given config."""
    return ConsoleReporter(
        "0.1.0-dev",
        color,
        is_tty=is_tty,
        no_color=no_color,
        verbosity=verbosity,
        show_output=show_output,
        mtest_build_flags=mtest_build_flags,
        durations=durations,
    )


def _mock_summary() -> Summary:
    """1 pass, 1 fail, 1 crash, 1 timeout, 1 compile error, 1 excluded, 2 not run.
    """
    var s = Summary.zeros()
    s.counts[Outcome.PASS.code] = 1
    s.counts[Outcome.FAIL.code] = 1
    s.counts[Outcome.CRASH.code] = 1
    s.counts[Outcome.TIMEOUT.code] = 1
    s.counts[Outcome.COMPILE_ERROR.code] = 1
    s.counts[Outcome.EXCLUDED.code] = 1
    s.counts[Outcome.NOT_RUN.code] = 2
    return s^


def _mock_test_counts() -> TestCounts:
    """The per-TEST totals matching `_feed_mock_run`: 1 passed, 1 failed."""
    return TestCounts(passed=1, failed=1, skipped=0, deselected=0)


def _feed_mock_run(mut c: ConsoleReporter):
    """Drive the reporter through the full console mock event stream.

    The stream mirrors what the session emits: a FILE_STARTED before each file,
    the retrospective per-test TEST_REPORTED rows for a parsed report, then the
    FILE_FINISHED verdict. The passing file collects one passing test; the
    failing file collects one failing test carrying assertion detail.
    """
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 5, 1))
    c.handle(
        Event.file_finished(
            "tests/slow/test_giant.mojo",
            Outcome.EXCLUDED,
            0.0,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
            exclusion_pattern="--exclude tests/slow/*",
        )
    )
    c.handle(Event.file_started("tests/test_alpha.mojo"))
    c.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_alpha.mojo", "test_alpha_one"), Outcome.PASS
            )
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_alpha.mojo",
            Outcome.PASS,
            0.41,
            _argv("tests/test_alpha.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
        )
    )
    c.handle(Event.file_started("tests/test_beta.mojo"))
    c.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_beta.mojo", "test_beta_fails"),
                Outcome.FAIL,
                "      boom:\n        fake detail line",
                "",
            )
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_beta.mojo",
            Outcome.FAIL,
            0.52,
            _argv("tests/test_beta.mojo"),
            1.0,
            _bytes("the suite report, verbatim\n"),
            _bytes("on stderr\n"),
            exit_status=1,
            parse_disposition=ParseDisposition.PARSED,
            failed_tests=1,
        )
    )
    c.handle(Event.file_started("tests/test_gamma.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_gamma.mojo",
            Outcome.CRASH,
            0.09,
            _argv("tests/test_gamma.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            signal_number=4,
        )
    )
    c.handle(Event.file_started("tests/test_delta.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_delta.mojo",
            Outcome.TIMEOUT,
            300.0,
            _argv("tests/test_delta.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            timeout_seconds=300,
        )
    )
    c.handle(Event.file_started("tests/test_typo.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_typo.mojo",
            Outcome.COMPILE_ERROR,
            1.30,
            _argv("tests/test_typo.mojo"),
            1.30,
            List[UInt8](),
            _bytes(
                "test_typo.mojo:3:5: error: use of unknown declaration 'foo'\n"
            ),
        )
    )
    c.handle(
        Event.session_finished(
            _mock_summary(), 302.4, 1, test_counts=_mock_test_counts()
        )
    )


def test_header_learns_facts_from_session_started() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 5, 1))
    var out = c.output()
    assert_true("mtest 0.1.0-dev (mojo 1.0.0b2)" in out)
    assert_true("root: tests" in out)
    assert_true("selected: 5 files" in out)
    assert_true("excluded: 1" in out)


def test_one_verdict_line_per_file_in_order() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    # Verdict lines appear in file order; each token precedes its path on a line,
    # and the paths (first occurrence = the verdict block, before any section)
    # are in emission order.
    assert_true("PASS" in out)
    assert_true("TIMEOUT" in out)
    assert_true("COMPILE-ERROR" in out)
    var i_alpha = out.find("tests/test_alpha.mojo")
    var i_beta = out.find("tests/test_beta.mojo")
    var i_gamma = out.find("tests/test_gamma.mojo")
    var i_delta = out.find("tests/test_delta.mojo")
    var i_typo = out.find("tests/test_typo.mojo")
    assert_true(i_alpha >= 0)
    assert_true(i_alpha < i_beta)
    assert_true(i_beta < i_gamma)
    assert_true(i_gamma < i_delta)
    assert_true(i_delta < i_typo)


def test_excluded_line_is_loud_and_names_pattern() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    assert_true("EXCLUDED" in out)
    assert_true("tests/slow/test_giant.mojo" in out)
    assert_true("(--exclude tests/slow/*)" in out)


def test_not_run_has_no_per_file_line_only_a_count() raises:
    # A stray NOT_RUN FileFinished must not crash and must not emit a line.
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(
        Event.file_finished(
            "tests/test_skipped.mojo",
            Outcome.NOT_RUN,
            0.0,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
        )
    )
    var out = c.output()
    assert_false("NOT-RUN" in out)
    assert_false("tests/test_skipped.mojo" in out)


def test_crash_names_signal_in_words() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    assert_true("signal 4 — SIGILL, illegal instruction" in out)


def test_timeout_notes_the_deadline() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    assert_true("timed out after 300s" in out)


def test_failing_test_section_carries_node_id_and_repro() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    # The failing test gets its OWN framed section headed by the node id.
    assert_true("--- FAIL tests/test_beta.mojo::test_beta_fails ---" in out)
    # The verbatim assertion detail rides through (dedented, see the dedicated
    # transform test); a distinctive fragment survives.
    assert_true("fake detail line" in out)
    # A copy-pasteable per-test repro names the node id (path::test).
    assert_true("reproduce: mtest tests/test_beta.mojo::test_beta_fails" in out)


def test_detail_is_dedented_and_at_line_made_root_relative() raises:
    # The two — and ONLY two — permitted detail transformations: strip the
    # common leading indentation TestSuite bakes in, and render `At <abs>:...`
    # lines root-relative by stripping the run root. Everything else is verbatim.
    var c = _console()
    c.handle(Event.session_started("/run/root", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_x.mojo"))
    var detail = (
        "        Unhandled exception\n"
        "        At /run/root/tests/test_x.mojo:12:5: AssertionError: nope\n"
        "          extra"
    )
    c.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_x.mojo", "test_x"), Outcome.FAIL, detail, ""
            )
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_x.mojo",
            Outcome.FAIL,
            0.1,
            _argv("tests/test_x.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            exit_status=1,
            parse_disposition=ParseDisposition.PARSED,
            failed_tests=1,
        )
    )
    var out = c.output()
    # (a) Common indentation stripped: the first detail line stands at column 0,
    # and the relative indent under it is preserved (uniform strip, not a crush).
    assert_true("\nUnhandled exception\n" in out)
    assert_true("\n  extra" in out)
    # (b) The `At` line is root-relative; the baked absolute path is gone.
    assert_true("At tests/test_x.mojo:12:5: AssertionError: nope" in out)
    assert_false("/run/root/tests/test_x.mojo" in out)
    # Nothing ELSE is rewritten: the message text is byte-verbatim.
    assert_true("AssertionError: nope" in out)


def test_at_line_root_strip_is_anchored_not_a_blanket_replace() raises:
    # A SECOND occurrence of the run root — inside the assertion message, on
    # the SAME line as the backtrace pointer — must survive verbatim. Only the
    # ONE root prefix immediately after `At ` is stripped; this is not a
    # blanket `.replace(root + "/", "")` over the whole line.
    var c = _console()
    c.handle(Event.session_started("/run/root", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_x.mojo"))
    var detail = (
        "        At /run/root/tests/x.mojo:12:5: AssertionError: expected"
        " /run/root/golden.txt, got /tmp/actual.txt"
    )
    c.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_x.mojo", "test_x"), Outcome.FAIL, detail, ""
            )
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_x.mojo",
            Outcome.FAIL,
            0.1,
            _argv("tests/test_x.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            exit_status=1,
            parse_disposition=ParseDisposition.PARSED,
            failed_tests=1,
        )
    )
    var out = c.output()
    # The backtrace pointer itself is made root-relative.
    assert_true("At tests/x.mojo:12:5:" in out)
    # But the SECOND occurrence — inside the assertion message — is preserved
    # verbatim, root prefix and all.
    assert_true("/run/root/golden.txt" in out)


def test_captured_output_shown_once_per_file_with_scope_label() raises:
    # Two failing tests in ONE file: the captured output is framed ONCE, under a
    # label that says it is file-scoped and TestSuite does not attribute it per
    # test.
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_two.mojo"))
    c.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_two.mojo", "test_a"), Outcome.FAIL, "a", ""
            )
        )
    )
    c.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_two.mojo", "test_b"), Outcome.FAIL, "b", ""
            )
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_two.mojo",
            Outcome.FAIL,
            0.2,
            _argv("tests/test_two.mojo"),
            1.0,
            _bytes("shared stdout\n"),
            _bytes("shared stderr\n"),
            exit_status=1,
            parse_disposition=ParseDisposition.PARSED,
            failed_tests=2,
        )
    )
    var out = c.output()
    # Two per-test sections, ONE file-scoped capture block.
    assert_true("--- FAIL tests/test_two.mojo::test_a ---" in out)
    assert_true("--- FAIL tests/test_two.mojo::test_b ---" in out)
    assert_true("does not attribute output to individual tests" in out)
    assert_equal(_count(out, "file-scoped"), 1)
    # The captured bytes still ride verbatim, once.
    assert_equal(_count(out, "shared stdout"), 1)
    assert_equal(_count(out, "shared stderr"), 1)


def test_captured_output_is_verbatim() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    assert_true("the suite report, verbatim" in out)
    assert_true("on stderr" in out)


def test_compile_error_shows_compiler_stderr_verbatim() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    assert_true(
        "test_typo.mojo:3:5: error: use of unknown declaration 'foo'" in out
    )


def test_truncation_marker_passes_through() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(
        Event.file_finished(
            "tests/test_loud.mojo",
            Outcome.FAIL,
            0.1,
            _argv("tests/test_loud.mojo"),
            1.0,
            _bytes("first line\n[... output truncated at 4096 bytes ...]\n"),
            List[UInt8](),
            exit_status=1,
        )
    )
    var out = c.output()
    assert_true("[... output truncated at 4096 bytes ...]" in out)


def test_reproduce_line_present_for_run_failure() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    assert_true("reproduce: mtest tests/test_beta.mojo" in out)


def test_reproduce_line_includes_build_flags_shell_quoted() raises:
    var c = _console(mtest_build_flags="--mojo /opt/mojo -I lib")
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(
        Event.file_finished(
            "tests/path with space.mojo",
            Outcome.FAIL,
            0.1,
            _argv("tests/path with space.mojo"),
            1.0,
            _bytes("boom\n"),
            List[UInt8](),
            exit_status=1,
        )
    )
    var out = c.output()
    # Build-affecting flags are carried, and the space-bearing path is quoted.
    assert_true(
        "reproduce: mtest --mojo /opt/mojo -I lib 'tests/path with space.mojo'"
        in out
    )


def test_per_test_repro_quotes_a_space_bearing_node_id() raises:
    # A per-test repro shell-quotes the WHOLE node id, so a space-bearing path
    # survives copy-paste as one argument.
    var c = _console(mtest_build_flags="-I lib")
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/path with space.mojo"))
    c.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/path with space.mojo", "test_boom"),
                Outcome.FAIL,
                "boom",
                "",
            )
        )
    )
    c.handle(
        Event.file_finished(
            "tests/path with space.mojo",
            Outcome.FAIL,
            0.1,
            _argv("tests/path with space.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            exit_status=1,
            parse_disposition=ParseDisposition.PARSED,
            failed_tests=1,
        )
    )
    var out = c.output()
    assert_true(
        "reproduce: mtest -I lib 'tests/path with space.mojo::test_boom'" in out
    )


def test_compile_error_reproduce_is_the_build_command() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    assert_true("reproduce: mojo build tests/test_typo.mojo" in out)


def test_no_tests_file_reads_no_tests_never_passed() raises:
    # A VALID file that ran zero tests is NO-TESTS, not PASS — exit-0 class but it
    # must never read as "passed".
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_zero.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_zero.mojo",
            Outcome.PASS,
            0.1,
            _argv("tests/test_zero.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=0,
            failed_tests=0,
            skipped_tests=0,
        )
    )
    var out = c.output()
    assert_true("NO-TESTS" in out)
    assert_true("tests/test_zero.mojo" in out)
    # The verdict token is never PASS for a zero-test file.
    assert_false("PASS" in out)


def test_malformed_suite_renders_token_and_diagnostic() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_silent.mojo"))
    c.handle(
        Event.warning(
            "malformed-suite",
            (
                "the --skip-all probe did not read as a collection listing"
                " (no report)"
            ),
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_silent.mojo",
            Outcome.MALFORMED_SUITE,
            0.1,
            _argv("tests/test_silent.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.NO_REPORT,
        )
    )
    var out = c.output()
    assert_true("MALFORMED-SUITE" in out)
    # The console composes a helpful diagnostic naming the failure mode.
    assert_true("no conforming report" in out)


def test_drift_renders_loud_banner_naming_pin_and_snapshots() raises:
    var c = _console()
    c.handle(Event.session_started("/root", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_liar.mojo"))
    c.handle(
        Event.warning(
            "drift",
            (
                "the --skip-all probe drifted off the pinned grammar (extra"
                " column); check the toolchain pin and"
                " tests/snapshots/protocol/"
            ),
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_liar.mojo",
            Outcome.NOT_RUN,
            0.1,
            _argv("tests/test_liar.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.DRIFT,
        )
    )
    var out = c.output()
    assert_true("DRIFT" in out)
    # Names the pinned toolchain, protocol snapshots, and the offending line.
    assert_true("mojo 1.0.0b2" in out)
    assert_true("tests/snapshots/protocol/" in out)
    assert_true("extra column" in out)


def test_capture_overflow_names_its_cause_distinct_from_fail() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_overflow.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_overflow.mojo",
            Outcome.FAIL,
            0.1,
            _argv("tests/test_overflow.mojo"),
            1.0,
            _bytes("flood\n"),
            List[UInt8](),
            exit_status=1,
            parse_disposition=ParseDisposition.CAPTURE_OVERFLOW,
        )
    )
    var out = c.output()
    assert_true("FAIL" in out)
    # A line names the overflow cause, distinct from a plain assertion failure.
    assert_true("capture-overflow" in out)


def test_summary_band_counts_tests_and_files_separately() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    # pass/fail/skip are per-TEST; the file-level abnormals are separate counts.
    assert_true("1 passed, 1 failed, 0 skipped" in out)
    assert_true("1 crashed" in out)
    assert_true("1 timed out" in out)
    assert_true("1 compile error" in out)
    # Excluded and not-run ride the SAME band as SEPARATE counts.
    assert_true("(1 excluded, 2 not run)" in out)
    assert_true("in 302.4s" in out)


def test_summary_band_omits_zero_file_abnormals() raises:
    # A clean run has no crash/timeout/compile-error files: those counts are
    # dropped, while the per-test pass/fail/skip counts always show.
    var c = _console()
    var s = Summary.zeros()
    s.counts[Outcome.PASS.code] = 2
    c.handle(
        Event.session_finished(
            s^,
            1.0,
            0,
            test_counts=TestCounts(passed=5, failed=0, skipped=1, deselected=0),
        )
    )
    var out = c.output()
    assert_true("5 passed, 0 failed, 1 skipped" in out)
    assert_false("crashed" in out)
    assert_false("timed out" in out)
    assert_false("compile error" in out)


def test_deselected_shows_in_band_only_when_nonzero() raises:
    # No deselection: the band stays the plain (excluded, not run) shape.
    var plain = _console()
    plain.handle(
        Event.session_finished(
            _mock_summary(), 302.4, 1, test_counts=_mock_test_counts()
        )
    )
    assert_false("deselected" in plain.output())

    # With deselections, the band names them as a separate count.
    var c = _console()
    c.handle(
        Event.session_finished(
            _mock_summary(),
            302.4,
            0,
            test_counts=TestCounts(passed=2, failed=0, skipped=0, deselected=3),
        )
    )
    var out = c.output()
    assert_true("(1 excluded, 2 not run, 3 deselected)" in out)


def test_color_off_emits_no_escape_codes_but_keeps_tokens() raises:
    var c = _console(color=ColorWhen.NEVER)
    _feed_mock_run(c)
    var out = c.output()
    assert_false("\x1b" in out)
    # Color is never the sole carrier: the tokens still convey the meaning.
    assert_true("FAIL" in out)
    assert_true("CRASH" in out)


def test_no_tests_and_drift_tokens_survive_color_off() raises:
    # The distinctive tokens carry meaning without color.
    var c = _console(color=ColorWhen.NEVER)
    c.handle(Event.session_started("/root", "mojo 1.0.0b2", 2, 0))
    c.handle(Event.file_started("tests/test_zero.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_zero.mojo",
            Outcome.PASS,
            0.1,
            _argv("tests/test_zero.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
        )
    )
    c.handle(Event.file_started("tests/test_liar.mojo"))
    c.handle(Event.warning("drift", "off grammar; tests/snapshots/protocol/"))
    c.handle(
        Event.file_finished(
            "tests/test_liar.mojo",
            Outcome.NOT_RUN,
            0.1,
            _argv("tests/test_liar.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.DRIFT,
        )
    )
    var out = c.output()
    assert_false("\x1b" in out)
    assert_true("NO-TESTS" in out)
    assert_true("DRIFT" in out)


def test_auto_color_off_when_not_tty() raises:
    var c = _console(color=ColorWhen.AUTO, is_tty=False, no_color=False)
    _feed_mock_run(c)
    assert_false("\x1b" in c.output())


def test_auto_color_off_under_no_color_even_on_tty() raises:
    var c = _console(color=ColorWhen.AUTO, is_tty=True, no_color=True)
    _feed_mock_run(c)
    assert_false("\x1b" in c.output())


def test_color_always_emits_escape_codes() raises:
    var c = _console(color=ColorWhen.ALWAYS)
    _feed_mock_run(c)
    var out = c.output()
    assert_true("\x1b[" in out)
    # A red summary band (worst outcome is crash-class).
    assert_true("\x1b[1;31m" in out)


def test_quiet_suppresses_header_and_pass_lines() raises:
    var c = _console(verbosity=Verbosity.QUIET)
    _feed_mock_run(c)
    var out = c.output()
    assert_false("mtest 0.1.0-dev" in out)
    assert_false("PASS      tests/test_alpha.mojo" in out)
    # Non-pass verdicts and the summary still appear.
    assert_true("FAIL" in out)
    assert_true("1 passed, 1 failed" in out)


def test_verbose_adds_build_command_and_timings() raises:
    var c = _console(verbosity=Verbosity.VERBOSE)
    _feed_mock_run(c)
    var out = c.output()
    assert_true("build: mojo build tests/test_alpha.mojo" in out)


def test_verbose_shows_per_test_rows() raises:
    var c = _console(verbosity=Verbosity.VERBOSE)
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_mix.mojo"))
    c.handle(
        Event.test_reported(
            TestResult(NodeId("tests/test_mix.mojo", "test_p"), Outcome.PASS)
        )
    )
    c.handle(
        Event.test_reported(
            TestResult(NodeId("tests/test_mix.mojo", "test_s"), Outcome.SKIP)
        )
    )
    c.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_mix.mojo", "test_f"),
                Outcome.FAIL,
                "boom",
                "",
            )
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_mix.mojo",
            Outcome.FAIL,
            0.2,
            _argv("tests/test_mix.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            exit_status=1,
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
            failed_tests=1,
            skipped_tests=1,
        )
    )
    var out = c.output()
    # One row per test, each naming its node id and its outcome token.
    assert_true("tests/test_mix.mojo::test_p" in out)
    assert_true("tests/test_mix.mojo::test_s" in out)
    assert_true("tests/test_mix.mojo::test_f" in out)
    assert_true("SKIP" in out)


def test_show_output_none_suppresses_sections() raises:
    var c = _console(show_output=ShowOutput.NONE)
    _feed_mock_run(c)
    var out = c.output()
    assert_false("--- FAIL" in out)
    # Verdict lines and summary still render.
    assert_true("FAIL" in out)
    assert_true("tests/test_beta.mojo" in out)
    assert_true("1 passed, 1 failed" in out)


def test_show_output_all_frames_passing_files_too() raises:
    var c = _console(show_output=ShowOutput.ALL)
    _feed_mock_run(c)
    var out = c.output()
    assert_true("--- PASS tests/test_alpha.mojo" in out)


def test_warning_renders_loud() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.warning("stale-exclusion", "old_*"))
    var out = c.output()
    assert_true("WARNING" in out)
    # The console composes the sentence from the kind and the pattern datum.
    assert_true("exclude pattern 'old_*' matched nothing" in out)


def test_precompile_failed_banner_verbatim() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 3, 0))
    c.handle(
        Event.precompile_failed(
            "precompile src/mtest",
            "error: undefined symbol 'bar'\n",
            3,
        )
    )
    var out = c.output()
    assert_true("PRECOMPILE-FAILED" in out)
    assert_true("precompile src/mtest" in out)
    assert_true("error: undefined symbol 'bar'" in out)
    assert_true("3 file(s) could not run" in out)


def test_internal_error_banner_names_step_program_and_errno() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.internal_error("build", "/no/such/mojo", 2))
    var out = c.output()
    assert_true("INTERNAL-ERROR" in out)
    assert_true("build:" in out)
    assert_true("/no/such/mojo" in out)
    assert_true("errno 2" in out)
    # A recognized errno is named in words alongside the number.
    assert_true("no such file or directory" in out)


def test_internal_error_banner_omits_errno_for_machinery_failure() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.internal_error("precompile", "/usr/bin/mojo", 0))
    var out = c.output()
    assert_true("INTERNAL-ERROR" in out)
    assert_true("precompile:" in out)
    assert_true("/usr/bin/mojo" in out)
    # errno 0 is a machinery failure: no errno suffix.
    assert_false("errno" in out)


def test_collection_known_renders_nothing() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 5, 1))
    var before = c.output()
    c.handle(
        Event.collection_known(selected_test_total=5, deselected_test_total=1)
    )
    var after = c.output()
    # Same precedent as before: the collection line arrives later, not here.
    assert_equal(after, before)


def test_internal_error_banner_falls_back_to_bare_errno() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.internal_error("run", "build/bin/x", 99))
    var out = c.output()
    assert_true("errno 99" in out)
    # An unrecognized errno carries no worded name and no dangling separator.
    assert_false("—" in out)


def test_durations_zero_renders_no_slowest_files_list() raises:
    # `durations=0` is the flag-absent default: the report is presence-only.
    var c = _console(durations=0)
    _feed_mock_run(c)
    var out = c.output()
    assert_false("slowest" in out)


def test_durations_header_states_count_descending_order_and_excludes_zero_duration() raises:
    # Three files ran with distinct durations; one COMPILE_ERROR file never
    # reached the run step and carries 0.0 — it must never appear in the
    # slowest list even though `durations=3` would otherwise have room.
    # QUIET verbosity so a PASS file contributes no head verdict line, making
    # each PASS path's ONLY occurrence in `out` the slowest-list row — this
    # also doubles as the "-q survival" proof.
    var c = _console(durations=3, verbosity=Verbosity.QUIET)
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 4, 0))
    c.handle(Event.file_started("tests/test_a.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_a.mojo",
            Outcome.PASS,
            0.30,
            _argv("tests/test_a.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
        )
    )
    c.handle(Event.file_started("tests/test_b.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_b.mojo",
            Outcome.PASS,
            0.10,
            _argv("tests/test_b.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
        )
    )
    c.handle(Event.file_started("tests/test_c.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_c.mojo",
            Outcome.PASS,
            0.50,
            _argv("tests/test_c.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
        )
    )
    c.handle(Event.file_started("tests/test_typo.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_typo.mojo",
            Outcome.COMPILE_ERROR,
            0.0,
            _argv("tests/test_typo.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
        )
    )
    c.handle(
        Event.session_finished(
            Summary.zeros(), 1.0, 1, test_counts=TestCounts.zeros()
        )
    )
    var out = c.output()
    # Header states the ACTUAL count shown, and says "files" (no per-test
    # timing implied).
    assert_true("slowest 3 files:" in out)
    # Descending order: 0.50 (c) > 0.30 (a) > 0.10 (b).
    var i_c = out.find("tests/test_c.mojo")
    var i_a = out.find("tests/test_a.mojo")
    var i_b = out.find("tests/test_b.mojo")
    assert_true(i_c >= 0)
    assert_true(i_a >= 0)
    assert_true(i_b >= 0)
    assert_true(i_c < i_a)
    assert_true(i_a < i_b)
    # Exactly 3 slowest-list rows: the zero-duration COMPILE_ERROR file never
    # reached the run step and is excluded, even though it did produce a
    # verdict line (QUIET only suppresses PASS lines).
    assert_equal(_count(out, "\n  tests/test_"), 3)
    assert_true("COMPILE-ERROR" in out)
    assert_true("tests/test_typo.mojo" in out)


def test_durations_row_count_is_capped_by_files_run_not_requested_n() raises:
    # `durations=10` but only 2 files ran: the header states 2 (the min), not
    # the requested 10, and exactly 2 rows render.
    var c = _console(durations=10)
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 2, 0))
    c.handle(Event.file_started("tests/test_a.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_a.mojo",
            Outcome.PASS,
            0.30,
            _argv("tests/test_a.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
        )
    )
    c.handle(Event.file_started("tests/test_b.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_b.mojo",
            Outcome.PASS,
            0.10,
            _argv("tests/test_b.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
        )
    )
    c.handle(
        Event.session_finished(
            Summary.zeros(), 1.0, 0, test_counts=TestCounts.zeros()
        )
    )
    var out = c.output()
    assert_true("slowest 2 files:" in out)
    assert_false("slowest 10 files:" in out)
    assert_equal(_count(out, "\n  tests/test_"), 2)


def test_durations_ties_break_by_path_ascending() raises:
    # Two files with the SAME duration, fed in reverse-alphabetical order:
    # the ascending-path tiebreak must still put "a" before "z".
    var c = _console(durations=2, verbosity=Verbosity.QUIET)
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 2, 0))
    c.handle(Event.file_started("tests/test_z.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_z.mojo",
            Outcome.PASS,
            0.20,
            _argv("tests/test_z.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
        )
    )
    c.handle(Event.file_started("tests/test_a.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_a.mojo",
            Outcome.PASS,
            0.20,
            _argv("tests/test_a.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
        )
    )
    c.handle(
        Event.session_finished(
            Summary.zeros(), 1.0, 0, test_counts=TestCounts.zeros()
        )
    )
    var out = c.output()
    var i_a = out.find("tests/test_a.mojo")
    var i_z = out.find("tests/test_z.mojo")
    assert_true(i_a >= 0)
    assert_true(i_z >= 0)
    assert_true(i_a < i_z)


def test_durations_zero_files_run_renders_nothing() raises:
    # `durations > 0` but every FileFinished carries 0.0 (nothing ran):
    # presence-only means no slowest-files section at all.
    var c = _console(durations=5)
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 1))
    c.handle(
        Event.file_finished(
            "tests/test_x.mojo",
            Outcome.EXCLUDED,
            0.0,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
            exclusion_pattern="--exclude tests/*",
        )
    )
    c.handle(
        Event.session_finished(
            Summary.zeros(), 1.0, 0, test_counts=TestCounts.zeros()
        )
    )
    var out = c.output()
    assert_false("slowest" in out)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
