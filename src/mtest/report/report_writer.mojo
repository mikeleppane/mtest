"""The stateful run-report writer: accumulate, spool, stream, publish.

Where `report_md` and `report_html` are pure fragment renderers and
`report_model` the value types they consume, this is the shell around both: a
`Reporter` that accumulates each file's typed state from the event stream,
renders one section fragment per finished file per ACTIVE format, spools those
fragments to a session temp directory, and stream-assembles each document at
finalize. The runner's memory therefore never holds every rendered section at
once — the same bound `JunitReporter` keeps, for the same reason.

This module owns document STRUCTURE (what follows what, and in which order)
and nothing about presentation: every byte of model-derived text comes from a
renderer function, so a report can never escape a value differently from the
way its own renderer would. The one ruling it shares with both renderers,
`report_model.needs_action`, decides which files earn a section under the
concise style, so "does this file need a second look" is answered in exactly
one place for the summary table, the machine index, and the section filter.

Two facts shape the type:

- The `Reporter` trait requires `Copyable`, while `UniqueTempFile` is
  `Movable`-only by design, so a writer that transitively owned one could not
  compile. `ReportArtifact` therefore splits the created temp into its path and
  its BORROWED descriptor, exactly as `JsonStreamReporter` borrows the machine
  stream's fd: the descriptor's lifetime belongs to `main`/`RunResources`, and
  exactly one instance ever closes it.

  Read that as a constraint on callers, because the type system cannot enforce
  it. `Copyable` is what the trait demands, so the compiler will happily make a
  copy of a writer holding a live descriptor, and `finalize_reports` on that
  copy would close a descriptor number the kernel may already have reissued to
  an unrelated file. Nothing in the shipped composition can reach that state:
  production MOVES the writer into `StandardReportCoordinator`, neither
  coordinator declares `Copyable`, and the session takes the coordinator by
  `mut`. Taking a copy of a writer before its finalize is therefore a
  programming error, not a supported use, and it is the one way to break the
  exactly-one-close property this module rests on.
- The two sinks are independent. A fragment write that fails latches only its
  own sink; a finalize that cannot write, close, or rename fails only its own
  sink. The other format still publishes, and a failing sink never truncates
  or replaces the report already at its target: the document is streamed into
  the unique temp and only an atomic rename publishes it.

An inert writer, the no-`--report` shape, holds no artifact at all: `handle` is
a no-op, `finalize_reports` is a clean success, and nothing is ever opened.
"""
from mtest.model import (
    AttemptFinishedPayload,
    Event,
    EventKind,
    FileFinishedPayload,
    FileStartedPayload,
    NotRunRecord,
    Outcome,
    PrecompileFailedPayload,
    TestReportedPayload,
    TestResult,
)
from mtest.platform import close_checked_fd, rename_path, write_all_bytes_fd
from mtest.report.file_accum import FileAccums
from mtest.report.junit import bounded_text_from_bytes
from mtest.report.report_html import (
    html_document_close,
    html_document_open,
    html_file_section,
    html_machine_index,
    html_not_run_heading,
    html_not_run_line,
    html_summary_row,
)
from mtest.report.report_md import (
    md_file_section,
    md_header,
    md_machine_index,
    md_not_run_heading,
    md_not_run_line,
    md_summary_row,
    md_summary_table_header,
)
from mtest.report.report_model import (
    ReportFinalizeContext,
    ReportHeaderFacts,
    ReportRow,
    ReportSectionInput,
    needs_action,
)
from mtest.report.reporter import Reporter
from mtest.report.spool_dir import open_spool_dir

comptime REPORT_STYLE_CONCISE = 0
"""The concise style: every file earns a summary row, and only a file that
`needs_action` earns a per-file section."""
comptime REPORT_STYLE_FULL = 1
"""The full style: every file earns both a summary row and a section."""

comptime _FORMAT_MD = 0
"""The Markdown sink's discriminant, used only inside this module."""
comptime _FORMAT_HTML = 1
"""The HTML sink's discriminant, used only inside this module."""

# Decomposed exec-layer termination kinds, as the events carry them. Restated
# here with the same meaning `junit_reporter` restates them with: this layer
# cannot import `exec`, which sits below it.
comptime _TERM_EXITED = 0
comptime _TERM_SIGNALED = 1
comptime _TERM_TIMED_OUT = 2
comptime _TERM_SPAWN_FAILED = 3

