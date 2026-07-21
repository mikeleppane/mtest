"""`TestCounts`: the authoritative per-test totals.

The session's per-run tally at test granularity, distinct from the per-file
`Summary` in `events.mojo`.
"""


@fieldwise_init
struct TestCounts(ImplicitlyCopyable, Movable):
    """The authoritative passed, failed, skipped, and deselected test totals.

    Four plain Int fields with no owned resources, so copies and moves are
    trivial.
    """

    var passed: Int
    """How many tests passed."""
    var failed: Int
    """How many tests failed."""
    var skipped: Int
    """How many tests were skipped."""
    var deselected: Int
    """How many tests were deselected (suppressed from the run)."""

    @staticmethod
    def zeros() -> TestCounts:
        """A tally with every count at zero."""
        return TestCounts(passed=0, failed=0, skipped=0, deselected=0)
