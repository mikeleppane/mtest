"""The `--shard` mode vocabulary of the mtest runner (Layer 1).

Names how a shard claims its files: by a stateless hash of each file's path
(`hash`, the default) or by the file's index in the sorted run set (`slice`).
This is a config concern — it names a partitioning choice, not a run outcome.
"""


@fieldwise_init
struct ShardMode(Equatable, ImplicitlyCopyable, Movable):
    """One value from the `--shard` mode closed vocabulary.

    A thin wrapper over a stable integer discriminant so the vocabulary is a
    closed set of named constants that compare by value. Holds no owned
    resources; copies and moves are trivial and it never raises.
    """

    var value: Int
    """The stable integer discriminant identifying this mode."""

    comptime HASH = Self(0)
    comptime SLICE = Self(1)

    def __eq__(self, other: Self) -> Bool:
        """Two modes are equal iff their discriminants match. Pure."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Pure."""
        return self.value != other.value
