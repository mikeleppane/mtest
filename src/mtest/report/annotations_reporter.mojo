"""The stateful GitHub Actions annotations reporter (Layer 2).

Where `annotations` is the PURE renderer, this is the thin stateful shell around
it: a `Reporter` that feeds each event through an `AnnotationAccumulator` as it
arrives and, on demand, renders the deterministic annotation tail. It SELF-GATES
on the resolved `--gh-annotations` mode — an INACTIVE reporter (mode `off`, or
`auto` outside GitHub Actions) records nothing and renders nothing, so composing
it is always safe and costs nothing when annotations are not wanted.

Retention is ONLINE and bounded: `handle` extracts an event's annotation row(s)
immediately and drops the event, so the reporter never holds the multi-megabyte
captured output a `FileFinished`/`AttemptFinished` carries (the renderer never
reads it). A CI-scale run of hundreds of large-capture failures therefore cannot
exhaust memory to produce its at-most-ten rendered rows.

`handle` is TOTAL and NON-RAISING per the `Reporter` seam. The reporter never
prints: `main` reaches the concrete reporter at its fixed composite index (the
compile-time type-checked typed-`Pointer` pattern the session uses for the stream
and JUnit reporters) and writes the rendered lines to stdout in the deterministic
tail after the console summary band — but only once `SessionFinished` has been
seen, so the single `::notice` is always present. `Copyable, Movable` so it slots
into the reporter composition.
"""
from mtest.model import Event

from mtest.report.annotations import AnnotationAccumulator
from mtest.report.reporter import Reporter


struct AnnotationsReporter(Reporter):
    """A `Reporter` that accumulates annotation rows and renders the tail.

    Self-gates on `active` (the resolved-on decision `main` derives from the
    `--gh-annotations` mode and `GITHUB_ACTIONS`): when inactive it accumulates
    nothing and `render` returns an empty list, so an off/auto-outside-Actions
    run pays only the empty composition slot. `handle` is total and non-raising.
    """

    var _active: Bool
    """Whether annotations render at all; `False` is the resolved-off shape."""
    var _acc: AnnotationAccumulator
    """The online row accumulator — lightweight rows only, never raw captures."""

    def __init__(out self, active: Bool):
        """Construct a reporter, self-gated on the resolved-on decision.

        Args:
            active: Whether annotations render (the resolved-on decision from the
                `--gh-annotations` mode and `GITHUB_ACTIONS`). `False` yields an
                inert reporter that accumulates and renders nothing.
        """
        self._active = active
        self._acc = AnnotationAccumulator()

    @staticmethod
    def inert() -> Self:
        """The resolved-off reporter: accumulates nothing, renders nothing."""
        return Self(False)

    def handle(mut self, e: Event):
        """Accumulate one event's annotation row(s) when active, dropping the
        raw event. Total over the event set; never raises. Emits nothing on its
        own — `main` renders the tail via `render`.
        """
        if not self._active:
            return
        self._acc.observe(e)

    def render(self) -> List[String]:
        """The deterministic annotation tail for the whole run.

        The node-id-sorted `::error` block, then the node-id-sorted `::warning`
        block, then the single `::notice` (present once `SessionFinished` was
        seen). An inactive reporter returns an empty list. Does not raise.
        """
        if not self._active:
            return List[String]()
        return self._acc.render()

    def retained_message_bytes(self) -> Int:
        """Bytes retained by the accumulator (rows + notice) — O(annotation
        output), independent of the raw capture bytes the events carried."""
        return self._acc.retained_message_bytes()