comptime _ATTEMPT_LINE_CODEPOINTS = 200
"""How many codepoints of one attempt summary survive; the rest is elided, so
no single attempt line can unbound a section fragment."""
comptime _ELISION: StaticString = "…"
"""The marker a bounded attempt line ends with when it was cut."""

comptime _PRECOMPILE_SECTION: StaticString = "mtest::precompile"
"""The section identity a precompile failure that named no step falls back to;
session-level like the JUnit suite of the same name, and deliberately not a
path, so it can never collide with a real file's section."""


def open_report_spool() raises -> String:
    """Create and return this run's private temp directory for section
    fragments.

    A thin naming of `open_spool_dir`, which owns the creation protocol and the
    reasoning behind it (no `mkdtemp`, a re-read clock per attempt, the
    TMPDIR/TEMP/TMP precedence). One directory serves both sinks: a section's
    Markdown and HTML fragments differ by filename, never by directory.

    Returns:
        The path of the freshly created, empty directory, mode 0o700. The
        caller owns it and is responsible for removing it, fragments and all.

    Raises:
        Error: When no candidate could be created within the attempt budget.
            The caller resolves this to the pre-run internal-error exit code.

    Examples:

    ```mojo
    from mtest.report import open_report_spool

    var spool = open_report_spool()
    ```
    """
    return open_spool_dir("run-report")


@fieldwise_init
struct ReportArtifact(Copyable, Movable):
    """One report destination: its target plus the borrowed open temp.

    `main` calls `create_unique_temp` (the sole open of that pathname — the
    platform seam's anti-replacement rule; it is never reopened) and splits
    the result here. The descriptor is BORROWED: exactly one instance — the
    coordinator-slot writer, at finalize — may close it.

    `Copyable` here is inherited from the `Reporter` trait's requirement on the
    writer that holds this, not a statement that a copy is safe to finalize. A
    copy taken while `fd` is still open holds a descriptor a second close would
    release twice, and the second release could land on an unrelated file the
    kernel reissued the number to. Copy this freely for reading; do not carry a
    copy across the one finalize.
    """

    var target: String
    """The path the finished document is renamed onto."""
    var temp_path: String
    """The unique-temp pathname, recorded only for the discard path."""
    var fd: Int
    """The open write descriptor from `create_unique_temp`; `-1` after the
    finalize close (and in copies made after it).

    Borrowed. `main` records the same descriptor on
    `RunResources`, whose `close_into` unlinks `temp_path` best-effort and
    never closes this fd: an abort path that skips finalize leaks it into
    `exit()`, exactly as the JUnit scratch path does today. The single close
    lives in `ReportWriter.finalize_reports`, which sets this field to `-1`
    immediately afterwards so no later call can close it twice."""
    var failed: Bool
    """Whether this sink has latched."""
    var detail: String
    """The latch diagnostic, empty while clean."""


@fieldwise_init
struct ReportFinalizeResult(Copyable, Movable):
    """Per-sink outcome of `finalize_reports`, consumed by the session."""

    var md_failed: Bool
    """Whether the Markdown sink failed to publish."""
    var md_detail: String
    """The Markdown sink's failure diagnostic, empty on success."""
    var html_failed: Bool
    """Whether the HTML sink failed to publish."""
    var html_detail: String
    """The HTML sink's failure diagnostic, empty on success."""


@fieldwise_init
struct _SpoolEntry(Copyable, Movable):
    """One spooled section's order key and its on-disk fragment path."""

    var key: String
    """The section's sort key: the file path the section describes."""
    var file_path: String
    """Where the rendered fragment was spooled."""


@fieldwise_init
struct _SinkOutcome(Copyable, Movable):
    """One sink's finalize verdict, before the two are paired into a result."""

    var failed: Bool
    """Whether this sink failed to publish."""
    var detail: String
    """The diagnostic when `failed`; empty when clean."""


