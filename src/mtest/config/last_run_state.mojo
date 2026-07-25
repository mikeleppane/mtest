"""Pure last-run state bytes, verdict deltas, and preservation merging.

Layer 1 owns the internal line codec and the merge policy. This module reads no
file, prints nothing, emits no event, and imports only the Layer 0 model.
"""
from std.builtin.sort import sort

from mtest.model import NodeId, Outcome, split_node_token


comptime _HEADER: StaticString = "mtest-lastrun v1"
comptime _DIAGNOSTIC_TEXT_LIMIT = 160


@fieldwise_init
struct LastRunRecordKind(Equatable, ImplicitlyCopyable, Movable):
    """The typed identifier scope of one persisted failure record."""

    var value: Int
    """The stable integer discriminant."""

    comptime FILE = Self(0)
    """A root-relative file identifier."""

    comptime TEST = Self(1)
    """A canonical `path::name` node identifier."""

    def __eq__(self, other: Self) -> Bool:
        """Whether both values name the same record scope."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether both values name different record scopes."""
        return self.value != other.value

    def is_file(self) -> Bool:
        """Whether this is the file-record kind."""
        return self == Self.FILE

    def is_test(self) -> Bool:
        """Whether this is the test-record kind."""
        return self == Self.TEST


@fieldwise_init
struct LastRunRecord(Copyable, Movable):
    """One typed failing file or test identifier."""

    var kind: LastRunRecordKind
    """Whether `identifier` names a file or test."""

    var identifier: String
    """The root-relative path or canonical node id."""

    @staticmethod
    def file(path: String) -> Self:
        """Build a file-scoped record.

        Args:
            path: The root-relative file path. Not mutated.

        Returns:
            A newly allocated file record.
        """
        return Self(LastRunRecordKind.FILE, path)

    @staticmethod
    def test(var node: NodeId) -> Self:
        """Build a test-scoped record from a typed node id.

        Args:
            node: The test identity. Consumed.

        Returns:
            A newly allocated test record.
        """
        return Self(LastRunRecordKind.TEST, node.render())


@fieldwise_init
struct LastRunState(Copyable, Movable):
    """The logical set of persisted failure records."""

    var records: List[LastRunRecord]
    """The records; codec output canonicalizes their order and duplicates."""

    @staticmethod
    def empty() -> Self:
        """Build an empty logical state.

        Returns:
            A freshly allocated state with no records.
        """
        return Self(records=[])


@fieldwise_init
struct LastRunDiagnosticKind(Equatable, ImplicitlyCopyable, Movable):
    """One nonfatal codec diagnostic class."""

    var value: Int
    """The stable integer discriminant."""

    comptime HEADER = Self(0)
    """The complete input was rejected because its header was not v1."""

    comptime RECORD = Self(1)
    """One malformed record was dropped while other records continued."""

    def __eq__(self, other: Self) -> Bool:
        """Whether both values name the same diagnostic class."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether both values name different diagnostic classes."""
        return self.value != other.value

    def is_header(self) -> Bool:
        """Whether the whole-file header was rejected."""
        return self == Self.HEADER

    def is_record(self) -> Bool:
        """Whether one individual record was dropped."""
        return self == Self.RECORD


@fieldwise_init
struct LastRunDiagnostic(Copyable, Movable):
    """One bounded, C0-safe, caller-rendered codec diagnostic."""

    var kind: LastRunDiagnosticKind
    """Whether the header or one record was rejected."""

    var source: String
    """The bounded, C0-safe source label."""

    var line: Int
    """The one-based source line, or zero when no line applies."""

    var message: String
    """The bounded, C0-safe explanation."""

    def render(self) -> String:
        """Render the diagnostic as exactly one physical line.

        Returns:
            Newly allocated stable framing containing only contained fields.
        """
        var location = self.source
        if self.line > 0:
            location += ":" + String(self.line)
        return "state: " + location + ": " + self.message


@fieldwise_init
struct LastRunEncodeResult(Copyable, Movable):
    """Canonical v1 text plus nonfatal dropped-record diagnostics."""

    var text: String
    """The canonical v1 bytes represented as a Mojo string."""

    var diagnostics: List[LastRunDiagnostic]
    """One contained diagnostic per dropped invalid record."""


@fieldwise_init
struct LastRunParseResult(Copyable, Movable):
    """A parsed logical state plus nonfatal typed diagnostics."""

    var state: LastRunState
    """The accepted valid records, or empty after a header rejection."""

    var diagnostics: List[LastRunDiagnostic]
    """Header rejection or individual dropped-record diagnostics."""


