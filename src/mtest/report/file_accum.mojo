"""The per-file accumulator both spool-then-assemble reporters keep.

`JunitReporter` and `ReportWriter` share one mechanism and nothing else: while
a file runs they collect its per-test results and one record per non-final
retry attempt, keyed by the file's path, and drop that state the moment the
file's fragment is rendered. Both reach it through the same four operations —
find, ensure, reset, drop — because the event stream gives them the same
problem: `FILE_STARTED` may restart a path that already has state, a
`TEST_REPORTED` may arrive for a path that never announced a start, and a
finished file's state must not outlive its fragment.

The two differ in exactly one place, the attempt record: the JUnit reporter
keeps a typed struct it later renders into rerun children, while the report
writer keeps the one-line summary it already composed. That difference is the
type parameter `A`, and it is the only thing this module is generic over. The
per-test results are `TestResult` for both, since that is the type the event
payload carries.

`items` is public on purpose. A caller appends to `items[idx].tests` and reads
`items[idx].attempts` directly, rather than through accessors that would only
forward, so this module owns the keyed-lookup mechanism and makes no claim over
what either reporter does with the state it finds.
"""
from mtest.model import TestResult


@fieldwise_init
struct FileAccum[A: Copyable & Movable & ImplicitlyDeletable](
    Copyable, Movable
):
    """One file's state accumulated between FileStarted and FileFinished.

    Parameters:
        A: The attempt-record type the owning reporter keeps per non-final
            retry attempt.
    """

    var path: String
    """The file this accumulator belongs to; the lookup key."""
    var tests: List[TestResult]
    """The per-test results reported for it, in arrival order."""
    var attempts: List[Self.A]
    """One record per non-final retry attempt, in attempt order."""


struct FileAccums[A: Copyable & Movable & ImplicitlyDeletable](
    Copyable, Movable
):
    """The in-flight per-file accumulators, keyed by path.

    A small linear index rather than a map: a run holds accumulators only for
    the files currently in flight, which is one for a sequential run and
    `workers` for a parallel one, so the scan is over a handful of entries and
    the ordering stays the arrival order a reader can follow.

    Parameters:
        A: The attempt-record type the owning reporter keeps.

    Examples:

    ```mojo
    from mtest.report.file_accum import FileAccums

    var accums = FileAccums[String].empty()
    var idx = accums.ensure("tests/test_a.mojo")
    accums.items[idx].attempts.append("attempt 1/2: exited with status 1")
    accums.drop("tests/test_a.mojo")
    ```
    """

    var items: List[FileAccum[Self.A]]
    """The live accumulators, in the order their paths were first seen."""

    def __init__(out self, var items: List[FileAccum[Self.A]]):
        """Take ownership of an existing accumulator list.

        Args:
            items: The accumulators to adopt. Consumed.
        """
        self.items = items^

    @staticmethod
    def empty() -> Self:
        """A fresh index holding no accumulator."""
        return Self(List[FileAccum[Self.A]]())

    def index_of(self, path: String) -> Int:
        """The index of `path`'s accumulator, or `-1` when it has none.

        Args:
            path: The file path to look up.

        Returns:
            The index into `items`, or `-1`.
        """
        for i in range(len(self.items)):
            if self.items[i].path == path:
                return i
        return -1

    def ensure(mut self, path: String) -> Int:
        """The index of `path`'s accumulator, creating an empty one if absent.

        Args:
            path: The file path to look up or create state for.

        Returns:
            The index into `items`, always valid.
        """
        var idx = self.index_of(path)
        if idx >= 0:
            return idx
        self.items.append(
            FileAccum[Self.A](path.copy(), List[TestResult](), List[Self.A]())
        )
        return len(self.items) - 1

    def reset(mut self, path: String):
        """Begin a fresh accumulator for `path`, discarding any stale one.

        The `FILE_STARTED` operation: a retried or re-announced file must not
        inherit the rows of its previous attempt.

        Args:
            path: The file path starting a fresh accumulation.
        """
        var idx = self.index_of(path)
        if idx >= 0:
            self.items[idx].tests = List[TestResult]()
            self.items[idx].attempts = List[Self.A]()
            return
        self.items.append(
            FileAccum[Self.A](path.copy(), List[TestResult](), List[Self.A]())
        )

    def drop(mut self, path: String):
        """Remove `path`'s accumulator once its fragment has been rendered.

        A no-op when the path holds no state, so a caller may drop
        unconditionally.

        Args:
            path: The file path whose state is finished with.
        """
        var idx = self.index_of(path)
        if idx >= 0:
            _ = self.items.pop(idx)
