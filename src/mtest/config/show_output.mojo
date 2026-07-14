"""The `--show-output` vocabulary of the mtest runner (Layer 1).

Controls which files' captured stdout/stderr the console reporter renders: only
the ones that failed, every file, or none. This is a config concern, not a
model one — it names a rendering choice, not a run outcome.
"""


@fieldwise_init
struct ShowOutput(Equatable, ImplicitlyCopyable, Movable):
    """One value from the `--show-output` closed vocabulary.

    A thin wrapper over a stable integer discriminant so the vocabulary is a
    closed set of named constants that compare by value. Holds no owned
    resources; copies and moves are trivial and it never raises.
    """

    var value: Int
    """The stable integer discriminant identifying this choice."""

    comptime FAILURES = Self(0)
    comptime ALL = Self(1)
    comptime NONE = Self(2)

    def __eq__(self, other: Self) -> Bool:
        """Two choices are equal iff their discriminants match. Pure."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Pure."""
        return self.value != other.value
