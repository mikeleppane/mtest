"""The closed, typed event set of the mtest runner.

These events are the whole vocabulary of the seam between the session and the
reporters: the session emits them and nothing else, and each reporter consumes
them through a single `handle(mut self, e: Event)` method. To keep that
single-method composition while making an invalid kind/payload pairing
impossible to build, the set is one closed `Event` type carrying a `Variant`
over one payload struct per kind. Each payload holds only the fields its kind
uses, so there is no `path` to read on a `WARNING`, and the outer `kind` tag is
derived from the payload's own `KIND`, never passed in, so the two can never
disagree. A factory method builds each kind.

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
from std.utils import Variant

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


trait EventPayload(Copyable, Movable):
    """A single event kind's payload arm.

    Each conforming struct holds only its own kind's fields and names its kind
    once, as `KIND`, so `Event` derives the outer tag from the payload rather
    than accepting a separate, forgeable discriminant.
    """

    comptime KIND: EventKind


@fieldwise_init
struct SessionStartedPayload(EventPayload):
    """The `SESSION_STARTED` payload: the run began."""

    comptime KIND = EventKind.SESSION_STARTED

    var root: String
    """The discovery root the run started from."""
    var toolchain: String
    """The resolved mojo path and version label."""
    var selected_count: Int
    """How many discovered files were selected to run."""
    var excluded_count: Int
    """How many discovered files were excluded."""
    var shard_label: String
    """The shard identity for a sharded run (e.g. "2/5"), empty when
    unsharded."""
    var sharded_out_count: Int
    """How many selected files this shard handed off to other shards."""


@fieldwise_init
struct WarningPayload(EventPayload):
    """The `WARNING` payload: a loud non-file notice."""

    comptime KIND = EventKind.WARNING

    var warning_kind: String
    """A short tag for the warning class (e.g. a stale exclusion)."""
    var warning_pattern: String
    """The offending pattern the warning concerns; the reporter composes the
    sentence from the kind and this datum."""


@fieldwise_init
struct PrecompileFailedPayload(EventPayload):
    """The `PRECOMPILE_FAILED` payload: a session-level build step failed."""

    comptime KIND = EventKind.PRECOMPILE_FAILED

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

    Carries how the step's last attempt ended in the
    `term_kind`/`term_value`/`escalated`/`timeout_seconds`/`attempts_used`
    fields. This flag says those fields were populated, so a reporter never
    renders an unset termination as "exited 0"."""
    var term_kind: Int
    """The decomposed exec-layer termination kind of the step's last attempt."""
    var term_value: Int
    """The value paired with `term_kind` (e.g. a signal number or exit
    status)."""
    var escalated: Bool
    """Whether the deadline kill escalated SIGTERM to SIGKILL."""
    var timeout_seconds: Int
    """The deadline mtest enforced on a TIMED_OUT step, in seconds."""
    var attempts_used: Int
    """How many attempts the retry budget spent."""


@fieldwise_init
struct FileStartedPayload(EventPayload):
    """The `FILE_STARTED` payload: a file's run is starting."""

    comptime KIND = EventKind.FILE_STARTED

    var path: String
    """The path of the file about to run."""


@fieldwise_init
struct FileFinishedPayload(EventPayload):
    """The `FILE_FINISHED` payload: a file's run finished.

    The per-outcome specifics ride as data rather than as rendered text, and
    each one is meaningful only for its own outcome.
    """

    comptime KIND = EventKind.FILE_FINISHED

    var path: String
    """The path of the file that ran."""
    var outcome: Outcome
    """The file's outcome."""
    var duration_seconds: Float64
    """Wall time the file's run took, in seconds."""
    var build_argv: List[String]
    """The build command as argv, for the reporter to shell-join."""
    var build_duration_seconds: Float64
    """Wall time the build took, in seconds, for verbose output."""
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
    """Why the report parse landed where it did."""
    var passed_tests: Int
    """How many tests in this file passed, at test granularity."""
    var failed_tests: Int
    """How many tests in this file failed, at test granularity."""
    var skipped_tests: Int
    """How many tests in this file were skipped, at test granularity."""
    var deselected_tests: Int
    """How many tests in this file were deselected, at test granularity."""
    var attempts_used: Int
    """How many attempts the file's run took to reach its outcome; 1 when it
    ran once with no retry."""
    var flaky: Bool
    """Whether the file passed only after one or more failing attempts."""
    var slow: Bool
    """Whether the file's wall time crossed the slow threshold."""
    var escalated: Bool
    """The run termination's latched SIGKILL escalation, so a TIMEOUT verdict
    can say whether the child went down on SIGTERM or had to be killed."""
    var stdout_truncated: Bool
    """Whether the file-scope process result's stdout was truncated by the
    capture bound, propagated by the session."""
    var stderr_truncated: Bool
    """Whether the file-scope process result's stderr was truncated by the
    capture bound, propagated by the session."""


