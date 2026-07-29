"""The report coordinator: named lifecycle operations over a reporter set.

Reporters share one event-stream method, `handle`, but the session also drives a
handful of out-of-band lifecycle interactions that only some concrete reporters
answer: polling the machine stream's write latch, synthesizing `[not-run]` rows
into the JUnit report and finalizing it, and rendering the annotation tail. A
coordinator owns its reporter set and exposes those interactions by NAME, so the
session depends on this interface rather than on a concrete reporter type or a
fixed position in a composition tuple.

Two coordinators conform. `StandardReportCoordinator` is the production set
(console, machine stream, JUnit, annotations). `RecordingCoordinator` swaps the
console for an arbitrary comptime pack of reporters, which is what the session's
own drivers compose. `CompositeReporter` remains the general fan-out mechanism
and does the pack's dispatch inside the recording coordinator.

Because every caller reaches the layer through these named methods, adding a
reporter stays a local change inside a coordinator.
"""
from mtest.config import StateDelta
from mtest.model import (
    Event,
    EventKind,
    FileFinishedPayload,
    PrecompileFailedPayload,
    TestReportedPayload,
)

from mtest.report.annotations_reporter import AnnotationsReporter
from mtest.report.composite import CompositeReporter
from mtest.report.console import ConsoleReporter
from mtest.report.json_stream_reporter import JsonStreamReporter
from mtest.report.junit_reporter import JunitFinalizeResult, JunitReporter
from mtest.report.reporter import Reporter


trait ReportCoordinator:
    """The report layer's lifecycle interface, as the session consumes it.

    Every operation the session or `main` needs beyond the event stream appears
    here as a named method. A coordinator that composes no reporter for a given
    channel answers inertly: an absent machine stream never latches, an absent
    JUnit reporter finalizes successfully, and an absent annotations reporter
    renders an empty tail. A caller therefore never branches on what is
    composed.

    Examples:

    ```mojo
    from mtest.model import Event
    from mtest.report import ReportCoordinator

    def drive[C: ReportCoordinator](mut c: C, events: List[Event]) -> Bool:
        for ref e in events:
            c.handle(e)
        return c.stream_failed()
    ```
    """

    def handle(mut self, e: Event):
        """Fan one event to every composed reporter, in composition order.

        Args:
            e: The event to dispatch, in emission order.
        """
        ...

    def stream_failed(self) -> Bool:
        """Whether the machine stream has latched a write failure.

        Returns:
            True when the stream's destination died, which the session treats
            as a fatal abort. False when no stream is composed.
        """
        ...

    def note_not_run(mut self, selected_paths: List[String]):
        """Synthesize a `[not-run]` row for every selected file without a verdict.

        A JUnit-only side channel: the console and the machine stream never
        receive synthetic not-run events, preserving the deliberate reporter
        asymmetry. A no-op when no JUnit reporter is composed.

        Args:
            selected_paths: The selected files that must appear in the report.
        """
        ...

    def finalize_junit(
        mut self, built_files: Int, cached_files: Int
    ) -> JunitFinalizeResult:
        """Publish the JUnit artifact: assemble, verify-write, atomic-rename.

        The two build-cache counters ride this call rather than an event: the
        JUnit reporter has no `SESSION_FINISHED` branch, so a run-wide terminal
        fact can only reach it through the finalize seam. They partition the
        run's first-attempt compile admissions — `built_files` counts those that
        reached the compiler, compile FAILURES included, `cached_files` those
        served from the store — and both zero states nothing in the document.

        Args:
            built_files: First-attempt compile admissions, failures included.
            cached_files: Cache-hit admissions.

        Returns:
            The finalize result, so the session can report a finalization
            failure. A no-op success when no JUnit reporter is composed.
        """
        ...

    def annotation_tail(self) -> List[String]:
        """Render the annotation tail accumulated from the whole event stream.

        Returns:
            The sorted `::error` lines, then the sorted `::warning` lines, then
            the single `::notice` line. Empty when no annotations reporter is
            composed. Allocates the returned list.
        """
        ...

    def console_output(self) -> String:
        """The console's fully rendered buffer, ready to flush verbatim.

        Returns:
            The rendered bytes, already newline-terminated. Empty when no
            console reporter is composed.
        """
        ...

    def drain_console(mut self, closing: Bool) -> String:
        """The console bytes not yet drained, for an incremental flush.

        Lets a driver flush the console as the run progresses rather than in one
        terminal write, while `concat(every drain)` still reproduces
        `console_output()` byte-for-byte. Each non-closing drain returns the
        header appended since the last drain; the closing drain returns the
        remaining header, the framed sections, and the summary band, sealing the
        buffer. Empty when no console reporter is composed.

        Args:
            closing: Whether this is the terminal drain, which additionally
                emits the sections and summary tail.

        Returns:
            The undrained rendered bytes, or an empty string.
        """
        ...

    def progress_overlay(self) -> String:
        """The console's live progress counter, for the driver's TTY overlay.

        Returns:
            The ephemeral counter line the driver erases and redraws around each
            committed console flush, or an empty string when no counter is shown
            (off a terminal, under `-q`, or when no console reporter is
            composed). Never part of the committed `drain_console` bytes.
        """
        ...

    def fence_token(self) -> String:
        """The console's captured-output fence token, if it fenced any region.

        Returns:
            The token to close with a resume delimiter under GitHub Actions, or
            an empty string when nothing was fenced.
        """
        ...

    def configure_state_gates(mut self, paths: List[String]):
        """Name gate paths before verdict events begin.

        Args:
            paths: The root-relative gate paths. Not mutated.
        """
        ...

    def state_delta(self) -> StateDelta:
        """Return a copy of the live verdict delta folded from events."""
        ...


