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
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.config import ColorWhen, Verbosity, ShowOutput
from mtest.model import (
    AttributionDisposition,
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
from mtest.report.console import _precompile_ending_phrase, _term_phrase


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
        "0.6.0",
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
    assert_true("mtest 0.6.0 (mojo 1.0.0b2)" in out)
    assert_true("root: tests" in out)
    assert_true("selected: 5 files" in out)
    assert_true("excluded: 1" in out)


def test_session_started_header_byte_identical_at_single_worker() raises:
    # The worker-count token is dormant on a sequential run: a resolved count of
    # one renders no `workers:` token and leaves the header byte-for-byte what it
    # was before the field existed. Only a count above one surfaces the token.
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 5, 1, workers=1))
    var out = c.output()
    assert_false("workers:" in out)
    assert_true(
        "root: tests   selected: 5 files   excluded: 1\n\n" in out,
        "the single-worker header carries no worker token",
    )


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

    var platform = _console()
    platform.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    platform.handle(Event.file_started("tests/test_platform_signal.mojo"))
    platform.handle(
        Event.file_finished(
            "tests/test_platform_signal.mojo",
            Outcome.CRASH,
            0.1,
            _argv("tests/test_platform_signal.mojo"),
            0.1,
            List[UInt8](),
            List[UInt8](),
            signal_number=7,
        )
    )
    comptime if CompilationTarget.is_macos():
        assert_true("signal 7 — SIGEMT, emulation trap" in platform.output())
    else:
        assert_true("signal 7 — SIGBUS, bus error" in platform.output())


def test_timeout_notes_the_deadline() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    assert_true("timed out after 300s" in out)


def _feed_timeout(mut c: ConsoleReporter, escalated: Bool):
    """One TIMEOUT FileFinished whose run did (or did not) need a SIGKILL."""
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_hangs.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_hangs.mojo",
            Outcome.TIMEOUT,
            1.31,
            _argv("tests/test_hangs.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            timeout_seconds=1,
            escalated=escalated,
        )
    )


def test_timeout_verdict_reports_the_sigkill_escalation() raises:
    # The COMMON case is `--timeout N` with NO retries: there is no TRY line, so
    # the verdict line is the only place the escalation can be told. A child that
    # ignored SIGTERM and had to be SIGKILLed is a materially different story
    # from one that stopped politely, and the reader is owed it.
    var c = _console()
    _feed_timeout(c, escalated=True)
    var out = c.output()
    assert_true("timed out after 1s" in out)
    assert_true("escalated to SIGKILL" in out)


def test_timeout_verdict_claims_no_escalation_that_never_happened() raises:
    # The mirror image: a child that went down on the polite SIGTERM must NOT be
    # narrated as having been SIGKILLed.
    var c = _console()
    _feed_timeout(c, escalated=False)
    var out = c.output()
    assert_true("timed out after 1s" in out)
    assert_false("escalated" in out)
    assert_false("SIGKILL" in out)


def _feed_slow(
    mut c: ConsoleReporter,
    outcome: Outcome,
    slow: Bool,
    duration_seconds: Float64,
    build_duration_seconds: Float64,
):
    """One terminal FileFinished with the given outcome/slow/durations."""
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_crawl.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_crawl.mojo",
            outcome,
            duration_seconds,
            _argv("tests/test_crawl.mojo"),
            build_duration_seconds,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1 if outcome == Outcome.PASS else 0,
            failed_tests=1 if outcome == Outcome.FAIL else 0,
            slow=slow,
        )
    )


def test_slow_file_carries_the_slow_token_on_the_verdict_line() raises:
    var c = _console()
    _feed_slow(c, Outcome.PASS, True, 61.0, 1.0)
    var out = c.output()
    assert_true("SLOW" in out)


def test_slow_file_still_reports_its_real_verdict() raises:
    # SLOW rides alongside the verdict; it never replaces or perturbs it. A
    # slow FAIL is still reported FAIL, with its real duration.
    var c = _console()
    _feed_slow(c, Outcome.FAIL, True, 61.0, 1.0)
    var out = c.output()
    assert_true("FAIL" in out)
    assert_true("SLOW" in out)
    assert_true("61.00s" in out)


def test_non_slow_file_has_no_slow_token() raises:
    # The honesty property: `slow=False` must never render SLOW, even for a
    # file whose duration happens to be printed elsewhere on the line.
    var c = _console()
    _feed_slow(c, Outcome.PASS, False, 1.5, 1.0)
    var out = c.output()
    assert_false("SLOW" in out)


def _feed_serial(mut c: ConsoleReporter, outcome: Outcome, serial: Bool):
    """One terminal FileFinished carrying the given outcome and serial flag."""
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_crawl.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_crawl.mojo",
            outcome,
            1.0,
            _argv("tests/test_crawl.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1 if outcome == Outcome.PASS else 0,
            failed_tests=1 if outcome == Outcome.FAIL else 0,
            serial=serial,
        )
    )


def test_serial_file_carries_the_serial_token_on_the_verdict_line() raises:
    var c = _console()
    _feed_serial(c, Outcome.PASS, True)
    var out = c.output()
    assert_true("SERIAL" in out)


def test_serial_file_still_reports_its_real_verdict() raises:
    # SERIAL rides alongside the verdict; it never replaces or perturbs it. A
    # serial FAIL is still reported FAIL.
    var c = _console()
    _feed_serial(c, Outcome.FAIL, True)
    var out = c.output()
    assert_true("FAIL" in out)
    assert_true("SERIAL" in out)


def test_non_serial_file_has_no_serial_token() raises:
    # The honesty property: `serial=False` (a worker-run verdict) must never
    # render SERIAL.
    var c = _console()
    _feed_serial(c, Outcome.PASS, False)
    var out = c.output()
    assert_false("SERIAL" in out)


