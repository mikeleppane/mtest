"""The pure NDJSON event serializer: one `Event` to one machine line.

The machine-readable twin of the console reporter. Where the console renders
English, this turns each landed `Event` into exactly one NDJSON object line and
produces the one-line stream header, so a second consumer recovers every fact
the session emitted without parsing prose. It is a pure serializer — `Event` to
`String`, plus a header `String` — with no I/O and no sink; the caller writes
the lines later.

The mapping is mechanical: every event object opens with
`"event":"<snake_case_kind>"` and then mirrors the landed model's payload
fields one to one under their model field names, with a single naming
exception. Every `*_seconds` duration becomes an integer-microsecond `*_us`
field, because the v1 stream carries no floating-point values at all, so a
strict consumer never sees a NaN, an Infinity, or a lossy float. Counts and
indices are plain integers; the closed-vocabulary types (`Outcome`,
`ParseDisposition`, `AttributionDisposition`) serialize as their frozen
lowercase string tokens; booleans serialize as `true`/`false`.

No single line grows without limit, but the bound is not applied in one place.
Most variable-length fields are bounded here at serialization: the captured
streams and the long text fields become a head window plus a tail window with a
visible elision marker between, and each such field rides beside omission
metadata computed here — a retained-byte count, an omitted-byte count, or an
omitted-entry count — rather than a parsed human truncation marker or an
inferred original total. The exception is `attempt_finished`, whose captured
streams the session already clamped when it built the event; those serialize
whole, carrying the event's own `*_truncated` markers.

Every string value is escaped through the shared `json_escape_string`, and
every value that originates as raw child-process bytes is first decoded through
the shared `lossy_utf8` so it is valid UTF-8 before escaping. There is no
second escaper and no second lossy path here.
"""
from mtest.config.lossy_utf8 import lossy_utf8
from mtest.model.attribution import AttributionDisposition
from mtest.model.events import (
    AttemptFinishedPayload,
    CollectionKnownPayload,
    CrashAttributionPayload,
    Event,
    EventKind,
    FileFinishedPayload,
    FileStartedPayload,
    InternalErrorPayload,
    PrecompileFailedPayload,
    SessionFinishedPayload,
    SessionStartedPayload,
    Summary,
    TestReportedPayload,
    WarningPayload,
)
from mtest.model.outcome import Outcome
from mtest.model.parse_disposition import ParseDisposition
from mtest.report.escape import json_escape_string

# --- Serialization bounds ---------------------------------------------------
# The captured-stream head/tail windows match the session's attempt-excerpt
# capture bound (64 KiB head + 64 KiB tail); this layer cannot import the
# session constant (that layer sits above and imports this one), so the value
# is restated here with the same meaning.
comptime _STREAM_HEAD = 65536
comptime _STREAM_TAIL = 65536
comptime _TEXT_HEAD = 65536
comptime _TEXT_TAIL = 65536
comptime _ARGV_LIST_MAX = 256
comptime _RUNNER_STRING_MAX = 4096
# A capped runner string is kept as a head+tail window (summing to
# _RUNNER_STRING_MAX retained bytes) with the visible elision marker between,
# so a truncated value is never silently cut.
comptime _RUNNER_HEAD_MAX = 3072
comptime _RUNNER_TAIL_MAX = 1024

comptime _US_PER_SEC = 1_000_000
comptime _I64_MAX = 9223372036854775807
"""The saturation ceiling for a microsecond count (2**63 - 1)."""

comptime _ELISION: StaticString = "…"
"""The visible marker placed between a kept head window and tail window."""


# --- Scalar conversions -----------------------------------------------------


def _b(v: Bool) -> StaticString:
    """`true`/`false` for a JSON boolean."""
    return "true" if v else "false"


