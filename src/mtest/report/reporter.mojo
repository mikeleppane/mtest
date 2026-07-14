"""The reporter seam: the `Reporter` trait (Layer 2).

The session (a later layer) emits the closed `Event` set and nothing else, and
every reporter consumes that stream through a single method, `handle`. This one
method is what lets heterogeneous reporters compose statically: a
`CompositeReporter` fans one event to a comptime-known tuple of reporters, each
conforming to this trait.

`handle` must be TOTAL over the event set — it must accept every `EventKind`
without raising, because the session cannot recover from a reporter that throws
mid-run. Reporters are `Copyable, Movable` so they can be moved into the
composition tuple and their state read back by index.
"""
from mtest.model import Event


trait Reporter(Copyable, Movable):
    """A consumer of the session's event stream.

    One method, `handle`, receives every event in emission order. Conforming
    reporters own whatever state they accumulate (a recorded list, a rendered
    buffer); the trait fixes only the seam.
    """

    def handle(mut self, e: Event):
        """Consume one event. Total over the event set; must not raise."""
        ...
