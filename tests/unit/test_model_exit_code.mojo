"""Exhaustive tests for the two pure functions that decide the exit code.

`exit_code_for` is total over the multiset of run outcomes and returns only 1,
5, or 0. The domain is enumerated, not sampled: every single-outcome case, the
empty case, and mixed multisets that prove a single failing outcome dominates
any number of passing ones. Assertions are exact integer comparisons.

`resolve_exit_code` is total over `TerminalFacts` and decides the code the
process actually exits with. Its whole domain is enumerated below — every
combination of the five boolean facts against every code the outcome tier can
present — because this is the product contract, and an exit code is right or it
is a lie. The named tests beside the table pin each individual rule at literal
values, so the table's expectation ladder is never the only witness.
"""
from std.testing import assert_equal

from mtest.model import (
    Outcome,
    TerminalFacts,
    exit_code_for,
    resolve_exit_code,
    EXIT_SUCCESS,
    EXIT_FAILURE,
    EXIT_NOTHING_RAN,
    EXIT_INTERNAL_ERROR,
)
from mtest.model.exit_code import EXIT_INTERRUPTED


def _all_outcomes() -> List[Outcome]:
    """Every value in the vocabulary, once each. Does not mutate or raise."""
    return [
        Outcome.PASS,
        Outcome.FAIL,
        Outcome.SKIP,
        Outcome.CRASH,
        Outcome.TIMEOUT,
        Outcome.COMPILE_ERROR,
        Outcome.COMPILE_TIMEOUT,
        Outcome.MALFORMED_SUITE,
        Outcome.PRECOMPILE_ERROR,
        Outcome.FLAKY,
        Outcome.DESELECTED,
        Outcome.EXCLUDED,
        Outcome.NOT_RUN,
    ]


def _resolved(
    interrupted: Bool,
    internal_error: Bool,
    drift: Bool,
    precompile_failed: Bool,
    outcome_code: Int,
    delivery_failed: Bool,
) -> Int:
    """Resolve one fact combination, spelled positionally for the tables below.

    Keeps every assertion in this file a single readable line and lets the
    exhaustive table drive the six facts from loop variables. Does not mutate or
    raise.
    """
    return resolve_exit_code(
        TerminalFacts(
            interrupted=interrupted,
            internal_error=internal_error,
            drift=drift,
            precompile_failed=precompile_failed,
            outcome_code=outcome_code,
            delivery_failed=delivery_failed,
        )
    )


def test_exit_code_constants() raises:
    assert_equal(EXIT_SUCCESS, 0)
    assert_equal(EXIT_FAILURE, 1)
    assert_equal(EXIT_NOTHING_RAN, 5)
    assert_equal(EXIT_INTERRUPTED, 2)
    assert_equal(EXIT_INTERNAL_ERROR, 3)


def test_empty_multiset_is_nothing_ran() raises:
    var empty = List[Outcome]()
    assert_equal(exit_code_for(empty), 5)


def test_every_singleton_matches_its_failing_class() raises:
    # Enumerate the whole vocabulary: a lone failing outcome yields 1, any other
    # lone outcome yields 0.
    for o in _all_outcomes():
        var expected = 1 if o.is_failing() else 0
        assert_equal(exit_code_for([o]), expected)


def test_all_passing_multiset_is_success() raises:
    # A non-empty multiset with no failing member yields 0. SKIP is not failing.
    assert_equal(exit_code_for([Outcome.PASS, Outcome.PASS, Outcome.PASS]), 0)
    assert_equal(exit_code_for([Outcome.PASS, Outcome.SKIP]), 0)
    assert_equal(exit_code_for([Outcome.SKIP, Outcome.SKIP]), 0)
    assert_equal(exit_code_for([Outcome.PASS, Outcome.FLAKY]), 0)


def test_one_failing_dominates_any_number_of_passes() raises:
    # For every failing outcome, its presence among passes forces exit 1 — the
    # "any failing -> 1" rule dominates "all pass -> 0", regardless of position.
    for o in _all_outcomes():
        if not o.is_failing():
            continue
        assert_equal(exit_code_for([o, Outcome.PASS, Outcome.PASS]), 1)
        assert_equal(exit_code_for([Outcome.PASS, o, Outcome.PASS]), 1)
        assert_equal(exit_code_for([Outcome.PASS, Outcome.PASS, o]), 1)
        assert_equal(exit_code_for([Outcome.SKIP, o]), 1)