def _seconds_to_us(seconds: Float64) -> Int:
    """A `Float64` second duration as integer microseconds.

    Clamps a negative or NaN input to 0, rounds half away from zero to the
    nearest microsecond, and saturates at the integer maximum. The v1 stream
    carries no floating-point values, so every duration passes through here.
    """
    if not (seconds > 0.0):
        return 0
    var us = seconds * Float64(_US_PER_SEC)
    if us >= Float64(_I64_MAX):
        return _I64_MAX
    # Positive domain: truncation toward zero of `us + 0.5` is floor(us + 0.5),
    # i.e. round-half-up, which equals round-half-away-from-zero here.
    return Int(us + 0.5)


def _timeout_us(seconds: Int) -> Int:
    """An integer-second timeout as integer microseconds.

    Clamps a negative input to 0 and saturates at the integer maximum. The
    input is already an integer count of seconds, so the conversion is exact.
    """
    if seconds <= 0:
        return 0
    if seconds > _I64_MAX // _US_PER_SEC:
        return _I64_MAX
    return seconds * _US_PER_SEC


def _outcome_token(o: Outcome) -> StaticString:
    """The frozen lowercase token for an outcome value, total over the enum."""
    if o == Outcome.PASS:
        return "pass"
    if o == Outcome.FAIL:
        return "fail"
    if o == Outcome.SKIP:
        return "skip"
    if o == Outcome.CRASH:
        return "crash"
    if o == Outcome.TIMEOUT:
        return "timeout"
    if o == Outcome.COMPILE_ERROR:
        return "compile_error"
    if o == Outcome.COMPILE_TIMEOUT:
        return "compile_timeout"
    if o == Outcome.MALFORMED_SUITE:
        return "malformed_suite"
    if o == Outcome.PRECOMPILE_ERROR:
        return "precompile_error"
    if o == Outcome.FLAKY:
        return "flaky"
    if o == Outcome.DESELECTED:
        return "deselected"
    if o == Outcome.EXCLUDED:
        return "excluded"
    return "not_run"


def _parse_disposition_token(d: ParseDisposition) -> StaticString:
    """The frozen lowercase token for a disposition, total over the enum."""
    if d == ParseDisposition.PARSED:
        return "parsed"
    if d == ParseDisposition.NO_REPORT:
        return "no_report"
    if d == ParseDisposition.AMBIGUOUS:
        return "ambiguous"
    if d == ParseDisposition.DRIFT:
        return "drift"
    return "capture_overflow"


def _attribution_disposition_token(d: AttributionDisposition) -> StaticString:
    """The frozen lowercase token for a disposition, total over the enum."""
    if d == AttributionDisposition.ATTRIBUTED:
        return "attributed"
    if d == AttributionDisposition.NO_REPRODUCTION:
        return "no_reproduction"
    if d == AttributionDisposition.PROBE_FAILED:
        return "probe_failed"
    if d == AttributionDisposition.RUN_CAP:
        return "run_cap"
    return "time_budget"


# --- Bounded text/byte helpers ----------------------------------------------


@fieldwise_init
struct _Excerpt(Copyable, Movable):
    """A bounded field's escaped inline value plus its omitted-byte count.

    `escaped` is ready to place between JSON quotes; `omitted` is how many
    middle bytes the head+tail bound dropped (0 when the whole value fit).
    """

    var escaped: String
    var omitted: Int


def _string_bytes(s: String) -> List[UInt8]:
    """A copy of `s`'s UTF-8 bytes as an owned list."""
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _cap_runner_excerpt(s: String) -> _Excerpt:
    """A runner-authored string bounded to a head and tail window, escaped.

    Most runner-authored strings — toolchain, labels, short paths — are never
    realistically long, so the bound is a formality that keeps a pathological
    value from unbounding a line. Some are not: `build_argv` and `attempt_argv`
    elements carry user-supplied build arguments and can be arbitrarily long.
    A value over `_RUNNER_STRING_MAX` bytes is therefore kept as a head plus
    tail window joined by the visible elision marker rather than silently cut,
    and the count of dropped middle bytes rides alongside for callers that
    surface it (the list serializers aggregate it into `*_omitted_bytes`).

    Each window is decoded through `lossy_utf8` independently, so a split
    multi-byte sequence degrades to U+FFFD instead of producing invalid UTF-8.
    """
    return _excerpt_string(s, _RUNNER_HEAD_MAX, _RUNNER_TAIL_MAX)


