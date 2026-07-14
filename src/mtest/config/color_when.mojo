"""The `--color` vocabulary of the mtest runner (Layer 1).

Controls whether the console reporter colorizes output: automatically (only on
a TTY), always, or never.
"""


@fieldwise_init
struct ColorWhen(Equatable, ImplicitlyCopyable, Movable):
    """One value from the `--color` closed vocabulary.

    A thin wrapper over a stable integer discriminant so the vocabulary is a
    closed set of named constants that compare by value. Holds no owned
    resources; copies and moves are trivial and it never raises.
    """

    var value: Int
    """The stable integer discriminant identifying this choice."""

    comptime AUTO = Self(0)
    comptime ALWAYS = Self(1)
    comptime NEVER = Self(2)

    def __eq__(self, other: Self) -> Bool:
        """Two choices are equal iff their discriminants match. Pure."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Pure."""
        return self.value != other.value
