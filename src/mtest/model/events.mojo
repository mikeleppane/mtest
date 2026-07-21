"""The closed, typed event set of the mtest runner.

These events are the whole vocabulary of the seam between the session and the
reporters: the session emits them and nothing else, and each reporter consumes
them through a single `handle(mut self, e: Event)` method. To keep that
single-method composition, the set is one closed `Event` type tagged by an
`EventKind` discriminant that carries the payload fields of every variant at
once, rather than one struct per event. A factory method builds each kind and
leaves the fields that kind does not use at their defaults.

The payloads are data only; there is no formatting, I/O, or printing here. The
console reporter renders everything from these fields, so the fields carry
everything it needs: captured stdout and stderr stay owned raw byte buffers the
reporter decodes verbatim, the build command rides as raw `build_argv` for the
reporter to shell-join, and the per-outcome specifics ride as data —
`signal_number` for a crash, `exit_status` for a failure, `timeout_seconds` for
a timeout, `exclusion_pattern` for an exclusion. A machine reporter can recover
every one of these without parsing English.

Usage errors are deliberately outside this set: they happen before any session
exists and the CLI prints them, so there is no usage-error event.
"""
from mtest.model.attribution import AttributionDisposition
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome
from mtest.model.parse_disposition import ParseDisposition
from mtest.model.test_counts import TestCounts
from mtest.model.test_result import TestResult


@fieldwise_init
struct EventKind(Equatable, ImplicitlyCopyable, Movable):
    """The discriminant tagging which variant an `Event` is.

    A thin wrapper over a stable integer, so the kinds form a closed set of
    named constants that compare by value.
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
    comptime ATTEMPT_FINISHED = Self(9)
    comptime CRASH_ATTRIBUTION = Self(10)

    def __eq__(self, other: Self) -> Bool:
        """Two kinds are equal iff their discriminants match."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return self.value != other.value


