"""The exit codes, and the two pure functions that decide which one a run gets.

This module owns the process exit code end to end. `exit_code_for` maps the
multiset of run outcomes to the three codes that mapping alone decides: 1, 5,
and 0. `resolve_exit_code` then folds that outcome code together with the run's
control-flow facts — an interrupt, an internal error, protocol drift, a
precompile failure, and whether a terminal artifact was delivered — into the
single code the process exits with. Every caller that reaches an exit code goes
through it, so the precedence is stated once and re-derived nowhere.

Code 4 is the one exception, and it stays with the entry point: a usage error is
refused before any run exists, so there are no outcomes and no facts to resolve.

The multiset callers pass is run outcomes at test granularity: one entry per
test that actually ran (PASS/FAIL/SKIP/…), plus one file-level outcome for each
file with no per-test attribution (CRASH, TIMEOUT, COMPILE_ERROR,
MALFORMED_SUITE, PRECOMPILE_ERROR). DESELECTED, EXCLUDED, and NOT_RUN never
appear in it, since a deselected, excluded, or not-run test did not run. An
empty multiset — an empty final selection, or an empty collection — maps to 5.
"""
from mtest.model.outcome import Outcome

comptime EXIT_SUCCESS = 0
"""All run outcomes passed (or skipped): a clean run."""
comptime EXIT_FAILURE = 1
"""At least one run outcome was in the failing class."""
comptime EXIT_NOTHING_RAN = 5
"""Nothing was runnable: an empty walk, or every discovered file excluded."""
comptime EXIT_INTERRUPTED = 2
"""The run was cut short by an interrupt: the accounting is truncated."""
comptime EXIT_INTERNAL_ERROR = 3
"""The runner failed, a report drifted, or an artifact was not delivered."""


def exit_code_for(outcomes: List[Outcome]) -> Int:
    """Map a multiset of run outcomes to a process exit code.

    Total over the multiset: every possible input maps to exactly one code. The
    rules apply in order:

    - If any outcome is in the failing class, return 1 (`EXIT_FAILURE`).
    - Else if the multiset is empty (nothing was runnable), return 5
      (`EXIT_NOTHING_RAN`).
    - Else return 0 (`EXIT_SUCCESS`): every outcome passed or skipped.

    Args:
        outcomes: The outcomes of the tests and files that actually ran.
            Excluded and not-run files are not part of this multiset.

    Returns:
        One of `EXIT_SUCCESS`, `EXIT_FAILURE`, or `EXIT_NOTHING_RAN`.
    """
    for o in outcomes:
        if o.is_failing():
            return EXIT_FAILURE
    if len(outcomes) == 0:
        return EXIT_NOTHING_RAN
    return EXIT_SUCCESS


@fieldwise_init
struct TerminalFacts(ImplicitlyCopyable, Movable):
    """What a finished run observed, as data the resolver ranks.

    Six independent observations and no policy: which of them wins is
    `resolve_exit_code`'s decision alone. Plain Bool and Int fields with no
    owned resources, so copies and moves are trivial.
    """

    var interrupted: Bool
    """Whether an interrupt was latched by the time the accounting was sealed."""
    var internal_error: Bool
    """Whether the runner's own machinery failed: a spawn failure or a raise."""
    var drift: Bool
    """Whether any report drifted off the pinned toolchain grammar."""
    var precompile_failed: Bool
    """Whether a precompile step failed."""
    var outcome_code: Int
    """The run's own verdict code, before the facts above and delivery apply.

    Normally the `exit_code_for` result over the run outcomes: 1, 5, or 0. A
    caller that learns of a delivery failure only after a code was already
    resolved presents that resolved code here, with no other fact set, which
    re-applies the delivery precedence to it and nothing else.
    """
    var delivery_failed: Bool
    """Whether a terminal artifact could not be delivered.

    Covers a latched machine-stream write failure such as a dead `--json`
    destination, a JUnit report that could not be published, and a `--json`
    descriptor whose close reported a deferred write error.
    """


def resolve_exit_code(facts: TerminalFacts) -> Int:
    """Resolve the one process exit code a run's facts add up to.

    Pure and total: it reads only `facts`, performs no I/O, mutates nothing,
    never raises, and maps every possible `TerminalFacts` value to exactly one
    code. Two precedences compose, in this order:

    - The base precedence: an interrupt dominates and yields 2, ranking above a
      resolved internal error because the run was truncated on purpose; else an
      internal error or protocol drift yields 3; else a precompile failure
      yields 1; else the outcome code stands.
    - The delivery precedence, applied last: a base of 2 stands, so an interrupt
      is never displaced by a later I/O failure; a base of 3 stays 3; and a base
      of 0, 1, or 5 escalates to 3 when a terminal artifact could not be
      delivered. A run's own verdict is not authoritative once its product could
      not be written.

    Args:
        facts: What the run observed. Not mutated.

    Returns:
        One of 2, 3, `EXIT_FAILURE`, `EXIT_NOTHING_RAN`, or `EXIT_SUCCESS` —
        or, when no fact is set, `facts.outcome_code` unchanged.
    """
    var base: Int
    if facts.interrupted:
        base = EXIT_INTERRUPTED
    elif facts.internal_error:
        base = EXIT_INTERNAL_ERROR
    elif facts.drift:
        base = EXIT_INTERNAL_ERROR
    elif facts.precompile_failed:
        base = EXIT_FAILURE
    else:
        base = facts.outcome_code
    if base == EXIT_INTERRUPTED:
        return EXIT_INTERRUPTED
    if facts.delivery_failed:
        return EXIT_INTERNAL_ERROR
    return base
