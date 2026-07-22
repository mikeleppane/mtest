"""The pure GitHub Actions annotations renderer: events to workflow commands.

Turns the accumulated facts of a run into GitHub Actions workflow-command lines
(`::error ...::...`, `::warning ...::...`, `::notice::...`), the surface GitHub
reads to place inline annotations on a Checks run. It is a pure renderer:
`List[Event] -> List[String]`, no I/O and no sink. A serving layer decides
whether to call it and where the returned lines are printed, and owns the
`--gh-annotations` flag, auto-detection, and the stop-commands fencing of
echoed child output.

The frozen shapes, one entry per kind:

- Per-test FAIL, from `TestReported`:
  `::error file=<path>[,line=<n>]::<node id>: <first line of the detail>`.
  `line=` appears only when that first line itself carries a recognizable
  `At <path>:<line>:<col>:` pointer — the same backtrace-pointer shape
  `console.mojo` renders root-relative. No other event carries that fact, so a
  detail without such a pointer (a bare `raise Error(...)`, say) omits `line=`
  rather than guessing one.
- Crash-class file-level failure, from a `FileFinished` whose outcome is
  failing but neither FAIL nor PRECOMPILE_ERROR (CRASH, TIMEOUT,
  COMPILE_ERROR, COMPILE_TIMEOUT, MALFORMED_SUITE):
  `::error file=<path>::<path>: <outcome in words>`. Never carries `line=`;
  there is no per-test location for a whole-file abnormal outcome. A plain
  per-test FAIL file is covered by its `TestReported` rows, so
  `FileFinished(FAIL)` emits nothing here — otherwise every failing test would
  be counted twice against the error cap.
- FLAKY, from `FileFinished.flaky`:
  `::warning file=<path>::<path>: flaky — passed on attempt K of N`. `K` is
  `FileFinished.attempts_used`; `N` is reconciled from the `attempts_planned`
  carried by an earlier `AttemptFinished` for the same file. A FLAKY file
  always had at least one retry-eligible attempt, so that fact is always in
  the stream between the file's `FileStarted` and `FileFinished`.
- The summary notice, from `SessionFinished`: exactly one `::notice` line per
  run carrying the summary band text, never subject to the caps below.
- Precompile failure, from `PrecompileFailed`: one `::error::<step>: ...` with
  no `file=` property. The failure belongs to the step, not to any one file,
  and the casualty files already get their identity from JUnit rows elsewhere.

Bounds are GitHub's own; see `_MAX_ERRORS`/`_MAX_WARNINGS` below. Every message
is escaped through the shared `gh_escape_message` and every `file=` value
through `gh_escape_property` (`mtest.report.escape`) — the only escaping path.
Every field this module reads is already a valid Mojo string — assertion detail
was decoded through `lossy_utf8` upstream, and paths and node ids were never
raw bytes — so this module never decodes and never touches raw captured bytes.

Root convention: every `file=` value is the file's run-root-relative path,
emitted verbatim. GitHub resolves a workflow-command `file=` against the
repository root of the checkout, so an annotation lands on the right source
line only when the invocation root is the repository root — `mtest` run from
the repo root, the ordinary case. Run from a subdirectory the path still
renders, but GitHub anchors it under that subdirectory.
"""
from mtest.model.events import (
    AttemptFinishedPayload,
    Event,
    EventKind,
    FileFinishedPayload,
    PrecompileFailedPayload,
    SessionFinishedPayload,
    TestReportedPayload,
)
from mtest.model.outcome import Outcome
from mtest.model.parse_disposition import ParseDisposition
from mtest.model.test_result import TestResult
from mtest.report.escape import gh_escape_message, gh_escape_property
from mtest.report.signals import _signal_name_for_target

# --- Platform bounds ---------------------------------------------------------
# Re-verified against GitHub's own documentation (July 2026): a workflow STEP
# is capped at 10 error annotations and 10 warning annotations; a JOB is
# additionally capped at 50 annotations total (the sum across its steps). The
# UNRELATED "50" some readers conflate with this is the Checks API's own
# per-UPDATE-REQUEST limit (`POST/PATCH .../check-runs`) — a raw REST surface
# this module never calls; mtest only ever emits workflow-command lines. This
# renderer implements the PER-STEP limits (10/10), since mtest itself is one
# step's stdout.
comptime _MAX_ERRORS = 10
comptime _MAX_WARNINGS = 10