@fieldwise_init
struct Summary(Copyable, Movable):
    """A per-outcome tally, indexed by outcome discriminant.

    `counts[o.code]` is the number of files that ended with outcome `o`. It
    includes the internal EXCLUDED and NOT_RUN tallies, so the session summary
    accounts for every discovered file, not only the ones that ran. Owns its
    backing list, so copies are explicit.
    """

    var counts: List[Int]
    """One count per outcome, indexed by `Outcome.code`; the list is always
    `Outcome.COUNT` long."""

    @staticmethod
    def zeros() -> Summary:
        """A summary with every outcome tallied at zero."""
        var c = List[Int]()
        for _ in range(Outcome.COUNT):
            c.append(0)
        return Summary(c^)

    def count_of(self, outcome: Outcome) -> Int:
        """The tally for one outcome.

        Args:
            outcome: Which outcome to read the tally for.

        Returns:
            How many files ended with `outcome`.
        """
        return self.counts[outcome.code]

    def total(self) -> Int:
        """The sum of every tally, across all outcomes."""
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
    explicit.
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
    var shard_label: String
    """The shard identity for a sharded run (e.g. "2/5"), empty when unsharded
    (SessionStarted)."""
    var sharded_out_count: Int
    """How many selected files this shard handed off to other shards
    (SessionStarted)."""

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
    var casualties: List[String]
    """The dependent test files that could not run (empty when only a count
    is known)."""
    var ending_known: Bool
    """Whether the step's final termination identity rides with this event.

    A PrecompileFailed carries how the step's last attempt ended in the shared
    `term_kind`/`term_value`/`escalated`/`timeout_seconds`/`attempts_used`
    fields. This flag says those fields were populated, so a reporter never
    renders an unset termination as "exited 0"."""

    # FileStarted / FileFinished.
    var path: String
    """The path of the file this event concerns."""
    var outcome: Outcome
    """The file's outcome (FileFinished)."""
    var duration_seconds: Float64
    """Wall time the file's run took, in seconds (FileFinished)."""
    var build_argv: List[String]
    """The build command as argv, for the reporter to shell-join
    (FileFinished)."""
    var build_duration_seconds: Float64
    """Wall time the build took, in seconds, for verbose output
    (FileFinished)."""
    var captured_stdout: List[UInt8]
    """The file run's raw captured stdout bytes, decoded verbatim by the
    reporter."""
    var captured_stderr: List[UInt8]
    """The file run's raw captured stderr bytes, decoded verbatim by the
    reporter; for a COMPILE_ERROR this holds the build's stderr (the compiler
    banner)."""
    var signal_number: Int
    """The terminating signal for a CRASH (0 otherwise)."""
    var exit_status: Int
    """The child's exit code for a FAIL (0 otherwise)."""
    var timeout_seconds: Int
    """The configured deadline for a TIMEOUT, in seconds (0 otherwise)."""
    var exclusion_pattern: String
    """The glob that excluded the file, for an EXCLUDED line (empty
    otherwise)."""
    var parse_disposition: ParseDisposition
    """Why the report parse landed where it did (FileFinished)."""
    var passed_tests: Int
    """How many tests in this file passed, at test granularity
    (FileFinished)."""
    var failed_tests: Int
    """How many tests in this file failed, at test granularity
    (FileFinished)."""
    var skipped_tests: Int
    """How many tests in this file were skipped, at test granularity
    (FileFinished)."""
    var deselected_tests: Int
    """How many tests in this file were deselected, at test granularity
    (FileFinished)."""
    var attempts_used: Int
    """How many attempts the file's run took to reach its outcome; 1 when it
    ran once with no retry (FileFinished)."""
    var flaky: Bool
    """Whether the file passed only after one or more failing attempts
    (FileFinished)."""
    var slow: Bool
    """Whether the file's wall time crossed the slow threshold
    (FileFinished)."""

    # AttemptFinished. `path` names the file, `step` names the attempted step
    # ("build" | "run" | "precompile"), `duration_seconds` the attempt's wall
    # time, and `captured_stdout`/`captured_stderr` the bounded excerpts (the
    # caller bounds them before constructing the event).
    var attempt_index: Int
    """Which attempt this was, 1-based (the k-th of the planned attempts)."""
    var attempts_planned: Int
    """How many attempts were planned in total (the retry budget, N+1)."""
    var term_kind: Int
    """The termination kind as a plain discriminant (the attempt's raw
    termination identity, decomposed from an exec.Termination)."""
    var term_value: Int
    """The termination value paired with `term_kind` (e.g. the signal number or
    exit status of this attempt)."""
    var term_final_kind: Int
    """The latched final termination kind after any escalation, meaningful
    only when `term_kind` is TIMED_OUT.

    Every other termination hard-codes EXITED here as a placeholder, so a
    SIGNALED attempt reads as "exited 0" if this field is consulted on its own.
    Read `term_kind`/`term_value` first and only descend to the final pair for
    a timeout."""
    var term_final_value: Int
    """The termination value paired with `term_final_kind`, meaningful under
    the same TIMED_OUT-only condition (`0` placeholder otherwise)."""
    var escalated: Bool
    """Whether the deadline kill escalated SIGTERM to SIGKILL, meaningful only
    when `term_kind` is TIMED_OUT and False for every other termination; a TRY
    line reads "SIGTERM sent, escalated to SIGKILL" from these fields."""
    var retry_eligible: Bool
    """Whether the classifier judged this attempt retry-eligible/crash-class."""
    var classification: String
    """A short classification label for the attempt (e.g. "signal",
    "compile-timeout", "compile-crash")."""
    var stdout_truncated: Bool
    """Whether the captured stdout was truncated by the capture bound, so the
    reporter can print a loud "excerpt"/truncation marker (AttemptFinished: the
    retry excerpt's own bound; FileFinished: the file-scope process result's
    stdout truncation, propagated by the session)."""
    var stderr_truncated: Bool
    """Whether the captured stderr was truncated by the capture bound
    (AttemptFinished: the retry excerpt's own bound; FileFinished: the
    file-scope process result's stderr truncation, propagated by the
    session)."""
    var attempt_argv: List[String]
    """The argv this attempt ran, for the reproduce/diagnostic line
    (AttemptFinished)."""

    # CrashAttribution. `path` names the crashing file.
    var attribution_disposition: AttributionDisposition
    """Why the bounded crash-isolation pass stopped (CrashAttribution)."""
    var culprit_test: String
    """The attributed culprit test name, empty when none was attributed
    (CrashAttribution)."""
    var isolation_reruns: Int
    """How many isolation reruns the attribution pass performed
    (CrashAttribution)."""
    var attribution_seconds: Float64
    """The wall time the attribution pass took, in seconds
    (CrashAttribution)."""

    # TestReported.
    var test: TestResult
    """The per-test result this event reports (TestReported)."""

    # CollectionKnown.
    var selected_test_total: Int
    """How many tests, across the whole run, are selected (CollectionKnown)."""
    var deselected_test_total: Int
    """How many tests, across the whole run, are deselected
    (CollectionKnown)."""

    # InternalError.
    var program: String
    """The executable a failed spawn tried to run (InternalError)."""
    var errno: Int
    """The spawn errno for an InternalError (0 when the cause is a machinery
    raise rather than a spawn failure)."""

    # SessionFinished.
    var summary: Summary
    """The per-outcome tally, including excluded and not-run
    (SessionFinished)."""
    var wall_time_seconds: Float64
    """Total wall time of the whole session, in seconds (SessionFinished)."""
    var exit_code: Int
    """The process exit code the session resolved (SessionFinished)."""
    var test_counts: TestCounts
    """The authoritative per-test totals for the whole run (SessionFinished)."""
    var flaky_files: Int
    """How many files passed only after a retry, run-wide (SessionFinished)."""

    @staticmethod
    def _blank(kind: EventKind) -> Event:
        """An event of `kind` with every payload field at its default.

        Args:
            kind: Which variant the returned event is tagged as.

        Returns:
            The event, for a factory method to fill in its own fields.
        """
        return Event(
            kind=kind,
            root="",
            toolchain="",
            selected_count=0,
            excluded_count=0,
            shard_label="",
            sharded_out_count=0,
            warning_kind="",
            warning_pattern="",
            step="",
            compiler_output="",
            casualty_count=0,
            casualties=List[String](),
            ending_known=False,
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
            attempts_used=1,
            flaky=False,
            slow=False,
            attempt_index=0,
            attempts_planned=0,
            term_kind=0,
            term_value=0,
            term_final_kind=0,
            term_final_value=0,
            escalated=False,
            retry_eligible=False,
            classification="",
            stdout_truncated=False,
            stderr_truncated=False,
            attempt_argv=List[String](),
            attribution_disposition=AttributionDisposition.NO_REPRODUCTION,
            culprit_test="",
            isolation_reruns=0,
            attribution_seconds=0.0,
            test=TestResult(NodeId("", ""), Outcome.NOT_RUN),
            selected_test_total=0,
            deselected_test_total=0,
            program="",
            errno=0,
            summary=Summary.zeros(),
            wall_time_seconds=0.0,
            exit_code=0,
            test_counts=TestCounts.zeros(),
            flaky_files=0,
        )

    @staticmethod
    def session_started(
        root: String,
        toolchain: String,
        selected_count: Int,
        excluded_count: Int,
        shard_label: String = "",
        sharded_out_count: Int = 0,
    ) -> Event:
        """The run began.

        Args:
            root: The discovery root the run started from.
            toolchain: The resolved mojo path and version label.
            selected_count: How many discovered files were selected to run.
            excluded_count: How many discovered files were excluded.
            shard_label: The shard identity for a sharded run, such as "2/5".
                Empty for an unsharded run.
            sharded_out_count: How many selected files this shard handed off to
                other shards.

        Returns:
            A SESSION_STARTED event.
        """
        var e = Event._blank(EventKind.SESSION_STARTED)
        e.root = root
        e.toolchain = toolchain
        e.selected_count = selected_count
        e.excluded_count = excluded_count
        e.shard_label = shard_label
        e.sharded_out_count = sharded_out_count
        return e^

    @staticmethod
    def warning(warning_kind: String, warning_pattern: String) -> Event:
        """A loud non-file notice, such as a stale-exclusion warning.

        The reporter composes the sentence from the two fields; neither carries
        rendered text.

        Args:
            warning_kind: A short tag for the warning class.
            warning_pattern: The offending pattern the warning concerns.

        Returns:
            A WARNING event.
        """
        var e = Event._blank(EventKind.WARNING)
        e.warning_kind = warning_kind
        e.warning_pattern = warning_pattern
        return e^

    @staticmethod
    def precompile_failed(
        step: String,
        compiler_output: String,
        casualty_count: Int,
        casualties: List[String] = List[String](),
        ending_known: Bool = False,
        term_kind: Int = 0,
        term_value: Int = 0,
        escalated: Bool = False,
        timeout_seconds: Int = 0,
        attempts_used: Int = 1,
    ) -> Event:
        """A session-level build step failed, before any file identity exists.

        The step's final ending rides as typed data so the banner can name it
        in words. A caller that knows none of it leaves `ending_known` False,
        and the reporter then says nothing about the ending rather than
        inventing one.

        Args:
            step: The name of the session-level step that failed.
            compiler_output: The raw captured compiler output for that step.
            casualty_count: How many files could not run. Ignored when
                `casualties` is non-empty, in which case that list's length is
                authoritative.
            casualties: The dependent test files that could not run. The banner
                lists these rather than merely counting them, so pass them
                whenever they are known.
            ending_known: Whether the termination fields below were populated.
            term_kind: The decomposed exec-layer termination kind: 0 EXITED,
                1 SIGNALED, 2 TIMED_OUT, 3 SPAWN_FAILED.
            term_value: The value paired with `term_kind`, such as a signal
                number or exit status.
            escalated: Whether the runner escalated to SIGKILL.
            timeout_seconds: The deadline mtest enforced on a TIMED_OUT step.
            attempts_used: How many attempts the retry budget spent.

        Returns:
            A PRECOMPILE_FAILED event.
        """
        var e = Event._blank(EventKind.PRECOMPILE_FAILED)
        e.step = step
        e.compiler_output = compiler_output
        e.casualties = casualties.copy()
        e.casualty_count = len(casualties) if casualties else casualty_count
        e.ending_known = ending_known
        e.term_kind = term_kind
        e.term_value = term_value
        e.escalated = escalated
        e.timeout_seconds = timeout_seconds
        e.attempts_used = attempts_used
        return e^

    @staticmethod
    def file_started(path: String) -> Event:
        """A file's run is starting.

        Args:
            path: The path of the file about to run.

        Returns:
            A FILE_STARTED event.
        """
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
        attempts_used: Int = 1,
        flaky: Bool = False,
        slow: Bool = False,
        escalated: Bool = False,
        stdout_truncated: Bool = False,
        stderr_truncated: Bool = False,
    ) -> Event:
        """A file's run finished, carrying the data the reporter renders from.

        The per-outcome specifics ride as data rather than as rendered text,
        and each one is meaningful only for its own outcome.

        Args:
            path: The path of the file that ran.
            outcome: The file's outcome.
            duration_seconds: Wall time the file's run took, in seconds.
            build_argv: The build command as argv, for the reporter to
                shell-join. Consumed.
            build_duration_seconds: Wall time the build took, in seconds.
            captured_stdout: The run's raw stdout bytes, which the reporter
                decodes verbatim. Consumed.
            captured_stderr: The run's raw stderr bytes. For a COMPILE_ERROR
                this holds the build's stderr, the compiler banner. Consumed.
            signal_number: The terminating signal for a CRASH.
            exit_status: The child's exit code for a FAIL.
            timeout_seconds: The configured deadline for a TIMEOUT, in seconds.
            exclusion_pattern: The glob that excluded the file, for an EXCLUDED
                line.
            parse_disposition: Why the report parse landed where it did.
            passed_tests: How many tests in this file passed.
            failed_tests: How many tests in this file failed.
            skipped_tests: How many tests in this file were skipped.
            deselected_tests: How many tests in this file were deselected.
            attempts_used: How many attempts the run took to reach its outcome.
            flaky: Whether the file passed only after a failing attempt.
            slow: Whether the file's wall time crossed the slow threshold.
            escalated: The run termination's latched SIGKILL escalation, so a
                TIMEOUT verdict can say whether the child went down on SIGTERM
                or had to be killed. Available even with no retry in play.
            stdout_truncated: Whether stdout overflowed the capture bound.
            stderr_truncated: Whether stderr overflowed the capture bound.

        Returns:
            A FILE_FINISHED event.
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
        e.attempts_used = attempts_used
        e.flaky = flaky
        e.slow = slow
        e.escalated = escalated
        e.stdout_truncated = stdout_truncated
        e.stderr_truncated = stderr_truncated
        return e^

    @staticmethod
    def internal_error(step: String, program: String, errno: Int) -> Event:
        """A spawn or machinery failure that stopped a step from running.

        Carries the diagnostic as data; the reporter renders the banner.

        Args:
            step: Which step failed: `"build"`, `"run"`, or `"precompile"`.
            program: The executable the runner tried to spawn.
            errno: The spawn errno, or 0 when the cause is a machinery raise
                rather than a spawn failure.

        Returns:
            An INTERNAL_ERROR event.
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
        flaky_files: Int = 0,
    ) -> Event:
        """The run ended.

        Args:
            summary: The per-outcome tally, including excluded and not-run.
                Consumed.
            wall_time_seconds: Total wall time of the whole session, in seconds.
            exit_code: The process exit code the session resolved.
            test_counts: The authoritative per-test totals for the whole run.
            flaky_files: How many files passed only after a retry, run-wide.

        Returns:
            A SESSION_FINISHED event.
        """
        var e = Event._blank(EventKind.SESSION_FINISHED)
        e.summary = summary^
        e.wall_time_seconds = wall_time_seconds
        e.exit_code = exit_code
        e.test_counts = test_counts
        e.flaky_files = flaky_files
        return e^

    @staticmethod
    def test_reported(var test: TestResult) -> Event:
        """One test's result, reported retrospectively after its file exits.

        Conceptually sits between `FileStarted` and `FileFinished`, once a
        child's report parses. The event's `path` mirrors `test.node.path`, so
        the `path_at` accessors work without inspecting `test`.

        Args:
            test: The per-test result to report. Consumed.

        Returns:
            A TEST_REPORTED event.
        """
        var e = Event._blank(EventKind.TEST_REPORTED)
        e.path = test.node.path
        e.test = test^
        return e^

    @staticmethod
    def collection_known(
        selected_test_total: Int, deselected_test_total: Int
    ) -> Event:
        """The final selected and deselected test totals became known, run-wide.

        Args:
            selected_test_total: How many tests across the run are selected.
            deselected_test_total: How many tests across the run are deselected.

        Returns:
            A COLLECTION_KNOWN event.
        """
        var e = Event._blank(EventKind.COLLECTION_KNOWN)
        e.selected_test_total = selected_test_total
        e.deselected_test_total = deselected_test_total
        return e^

    @staticmethod
    def attempt_finished(
        path: String,
        step: String,
        attempt_index: Int,
        attempts_planned: Int,
        term_kind: Int,
        term_value: Int,
        term_final_kind: Int,
        term_final_value: Int,
        escalated: Bool,
        retry_eligible: Bool,
        classification: String,
        duration_seconds: Float64,
        var captured_stdout: List[UInt8],
        var captured_stderr: List[UInt8],
        stdout_truncated: Bool,
        stderr_truncated: Bool,
        var attempt_argv: List[String],
    ) -> Event:
        """One non-final retry attempt's full record, for a "TRY" block.

        Carries everything a reporter needs to render the attempt now and to
        serialize it later without re-parsing bytes. The termination identity
        rides as plain Int fields, decomposed from an `exec.Termination`, so
        this layer imports nothing above it.

        Args:
            path: The file this attempt belongs to.
            step: The attempted step: `"build"`, `"run"`, or `"precompile"`.
            attempt_index: Which attempt this was, 1-based.
            attempts_planned: How many attempts were planned in total.
            term_kind: This attempt's raw termination kind.
            term_value: The value paired with `term_kind`.
            term_final_kind: The latched final termination kind after any
                escalation.
            term_final_value: The value paired with `term_final_kind`.
            escalated: Whether the runner escalated the signal, for example
                SIGTERM then SIGKILL.
            retry_eligible: Whether the classifier judged this attempt
                retry-eligible, or crash-class.
            classification: A short classifier label, such as `"signal"` or
                `"compile-timeout"`.
            duration_seconds: The attempt's wall time, in seconds.
            captured_stdout: A bounded stdout excerpt. The caller bounds the
                bytes before constructing the event. Consumed.
            captured_stderr: A bounded stderr excerpt, bounded by the caller.
                Consumed.
            stdout_truncated: Whether that excerpt hit its bound.
            stderr_truncated: Whether that excerpt hit its bound.
            attempt_argv: The argv this attempt ran, for the reproduce line.
                Consumed.

        Returns:
            An ATTEMPT_FINISHED event.
        """
        var e = Event._blank(EventKind.ATTEMPT_FINISHED)
        e.path = path
        e.step = step
        e.attempt_index = attempt_index
        e.attempts_planned = attempts_planned
        e.term_kind = term_kind
        e.term_value = term_value
        e.term_final_kind = term_final_kind
        e.term_final_value = term_final_value
        e.escalated = escalated
        e.retry_eligible = retry_eligible
        e.classification = classification
        e.duration_seconds = duration_seconds
        e.captured_stdout = captured_stdout^
        e.captured_stderr = captured_stderr^
        e.stdout_truncated = stdout_truncated
        e.stderr_truncated = stderr_truncated
        e.attempt_argv = attempt_argv^
        return e^

    @staticmethod
    def crash_attribution(
        path: String,
        disposition: AttributionDisposition,
        culprit_test: String,
        isolation_reruns: Int,
        attribution_seconds: Float64,
    ) -> Event:
        """One crash file's bounded-isolation attribution result.

        Args:
            path: The crashing file the pass investigated.
            disposition: Why the isolation pass stopped where it did.
            culprit_test: The attributed test name, empty when none was
                attributed.
            isolation_reruns: How many isolation reruns the pass performed.
            attribution_seconds: The pass's wall time, in seconds.

        Returns:
            A CRASH_ATTRIBUTION event.
        """
        var e = Event._blank(EventKind.CRASH_ATTRIBUTION)
        e.path = path
        e.attribution_disposition = disposition
        e.culprit_test = culprit_test
        e.isolation_reruns = isolation_reruns
        e.attribution_seconds = attribution_seconds
        return e^