def test_verbose_slow_build_names_the_build_step() raises:
    var c = _console(verbosity=Verbosity.VERBOSE)
    _feed_slow(c, Outcome.PASS, True, 1.2, 65.0)
    var out = c.output()
    assert_true("SLOW" in out)
    assert_true("build" in out)
    assert_true("65.00s" in out)


def test_verbose_slow_run_names_the_run_step() raises:
    var c = _console(verbosity=Verbosity.VERBOSE)
    _feed_slow(c, Outcome.PASS, True, 90.0, 1.0)
    var out = c.output()
    assert_true("SLOW" in out)
    assert_true("run" in out)
    assert_true("90.00s" in out)


def test_verbose_non_slow_file_has_no_slow_step_note() raises:
    var c = _console(verbosity=Verbosity.VERBOSE)
    _feed_slow(c, Outcome.PASS, False, 1.2, 1.0)
    var out = c.output()
    assert_false("SLOW" in out)
    assert_false("slow:" in out)


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
    # (a) Common indentation stripped: the first detail line stands at the
    # gutter, and the relative indent under it is preserved (uniform strip, not
    # a crush). (b) The `At` line is root-relative; the baked absolute path is
    # gone. Asserted as one exact block so neither transformation can be lost
    # while the other still satisfies a substring probe. The `    | ` gutter is
    # the display fence every untrusted block now rides behind; the detail text
    # inside it is byte-verbatim.
    assert_true(
        "    | Unhandled exception\n"
        "    | At tests/test_x.mojo:12:5: AssertionError: nope\n"
        "    |   extra\n"
        in out
    )
    assert_false("/run/root/tests/test_x.mojo" in out)


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


# --- COMPILE-TIMEOUT: the banner is rendered from the typed event fields only ---


def _feed_compile_timeout(
    mut c: ConsoleReporter,
    attempts_used: Int = 1,
    stderr_text: String = "mojo: warning: still lowering module\n",
    path: String = "tests/test_slow.mojo",
):
    """One COMPILE_TIMEOUT FileFinished for the fixed slow-build fixture."""
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started(path))
    c.handle(
        Event.file_finished(
            path,
            Outcome.COMPILE_TIMEOUT,
            0.0,
            _argv(path),
            1.0,
            List[UInt8](),
            _bytes(stderr_text),
            timeout_seconds=1,
            attempts_used=attempts_used,
        )
    )


def test_compile_timeout_verdict_token_and_deadline() raises:
    var c = _console()
    _feed_compile_timeout(c)
    var out = c.output()
    # The verdict line carries the token and names the deadline that fired.
    assert_true("COMPILE-TIMEOUT" in out)
    assert_true("tests/test_slow.mojo" in out)
    assert_true("timed out after 1s" in out)


def test_compile_timeout_banner_shows_compiler_stderr_verbatim() raises:
    # Exact, not a substring probe: the compiler's words ride through byte-for
    # byte, behind the display gutter and nothing else. A substring check here
    # would pass just as happily if the line lost its fence or gained a rewrite.
    var c = _console()
    _feed_compile_timeout(c, stderr_text="mojo: note: lowering @foo\n")
    var out = c.output()
    assert_true("\n    | mojo: note: lowering @foo\n" in out)


def test_compile_timeout_banner_carries_the_split_or_exclude_hint() raises:
    var c = _console()
    _feed_compile_timeout(c)
    var out = c.output()
    assert_true("exceeded the 1s compile timeout" in out)
    assert_true("split" in out)
    assert_true("exclude" in out)


def test_compile_timeout_reproduce_names_the_deadline() raises:
    var c = _console()
    _feed_compile_timeout(c)
    var out = c.output()
    assert_true(
        "reproduce: mtest --compile-timeout 1 tests/test_slow.mojo" in out
    )


def test_compile_timeout_reproduce_keeps_the_build_flags() raises:
    var c = _console(mtest_build_flags="--mojo /opt/mojo -I lib")
    _feed_compile_timeout(c)
    var out = c.output()
    assert_true(
        "reproduce: mtest --mojo /opt/mojo -I lib --compile-timeout 1"
        " tests/test_slow.mojo"
        in out
    )


def test_compile_timeout_promises_no_quarantine_when_no_retry_ran() raises:
    # At `--retries 0` exactly ONE attempt was scheduled: the banner must not
    # claim a quarantined rebuild that never happened.
    var c = _console()
    _feed_compile_timeout(c, attempts_used=1)
    var out = c.output()
    assert_false("quarantin" in out)
    assert_false("retried" in out)


# --- stop-commands FENCING of echoed captured child output (Actions only) ---

comptime _FORGED: StaticString = "::error file=evil.mojo::forged by the child"


def _fence_opener_token(rendered: String) raises -> String:
    """The token from the FIRST `::stop-commands::<token>` opener in `rendered`.
    """
    var marker = "::stop-commands::"
    assert_true(marker in rendered, "no stop-commands opener in fenced output")
    var after = String(rendered.split(marker, 1)[1])
    return String(after.split("\n", 1)[0])


def _gh_console(gh_actions: Bool) -> ConsoleReporter:
    """A console reporter under `show-output all`, optionally under Actions."""
    return ConsoleReporter(
        "0.6.0",
        ColorWhen.NEVER,
        is_tty=False,
        no_color=False,
        verbosity=Verbosity.NORMAL,
        show_output=ShowOutput.ALL,
        mtest_build_flags="",
        durations=0,
        gh_actions=gh_actions,
    )


def _feed_forged_capture(mut c: ConsoleReporter):
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_hostile.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_hostile.mojo",
            Outcome.FAIL,
            0.1,
            _argv("tests/test_hostile.mojo"),
            1.0,
            _bytes(String(_FORGED) + "\n"),
            List[UInt8](),
            exit_status=1,
            parse_disposition=ParseDisposition.PARSED,
        )
    )


