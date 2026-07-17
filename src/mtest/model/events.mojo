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
from mtest.model.attribution import AttributionDisposition
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
    comptime ATTEMPT_FINISHED = Self(9)
    comptime CRASH_ATTRIBUTION = Self(10)

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
    """The dependent test files that could not run (empty if only a count is known)."""
    var ending_known: Bool
    """Whether the step's final termination identity rides with this event.

    A PrecompileFailed carries HOW the step's last attempt ended in the shared
    `term_kind`/`term_value`/`escalated`/`timeout_seconds`/`attempts_used` fields.
    This flag says those fields were populated, so a reporter never renders an
    unset termination as the lie "exited 0"."""

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
    var attempts_used: Int
    """How many attempts the file's run took to reach its outcome; 1 when it
    ran once with no retry (FileFinished)."""
    var flaky: Bool
    """Whether the file passed only after one or more failing attempts
    (FileFinished)."""
    var slow: Bool
    """Whether the file's wall time crossed the slow threshold (FileFinished)."""

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
    """The latched final termination kind after any escalation."""
    var term_final_value: Int
    """The termination value paired with `term_final_kind`."""
    var escalated: Bool
    """Whether the runner escalated the signal (e.g. SIGTERM then SIGKILL); a
    TRY line reads "SIGTERM sent, escalated to SIGKILL" from these fields."""
    var retry_eligible: Bool
    """Whether the classifier judged this attempt retry-eligible/crash-class."""
    var classification: String
    """A short classification label for the attempt (e.g. "signal",
    "compile-timeout", "compile-crash")."""
    var stdout_truncated: Bool
    """Whether the captured stdout excerpt was truncated by the caller's bound,
    so the reporter can print a loud "excerpt" marker (AttemptFinished)."""
    var stderr_truncated: Bool
    """Whether the captured stderr excerpt was truncated by the caller's bound
    (AttemptFinished)."""
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
    """The wall time the attribution pass took, in seconds (CrashAttribution)."""

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
    var flaky_files: Int
    """How many files passed only after a retry, run-wide (SessionFinished)."""

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
        """The run began: root, resolved toolchain, and selected/excluded counts.

        `shard_label` names the shard identity for a sharded run (e.g. "2/5")
        and `sharded_out_count` how many selected files were handed to other
        shards; both default so existing callers are unaffected.
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

        Carries the offending pattern as data; the reporter composes the
        sentence from `warning_kind` and `warning_pattern`.
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

        `casualties` names the dependent test files that could not run; when it
        is non-empty its length is authoritative for the count (§8.3 asks the
        banner to list them, not merely count them).

        The step's FINAL ending rides as typed data so the banner can name it in
        words rather than leave a reader guessing: `term_kind`/`term_value` are
        the decomposed exec-layer termination (0 EXITED, 1 SIGNALED, 2 TIMED_OUT,
        3 SPAWN_FAILED) with `escalated` for a SIGKILL escalation,
        `timeout_seconds` the deadline WE enforced on a TIMED_OUT step, and
        `attempts_used` how many attempts the retry budget spent. A caller that
        knows none of this leaves `ending_known` False and the reporter says
        nothing about the ending rather than inventing one.
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
        attempts_used: Int = 1,
        flaky: Bool = False,
        slow: Bool = False,
        escalated: Bool = False,
    ) -> Event:
        """A file's run finished, carrying the data the reporter renders from.

        The per-outcome specifics ride as data: `signal_number` for a CRASH,
        `exit_status` for a FAIL, `timeout_seconds` for a TIMEOUT, and
        `exclusion_pattern` for an EXCLUDED line. The build command rides as
        `build_argv`, and the captured streams as raw bytes. `parse_disposition`
        and the four `*_tests` totals carry the test-granularity read of this
        file's report. `attempts_used`/`flaky`/`slow` carry the resilience
        summary of the run. `escalated` is the run `Termination`'s latched
        SIGKILL escalation, so a TIMEOUT verdict can say whether the child went
        down on the polite SIGTERM or had to be killed — the same fact a TRY
        line reads, but available with no retry in play. Every one defaults so
        existing callers are unaffected.
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
        flaky_files: Int = 0,
    ) -> Event:
        """The run ended: the full summary tally, wall time, and exit code.

        `test_counts` carries the authoritative per-test totals and
        `flaky_files` how many files passed only after a retry; both default so
        existing callers are unaffected.
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

        Carries everything a reporter needs to render the attempt now AND to
        serialize it later without re-parsing bytes: `path` associates it with a
        file and `step` is the attempted step ("build" | "run" | "precompile").
        The termination identity rides as plain fields — `term_kind`/`term_value`
        with the latched `term_final_kind`/`term_final_value` and `escalated` —
        decomposed from an exec.Termination so this layer imports nothing above
        it. `retry_eligible` and `classification` carry the classifier verdict,
        `duration_seconds` the attempt's wall time, and the captured streams the
        bounded excerpts with their `*_truncated` markers (the caller bounds the
        bytes before constructing the event). `attempt_argv` is the argv for the
        reproduce line.
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

        `path` is the crashing file, `disposition` why the pass stopped,
        `culprit_test` the attributed test (empty when none), `isolation_reruns`
        how many reruns it took, and `attribution_seconds` the pass's wall time.
        """
        var e = Event._blank(EventKind.CRASH_ATTRIBUTION)
        e.path = path
        e.attribution_disposition = disposition
        e.culprit_test = culprit_test
        e.isolation_reruns = isolation_reruns
        e.attribution_seconds = attribution_seconds
        return e^
