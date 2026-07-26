"""The comptime fan-out: `CompositeReporter`.

Fans every event to every reporter in a comptime-known tuple, via static
dispatch. Mojo 1.0.0b2 polymorphism is static, so this is a variadic
type-parameter pack (`*Rs: Reporter`) over a `Tuple`, not a runtime
heterogeneous trait-object list. Adding a reporter means adding a tuple element
at the call site; dispatch stays fully static.
"""
from mtest.model import Event

from mtest.report.reporter import Reporter


struct CompositeReporter[*Rs: Reporter](Movable):
    """Fans one event to a comptime tuple of reporters via static dispatch.

    Stores the reporters in a `Tuple` and, on each event, iterates the pack at
    compile time, so every reporter's concrete `handle` is called directly with
    no virtual dispatch and no boxing. Build the tuple at the call site and move
    it in, as `CompositeReporter(Tuple(a, b))` with `Rs` inferred: a
    `VariadicPack` cannot be splatted into a `Tuple`, so the pack cannot be
    assembled inside `__init__`. Inside the struct the pack is spelled
    `Self.Rs`, and its length comes from the comptime `Self.Rs.__len__()`.

    `Movable` is declared so a composite can be moved into a coordinator's
    field. `Copyable` cannot be: `Tuple[*Self.Rs]` has no synthesizable copy
    constructor, so a copy-bounded conformance fails to compile even when every
    element type is itself copyable.

    A composed reporter is read back at a comptime index, `reporters[i]`, so a
    wrong index fails to compile rather than becoming undefined behavior.

    Parameters:
        Rs: The concrete reporter types to compose, in fan-out order.

    Examples:

    ```mojo
    from mtest.model import Event
    from mtest.report import CompositeReporter
    from mtest.report import RecordingReporter

    var comp = CompositeReporter(Tuple(RecordingReporter(), RecordingReporter()))
    comp.handle(Event.file_started("tests/test_a.mojo"))
    var seen = comp.reporters[1].count()  # 1
    ```
    """

    var reporters: Tuple[*Self.Rs]
    """The composed reporters, one per pack element, in fan-out order."""

    comptime N = Self.Rs.__len__()
    """How many reporters are composed, as a compile-time constant."""

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
