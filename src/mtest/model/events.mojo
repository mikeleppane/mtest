"""The closed, typed event set of the mtest runner (Layer 0).

These events are the whole vocabulary of the seam between the session and the
reporters: the session emits them and nothing else, and each reporter consumes
them through a single `handle(mut self, e: Event)` method. So the set is one
closed `Event` type tagged by an `EventKind` discriminant, carrying the payload
fields of every variant at once; a factory builds each kind and leaves the
fields the kind does not use at their defaults. It is deliberately not one
struct per event with per-event methods, which would break that single-method
composition.

The payloads are data only. There is no formatting, I/O, or printing here: the
console reporter renders everything from these fields, so the fields must carry
everything it needs — the captured stdout/stderr are kept as owned raw buffers
the reporter reads verbatim, never pre-rendered, and `detail` carries the
per-outcome specifics (the signal for a crash, the exit code for a failure, the
compiler output for a compile error) as plain data.

Usage errors are intentionally outside this set: they happen before any session
exists and are printed by the CLI, so there is no usage-error event.
"""
from mtest.model.outcome import Outcome


@fieldwise_init
struct EventKind(Equatable, ImplicitlyCopyable, Movable):
    """The discriminant tagging which variant an `Event` is.

    A thin wrapper over a stable integer so the kinds form a closed set of named
    constants that compare by value. Holds no owned resources and never raises.
    """

    var value: Int
    """The stable integer discriminant identifying this event kind."""

    comptime SESSION_STARTED = Self(0)
    comptime WARNING = Self(1)
    comptime PRECOMPILE_FAILED = Self(2)
    comptime FILE_STARTED = Self(3)
    comptime FILE_FINISHED = Self(4)
    comptime SESSION_FINISHED = Self(5)

    def __eq__(self, other: Self) -> Bool:
        """Two kinds are equal iff their discriminants match. Pure."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Pure."""
        return self.value != other.value


@fieldwise_init
struct Summary(Copyable, Movable):
    """A per-outcome tally, indexed by outcome discriminant.

    `counts[o.code]` is the number of files that ended with outcome `o`. It
    includes the internal EXCLUDED and NOT_RUN tallies, so the session summary
    accounts for every discovered file, not only the ones that ran. Owns its
    backing list, so copies are explicit; reads do not mutate or raise.
    """

    var counts: List[Int]
    """One count per outcome, indexed by `Outcome.code`; length is Outcome.COUNT."""

    @staticmethod
    def zeros() -> Summary:
        """A summary with every outcome tallied at zero. Allocates; never raises.
        """
        var c = List[Int]()
        for _ in range(Outcome.COUNT):
            c.append(0)
        return Summary(c^)

    def count_of(self, outcome: Outcome) -> Int:
        """The tally for one outcome. Does not mutate or raise."""
        return self.counts[outcome.code]

    def total(self) -> Int:
        """The sum of every tally. Does not mutate or raise."""
        var t = 0
        for c in self.counts:
            t += c
        return t