@fieldwise_init
struct SessionFinishedPayload(EventPayload):
    """The `SESSION_FINISHED` payload: the run ended."""

    comptime KIND = EventKind.SESSION_FINISHED

    var summary: Summary
    """The per-outcome tally, including excluded and not-run."""
    var wall_time_seconds: Float64
    """Total wall time of the whole session, in seconds."""
    var exit_code: Int
    """The process exit code the session resolved."""
    var test_counts: TestCounts
    """The authoritative per-test totals for the whole run."""
    var flaky_files: Int
    """How many files passed only after a retry, run-wide."""


@fieldwise_init
struct InternalErrorPayload(EventPayload):
    """The `INTERNAL_ERROR` payload: a spawn or machinery failure."""

    comptime KIND = EventKind.INTERNAL_ERROR

    var step: String
    """The step that failed: `"build"`, `"run"`, or `"precompile"`."""
    var program: String
    """The executable a failed spawn tried to run."""
    var errno: Int
    """The spawn errno (0 when the cause is a machinery raise rather than a
    spawn failure)."""


@fieldwise_init
struct TestReportedPayload(EventPayload):
    """The `TEST_REPORTED` payload: one test's result.

    `path` mirrors `test.node.path`, so the accessors work without inspecting
    `test`.
    """

    comptime KIND = EventKind.TEST_REPORTED

    var path: String
    """The path of the file this test belongs to (mirrors `test.node.path`)."""
    var test: TestResult
    """The per-test result this event reports."""


@fieldwise_init
struct CollectionKnownPayload(EventPayload):
    """The `COLLECTION_KNOWN` payload: run-wide selected/deselected totals."""

    comptime KIND = EventKind.COLLECTION_KNOWN

    var selected_test_total: Int
    """How many tests, across the whole run, are selected."""
    var deselected_test_total: Int
    """How many tests, across the whole run, are deselected."""


@fieldwise_init
struct AttemptFinishedPayload(EventPayload):
    """The `ATTEMPT_FINISHED` payload: one non-final retry attempt's record.

    Carries everything a reporter needs to render the attempt now and to
    serialize it later without re-parsing bytes. The termination identity rides
    as plain Int fields, decomposed from an `exec.Termination`, so this layer
    imports nothing above it.
    """

    comptime KIND = EventKind.ATTEMPT_FINISHED

    var path: String
    """The file this attempt belongs to."""
    var step: String
    """The attempted step: `"build"`, `"run"`, or `"precompile"`."""
    var attempt_index: Int
    """Which attempt this was, 1-based (the k-th of the planned attempts)."""
    var attempts_planned: Int
    """How many attempts were planned in total (the retry budget, N+1)."""
    var term_kind: Int
    """This attempt's raw termination kind, decomposed from an
    `exec.Termination`."""
    var term_value: Int
    """The termination value paired with `term_kind` (e.g. the signal number or
    exit status of this attempt)."""
    var term_final_kind: Int
    """The latched final termination kind after any escalation, meaningful only
    when `term_kind` is TIMED_OUT.

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
    var duration_seconds: Float64
    """The attempt's wall time, in seconds."""
    var captured_stdout: List[UInt8]
    """A bounded stdout excerpt; the caller bounds the bytes before constructing
    the event."""
    var captured_stderr: List[UInt8]
    """A bounded stderr excerpt, bounded by the caller."""
    var stdout_truncated: Bool
    """Whether that stdout excerpt hit its bound."""
    var stderr_truncated: Bool
    """Whether that stderr excerpt hit its bound."""
    var attempt_argv: List[String]
    """The argv this attempt ran, for the reproduce/diagnostic line."""


@fieldwise_init
struct CrashAttributionPayload(EventPayload):
    """The `CRASH_ATTRIBUTION` payload: one crash file's attribution result."""

    comptime KIND = EventKind.CRASH_ATTRIBUTION

    var path: String
    """The crashing file the pass investigated."""
    var attribution_disposition: AttributionDisposition
    """Why the bounded crash-isolation pass stopped."""
    var culprit_test: String
    """The attributed culprit test name, empty when none was attributed."""
    var isolation_reruns: Int
    """How many isolation reruns the attribution pass performed."""
    var attribution_seconds: Float64
    """The wall time the attribution pass took, in seconds."""