def _bounded_line(text: String) -> String:
    """Bound one composed summary line to a fixed codepoint budget.

    Cuts on a codepoint boundary, never inside a multi-byte sequence, and
    marks a cut line so a reader can tell a short line from a truncated one.

    Args:
        text: The composed line.

    Returns:
        `text` unchanged when it fits, else its first
        `_ATTEMPT_LINE_CODEPOINTS` codepoints plus the elision marker.
    """
    if text.count_codepoints() <= _ATTEMPT_LINE_CODEPOINTS:
        return text.copy()
    var out = String("")
    var kept = 0
    for cp in text.codepoint_slices():
        if kept >= _ATTEMPT_LINE_CODEPOINTS:
            break
        out += String(cp)
        kept += 1
    return out + _ELISION


def _termination_phrase(kind: Int, value: Int, escalated: Bool) -> String:
    """How one attempt ended, in the same words the JUnit reporter uses."""
    if kind == _TERM_SIGNALED:
        var m = "killed by signal " + String(value)
        if escalated:
            m += " (escalated to SIGKILL)"
        return m^
    if kind == _TERM_TIMED_OUT:
        return String("timed out")
    if kind == _TERM_SPAWN_FAILED:
        return "spawn failed (errno " + String(value) + ")"
    return "exited with status " + String(value)


def _attempt_line(a: AttemptFinishedPayload) -> String:
    """One non-final attempt, as a bounded single line for a section's list."""
    var out = (
        "attempt " + String(a.attempt_index) + "/" + String(a.attempts_planned)
    )
    if a.step != "":
        out += " " + a.step
    out += ": " + _termination_phrase(a.term_kind, a.term_value, a.escalated)
    if a.classification != "":
        out += " (" + a.classification + ")"
    return _bounded_line(out)


def _build_line(argv: List[String]) -> String:
    """The build command line for a section, as one space-joined string."""
    var out = String("")
    for i in range(len(argv)):
        if i > 0:
            out += " "
        out += argv[i]
    return out^