@fieldwise_init
struct _StateTracker(Copyable, Movable):
    """An event consumer that folds only persisted last-run verdict facts."""

    var delta: StateDelta
    var gates: List[String]

    @staticmethod
    def empty() -> Self:
        return Self(StateDelta.empty(), [])

    def configure_gates(mut self, paths: List[String]):
        self.gates = paths.copy()

    def _is_gate(self, path: String) -> Bool:
        for gate in self.gates:
            if gate == path:
                return True
        return False

    def handle(mut self, event: Event):
        if event.kind == EventKind.TEST_REPORTED:
            ref payload = event.data[TestReportedPayload]
            if not self._is_gate(payload.path):
                self.delta.observe_test(
                    payload.test.node.copy(), payload.test.outcome
                )
            return
        if event.kind == EventKind.FILE_FINISHED:
            ref payload = event.data[FileFinishedPayload]
            if self._is_gate(payload.path):
                self.delta.observe_gate(
                    payload.path, failed=payload.outcome.is_failing()
                )
            else:
                self.delta.observe_file(
                    payload.path,
                    payload.outcome,
                    fully_observed=payload.deselected_tests == 0,
                )
            return
        if event.kind == EventKind.PRECOMPILE_FAILED:
            ref payload = event.data[PrecompileFailedPayload]
            self.delta.observe_precompile_casualties(payload.casualties)