def _cap_runner_string(s: String) -> String:
    """A scalar runner field's bounded, JSON-escaped inline value.

    The escaped value from `_cap_runner_excerpt`. A scalar field signals its
    own truncation through the visible elision marker in the value; these
    fields are formality-capped and carry no separate omitted-byte count.
    """
    return _cap_runner_excerpt(s).escaped


def _excerpt_bytes(data: List[UInt8], head_max: Int, tail_max: Int) -> _Excerpt:
    """Bound raw bytes to a head and tail window, decode, and escape.

    When the data fits, the whole lossy-decoded, escaped value rides with an
    omitted count of 0. Otherwise the first `head_max` and last `tail_max`
    bytes are kept, joined by the elision marker, and the dropped middle-byte
    count is reported. The bound applies to the raw bytes, before escaping, and
    each window is decoded independently so a sequence split at either boundary
    degrades to U+FFFD rather than swallowing the marker.
    """
    var n = len(data)
    if n <= head_max + tail_max:
        return _Excerpt(json_escape_string(lossy_utf8(data)), 0)
    var head = List[UInt8]()
    for i in range(head_max):
        head.append(data[i])
    var tail = List[UInt8]()
    for i in range(n - tail_max, n):
        tail.append(data[i])
    var combined = lossy_utf8(head) + _ELISION + lossy_utf8(tail)
    return _Excerpt(json_escape_string(combined), n - head_max - tail_max)


def _excerpt_string(s: String, head_max: Int, tail_max: Int) -> _Excerpt:
    """Bound an already-UTF-8 string to a head and tail window.

    The same bound as `_excerpt_bytes`, applied over the string's UTF-8 bytes,
    so a long runner-authored or captured-then-decoded field is kept as a head
    window plus a tail window with the dropped-byte count reported.
    """
    return _excerpt_bytes(_string_bytes(s), head_max, tail_max)


@fieldwise_init
struct _ArrayResult(Copyable, Movable):
    """A bounded list serialized as a JSON array plus its omission counts.

    `text` is the complete `[...]` array literal. `omitted` is how many entries
    past the list cap were dropped, 0 when the whole list fit. `omitted_bytes`
    is the total bytes elided from the kept entries by the per-element head and
    tail bound, 0 when every kept entry fit, so a consumer can detect and
    quantify per-element truncation of user-supplied values and not just
    dropped entries.
    """

    var text: String
    var omitted: Int
    var omitted_bytes: Int


def _string_array(items: List[String]) -> _ArrayResult:
    """A bounded JSON array of runner-authored strings.

    The list is capped at `_ARGV_LIST_MAX` entries, and each kept entry goes
    through `_cap_runner_excerpt`, so an element over `_RUNNER_STRING_MAX`
    bytes is kept as a head plus tail window. The count of entries dropped past
    the list cap and the total bytes elided from the kept entries both ride
    beside the array as its omission metadata.
    """
    var n = len(items)
    var kept = n if n <= _ARGV_LIST_MAX else _ARGV_LIST_MAX
    var text = String("[")
    var omitted_bytes = 0
    for i in range(kept):
        if i > 0:
            text += ","
        var element = _cap_runner_excerpt(items[i])
        text += '"' + element.escaped + '"'
        omitted_bytes += element.omitted
    text += "]"
    var omitted = 0 if n <= _ARGV_LIST_MAX else n - _ARGV_LIST_MAX
    return _ArrayResult(text^, omitted, omitted_bytes)


# --- Public surface ---------------------------------------------------------


