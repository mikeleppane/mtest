"""The console design language: `ConsoleReporter`.

The one place in the runner that formats text for humans. It renders the event
stream into an owned `String` buffer, exposed via `output()`, so unit tests can
assert the structure directly and `main` writes that buffer to stdout, flushing
even on an interrupt or partial-summary path.

Every fact it prints comes from an event; there is no side channel. It tells the
per-test failure story: a framed section for every failing test carrying its
verbatim assertion detail and a copy-pasteable repro line, the captured output
shown once per file under an explicit file-scope label, `-v` per-test rows, the
NO-TESTS, MALFORMED-SUITE, DRIFT and capture-overflow tokens, and a summary band
that counts tests for pass/fail/skip and files for the abnormals.

Only the version string, a build constant, and the color/verbosity/show-output
config are passed at construction; those are not session facts. Color is always
redundant: the verdict tokens carry the meaning, and when color is off no escape
code is emitted at all.
"""
from mtest.config import (
    ColorWhen,
    ShowOutput,
    Verbosity,
    lossy_utf8,
    shell_join,
    shell_quote,
)
from mtest.model import (
    AttributionDisposition,
    Event,
    EventKind,
    Outcome,
    ParseDisposition,
    Summary,
    TestCounts,
    TestResult,
    slow_step_label,
)

from mtest.report.escape import fence_region, select_collision_free_token
from mtest.report.reporter import Reporter
from mtest.report.signals import _signal_name_for_target

comptime _HEX: StaticString = "0123456789abcdef"
"""Lowercase hex alphabet for rendering a fence token's random bytes."""

comptime _FENCE_TOKEN_BYTES = 16
"""Random bytes per fence token candidate; 16 bytes is 128 bits of entropy."""

comptime _FENCE_TOKEN_POOL = 4
"""How many independent candidate tokens to mint per run. A region that already
contains the primary token's resume delimiter falls through to the next
candidate; four independent 128-bit tokens make an all-collision draw
impossible in practice."""

comptime _FENCE_WITHHELD: StaticString = (
    "[mtest: captured output withheld — no fence entropy available]"
)
"""Placeholder emitted when no fence token could be minted. Unfenced child bytes
are never echoed under Actions, where they could forge a workflow command.
"""


