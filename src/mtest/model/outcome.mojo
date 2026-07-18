"""The outcome vocabulary of the mtest runner (Layer 0).

This module names every outcome the runner can report and classifies which of
them count as a failure. It is the base of the layering: it imports nothing
internal, and every layer above imports its vocabulary from here.

The full v1 vocabulary is defined now so future work only starts emitting the
values it adds, never redefines the set. The runner currently emits PASS, FAIL,
CRASH, TIMEOUT, COMPILE_ERROR, COMPILE_TIMEOUT, MALFORMED_SUITE,
PRECOMPILE_ERROR, and FLAKY, plus the internal EXCLUDED and NOT_RUN; the
remaining values exist here but are not produced yet.

The values split into three groups:

- Reported per-test/per-file outcomes: PASS, FAIL, SKIP, CRASH, TIMEOUT,
  COMPILE_ERROR, COMPILE_TIMEOUT, MALFORMED_SUITE, and the session-level
  PRECOMPILE_ERROR. FLAKY is the annotation on a pass that only succeeded on a
  retry; the session emits it on a late pass after a crash-class attempt, but
  this module itself builds no retry machinery — that lives in the session
  layer above.
- Internal states that are not per-test outcomes: DESELECTED, EXCLUDED, NOT_RUN.

The failing class (contributes to process exit 1) is exactly FAIL, CRASH,
TIMEOUT, COMPILE_ERROR, COMPILE_TIMEOUT, MALFORMED_SUITE, and PRECOMPILE_ERROR.
PASS and SKIP pass; FLAKY (a retried pass) and the internal states do not fail.
"""


@fieldwise_init
struct Outcome(Equatable, ImplicitlyCopyable, Movable):
    """One value from the runner's outcome vocabulary.

    A thin wrapper over a stable integer discriminant so the vocabulary is a
    closed set of named constants that compare by value. Holds no owned
    resources; copies and moves are trivial and it never raises.
    """

    var code: Int
    """The stable integer discriminant identifying this outcome."""

    # Reported outcomes.
    comptime PASS = Self(0)
    comptime FAIL = Self(1)
    comptime SKIP = Self(2)
    comptime CRASH = Self(3)
    comptime TIMEOUT = Self(4)
    comptime COMPILE_ERROR = Self(5)
    comptime COMPILE_TIMEOUT = Self(6)
    comptime MALFORMED_SUITE = Self(7)
    comptime PRECOMPILE_ERROR = Self(8)
    comptime FLAKY = Self(9)
    # Internal states (not per-test outcomes).
    comptime DESELECTED = Self(10)
    comptime EXCLUDED = Self(11)
    comptime NOT_RUN = Self(12)

    comptime COUNT = 13
    """The number of distinct values in the vocabulary."""

    def __eq__(self, other: Self) -> Bool:
        """Two outcomes are equal iff their discriminants match. Pure."""
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Pure."""
        return self.code != other.code

    def is_failing(self) -> Bool:
        """Whether this outcome belongs to the failing class (drives exit 1).

        True for exactly FAIL, CRASH, TIMEOUT, COMPILE_ERROR, COMPILE_TIMEOUT,
        MALFORMED_SUITE, and PRECOMPILE_ERROR; False for every other value,
        including PASS, SKIP, the FLAKY pass annotation, and the internal
        states. Total over the vocabulary; does not mutate or raise.
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