def test_lone_internal_state_is_pinned_not_failing() raises:
    # DESELECTED, EXCLUDED, and NOT_RUN should never normally be passed in the
    # multiset (deselected/excluded/not-run tests did not run) -- but the raw
    # function behavior is pinned here so the contract is explicit: none of
    # them is in the failing class, so a lone one yields 0, not 5 or 1.
    assert_equal(exit_code_for([Outcome.DESELECTED]), 0)
    assert_equal(exit_code_for([Outcome.EXCLUDED]), 0)
    assert_equal(exit_code_for([Outcome.NOT_RUN]), 0)


def test_flaky_never_contributes_to_failing_exit() raises:
    # A FLAKY outcome is a pass that only succeeded on a retry: it must never
    # push the exit code to 1. A multiset of FLAKY among PASS and SKIP yields 0,
    # and a lone FLAKY yields 0 -- the flaky-is-non-failing guarantee, explicit.
    assert_equal(exit_code_for([Outcome.FLAKY]), 0)
    assert_equal(exit_code_for([Outcome.PASS, Outcome.FLAKY, Outcome.SKIP]), 0)
    assert_equal(exit_code_for([Outcome.FLAKY, Outcome.FLAKY, Outcome.PASS]), 0)
    # A real failure still dominates, even beside a flaky pass.
    assert_equal(exit_code_for([Outcome.FLAKY, Outcome.FAIL]), 1)


def test_all_skip_multiset_is_success() raises:
    assert_equal(exit_code_for([Outcome.SKIP, Outcome.SKIP, Outcome.SKIP]), 0)


def test_fail_among_passes_is_failure() raises:
    assert_equal(exit_code_for([Outcome.PASS, Outcome.FAIL, Outcome.PASS]), 1)


def test_multiple_failing_outcomes_still_one() raises:
    assert_equal(
        exit_code_for([Outcome.FAIL, Outcome.CRASH, Outcome.TIMEOUT]), 1
    )
    assert_equal(
        exit_code_for([Outcome.COMPILE_ERROR, Outcome.PASS, Outcome.FAIL]), 1
    )


def test_resolver_precedence_table_is_exhaustive() raises:
    # The WHOLE domain: every combination of the five boolean facts (32) against
    # every code the outcome tier can present (5) — 0, 1 and 5 from
    # `exit_code_for`, plus 2 and 3 for the caller that re-applies the delivery
    # precedence to a code the session already resolved. 160 cases, none sampled.
    #
    # The expectation is written as a SINGLE-PASS ladder with the delivery fact
    # hoisted above the 3-tier and the 1-tier, deliberately a different shape
    # from the resolver's own two-stage form, so a transcription slip in either
    # one shows up as a disagreement rather than cancelling out.
    var codes = [0, 1, 2, 3, 5]
    var seen = 0
    for bits in range(32):
        var interrupted = (bits & 1) != 0
        var internal_error = (bits & 2) != 0
        var drift = (bits & 4) != 0
        var precompile_failed = (bits & 8) != 0
        var delivery_failed = (bits & 16) != 0
        for c in codes:
            var expected: Int
            if interrupted:
                # An interrupt dominates every other fact, delivery included.
                expected = 2
            elif (
                c == 2
                and not internal_error
                and not drift
                and not precompile_failed
            ):
                # A re-applied 2 is still an interrupt verdict: it stands.
                expected = 2
            elif delivery_failed:
                # Nothing below the 2-tier survives an undelivered artifact.
                expected = 3
            elif internal_error or drift:
                expected = 3
            elif precompile_failed:
                expected = 1
            else:
                expected = c
            assert_equal(
                _resolved(
                    interrupted,
                    internal_error,
                    drift,
                    precompile_failed,
                    c,
                    delivery_failed,
                ),
                expected,
                "facts bits=" + String(bits) + " outcome_code=" + String(c),
            )
            seen += 1
    assert_equal(seen, 160, "the table must enumerate the whole domain")