def _mint_fence_tokens(count: Int) raises -> List[String]:
    """Mint `count` independent high-entropy fence tokens from `/dev/urandom`.

    Each token is `_FENCE_TOKEN_BYTES` random bytes rendered as lowercase hex,
    giving 128 bits of entropy apiece, unique per run. The entropy comes from
    ordinary std file I/O over `/dev/urandom`; the exec and native layers are
    never touched.

    Args:
        count: How many tokens to mint.

    Returns:
        `count` hex token strings, in draw order.

    Raises:
        Error: When `/dev/urandom` could not be read or returned a short read.
            The caller withholds the echoed region rather than emit it
            unfenced.
    """
    var need = count * _FENCE_TOKEN_BYTES
    var raw: List[UInt8]
    with open("/dev/urandom", "r") as f:
        raw = f.read_bytes(need)
    if len(raw) < need:
        raise Error("console: short read from /dev/urandom for fence tokens")
    var out = List[String]()
    for t in range(count):
        var token = String("")
        for b in range(_FENCE_TOKEN_BYTES):
            var v = Int(raw[t * _FENCE_TOKEN_BYTES + b])
            token += String(_HEX[byte=v >> 4])
            token += String(_HEX[byte=v & 0xF])
        out.append(token^)
    return out^


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
    """The fixed, ASCII verdict token for an outcome.

    The vocabulary is glyph-free so it reads identically with or without color
    and on any terminal.
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
    """The ANSI code for an outcome's verdict line."""
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

    Keeps the verdict columns aligned without a table library.
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
    """Format a non-negative number to a fixed number of decimals.

    Assumes `x` is non-negative, which every duration is, so a simple
    scale-round-split suffices. Avoids depending on the default float
    formatting, which is not fixed-width.
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


def _term_phrase(kind: Int, value: Int, escalated: Bool) -> String:
    """A short human phrase for an attempt's decomposed termination.

    The `AttemptFinished` event carries the termination as plain integers, the
    exec-layer `Termination` kinds 0 EXITED, 1 SIGNALED, 2 TIMED_OUT and 3
    SPAWN_FAILED, so this layer imports nothing above it. A signal is named in
    words when recognized, a deadline notes any SIGKILL escalation, and a
    nonzero EXITED is a compiler ICE that exited under its own control.
    """
    if kind == 1:
        var name = _signal_name_for_target(value)
        if name != "":
            return String("signal ") + String(value) + " — " + name
        return String("signal ") + String(value)
    if kind == 2:
        var s = String("timed out")
        if escalated:
            s += ", escalated to SIGKILL"
        return s
    if kind == 3:
        return String("spawn failed (errno ") + String(value) + ")"
    return String("exit ") + String(value)


def _precompile_ending_phrase(
    term_kind: Int, term_value: Int, escalated: Bool, timeout_seconds: Int
) -> String:
    """How a precompile step's final attempt ended, in words.

    A step that never produced its package exits 1 either way, so what the
    banner owes a reader is which ending it was: a deadline mtest enforced, a
    compiler that died by a signal, a compiler that rejected the code, or a
    compiler that could not be spawned. Reads the decomposed exec-layer
    termination kinds the event carries (0 EXITED, 1 SIGNALED, 2 TIMED_OUT,
    3 SPAWN_FAILED), so this layer imports nothing above it.
    """
    if term_kind == 1:
        var name = _signal_name_for_target(term_value)
        var base = String("died by signal ") + String(term_value)
        if name != "":
            return base + " (" + name + ")"
        return base
    if term_kind == 2:
        var s = String("timed out after ") + String(timeout_seconds) + "s"
        if escalated:
            s += ", escalated to SIGKILL"
        return s
    if term_kind == 3:
        return String("could not be spawned (errno ") + String(term_value) + ")"
    return String("exited ") + String(term_value)


def _errno_name(errno: Int) -> String:
    """The strerror-style words for a common spawn errno, else `""`.

    Covers the errnos a failed `execve` or `chdir` plausibly reports, so the
    caller can name the cause and otherwise fall back to the bare number.
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

    `FAIL` carries the exit code (`"exit <n>"`). `CRASH` carries the terminating
    signal, named in words when recognized (`"signal 4 — SIGILL, illegal
    instruction"`, else just `"signal <n>"`). `TIMEOUT` and `COMPILE_TIMEOUT`
    carry the configured deadline (`"timed out after <n>s"`); both read the same
    because both name a deadline mtest enforced. Every other outcome has no
    detail.

    A deadline that had to be escalated says so, in `_term_phrase`'s words so
    the verdict line and the TRY lines agree. When no retry ran, this is the
    only place the escalation reaches a reader, since a TRY line exists only for
    a non-final attempt; that is the common `--timeout N` case.

    The clause is driven by the event's latched `escalated`, so it appears only
    where the session populates it from a run `Termination`. The compile steps
    do not yet pass their `bterm.escalated`, so a COMPILE_TIMEOUT renders the
    bare deadline rather than claiming an escalation nobody recorded.
    """
    if e.outcome == Outcome.FAIL:
        return String("exit ") + String(e.exit_status)
    if e.outcome == Outcome.CRASH:
        var base = String("signal ") + String(e.signal_number)
        var name = _signal_name_for_target(e.signal_number)
        if name.byte_length() > 0:
            return base + " — " + name
        return base
    if e.outcome == Outcome.TIMEOUT or e.outcome == Outcome.COMPILE_TIMEOUT:
        var s = String("timed out after ") + String(e.timeout_seconds) + "s"
        if e.escalated:
            s += ", escalated to SIGKILL"
        return s
    return String("")


def _is_no_tests(e: Event) -> Bool:
    """Whether a `FileFinished` is a NO-TESTS pass.

    A parsed report with zero passed, failed and skipped rows on a PASS file is
    a NO-TESTS result: exit-0 class, but it must never read as "passed".
    """
    return (
        e.outcome == Outcome.PASS
        and e.parse_disposition == ParseDisposition.PARSED
        and e.passed_tests == 0
        and e.failed_tests == 0
        and e.skipped_tests == 0
    )


def _disposition_note(e: Event) -> String:
    """A verdict-line note naming a non-plain disposition, or `""`.

    A CAPTURE_OVERFLOW FAIL and a MALFORMED_SUITE each get a distinct sentence
    naming why no report can be trusted, so neither reads as a plain assertion
    failure.
    """
    if e.parse_disposition == ParseDisposition.CAPTURE_OVERFLOW:
        return String(
            "    capture-overflow: the captured output exceeded the capture"
            " bound, so no report block is trustworthy (not a plain assertion"
            " failure)"
        )
    if e.outcome == Outcome.MALFORMED_SUITE:
        if e.parse_disposition == ParseDisposition.AMBIGUOUS:
            return String(
                "    malformed-suite: the module produced an ambiguous report"
                " (multiple or forged report blocks) — no per-test verdict can"
                " be trusted"
            )
        return String(
            "    malformed-suite: the module ran but spoke no conforming report"
            " block — no per-test verdict can be trusted"
        )
    return String("")


def _slow_note(e: Event) -> String:
    """The `-v` clause naming which steps were slow and their durations.

    `slow_step_label` decides which of the two typed duration fields crossed the
    threshold, and the durations rendered here are always those same fields, so
    this cannot claim a step time the event does not itself carry. Called only
    when `e.slow` is True.
    """
    var label = slow_step_label(e.build_duration_seconds, e.duration_seconds)
    if label == "build":
        return "build " + _fmt_fixed(e.build_duration_seconds, 2) + "s"
    if label == "run":
        return "run " + _fmt_fixed(e.duration_seconds, 2) + "s"
    if label == "build and run":
        return (
            "build "
            + _fmt_fixed(e.build_duration_seconds, 2)
            + "s, run "
            + _fmt_fixed(e.duration_seconds, 2)
            + "s"
        )
    return ""


def _common_indent(lines: List[String]) -> Int:
    """The count of leading spaces shared by every non-empty line, or 0.

    Empty lines are ignored; a non-empty line with no leading space forces 0.
    """
    var m = -1
    for ref ln in lines:
        if ln.byte_length() == 0:
            continue
        var c = 0
        for cp in ln.codepoint_slices():
            if String(cp) == " ":
                c += 1
            else:
                break
        if c == 0:
            return 0
        if m < 0 or c < m:
            m = c
    if m < 0:
        return 0
    return m


def _strip_at_root_prefix(ln: String, root: String) -> String:
    """Strip the run-root prefix from a line that is a backtrace pointer.

    The anchored form of `_transform_detail`'s second transformation. If `ln`,
    after any leading spaces, starts with `At <root>/`, that single occurrence
    of `root + "/"` immediately after `At ` is removed. Every other byte on the
    line rides through untouched, including any later occurrence of the root
    path, such as one inside an assertion message. A line that merely contains
    `"At "` somewhere without being anchored there is left alone.
    """
    if root.byte_length() == 0:
        return ln
    var lead = String("")
    for cp in ln.codepoint_slices():
        if String(cp) == " ":
            lead += " "
        else:
            break
    var marker = lead + "At " + root + "/"
    if not ln.startswith(marker):
        return ln
    return lead + "At " + String(ln.removeprefix(marker))


def _transform_detail(detail: String, root: String) -> String:
    """A FAIL's verbatim detail with the two permitted transformations applied.

    First, strip the common leading-whitespace prefix TestSuite bakes into the
    detail block: a uniform dedent that preserves the relative shape. Second, on
    a line that is a backtrace pointer (`At <path>:<line>:<col>: ...`,
    optionally indented), render the compiler-baked absolute path root-relative
    by stripping the single run-root prefix (`root + "/"`) that immediately
    follows `At `.

    Nothing else is rewritten. A later occurrence of the run root elsewhere on
    the same line, such as inside the assertion message, is untouched, and every
    other byte rides through verbatim.
    """
    if detail.byte_length() == 0:
        return String("")
    var lines = List[String]()
    for ln in detail.split("\n"):
        lines.append(String(ln))
    var indent = _common_indent(lines)
    var prefix = String("")
    for _ in range(indent):
        prefix += " "
    var out = String("")
    for i in range(len(lines)):
        var ln = lines[i].copy()
        if indent > 0 and ln.byte_length() >= indent:
            ln = String(ln.removeprefix(prefix))
        ln = _strip_at_root_prefix(ln, root)
        if i > 0:
            out += "\n"
        out += ln
    return out^


def _extra_count(s: Summary, outcome: Outcome, label: String) -> String:
    """`, <n> <label>` for a nonzero outcome tally, else empty."""
    var n = s.count_of(outcome)
    if n == 0:
        return String("")
    return String(", ") + String(n) + " " + label


@fieldwise_init
struct _FileDuration(Copyable, Movable):
    """One run file's root-relative path and its run-only wall-clock duration.

    Accumulated from `FileFinished` events that reached the run step, meaning
    `duration_seconds > 0.0`, so the slowest-files list can be sorted after the
    fact without re-touching the event stream.
    """

    var path: String
    """The file's root-relative path, as carried by the event."""
    var duration_seconds: Float64
    """The file's spawn-to-reap wall time, in seconds."""