def test_captured_output_is_not_fenced_without_actions() raises:
    var c = _gh_console(gh_actions=False)
    _feed_forged_capture(c)
    var out = c.output()
    # The forged bytes echo verbatim, and NO stop-commands fence is emitted.
    assert_true(String(_FORGED) in out)
    assert_false("::stop-commands::" in out)


def test_captured_output_is_fenced_under_actions() raises:
    var c = _gh_console(gh_actions=True)
    _feed_forged_capture(c)
    var out = c.output()
    # The forged region is wrapped: an opener with a high-entropy token, the
    # forged bytes inside, and a MATCHING resume delimiter that terminates it.
    assert_true("::stop-commands::" in out)
    var token = _fence_opener_token(out)
    assert_equal(token.byte_length(), 32, "fence token is not 128-bit hex")
    assert_true(String(_FORGED) in out, "the forged bytes were not echoed")
    assert_true(
        ("::" + token + "::") in out, "the fence has no matching resume"
    )
    # The opener precedes the forged bytes, and the resume follows them: the
    # forged command is sealed inside the fence.
    var opener = "::stop-commands::" + token
    assert_true(out.find(opener) < out.find(String(_FORGED)))
    assert_true(out.find(String(_FORGED)) < out.rfind("::" + token + "::"))


def test_fence_token_getter_matches_the_opener() raises:
    var c = _gh_console(gh_actions=True)
    _feed_forged_capture(c)
    var out = c.output()
    var primary = c.fence_token()
    assert_equal(primary.byte_length(), 32)
    # The primary token is the one the (single, uncolliding) region fenced with,
    # and is what `main`'s always-runs epilogue restores with.
    assert_true(("::stop-commands::" + primary) in out)


def test_fence_token_empty_before_any_fenced_region() raises:
    var c = _gh_console(gh_actions=True)
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    # No captured-output region rendered yet: nothing to restore.
    assert_equal(c.fence_token(), "")


def test_compile_timeout_names_the_quarantine_when_a_retry_ran() raises:
    # attempts_used > 1: a quarantined rebuild really did run. A retried build
    # failure is always quarantined (a run-crash retry does not rebuild), so the
    # rebuild itself is the one thing the count DOES license the banner to say.
    var c = _console()
    _feed_compile_timeout(c, attempts_used=2)
    var out = c.output()
    assert_true("quarantined" in out)
    assert_true("2 attempts" in out)


def test_compile_timeout_never_claims_every_attempt_hit_the_deadline() raises:
    # `attempts_used` counts attempts; it does NOT record how each one ENDED.
    # A first attempt killed by a compiler ICE (crash-class -> quarantined
    # rebuild) followed by a second that blew the deadline is ALSO
    # `attempts_used == 2` with a COMPILE-TIMEOUT verdict — so a banner that
    # says the deadline fired every time would be asserting what no typed field
    # supports. It may say how many attempts ran, and no more.
    var c = _console()
    _feed_compile_timeout(c, attempts_used=2)
    var out = c.output()
    assert_false("every time" in out)
    assert_false("every attempt" in out)
    assert_true("2 attempts" in out)


def test_compile_timeout_banner_is_not_the_compile_error_banner() raises:
    # A build WE killed must never be framed as the compiler rejecting the code.
    var c = _console()
    _feed_compile_timeout(c)
    var out = c.output()
    assert_false("COMPILE-ERROR" in out)
    assert_false("mojo build said" in out)


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
    assert_false("mtest 0.6.0" in out)
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


def _attribution(
    disposition: AttributionDisposition,
    culprit: String = "",
    reruns: Int = 0,
    seconds: Float64 = 0.0,
) -> String:
    """The rendered buffer for ONE crash-attribution event on a crashed file.

    The FileFinished rides first so every assertion below reads the attribution
    line in the place a real run puts it: after the file's CRASH verdict, which
    the attribution never touches.
    """
    try:
        var c = _console()
        c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
        c.handle(Event.file_started("tests/test_boom.mojo"))
        c.handle(
            Event.file_finished(
                "tests/test_boom.mojo",
                Outcome.CRASH,
                0.3,
                _argv("tests/test_boom.mojo"),
                1.0,
                List[UInt8](),
                List[UInt8](),
                signal_number=11,
            )
        )
        c.handle(
            Event.crash_attribution(
                "tests/test_boom.mojo", disposition, culprit, reruns, seconds
            )
        )
        return c.output()
    except:
        return String("")


def test_attribution_attributed_names_the_culprit_reruns_and_elapsed() raises:
    var out = _attribution(
        AttributionDisposition.ATTRIBUTED, "test_segfaults", 4, 2.5
    )
    assert_true("ATTRIBUTION" in out)
    assert_true("tests/test_boom.mojo" in out)
    assert_true("test_segfaults" in out)
    assert_true("4 isolation rerun" in out)
    assert_true("2.50s" in out)
    # The verdict it annotates is untouched and still rendered above it.
    assert_true("CRASH" in out)
    # An ATTRIBUTED line is the ONE disposition that is not an admission of
    # ignorance, so it must not claim the culprit is unknown.
    assert_false("UNATTRIBUTED" in out)


def test_attribution_no_reproduction_leaves_the_culprit_unattributed() raises:
    var out = _attribution(AttributionDisposition.NO_REPRODUCTION, "", 3, 1.25)
    assert_true("ATTRIBUTION" in out)
    assert_true("NO-REPRODUCTION" in out)
    assert_true("did not reproduce" in out)
    # Never a guess: the verdict stands and the culprit is named as unknown.
    assert_true("UNATTRIBUTED" in out)
    assert_true("CRASH verdict stands" in out)


