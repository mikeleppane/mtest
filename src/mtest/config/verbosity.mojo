"""The verbosity vocabulary.

Controls how much the console reporter prints per file: quiet, normal, or
verbose. This module only names the vocabulary; enforcing that `-q` and `-v`
are mutually exclusive is the parser's job.
"""


@fieldwise_init
struct Verbosity(Equatable, ImplicitlyCopyable, Movable):
    """One value from the verbosity closed vocabulary.

    A wrapper over a stable integer discriminant, so the vocabulary is a closed
    set of named constants that compare by value.
    """

    var value: Int
    """The stable integer discriminant identifying this level."""

    comptime QUIET = Self(0)
    comptime NORMAL = Self(1)
    comptime VERBOSE = Self(2)

    def __eq__(self, other: Self) -> Bool:
        """Whether both levels carry the same discriminant."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether the two levels carry different discriminants."""
        return self.value != other.value