struct StandardReportCoordinator(ReportCoordinator):
    """The production reporter set: console, machine stream, JUnit, annotations.

    Owns all four reporters by name. Each is independently inert when its
    feature is off (no `--json`, no `--junit-xml`, annotations resolved off), so
    the set is fixed and the composition carries no positional convention.

    Examples:

    ```mojo
    from mtest.config import ColorWhen, ShowOutput, Verbosity
    from mtest.model import Event
    from mtest.report import AnnotationsReporter
    from mtest.report import ConsoleReporter
    from mtest.report import StandardReportCoordinator
    from mtest.report import JsonStreamReporter
    from mtest.report import JunitReporter

    var console = ConsoleReporter(
        "0.6.0", ColorWhen.NEVER, False, False, Verbosity.NORMAL,
        ShowOutput.FAILURES, "", 0,
    )
    var coord = StandardReportCoordinator(
        console^, JsonStreamReporter.inert(), JunitReporter.inert(),
        AnnotationsReporter.inert(),
    )
    coord.handle(Event.file_started("tests/test_a.mojo"))
    var rendered = coord.console_output()
    ```
    """

    var console: ConsoleReporter
    """Renders the human-readable run into a buffer `main` flushes."""

    var stream: JsonStreamReporter
    """Writes the machine stream and latches a write failure."""

    var junit: JunitReporter
    """Spools per-file suites and publishes the JUnit artifact."""

    var annotations: AnnotationsReporter
    """Accumulates the stream and renders the workflow-command tail."""

    var state_tracker: _StateTracker
    """Folds the state delta from the same ordered event stream."""

    def __init__(
        out self,
        var console: ConsoleReporter,
        var stream: JsonStreamReporter,
        var junit: JunitReporter,
        var annotations: AnnotationsReporter,
    ):
        """Take ownership of the four reporters.

        Args:
            console: The console reporter. Consumed.
            stream: The machine-stream reporter, inert without `--json`.
                Consumed.
            junit: The JUnit reporter, inert without `--junit-xml`. Consumed.
            annotations: The annotations reporter, inert when resolved off.
                Consumed.
        """
        self.console = console^
        self.stream = stream^
        self.junit = junit^
        self.annotations = annotations^
        self.state_tracker = _StateTracker.empty()

    def handle(mut self, e: Event):
        """Fan the event to all four reporters, console first.

        Args:
            e: The event to dispatch.
        """
        self.console.handle(e)
        self.stream.handle(e)
        self.junit.handle(e)
        self.annotations.handle(e)
        self.state_tracker.handle(e)

    def stream_failed(self) -> Bool:
        """Whether the machine stream latched a write failure."""
        return self.stream.status().failed

    def note_not_run(mut self, selected_paths: List[String]):
        """Synthesize the JUnit `[not-run]` rows.

        Args:
            selected_paths: The selected files that must appear in the report.
        """
        self.junit.note_not_run(selected_paths)

    def finalize_junit(
        mut self, built_files: Int, cached_files: Int
    ) -> JunitFinalizeResult:
        """Publish the JUnit artifact, naming the run's cache counters.

        Args:
            built_files: First-attempt compile admissions, failures included.
            cached_files: Cache-hit admissions.
        """
        return self.junit.finalize(built_files, cached_files)

    def annotation_tail(self) -> List[String]:
        """Render the annotation tail. Allocates the returned list."""
        return self.annotations.render()

    def console_output(self) -> String:
        """The console's rendered buffer."""
        return self.console.output()

    def drain_console(mut self, closing: Bool) -> String:
        """The console bytes not yet drained; delegates to the console.

        Args:
            closing: Whether this is the terminal drain, which additionally
                emits the sections and summary tail.
        """
        return self.console.drain(closing)

    def progress_overlay(self) -> String:
        """The console's live progress counter; delegates to the console."""
        return self.console.progress_line()

    def fence_token(self) -> String:
        """The console's fence token, or an empty string."""
        return self.console.fence_token()

    def configure_state_gates(mut self, paths: List[String]):
        """Name gate paths before verdict events begin.

        Args:
            paths: The root-relative gate paths. Not mutated.
        """
        self.state_tracker.configure_gates(paths)

    def state_delta(self) -> StateDelta:
        """Return a copy of the live verdict delta."""
        return self.state_tracker.delta.copy()


