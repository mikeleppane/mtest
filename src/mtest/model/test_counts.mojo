"""`TestCounts`: authoritative per-test totals (Layer 0).

The session's per-run tally at TEST granularity, distinct from the per-FILE
`Summary` in `events.mojo`. Trivial Int fields with no owned resources, so the
type is `ImplicitlyCopyable`.
"""


@fieldwise_init
struct TestCounts(ImplicitlyCopyable, Movable):
    """The authoritative passed/failed/skipped/deselected test totals.

    Four plain Int fields; copies and moves are trivial and it never raises.
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
        """Every count at zero. Never raises."""
        return TestCounts(passed=0, failed=0, skipped=0, deselected=0)
