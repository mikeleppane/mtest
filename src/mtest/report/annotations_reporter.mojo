"""The stateful GitHub Actions annotations reporter (Layer 2).

Where `annotations` is the PURE renderer (`List[Event] -> List[String]`), this is
the thin stateful shell around it: a `Reporter` that accumulates the event stream
the renderer needs and, on demand, renders the deterministic annotation tail. It
SELF-GATES on the resolved `--gh-annotations` mode — an INACTIVE reporter (mode
`off`, or `auto` outside GitHub Actions) records nothing and renders nothing, so
composing it is always safe and costs nothing when annotations are not wanted.

`handle` is TOTAL and NON-RAISING per the `Reporter` seam. The reporter never
prints: `main` reaches the concrete reporter at its fixed composite index (the
compile-time type-checked typed-`Pointer` pattern the session uses for the stream
and JUnit reporters) and writes the rendered lines to stdout in the deterministic
tail after the console summary band — but only once `SessionFinished` has been
seen, so the single `::notice` is always present. `Copyable, Movable` (owns a
`List[Event]`) so it slots into the reporter composition.
"""
from mtest.model import Event

from mtest.report.annotations import render_annotations
from mtest.report.reporter import Reporter


struct AnnotationsReporter(Reporter):
    """A `Reporter` that accumulates events and renders the annotation tail.

    Self-gates on `active` (the resolved-on decision `main` derives from the
    `--gh-annotations` mode and `GITHUB_ACTIONS`): when inactive it accumulates
    nothing and `render` returns an empty list, so an off/auto-outside-Actions
    run pays only the empty composition slot. `handle` is total and non-raising.
    """

    var _active: Bool
    """Whether annotations render at all; `False` is the resolved-off shape."""
    var _events: List[Event]
    """The accumulated event stream the renderer consumes (empty when inactive).
    """

    def __init__(out self, active: Bool):
        """Construct a reporter, self-gated on the resolved-on decision.

        Args:
            active: Whether annotations render (the resolved-on decision from the
                `--gh-annotations` mode and `GITHUB_ACTIONS`). `False` yields an
                inert reporter that accumulates and renders nothing.
        """
        self._active = active
        self._events = List[Event]()

    @staticmethod
    def inert() -> Self:
        """The resolved-off reporter: accumulates nothing, renders nothing."""
        return Self(False)

    def handle(mut self, e: Event):
        """Accumulate one event when active. Total over the event set; never
        raises. Emits nothing on its own — `main` renders the tail via `render`.
        """
        if not self._active:
            return
        self._events.append(e.copy())

    def render(self) -> List[String]:
        """The deterministic annotation tail for the whole run.

        Delegates to the pure `render_annotations`: the node-id-sorted `::error`
        block, then the node-id-sorted `::warning` block, then the single
        `::notice` (present once `SessionFinished` was accumulated). An inactive
        reporter returns an empty list. Does not mutate or raise.
        """
        if not self._active:
            return List[String]()
        return render_annotations(self._events)