struct RecordingCoordinator[*Rs: Reporter](ReportCoordinator):
    """A coordinator whose console slot is an arbitrary pack of reporters.

    The session's own drivers compose recording reporters where production
    composes a console, and pair them with whichever real lifecycle reporter the
    driver is exercising. The pack is dispatched by `CompositeReporter`, so a
    driver reads its recorders back through `composite.reporters[i]` at a
    comptime index, bound to a typed reference rather than a bare `rebind`, so a
    wrong index fails to compile instead of being undefined behavior. That reach
    is legitimate only for a driver pulling its own recorder out of a pack it
    composed; session-level reporter lifecycle goes through the named methods
    above. The console channel has no reporter behind it and answers with empty
    strings.

    A function returning one spells the pack parameter bare, without the `*`, as
    `RecordingCoordinator[RecordingReporter]`.

    Parameters:
        Rs: The reporter types composing the pack, in fan-out order.

    Examples:

    ```mojo
    from mtest.model import Event
    from mtest.report import CompositeReporter
    from mtest.report import RecordingCoordinator
    from mtest.report import RecordingReporter

    var coord = RecordingCoordinator(CompositeReporter(Tuple(RecordingReporter())))
    coord.handle(Event.file_started("tests/test_a.mojo"))
    var seen = coord.composite.reporters[0].count()  # 1
    ```
    """

    var composite: CompositeReporter[*Self.Rs]
    """The reporter pack standing in for the console."""

    var stream: JsonStreamReporter
    """The machine-stream reporter, inert unless the driver supplies one."""

    var junit: JunitReporter
    """The JUnit reporter, inert unless the driver supplies one."""

    var annotations: AnnotationsReporter
    """The annotations reporter, inert unless the driver supplies one."""

    var state_tracker: _StateTracker
    """Folds the state delta from the same ordered event stream."""

    def __init__(out self, var composite: CompositeReporter[*Self.Rs]):
        """Compose the pack alone, with every lifecycle channel inert.

        Args:
            composite: The reporter pack to fan events to. Consumed.
        """
        self.composite = composite^
        self.stream = JsonStreamReporter.inert()
        self.junit = JunitReporter.inert()
        self.annotations = AnnotationsReporter.inert()
        self.state_tracker = _StateTracker.empty()

    def __init__(
        out self,
        var composite: CompositeReporter[*Self.Rs],
        var stream: JsonStreamReporter,
        var junit: JunitReporter,
        var annotations: AnnotationsReporter,
    ):
        """Compose the pack alongside real lifecycle reporters.

        Args:
            composite: The reporter pack to fan events to. Consumed.
            stream: The machine-stream reporter to poll. Consumed.
            junit: The JUnit reporter to synthesize into and finalize.
                Consumed.
            annotations: The annotations reporter to render the tail from.
                Consumed.
        """
        self.composite = composite^
        self.stream = stream^
        self.junit = junit^
        self.annotations = annotations^
        self.state_tracker = _StateTracker.empty()

    def handle(mut self, e: Event):
        """Fan the event to the pack, then to each lifecycle reporter.

        Args:
            e: The event to dispatch.
        """
        self.composite.handle(e)
        self.stream.handle(e)
        self.junit.handle(e)
        self.annotations.handle(e)
        self.state_tracker.handle(e)

    def stream_failed(self) -> Bool:
        """Whether the composed machine stream latched a write failure."""
        return self.stream.status().failed

    def note_not_run(mut self, selected_paths: List[String]):
        """Synthesize the JUnit `[not-run]` rows.

        Args:
            selected_paths: The selected files that must appear in the report.
        """
        self.junit.note_not_run(selected_paths)

    def finalize_junit(
        mut self, built_files: Int, cached_files: Int
    ) -> JunitFinalizeResult:
        """Publish the JUnit artifact, naming the run's cache counters.

        Args:
            built_files: First-attempt compile admissions, failures included.
            cached_files: Cache-hit admissions.
        """
        return self.junit.finalize(built_files, cached_files)

    def annotation_tail(self) -> List[String]:
        """Render the annotation tail. Allocates the returned list."""
        return self.annotations.render()

    def console_output(self) -> String:
        """Empty: no console reporter stands behind the pack."""
        return String("")

    def drain_console(mut self, closing: Bool) -> String:
        """Empty: no console reporter stands behind the pack.

        Args:
            closing: Accepted to satisfy the interface; the answer is empty
                either way.
        """
        return String("")

    def progress_overlay(self) -> String:
        """Empty: a recording stream has no TTY progress overlay."""
        return String("")

    def fence_token(self) -> String:
        """Empty: no console reporter stands behind the pack."""
        return String("")

    def configure_state_gates(mut self, paths: List[String]):
        """Name gate paths before verdict events begin.

        Args:
            paths: The root-relative gate paths. Not mutated.
        """
        self.state_tracker.configure_gates(paths)

    def state_delta(self) -> StateDelta:
        """Return a copy of the live verdict delta."""
        return self.state_tracker.delta.copy()