def test_attribution_probe_failed_says_the_listing_was_unrecoverable() raises:
    var out = _attribution(AttributionDisposition.PROBE_FAILED, "", 0, 0.5)
    assert_true("PROBE-FAILED" in out)
    assert_true("test list" in out)
    assert_true("UNATTRIBUTED" in out)
    assert_true("CRASH verdict stands" in out)


def test_attribution_run_cap_says_the_cap_stopped_the_search() raises:
    var out = _attribution(AttributionDisposition.RUN_CAP, "", 32, 9.0)
    assert_true("RUN-CAP" in out)
    assert_true("32-run cap" in out)
    assert_true("UNATTRIBUTED" in out)
    assert_true("CRASH verdict stands" in out)


def test_attribution_time_budget_says_the_clock_stopped_the_search() raises:
    var out = _attribution(AttributionDisposition.TIME_BUDGET, "", 7, 120.0)
    assert_true("TIME-BUDGET" in out)
    assert_true("time budget" in out)
    assert_true("UNATTRIBUTED" in out)
    assert_true("CRASH verdict stands" in out)


def test_attribution_never_starts_a_line_with_an_existing_verdict_token() raises:
    # The attribution cluster shares the console with the verdict lines; a token
    # that PREFIXED an existing one (e.g. "CRASH-ATTRIBUTION") would make a
    # line-oriented reader mistake a diagnostic for a second CRASH verdict.
    var out = _attribution(
        AttributionDisposition.ATTRIBUTED, "test_segfaults", 2, 0.1
    )
    var crash_starts = 0
    for line in out.split("\n"):
        if String(line).startswith("CRASH"):
            crash_starts += 1
    assert_equal(crash_starts, 1)


def test_precompile_failed_banner_verbatim() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 3, 0))
    c.handle(
        Event.precompile_failed(
            "precompile src/mtest",
            "error: undefined symbol 'bar'\n",
            0,
            casualties=[
                String("tests/test_a.mojo"),
                String("tests/test_b.mojo"),
                String("tests/nested/test_c.mojo"),
            ],
        )
    )
    var out = c.output()
    # The banner uses the frozen outcome-vocabulary label, not an ad-hoc one.
    assert_true("PRECOMPILE-ERROR" in out)
    assert_true("precompile src/mtest" in out)
    assert_true("error: undefined symbol 'bar'" in out)
    assert_true("3 file(s) could not run" in out)
    # §8.3: every dependent test file is named as a casualty, not merely counted.
    assert_true("tests/test_a.mojo" in out)
    assert_true("tests/test_b.mojo" in out)
    assert_true("tests/nested/test_c.mojo" in out)


def test_term_phrase_names_a_signal_in_words_and_falls_back_to_the_number() raises:
    # The PURE phrase builder behind the TRY lines. The decomposed termination
    # kinds are the exec-layer discriminants: 0 EXITED, 1 SIGNALED, 2 TIMED_OUT,
    # 3 SPAWN_FAILED.
    assert_equal(
        _term_phrase(1, 11, False),
        "signal 11 — SIGSEGV, segmentation fault",
    )
    # A signal OUTSIDE the named set must still read as the bare number — never
    # an empty phrase and never a neighbour's name.
    assert_equal(_term_phrase(1, 31, False), "signal 31")
    assert_equal(_term_phrase(1, 62, False), "signal 62")


def test_term_phrase_notes_the_sigkill_escalation_of_a_deadline() raises:
    # A deadline the child survived until SIGKILL says so; a child that went
    # down on the polite SIGTERM must not claim an escalation that never ran.
    assert_equal(_term_phrase(2, 0, False), "timed out")
    assert_equal(_term_phrase(2, 0, True), "timed out, escalated to SIGKILL")


def test_crash_narrative_reads_a_segfault_with_no_stdout_and_no_abort() raises:
    # The OBSERVED segfault shape (tests/snapshots/protocol/): termination is
    # signal 11, stdout is EMPTY, there is NO `ABORT:` line anywhere, and stderr
    # carries only the runtime's stack dump. The narrative must be built from the
    # typed `signal_number` alone: it may never assume an ABORT line (that is the
    # SIGABRT fixture's shape) or that stdout said anything at all.
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_segfault.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_segfault.mojo",
            Outcome.CRASH,
            0.2,
            _argv("tests/test_segfault.mojo"),
            1.0,
            List[UInt8](),
            _bytes("<STACK-DUMP>\n"),
            signal_number=11,
        )
    )
    var out = c.output()
    assert_true("CRASH" in out)
    assert_true("signal 11 — SIGSEGV, segmentation fault" in out)
    # No ABORT line existed, so none may be printed or implied.
    assert_false("ABORT" in out)
    # The empty stdout is rendered as nothing, and the stderr rides verbatim.
    assert_true("--- captured stderr ---" in out)
    assert_true("<STACK-DUMP>" in out)


def test_precompile_ending_phrase_names_each_ending_in_words() raises:
    # The PURE phrase builder behind the banner's "how it ended" clause. The
    # decomposed termination kinds are the exec-layer discriminants: 0 EXITED,
    # 1 SIGNALED, 2 TIMED_OUT, 3 SPAWN_FAILED.
    assert_equal(
        _precompile_ending_phrase(2, 0, False, 600), "timed out after 600s"
    )
    assert_equal(
        _precompile_ending_phrase(2, 0, True, 600),
        "timed out after 600s, escalated to SIGKILL",
    )
    assert_equal(
        _precompile_ending_phrase(1, 11, False, 0),
        "died by signal 11 (SIGSEGV, segmentation fault)",
    )
    # A signal outside the named set still reads as words, minus the name.
    assert_equal(
        _precompile_ending_phrase(1, 62, False, 0), "died by signal 62"
    )
    assert_equal(_precompile_ending_phrase(0, 1, False, 0), "exited 1")
    assert_equal(
        _precompile_ending_phrase(3, 2, False, 0),
        "could not be spawned (errno 2)",
    )