# STABLE-INTENT: measured on the ESCAPED message text (after `gh_escape_message`
# has run), not the raw input — a message that escapes to exactly this many
# bytes or fewer rides whole; anything longer is cut to fit, with the marker
# below appended so a reader can always tell a message was shortened.
comptime _MESSAGE_MAX_BYTES = 4096
comptime _TRUNCATION_MARKER: StaticString = " …[truncated]"


# --- The candidate row: one shape's data before sort/cap/escape -------------


@fieldwise_init
struct _AnnotationRow(Copyable, Movable):
    """One candidate `::error`/`::warning` line before sort, cap, and escape.

    `sort_key` orders it among rows of the same command kind: a real node id
    for a per-test row, a bracket-sentinel key for a file-level, flaky, or
    precompile row. `file` and `message` are raw, unescaped text — escaping
    happens exactly once, in `_render_capped`, so no row-building helper below
    needs to know GitHub's escape grammar.
    """

    var sort_key: String
    var has_file: Bool
    var file: String
    var has_line: Bool
    var line: Int
    var message: String


# --- Per-test FAIL: locating the `At <path>:<line>:<col>:` pointer ----------


def _first_line(text: String) -> String:
    """The text before the first `\\n`, or all of `text` if it has none."""
    if text.byte_length() == 0:
        return String("")
    var parts = text.split("\n", 1)
    return String(parts[0])


def _strip_leading_spaces(s: String) -> String:
    """`s` with its leading run of ASCII spaces removed."""
    var lead = String("")
    for cp in s.codepoint_slices():
        if String(cp) == " ":
            lead += " "
        else:
            break
    return String(s.removeprefix(lead))


def _parse_uint(s: String) -> Int:
    """`s` parsed as a nonnegative base-10 integer, or -1 if it is not one.

    Empty, non-digit, and over-long (more than 15 digits) input is rejected
    rather than guessed at: a line number a reader cannot trust is worse than
    no `line=` property at all.
    """
    var n = s.byte_length()
    if n == 0 or n > 15:
        return -1
    var v = 0
    for b in s.as_bytes():
        var d = Int(b) - 48  # '0'
        if d < 0 or d > 9:
            return -1
        v = v * 10 + d
    return v


def _detail_line_number(first_line: String) -> Int:
    """The line number an `At <path>:<n>:<col>:` pointer carries, else -1.

    Mirrors the one recognized backtrace-pointer shape TestSuite bakes into a
    FAIL's detail, the same shape `console.mojo` renders root-relative: after
    any leading spaces, a line starting `At ` followed by a path, then `:`,
    then digits, then `:`. The path portion is not used — the caller already
    has the test's own root-relative path for `file=` — so only the digit run
    immediately after the first `:` is read, and a path that itself contains a
    `:` degrades to "no line found" rather than mis-locating one.
    """
    var core = _strip_leading_spaces(first_line)
    if not core.startswith("At "):
        return -1
    var rest = String(core.removeprefix("At "))
    var parts = rest.split(":", 2)
    if len(parts) < 2:
        return -1
    return _parse_uint(String(parts[1]))


def _bound_row_detail(s: String) -> String:
    """`s` cut to a bounded raw prefix, on a codepoint boundary.

    A row never retains more than the render bound can ever emit. A row's
    message is escaped and cut to `_MESSAGE_MAX_BYTES` escaped bytes at render
    time; because `gh_escape_message` never shrinks its input, that final
    window derives from at most `_MESSAGE_MAX_BYTES` raw bytes. Keeping whole
    codepoints until at least that many raw bytes are retained therefore
    reproduces the rendered line byte for byte while bounding what the row pins
    in memory. A single newline-free assertion detail can be capture-sized;
    without this the accumulator would retain every such detail in full.
    """
    if s.byte_length() <= _MESSAGE_MAX_BYTES:
        return s.copy()
    var out = String("")
    var used = 0
    for cp in s.codepoint_slices():
        var piece = String(cp)
        out += piece
        used += piece.byte_length()
        if used >= _MESSAGE_MAX_BYTES:
            break
    return out^


