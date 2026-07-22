"""The report coordinator: named lifecycle operations over a reporter set.

Reporters share one event-stream method, `handle`, but the session also drives a
handful of out-of-band lifecycle interactions that only some concrete reporters
answer: polling the machine stream's write latch, synthesizing `[not-run]` rows
into the JUnit report and finalizing it, and rendering the annotation tail. A
coordinator owns its reporter set and exposes those interactions by NAME, so the
session depends on this interface rather than on a concrete reporter type or a
fixed position in a composition tuple.

Two coordinators conform. `StandardReportCoordinator` is the production set —
console, machine stream, JUnit, annotations — and `RecordingCoordinator` swaps
the console for an arbitrary comptime pack of reporters, which is what the
session's own drivers compose. `CompositeReporter` remains the general fan-out
mechanism and does the pack's dispatch inside the recording coordinator.
"""
from mtest.model import Event

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
    channel answers inertly — an absent machine stream never latches, an absent
    JUnit reporter finalizes successfully, an absent annotations reporter
    renders an empty tail — so a caller never branches on what is composed.
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

    def finalize_junit(mut self) -> JunitFinalizeResult:
        """Publish the JUnit artifact: assemble, verify-write, atomic-rename.

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

    def fence_token(self) -> String:
        """The console's captured-output fence token, if it fenced any region.

        Returns:
            The token to close with a resume delimiter under GitHub Actions, or
            an empty string when nothing was fenced.
        """
        ...


struct StandardReportCoordinator(ReportCoordinator):
    """The production reporter set: console, machine stream, JUnit, annotations.

    Owns all four reporters by name. Each is independently inert when its
    feature is off — no `--json`, no `--junit-xml`, annotations resolved off —
    so the set is fixed and the composition carries no positional convention.
    """

    var console: ConsoleReporter
    """Renders the human-readable run into a buffer `main` flushes."""

    var stream: JsonStreamReporter
    """Writes the machine stream and latches a write failure."""

    var junit: JunitReporter
    """Spools per-file suites and publishes the JUnit artifact."""

    var annotations: AnnotationsReporter
    """Accumulates the stream and renders the workflow-command tail."""

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

    def handle(mut self, e: Event):
        """Fan the event to all four reporters, console first.

        Args:
            e: The event to dispatch.
        """
        self.console.handle(e)
        self.stream.handle(e)
        self.junit.handle(e)
        self.annotations.handle(e)

    def stream_failed(self) -> Bool:
        """Whether the machine stream latched a write failure."""
        return self.stream.status().failed

    def note_not_run(mut self, selected_paths: List[String]):
        """Synthesize the JUnit `[not-run]` rows.

        Args:
            selected_paths: The selected files that must appear in the report.
        """
        self.junit.note_not_run(selected_paths)

    def finalize_junit(mut self) -> JunitFinalizeResult:
        """Publish the JUnit artifact."""
        return self.junit.finalize()

    def annotation_tail(self) -> List[String]:
        """Render the annotation tail. Allocates the returned list."""
        return self.annotations.render()

    def console_output(self) -> String:
        """The console's rendered buffer."""
        return self.console.output()

    def fence_token(self) -> String:
        """The console's fence token, or an empty string."""
        return self.console.fence_token()


struct RecordingCoordinator[*Rs: Reporter](ReportCoordinator):
    """A coordinator whose console slot is an arbitrary pack of reporters.

    The session's own drivers compose recording reporters where production
    composes a console, and pair them with whichever real lifecycle reporter the
    driver is exercising. The pack is dispatched by `CompositeReporter`, so a
    driver reads its recorders back through `composite.reporters[i]` at a
    comptime index. The console channel has no reporter behind it and answers
    with empty strings.

    Parameters:
        Rs: The reporter types composing the pack, in fan-out order.
    """

    var composite: CompositeReporter[*Self.Rs]
    """The reporter pack standing in for the console."""

    var stream: JsonStreamReporter
    """The machine-stream reporter, inert unless the driver supplies one."""

    var junit: JunitReporter
    """The JUnit reporter, inert unless the driver supplies one."""

    var annotations: AnnotationsReporter
    """The annotations reporter, inert unless the driver supplies one."""

    def __init__(out self, var composite: CompositeReporter[*Self.Rs]):
        """Compose the pack alone, with every lifecycle channel inert.

        Args:
            composite: The reporter pack to fan events to. Consumed.
        """
        self.composite = composite^
        self.stream = JsonStreamReporter.inert()
        self.junit = JunitReporter.inert()
        self.annotations = AnnotationsReporter.inert()

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

    def handle(mut self, e: Event):
        """Fan the event to the pack, then to each lifecycle reporter.

        Args:
            e: The event to dispatch.
        """
        self.composite.handle(e)
        self.stream.handle(e)
        self.junit.handle(e)
        self.annotations.handle(e)

    def stream_failed(self) -> Bool:
        """Whether the composed machine stream latched a write failure."""
        return self.stream.status().failed

    def note_not_run(mut self, selected_paths: List[String]):
        """Synthesize the JUnit `[not-run]` rows.

        Args:
            selected_paths: The selected files that must appear in the report.
        """
        self.junit.note_not_run(selected_paths)

    def finalize_junit(mut self) -> JunitFinalizeResult:
        """Publish the JUnit artifact."""
        return self.junit.finalize()

    def annotation_tail(self) -> List[String]:
        """Render the annotation tail. Allocates the returned list."""
        return self.annotations.render()

    def console_output(self) -> String:
        """Empty: no console reporter stands behind the pack."""
        return String("")

    def fence_token(self) -> String:
        """Empty: no console reporter stands behind the pack."""
        return String("")