def test_precompile_failed_banner_names_a_timeout_ending() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(
        Event.precompile_failed(
            "mathlib",
            "mojo: note: lowering @foo\n",
            0,
            casualties=[String("tests/test_a.mojo")],
            ending_known=True,
            term_kind=2,
            term_value=0,
            escalated=False,
            timeout_seconds=600,
            attempts_used=1,
        )
    )
    var out = c.output()
    assert_true("PRECOMPILE-ERROR" in out)
    # A step WE killed at the deadline names the deadline, in words.
    assert_true("timed out after 600s" in out)
    assert_true("1 file(s) could not run" in out)
    # The compiler's own output still rides verbatim, and the casualty is named.
    assert_true("mojo: note: lowering @foo" in out)
    assert_true("tests/test_a.mojo" in out)


def test_precompile_failed_banner_names_a_signal_ending() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(
        Event.precompile_failed(
            "mathlib",
            "Stack dump:\n",
            0,
            casualties=[String("tests/test_a.mojo")],
            ending_known=True,
            term_kind=1,
            term_value=11,
            attempts_used=2,
        )
    )
    var out = c.output()
    assert_true("died by signal 11 (SIGSEGV, segmentation fault)" in out)
    # A step that burned its retry budget says so.
    assert_true("2 attempts" in out)


def test_precompile_failed_banner_without_an_ending_is_unchanged() raises:
    # An event that carries no ending identity must not invent one (an unset
    # termination would otherwise read as the lie "exited 0").
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.precompile_failed("mathlib", "error: boom\n", 2))
    var out = c.output()
    assert_true("2 file(s) could not run" in out)
    assert_false("exited 0" in out)
    assert_false("timed out" in out)


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


def _progress(
    completed: Int, total: Int, paths: List[String], elapsed: List[Float64]
) -> Event:
    """A PROGRESS event with the given counts and index-aligned in-flight data.
    """
    return Event.progress(completed, total, paths.copy(), elapsed.copy())


def test_progress_on_tty_renders_a_single_counter_line() raises:
    # On a terminal the live counter names the completed/total and the in-flight
    # files by basename, on ONE physical line (no newline, within the width cap).
    var c = _console(is_tty=True)
    c.handle(
        _progress(
            3,
            8,
            ["tests/parallel/test_foo.mojo", "tests/parallel/test_bar.mojo"],
            [0.4, 0.2],
        )
    )
    var line = c.progress_line()
    assert_true(line.byte_length() > 0)
    assert_true("3/8" in line)
    assert_true("test_foo.mojo" in line)
    # A basename, never the full path — the counter must not carry the dir.
    assert_false("tests/parallel/test_foo.mojo" in line)
    # One physical line: no embedded newline and within the codepoint cap.
    assert_false("\n" in line)
    assert_true(line.count_codepoints() <= 72)


def test_progress_off_tty_is_empty() raises:
    # A piped destination is not a terminal: no counter byte is ever rendered.
    var c = _console(is_tty=False)
    c.handle(_progress(1, 4, ["tests/test_a.mojo"], [0.1]))
    assert_equal(c.progress_line(), String(""))


def test_progress_under_quiet_is_empty_even_on_tty() raises:
    # `-q` suppresses the counter outright, exactly as it suppresses the header.
    var c = _console(is_tty=True, verbosity=Verbosity.QUIET)
    c.handle(
        _progress(2, 5, ["tests/test_a.mojo", "tests/test_b.mojo"], [1.0, 0.5])
    )
    assert_equal(c.progress_line(), String(""))


def test_progress_color_off_on_tty_shows_but_carries_no_ansi() raises:
    # `--color never` on a real terminal still SHOWS the counter, just uncolored:
    # non-empty text with no ANSI escape byte at all.
    var c = _console(color=ColorWhen.NEVER, is_tty=True)
    c.handle(_progress(1, 3, ["tests/test_a.mojo"], [0.3]))
    var line = c.progress_line()
    assert_true(line.byte_length() > 0)
    assert_true("1/3" in line)
    assert_false("\x1b" in line)


def test_progress_color_on_tty_paints_the_counter() raises:
    # AUTO color on a terminal paints the counter; an escape byte is present.
    var c = _console(color=ColorWhen.AUTO, is_tty=True)
    c.handle(_progress(0, 2, ["tests/test_a.mojo"], [0.0]))
    var line = c.progress_line()
    assert_true(line.byte_length() > 0)
    assert_true("\x1b" in line)


def test_progress_caps_running_names_with_overflow_marker() raises:
    # More than three in-flight files: at most three basenames are named, and an
    # ` +N more` marker accounts the rest — the line must not enumerate them all.
    var c = _console(is_tty=True)
    c.handle(
        _progress(
            0,
            6,
            [
                "tests/test_a.mojo",
                "tests/test_b.mojo",
                "tests/test_c.mojo",
                "tests/test_d.mojo",
                "tests/test_e.mojo",
            ],
            [0.5, 0.4, 0.3, 0.2, 0.1],
        )
    )
    var line = c.progress_line()
    assert_true("+2 more" in line)
    assert_false("test_d.mojo" in line)
    assert_false("test_e.mojo" in line)


def test_progress_empty_running_set_still_reports_counts() raises:
    # A tick with no in-flight files (the final fold, all done) still renders the
    # completed/total counts so the counter is coherent up to the batch's end.
    var c = _console(is_tty=True)
    c.handle(_progress(8, 8, List[String](), List[Float64]()))
    var line = c.progress_line()
    assert_true(line.byte_length() > 0)
    assert_true("8/8" in line)


# --- The text-safety boundary: no child byte reaches the terminal as a command