def _test_fail_row(t: TestResult) -> _AnnotationRow:
    """The per-test FAIL row: `<node id>: <first assertion line>`.

    Carries `line=` only when that first line itself holds a backtrace
    pointer.
    """
    var node_id = t.node.render()
    var first = _first_line(t.detail)
    # `line=` is read from the leading backtrace pointer, so it is computed from
    # the full first line; only the retained message is bounded (see
    # `_bound_row_detail`) so the row cannot pin a capture-sized detail.
    var line = _detail_line_number(first)
    return _AnnotationRow(
        sort_key=node_id,
        has_file=True,
        file=t.node.path,
        has_line=line >= 0,
        line=line if line >= 0 else 0,
        message=node_id + ": " + _bound_row_detail(first),
    )


# --- Crash-class / file-level failure ---------------------------------------


def _is_file_level_crash_class(o: Outcome) -> Bool:
    """Whether `o` is a whole-file abnormal outcome with no per-test rows.

    Exactly the failing outcomes other than FAIL, which is covered by its own
    `TestReported` rows, and PRECOMPILE_ERROR, which is session-level rather
    than per-file and is rendered by `_precompile_row` instead.
    """
    return (
        o.is_failing() and o != Outcome.FAIL and o != Outcome.PRECOMPILE_ERROR
    )


def _outcome_words(e: FileFinishedPayload) -> String:
    """The crash-class outcome named in words, from typed event fields only.

    Total over the outcomes `_is_file_level_crash_class` accepts; any other
    outcome renders as a bare "failed".
    """
    if e.outcome == Outcome.CRASH:
        var name = _signal_name_for_target(e.signal_number)
        if name != "":
            return (
                "crashed (signal "
                + String(e.signal_number)
                + " — "
                + name
                + ")"
            )
        return "crashed (signal " + String(e.signal_number) + ")"
    if e.outcome == Outcome.TIMEOUT:
        var s = "timed out after " + String(e.timeout_seconds) + "s"
        if e.escalated:
            s += ", escalated to SIGKILL"
        return s
    if e.outcome == Outcome.COMPILE_ERROR:
        return String("compile error")
    if e.outcome == Outcome.COMPILE_TIMEOUT:
        var s = "compile timed out after " + String(e.timeout_seconds) + "s"
        if e.escalated:
            s += ", escalated to SIGKILL"
        return s
    if e.outcome == Outcome.MALFORMED_SUITE:
        if e.parse_disposition == ParseDisposition.AMBIGUOUS:
            return String("malformed suite (ambiguous report)")
        return String("malformed suite (no conforming report block)")
    return String("failed")


def _file_level_row(e: FileFinishedPayload) -> _AnnotationRow:
    """The crash-class file-level row for one abnormal `FileFinished`."""
    return _AnnotationRow(
        sort_key=e.path + "::[file]",
        has_file=True,
        file=e.path,
        has_line=False,
        line=0,
        message=e.path + ": " + _outcome_words(e),
    )


# --- FLAKY -------------------------------------------------------------------


def _flaky_row(
    path: String, attempts_used: Int, attempts_planned: Int
) -> _AnnotationRow:
    """The FLAKY row: `<path>: flaky — passed on attempt K of N`."""
    return _AnnotationRow(
        sort_key=path + "::[flaky]",
        has_file=True,
        file=path,
        has_line=False,
        line=0,
        message=(
            path
            + ": flaky — passed on attempt "
            + String(attempts_used)
            + " of "
            + String(attempts_planned)
        ),
    )


# --- Precompile failure: no `file=` property --------------------------------


