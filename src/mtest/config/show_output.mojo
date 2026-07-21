"""The `--show-output` vocabulary.

Controls which files' captured stdout/stderr the console reporter renders: only
the ones that failed, every file, or none. It names a rendering choice rather
than a run outcome, which is why it lives in config and not in model.
"""


@fieldwise_init
struct ShowOutput(Equatable, ImplicitlyCopyable, Movable):
    """One value from the `--show-output` closed vocabulary.

    A wrapper over a stable integer discriminant, so the vocabulary is a closed
    set of named constants that compare by value.
    """

    var value: Int
    """The stable integer discriminant identifying this choice."""

    comptime FAILURES = Self(0)
    comptime ALL = Self(1)
    comptime NONE = Self(2)

    def __eq__(self, other: Self) -> Bool:
        """Whether both choices carry the same discriminant."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether the two choices carry different discriminants."""
        return self.value != other.value