def _hostile_capture() -> String:
    """One capture block exercising every class the escape mapping names.

    Covers, in order: a plain line; a CSI color sequence; an OSC terminated by
    BEL; an OSC terminated by the two-byte ESC-backslash ST; NUL and DEL inside
    a line; an empty logical line; quotes and a tab; a bare CR; and a C1 control
    written as its valid two-byte UTF-8 encoding, which is the only way a C1 can
    survive the lossy decode as itself rather than as U+FFFD. The block ends in
    a final LF, so the fenced rendering must not gain a phantom last line.
    """
    return (
        String("plain\n")
        + "\x1b[31mred\x1b[0m\n"
        + "\x1b]0;title\x07\n"
        + "\x1b]0;title\x1b\\\n"
        + "nul\x00del\x7f\n"
        + "\n"
        + "quote\"tick'\ttab\n"
        + "carriage\rreturn\n"
        + chr(0x9B)
        + "csi-c1\n"
    )


comptime _HOSTILE_RENDERED: StaticString = (
    "    | plain\n"
    "    | \\x1B[31mred\\x1B[0m\n"
    "    | \\x1B]0;title\\x07\n"
    "    | \\x1B]0;title\\x1B\\\n"
    "    | nul\\x00del\\x7F\n"
    "    | \n"
    "    | quote\"tick'\ttab\n"
    "    | carriage\\x0Dreturn\n"
    "    | \\u009Bcsi-c1\n"
)
"""Exactly what `_hostile_capture()` must look like on screen: every control
the terminal would have executed rendered as visible text, LF and Tab kept, and
one gutter per logical line with no fourth line after the final LF."""


def _feed_hostile_capture(mut c: ConsoleReporter, text: String):
    """One FAIL file whose captured stdout and stderr are both `text`."""
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_hostile.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_hostile.mojo",
            Outcome.FAIL,
            0.1,
            _argv("tests/test_hostile.mojo"),
            1.0,
            _bytes(text),
            _bytes(text),
            exit_status=1,
            parse_disposition=ParseDisposition.PARSED,
        )
    )


def test_captured_output_renders_every_control_class_exactly() raises:
    var c = _console()
    _feed_hostile_capture(c, _hostile_capture())
    var out = c.output()
    assert_true(
        String(_HOSTILE_RENDERED) in out,
        "the captured block was not rendered as the escaped, fenced text the"
        " mapping promises:\n"
        + out,
    )


def test_captured_output_carries_no_raw_escape_or_control_byte() raises:
    # Color is off, so mtest itself emits no ESC either: a single raw ESC, CR,
    # NUL, or DEL anywhere in the buffer is a child byte that got through.
    var c = _console()
    _feed_hostile_capture(c, _hostile_capture())
    var out = c.output()
    assert_false("\x1b" in out, "a raw ESC byte reached the console buffer")
    assert_false("\r" in out, "a raw CR byte reached the console buffer")
    assert_false("\x00" in out, "a raw NUL byte reached the console buffer")
    assert_false("\x07" in out, "a raw BEL byte reached the console buffer")
    assert_false("\x7f" in out, "a raw DEL byte reached the console buffer")
    assert_false(
        chr(0x9B) in out, "a raw C1 control reached the console buffer"
    )


def test_captured_output_appears_once_per_stream_still() raises:
    # The boundary changes how the block is rendered, never how often: stdout
    # and stderr are each framed exactly once for the file.
    var c = _console()
    _feed_hostile_capture(c, _hostile_capture())
    var out = c.output()
    assert_equal(_count(out, String(_HOSTILE_RENDERED)), 2)


def test_child_ansi_is_literal_while_mtest_color_survives() raises:
    # `--color always` is absolute, so mtest paints its own verdict line. The
    # child's identical sequence must appear as text on the same screen.
    var c = _console(color=ColorWhen.ALWAYS, show_output=ShowOutput.ALL)
    _feed_hostile_capture(c, "\x1b[31mred\x1b[0m\n")
    var out = c.output()
    # mtest's own styling, applied AFTER escaping, is intact.
    assert_true(
        "\x1b[31mFAIL" in out, "mtest lost its own ANSI under --color always"
    )
    assert_true("\x1b[0m" in out, "mtest lost its own ANSI reset")
    # The child's identical bytes are shown, not executed.
    assert_true("    | \\x1B[31mred\\x1B[0m\n" in out)
    assert_false(
        "\x1b[31mred" in out, "the child's raw color sequence was emitted"
    )


def test_a_large_capture_escapes_controls_near_both_retained_ends() raises:
    # A clamped capture keeps a head and a tail around a spliced marker line.
    # The boundary must reach both ends, not just the first few bytes.
    var filler = String("")
    for _ in range(2000):
        filler += "ab"
    var text = (
        String("\x1b[2Jhead ")
        + filler
        + "\n[... output truncated at 4096 bytes ...]\n"
        + filler
        + " tail\x1b[0m\n"
    )
    var c = _console()
    _feed_hostile_capture(c, text)
    var out = c.output()
    assert_true("    | \\x1B[2Jhead ab" in out, "the head control survived")
    assert_true("ab tail\\x1B[0m\n" in out, "the tail control survived")
    assert_false("\x1b" in out, "a raw ESC survived in a large capture")
    # The marker line is mtest's own splice and still reads as one fenced line.
    assert_true("    | [... output truncated at 4096 bytes ...]\n" in out)


def test_compiler_diagnostic_is_escaped_and_fenced() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_bad.mojo"))
    c.handle(
        Event.file_finished(
            "tests/test_bad.mojo",
            Outcome.COMPILE_ERROR,
            0.0,
            _argv("tests/test_bad.mojo"),
            0.5,
            List[UInt8](),
            _bytes("error: nope\x1b[2K\nnote: here\n"),
        )
    )
    var out = c.output()
    assert_true("    | error: nope\\x1B[2K\n    | note: here\n" in out)
    assert_false("\x1b" in out)