def test_clean_run_resolves_to_the_outcome_code() raises:
    # No fact set: the code is exactly the outcome code (0/1/5) `exit_code_for`
    # produced — the resolution layer is a pass-through.
    assert_equal(_resolved(False, False, False, False, 0, False), 0)
    assert_equal(_resolved(False, False, False, False, 1, False), 1)
    assert_equal(_resolved(False, False, False, False, 5, False), 5)


def test_interrupt_dominates_every_other_fact() raises:
    # A run-time interrupt resolves to 2 even above an internal error, drift, a
    # precompile failure, or a delivery failure — the frozen precedence.
    assert_equal(_resolved(True, True, True, True, 1, True), 2)


def test_interrupt_dominates_each_raw_outcome_multiset_code() raises:
    # The parallel scheduler feeds resolve_exit_code a RAW outcome-multiset code
    # — 0, 1, or 5 from `exit_code_for` over the run outcomes — together with
    # interrupted=True, never a pre-resolved code and never the kernel's halt
    # latch. Each raw code is dominated to exit 2, which is precisely why the
    # pool may fold a straggling limit verdict without the exit ever catching it.
    assert_equal(_resolved(True, False, False, False, 0, False), 2)
    assert_equal(_resolved(True, False, False, False, 1, False), 2)
    assert_equal(_resolved(True, False, False, False, 5, False), 2)


def test_internal_error_is_three() raises:
    assert_equal(_resolved(False, True, False, False, 0, False), 3)


def test_drift_is_three() raises:
    assert_equal(_resolved(False, False, True, False, 0, False), 3)


def test_precompile_failure_is_one() raises:
    assert_equal(_resolved(False, False, False, True, 0, False), 1)


def test_precompile_failure_yields_to_internal_error() raises:
    # Internal error outranks a precompile failure (the 3 tier beats the 1 tier).
    assert_equal(_resolved(False, True, False, True, 0, False), 3)


def test_delivery_failure_escalates_a_clean_pass_to_three() raises:
    # A resolved 0 escalates to 3 when a terminal artifact could not be
    # delivered (a dead --json destination, a junit report that never published,
    # a close that reported a deferred write error).
    assert_equal(_resolved(False, False, False, False, 0, True), 3)


def test_delivery_failure_escalates_a_failing_run_to_three() raises:
    # A resolved 1 (a failing run) also escalates to 3: the product could not be
    # delivered, so the run's own verdict is no longer authoritative.
    assert_equal(_resolved(False, False, False, False, 1, True), 3)


def test_delivery_failure_escalates_the_nothing_ran_five() raises:
    assert_equal(_resolved(False, False, False, False, 5, True), 3)


def test_delivery_failure_leaves_a_resolved_three_at_three() raises:
    # A resolved 3 (internal error) stays 3 under a later delivery failure.
    assert_equal(_resolved(False, True, False, False, 0, True), 3)


def test_interrupt_stands_over_a_later_delivery_failure() raises:
    # The interrupt precedence is never displaced by a delivery failure: a
    # resolved 2 stays 2 even when finalization also failed. This is the case
    # most likely to regress, so it is pinned on its own.
    assert_equal(_resolved(True, False, False, False, 0, True), 2)
    assert_equal(_resolved(True, False, False, True, 1, True), 2)


def test_delivery_precedence_reapplied_to_an_already_resolved_code() raises:
    # The caller that learns of a delivery failure only AFTER the session
    # resolved a code presents that code as the outcome code with no other fact
    # set. No delivery failure: the resolved code is untouched, whatever it is.
    assert_equal(_resolved(False, False, False, False, 0, False), 0)
    assert_equal(_resolved(False, False, False, False, 1, False), 1)
    assert_equal(_resolved(False, False, False, False, 2, False), 2)
    assert_equal(_resolved(False, False, False, False, 5, False), 5)
    assert_equal(_resolved(False, False, False, False, 3, False), 3)
    # A delivery failure escalates a resolved 0/1/5 to 3 (the artifact was not
    # durably committed), a resolved 2 STANDS (interrupt dominates), and a
    # resolved 3 stays 3.
    assert_equal(_resolved(False, False, False, False, 0, True), 3)
    assert_equal(_resolved(False, False, False, False, 1, True), 3)
    assert_equal(_resolved(False, False, False, False, 5, True), 3)
    assert_equal(_resolved(False, False, False, False, 2, True), 2)
    assert_equal(_resolved(False, False, False, False, 3, True), 3)
