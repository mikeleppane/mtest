"""The `--shard` mode vocabulary.

Names how a shard claims its files: by a stateless hash of each file's path
(`hash`, the default) or by the file's index in the sorted run set (`slice`).
It names a partitioning choice rather than a run outcome, which is why it lives
in config and not in model.
"""


@fieldwise_init
struct ShardMode(Equatable, ImplicitlyCopyable, Movable):
    """One value from the `--shard` mode closed vocabulary.

    A wrapper over a stable integer discriminant, so the vocabulary is a closed
    set of named constants that compare by value.
    """

    var value: Int
    """The stable integer discriminant identifying this mode."""

    comptime HASH = Self(0)
    comptime SLICE = Self(1)

    def __eq__(self, other: Self) -> Bool:
        """Whether both modes carry the same discriminant."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether the two modes carry different discriminants."""
        return self.value != other.value