@fieldwise_init
struct StateDelta(Copyable, Movable):
    """Fresh observations and failures, kept distinct for preservation."""

    var observed_tests: List[String]
    """Exact node ids that received a test verdict."""

    var observed_files: List[String]
    """Exact files that received a file-level verdict."""

    var fully_observed_files: List[String]
    """Files whose entire collected test universe received normal verdicts."""

    var terminal_files: List[String]
    """Files replaced by a terminal file-level abnormal verdict."""

    var failures: List[LastRunRecord]
    """Fresh failing records, separate from clearing observations."""

    @staticmethod
    def empty() -> Self:
        """Build a delta with no fresh verdicts.

        Returns:
            A freshly allocated empty delta.
        """
        return Self(
            observed_tests=[],
            observed_files=[],
            fully_observed_files=[],
            terminal_files=[],
            failures=[],
        )

    def observe_test(mut self, var node: NodeId, outcome: Outcome):
        """Fold one normalized per-test outcome into this delta.

        PASS, SKIP, and FLAKY clear an exact prior test failure. FAIL clears
        and rewrites that test. File-level abnormalities defensively replace
        the node's whole file. Internal non-verdict outcomes and the event-only
        PRECOMPILE_ERROR change nothing.

        Args:
            node: The observed test identity. Consumed.
            outcome: Its normalized outcome.
        """
        if (
            outcome == Outcome.DESELECTED
            or outcome == Outcome.EXCLUDED
            or outcome == Outcome.NOT_RUN
            or outcome == Outcome.PRECOMPILE_ERROR
        ):
            return
        if (
            outcome == Outcome.CRASH
            or outcome == Outcome.TIMEOUT
            or outcome == Outcome.COMPILE_ERROR
            or outcome == Outcome.COMPILE_TIMEOUT
            or outcome == Outcome.MALFORMED_SUITE
        ):
            self._observe_terminal_file(node.path)
            return
        if (
            outcome != Outcome.PASS
            and outcome != Outcome.FAIL
            and outcome != Outcome.SKIP
            and outcome != Outcome.FLAKY
        ):
            return
        var identifier = node.render()
        _append_string_once(self.observed_tests, identifier)
        if outcome == Outcome.FAIL:
            _append_record_once(
                self.failures,
                LastRunRecord(LastRunRecordKind.TEST, identifier),
            )

    def observe_file(
        mut self,
        path: String,
        outcome: Outcome,
        *,
        fully_observed: Bool,
    ):
        """Fold one normalized file outcome into this delta.

        A normal file FAIL is an aggregate over per-test facts and therefore
        persists no file record; its failing tests arrive through
        `observe_test`. A terminal abnormal outcome replaces the whole file.
        Internal non-verdict outcomes and the event-only PRECOMPILE_ERROR
        change nothing.

        Args:
            path: The root-relative file path. Not mutated.
            outcome: Its normalized file outcome.
            fully_observed: Whether every collected test in the file received
                a verdict, allowing all stale test records to clear.
        """
        if (
            outcome == Outcome.DESELECTED
            or outcome == Outcome.EXCLUDED
            or outcome == Outcome.NOT_RUN
            or outcome == Outcome.PRECOMPILE_ERROR
        ):
            return
        if (
            outcome == Outcome.CRASH
            or outcome == Outcome.TIMEOUT
            or outcome == Outcome.COMPILE_ERROR
            or outcome == Outcome.COMPILE_TIMEOUT
            or outcome == Outcome.MALFORMED_SUITE
        ):
            self._observe_terminal_file(path)
            return
        if (
            outcome != Outcome.PASS
            and outcome != Outcome.FAIL
            and outcome != Outcome.SKIP
            and outcome != Outcome.FLAKY
        ):
            return
        _append_string_once(self.observed_files, path)
        if fully_observed:
            _append_string_once(self.fully_observed_files, path)

    def observe_precompile_casualties(mut self, casualties: List[String]):
        """Record one terminal file failure per named precompile casualty.

        Args:
            casualties: Root-relative paths denied a build by the failed step.
                Not mutated.
        """
        for path in casualties:
            self._observe_terminal_file(path)

    def observe_gate(mut self, path: String, *, failed: Bool):
        """Fold one fully observed gate verdict into this delta.

        Args:
            path: The root-relative gate file path. Not mutated.
            failed: Whether the gate failed.
        """
        if failed:
            self._observe_terminal_file(path)
        else:
            _append_string_once(self.observed_files, path)
            _append_string_once(self.fully_observed_files, path)

    def record_sharded_out(mut self, path: String):
        """Keep a sharded-out file outside the observation set.

        Args:
            path: The file omitted by shard ownership. Not mutated.
        """
        _ = path

    def _observe_terminal_file(mut self, path: String):
        """Replace a file with one fresh terminal file-level failure."""
        _append_string_once(self.observed_files, path)
        _append_string_once(self.terminal_files, path)
        _append_record_once(
            self.failures,
            LastRunRecord(LastRunRecordKind.FILE, path),
        )