def stream_header(version: String) -> String:
    """The frozen first line of an NDJSON stream.

    Exactly `{"event":"stream","version":1,"generator":"mtest <version>"}`. The
    stream format integer is frozen at 1 and lives only here.

    Args:
        version: The build's mtest version label, passed in by the caller the
            same way the console reporter receives it so this module depends on
            no higher layer. JSON-escaped into the `generator` field.

    Returns:
        The complete header line, without a trailing newline.
    """
    return (
        '{"event":"stream","version":1,"generator":"mtest '
        + json_escape_string(version)
        + '"}'
    )


def serialize_event(e: Event) -> String:
    """One `Event` as one NDJSON object line.

    Dispatches on the event kind and mirrors that kind's landed payload fields.

    Args:
        e: The event to serialize.

    Returns:
        A single complete JSON object, without the trailing newline that
        delimits it in the stream; the caller appends that. An empty string
        for an `EventKind` with no serializer, which cannot happen while the
        vocabulary stays closed.
    """
    if e.kind == EventKind.SESSION_STARTED:
        return _session_started(e.data[SessionStartedPayload])
    if e.kind == EventKind.WARNING:
        return _warning(e.data[WarningPayload])
    if e.kind == EventKind.PRECOMPILE_FAILED:
        return _precompile_failed(e.data[PrecompileFailedPayload])
    if e.kind == EventKind.FILE_STARTED:
        return _file_started(e.data[FileStartedPayload])
    if e.kind == EventKind.FILE_FINISHED:
        return _file_finished(e.data[FileFinishedPayload])
    if e.kind == EventKind.ATTEMPT_FINISHED:
        return _attempt_finished(e.data[AttemptFinishedPayload])
    if e.kind == EventKind.CRASH_ATTRIBUTION:
        return _crash_attribution(e.data[CrashAttributionPayload])
    if e.kind == EventKind.COLLECTION_KNOWN:
        return _collection_known(e.data[CollectionKnownPayload])
    if e.kind == EventKind.INTERNAL_ERROR:
        return _internal_error(e.data[InternalErrorPayload])
    if e.kind == EventKind.TEST_REPORTED:
        return _test_reported(e.data[TestReportedPayload])
    if e.kind == EventKind.SESSION_FINISHED:
        return _session_finished(e.data[SessionFinishedPayload])
    # Unreachable: the EventKind vocabulary is closed and every kind is handled
    # above. Returning an empty (invalid) line rather than mislabeling an
    # unhandled kind as a session_finished record means a future kind added
    # without its own serializer surfaces loudly to the strict consumer instead
    # of being silently misencoded.
    return String("")


# --- Per-kind serializers ---------------------------------------------------


def _session_started(p: SessionStartedPayload) -> String:
    var s = String('{"event":"session_started"')
    s += ',"root":"' + _cap_runner_string(p.root) + '"'
    s += ',"toolchain":"' + _cap_runner_string(p.toolchain) + '"'
    s += ',"selected_count":' + String(p.selected_count)
    s += ',"excluded_count":' + String(p.excluded_count)
    s += ',"shard_label":"' + _cap_runner_string(p.shard_label) + '"'
    s += ',"sharded_out_count":' + String(p.sharded_out_count)
    s += "}"
    return s^


def _warning(p: WarningPayload) -> String:
    var s = String('{"event":"warning"')
    s += ',"warning_kind":"' + _cap_runner_string(p.warning_kind) + '"'
    s += ',"warning_pattern":"' + _cap_runner_string(p.warning_pattern) + '"'
    s += "}"
    return s^


def _precompile_failed(p: PrecompileFailedPayload) -> String:
    var out = _excerpt_string(p.compiler_output, _TEXT_HEAD, _TEXT_TAIL)
    var cas = _string_array(p.casualties)
    var s = String('{"event":"precompile_failed"')
    s += ',"step":"' + _cap_runner_string(p.step) + '"'
    s += ',"compiler_output":"' + out.escaped + '"'
    s += ',"compiler_output_omitted_bytes":' + String(out.omitted)
    s += ',"casualty_count":' + String(p.casualty_count)
    s += ',"casualties":' + cas.text
    s += ',"casualties_omitted":' + String(cas.omitted)
    s += ',"casualties_omitted_bytes":' + String(cas.omitted_bytes)
    s += ',"ending_known":' + _b(p.ending_known)
    s += ',"term_kind":' + String(p.term_kind)
    s += ',"term_value":' + String(p.term_value)
    s += ',"escalated":' + _b(p.escalated)
    s += ',"timeout_us":' + String(_timeout_us(p.timeout_seconds))
    s += ',"attempts_used":' + String(p.attempts_used)
    s += "}"
    return s^


