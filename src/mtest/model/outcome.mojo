"""The outcome vocabulary of the mtest runner.

This module names every outcome the runner can report and classifies which of
them count as a failure. It imports nothing internal, and every layer above
imports its vocabulary from here.

The whole v1 vocabulary is defined here, so later work only starts emitting the
values it needs and never redefines the set. The runner currently produces
PASS, FAIL, SKIP, CRASH, TIMEOUT, COMPILE_ERROR, COMPILE_TIMEOUT,
MALFORMED_SUITE, and FLAKY, plus the internal EXCLUDED and NOT_RUN. Two values
are defined but never assigned: a deselected test is dropped from the selection
rather than marked DESELECTED, and a precompile failure travels as its own
event carrying the step and its casualties rather than as a PRECOMPILE_ERROR
outcome, so the reporters that branch on it read a tally that stays zero.

The values split into two groups: the reported per-test and per-file outcomes
PASS through FLAKY, and the internal states DESELECTED, EXCLUDED, and NOT_RUN,
which are not per-test outcomes at all. The retry machinery that decides when a
late pass is FLAKY lives in the session, not here.

The failing class, which drives process exit 1, is exactly FAIL, CRASH, TIMEOUT,
COMPILE_ERROR, COMPILE_TIMEOUT, MALFORMED_SUITE, and PRECOMPILE_ERROR. PASS and
SKIP pass; FLAKY and the internal states do not fail.
"""


@fieldwise_init
struct Outcome(Equatable, ImplicitlyCopyable, Movable):
    """One value from the runner's outcome vocabulary.

    A thin wrapper over a stable integer discriminant, so the vocabulary is a
    closed set of named constants that compare by value. It holds no owned
    resources, so copies and moves are trivial.
    """

    var code: Int
    """The stable integer discriminant identifying this outcome."""

    # Reported outcomes.
    comptime PASS = Self(0)
    """The test passed, or the file's run exited 0."""
    comptime FAIL = Self(1)
    """The test failed, or the file's run exited nonzero."""
    comptime SKIP = Self(2)
    """The test was skipped by the child suite itself."""
    comptime CRASH = Self(3)
    """The run died by a signal: a real crash, never read as a failure."""
    comptime TIMEOUT = Self(4)
    """The runner's own `--timeout` deadline killed the run."""
    comptime COMPILE_ERROR = Self(5)
    """The build failed, so the file never ran. A compiler that itself dies by
    a signal lands here too, as a build failure rather than a test crash."""
    comptime COMPILE_TIMEOUT = Self(6)
    """The `--compile-timeout` deadline killed the build before the compiler
    reached any verdict on the source."""
    comptime MALFORMED_SUITE = Self(7)
    """The file ran but its stdout carried no honest report: absent,
    off-grammar, or ambiguous against the pinned report grammar."""
    comptime PRECOMPILE_ERROR = Self(8)
    """A session-level precompile step failed. In the failing class, but never
    assigned — precompile failure travels as its own event instead."""
    comptime FLAKY = Self(9)
    """A pass that only arrived after a crash-class attempt was retried; an
    annotation on a pass, not a failure."""
    # Internal states (not per-test outcomes).
    comptime DESELECTED = Self(10)
    """A test suppressed from the run by selection. Never assigned — a
    deselected test is dropped from the selection rather than marked."""
    comptime EXCLUDED = Self(11)
    """A discovered file an `--exclude` pattern removed before any build."""
    comptime NOT_RUN = Self(12)
    """A discovered file that never ran. Also the total-function sentinel the
    verdict mappers return for a spawn failure, which the session routes to an
    internal error rather than recording."""

    comptime COUNT = 13
    """The number of distinct values in the vocabulary."""

    def __eq__(self, other: Self) -> Bool:
        """Two outcomes are equal iff their discriminants match."""
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return self.code != other.code

    def is_failing(self) -> Bool:
        """Whether this outcome is in the failing class, which drives exit 1.

        Returns:
            True for exactly FAIL, CRASH, TIMEOUT, COMPILE_ERROR,
            COMPILE_TIMEOUT, MALFORMED_SUITE, and PRECOMPILE_ERROR; False for
            every other value, including PASS, SKIP, the FLAKY pass
            annotation, and the internal states.
        """
        return (
            self == Self.FAIL
            or self == Self.CRASH
            or self == Self.TIMEOUT
            or self == Self.COMPILE_ERROR
            or self == Self.COMPILE_TIMEOUT
            or self == Self.MALFORMED_SUITE
            or self == Self.PRECOMPILE_ERROR
        )
