"""The pure GitHub Actions annotations renderer (Layer 2): `Event`s -> workflow-
command lines.

This turns the accumulated facts of a run into GitHub Actions workflow-command
lines (`::error ...::...`, `::warning ...::...`, `::notice::...`) — the surface
GitHub reads to place inline annotations on a Checks run. It is a PURE
renderer: `List[Event] -> List[String]`, no I/O, no sink; a later (serving)
task decides WHETHER to call this, WHERE the returned lines are printed, and
owns the `--gh-annotations` flag, auto-detection, and the stop-commands
FENCING of echoed CHILD output (a different concern: neutralizing text this
module does not touch).

The frozen shapes, one clear entry per kind:

- Per-test FAIL (from `TestReported`): `::error file=<path>[,line=<n>]::
  <node id>: <first line of the assertion detail>`. `line=` is present ONLY
  when that first line itself carries a recognizable `At <path>:<line>:<col>:`
  location pointer (the same backtrace-pointer shape `console.mojo` renders
  root-relative) — a fact no OTHER event carries, so a detail with no such
  pointer (e.g. a bare `raise Error(...)`) omits `line=` rather than guess one.
- Crash-class / file-level failure (`FileFinished` with a failing, non-FAIL,
  non-PRECOMPILE_ERROR outcome — CRASH, TIMEOUT, COMPILE_ERROR,
  COMPILE_TIMEOUT, MALFORMED_SUITE): `::error file=<path>::<path>: <outcome in
  words>`. Never carries `line=` — there is no per-test location for a whole-
  file abnormal outcome. A plain per-test FAIL file is covered ENTIRELY by its
  `TestReported` rows above; `FileFinished(FAIL)` itself emits nothing here, or
  every failing test would be double-counted against the error cap.
- FLAKY (`FileFinished.flaky`): `::warning file=<path>::<path>: flaky — passed
  on attempt K of N`. `K` is `FileFinished.attempts_used`; `N` is
  reconciled from the `attempts_planned` an earlier `AttemptFinished` for the
  SAME file carried (a FLAKY file always had at least one retry-eligible
  attempt, so this fact is always present in the stream between that file's
  `FileStarted` and `FileFinished` — a genuine cross-event reconciliation,
  never a console-text parse or an invented session side channel).
- The summary notice (`SessionFinished`): exactly ONE `::notice::<band text>`
  per run, never subject to the error/warning caps.
- Precompile failure (`PrecompileFailed`): one `::error::<step>: ...` with NO
  `file=` property — the failure belongs to the STEP, not any one file, and
  the casualty files already get their identity from JUnit rows elsewhere; an
  annotation flood here would only burn the error cap on a derivative fact.

Bounds (GitHub's own, re-verified — see `_MAX_ERRORS`/`_MAX_WARNINGS` below).
Every message is escaped via the shared `gh_escape_message`
(`mtest.report.escape`) and every `file=` value via `gh_escape_property` — the
ONLY escaping path, applied to already-decoded `String` fields (every field
this module reads — paths, node ids, assertion detail — is built from a
`lossy_utf8`-decoded source upstream in the protocol/session layers, so this
module never re-decodes and never touches raw captured bytes).

Root convention: every `file=` value is the test/file's RUN-ROOT-RELATIVE path,
emitted verbatim. GitHub resolves a workflow-command `file=` against the
repository root of the checkout, so an annotation lands on the right source line
ONLY when the invocation root is the repository root (`mtest` run from the repo
root, the ordinary case). Run from a subdirectory the same path still renders,
but GitHub would anchor it under that subdirectory — the convention this module
assumes, stated here rather than inherited transitively from the path fields.
"""
from mtest.model.events import Event, EventKind
from mtest.model.outcome import Outcome
from mtest.model.parse_disposition import ParseDisposition
from mtest.model.test_result import TestResult
from mtest.report.escape import gh_escape_message, gh_escape_property

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

    `sort_key` orders it among rows of the SAME command kind (a real node id
    for a per-test row, a bracket-sentinel key for a file-level/flaky/
    precompile row); `file` and `message` are RAW, unescaped text — escaping
    happens exactly once, in `_render_capped`, so no row-building helper
    below needs to know about GH's escape grammar.
    """

    var sort_key: String
    var has_file: Bool
    var file: String
    var has_line: Bool
    var line: Int
    var message: String


# --- Per-test FAIL: locating the `At <path>:<line>:<col>:` pointer ----------


def _first_line(text: String) -> String:
    """The text before the first `\\n`, or all of `text` if it has none. Pure.
    """
    if text.byte_length() == 0:
        return String("")
    var parts = text.split("\n", 1)
    return String(parts[0])


def _strip_leading_spaces(s: String) -> String:
    """`s` with its leading ASCII space run removed. Pure; never raises."""
    var lead = String("")
    for cp in s.codepoint_slices():
        if String(cp) == " ":
            lead += " "
        else:
            break
    return String(s.removeprefix(lead))


def _parse_uint(s: String) -> Int:
    """`s` parsed as a nonnegative base-10 integer, or -1 if it is not one.

    Pure; never raises. Empty, non-digit, or pathologically long (>15 digit)
    input is rejected rather than guessed at — a line NUMBER a reader cannot
    trust is worse than no `line=` property at all.
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
    """The line number `first_line` carries via an `At <path>:<n>:<col>:`
    pointer, or -1 if it carries none. Pure; never raises.

    Mirrors the ONE recognized backtrace-pointer shape TestSuite bakes into a
    FAIL's detail (the same shape `console.mojo` renders root-relative): after
    any leading spaces, a line starting `At ` followed by a path, then `:`,
    then digits, then `:`. The path portion is not used here (the caller
    already has the test's own root-relative path for `file=`) — only the
    digit run immediately after the FIRST `:` is read, so a path that itself
    contains a `:` degrades to "no line found" rather than mis-locating one.
    """
    var core = _strip_leading_spaces(first_line)
    if not core.startswith("At "):
        return -1
    var rest = String(core.removeprefix("At "))
    var parts = rest.split(":", 2)
    if len(parts) < 2:
        return -1
    return _parse_uint(String(parts[1]))