def _safe_excerpt(text: String) -> String:
    """Escape C0 and DEL controls and bound untrusted diagnostic text."""
    var escaped = String("")
    comptime HEX = "0123456789abcdef"
    for cp in text.codepoints():
        var value = Int(cp)
        if value == 10:
            escaped += "\\n"
        elif value == 13:
            escaped += "\\r"
        elif value == 9:
            escaped += "\\t"
        elif (value >= 0 and value < 32) or value == 127:
            escaped += "\\x"
            escaped += String(HEX[byte=value // 16])
            escaped += String(HEX[byte=value % 16])
        else:
            escaped += String(cp)
    if escaped.count_codepoints() <= _DIAGNOSTIC_TEXT_LIMIT:
        return escaped
    var bounded = String("")
    for cp in escaped.codepoint_slices():
        if bounded.count_codepoints() == _DIAGNOSTIC_TEXT_LIMIT - 3:
            break
        bounded += String(cp)
    return bounded + "..."


def _diagnostic(
    kind: LastRunDiagnosticKind,
    source: String,
    line: Int,
    message: String,
) -> LastRunDiagnostic:
    """Build one bounded and contained diagnostic."""
    return LastRunDiagnostic(
        kind=kind,
        source=_safe_excerpt(source),
        line=line,
        message=_safe_excerpt(message),
    )


def _identifier_has_control(identifier: String) -> Bool:
    """Whether an identifier contains a C0 or DEL control."""
    for cp in identifier.codepoints():
        var value = Int(cp)
        if (value >= 0 and value < 32) or value == 127:
            return True
    return False


def _record_rejection(record: LastRunRecord) -> String:
    """Return an invalid-record reason, or empty when valid."""
    if not record.kind.is_file() and not record.kind.is_test():
        return "unknown record kind"
    if record.identifier.byte_length() == 0:
        return "empty identifier"
    if _identifier_has_control(record.identifier):
        return "identifier contains C0 or DEL control"
    if record.kind.is_test():
        var split = split_node_token(record.identifier)
        if (
            split.sep_count != 1
            or split.file_part.byte_length() == 0
            or split.name_part.byte_length() == 0
        ):
            return "invalid node-id shape"
    return ""


def _same_record(left: LastRunRecord, right: LastRunRecord) -> Bool:
    """Whether two records have equal kind and identifier."""
    return left.kind == right.kind and left.identifier == right.identifier


def _append_record_once(
    mut records: List[LastRunRecord], var candidate: LastRunRecord
):
    """Append a record only when an equal record is absent."""
    for record in records:
        if _same_record(record, candidate):
            return
    records.append(candidate^)


def _append_string_once(mut values: List[String], value: String):
    """Append a string only when an equal value is absent."""
    for existing in values:
        if existing == value:
            return
    values.append(value)


def _record_line(record: LastRunRecord) -> String:
    """Render one already-validated record line without its newline."""
    if record.kind.is_file():
        return "file\t" + record.identifier
    return "test\t" + record.identifier


def encode_last_run_state(
    state: LastRunState, source: String = ".mtest-cache/lastrun"
) -> LastRunEncodeResult:
    """Encode logical state as deterministic canonical v1 text.

    Invalid in-memory records are dropped with diagnostics instead of raising.
    Valid lines sort bytewise by kind and identifier, deduplicate, and end in
    exactly one final newline.

    Args:
        state: The logical state. Not mutated.
        source: The diagnostic source label. Not mutated.

    Returns:
        Newly allocated canonical text plus contained drop diagnostics.
    """
    var lines = List[String]()
    var diagnostics = List[LastRunDiagnostic]()
    for i in range(len(state.records)):
        var rejection = _record_rejection(state.records[i])
        if rejection.byte_length() > 0:
            diagnostics.append(
                _diagnostic(
                    LastRunDiagnosticKind.RECORD,
                    source,
                    # No line: these records are being refused on the way OUT,
                    # so they are in no line of the file. Reporting the record
                    # index as one cited `lastrun:1`, which is the header.
                    0,
                    (
                        "dropped malformed "
                        + _safe_excerpt(state.records[i].identifier)
                        + ": "
                        + rejection
                    ),
                )
            )
            continue
        var line = _record_line(state.records[i])
        var seen = False
        for existing in lines:
            if existing == line:
                seen = True
                break
        if not seen:
            lines.append(line)
    sort(lines)
    var text = String(_HEADER) + "\n"
    for line in lines:
        text += line + "\n"
    return LastRunEncodeResult(text=text, diagnostics=diagnostics^)


def parse_last_run_state(
    text: String, source: String = ".mtest-cache/lastrun"
) -> LastRunParseResult:
    """Parse arbitrary text as v1 state without raising.

    A missing, malformed, or unknown header rejects the whole input. With a
    valid header, each malformed record is independently diagnosed and dropped
    while parsing continues.

    Args:
        text: Arbitrary valid-UTF-8 Mojo text. Not mutated.
        source: The diagnostic source label. Not mutated.

    Returns:
        Newly allocated accepted state plus contained typed diagnostics.
    """
    var lines = text.split("\n")
    if len(lines) == 0 or String(lines[0]) != String(_HEADER):
        var got = String("")
        if len(lines) > 0:
            got = String(lines[0])
        return LastRunParseResult(
            state=LastRunState.empty(),
            diagnostics=[
                _diagnostic(
                    LastRunDiagnosticKind.HEADER,
                    source,
                    1,
                    "expected 'mtest-lastrun v1'; got '" + got + "'",
                )
            ],
        )

    var records = List[LastRunRecord]()
    var diagnostics = List[LastRunDiagnostic]()
    for i in range(1, len(lines)):
        var raw = String(lines[i])
        if i == len(lines) - 1 and raw.byte_length() == 0:
            continue
        var fields = raw.split("\t")
        if len(fields) != 2:
            diagnostics.append(
                _diagnostic(
                    LastRunDiagnosticKind.RECORD,
                    source,
                    i + 1,
                    (
                        "dropped malformed record '"
                        + raw
                        + "': expected kind<TAB>identifier"
                    ),
                )
            )
            continue
        var kind_text = String(fields[0])
        if kind_text != "file" and kind_text != "test":
            diagnostics.append(
                _diagnostic(
                    LastRunDiagnosticKind.RECORD,
                    source,
                    i + 1,
                    "dropped record with unknown kind '" + kind_text + "'",
                )
            )
            continue
        var kind = (
            LastRunRecordKind.FILE if kind_text
            == "file" else LastRunRecordKind.TEST
        )
        var record = LastRunRecord(kind, String(fields[1]))
        var rejection = _record_rejection(record)
        if rejection.byte_length() > 0:
            diagnostics.append(
                _diagnostic(
                    LastRunDiagnosticKind.RECORD,
                    source,
                    i + 1,
                    ("dropped malformed record '" + raw + "': " + rejection),
                )
            )
            continue
        _append_record_once(records, record^)
    return LastRunParseResult(
        state=LastRunState(records=records^),
        diagnostics=diagnostics^,
    )


def _contains_string(values: List[String], wanted: String) -> Bool:
    """Whether a string list contains an equal value."""
    for value in values:
        if value == wanted:
            return True
    return False


def _record_path(record: LastRunRecord) -> String:
    """Return the root-relative file component of a record."""
    if record.kind.is_file():
        return record.identifier
    return split_node_token(record.identifier).file_part


def merge_last_run_state(
    previous: LastRunState, delta: StateDelta
) -> LastRunState:
    """Merge fresh observations without clearing unverdicted failures.

    Terminal file abnormalities replace all old and fresh test records for the
    file. A fully observed normal file clears all of its old records before
    fresh test failures are added. Partial selection clears only exact observed
    tests and clears the observed file's stale file-level record while
    preserving every unselected test.

    Args:
        previous: The previously persisted logical state. Not mutated.
        delta: Fresh observations and failures. Not mutated.

    Returns:
        A newly allocated merged logical state. Encoding canonicalizes order.
    """
    var merged = List[LastRunRecord]()
    for record in previous.records:
        var path = _record_path(record)
        if _contains_string(delta.terminal_files, path) or _contains_string(
            delta.fully_observed_files, path
        ):
            continue
        if record.kind.is_test() and _contains_string(
            delta.observed_tests, record.identifier
        ):
            continue
        if record.kind.is_file() and _contains_string(
            delta.observed_files, path
        ):
            continue
        _append_record_once(merged, record.copy())

    for record in delta.failures:
        var path = _record_path(record)
        if (
            _contains_string(delta.terminal_files, path)
            and record.kind.is_test()
        ):
            continue
        _append_record_once(merged, record.copy())
    return LastRunState(records=merged^)