def _file_started(p: FileStartedPayload) -> String:
    var s = String('{"event":"file_started"')
    s += ',"path":"' + _cap_runner_string(p.path) + '"'
    s += "}"
    return s^


def _file_finished(p: FileFinishedPayload) -> String:
    var argv = _string_array(p.build_argv)
    var out = _excerpt_bytes(p.captured_stdout, _STREAM_HEAD, _STREAM_TAIL)
    var err = _excerpt_bytes(p.captured_stderr, _STREAM_HEAD, _STREAM_TAIL)
    var s = String('{"event":"file_finished"')
    s += ',"path":"' + _cap_runner_string(p.path) + '"'
    s += ',"outcome":"' + String(_outcome_token(p.outcome)) + '"'
    s += ',"duration_us":' + String(_seconds_to_us(p.duration_seconds))
    s += ',"build_argv":' + argv.text
    s += ',"build_argv_omitted":' + String(argv.omitted)
    s += ',"build_argv_omitted_bytes":' + String(argv.omitted_bytes)
    s += ',"build_duration_us":' + String(
        _seconds_to_us(p.build_duration_seconds)
    )
    s += ',"captured_stdout":"' + out.escaped + '"'
    s += ',"stdout_capture_bytes":' + String(len(p.captured_stdout))
    s += ',"stdout_stream_omitted_bytes":' + String(out.omitted)
    s += ',"captured_stderr":"' + err.escaped + '"'
    s += ',"stderr_capture_bytes":' + String(len(p.captured_stderr))
    s += ',"stderr_stream_omitted_bytes":' + String(err.omitted)
    s += ',"stdout_truncated":' + _b(p.stdout_truncated)
    s += ',"stderr_truncated":' + _b(p.stderr_truncated)
    s += ',"signal_number":' + String(p.signal_number)
    s += ',"exit_status":' + String(p.exit_status)
    s += ',"timeout_us":' + String(_timeout_us(p.timeout_seconds))
    s += (
        ',"exclusion_pattern":"' + _cap_runner_string(p.exclusion_pattern) + '"'
    )
    s += (
        ',"parse_disposition":"'
        + String(_parse_disposition_token(p.parse_disposition))
        + '"'
    )
    s += ',"passed_tests":' + String(p.passed_tests)
    s += ',"failed_tests":' + String(p.failed_tests)
    s += ',"skipped_tests":' + String(p.skipped_tests)
    s += ',"deselected_tests":' + String(p.deselected_tests)
    s += ',"attempts_used":' + String(p.attempts_used)
    s += ',"flaky":' + _b(p.flaky)
    s += ',"slow":' + _b(p.slow)
    s += ',"escalated":' + _b(p.escalated)
    s += "}"
    return s^