def _test_fail_row(t: TestResult) -> _AnnotationRow:
    """The per-test FAIL row: `<node id>: <first assertion line>`, `line=`
    only when that line carries one. Pure; never raises.
    """
    var node_id = t.node.render()
    var first = _first_line(t.detail)
    var line = _detail_line_number(first)
    return _AnnotationRow(
        sort_key=node_id,
        has_file=True,
        file=t.node.path,
        has_line=line >= 0,
        line=line if line >= 0 else 0,
        message=node_id + ": " + first,
    )


# --- Crash-class / file-level failure ---------------------------------------


def _signal_name(signo: Int) -> String:
    """The `"SIGNAME, description"` words for a common terminating signal, or
    `""` outside that set. Pure; mirrors `console.mojo`'s table (this module
    does not import console — a small duplicated lookup table costs far less
    than a cross-reporter coupling)."""
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


def _is_file_level_crash_class(o: Outcome) -> Bool:
    """Whether `o` is a whole-file abnormal outcome with no per-test rows.

    Exactly the failing outcomes other than FAIL (which is covered by its own
    `TestReported` rows) and PRECOMPILE_ERROR (which is session-level, not
    per-file, and rendered by `_precompile_row` instead). Pure; total.
    """
    return (
        o.is_failing() and o != Outcome.FAIL and o != Outcome.PRECOMPILE_ERROR
    )


def _outcome_words(e: Event) -> String:
    """The crash-class outcome named in words, from typed event fields only.

    Pure; total over the outcomes `_is_file_level_crash_class` accepts.
    """
    if e.outcome == Outcome.CRASH:
        var name = _signal_name(e.signal_number)
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


def _file_level_row(e: Event) -> _AnnotationRow:
    """The crash-class/file-level row for one abnormal `FileFinished`. Pure."""
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
    """The FLAKY row: `<path>: flaky — passed on attempt K of N`. Pure."""
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


def _precompile_ending_words(e: Event) -> String:
    """How the step's final attempt ended, in words, or `""` if unknown.

    Reads the decomposed exec-layer termination kinds the event carries (0
    EXITED, 1 SIGNALED, 2 TIMED_OUT, 3 SPAWN_FAILED) — mirrors
    `console.mojo`'s `_precompile_ending_phrase` in spirit, kept as its own
    small copy rather than a cross-reporter import. Pure.
    """
    if not e.ending_known:
        return String("")
    if e.term_kind == 1:
        var name = _signal_name(e.term_value)
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


def _precompile_row(e: Event) -> _AnnotationRow:
    """The precompile-failure row: NO `file=` property (a step-level fact, not
    a file-level one). Pure."""
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
    """`, <n> <label>` for a nonzero count, else `""`. Pure; never raises."""
    if count == 0:
        return String("")
    return ", " + String(count) + " " + label


def _fmt_one_decimal(x: Float64) -> String:
    """`x` rendered with exactly one fractional digit. Pure; never raises.

    Durations here are always nonnegative; a simple scale-round-split avoids
    depending on the default float formatting, which is not fixed-precision.
    """
    if not (x > 0.0):
        return String("0.0")
    var tenths = Int(x * 10.0 + 0.5)
    var whole = tenths // 10
    var frac = tenths % 10
    return String(whole) + "." + String(frac)


