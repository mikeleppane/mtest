"""The per-file records the `session` run paths produce, and their operations.

Layer 4, holding both the records and the step that retires one. `FileResult` is
what every driver hands back for one file: the plain attempt loop, the
build-and-probe pass, and the selection run. `_CrashFile` is the diagnostic
record a CRASH verdict queues for the attribution post-pass. `RunTally` is what
a driver accumulates as those results land.

`settle_file` is the orchestration that turns one into the other, and it reaches
across to `report` and to the pipeline kernel to do it: it emits the file's
prologue and verdict to a `ReportCoordinator`, tallies the outcome into a
`Summary`, folds the totals, and records the verdict against a `RunPipeline`'s
stop policy. It lives beside the records because it is the only path from a
result to a tally, and the gate loop, the plain run loop, the selection
sub-session, and the parallel pool must not drift apart on what a verdict does
to a run.
"""
from mtest.model import Event, Outcome, Summary, TestCounts
from mtest.report import ReportCoordinator
from mtest.session.effective_settings import EffectiveFileSettings
from mtest.session.pipeline import RunPipeline


@fieldwise_init
struct FileResult(Copyable, Movable):
    """The outcome of building and running one file, plus its control signals.

    Owns its lists and its event; copies are explicit.

    A completed file emits its `pre_events` in order, then its `event`. The
    session accumulates `test_counts` unconditionally, before it inspects
    `is_drift`. A non-drift file also tallies `outcome` once in the summary and
    appends `exit_outcomes` to the run outcomes. A drift file emits its events
    and forces exit 3; drift suppresses the file-level outcome and exit-outcome
    tally, not the per-test totals.

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

        Examples:

        ```mojo
        from mtest.model import Event, Outcome
        from mtest.session.file_result import FileResult

        var argv: List[String] = ["mojo", "build", "tests/test_a.mojo"]
        var ev = Event.file_finished(
            "tests/test_a.mojo", Outcome.COMPILE_ERROR, 0.0, argv^, 1.5,
            List[UInt8](), List[UInt8]()
        )
        var fr = FileResult.ran_with(ev^, Outcome.COMPILE_ERROR)
        ```
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
    var settings: EffectiveFileSettings
    """The file's effective deadlines and retry/serial policy."""
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


@fieldwise_init
struct RunTally(Copyable, Movable):
    """What a run accumulates as its files settle, wherever they ran.

    Owns its lists; copies are explicit. Every driver targets one of these —
    the gate loop and the plain run loop share the session's, the selection
    sub-session and each pooled batch keep their own and fold it back — so a
    run's totals are added up in exactly one shape.
    """

    var run_outcomes: List[Outcome]
    """The exit-code multiset, test-granular for a valid report and one
    file-level entry otherwise."""
    var test_totals: TestCounts
    """The per-test passed/failed/skipped/deselected totals."""
    var ran_files: Int
    """How many files produced a tallied verdict."""
    var crash_files: List[_CrashFile]
    """The files that ended CRASH, in discovery order, for the bounded
    attribution post-pass. Diagnostics only: this list feeds no count, no
    outcome multiset, and no exit code."""
    var drift: Bool
    """Whether any report drifted off the pinned grammar (forces exit 3)."""
    var aborted: Bool
    """Whether a failing or drifting gate aborted the whole run."""
    var interrupted: Bool
    """Whether an interrupt abandoned unfinished work (exit 2)."""
    var internal_error: Bool
    """Whether a spawn or machinery failure occurred (exit 3)."""
    var console_dead: Bool
    """Whether a console flush could not deliver its bytes for a reason other
    than a departed consumer. The exit-code model ranks it, so a run that
    printed nothing cannot report a verdict it never showed anyone."""

    @staticmethod
    def zeros() -> Self:
        """A tally with nothing accumulated and nothing latched."""
        return Self(
            List[Outcome](),
            TestCounts.zeros(),
            0,
            List[_CrashFile](),
            False,
            False,
            False,
            False,
            False,
        )

    def merge(mut self, other: Self):
        """Fold another tally's whole contents into this one.

        Args:
            other: The tally to absorb — a pooled batch's or the selection
                sub-session's. Copied, not consumed; every list grows.
        """
        self.run_outcomes.extend(other.run_outcomes.copy())
        self.test_totals.passed += other.test_totals.passed
        self.test_totals.failed += other.test_totals.failed
        self.test_totals.skipped += other.test_totals.skipped
        self.test_totals.deselected += other.test_totals.deselected
        self.ran_files += other.ran_files
        self.crash_files.extend(other.crash_files.copy())
        self.drift = self.drift or other.drift
        self.aborted = self.aborted or other.aborted
        self.interrupted = self.interrupted or other.interrupted
        self.internal_error = self.internal_error or other.internal_error
        self.console_dead = self.console_dead or other.console_dead