def test_precompile_compiler_output_is_escaped_and_fenced() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 2, 0))
    c.handle(
        Event.precompile_failed(
            "precompile src/mtest",
            "error: boom\x1b[1;31m\n",
            0,
            casualties=[String("tests/test_a.mojo")],
        )
    )
    var out = c.output()
    assert_true("    | error: boom\\x1B[1;31m\n" in out)
    assert_false("\x1b" in out)


def test_verdict_line_path_cannot_forge_a_second_verdict_row() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(
        Event.file_finished(
            "tests/test_a.mojo\nPASS           tests/evil.mojo  0.00s",
            Outcome.FAIL,
            0.1,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
            exit_status=1,
        )
    )
    var out = c.output()
    assert_true("tests/test_a.mojo\\x0APASS           tests/evil.mojo" in out)
    # The forged row never becomes a line of its own.
    assert_false("\nPASS " in out)


def test_reproduce_line_scalarizes_an_embedded_newline() raises:
    # A node id carrying a newline plus a plausible-looking command must stay
    # inside ONE quoted reproduce line.
    var c = _console()
    var node = String("test_a\nreproduce: mtest --gate /etc/passwd")
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_x.mojo"))
    c.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_x.mojo", node), Outcome.FAIL, "boom", ""
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
    assert_true(
        "\nreproduce: mtest 'tests/test_x.mojo::test_a\\x0Areproduce: mtest"
        " --gate /etc/passwd'\n"
        in out
    )
    # Exactly one line in the buffer begins a reproduce command.
    var starts = 0
    for line in out.split("\n"):
        if String(line).startswith("reproduce: "):
            starts += 1
    assert_equal(starts, 1)


def test_per_test_row_node_id_cannot_forge_a_second_row() raises:
    var c = _console(verbosity=Verbosity.VERBOSE)
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_x.mojo"))
    c.handle(
        Event.test_reported(
            TestResult(
                NodeId("tests/test_x.mojo", "ok\n    FAIL forged"),
                Outcome.PASS,
                "",
                "\x1b[5m0.01s",
            )
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_x.mojo",
            Outcome.PASS,
            0.1,
            _argv("tests/test_x.mojo"),
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
        )
    )
    var out = c.output()
    assert_true(
        "    PASS tests/test_x.mojo::ok\\x0A    FAIL forged  [\\x1B[5m0.01s]\n"
        in out
    )
    assert_false("\n    FAIL forged" in out)


def test_verbose_build_line_scalarizes_each_argv_token() raises:
    var c = _console(verbosity=Verbosity.VERBOSE)
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(
        Event.file_finished(
            "tests/test_x.mojo",
            Outcome.PASS,
            0.1,
            [String("mojo"), String("build"), String("a\nb.mojo")],
            1.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.PARSED,
            passed_tests=1,
        )
    )
    var out = c.output()
    assert_true("    build: mojo build 'a\\x0Ab.mojo'  (build 1.00s)\n" in out)


def test_warning_pattern_cannot_forge_a_second_console_line() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.warning("stale-exclusion", "p\nWARNING  forged: trust me"))
    var out = c.output()
    assert_true(
        "WARNING  stale-exclusion: exclude pattern"
        " 'p\\x0AWARNING  forged: trust me' matched nothing\n"
        in out
    )
    assert_equal(_count(out, "\nWARNING"), 1)


def test_exclusion_pattern_is_scalarized_on_the_excluded_line() raises:
    var c = _console()
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
            exclusion_pattern="a\x1b[2Kb",
        )
    )
    var out = c.output()
    assert_true("(a\\x1B[2Kb)\n" in out)
    assert_false("\x1b" in out)


def test_internal_error_program_name_is_scalarized() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.internal_error("build", "/bin/x\x1b[31m", 2))
    var out = c.output()
    assert_true("could not execute '/bin/x\\x1B[31m' (errno 2" in out)
    assert_false("\x1b" in out)


def test_drift_banner_scalarizes_the_offending_line() raises:
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(Event.file_started("tests/test_x.mojo"))
    c.handle(Event.warning("drift", "off-grammar: \x1b[2Jsurprise"))
    c.handle(
        Event.file_finished(
            "tests/test_x.mojo",
            Outcome.NOT_RUN,
            0.0,
            _argv("tests/test_x.mojo"),
            0.5,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition.DRIFT,
        )
    )
    var out = c.output()
    assert_true("    off-grammar: \\x1B[2Jsurprise\n" in out)
    assert_false("\x1b" in out)


def test_attribution_culprit_name_is_scalarized() raises:
    var out = _attribution(
        AttributionDisposition.ATTRIBUTED, "test_x\x1b[31m", 1, 0.1
    )
    assert_true("culprit: test_x\\x1B[31m " in out)
    assert_false("\x1b" in out)


def test_progress_counter_scalarizes_a_hostile_basename() raises:
    var c = _console(is_tty=True)
    c.handle(_progress(1, 2, ["tests/a\x1b[2Kb.mojo"], [0.1]))
    var line = c.progress_line()
    assert_true("a\\x1B[2Kb.mojo" in line)
    assert_false("\x1b" in line)
    assert_false("\n" in line)