def _sorted_indices(keys: List[String]) -> List[Int]:
    """The permutation that puts `keys` in ascending order.

    One insertion sort for every ordered thing the document has — the summary
    rows, each sink's spooled sections, and the not-run reasons — so a section
    can never land in a different order from the row that announced it. Stable
    and comparison-based over the same `String` ordering, which is what makes
    "the sections are in the rows' order" a property of one function rather
    than an agreement between three.

    Args:
        keys: The sort keys, in their arrival order. Not mutated.

    Returns:
        Indices into `keys`, ordered so `keys[result[i]]` is ascending.
    """
    var order = List[Int]()
    for i in range(len(keys)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0 and keys[order[j]] < keys[order[j - 1]]:
            var t = order[j]
            order[j] = order[j - 1]
            order[j - 1] = t
            j -= 1
    return order^


def _sink_label(fmt: Int) -> String:
    """The format's name, as it appears in a failure diagnostic."""
    return String("markdown") if fmt == _FORMAT_MD else String("html")


struct ReportWriter(Reporter):
    """A `Reporter` that spools one section per finished file and publishes.

    Accumulates per-file typed state, appends one `ReportRow` per finished
    file, renders and spools a section fragment per active sink, and streams
    the whole document per sink at finalize: header, summary rows in sorted
    path order, spooled sections read back one at a time in that same order,
    the not-run reasons, and the machine index. Each sink is independent, and
    an inert writer holds no artifact and does nothing.

    Examples:

    ```mojo
    from mtest.model import Event
    from mtest.report import ReportWriter

    var writer = ReportWriter.inert()
    writer.handle(Event.file_started("tests/test_a.mojo"))
    ```
    """

    var _md: Optional[ReportArtifact]
    """The Markdown sink, or `None` when Markdown was not requested."""
    var _html: Optional[ReportArtifact]
    """The HTML sink, or `None` when HTML was not requested."""
    var _facts: ReportHeaderFacts
    """The build-time version and platform labels the header names."""
    var _style: Int
    """`REPORT_STYLE_CONCISE` or `REPORT_STYLE_FULL`; decides which files earn
    a section."""
    var _spool_dir: String
    """The existing session temp directory the section fragments are written
    to; empty when inert.

    The writer neither creates nor removes it: `main` creates it before the run
    and removes it, fragments and all, on the way out, exactly as it owns the
    JUnit spool. A fragment left here after a failed sink is therefore cleaned
    up with the rest of the directory rather than one file at a time."""
    var _root: String
    """The run root every section relativizes a compiler-baked `At <path>`
    line against, the same root every other reporter was given."""
    var _counter: Int
    """A monotonic counter minting a unique fragment filename per section.

    Shared by both sinks and advanced once per section, so a section's
    Markdown and HTML fragments carry the same index."""
    var _rows: List[ReportRow]
    """One summary row per finished file, plus one per surviving not-run
    record, in arrival order (sorted at finalize)."""
    var _nodes: List[String]
    """The reproduce target parallel to `_rows`: the file's path, or its
    single failing node id."""
    var _md_spool: List[_SpoolEntry]
    """The Markdown sections spooled so far, in arrival order."""
    var _html_spool: List[_SpoolEntry]
    """The HTML sections spooled so far, in arrival order."""
    var _not_run: List[NotRunRecord]
    """The not-run records that survived the row-index filter."""
    var _accums: FileAccums[String]
    """The in-flight per-file accumulators, keyed by path.

    The same mechanism `JunitReporter` keeps, parameterized by what an attempt
    record is: this writer keeps the composed one-line summary, the JUnit
    reporter a typed struct it renders later."""

    def __init__(
        out self,
        facts: ReportHeaderFacts,
        style: Int,
        var md: Optional[ReportArtifact],
        var html: Optional[ReportArtifact],
        spool_dir: String,
        root: String,
    ):
        """Construct a writer over zero, one, or both destinations.

        Args:
            facts: The build-time version and platform labels for the header.
            style: `REPORT_STYLE_CONCISE` or `REPORT_STYLE_FULL`.
            md: The Markdown destination, or `None` when Markdown is off.
                Consumed.
            html: The HTML destination, or `None` when HTML is off. Consumed.
            spool_dir: An existing, writable session temp directory the section
                fragments are written to.
            root: The run root a section's backtrace lines are relativized
                against.
        """
        self._md = md^
        self._html = html^
        self._facts = facts.copy()
        self._style = style
        self._spool_dir = spool_dir.copy()
        self._root = root.copy()
        self._counter = 0
        self._rows = List[ReportRow]()
        self._nodes = List[String]()
        self._md_spool = List[_SpoolEntry]()
        self._html_spool = List[_SpoolEntry]()
        self._not_run = List[NotRunRecord]()
        self._accums = FileAccums[String].empty()

    @staticmethod
    def inert() -> Self:
        """The no-`--report` writer: both sinks off, `handle` a no-op."""
        return Self(
            ReportHeaderFacts("", ""),
            REPORT_STYLE_CONCISE,
            Optional[ReportArtifact](None),
            Optional[ReportArtifact](None),
            "",
            "",
        )

    def active(self) -> Bool:
        """Whether any sink is composed, so the writer consumes events."""
        return Bool(self._md) or Bool(self._html)

    def handle(mut self, e: Event):
        """Consume one event, spooling a section as each file finishes.

        Accumulation is in-memory list work; only the fragment write is
        fallible, and it is caught and latched onto its own sink so a dead
        spool never propagates out of the `Reporter` seam.

        Args:
            e: The event to consume.
        """
        if not self.active():
            return
        if e.kind == EventKind.FILE_STARTED:
            self._accums.reset(e.data[FileStartedPayload].path)
            return
        if e.kind == EventKind.TEST_REPORTED:
            ref tr = e.data[TestReportedPayload]
            var idx = self._accums.ensure(tr.path)
            self._accums.items[idx].tests.append(tr.test.copy())
            return
        if e.kind == EventKind.ATTEMPT_FINISHED:
            ref a = e.data[AttemptFinishedPayload]
            var idx = self._accums.ensure(a.path)
            self._accums.items[idx].attempts.append(_attempt_line(a))
            return
        if e.kind == EventKind.FILE_FINISHED:
            self._finish_file(e.data[FileFinishedPayload])
            return
        if e.kind == EventKind.PRECOMPILE_FAILED:
            self._finish_precompile(e.data[PrecompileFailedPayload])
            return

    def note_not_run_records(mut self, records: List[NotRunRecord]):
        """Fold in one classified record per selected file, filtering verdicts.

        Records arrive for EVERY selected file, the ones that produced a
        verdict included, so the row index is the filter here — the same
        contract `JunitReporter.note_not_run` implements with its `_has_suite`
        skip. A path already carrying a row is dropped; a surviving path gains
        a `NOT_RUN` summary row and is retained for its reason line. The same
        index check deduplicates a repeated record and a record that follows a
        drift `FILE_FINISHED` row for the same path.

        Args:
            records: One record per selected file, in the session's stated
                order. Not mutated.
        """
        if not self.active():
            return
        for i in range(len(records)):
            ref record = records[i]
            if self._has_row(record.path):
                continue
            self._rows.append(
                ReportRow(
                    record.path.copy(), Outcome.NOT_RUN.code, 0.0, 0, 0, 0, 0
                )
            )
            self._nodes.append(record.path.copy())
            self._not_run.append(record.copy())

    def finalize_reports(
        mut self, ctx: ReportFinalizeContext
    ) -> ReportFinalizeResult:
        """Publish every active sink: stream the document, close, rename.

        Each sink is finalized independently and in full — a Markdown failure
        never stops the HTML document from being published, and neither ever
        touches the report already at the other's target. Within one sink the
        order is fixed: stream the header and summary rows, read the spooled
        sections back one at a time in sorted path order, then the not-run
        reasons and the machine index, then close the borrowed descriptor
        exactly once and atomically rename the temp onto the target. A sink
        that already latched a fragment-write failure streams nothing at all
        and reports that latch; its temp is left for `RunResources` to unlink,
        and the prior report at its target is untouched.

        Calling this twice is safe: the descriptor is released on the first
        call, and a later call reports that sink's recorded outcome rather
        than closing or renaming again.

        Args:
            ctx: The run-wide facts the header and the epilogue render from.
                Not mutated.

        Returns:
            Both sinks' outcomes; an absent sink is a clean success.
        """
        var order = self._sorted_row_order()
        var md = self._finalize_sink(_FORMAT_MD, ctx, order)
        var html = self._finalize_sink(_FORMAT_HTML, ctx, order)
        return ReportFinalizeResult(
            md.failed, md.detail.copy(), html.failed, html.detail.copy()
        )

    def _artifact(self, fmt: Int) -> Optional[ReportArtifact]:
        """A copy of one sink's artifact, or `None` when that sink is off."""
        if fmt == _FORMAT_MD:
            return self._md.copy()
        return self._html.copy()

    def _finalize_sink(
        mut self, fmt: Int, ctx: ReportFinalizeContext, order: List[Int]
    ) -> _SinkOutcome:
        """Stream, close, and publish one sink; never raise past this frame."""
        var held = self._artifact(fmt)
        if not held:
            return _SinkOutcome(False, "")
        var art = held.value().copy()
        var label = _sink_label(fmt)
        if art.fd < 0:
            # Already finalized: the descriptor was released on the first call,
            # so nothing here may close or rename again.
            return _SinkOutcome(art.failed, art.detail.copy())
        var detail = String("")
        if art.failed:
            detail = (
                "run report (" + label + ") section spool failed: " + art.detail
            )
        else:
            try:
                self._stream_document(fmt, art.fd, ctx, order)
            except e:
                detail = (
                    "run report ("
                    + label
                    + ") could not be written: "
                    + String(e)
                )
        # The single close, on every path that got this far: a streamed
        # document, a failed write, and a latched spool all release the
        # borrowed descriptor here and nowhere else.
        try:
            close_checked_fd(art.fd)
        except e:
            if detail == "":
                detail = (
                    "run report ("
                    + label
                    + ") could not be closed: "
                    + String(e)
                )
        self._release(fmt, detail)
        if detail != "":
            return _SinkOutcome(True, detail^)
        try:
            rename_path(art.temp_path, art.target)
        except e:
            var failure = (
                "run report ("
                + label
                + ") could not be published: "
                + String(e)
            )
            self._release(fmt, failure)
            return _SinkOutcome(True, failure^)
        return _SinkOutcome(False, "")

    def _release(mut self, fmt: Int, detail: String):
        """Mark one sink's descriptor released, recording the final failure.

        A non-empty `detail` REPLACES whatever a fragment-write latch recorded
        earlier, because this one is the finalize-level diagnostic the caller
        was handed. Storing the same string is what lets a second
        `finalize_reports` answer with the first call's result rather than the
        raw latch text underneath it.

        Args:
            fmt: Which sink to release.
            detail: The finalize diagnostic, or `""` when the sink published.
        """
        if fmt == _FORMAT_MD:
            if self._md:
                self._md.value().fd = -1
                if detail != "":
                    self._md.value().failed = True
                    self._md.value().detail = detail.copy()
            return
        if self._html:
            self._html.value().fd = -1
            if detail != "":
                self._html.value().failed = True
                self._html.value().detail = detail.copy()

    def _write(self, fd: Int, text: String) raises:
        """Write one complete fragment to the sink's borrowed descriptor."""
        write_all_bytes_fd(fd, text.as_bytes())

    def _stream_document(
        self, fmt: Int, fd: Int, ctx: ReportFinalizeContext, order: List[Int]
    ) raises:
        """Assemble and write one whole document, one fragment at a time."""
        if fmt == _FORMAT_MD:
            self._write(fd, md_header(self._facts, ctx))
            self._write(fd, md_summary_table_header())
        else:
            self._write(fd, html_document_open(self._facts, ctx))

        for i in range(len(order)):
            ref row = self._rows[order[i]]
            if fmt == _FORMAT_MD:
                self._write(fd, md_summary_row(row))
            else:
                self._write(fd, html_summary_row(row))
        if fmt == _FORMAT_MD:
            # Markdown needs the table closed by a blank line before whatever
            # block follows it; HTML's rows nest inside one open `<tbody>`.
            self._write(fd, "\n")

        if fmt == _FORMAT_MD:
            self._stream_sections(fd, self._md_spool)
        else:
            self._stream_sections(fd, self._html_spool)

        var reasons = self._sorted_not_run_order()
        if len(reasons) > 0:
            # Only when a list actually follows: a run where every selected
            # file produced a verdict carries no empty section.
            if fmt == _FORMAT_MD:
                self._write(fd, md_not_run_heading())
            else:
                self._write(fd, html_not_run_heading())
        for i in range(len(reasons)):
            ref record = self._not_run[reasons[i]]
            if fmt == _FORMAT_MD:
                self._write(fd, md_not_run_line(record))
            else:
                self._write(fd, html_not_run_line(record))

        var rows = List[ReportRow]()
        var nodes = List[String]()
        for i in range(len(order)):
            rows.append(self._rows[order[i]].copy())
            nodes.append(self._nodes[order[i]].copy())
        if fmt == _FORMAT_MD:
            self._write(fd, md_machine_index(rows, nodes))
        else:
            self._write(fd, html_machine_index(rows, nodes))
            self._write(fd, html_document_close())

    def _stream_sections(self, fd: Int, spool: List[_SpoolEntry]) raises:
        """Read one sink's spooled sections back and write them in key order.

        One fragment is held in memory at a time, which is the whole point of
        spooling them: the document may be far larger than the runner's own
        footprint.

        Args:
            fd: The sink's borrowed descriptor.
            spool: That sink's spool index. Not mutated.

        Raises:
            Error: When a fragment cannot be read back or written out.
        """
        var order = self._sorted_spool_order(spool)
        for i in range(len(order)):
            var body: String
            with open(spool[order[i]].file_path, "r") as f:
                body = f.read()
            self._write(fd, body)

    def _sorted_row_order(self) -> List[Int]:
        """Row indices in sorted path order; the document's one order."""
        var keys = List[String]()
        for i in range(len(self._rows)):
            keys.append(self._rows[i].path.copy())
        return _sorted_indices(keys)

    def _sorted_spool_order(self, spool: List[_SpoolEntry]) -> List[Int]:
        """Fragment indices in sorted key order, matching the row order."""
        var keys = List[String]()
        for i in range(len(spool)):
            keys.append(spool[i].key.copy())
        return _sorted_indices(keys)

    def _sorted_not_run_order(self) -> List[Int]:
        """Record indices in sorted path order, so the reasons read stably."""
        var keys = List[String]()
        for i in range(len(self._not_run)):
            keys.append(self._not_run[i].path.copy())
        return _sorted_indices(keys)

    def _has_row(self, path: String) -> Bool:
        """Whether a summary row already exists for `path`."""
        for i in range(len(self._rows)):
            if self._rows[i].path == path:
                return True
        return False

    def _reproduce_node_for(self, accum_idx: Int, path: String) -> String:
        """The section's single reproduce/debug target for one file.

        A file whose verdict is carried by exactly one failing test names that
        test's node id, so the emitted command reruns the failure itself;
        anything else — several failures, or a file-level verdict no per-test
        row carries — names the file.
        """
        var failing = 0
        var node = String("")
        for i in range(len(self._accums.items[accum_idx].tests)):
            ref t = self._accums.items[accum_idx].tests[i]
            if t.outcome == Outcome.FAIL:
                failing += 1
                node = t.node.render()
        if failing == 1:
            return node^
        return path.copy()

    def _finish_file(mut self, e: FileFinishedPayload):
        """Record one finished file's row and, when it earns one, its section.
        """
        var idx = self._accums.ensure(e.path)
        var repro = self._reproduce_node_for(idx, e.path)
        self._rows.append(
            ReportRow(
                e.path.copy(),
                e.outcome.code,
                e.duration_seconds,
                e.passed_tests,
                e.failed_tests,
                e.skipped_tests,
                e.attempts_used,
            )
        )
        self._nodes.append(repro.copy())
        if self._style == REPORT_STYLE_CONCISE and not needs_action(
            e.outcome.code
        ):
            self._accums.drop(e.path)
            return
        var section = ReportSectionInput(
            e.path.copy(),
            self._root.copy(),
            e.outcome.code,
            self._accums.items[idx].tests.copy(),
            bounded_text_from_bytes(e.captured_stdout),
            bounded_text_from_bytes(e.captured_stderr),
            e.stdout_truncated,
            e.stderr_truncated,
            self._accums.items[idx].attempts.copy(),
            _build_line(e.build_argv),
            repro^,
        )
        self._accums.drop(e.path)
        self._spool_section(section, e.path)

    def _finish_precompile(mut self, e: PrecompileFailedPayload):
        """Give a failed precompile step its own section.

        The step is the package source path the session precompiled, which is
        what the console's banner names too, so it keys the section directly.
        The compiler's own output rides as the section's captured stderr,
        which is where the renderers already fence untrusted multi-line text.
        Named casualties are not sectioned here: each one reaches the report as
        a not-run record, with the classified reason that says why.
        """
        var path = e.step.copy() if e.step != "" else String(
            _PRECOMPILE_SECTION
        )
        var section = ReportSectionInput(
            path.copy(),
            self._root.copy(),
            Outcome.PRECOMPILE_ERROR.code,
            List[TestResult](),
            "",
            e.compiler_output.copy(),
            False,
            False,
            List[String](),
            "",
            "",
        )
        self._spool_section(section, path)

    def _spool_section(mut self, section: ReportSectionInput, key: String):
        """Render and spool one section per active, unlatched sink."""
        var index = self._counter
        self._counter += 1
        if self._md and not self._md.value().failed:
            var path = self._spool_dir + "/md-" + String(index) + ".md"
            self._spool_one(_FORMAT_MD, md_file_section(section), path, key)
        if self._html and not self._html.value().failed:
            var path = self._spool_dir + "/html-" + String(index) + ".html"
            self._spool_one(_FORMAT_HTML, html_file_section(section), path, key)

    def _spool_one(mut self, fmt: Int, body: String, path: String, key: String):
        """Write one rendered fragment, latching that sink on any failure."""
        try:
            with open(path, "w") as f:
                f.write(body)
        except e:
            self._latch(fmt, "section " + key + ": " + String(e))
            return
        if fmt == _FORMAT_MD:
            self._md_spool.append(_SpoolEntry(key.copy(), path.copy()))
        else:
            self._html_spool.append(_SpoolEntry(key.copy(), path.copy()))

    def _latch(mut self, fmt: Int, detail: String):
        """Record one sink's first fragment-write failure and go silent."""
        if fmt == _FORMAT_MD:
            if self._md and not self._md.value().failed:
                self._md.value().failed = True
                self._md.value().detail = detail.copy()
            return
        if self._html and not self._html.value().failed:
            self._html.value().failed = True
            self._html.value().detail = detail.copy()
