"""The stateful GitHub Actions annotations reporter.

Where `annotations` is the pure renderer, this is the thin stateful shell
around it: a `Reporter` that feeds each event through an
`AnnotationAccumulator` as it arrives and, on demand, renders the deterministic
annotation tail. It self-gates on the resolved `--gh-annotations` mode — an
inactive reporter (mode `off`, or `auto` outside GitHub Actions) records
nothing and renders nothing, so composing it is always safe and costs nothing
when annotations are not wanted.

Retention is online and bounded per event: `handle` extracts an event's
annotation rows immediately and drops the event, so the reporter never holds
the multi-megabyte captured output a `FileFinished`/`AttemptFinished` carries
(the renderer never reads it), and each row's message is bounded as it is
built. The rows themselves all persist until `render`; the caps bound the
output, not the accumulation. A CI-scale run of hundreds of large-capture
failures therefore cannot exhaust memory, though it accumulates far more rows
than it prints. The tail is capped at 10 `::error` lines and 10 `::warning`
lines, plus the single `::notice` — at most 21 lines.

`handle` is total and non-raising, per the `Reporter` seam. The reporter never
prints: `main` reaches the concrete reporter at its fixed composite index and
writes the rendered lines to stdout in the tail after the console summary band,
once `SessionFinished` has been seen so the single `::notice` is present.
`Copyable, Movable` so it slots into the reporter composition.
"""
from mtest.model import Event

from mtest.report.annotations import AnnotationAccumulator
from mtest.report.reporter import Reporter


struct AnnotationsReporter(Reporter):
    """A `Reporter` that accumulates annotation rows and renders the tail.

    Self-gates on the resolved-on decision `main` derives from the
    `--gh-annotations` mode and `GITHUB_ACTIONS`: when inactive it accumulates
    nothing and `render` returns an empty list, so an off/auto-outside-Actions
    run pays only the empty composition slot.
    """

    var _active: Bool
    """Whether annotations render at all; `False` is the resolved-off shape."""
    var _acc: AnnotationAccumulator
    """The online row accumulator: lightweight rows only, never raw captures."""

    def __init__(out self, active: Bool):
        """Construct a reporter, self-gated on the resolved-on decision.

        Args:
            active: Whether annotations render, as resolved from the
                `--gh-annotations` mode and `GITHUB_ACTIONS`. `False` yields an
                inert reporter that accumulates and renders nothing.
        """
        self._active = active
        self._acc = AnnotationAccumulator()

    @staticmethod
    def inert() -> Self:
        """The resolved-off reporter: accumulates nothing, renders nothing."""
        return Self(False)

    def handle(mut self, e: Event):
        """Accumulate one event's annotation rows when active, then drop it.

        Emits nothing on its own — `main` renders the tail via `render`.

        Args:
            e: The event to extract annotation rows from. Not retained.
        """
        if not self._active:
            return
        self._acc.observe(e)

    def render(self) -> List[String]:
        """The deterministic annotation tail for the whole run.

        Returns:
            The sort-key-ordered `::error` block, then the sort-key-ordered
            `::warning` block, then the single `::notice` (present once
            `SessionFinished` was seen). Empty when the reporter is inactive.
        """
        if not self._active:
            return List[String]()
        return self._acc.render()

    def retained_message_bytes(self) -> Int:
        """Bytes retained by the accumulator, as rows plus notice.

        O(annotation output), independent of the raw capture bytes the events
        carried. An inactive reporter has accumulated nothing, so this is 0.
        """
        return self._acc.retained_message_bytes()
