"""The console design language: `ConsoleReporter` (Layer 2).

The one place in the runner that formats text for humans. It renders the event
stream into an owned `String` buffer, exposed via `output()`, so unit tests can
assert the structure directly and `main` writes that buffer to stdout (flushing
even on an interrupt/partial-summary path).

Every fact it prints comes from an event — there is no side channel. Only the
version string (a build constant) and the color/verbosity/show-output config are
passed at construction; those are not session facts. Color is redundant: the
verdict tokens carry the meaning, and when color is off no escape code is
emitted at all.
"""
from mtest.config import (
    ColorWhen,
    ShowOutput,
    Verbosity,
    lossy_utf8,
    shell_join,
    shell_quote,
)
from mtest.model import Event, EventKind, Outcome, Summary

from mtest.report.reporter import Reporter

# ANSI escape codes. Green for PASS, red for FAIL, red-bold for the crash class
# (CRASH/TIMEOUT/COMPILE-ERROR and their kin), yellow for exclusions/warnings.
# Emitted only when color is enabled; color is never the sole information carrier.
comptime _GREEN: StaticString = "\x1b[32m"
comptime _RED: StaticString = "\x1b[31m"
comptime _RED_BOLD: StaticString = "\x1b[1;31m"
comptime _YELLOW: StaticString = "\x1b[33m"
comptime _PLAIN: StaticString = ""
comptime _RESET: StaticString = "\x1b[0m"

# Column widths for the aligned verdict block. Long tokens (COMPILE-ERROR) fall
# back to a two-space gutter so columns never collide.
comptime _TOKEN_W = 15
comptime _PATH_W = 32


def _verdict_token(outcome: Outcome) -> String:
    """The fixed, ASCII verdict token for an outcome. Total; never raises.

    The vocabulary is fixed and glyph-free so it reads identically with or
    without color and on any terminal.
    """
    if outcome == Outcome.PASS:
        return "PASS"
    if outcome == Outcome.FAIL:
        return "FAIL"
    if outcome == Outcome.SKIP:
        return "SKIP"
    if outcome == Outcome.CRASH:
        return "CRASH"
    if outcome == Outcome.TIMEOUT:
        return "TIMEOUT"
    if outcome == Outcome.COMPILE_ERROR:
        return "COMPILE-ERROR"
    if outcome == Outcome.COMPILE_TIMEOUT:
        return "COMPILE-TIMEOUT"
    if outcome == Outcome.MALFORMED_SUITE:
        return "MALFORMED-SUITE"
    if outcome == Outcome.PRECOMPILE_ERROR:
        return "PRECOMPILE-ERROR"
    if outcome == Outcome.FLAKY:
        return "FLAKY"
    if outcome == Outcome.DESELECTED:
        return "DESELECTED"
    if outcome == Outcome.EXCLUDED:
        return "EXCLUDED"
    if outcome == Outcome.NOT_RUN:
        return "NOT-RUN"
    return "?"


def _color_for(outcome: Outcome) -> StaticString:
    """The ANSI code for an outcome's verdict line. Total; never raises."""
    if outcome == Outcome.PASS:
        return _GREEN
    if outcome == Outcome.FAIL:
        return _RED
    if outcome.is_failing():
        # The remaining failing outcomes are the crash class.
        return _RED_BOLD
    return _PLAIN


def _col(s: String, w: Int) -> String:
    """Left-justify `s` to width `w`, or a two-space gutter if it overflows.

    Keeps the verdict columns aligned without a table library. Never raises.
    """
    var out = s.copy()
    var n = s.byte_length()
    if n >= w:
        out += "  "
    else:
        for _ in range(w - n):
            out += " "
    return out


def _fmt_fixed(x: Float64, decimals: Int) -> String:
    """Format a non-negative number to a fixed number of decimals. Never raises.

    Durations are always non-negative, so a simple scale-round-split is enough;
    it avoids depending on the default float formatting, which is not fixed.
    """
    var scale = 1
    for _ in range(decimals):
        scale *= 10
    var rounded = Int(x * Float64(scale) + 0.5)
    var whole = rounded // scale
    var out = String(whole)
    if decimals > 0:
        var frac = rounded % scale
        var fs = String(frac)
        out += "."
        for _ in range(decimals - fs.byte_length()):
            out += "0"
        out += fs
    return out


def _ensure_trailing_newline(s: String) -> String:
    """A copy of `s` that ends in exactly one newline (empty stays empty)."""
    if s.byte_length() == 0:
        return s.copy()
    if s[byte=s.byte_length() - 1] == "\n":
        return s.copy()
    return s + "\n"