def _precompile_ending_words(e: PrecompileFailedPayload) -> String:
    """How the step's final attempt ended, in words, or `""` if unknown.

    Reads the decomposed exec-layer termination kinds the event carries: 0
    EXITED, 1 SIGNALED, 2 TIMED_OUT, 3 SPAWN_FAILED. Mirrors `console.mojo`'s
    `_precompile_ending_phrase` in spirit, kept as its own small copy rather
    than a cross-reporter import.
    """
    if not e.ending_known:
        return String("")
    if e.term_kind == 1:
        var name = _signal_name_for_target(e.term_value)
        var base = "died by signal " + String(e.term_value)
        if name != "":
            base += " (" + name + ")"
        return base
    if e.term_kind == 2:
        var s = "timed out after " + String(e.timeout_seconds) + "s"
        if e.escalated:
            s += ", escalated to SIGKILL"
        return s
    if e.term_kind == 3:
        return "could not be spawned (errno " + String(e.term_value) + ")"
    return "exited " + String(e.term_value)


def _precompile_row(e: PrecompileFailedPayload) -> _AnnotationRow:
    """The precompile-failure row, with no `file=` property.

    The failure is a step-level fact, not a file-level one.
    """
    var msg = e.step + ": precompile failed"
    var ending = _precompile_ending_words(e)
    if ending != "":
        msg += " (" + ending + ")"
    if e.attempts_used > 1:
        msg += "; " + String(e.attempts_used) + " attempts"
    msg += "; " + String(e.casualty_count) + " file(s) could not run"
    return _AnnotationRow(
        sort_key="[precompile]::" + e.step,
        has_file=False,
        file=String(""),
        has_line=False,
        line=0,
        message=msg,
    )


# --- The summary notice -------------------------------------------------------


def _extra_count(count: Int, label: String) -> String:
    """`, <n> <label>` for a nonzero count, else the empty string."""
    if count == 0:
        return String("")
    return ", " + String(count) + " " + label


def _fmt_one_decimal(x: Float64) -> String:
    """`x` rendered with exactly one fractional digit.

    Durations here are always nonnegative; a simple scale-round-split avoids
    depending on the default float formatting, which is not fixed-precision.
    """
    if not (x > 0.0):
        return String("0.0")
    var tenths = Int(x * 10.0 + 0.5)
    var whole = tenths // 10
    var frac = tenths % 10
    return String(whole) + "." + String(frac)


def _notice_message(e: SessionFinishedPayload) -> String:
    """The one-line run summary for the `::notice`.

    Carries the same facts as `console.mojo`'s summary band, composed
    independently of it: no shared state, no ANSI, no framing.
    """
    var tc = e.test_counts
    var s = e.summary.copy()
    var body = (
        String(tc.passed)
        + " passed, "
        + String(tc.failed)
        + " failed, "
        + String(tc.skipped)
        + " skipped"
    )
    body += _extra_count(s.count_of(Outcome.CRASH), "crashed")
    body += _extra_count(s.count_of(Outcome.TIMEOUT), "timed out")
    body += _extra_count(s.count_of(Outcome.COMPILE_ERROR), "compile error")
    body += _extra_count(s.count_of(Outcome.MALFORMED_SUITE), "malformed suite")
    body += _extra_count(s.count_of(Outcome.COMPILE_TIMEOUT), "compile timeout")
    body += _extra_count(
        s.count_of(Outcome.PRECOMPILE_ERROR), "precompile error"
    )
    body += _extra_count(s.count_of(Outcome.FLAKY), "flaky")

    var parenthetical = (
        "("
        + String(s.count_of(Outcome.EXCLUDED))
        + " excluded, "
        + String(s.count_of(Outcome.NOT_RUN))
        + " not run"
    )
    if tc.deselected > 0:
        parenthetical += ", " + String(tc.deselected) + " deselected"
    parenthetical += ")"

    return (
        body
        + " "
        + parenthetical
        + " in "
        + _fmt_one_decimal(e.wall_time_seconds)
        + "s"
    )


# --- Escaping + the 4096-escaped-byte per-message bound ----------------------


def _bound_escaped(escaped: String, max_bytes: Int) -> String:
    """`escaped` cut to at most `max_bytes`, with a marker when it was cut.

    `escaped` is already valid UTF-8, since the GitHub escapers only ever
    replace single ASCII bytes with ASCII escape sequences and never touch a
    multi-byte sequence. The cut therefore walks whole codepoints via
    `codepoint_slices()`; a plain byte-offset cut could split one in half and
    produce invalid UTF-8.
    """
    if escaped.byte_length() <= max_bytes:
        return escaped.copy()
    var marker = String(_TRUNCATION_MARKER)
    var budget = max_bytes - marker.byte_length()
    if budget < 0:
        budget = 0
    var out = String("")
    var used = 0
    for cp in escaped.codepoint_slices():
        var piece = String(cp)
        var piece_len = piece.byte_length()
        if used + piece_len > budget:
            break
        out += piece
        used += piece_len
    return out + marker