@fieldwise_init
struct Event(Copyable, Movable):
    """One event on the session-to-reporter seam.

    A single closed type tagged by `kind`, carrying the payload fields of every
    variant; a given kind populates only its own fields and leaves the rest at
    their defaults. Build events through the factory methods rather than the
    fieldwise constructor. Owns its string and summary payloads, so copies are
    explicit; the type never raises.
    """

    var kind: EventKind
    """Which variant this event is."""

    # SessionStarted.
    var root: String
    """The discovery root the run started from."""
    var toolchain: String
    """The resolved mojo path and version label."""
    var selected_count: Int
    """How many discovered files were selected to run."""
    var excluded_count: Int
    """How many discovered files were excluded."""

    # Warning.
    var warning_kind: String
    """A short tag for the warning class (e.g. a stale exclusion)."""
    var message: String
    """The human-readable warning text."""

    # PrecompileFailed.
    var step: String
    """The name of the session-level step that failed."""
    var compiler_output: String
    """The raw captured compiler output for the failed step."""
    var casualty_count: Int
    """How many files could not run because the step failed."""

    # FileStarted / FileFinished.
    var path: String
    """The path of the file this event concerns."""
    var outcome: Outcome
    """The file's outcome (FileFinished)."""
    var duration_seconds: Float64
    """Wall time the file's run took, in seconds (FileFinished)."""
    var build_command: String
    """The command used to build the file, for verbose output (FileFinished)."""
    var build_duration_seconds: Float64
    """Wall time the build took, in seconds, for verbose output (FileFinished)."""
    var captured_stdout: String
    """The file run's raw captured stdout, read verbatim by the reporter."""
    var captured_stderr: String
    """The file run's raw captured stderr, read verbatim by the reporter."""
    var detail: String
    """Per-outcome specifics: signal for a crash, exit code for a failure, etc."""

    # SessionFinished.
    var summary: Summary
    """The per-outcome tally, including excluded and not-run (SessionFinished)."""
    var wall_time_seconds: Float64
    """Total wall time of the whole session, in seconds (SessionFinished)."""
    var exit_code: Int
    """The process exit code the session resolved (SessionFinished)."""

    @staticmethod
    def _blank(kind: EventKind) -> Event:
        """An event of `kind` with every payload field at its default. Allocates.
        """
        return Event(
            kind=kind,
            root="",
            toolchain="",
            selected_count=0,
            excluded_count=0,
            warning_kind="",
            message="",
            step="",
            compiler_output="",
            casualty_count=0,
            path="",
            outcome=Outcome.NOT_RUN,
            duration_seconds=0.0,
            build_command="",
            build_duration_seconds=0.0,
            captured_stdout="",
            captured_stderr="",
            detail="",
            summary=Summary.zeros(),
            wall_time_seconds=0.0,
            exit_code=0,
        )

    @staticmethod
    def session_started(
        root: String,
        toolchain: String,
        selected_count: Int,
        excluded_count: Int,
    ) -> Event:
        """The run began: root, resolved toolchain, and selected/excluded counts.
        """
        var e = Event._blank(EventKind.SESSION_STARTED)
        e.root = root
        e.toolchain = toolchain
        e.selected_count = selected_count
        e.excluded_count = excluded_count
        return e^

    @staticmethod
    def warning(warning_kind: String, message: String) -> Event:
        """A loud non-file notice, such as a stale-exclusion warning."""
        var e = Event._blank(EventKind.WARNING)
        e.warning_kind = warning_kind
        e.message = message
        return e^

    @staticmethod
    def precompile_failed(
        step: String, compiler_output: String, casualty_count: Int
    ) -> Event:
        """A session-level build step failed, before any file identity exists.
        """
        var e = Event._blank(EventKind.PRECOMPILE_FAILED)
        e.step = step
        e.compiler_output = compiler_output
        e.casualty_count = casualty_count
        return e^

    @staticmethod
    def file_started(path: String) -> Event:
        """A file's run is starting."""
        var e = Event._blank(EventKind.FILE_STARTED)
        e.path = path
        return e^

    @staticmethod
    def file_finished(
        path: String,
        outcome: Outcome,
        duration_seconds: Float64,
        build_command: String,
        build_duration_seconds: Float64,
        captured_stdout: String,
        captured_stderr: String,
        detail: String,
    ) -> Event:
        """A file's run finished, carrying everything the reporter renders from.
        """
        var e = Event._blank(EventKind.FILE_FINISHED)
        e.path = path
        e.outcome = outcome
        e.duration_seconds = duration_seconds
        e.build_command = build_command
        e.build_duration_seconds = build_duration_seconds
        e.captured_stdout = captured_stdout
        e.captured_stderr = captured_stderr
        e.detail = detail
        return e^

    @staticmethod
    def session_finished(
        var summary: Summary, wall_time_seconds: Float64, exit_code: Int
    ) -> Event:
        """The run ended: the full summary tally, wall time, and exit code."""
        var e = Event._blank(EventKind.SESSION_FINISHED)
        e.summary = summary^
        e.wall_time_seconds = wall_time_seconds
        e.exit_code = exit_code
        return e^
