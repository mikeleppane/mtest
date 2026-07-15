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
everything it needs — the captured stdout/stderr are kept as owned raw byte
buffers the reporter decodes verbatim, never pre-rendered; the build command
rides as raw `build_argv` (the reporter shell-joins it); and the per-outcome
specifics ride as the data they are — `signal_number` for a crash, `exit_status`
for a failure, `timeout_seconds` for a timeout, `exclusion_pattern` for an
exclusion. A second, machine reporter could recover every one of these without
parsing English.

Usage errors are intentionally outside this set: they happen before any session
exists and are printed by the CLI, so there is no usage-error event.
"""
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome
from mtest.model.parse_disposition import ParseDisposition
from mtest.model.test_counts import TestCounts
from mtest.model.test_result import TestResult


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
    comptime INTERNAL_ERROR = Self(6)
    comptime TEST_REPORTED = Self(7)
    comptime COLLECTION_KNOWN = Self(8)

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
    var warning_pattern: String
    """The offending pattern the warning concerns; the reporter composes the
    sentence from the kind and this datum."""

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
    var build_argv: List[String]
    """The build command as argv, for the reporter to shell-join (FileFinished).
    """
    var build_duration_seconds: Float64
    """Wall time the build took, in seconds, for verbose output (FileFinished)."""
    var captured_stdout: List[UInt8]
    """The file run's raw captured stdout bytes, decoded verbatim by the reporter.
    """
    var captured_stderr: List[UInt8]
    """The file run's raw captured stderr bytes, decoded verbatim by the reporter;
    for a COMPILE_ERROR this holds the build's stderr (the compiler banner)."""
    var signal_number: Int
    """The terminating signal for a CRASH (0 otherwise)."""
    var exit_status: Int
    """The child's exit code for a FAIL (0 otherwise)."""
    var timeout_seconds: Int
    """The configured deadline for a TIMEOUT, in seconds (0 otherwise)."""
    var exclusion_pattern: String
    """The glob that excluded the file, for an EXCLUDED line (empty otherwise)."""
    var parse_disposition: ParseDisposition
    """Why the report parse landed where it did (FileFinished)."""
    var passed_tests: Int
    """How many tests in this file passed, at test granularity (FileFinished).
    """
    var failed_tests: Int
    """How many tests in this file failed, at test granularity (FileFinished).
    """
    var skipped_tests: Int
    """How many tests in this file were skipped, at test granularity
    (FileFinished)."""
    var deselected_tests: Int
    """How many tests in this file were deselected, at test granularity
    (FileFinished)."""

    # TestReported.
    var test: TestResult
    """The per-test result this event reports (TestReported)."""

    # CollectionKnown.
    var selected_test_total: Int
    """How many tests, across the whole run, are selected (CollectionKnown)."""
    var deselected_test_total: Int
    """How many tests, across the whole run, are deselected (CollectionKnown).
    """

    # InternalError.
    var program: String
    """The executable a failed spawn tried to run (InternalError)."""
    var errno: Int
    """The spawn errno for an InternalError (0 when the cause is a machinery
    raise rather than a spawn failure)."""

    # SessionFinished.
    var summary: Summary
    """The per-outcome tally, including excluded and not-run (SessionFinished)."""
    var wall_time_seconds: Float64
    """Total wall time of the whole session, in seconds (SessionFinished)."""
    var exit_code: Int
    """The process exit code the session resolved (SessionFinished)."""
    var test_counts: TestCounts
    """The authoritative per-test totals for the whole run (SessionFinished)."""

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
            warning_pattern="",
            step="",
            compiler_output="",
            casualty_count=0,
            path="",
            outcome=Outcome.NOT_RUN,
            duration_seconds=0.0,
            build_argv=List[String](),
            build_duration_seconds=0.0,
            captured_stdout=List[UInt8](),
            captured_stderr=List[UInt8](),
            signal_number=0,
            exit_status=0,
            timeout_seconds=0,
            exclusion_pattern="",
            parse_disposition=ParseDisposition.NO_REPORT,
            passed_tests=0,
            failed_tests=0,
            skipped_tests=0,
            deselected_tests=0,
            test=TestResult(NodeId("", ""), Outcome.NOT_RUN),
            selected_test_total=0,
            deselected_test_total=0,
            program="",
            errno=0,
            summary=Summary.zeros(),
            wall_time_seconds=0.0,
            exit_code=0,
            test_counts=TestCounts.zeros(),
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
    def warning(warning_kind: String, warning_pattern: String) -> Event:
        """A loud non-file notice, such as a stale-exclusion warning.

        Carries the offending pattern as data; the reporter composes the
        sentence from `warning_kind` and `warning_pattern`.
        """
        var e = Event._blank(EventKind.WARNING)
        e.warning_kind = warning_kind
        e.warning_pattern = warning_pattern
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
        var build_argv: List[String],
        build_duration_seconds: Float64,
        var captured_stdout: List[UInt8],
        var captured_stderr: List[UInt8],
        signal_number: Int = 0,
        exit_status: Int = 0,
        timeout_seconds: Int = 0,
        exclusion_pattern: String = "",
        parse_disposition: ParseDisposition = ParseDisposition.NO_REPORT,
        passed_tests: Int = 0,
        failed_tests: Int = 0,
        skipped_tests: Int = 0,
        deselected_tests: Int = 0,
    ) -> Event:
        """A file's run finished, carrying the data the reporter renders from.

        The per-outcome specifics ride as data: `signal_number` for a CRASH,
        `exit_status` for a FAIL, `timeout_seconds` for a TIMEOUT, and
        `exclusion_pattern` for an EXCLUDED line. The build command rides as
        `build_argv`, and the captured streams as raw bytes. `parse_disposition`
        and the four `*_tests` totals carry the test-granularity read of this
        file's report; every one defaults so existing callers are unaffected.
        """
        var e = Event._blank(EventKind.FILE_FINISHED)
        e.path = path
        e.outcome = outcome
        e.duration_seconds = duration_seconds
        e.build_argv = build_argv^
        e.build_duration_seconds = build_duration_seconds
        e.captured_stdout = captured_stdout^
        e.captured_stderr = captured_stderr^
        e.signal_number = signal_number
        e.exit_status = exit_status
        e.timeout_seconds = timeout_seconds
        e.exclusion_pattern = exclusion_pattern
        e.parse_disposition = parse_disposition
        e.passed_tests = passed_tests
        e.failed_tests = failed_tests
        e.skipped_tests = skipped_tests
        e.deselected_tests = deselected_tests
        return e^

    @staticmethod
    def internal_error(step: String, program: String, errno: Int) -> Event:
        """A spawn or machinery failure that stopped a step from running.

        `step` is `"build"`, `"run"`, or `"precompile"`; `program` is the
        executable the runner tried to spawn; `errno` is the spawn errno, or 0
        when the cause is a machinery raise rather than a spawn failure. Carries
        the diagnostic as data; the reporter renders the banner.
        """
        var e = Event._blank(EventKind.INTERNAL_ERROR)
        e.step = step
        e.program = program
        e.errno = errno
        return e^

    @staticmethod
    def session_finished(
        var summary: Summary,
        wall_time_seconds: Float64,
        exit_code: Int,
        test_counts: TestCounts = TestCounts.zeros(),
    ) -> Event:
        """The run ended: the full summary tally, wall time, and exit code.

        `test_counts` carries the authoritative per-test totals; it defaults to
        zeros so existing callers are unaffected.
        """
        var e = Event._blank(EventKind.SESSION_FINISHED)
        e.summary = summary^
        e.wall_time_seconds = wall_time_seconds
        e.exit_code = exit_code
        e.test_counts = test_counts
        return e^

    @staticmethod
    def test_reported(var test: TestResult) -> Event:
        """One test's result, reported retrospectively after its file exits.

        Conceptually sits between `FileStarted` and `FileFinished` once a
        child's report parses. `path` mirrors `test.node.path` so the existing
        `path_at` accessors keep working without inspecting `test`.
        """
        var e = Event._blank(EventKind.TEST_REPORTED)
        e.path = test.node.path
        e.test = test^
        return e^

    @staticmethod
    def collection_known(
        selected_test_total: Int, deselected_test_total: Int
    ) -> Event:
        """The final selected/deselected test totals became known, run-wide."""
        var e = Event._blank(EventKind.COLLECTION_KNOWN)
        e.selected_test_total = selected_test_total
        e.deselected_test_total = deselected_test_total
        return e^