def settle_file[
    C: ReportCoordinator
](
    mut tally: RunTally,
    mut reporter: C,
    mut summary: Summary,
    mut pipeline: RunPipeline,
    index: Int,
    rel: String,
    settings: EffectiveFileSettings,
    binary: String,
    selected: List[String],
    var pre: List[Event],
    var fr: FileResult,
    is_gate: Bool = False,
) raises -> Bool:
    """Settle one file's verdict: emit it, account it, and apply the policy.

    Prepends the file's accumulated prologue, emits the verdict, and folds the
    per-test totals. For a non-drift verdict it then tallies the outcome,
    extends the run multiset, records the verdict against the stop policy, and
    queues a crash for attribution. A drift verdict forces exit 3 and is
    accounted NOT-RUN rather than tallied: it never reaches the summary, the
    multiset, or the `-x`/`--maxfail` counters.

    Args:
        tally: The run accumulator this verdict lands in.
        reporter: The coordinator the prologue and the verdict are handed to.
        summary: The run summary to tally the file-level outcome into.
        pipeline: The stop-policy kernel.
        index: The settling file's index in discovery order.
        rel: The settling file's root-relative path.
        settings: The file's effective deadlines and retry/serial policy.
        binary: The binary this file's run executed, for a queued crash. The
            crash-attribution pass reruns it rather than reconstructing a name,
            because a crash-class build retry runs a per-attempt path.
        selected: The test names this run selected, for a queued crash. Empty
            means no selection was active, so every name qualifies.
        pre: Attempt and recovery events that happened before the verdict.
            Consumed; empty when the result already carries its own prologue.
        fr: The file's terminal result. Consumed.
        is_gate: Whether this is a gate, which aborts the whole run on a
            failing or drifting verdict and queues no crash for attribution.

    Returns:
        True when a gate verdict aborts the run and the caller must stop.

    Raises:
        Error: If the reporter cannot deliver an event.
    """
    var settled = _prepend_events(pre^, fr^)
    for pe in settled.pre_events:
        reporter.handle(pe)
    reporter.handle(settled.event)
    tally.test_totals.passed += settled.test_counts.passed
    tally.test_totals.failed += settled.test_counts.failed
    tally.test_totals.skipped += settled.test_counts.skipped
    tally.test_totals.deselected += settled.test_counts.deselected

    if settled.is_drift:
        tally.drift = True
        pipeline.record_settled(index)
        if is_gate:
            # A drifting gate is at least as serious as a failing one: a gate
            # exists to stop the run early, and drift keeps exit-3 precedence
            # over the exit 1 a failing gate resolves to.
            tally.aborted = True
            return True
        return False

    summary.counts[settled.outcome.code] += 1
    tally.run_outcomes.extend(settled.exit_outcomes.copy())
    tally.ran_files += 1
    if (not is_gate) and settled.outcome == Outcome.CRASH:
        tally.crash_files.append(
            _CrashFile(rel, settings, binary, selected.copy())
        )
    pipeline.record_verdict(
        index, settled.outcome.is_failing(), _failing_count(tally.run_outcomes)
    )
    if is_gate and settled.outcome.is_failing():
        tally.aborted = True
        return True
    return False


def _failing_count(outcomes: List[Outcome]) -> Int:
    """Count the failing-class entries in a run-outcome multiset.

    `outcomes` is already test-granular (per-test for a valid report, one
    file-level entry otherwise), so this is exactly the `--maxfail` counter:
    each element counts once, with no re-derivation from file-level outcomes.

    Args:
        outcomes: The accumulated run-outcome multiset.

    Returns:
        How many entries are failing-class.
    """
    var n = 0
    for o in outcomes:
        if o.is_failing():
            n += 1
    return n