def _path_less(a: String, b: String) -> Bool:
    """Byte-wise lexicographic `a < b`.

    Paths are UTF-8, and comparing bytes gives the same order as comparing
    codepoints, so this is a correct, dependency-free path tiebreak.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var an = len(ab)
    var bn = len(bb)
    var n = an if an < bn else bn
    for i in range(n):
        if ab[i] != bb[i]:
            return ab[i] < bb[i]
    return an < bn


def _slower(a: _FileDuration, b: _FileDuration) -> Bool:
    """Whether `a` sorts before `b`: longer duration first, path breaks ties."""
    if a.duration_seconds != b.duration_seconds:
        return a.duration_seconds > b.duration_seconds
    return _path_less(a.path, b.path)


def _sort_slowest(mut files: List[_FileDuration]):
    """In-place selection sort of `files` by `_slower`.

    File counts are small, one run's worth, so an O(n^2) selection sort keeps
    this dependency-free and trivially deterministic. It is not on a hot path.
    """
    var n = len(files)
    for i in range(n):
        var best = i
        for j in range(i + 1, n):
            if _slower(files[j], files[best]):
                best = j
        if best != i:
            var tmp = files[i].copy()
            files[i] = files[best].copy()
            files[best] = tmp^


def _worst_color(s: Summary, tc: TestCounts) -> StaticString:
    """The summary-band color.

    Red-bold if any crash-class file ran, otherwise red if any test failed or
    any file is a FAIL, otherwise green.
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
    if s.count_of(Outcome.FAIL) > 0 or tc.failed > 0:
        return _RED
    return _GREEN


