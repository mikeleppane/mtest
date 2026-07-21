"""The closed report-parse vocabulary.

`ParseDisposition` names why the protocol layer's report parse landed where it
did, so a `FileFinished` event can carry the parse verdict as data rather than
collapsing it into MALFORMED_SUITE before the reporter sees it. It mirrors
`Outcome`'s shape: a thin wrapper over a stable integer discriminant.
"""


@fieldwise_init
struct ParseDisposition(Equatable, ImplicitlyCopyable, Movable):
    """One value from the report-parse disposition vocabulary.

    A thin wrapper over a stable integer discriminant, holding no owned
    resources, so copies and moves are trivial.
    """

    var code: Int
    """The stable integer discriminant identifying this disposition."""

    comptime PARSED = Self(0)
    """A valid report was parsed."""
    comptime NO_REPORT = Self(1)
    """No matching report block is present in the captured output."""
    comptime AMBIGUOUS = Self(2)
    """Multiple report blocks, or a forged one, were found."""
    comptime DRIFT = Self(3)
    """An off-grammar report from the pinned toolchain (the format moved)."""
    comptime CAPTURE_OVERFLOW = Self(4)
    """Output was truncated, so no report block can be trusted."""

    comptime COUNT = 5
    """The number of distinct values in the vocabulary."""

    def __eq__(self, other: Self) -> Bool:
        """Two dispositions are equal iff their discriminants match."""
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return self.code != other.code
