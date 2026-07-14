"""The verbosity vocabulary of the mtest runner (Layer 1).

Controls how much the console reporter prints per file: quiet, normal, or
verbose. `-q`/`-v` are mutually exclusive on the command line, but that
enforcement is the parser's concern — this module only names the vocabulary.
"""


@fieldwise_init
struct Verbosity(Equatable, ImplicitlyCopyable, Movable):
    """One value from the verbosity closed vocabulary.

    A thin wrapper over a stable integer discriminant so the vocabulary is a
    closed set of named constants that compare by value. Holds no owned
    resources; copies and moves are trivial and it never raises.
    """

    var value: Int
    """The stable integer discriminant identifying this level."""

    comptime QUIET = Self(0)
    comptime NORMAL = Self(1)
    comptime VERBOSE = Self(2)

    def __eq__(self, other: Self) -> Bool:
        """Two levels are equal iff their discriminants match. Pure."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Pure."""
        return self.value != other.value
