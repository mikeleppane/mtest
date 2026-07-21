"""The per-file records the `session` run paths produce, and their operations.

Layer 4, beneath the orchestration that fills these in: `FileResult` is what
every step — the plain attempt loop, the build-and-probe pass, and the
selection run — hands back for one file, and `_CrashFile` is the diagnostic
record a CRASH verdict queues for the attribution post-pass. The two pure
operations the run loops perform on them live here too: merging an event
prologue onto a result, and counting the failing entries in a run-outcome
multiset for `--maxfail`.
"""
from mtest.model import Event, Outcome, TestCounts


@fieldwise_init
struct FileResult(Copyable, Movable):
    """The outcome of building and running one file, plus its control signals.

    Owns its lists and its event; copies are explicit.

    A completed file emits its `pre_events` in order, then its `event`. The
    session accumulates `test_counts` unconditionally, adding it before it
    inspects `is_drift`. A non-drift file also tallies `outcome` once in the
    summary and appends `exit_outcomes` to the run outcomes. A drift file emits
    its events and forces exit 3; drift suppresses the file-level outcome and
    exit-outcome tally, not the per-test totals.
    `internal_error` and `interrupted` are mutually exclusive short-circuits:
    the session emits `event` (for an internal error) and resolves the exit code
    (3 or 2) directly.
    """

    var pre_events: List[Event]
    """Events to emit before `event`: per-test `TestReported` rows, then a loud
    `Warning` when the classification demands one (empty otherwise)."""
    var event: Event
    """The event to emit: a `FileFinished` verdict when `ran`, an
    `InternalError` diagnostic when `internal_error`."""
    var outcome: Outcome
    """The file-level outcome to tally once (only meaningful when `ran`)."""
    var exit_outcomes: List[Outcome]
    """The exit-code multiset contribution: per-test for a valid report, else a
    single file-level entry; empty for a drift file."""
    var test_counts: TestCounts
    """The per-test passed/failed/skipped tally to accumulate run-wide."""
    var ran: Bool
    """Whether the file produced a real verdict to emit and tally."""
    var internal_error: Bool
    """Whether a spawn failure occurred (routes to internal-error exit 3)."""
    var interrupted: Bool
    """Whether an interrupt aborted this file (routes to exit 2)."""
    var is_drift: Bool
    """Whether the report drifted off the pinned grammar (forces exit 3)."""
    var binary_path: String
    """The binary this file's run actually executed, or empty when none ran.

    Carried so the crash-attribution post-pass can rerun that exact binary
    rather than reconstruct a name for it: a crash-class build retry rebuilds to
    `build/bin/<mangled>.inv-<nonce>.attempt-N` and runs that, so the mangled
    name is not always the thing that crashed. Diagnostics only; no verdict
    reads it."""

    @staticmethod
    def ran_with(var event: Event, outcome: Outcome) -> Self:
        """Build a completed file whose only multiset entry is its own outcome.

        Used by the build compile-error path, which has no per-test report.

        Args:
            event: The `FileFinished` verdict to emit. Consumed; the returned
                `FileResult` owns it.
            outcome: The file-level outcome, tallied and used as the sole
                exit-code multiset entry.

        Returns:
            The completed `FileResult`.
        """
        return Self(
            List[Event](),
            event^,
            outcome,
            [outcome],
            TestCounts.zeros(),
            True,
            False,
            False,
            False,
            "",
        )

    @staticmethod
    def classified(
        var pre_events: List[Event],
        var event: Event,
        outcome: Outcome,
        var exit_outcomes: List[Outcome],
        test_counts: TestCounts,
        is_drift: Bool,
    ) -> Self:
        """Build a completed run carrying per-test events and exit outcomes.

        Args:
            pre_events: Per-test rows and any warning, emitted before `event`.
                Consumed; the returned `FileResult` owns it.
            event: The `FileFinished` verdict to emit. Consumed; the returned
                `FileResult` owns it.
            outcome: The file-level outcome to tally once.
            exit_outcomes: The exit-code multiset contribution. Consumed; the
                returned `FileResult` owns it.
            test_counts: The per-test passed/failed/skipped tally.
            is_drift: Whether the report drifted off the pinned grammar, which
                forces exit 3 and suppresses tallying.

        Returns:
            The completed `FileResult`.
        """
        return Self(
            pre_events^,
            event^,
            outcome,
            exit_outcomes^,
            test_counts,
            True,
            False,
            False,
            is_drift,
            "",
        )

    @staticmethod
    def internal(var event: Event) -> Self:
        """Build a spawn failure: no verdict, and the session exits 3.

        Args:
            event: The `InternalError` diagnostic to emit. Consumed; the
                returned `FileResult` owns it.

        Returns:
            The internal-error `FileResult`.
        """
        return Self(
            List[Event](),
            event^,
            Outcome.NOT_RUN,
            List[Outcome](),
            TestCounts.zeros(),
            False,
            True,
            False,
            False,
            "",
        )

    @staticmethod
    def interrupt() -> Self:
        """Build an interrupted file: no verdict, and the session exits 2.

        Returns:
            The interrupted `FileResult`.
        """
        return Self(
            List[Event](),
            Event.file_started(""),
            Outcome.NOT_RUN,
            List[Outcome](),
            TestCounts.zeros(),
            False,
            False,
            True,
            False,
            "",
        )


@fieldwise_init
struct _CrashFile(Copyable, Movable):
    """One crashed file queued for attribution, with the binary that ran.

    The binary is carried, never reconstructed from `rel`: a crash-class build
    retry rebuilds to `build/bin/<mangled>.inv-<nonce>.attempt-N` and runs that,
    so only the run itself knows what actually crashed.
    """

    var rel: String
    """The root-relative path of the crashed file."""
    var binary: String
    """The binary its crashed run executed."""
    var selected: List[String]
    """The test names actually selected in this run; empty means no selection
    was active, so all names qualify. Attribution isolates only these, never a
    deselected test that never ran under the user's `-k` or `--only`."""


def _prepend_events(var extra: List[Event], var fr: FileResult) -> FileResult:
    """Prepend `extra` events to `fr.pre_events`, consuming both.

    Args:
        extra: Attempt and recovery events that happened before the verdict.
            Consumed.
        fr: The file result to prepend onto. Consumed; it is returned.

    Returns:
        `fr` with the merged event stream.
    """
    if len(extra) == 0:
        return fr^
    var merged = List[Event]()
    for e in extra:
        merged.append(e.copy())
    for e in fr.pre_events:
        merged.append(e.copy())
    fr.pre_events = merged^
    return fr^


def _failing_count(outcomes: List[Outcome]) -> Int:
    """Count the failing-class entries in a run-outcome multiset.

    `outcomes` is already test-granular — per-test for a valid report, one
    file-level entry otherwise — so this is exactly the `--maxfail` counter:
    each element counts once, with no re-derivation from file-level outcomes.

    Args:
        outcomes: The accumulated run-outcome multiset.

    Returns:
        How many entries are failing-class."""
    var n = 0
    for o in outcomes:
        if o.is_failing():
            n += 1
    return n
