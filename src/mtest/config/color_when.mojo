"""The `--color` vocabulary.

Controls whether the console reporter colorizes output: automatically (only on
a TTY), always, or never.
"""


@fieldwise_init
struct ColorWhen(Equatable, ImplicitlyCopyable, Movable):
    """One value from the `--color` closed vocabulary.

    A wrapper over a stable integer discriminant, so the vocabulary is a closed
    set of named constants that compare by value.
    """

    var value: Int
    """The stable integer discriminant identifying this choice."""

    comptime AUTO = Self(0)
    comptime ALWAYS = Self(1)
    comptime NEVER = Self(2)

    def __eq__(self, other: Self) -> Bool:
        """Whether both choices carry the same discriminant."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether the two choices carry different discriminants."""
        return self.value != other.value
