"""The comptime fan-out: `CompositeReporter`.

Fans every event to every reporter in a comptime-known tuple, via static
dispatch. Mojo 1.0.0b2 polymorphism is static, so this is a variadic
type-parameter pack (`*Rs: Reporter`) over a `Tuple`, not a runtime
heterogeneous trait-object list. Adding a reporter means adding a tuple element
at the call site; dispatch stays fully static.
"""
from mtest.model import Event

from mtest.report.reporter import Reporter


struct CompositeReporter[*Rs: Reporter]:
    """Fans one event to a comptime tuple of reporters via static dispatch.

    Stores the reporters in a `Tuple` and, on each event, iterates the pack at
    compile time so every reporter's concrete `handle` is called directly — no
    virtual dispatch, no boxing. Build it at the call site with a pre-built
    tuple: `CompositeReporter(Tuple(a, b))`, letting `Rs` be inferred.

    Parameters:
        Rs: The concrete reporter types to compose, in fan-out order.
    """

    var reporters: Tuple[*Self.Rs]
    """The composed reporters, one per pack element, in fan-out order."""

    comptime N = Self.Rs.__len__()
    """How many reporters are composed — a compile-time constant."""

    def __init__(out self, var reporters: Tuple[*Self.Rs]):
        """Take ownership of the pre-built reporter tuple.

        Args:
            reporters: The reporters to fan events to, in fan-out order.
                Consumed.
        """
        self.reporters = reporters^

    def handle(mut self, e: Event):
        """Fan the event to every composed reporter, in order.

        Args:
            e: The event to dispatch.
        """
        comptime for i in range(Self.N):
            self.reporters[i].handle(e)