def _attempt_finished(p: AttemptFinishedPayload) -> String:
    # Attempt excerpts are already bounded at construction (the session clamps
    # each non-final attempt's streams to a head+tail window before building the
    # event), so they serialize whole; their `*_truncated` markers still ride.
    var out = json_escape_string(lossy_utf8(p.captured_stdout))
    var err = json_escape_string(lossy_utf8(p.captured_stderr))
    var argv = _string_array(p.attempt_argv)
    var s = String('{"event":"attempt_finished"')
    s += ',"path":"' + _cap_runner_string(p.path) + '"'
    s += ',"step":"' + _cap_runner_string(p.step) + '"'
    s += ',"attempt_index":' + String(p.attempt_index)
    s += ',"attempts_planned":' + String(p.attempts_planned)
    s += ',"term_kind":' + String(p.term_kind)
    s += ',"term_value":' + String(p.term_value)
    s += ',"term_final_kind":' + String(p.term_final_kind)
    s += ',"term_final_value":' + String(p.term_final_value)
    s += ',"escalated":' + _b(p.escalated)
    s += ',"retry_eligible":' + _b(p.retry_eligible)
    s += ',"classification":"' + _cap_runner_string(p.classification) + '"'
    s += ',"duration_us":' + String(_seconds_to_us(p.duration_seconds))
    s += ',"captured_stdout":"' + out + '"'
    s += ',"captured_stderr":"' + err + '"'
    s += ',"stdout_truncated":' + _b(p.stdout_truncated)
    s += ',"stderr_truncated":' + _b(p.stderr_truncated)
    s += ',"attempt_argv":' + argv.text
    s += ',"attempt_argv_omitted":' + String(argv.omitted)
    s += ',"attempt_argv_omitted_bytes":' + String(argv.omitted_bytes)
    s += "}"
    return s^


def _crash_attribution(p: CrashAttributionPayload) -> String:
    var s = String('{"event":"crash_attribution"')
    s += ',"path":"' + _cap_runner_string(p.path) + '"'
    s += (
        ',"attribution_disposition":"'
        + String(_attribution_disposition_token(p.attribution_disposition))
        + '"'
    )
    s += ',"culprit_test":"' + _cap_runner_string(p.culprit_test) + '"'
    s += ',"isolation_reruns":' + String(p.isolation_reruns)
    s += ',"attribution_us":' + String(_seconds_to_us(p.attribution_seconds))
    s += "}"
    return s^


def _collection_known(p: CollectionKnownPayload) -> String:
    var s = String('{"event":"collection_known"')
    s += ',"selected_test_total":' + String(p.selected_test_total)
    s += ',"deselected_test_total":' + String(p.deselected_test_total)
    s += "}"
    return s^


def _internal_error(p: InternalErrorPayload) -> String:
    var s = String('{"event":"internal_error"')
    s += ',"step":"' + _cap_runner_string(p.step) + '"'
    s += ',"program":"' + _cap_runner_string(p.program) + '"'
    s += ',"errno":' + String(p.errno)
    s += "}"
    return s^


def _test_reported(p: TestReportedPayload) -> String:
    var detail = _excerpt_string(p.test.detail, _TEXT_HEAD, _TEXT_TAIL)
    var s = String('{"event":"test_reported"')
    s += ',"path":"' + _cap_runner_string(p.test.node.path) + '"'
    s += ',"name":"' + _cap_runner_string(p.test.node.name) + '"'
    s += ',"outcome":"' + String(_outcome_token(p.test.outcome)) + '"'
    s += ',"detail":"' + detail.escaped + '"'
    s += ',"detail_omitted_bytes":' + String(detail.omitted)
    s += ',"timing":"' + _cap_runner_string(p.test.timing) + '"'
    s += "}"
    return s^


def _summary_object(summary: Summary) -> String:
    var s = String("{")
    for code in range(Outcome.COUNT):
        if code > 0:
            s += ","
        s += (
            '"'
            + String(_outcome_token(Outcome(code)))
            + '":'
            + String(summary.counts[code])
        )
    s += "}"
    return s^


def _session_finished(p: SessionFinishedPayload) -> String:
    var s = String('{"event":"session_finished"')
    s += ',"summary":' + _summary_object(p.summary)
    s += ',"wall_time_us":' + String(_seconds_to_us(p.wall_time_seconds))
    s += ',"exit_code":' + String(p.exit_code)
    s += ',"test_counts":{"passed":' + String(p.test_counts.passed)
    s += ',"failed":' + String(p.test_counts.failed)
    s += ',"skipped":' + String(p.test_counts.skipped)
    s += ',"deselected":' + String(p.test_counts.deselected)
    s += "}"
    s += ',"flaky_files":' + String(p.flaky_files)
    s += "}"
    return s^
