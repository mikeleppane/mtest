"""`AttributionDisposition`: the closed crash-attribution vocabulary (Layer 0).

Mirrors `ParseDisposition`'s shape: a thin wrapper over a stable integer
discriminant naming why a bounded crash-isolation pass stopped where it did, so
a `CrashAttribution` event can carry the verdict as data instead of collapsing
it into a rendered sentence before the reporter ever sees it.
"""


@fieldwise_init
struct AttributionDisposition(Equatable, ImplicitlyCopyable, Movable):
    """One value from the crash-attribution disposition vocabulary.

    A thin wrapper over a stable integer discriminant. Holds no owned
    resources; copies and moves are trivial and it never raises.
    """

    var code: Int
    """The stable integer discriminant identifying this disposition."""

    comptime ATTRIBUTED = Self(0)
    """A single culprit test was isolated and named as the crash's cause."""
    comptime NO_REPRODUCTION = Self(1)
    """The crash did not reproduce under isolation; no culprit was attributed."""
    comptime PROBE_FAILED = Self(2)
    """An isolation probe could not run (a spawn or machinery failure), so the
    pass gave up before reaching a verdict."""
    comptime RUN_CAP = Self(3)
    """The isolation rerun budget was exhausted before a culprit was isolated."""
    comptime TIME_BUDGET = Self(4)
    """The attribution wall-time budget was exhausted before a verdict."""

    comptime COUNT = 5
    """The number of distinct values in the vocabulary."""

    def __eq__(self, other: Self) -> Bool:
        """Two dispositions are equal iff their discriminants match. Pure."""
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Pure."""
        return self.code != other.code