def _escaped_message(raw: String) -> String:
    """`raw` escaped for a workflow-command message payload, then bounded.

    The only escaping path is `gh_escape_message`, applied before the byte
    bound is measured: the bound is stable-intent on the escaped length.
    """
    return _bound_escaped(gh_escape_message(raw), _MESSAGE_MAX_BYTES)


# --- Sort, cap, and assemble one command kind's rows -------------------------


def _less(a: String, b: String) -> Bool:
    """Bytewise lexicographic `a < b`."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var na = len(ab)
    var nb = len(bb)
    var m = na if na < nb else nb
    for i in range(m):
        if ab[i] != bb[i]:
            return ab[i] < bb[i]
    return na < nb


def _sort_rows(mut rows: List[_AnnotationRow]):
    """Sort `rows` in place by `sort_key`.

    Row counts are small — one run's worth of failed and flaky files — so an
    O(n^2) insertion sort keeps this dependency-free and stable.
    """
    var n = len(rows)
    for i in range(1, n):
        var j = i
        while j > 0 and _less(rows[j].sort_key, rows[j - 1].sort_key):
            var t = rows[j].copy()
            rows[j] = rows[j - 1].copy()
            rows[j - 1] = t^
            j -= 1


def _command_line(is_warning: Bool, row: _AnnotationRow) -> String:
    """One fully escaped `::error`/`::warning` line from a candidate row."""
    var cmd = "warning" if is_warning else "error"
    var head = "::" + cmd
    if row.has_file:
        head += " file=" + gh_escape_property(row.file)
        if row.has_line:
            head += ",line=" + String(row.line)
    head += "::"
    return head + _escaped_message(row.message)


def _aggregate_line(is_warning: Bool, remaining: Int) -> String:
    """The rollup line replacing the rows past `cap - 1`."""
    var cmd = "warning" if is_warning else "error"
    var noun = "warnings" if is_warning else "errors"
    var msg = "... and " + String(remaining) + " more " + noun
    return "::" + cmd + "::" + _escaped_message(msg)


def _render_capped(
    var rows: List[_AnnotationRow], is_warning: Bool, cap: Int
) -> List[String]:
    """Sort `rows` by sort key, then render them capped at `cap` lines.

    At or under `cap` rows, every row renders individually, in sorted order.
    Past `cap`, the first `cap - 1` sorted rows render individually and one
    aggregate line replaces the rest, so the total line count never exceeds
    `cap`.

    Args:
        rows: The candidate rows for one command kind. Consumed and sorted.
        is_warning: Whether to render `::warning` lines rather than `::error`.
        cap: The maximum number of lines to emit.

    Returns:
        The rendered, fully escaped command lines.
    """
    _sort_rows(rows)
    var n = len(rows)
    var out = List[String]()
    if n <= cap:
        for i in range(n):
            out.append(_command_line(is_warning, rows[i]))
        return out^
    var keep = cap - 1
    for i in range(keep):
        out.append(_command_line(is_warning, rows[i]))
    out.append(_aggregate_line(is_warning, n - keep))
    return out^


# --- Public entry point -------------------------------------------------------


struct AnnotationAccumulator(Copyable, Movable):
    """Online accumulation of the annotation rows a run produces.

    The reporter feeds every event through `observe` as it arrives, and only
    the lightweight `_AnnotationRow`s the capped renderer needs are kept: a
    per-test FAIL row, a file-level crash row, a flaky warning, a precompile
    error, plus the terminal notice. The multi-megabyte `captured_stdout` and
    `captured_stderr` a `FileFinished` or `AttemptFinished` carries is never
    retained; the renderer does not read it, and each row's message is truncated
    to a bounded length as the row is built.

    Every candidate row is held until `render` runs — the caps apply to the
    rendered output, not to what is accumulated — so retention grows as
    O(failures x bounded message) rather than O(files x capture bytes). A
    CI-scale run of hundreds of large-capture failures therefore cannot exhaust
    memory, even though it accumulates far more rows than it will print.

    The only cross-event fact carried is a FLAKY row's `attempts_planned`,
    reconciled from the most recent `AttemptFinished` for the same file since
    its last `FileStarted`.
    """

    var _error_rows: List[_AnnotationRow]
    var _warning_rows: List[_AnnotationRow]
    var _has_notice: Bool
    var _notice_message: String
    var _pending_attempts_planned: Int

    def __init__(out self):
        """An empty accumulator."""
        self._error_rows = List[_AnnotationRow]()
        self._warning_rows = List[_AnnotationRow]()
        self._has_notice = False
        self._notice_message = String("")
        self._pending_attempts_planned = -1

    def observe(mut self, e: Event):
        """Extract this event's annotation rows, then drop the event.

        Total over the event set. No row helper reads the event's raw captured
        bytes, and none of them are retained past this call.

        Args:
            e: The event to extract rows from. Not retained.
        """
        if e.kind == EventKind.FILE_STARTED:
            self._pending_attempts_planned = -1
        elif e.kind == EventKind.ATTEMPT_FINISHED:
            self._pending_attempts_planned = e.data[
                AttemptFinishedPayload
            ].attempts_planned
        elif e.kind == EventKind.TEST_REPORTED:
            ref tr = e.data[TestReportedPayload]
            if tr.test.outcome == Outcome.FAIL:
                self._error_rows.append(_test_fail_row(tr.test))
        elif e.kind == EventKind.FILE_FINISHED:
            ref f = e.data[FileFinishedPayload]
            if _is_file_level_crash_class(f.outcome):
                self._error_rows.append(_file_level_row(f))
            if f.flaky:
                var planned = (
                    self._pending_attempts_planned if self._pending_attempts_planned
                    > 0 else f.attempts_used
                )
                self._warning_rows.append(
                    _flaky_row(f.path, f.attempts_used, planned)
                )
            self._pending_attempts_planned = -1
        elif e.kind == EventKind.PRECOMPILE_FAILED:
            self._error_rows.append(
                _precompile_row(e.data[PrecompileFailedPayload])
            )
        elif e.kind == EventKind.SESSION_FINISHED:
            self._has_notice = True
            self._notice_message = _notice_message(
                e.data[SessionFinishedPayload]
            )

    def render(self) -> List[String]:
        """The accumulated annotation lines, grouped by command kind.

        Returns:
            The sorted, capped `::error` lines, then the sorted, capped
            `::warning` lines, then the single `::notice` line when a
            `SessionFinished` was seen. Each group is ordered by row sort key,
            not by the order the events arrived.
        """
        var out = _render_capped(self._error_rows.copy(), False, _MAX_ERRORS)
        var warning_lines = _render_capped(
            self._warning_rows.copy(), True, _MAX_WARNINGS
        )
        for i in range(len(warning_lines)):
            out.append(warning_lines[i])
        if self._has_notice:
            out.append("::notice::" + _escaped_message(self._notice_message))
        return out^

    def retained_message_bytes(self) -> Int:
        """Total bytes held in the accumulated rows and notice.

        An observability hook: the count is O(annotation output) and
        independent of the raw capture bytes the events carried, which is the
        property the retention bound guarantees.
        """
        var total = self._notice_message.byte_length()
        for r in self._error_rows:
            total += r.message.byte_length() + r.file.byte_length()
        for r in self._warning_rows:
            total += r.message.byte_length() + r.file.byte_length()
        return total


def render_annotations(events: List[Event]) -> List[String]:
    """The complete, ordered GitHub Actions annotation lines for one run.

    Feeds the whole stream through an `AnnotationAccumulator` in emission order
    and renders it: the batch equivalent of the reporter's online path, with no
    I/O and no sink.

    Args:
        events: The run's event stream, in emission order.

    Returns:
        The ordered workflow-command lines, ready to print one per line.
    """
    var acc = AnnotationAccumulator()
    for e in events:
        acc.observe(e)
    return acc.render()