def test_slowest_files_list_scalarizes_its_paths() raises:
    var c = _console(durations=1)
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(
        Event.file_finished(
            "tests/a\x1b[2Kb.mojo",
            Outcome.PASS,
            0.5,
            List[String](),
            0.0,
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
    assert_true("\n  tests/a\\x1B[2Kb.mojo  0.50s\n" in out)
    assert_false("\x1b" in out)


def test_session_header_scalarizes_the_root_and_toolchain_label() raises:
    var c = _console()
    c.handle(Event.session_started("/r\x1b[2Koot", "mojo 1.0.0b2\nfake", 1, 0))
    var out = c.output()
    assert_true("mtest 0.6.0 (mojo 1.0.0b2\\x0Afake)\n" in out)
    assert_true("root: /r\\x1B[2Koot   selected: 1 files" in out)
    assert_false("\x1b" in out)


# --- Escape sites reached only by the retry, precompile, and compile-timeout
# --- paths. Each test is named for ONE escape call and fails when that call
# --- alone is deleted, so no site is covered only by a neighbour's assertion.


def _line_starting_with(text: String, prefix: String) -> String:
    """The first line of `text` beginning with `prefix`, or `""` if none does.

    Lets a test compare a whole rendered line with `assert_equal` instead of
    probing it for fragments, so column padding and field order are pinned
    along with the escaping.
    """
    for line in text.split("\n"):
        if String(line).startswith(prefix):
            return String(line)
    return String("")


def _feed_attempt(
    mut c: ConsoleReporter,
    path: String = "t.mojo",
    step: String = "run",
    classification: String = "signal",
):
    """One non-final retry attempt, rendered as a TRY line."""
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 1, 0))
    c.handle(
        Event.attempt_finished(
            path,
            step,
            1,
            2,
            0,
            1,
            0,
            1,
            False,
            True,
            classification,
            0.5,
            List[UInt8](),
            List[UInt8](),
            False,
            False,
            List[String](),
        )
    )


def test_try_line_scalarizes_the_path() raises:
    # console.mojo `_on_attempt_finished`: `_col(escape_scalar(e.path), ...)`.
    # The whole line is pinned, so the escape is asserted together with the
    # column padding it feeds — a raw ESC would both address the terminal and
    # silently shift the columns.
    var c = _console()
    _feed_attempt(c, path="a\x1b[2Kb.mojo")
    var out = c.output()
    assert_equal(
        _line_starting_with(out, "TRY"),
        "TRY            "
        + "a\\x1B[2Kb.mojo"
        + "                  "
        + "attempt 1/2  run signal  (exit 1)  0.50s",
    )
    assert_false("\x1b" in out)


def test_try_line_scalarizes_the_step_label() raises:
    # console.mojo `_on_attempt_finished`: `escape_scalar(e.step)`.
    var c = _console()
    _feed_attempt(c, step="ru\x1b[2Kn")
    var out = c.output()
    assert_equal(
        _line_starting_with(out, "TRY"),
        "TRY            "
        + "t.mojo                          "
        + "attempt 1/2  ru\\x1B[2Kn signal  (exit 1)  0.50s",
    )
    assert_false("\x1b" in out)


def test_try_line_scalarizes_the_classification_tag() raises:
    # console.mojo `_on_attempt_finished`: `escape_scalar(e.classification)`.
    var c = _console()
    _feed_attempt(c, classification="sig\x1b[2Knal")
    var out = c.output()
    assert_equal(
        _line_starting_with(out, "TRY"),
        "TRY            "
        + "t.mojo                          "
        + "attempt 1/2  run sig\\x1B[2Knal  (exit 1)  0.50s",
    )
    assert_false("\x1b" in out)


def test_precompile_casualty_paths_are_scalarized() raises:
    # console.mojo `_on_precompile_failed`: `escape_scalar(c)` over casualties.
    # A casualty is a file path the run denied; it is named, not counted, so a
    # hostile name reaches the console on its own line.
    var c = _console()
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 2, 0))
    c.handle(
        Event.precompile_failed(
            "precompile src/mtest",
            "error: boom\n",
            0,
            casualties=[
                String("tests/a\x1b[2Kb.mojo"),
                String("tests/plain.mojo"),
            ],
        )
    )
    var out = c.output()
    assert_true("\n  tests/a\\x1B[2Kb.mojo\n  tests/plain.mojo\n" in out)
    assert_false("\x1b" in out)


def test_compile_timeout_banner_scalarizes_the_path() raises:
    # console.mojo `_render_compile_timeout`: `escape_scalar(e.path)` in the
    # framed banner header.
    var c = _console()
    _feed_compile_timeout(c, path="tests/a\x1b[2Kb.mojo")
    var out = c.output()
    # Scoped to THIS line, not the whole buffer: the reproduce line below
    # renders the same path through a different call, so a buffer-wide check
    # would go red for either site and name neither.
    assert_equal(
        _line_starting_with(out, "--- COMPILE-TIMEOUT"),
        (
            "--- COMPILE-TIMEOUT tests/a\\x1B[2Kb.mojo (timed out after 1s) —"
            " mtest killed the build at the compile timeout; the compiler said:"
            " ---"
        ),
    )


def test_compile_timeout_banner_escapes_and_fences_the_compiler_output() raises:
    # console.mojo `_render_compile_timeout`: `_safe_block(...)` over the
    # compiler's captured stderr. The compiler is a child process, so its
    # diagnostics are as untrusted as a test's own stdout.
    var c = _console()
    _feed_compile_timeout(
        c, stderr_text="mojo: note: \x1b[2Klowering\nmojo: note: still\n"
    )
    var out = c.output()
    assert_true(
        "\n    | mojo: note: \\x1B[2Klowering\n    | mojo: note: still\n" in out
    )
    assert_false("\x1b" in out)


def test_compile_timeout_reproduce_scalarizes_the_path() raises:
    # console.mojo `_compile_timeout_repro`: `shell_quote(escape_scalar(e.path))`.
    # Escaping precedes quoting, so the quoting covers the text on screen and
    # the reproduce command stays exactly one console line.
    var c = _console()
    _feed_compile_timeout(c, path="tests/a\x1b[2Kb.mojo")
    var out = c.output()
    # The whole line, exactly — including the quoting the escape feeds. Scoped
    # to this line for the same reason the banner test is: the banner above
    # renders the same path through its own call.
    assert_equal(
        _line_starting_with(out, "reproduce:"),
        "reproduce: mtest --compile-timeout 1 'tests/a\\x1B[2Kb.mojo'",
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
