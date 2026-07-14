"""Structural tests for the ConsoleReporter design language (Layer 2).

These feed a fixed event stream and assert the STRUCTURE of the rendered buffer,
not its exact bytes: one verdict line per FileFinished in order, the fixed
verdict-token vocabulary, a framed section per non-PASS under the default
`failures`, a shell-quoted `reproduce:` line carrying build flags, the summary
count arithmetic, no escape codes when color is off, signals named in words, and
captured output rendered verbatim (truncation marker included). The console
learns every printed fact from the events — only version and config are passed
in.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.config import ColorWhen, Verbosity, ShowOutput
from mtest.model import EventKind, Summary, Event, Outcome
from mtest.report import ConsoleReporter


def _console(
    color: ColorWhen = ColorWhen.NEVER,
    verbosity: Verbosity = Verbosity.NORMAL,
    show_output: ShowOutput = ShowOutput.FAILURES,
    is_tty: Bool = False,
    no_color: Bool = False,
    mtest_build_flags: String = "",
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


def _feed_mock_run(mut c: ConsoleReporter):
    """Drive the reporter through the full console mock event stream."""
    c.handle(Event.session_started("tests", "mojo 1.0.0b2", 5, 1))
    c.handle(
        Event.file_finished(
            "tests/slow/test_giant.mojo",
            Outcome.EXCLUDED,
            0.0,
            "",
            0.0,
            "",
            "",
            "--exclude tests/slow/*",
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_alpha.mojo",
            Outcome.PASS,
            0.41,
            "mojo build tests/test_alpha.mojo",
            1.0,
            "",
            "",
            "",
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_beta.mojo",
            Outcome.FAIL,
            0.52,
            "mojo build tests/test_beta.mojo",
            1.0,
            "the suite report, verbatim\n",
            "on stderr\n",
            "exit 1",
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_gamma.mojo",
            Outcome.CRASH,
            0.09,
            "mojo build tests/test_gamma.mojo",
            1.0,
            "",
            "",
            "signal 4 — SIGILL, illegal instruction",
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_delta.mojo",
            Outcome.TIMEOUT,
            300.0,
            "mojo build tests/test_delta.mojo",
            1.0,
            "",
            "",
            "SIGTERM sent, exited in grace",
        )
    )
    c.handle(
        Event.file_finished(
            "tests/test_typo.mojo",
            Outcome.COMPILE_ERROR,
            1.30,
            "mojo build tests/test_typo.mojo",
            1.30,
            "",
            "test_typo.mojo:3:5: error: use of unknown declaration 'foo'\n",
            "",
        )
    )
    c.handle(Event.session_finished(_mock_summary(), 302.4, 1))


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
            "",
            0.0,
            "",
            "",
            "",
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


def test_timeout_notes_the_kill() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    assert_true("SIGTERM sent, exited in grace" in out)


def test_framed_section_per_non_pass_under_failures() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    # FAIL, CRASH, TIMEOUT, COMPILE-ERROR each get a framed section; PASS does not.
    assert_true(
        "--- FAIL tests/test_beta.mojo (exit 1) — captured stdout ---" in out
    )
    assert_true(
        "--- COMPILE-ERROR tests/test_typo.mojo — mojo build said: ---" in out
    )
    # The passing file is never framed.
    assert_false("--- PASS tests/test_alpha.mojo" in out)


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
            "mojo build tests/test_loud.mojo",
            1.0,
            "first line\n[... output truncated at 4096 bytes ...]\n",
            "",
            "exit 1",
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
            "mojo build 'tests/path with space.mojo'",
            1.0,
            "boom\n",
            "",
            "exit 1",
        )
    )
    var out = c.output()
    # Build-affecting flags are carried, and the space-bearing path is quoted.
    assert_true(
        "reproduce: mtest --mojo /opt/mojo -I lib 'tests/path with space.mojo'"
        in out
    )


def test_compile_error_reproduce_is_the_build_command() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    assert_true("reproduce: mojo build tests/test_typo.mojo" in out)


def test_summary_count_arithmetic_matches_verdict_lines() raises:
    var c = _console()
    _feed_mock_run(c)
    var out = c.output()
    # The five run-outcome counts equal the five non-excluded/non-not-run lines.
    assert_true(
        "1 passed, 1 failed, 1 crashed, 1 timed out, 1 compile error" in out
    )
    # Excluded and not-run ride the SAME band as SEPARATE counts.
    assert_true("(1 excluded, 2 not run)" in out)
    assert_true("in 302.4s" in out)


def test_color_off_emits_no_escape_codes_but_keeps_tokens() raises:
    var c = _console(color=ColorWhen.NEVER)
    _feed_mock_run(c)
    var out = c.output()
    assert_false("\x1b" in out)
    # Color is never the sole carrier: the tokens still convey the meaning.
    assert_true("FAIL" in out)
    assert_true("CRASH" in out)


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
    c.handle(
        Event.warning("stale-exclusion", "pattern 'old_*' matched nothing")
    )
    var out = c.output()
    assert_true("WARNING" in out)
    assert_true("pattern 'old_*' matched nothing" in out)


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
