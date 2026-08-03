"""Why a selected file never produced a tallied verdict.

`NotRunReason` closes the vocabulary the session classifies a NOT_RUN
casualty into. `classify_not_run` is the one place that vocabulary's
precedence is decided: pure and total over `NotRunFacts`, so the session
states the facts it observed for one file and this module ranks them, exactly
as `resolve_exit_code` ranks a run's terminal facts. `NotRunRecord` pairs one
reason with the file path it explains — delivered for EVERY selected file,
gate and run alike, including a file that DID produce a verdict, because a
consumer with verdict knowledge (the report writer's row index) filters,
exactly as `JunitReporter.note_not_run` already skips a path that spooled a
suite. This module imports nothing internal, so every layer above can consult
it.
"""


@fieldwise_init
struct NotRunReason(Equatable, ImplicitlyCopyable, Movable):
    """Why a selected file never produced a tallied verdict.

    A closed integer discriminant over the causes the session distinguishes;
    every renderer over it must stay total.
    """

    var code: Int
    """The stable integer discriminant identifying this reason."""

    comptime GATE_CASUALTY = Self(0)
    """A gate-owned file that never reached a verdict."""
    comptime GATE_ABORT = Self(1)
    """A failing gate aborted the session before this file ran."""
    comptime LIMIT_REACHED = Self(2)
    """-x / --maxfail stopped scheduling before this file ran."""
    comptime INTERRUPTED = Self(3)
    """An interrupt stopped scheduling before this file ran."""
    comptime INTERNAL_ERROR = Self(4)
    """A spawn or machinery failure aborted the run."""
    comptime PRECOMPILE_CASUALTY = Self(5)
    """A failed precompile step made every selected file a casualty."""
    comptime DRIFT_HALT = Self(6)
    """Protocol drift halted the session before this file ran."""
    comptime DELIVERY_ABORT = Self(7)
    """The terminal stream died; scheduling stopped rather than run unrecorded."""

    def __eq__(self, other: Self) -> Bool:
        """Two reasons are equal when their discriminants are equal."""
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return self.code != other.code


@fieldwise_init
struct NotRunFacts(ImplicitlyCopyable, Movable):
    """What the session observed about one selected file's stopped run.

    Seven independent observations and no policy: which of them wins is
    `classify_not_run`'s decision alone. Plain Bool fields with no owned
    resources, so copies and moves are trivial.
    """

    var interrupt_latched: Bool
    """Whether an interrupt was latched by the time accounting was sealed."""
    var internal_error: Bool
    """Whether the runner's own machinery failed: a spawn failure or a raise."""
    var drift: Bool
    """Whether any report drifted off the pinned toolchain grammar."""
    var precompile_failed: Bool
    """Whether a precompile step failed, making every selected file a
    casualty."""
    var gate_abort: Bool
    """Whether a failing or drifting gate aborted the session."""
    var stream_dead: Bool
    """Whether the terminal stream latched a delivery failure."""
    var is_gate_file: Bool
    """Whether the file this classification is for is itself a gate."""


def classify_not_run(facts: NotRunFacts) -> NotRunReason:
    """Classify why one selected file never produced a tallied verdict.

    Pure and total over `facts`: every possible combination maps to exactly
    one reason. Latched causal facts rank first, in their causal order — a
    latched earlier cause explains the stop even when the exit-code resolver
    later escalates for delivery, because these rows answer "why did this
    file not run" while `resolve_exit_code` separately answers "can the
    verdict be trusted". `stream_dead` ranks below every latched cause and
    above the bare gate-membership heuristic: a gate file that never ran
    because the stream died is a delivery casualty, not a gate casualty, when
    no gate actually aborted.

    Args:
        facts: What the session observed for this one file. Not mutated.

    Returns:
        `INTERRUPTED`, `INTERNAL_ERROR`, `DRIFT_HALT`, `PRECOMPILE_CASUALTY`,
        or `GATE_CASUALTY`/`GATE_ABORT` for the first latched cause found, in
        that order; else `DELIVERY_ABORT` when the stream died; else
        `GATE_CASUALTY` for a bare gate file; else `LIMIT_REACHED`.

    Examples:

    ```mojo
    from mtest.model import NotRunFacts, NotRunReason, classify_not_run

    var reason = classify_not_run(
        NotRunFacts(
            interrupt_latched=False,
            internal_error=False,
            drift=False,
            precompile_failed=False,
            gate_abort=False,
            stream_dead=True,
            is_gate_file=True,
        )
    )  # DELIVERY_ABORT: the stream died before any gate aborted
    ```
    """
    if facts.interrupt_latched:
        return NotRunReason.INTERRUPTED
    if facts.internal_error:
        return NotRunReason.INTERNAL_ERROR
    if facts.drift:
        return NotRunReason.DRIFT_HALT
    if facts.precompile_failed:
        return NotRunReason.PRECOMPILE_CASUALTY
    if facts.gate_abort:
        if facts.is_gate_file:
            return NotRunReason.GATE_CASUALTY
        return NotRunReason.GATE_ABORT
    if facts.stream_dead:
        return NotRunReason.DELIVERY_ABORT
    if facts.is_gate_file:
        return NotRunReason.GATE_CASUALTY
    return NotRunReason.LIMIT_REACHED


@fieldwise_init
struct NotRunRecord(Copyable, Movable):
    """One selected file with the reason scheduling stopped for it.

    Delivered for EVERY selected file; consumers that know which files
    produced verdicts (the report writer's row index) filter, exactly as
    JunitReporter.note_not_run skips paths that already spooled a suite.
    """

    var path: String
    """Root-relative file path."""
    var reason: NotRunReason
    """The classified cause, meaningful only for files that never tallied."""


def not_run_reason_label(reason: NotRunReason) -> String:
    """Human-readable label; total over any discriminant value.

    Args:
        reason: The reason to label.

    Returns:
        A fixed label for each known discriminant, and a numbered fallback
        for anything else — the discriminant is a stable integer, not a
        closed enum the compiler can check exhaustively.
    """
    if reason == NotRunReason.GATE_CASUALTY:
        return String("gate casualty")
    if reason == NotRunReason.GATE_ABORT:
        return String("gate aborted the session")
    if reason == NotRunReason.LIMIT_REACHED:
        return String("stopped early (-x/--maxfail)")
    if reason == NotRunReason.INTERRUPTED:
        return String("interrupted")
    if reason == NotRunReason.INTERNAL_ERROR:
        return String("internal error")
    if reason == NotRunReason.PRECOMPILE_CASUALTY:
        return String("precompile casualty")
    if reason == NotRunReason.DRIFT_HALT:
        return String("protocol drift halted the session")
    if reason == NotRunReason.DELIVERY_ABORT:
        return String("terminal stream died; scheduling stopped")
    return String("unclassified (code ") + String(reason.code) + String(")")