def _notice_message(e: Event) -> String:
    """The one-line run summary: the same facts `console.mojo`'s summary band
    carries, composed independently (no shared state, no ANSI, no framing).
    Pure.
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

    `escaped` is already valid UTF-8 (the GH escapers only ever replace single
    ASCII bytes with ASCII escape sequences, never touching a multi-byte
    sequence), so the cut walks whole codepoints via `codepoint_slices()` — a
    plain byte-offset cut could otherwise split one in half and produce
    invalid UTF-8. Pure; never raises.
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
    """`raw` escaped for a workflow-command MESSAGE payload, then bounded.

    The ONLY escaping path (`gh_escape_message`), applied before the byte
    bound is measured — the bound is STABLE-INTENT on the ESCAPED length.
    Pure.
    """
    return _bound_escaped(gh_escape_message(raw), _MESSAGE_MAX_BYTES)


# --- Sort, cap, and assemble one command kind's rows -------------------------


def _less(a: String, b: String) -> Bool:
    """Bytewise lexicographic `a < b`. Pure; total; never raises."""
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
    """In-place insertion sort of `rows` by `sort_key`. Never raises.

    Row counts are small (one run's worth of failures/flaky files), so an
    O(n^2) insertion sort keeps this dependency-free and trivially stable —
    it is not on any hot path.
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
    """The rollup line replacing the rows past `cap - 1`. Pure."""
    var cmd = "warning" if is_warning else "error"
    var noun = "warnings" if is_warning else "errors"
    var msg = "... and " + String(remaining) + " more " + noun
    return "::" + cmd + "::" + _escaped_message(msg)


def _render_capped(
    var rows: List[_AnnotationRow], is_warning: Bool, cap: Int
) -> List[String]:
    """Node-id-sort `rows`, then cap at `cap` with cap-minus-one + aggregate.

    At or under `cap` rows, every row renders individually, in sorted order.
    Past `cap`, the first `cap - 1` sorted rows render individually and ONE
    aggregate line replaces the rest, so the total line count never exceeds
    `cap`. Pure; never raises.
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


def render_annotations(events: List[Event]) -> List[String]:
    """The complete, ordered GitHub Actions annotation lines for one run.

    Pure: `List[Event] -> List[String]`, no I/O, no sink, never raises. Walks
    `events` once, in emission order, building the per-shape rows above (the
    only cross-event fact this needs is a FLAKY row's `attempts_planned`,
    reconciled from the most recent `AttemptFinished` for the SAME file since
    its last `FileStarted` — never a console-text parse or an invented session
    side channel). Returns the node-id-sorted, capped `::error` lines, then
    the node-id-sorted, capped `::warning` lines, then the single `::notice`
    line when a `SessionFinished` was seen (never capped, never more than
    one).

    Args:
        events: The run's event stream, in emission order. Not mutated.

    Returns:
        The ordered workflow-command lines, ready to print one per line.
    """
    var error_rows = List[_AnnotationRow]()
    var warning_rows = List[_AnnotationRow]()
    var has_notice = False
    var notice_message = String("")
    var pending_attempts_planned = -1

    for e in events:
        if e.kind == EventKind.FILE_STARTED:
            pending_attempts_planned = -1
        elif e.kind == EventKind.ATTEMPT_FINISHED:
            pending_attempts_planned = e.attempts_planned
        elif e.kind == EventKind.TEST_REPORTED:
            if e.test.outcome == Outcome.FAIL:
                error_rows.append(_test_fail_row(e.test))
        elif e.kind == EventKind.FILE_FINISHED:
            if _is_file_level_crash_class(e.outcome):
                error_rows.append(_file_level_row(e))
            if e.flaky:
                var planned = (
                    pending_attempts_planned if pending_attempts_planned
                    > 0 else e.attempts_used
                )
                warning_rows.append(
                    _flaky_row(e.path, e.attempts_used, planned)
                )
            pending_attempts_planned = -1
        elif e.kind == EventKind.PRECOMPILE_FAILED:
            error_rows.append(_precompile_row(e))
        elif e.kind == EventKind.SESSION_FINISHED:
            has_notice = True
            notice_message = _notice_message(e)

    var out = _render_capped(error_rows^, False, _MAX_ERRORS)
    var warning_lines = _render_capped(warning_rows^, True, _MAX_WARNINGS)
    for i in range(len(warning_lines)):
        out.append(warning_lines[i])
    if has_notice:
        out.append("::notice::" + _escaped_message(notice_message))
    return out^