struct ConsoleReporter(Reporter):
    """Renders the event stream into an owned, inspectable console buffer.

    Accumulates three parts as events arrive — the streamed header and verdict
    block, the framed failure sections, and the final summary band — and joins
    them in `output()`. Per file it accumulates the retrospective TEST_REPORTED
    results so `FILE_FINISHED` can render per-test failure sections.
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
    """Shell-ready build-affecting flags echoed in a reproduce line."""
    var durations: Int
    """`--durations N`: how many slowest-running files to list after the summary
    band; `0`, or the flag being absent, renders nothing extra. Independent of
    `verbosity`, so an explicit `--durations` survives `-q`."""
    var _head: String
    """The streamed header, warnings, banners, and verdict/excluded lines."""
    var _sections: String
    """The framed failure/crash/compile sections, in file order."""
    var _summary: String
    """The final summary band, plus the slowest-files list (when `durations`
    is set) appended after it."""
    var _file_durations: List[_FileDuration]
    """Per-file run-only wall-clock durations accumulated from `FileFinished`,
    for the slowest-files list. Only files that reached the run step
    (`duration_seconds > 0.0`) are recorded; a COMPILE_ERROR, EXCLUDED or
    NOT_RUN file carries `0.0` and is never added."""
    var _run_root: String
    """The run root from SESSION_STARTED, for root-relativizing `At` lines."""
    var _toolchain: String
    """The resolved toolchain label, for naming the pin in a DRIFT banner."""
    var _file_tests: List[TestResult]
    """The current file's TEST_REPORTED results, reset on FILE_STARTED."""
    var _last_warning_detail: String
    """The most recent warning's detail, for folding into a DRIFT banner."""
    var _gh_actions: Bool
    """Whether the run is inside GitHub Actions (`GITHUB_ACTIONS=true`). When
    True, every echoed region of captured child output is wrapped in
    stop-commands fencing so a child's `::error`-shaped bytes cannot forge a
    workflow command. Independent of the `--gh-annotations` mode: fencing is a
    console-path safety measure, active even when annotations are off."""
    var _fence_tokens: List[String]
    """The per-run high-entropy fence-token pool, minted lazily the first time a
    region is fenced, after the producing child has already exited, and reused
    for the whole run. Empty until minted, or if minting failed."""
    var _fence_tokens_tried: Bool
    """Whether token minting has been attempted, so a failed `/dev/urandom` read
    is not retried on every subsequent region."""

    def __init__(
        out self,
        var version: String,
        color: ColorWhen,
        is_tty: Bool,
        no_color: Bool,
        verbosity: Verbosity,
        show_output: ShowOutput,
        var mtest_build_flags: String,
        durations: Int,
        gh_actions: Bool = False,
    ):
        """Construct a reporter and resolve color once.

        The `--color` choice wins over the environment: `ALWAYS` and `NEVER` are
        absolute, while `AUTO` enables color only when the resolved console
        destination is a TTY and `NO_COLOR` is unset. All inputs are build
        constants or config, never session facts.

        Args:
            version: The mtest version label for the header line. Consumed.
            color: The resolved `--color` choice.
            is_tty: Whether the resolved console destination is a terminal,
                consulted for `AUTO`. The caller resolves that destination
                first: under `--json -` the machine stream owns stdout and the
                console relocates to stderr, so this is stderr's TTY status.
            no_color: Whether `NO_COLOR` is set, consulted for `AUTO`.
            verbosity: How much per-file detail to render.
            show_output: Which files' captured output to frame.
            mtest_build_flags: Shell-ready build-affecting flags for reproduce
                lines; empty when none are in effect. Consumed.
            durations: `--durations N` from config; `0` disables the
                slowest-files list.
            gh_actions: Whether the run is inside GitHub Actions
                (`GITHUB_ACTIONS=true`). When True, echoed captured child output
                is wrapped in collision-proof stop-commands fencing.
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
        self.durations = durations
        self._head = String("")
        self._sections = String("")
        self._summary = String("")
        self._run_root = String("")
        self._toolchain = String("")
        self._file_tests = List[TestResult]()
        self._last_warning_detail = String("")
        self._file_durations = List[_FileDuration]()
        self._gh_actions = gh_actions
        self._fence_tokens = List[String]()
        self._fence_tokens_tried = False

    def _paint(self, code: StaticString, text: String) -> String:
        """Wrap `text` in an ANSI color, unless color is off or `code` is empty.

        When color is disabled no escape byte is emitted at all. Color is never
        the sole carrier of meaning, so the plain text stands alone.
        """
        if not self.color_enabled or code.byte_length() == 0:
            return text.copy()
        return String(code) + text + String(_RESET)

    def _ensure_fence_tokens(mut self):
        """Mint the per-run fence-token pool once, on first need.

        Called only under `_gh_actions`, at the first captured-output region.
        That region is rendered from a `FileFinished` or `PrecompileFailed`,
        so the producing child has already exited and the token is never
        exposed to it. A `/dev/urandom` read failure leaves the pool empty and
        is not retried; `_fence` then withholds the region.
        """
        if self._fence_tokens_tried:
            return
        self._fence_tokens_tried = True
        try:
            self._fence_tokens = _mint_fence_tokens(_FENCE_TOKEN_POOL)
        except:
            self._fence_tokens = List[String]()

    def _fence(self, region: String) -> String:
        """Wrap one captured child-output `region` in stop-commands fencing.

        Returns `region` unchanged when not under Actions. Under Actions it
        selects the first pool candidate whose resume delimiter `::<token>::` is
        absent from `region`, stepping past a seeded delimiter, then returns the
        region wrapped by `fence_region` as an opener line, the region, and the
        resume delimiter.

        The token pool must already be minted, which the `mut` callers arrange
        by calling `_ensure_fence_tokens` first. This method only reads the
        pool, so it is safe to call while iterating the per-test list. If the
        pool is empty or every candidate collides, the region is withheld rather
        than echoed unfenced, since unfenced child bytes could forge a workflow
        command.
        """
        if not self._gh_actions:
            return region.copy()
        if len(self._fence_tokens) == 0:
            return String(_FENCE_WITHHELD)
        try:
            var token = select_collision_free_token(region, self._fence_tokens)
            return fence_region(token, region)
        except:
            return String(_FENCE_WITHHELD)

    def fence_token(self) -> String:
        """The primary per-run fence token, or `""` if none was minted.

        `main` reads this to emit the restoration epilogue, a final resume
        delimiter, before its own annotation lines. That epilogue always runs,
        so workflow commands are re-enabled even on a partial or error path.
        Empty means no region was ever fenced, so there is nothing to restore.
        """
        if len(self._fence_tokens) == 0:
            return String("")
        return self._fence_tokens[0].copy()

    def output(self) -> String:
        """The full rendered buffer so far.

        Joins the streamed head, the framed sections, and the summary band. Safe
        to read at any point, including mid-run, so `main` can flush it on an
        interrupt.
        """
        var out = self._head.copy()
        if self._sections.byte_length() > 0:
            out += "\n" + self._sections
        out += self._summary
        return out

    def handle(mut self, e: Event):
        """Render one event into the buffer; total over the event set.

        Args:
            e: The event to render.
        """
        var k = e.kind
        if k == EventKind.SESSION_STARTED:
            self._on_session_started(e)
        elif k == EventKind.WARNING:
            self._on_warning(e)
        elif k == EventKind.PRECOMPILE_FAILED:
            self._on_precompile_failed(e)
        elif k == EventKind.FILE_STARTED:
            # A new file's per-test accumulation begins; drop any stale state.
            self._file_tests = List[TestResult]()
            self._last_warning_detail = String("")
        elif k == EventKind.FILE_FINISHED:
            self._on_file_finished(e)
        elif k == EventKind.INTERNAL_ERROR:
            self._on_internal_error(e)
        elif k == EventKind.SESSION_FINISHED:
            self._on_session_finished(e)
        elif k == EventKind.TEST_REPORTED:
            # Accumulate the retrospective per-test result; FILE_FINISHED renders
            # the per-test story from it. Emits nothing on its own.
            self._file_tests.append(e.test.copy())
        elif k == EventKind.COLLECTION_KNOWN:
            # The collection line arrives in a later surface; nothing here yet.
            pass
        elif k == EventKind.ATTEMPT_FINISHED:
            self._on_attempt_finished(e)
        elif k == EventKind.CRASH_ATTRIBUTION:
            self._on_crash_attribution(e)

    def _reset_file(mut self):
        """Clear the per-file accumulation after a file is fully rendered."""
        self._file_tests = List[TestResult]()
        self._last_warning_detail = String("")

    def _on_internal_error(mut self, e: Event):
        """Render a red-bold banner naming the step, program, and errno.

        A spawn failure, meaning a nonzero errno, names the cause. Errno 0 is a
        machinery failure and carries no errno suffix.
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
        """Render the header: version and toolchain, then root and file counts.

        Also latches the run root and toolchain, which are needed even under
        quiet for root-relativizing `At` lines and naming the pin in a DRIFT
        banner.
        """
        self._run_root = e.root.copy()
        self._toolchain = e.toolchain.copy()
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
        """Render a yellow warning line, composing the sentence per kind.

        Latches the detail so a DRIFT file's banner can fold in the offending
        line the session emitted just before its `FileFinished`.
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
        self._last_warning_detail = e.warning_pattern.copy()
        var line = String("WARNING  ") + e.warning_kind + ": " + sentence
        self._head += self._paint(_YELLOW, line) + "\n"

    def _on_attempt_finished(mut self, e: Event):
        """Render a "TRY" line for one non-final crash-class retry attempt.

        Reads the attempt's identity from the plain decomposed fields the event
        carries, never by re-parsing bytes: which attempt of how many, the step
        and classification, and a short phrase for the termination. An excerpt
        marker says when the captured streams were clamped.
        """
        var phrase = _term_phrase(e.term_kind, e.term_value, e.escalated)
        var line = _col("TRY", _TOKEN_W) + _col(e.path, _PATH_W)
        line += (
            String("attempt ")
            + String(e.attempt_index)
            + "/"
            + String(e.attempts_planned)
            + "  "
            + e.step
            + " "
            + e.classification
            + "  ("
            + phrase
            + ")  "
            + _fmt_fixed(e.duration_seconds, 2)
            + "s"
        )
        if e.stdout_truncated or e.stderr_truncated:
            line += "  [excerpt]"
        self._head += self._paint(_YELLOW, line) + "\n"

    def _on_crash_attribution(mut self, e: Event):
        """Render one crashed file's bounded-isolation attribution result.

        Composed from the event's typed fields only — the disposition, the
        culprit, the rerun count, and the elapsed time — never from a sentence
        the session pre-rendered.

        Attribution is secondary evidence: the file's CRASH verdict was already
        rendered above and is not restated here as a verdict. Every
        non-ATTRIBUTED disposition therefore states both that the verdict is
        unchanged and that the culprit is unattributed, so a stopped search
        cannot read as a soft accusation. The line's token is `ATTRIBUTION`,
        which is not a prefix of any verdict token in the vocabulary, so a
        line-oriented reader scanning for `CRASH` never matches this diagnostic.
        """
        var d = e.attribution_disposition
        var label: String
        var detail: String
        if d == AttributionDisposition.ATTRIBUTED:
            label = String("ATTRIBUTED")
            detail = String("culprit: ") + e.culprit_test
        elif d == AttributionDisposition.NO_REPRODUCTION:
            label = String("NO-REPRODUCTION")
            detail = String(
                "the crash did not reproduce with each test run alone; the"
                " CRASH verdict stands and the culprit is UNATTRIBUTED"
            )
        elif d == AttributionDisposition.PROBE_FAILED:
            label = String("PROBE-FAILED")
            detail = String(
                "the file's test list could not be recovered, so no test could"
                " be isolated; the CRASH verdict stands and the culprit is"
                " UNATTRIBUTED"
            )
        elif d == AttributionDisposition.RUN_CAP:
            label = String("RUN-CAP")
            detail = String(
                "the 32-run cap stopped the search before every test had run"
                " alone; the CRASH verdict stands and the culprit is"
                " UNATTRIBUTED"
            )
        else:
            label = String("TIME-BUDGET")
            detail = String(
                "the time budget stopped the search before every test had run"
                " alone; the CRASH verdict stands and the culprit is"
                " UNATTRIBUTED"
            )
        var line = _col("ATTRIBUTION", _TOKEN_W) + _col(e.path, _PATH_W)
        line += (
            label
            + "  "
            + detail
            + "  ("
            + String(e.isolation_reruns)
            + " isolation rerun(s), "
            + _fmt_fixed(e.attribution_seconds, 2)
            + "s)"
        )
        self._head += self._paint(_YELLOW, line) + "\n"

    def _on_precompile_failed(mut self, e: Event):
        """Render the precompile-failure banner, compiler output verbatim.

        Uses the frozen outcome-vocabulary label PRECOMPILE-ERROR and names each
        dependent test file as a casualty rather than only counting them, so a
        reader sees exactly which files were denied a run. When the event
        carries the step's final termination it is named in words: a step killed
        at the compile deadline reads as a timeout, never as the compiler
        rejecting the code, and a step that burned its retry budget says how
        many attempts it spent. Rendered from typed fields only; the compiler's
        own output rides verbatim below.
        """
        var detail = String("")
        if e.ending_known:
            detail += (
                _precompile_ending_phrase(
                    e.term_kind, e.term_value, e.escalated, e.timeout_seconds
                )
                + "; "
            )
            if e.attempts_used > 1:
                detail += String(e.attempts_used) + " attempts; "
        var banner = (
            String("PRECOMPILE-ERROR  ")
            + e.step
            + "  ("
            + detail
            + String(e.casualty_count)
            + " file(s) could not run)"
        )
        self._head += self._paint(_RED_BOLD, banner) + "\n"
        for c in e.casualties:
            self._head += "  " + c + "\n"
        if self._gh_actions:
            self._ensure_fence_tokens()
        self._head += _ensure_trailing_newline(self._fence(e.compiler_output))
        self._head += "\n"

    def _on_file_finished(mut self, e: Event):
        """Render an excluded line, verdict line, sections, or a banner."""
        if e.duration_seconds > 0.0:
            # RUN-ONLY signal: a file that never reached the run step (an
            # EXCLUDED, COMPILE_ERROR-before-run, or NOT_RUN file) carries
            # `0.0` here and is never counted for the slowest-files list. A
            # TIMEOUT/interrupted file DID run and is recorded at its
            # observed value. Independent of every branch below.
            self._file_durations.append(
                _FileDuration(e.path.copy(), e.duration_seconds)
            )
        if e.outcome == Outcome.EXCLUDED:
            var line = _col("EXCLUDED", _TOKEN_W) + _col(e.path, _PATH_W)
            line += "(" + e.exclusion_pattern + ")"
            self._head += self._paint(_YELLOW, line) + "\n"
            self._reset_file()
            return
        if e.parse_disposition == ParseDisposition.DRIFT:
            # The sanctioned exit-3 path: an off-grammar report from the pinned
            # toolchain. Its file outcome is NOT_RUN, so render the loud banner
            # here before the generic not-run drop below.
            self._render_drift(e)
            self._reset_file()
            return
        if e.outcome == Outcome.NOT_RUN:
            # Not-run is a summary count only; no per-file line. Be robust and
            # simply drop a stray not-run FileFinished rather than crash.
            self._reset_file()
            return

        var no_tests = _is_no_tests(e)
        # In quiet mode only non-PASS verdict lines are shown (NO-TESTS is
        # exit-0 class, so it is suppressed alongside PASS).
        if not (
            self.verbosity == Verbosity.QUIET and e.outcome == Outcome.PASS
        ):
            var token = String("NO-TESTS") if no_tests else _verdict_token(
                e.outcome
            )
            var line = _col(token, _TOKEN_W) + _col(e.path, _PATH_W)
            line += _fmt_fixed(e.duration_seconds, 2) + "s"
            var detail = _outcome_detail(e)
            if (
                e.outcome == Outcome.CRASH
                or e.outcome == Outcome.TIMEOUT
                or e.outcome == Outcome.COMPILE_TIMEOUT
            ) and detail.byte_length() > 0:
                line += "  (" + detail + ")"
            if e.slow:
                # An INFORMAL-tier annotation, never an outcome: it rides
                # alongside whatever verdict token this line already carries
                # and never replaces it — a SLOW file still reports its real
                # verdict, counts, and exit code.
                line += "  SLOW"
            var color = _YELLOW if no_tests else _color_for(e.outcome)
            self._head += self._paint(color, line) + "\n"
            var note = _disposition_note(e)
            if note.byte_length() > 0:
                self._head += self._paint(_YELLOW, note) + "\n"
            if self.verbosity == Verbosity.VERBOSE:
                self._head += (
                    String("    build: ")
                    + shell_join(e.build_argv)
                    + "  (build "
                    + _fmt_fixed(e.build_duration_seconds, 2)
                    + "s)\n"
                )
                if e.slow:
                    self._head += String("    slow: ") + _slow_note(e) + "\n"
                for ref t in self._file_tests:
                    self._head += self._render_test_row(t)

        if self._should_show_section(e.outcome):
            # Mint the per-run fence tokens before rendering any captured-output
            # region (the child has exited by now); the read-only render helpers
            # then fence each region from the minted pool.
            if self._gh_actions:
                self._ensure_fence_tokens()
            self._sections += self._render_section(e)
        self._reset_file()

    def _render_test_row(self, t: TestResult) -> String:
        """One `-v` per-test row: outcome token, node id, and raw timing."""
        var out = String("    ") + _verdict_token(t.outcome) + " "
        out += t.node.render()
        if t.timing.byte_length() > 0:
            out += "  [" + t.timing + "]"
        return out + "\n"

    def _render_drift(mut self, e: Event):
        """A DRIFT banner naming the pin, snapshots, and offending line."""
        var banner = (
            String("DRIFT  ")
            + e.path
            + " — the pinned toolchain "
            + self._toolchain
            + " emitted an off-grammar report."
        )
        self._head += self._paint(_RED_BOLD, banner) + "\n"
        if self._last_warning_detail.byte_length() > 0:
            self._head += "    " + self._last_warning_detail + "\n"
        self._head += (
            "    Check the toolchain pin and tests/snapshots/protocol/, and"
            " this file's own captured output.\n"
        )

    def _should_show_section(self, outcome: Outcome) -> Bool:
        """Whether a framed section is shown for this outcome, per config."""
        if self.show_output == ShowOutput.NONE:
            return False
        if self.show_output == ShowOutput.ALL:
            return True
        return outcome.is_failing()

    def _repro_line(self, target: String) -> String:
        """A `reproduce: mtest [<flags>] <target>` line, shell-quoted."""
        var repro = String("reproduce: mtest ")
        if self.mtest_build_flags.byte_length() > 0:
            repro += self.mtest_build_flags + " "
        repro += shell_quote(target)
        return repro

    def _compile_timeout_repro(self, e: Event) -> String:
        """A `reproduce:` line naming the deadline that fired.

        The COMPILE-ERROR banner reproduces with the raw `mojo build` argv, but
        that argv would hang, since this build is precisely one that does not
        finish. A COMPILE-TIMEOUT therefore reproduces through mtest, carrying
        the `--compile-timeout` that fired, so the reader reruns the same
        experiment rather than a different one.
        """
        var repro = String("reproduce: mtest ")
        if self.mtest_build_flags.byte_length() > 0:
            repro += self.mtest_build_flags + " "
        repro += "--compile-timeout " + String(e.timeout_seconds) + " "
        repro += shell_quote(e.path)
        return repro

    def _render_compile_timeout(self, e: Event) -> String:
        """The framed COMPILE-TIMEOUT banner, rendered from typed fields only.

        Names the deadline, shows whatever the compiler managed to say verbatim,
        then carries the one actionable hint, split or exclude, and a repro
        line.

        The quarantine sentence is conditional on `attempts_used > 1`, because
        only then did a retry actually run and rebuild against a fresh
        quarantined module cache. At `--retries 0` exactly one attempt was
        scheduled, and the banner promises nothing about a rebuild that never
        happened.

        That sentence reports how many attempts ran and nothing about how each
        one ended, because `attempts_used` is a count and no typed field records
        the per-attempt endings. A first attempt killed by a compiler ICE, which
        is crash-class and so triggers a quarantined-cache rebuild, followed by
        a second that blew the deadline, is also `attempts_used == 2` on a
        COMPILE-TIMEOUT file, so claiming the deadline fired every time would be
        unearned. The verdict line and the sentence above it already state the
        one ending that is known: the final attempt's.
        """
        var secs = String(e.timeout_seconds)
        var out = (
            String("--- COMPILE-TIMEOUT ")
            + e.path
            + " (timed out after "
            + secs
            + "s) — mtest killed the build at the compile timeout; the"
            + " compiler said: ---\n"
        )
        out += _ensure_trailing_newline(
            self._fence(lossy_utf8(e.captured_stderr))
        )
        out += (
            "the build exceeded the "
            + secs
            + "s compile timeout — split the module into smaller files or"
            " exclude it (raise the deadline with --compile-timeout N, or"
            " --compile-timeout 0 to remove it)\n"
        )
        if e.attempts_used > 1:
            out += (
                "the compile was retried against a fresh quarantined module"
                " cache ("
                + String(e.attempts_used)
                + " attempts)\n"
            )
        out += self._compile_timeout_repro(e) + "\n\n"
        return out

    def _render_section(self, e: Event) -> String:
        """The file's sections for one FILE_FINISHED event.

        A compile timeout or a compile error renders its own single block and
        nothing else. Otherwise: one framed block per failing test in the file,
        followed by the file-scope block.
        """
        if e.outcome == Outcome.COMPILE_TIMEOUT:
            return self._render_compile_timeout(e)

        if e.outcome == Outcome.COMPILE_ERROR:
            var out = (
                String("--- COMPILE-ERROR ")
                + e.path
                + " — mojo build said: ---\n"
            )
            out += _ensure_trailing_newline(
                self._fence(lossy_utf8(e.captured_stderr))
            )
            out += "reproduce: " + shell_join(e.build_argv) + "\n\n"
            return out

        var out = String("")
        var has_pertest = False
        for ref t in self._file_tests:
            if t.outcome == Outcome.FAIL:
                has_pertest = True
                out += self._render_test_failure(t)
        out += self._render_file_scope(e, has_pertest)
        return out

    def _render_test_failure(self, t: TestResult) -> String:
        """A framed per-test failure: node id, verbatim detail, repro line.

        The detail carries the two permitted transformations only, a uniform
        dedent and a root-relative `At` line; the untransformed bytes remain in
        the file-scope captured-output block below.
        """
        var node = t.node.render()
        var out = String("--- FAIL ") + node + " ---\n"
        var d = _transform_detail(t.detail, self._run_root)
        if d.byte_length() > 0:
            out += _ensure_trailing_newline(self._fence(d))
        out += self._repro_line(node) + "\n\n"
        return out

    def _render_file_scope(self, e: Event, has_pertest: Bool) -> String:
        """The once-per-file captured-output block, under a scope label.

        TestSuite does not attribute captured output per test, so the block is
        labelled file-scoped and says so on screen. A file-level repro rides
        here only when no per-test section already carried one.
        """
        var token = String("NO-TESTS") if _is_no_tests(e) else _verdict_token(
            e.outcome
        )
        var header = String("--- ") + token + " " + e.path
        var detail = _outcome_detail(e)
        if detail.byte_length() > 0:
            header += " (" + detail + ")"
        header += (
            " — captured output (file-scoped; TestSuite does not attribute"
            " output to individual tests) ---\n"
        )
        var out = header
        out += _ensure_trailing_newline(
            self._fence(lossy_utf8(e.captured_stdout))
        )
        out += "--- captured stderr ---\n"
        out += _ensure_trailing_newline(
            self._fence(lossy_utf8(e.captured_stderr))
        )
        if not has_pertest:
            out += self._repro_line(e.path) + "\n"
        out += "\n"
        return out

    def _on_session_finished(mut self, e: Event):
        """Render the summary band, colored by the worst outcome present.

        The arithmetic: `passed`, `failed` and `skipped` are per-test totals
        over the tests that actually ran. The file-level abnormals — crashed,
        timed out, compile error, malformed suite and their kin — are per-file
        counts appended only when nonzero, accounting for files that produced no
        per-test attribution. `excluded`, `not run` and `deselected` are
        separate counts in the parenthetical.

        So passed + failed + skipped is the number of tests run, and the file
        abnormals plus excluded plus not-run cover every file with no test rows.
        """
        var s = e.summary.copy()
        var tc = e.test_counts
        var body = (
            String(tc.passed)
            + " passed, "
            + String(tc.failed)
            + " failed, "
            + String(tc.skipped)
            + " skipped"
        )
        body += _extra_count(s, Outcome.CRASH, "crashed")
        body += _extra_count(s, Outcome.TIMEOUT, "timed out")
        body += _extra_count(s, Outcome.COMPILE_ERROR, "compile error")
        body += _extra_count(s, Outcome.MALFORMED_SUITE, "malformed suite")
        body += _extra_count(s, Outcome.COMPILE_TIMEOUT, "compile timeout")
        body += _extra_count(s, Outcome.PRECOMPILE_ERROR, "precompile error")
        body += _extra_count(s, Outcome.FLAKY, "flaky")

        var parenthetical = (
            String("(")
            + String(s.count_of(Outcome.EXCLUDED))
            + " excluded, "
            + String(s.count_of(Outcome.NOT_RUN))
            + " not run"
        )
        if tc.deselected > 0:
            parenthetical += ", " + String(tc.deselected) + " deselected"
        parenthetical += ")"

        var band = (
            String("===== ")
            + body
            + " "
            + parenthetical
            + " in "
            + _fmt_fixed(e.wall_time_seconds, 1)
            + "s ====="
        )
        self._summary = "\n" + self._paint(_worst_color(s, tc), band) + "\n"
        self._summary += self._render_slowest_files()

    def _render_slowest_files(self) -> String:
        """The after-band slowest-files list, or `""` when it says nothing.

        Empty when `durations` is `0` or absent, and also empty when no file
        reached the run step. Otherwise sorts the accumulated run-only durations
        descending, breaking ties by root-relative path ascending, and renders
        at most `min(durations, files_run)` rows under a header stating the
        actual row count shown, never the requested `N` when fewer files ran.

        This is file-level: the header says "files" and no per-test timing is
        shown or implied. Renders regardless of `verbosity`, so an explicit
        `--durations` survives `-q`.
        """
        if self.durations <= 0:
            return String("")
        var files = self._file_durations.copy()
        _sort_slowest(files)
        var total = len(files)
        var n_rows = self.durations if self.durations < total else total
        if n_rows == 0:
            return String("")
        var out = String("\nslowest ") + String(n_rows) + " files:\n"
        for i in range(n_rows):
            out += (
                "  "
                + files[i].path
                + "  "
                + _fmt_fixed(files[i].duration_seconds, 2)
                + "s\n"
            )
        return out^