comptime EventData = Variant[
    SessionStartedPayload,
    WarningPayload,
    PrecompileFailedPayload,
    FileStartedPayload,
    FileFinishedPayload,
    SessionFinishedPayload,
    InternalErrorPayload,
    TestReportedPayload,
    CollectionKnownPayload,
    AttemptFinishedPayload,
    CrashAttributionPayload,
]
"""The closed set of event payloads, one arm per `EventKind`."""


struct Event(Copyable, Movable):
    """One event on the session-to-reporter seam.

    A single closed type carrying a `Variant` over one payload struct per kind.
    The `kind` tag is derived from the payload's `KIND`, never passed in, so a
    kind and its payload can never disagree, and a payload holds only its own
    kind's fields, so a field meaningless for the current kind is not
    representable. Build events through the factory methods; read a payload back
    through the typed arm, e.g. `e.data[FileFinishedPayload].outcome` under an
    `e.kind == EventKind.FILE_FINISHED` guard. Owns its payload, so copies are
    explicit.
    """

    var kind: EventKind
    """Which variant this event is; equals the active payload's `KIND`.

    Derived from the active payload arm at construction time; do not reassign
    it directly, as that would desync the tag from `data`."""
    var data: EventData
    """The typed payload for `kind`."""

    def __init__[P: EventPayload](out self, var payload: P):
        """Wrap one typed payload, deriving the tag from its `KIND`.

        Args:
            payload: The kind's payload arm. Consumed. Its `KIND` becomes the
                event's `kind`, so the tag can never disagree with the payload.
        """
        self.kind = P.KIND
        self.data = EventData(payload^)

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
        return Event(
            SessionStartedPayload(
                root,
                toolchain,
                selected_count,
                excluded_count,
                shard_label,
                sharded_out_count,
            )
        )

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
        return Event(WarningPayload(warning_kind, warning_pattern))

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
        var resolved_count = len(casualties) if casualties else casualty_count
        return Event(
            PrecompileFailedPayload(
                step,
                compiler_output,
                resolved_count,
                casualties.copy(),
                ending_known,
                term_kind,
                term_value,
                escalated,
                timeout_seconds,
                attempts_used,
            )
        )

    @staticmethod
    def file_started(path: String) -> Event:
        """A file's run is starting.

        Args:
            path: The path of the file about to run.

        Returns:
            A FILE_STARTED event.
        """
        return Event(FileStartedPayload(path))

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
        return Event(
            FileFinishedPayload(
                path,
                outcome,
                duration_seconds,
                build_argv^,
                build_duration_seconds,
                captured_stdout^,
                captured_stderr^,
                signal_number,
                exit_status,
                timeout_seconds,
                exclusion_pattern,
                parse_disposition,
                passed_tests,
                failed_tests,
                skipped_tests,
                deselected_tests,
                attempts_used,
                flaky,
                slow,
                escalated,
                stdout_truncated,
                stderr_truncated,
            )
        )

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
        return Event(InternalErrorPayload(step, program, errno))

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
        return Event(
            SessionFinishedPayload(
                summary^, wall_time_seconds, exit_code, test_counts, flaky_files
            )
        )

    @staticmethod
    def test_reported(var test: TestResult) -> Event:
        """One test's result, reported retrospectively after its file exits.

        Conceptually sits between `FileStarted` and `FileFinished`, once a
        child's report parses. The event's `path` mirrors `test.node.path`, so
        the `path` accessors work without inspecting `test`.

        Args:
            test: The per-test result to report. Consumed.

        Returns:
            A TEST_REPORTED event.
        """
        var path = test.node.path.copy()
        return Event(TestReportedPayload(path^, test^))

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
        return Event(
            CollectionKnownPayload(selected_test_total, deselected_test_total)
        )

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
        return Event(
            AttemptFinishedPayload(
                path,
                step,
                attempt_index,
                attempts_planned,
                term_kind,
                term_value,
                term_final_kind,
                term_final_value,
                escalated,
                retry_eligible,
                classification,
                duration_seconds,
                captured_stdout^,
                captured_stderr^,
                stdout_truncated,
                stderr_truncated,
                attempt_argv^,
            )
        )

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
        return Event(
            CrashAttributionPayload(
                path,
                disposition,
                culprit_test,
                isolation_reruns,
                attribution_seconds,
            )
        )