def _signal_name(signo: Int) -> String:
    """The `"SIGNAME, description"` words for a common Linux terminating signal.

    Covers the signals a supervised child can plausibly die by. Returns `""`
    for a signal number outside that set, so the caller can fall back to the
    bare number. Pure.
    """
    if signo == 1:
        return String("SIGHUP, hangup")
    if signo == 2:
        return String("SIGINT, interrupt")
    if signo == 3:
        return String("SIGQUIT, quit")
    if signo == 4:
        return String("SIGILL, illegal instruction")
    if signo == 5:
        return String("SIGTRAP, trace/breakpoint trap")
    if signo == 6:
        return String("SIGABRT, abort")
    if signo == 7:
        return String("SIGBUS, bus error")
    if signo == 8:
        return String("SIGFPE, floating-point exception")
    if signo == 9:
        return String("SIGKILL, killed")
    if signo == 11:
        return String("SIGSEGV, segmentation fault")
    if signo == 13:
        return String("SIGPIPE, broken pipe")
    if signo == 15:
        return String("SIGTERM, terminated")
    return String("")


def _errno_name(errno: Int) -> String:
    """The strerror-style words for a common spawn errno. `""` outside the set.

    Covers the errnos a failed `execvp`/`chdir` plausibly reports, so the caller
    can name the cause and otherwise fall back to the bare number. Pure.
    """
    if errno == 2:
        return String("no such file or directory")
    if errno == 7:
        return String("argument list too long")
    if errno == 8:
        return String("exec format error")
    if errno == 13:
        return String("permission denied")
    return String("")


def _outcome_detail(e: Event) -> String:
    """The per-outcome detail suffix the console renders from event data.

    `FAIL` carries the exit code (`"exit <n>"`), `CRASH` the terminating signal
    named in words when recognized (`"signal 4 — SIGILL, illegal instruction"`,
    else just `"signal <n>"`), `TIMEOUT` the configured deadline (`"timed out
    after <n>s"`); every other outcome has no detail. Pure.
    """
    if e.outcome == Outcome.FAIL:
        return String("exit ") + String(e.exit_status)
    if e.outcome == Outcome.CRASH:
        var base = String("signal ") + String(e.signal_number)
        var name = _signal_name(e.signal_number)
        if name.byte_length() > 0:
            return base + " — " + name
        return base
    if e.outcome == Outcome.TIMEOUT:
        return String("timed out after ") + String(e.timeout_seconds) + "s"
    return String("")


struct ConsoleReporter(Reporter):
    """Renders the event stream into an owned, inspectable console buffer.

    Accumulates three parts as events arrive — the streamed header/verdict
    block, the framed failure sections, and the final summary band — and joins
    them in `output()`. Copyable and Movable so it composes into a
    `CompositeReporter`.
    """

    var version: String
    """The mtest version label, a build constant passed by main."""
    var color_enabled: Bool
    """Whether to emit ANSI color, resolved once at construction."""
    var verbosity: Verbosity
    """How much per-file detail to print: quiet, normal, or verbose."""
    var show_output: ShowOutput
    """Which files' captured output to frame: failures, all, or none."""
    var mtest_build_flags: String
    """Shell-ready build-affecting flags to echo in a run-failure reproduce line."""
    var _head: String
    """The streamed header, warnings, banners, and verdict/excluded lines."""
    var _sections: String
    """The framed failure/crash/compile sections, in file order."""
    var _summary: String
    """The final summary band."""

    def __init__(
        out self,
        var version: String,
        color: ColorWhen,
        is_tty: Bool,
        no_color: Bool,
        verbosity: Verbosity,
        show_output: ShowOutput,
        var mtest_build_flags: String,
    ):
        """Construct a reporter and resolve color once.

        The `--color` choice wins over the environment: `ALWAYS`/`NEVER` are
        absolute; `AUTO` enables color iff stdout is a TTY and `NO_COLOR` is not
        set. All inputs are build constants or config — never session facts.

        Args:
            version: The mtest version label for the header line.
            color: The resolved `--color` choice.
            is_tty: Whether stdout is a terminal (for `AUTO`).
            no_color: Whether `NO_COLOR` is set in the environment (for `AUTO`).
            verbosity: How much per-file detail to render.
            show_output: Which files' captured output to frame.
            mtest_build_flags: Shell-ready build-affecting flags for reproduce
                lines (empty when none are in effect).
        """
        self.version = version^
        if color == ColorWhen.ALWAYS:
            self.color_enabled = True
        elif color == ColorWhen.NEVER:
            self.color_enabled = False
        else:
            self.color_enabled = is_tty and not no_color
        self.verbosity = verbosity
        self.show_output = show_output
        self.mtest_build_flags = mtest_build_flags^
        self._head = String("")
        self._sections = String("")
        self._summary = String("")

    def _paint(self, code: StaticString, text: String) -> String:
        """Wrap `text` in an ANSI color unless color is off or the code is empty.

        When color is disabled no escape byte is emitted at all — color is never
        the sole carrier, so the plain text stands alone. Never raises.
        """
        if not self.color_enabled or code.byte_length() == 0:
            return text.copy()
        return String(code) + text + String(_RESET)

    def output(self) -> String:
        """The full rendered buffer so far. Does not mutate or raise.

        Joins the streamed head, the framed sections, and the summary band. Safe
        to read at any point, including a partial run, so main can flush it on an
        interrupt.
        """
        var out = self._head.copy()
        if self._sections.byte_length() > 0:
            out += "\n" + self._sections
        out += self._summary
        return out

    def handle(mut self, e: Event):
        """Render one event into the buffer. Total over the event set; never raises.
        """
        var k = e.kind
        if k == EventKind.SESSION_STARTED:
            self._on_session_started(e)
        elif k == EventKind.WARNING:
            self._on_warning(e)
        elif k == EventKind.PRECOMPILE_FAILED:
            self._on_precompile_failed(e)
        elif k == EventKind.FILE_FINISHED:
            self._on_file_finished(e)
        elif k == EventKind.INTERNAL_ERROR:
            self._on_internal_error(e)
        elif k == EventKind.SESSION_FINISHED:
            self._on_session_finished(e)
        # FILE_STARTED carries nothing the console renders on its own.

    def _on_internal_error(mut self, e: Event):
        """Render a loud red-bold banner naming the step, program, and errno.

        A spawn failure (nonzero errno) names the cause; errno 0 is a machinery
        failure and carries no errno suffix.
        """
        var banner = String("INTERNAL-ERROR  ") + e.step + ": "
        if e.errno == 0:
            banner += "internal failure running '" + e.program + "'"
        else:
            banner += (
                "could not execute '"
                + e.program
                + "' (errno "
                + String(e.errno)
            )
            var name = _errno_name(e.errno)
            if name.byte_length() > 0:
                banner += " — " + name
            banner += ")"
        self._head += self._paint(_RED_BOLD, banner) + "\n"

    def _on_session_started(mut self, e: Event):
        """Render the header: version + toolchain, then root and file counts."""
        if self.verbosity == Verbosity.QUIET:
            return
        self._head += (
            String("mtest ") + self.version + " (" + e.toolchain + ")\n"
        )
        self._head += (
            String("root: ")
            + e.root
            + "   selected: "
            + String(e.selected_count)
            + " files   excluded: "
            + String(e.excluded_count)
            + "\n\n"
        )

    def _on_warning(mut self, e: Event):
        """Render a loud, yellow warning line, composing the sentence per kind.
        """
        var sentence: String
        if e.warning_kind == "stale-exclusion":
            sentence = (
                String("exclude pattern '")
                + e.warning_pattern
                + "' matched nothing"
            )
        else:
            sentence = e.warning_pattern.copy()
        var line = String("WARNING  ") + e.warning_kind + ": " + sentence
        self._head += self._paint(_YELLOW, line) + "\n"

    def _on_precompile_failed(mut self, e: Event):
        """Render the precompile-failure banner with the compiler output verbatim.
        """
        var banner = (
            String("PRECOMPILE-FAILED  ")
            + e.step
            + "  ("
            + String(e.casualty_count)
            + " file(s) could not run)"
        )
        self._head += self._paint(_RED_BOLD, banner) + "\n"
        self._head += _ensure_trailing_newline(e.compiler_output)
        self._head += "\n"

    def _on_file_finished(mut self, e: Event):
        """Render an excluded line, a verdict line, and any framed section."""
        if e.outcome == Outcome.EXCLUDED:
            var line = _col("EXCLUDED", _TOKEN_W) + _col(e.path, _PATH_W)
            line += "(" + e.exclusion_pattern + ")"
            self._head += self._paint(_YELLOW, line) + "\n"
            return
        if e.outcome == Outcome.NOT_RUN:
            # Not-run is a summary count only; no per-file line. Be robust and
            # simply drop a stray not-run FileFinished rather than crash.
            return

        # In quiet mode only non-PASS verdict lines are shown.
        if not (
            self.verbosity == Verbosity.QUIET and e.outcome == Outcome.PASS
        ):
            var token = _verdict_token(e.outcome)
            var line = _col(token, _TOKEN_W) + _col(e.path, _PATH_W)
            line += _fmt_fixed(e.duration_seconds, 2) + "s"
            var detail = _outcome_detail(e)
            if (
                e.outcome == Outcome.CRASH or e.outcome == Outcome.TIMEOUT
            ) and detail.byte_length() > 0:
                line += "  (" + detail + ")"
            self._head += self._paint(_color_for(e.outcome), line) + "\n"
            if self.verbosity == Verbosity.VERBOSE:
                self._head += (
                    String("    build: ")
                    + shell_join(e.build_argv)
                    + "  (build "
                    + _fmt_fixed(e.build_duration_seconds, 2)
                    + "s)\n"
                )

        if self._should_show_section(e.outcome):
            self._sections += self._render_section(e)

    def _should_show_section(self, outcome: Outcome) -> Bool:
        """Whether a framed section is shown for this outcome under the config.
        """
        if self.show_output == ShowOutput.NONE:
            return False
        if self.show_output == ShowOutput.ALL:
            return True
        return outcome.is_failing()

    def _render_section(self, e: Event) -> String:
        """A framed section with the captured output verbatim and a reproduce line.
        """
        if e.outcome == Outcome.COMPILE_ERROR:
            var out = (
                String("--- COMPILE-ERROR ")
                + e.path
                + " — mojo build said: ---\n"
            )
            out += _ensure_trailing_newline(lossy_utf8(e.captured_stderr))
            out += "reproduce: " + shell_join(e.build_argv) + "\n\n"
            return out

        var token = _verdict_token(e.outcome)
        var header = String("--- ") + token + " " + e.path
        var detail = _outcome_detail(e)
        if detail.byte_length() > 0:
            header += " (" + detail + ")"
        header += " — captured stdout ---\n"
        var out = header
        out += _ensure_trailing_newline(lossy_utf8(e.captured_stdout))
        out += "--- captured stderr ---\n"
        out += _ensure_trailing_newline(lossy_utf8(e.captured_stderr))
        var repro = String("reproduce: mtest ")
        if self.mtest_build_flags.byte_length() > 0:
            repro += self.mtest_build_flags + " "
        repro += shell_quote(e.path)
        out += repro + "\n\n"
        return out

    def _on_session_finished(mut self, e: Event):
        """Render the summary band, colored by the worst outcome present."""
        var s = e.summary.copy()
        var body = (
            String(s.count_of(Outcome.PASS))
            + " passed, "
            + String(s.count_of(Outcome.FAIL))
            + " failed, "
            + String(s.count_of(Outcome.CRASH))
            + " crashed, "
            + String(s.count_of(Outcome.TIMEOUT))
            + " timed out, "
            + String(s.count_of(Outcome.COMPILE_ERROR))
            + " compile error"
        )
        body += _extra_count(s, Outcome.SKIP, "skipped")
        body += _extra_count(s, Outcome.COMPILE_TIMEOUT, "compile timeout")
        body += _extra_count(s, Outcome.MALFORMED_SUITE, "malformed suite")
        body += _extra_count(s, Outcome.PRECOMPILE_ERROR, "precompile error")
        body += _extra_count(s, Outcome.FLAKY, "flaky")

        var band = (
            String("===== ")
            + body
            + " ("
            + String(s.count_of(Outcome.EXCLUDED))
            + " excluded, "
            + String(s.count_of(Outcome.NOT_RUN))
            + " not run) in "
            + _fmt_fixed(e.wall_time_seconds, 1)
            + "s ====="
        )
        self._summary = "\n" + self._paint(_worst_color(s), band) + "\n"


def _extra_count(s: Summary, outcome: Outcome, label: String) -> String:
    """`, <n> <label>` for a nonzero outcome tally, else empty. Never raises."""
    var n = s.count_of(outcome)
    if n == 0:
        return String("")
    return String(", ") + String(n) + " " + label


def _worst_color(s: Summary) -> StaticString:
    """The summary-band color: red-bold if any crash-class outcome ran, else red
    if any failure, else green. Never raises.
    """
    if (
        s.count_of(Outcome.CRASH) > 0
        or s.count_of(Outcome.TIMEOUT) > 0
        or s.count_of(Outcome.COMPILE_ERROR) > 0
        or s.count_of(Outcome.COMPILE_TIMEOUT) > 0
        or s.count_of(Outcome.MALFORMED_SUITE) > 0
        or s.count_of(Outcome.PRECOMPILE_ERROR) > 0
    ):
        return _RED_BOLD
    if s.count_of(Outcome.FAIL) > 0:
        return _RED
    return _GREEN
