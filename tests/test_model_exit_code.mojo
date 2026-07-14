"""Exhaustive tests for the pure outcome-multiset to exit-code function.

`exit_code_for` is total over the multiset of run outcomes and returns only 1,
5, or 0. The domain is enumerated, not sampled: every single-outcome case, the
empty case, and mixed multisets that prove a single failing outcome dominates
any number of passing ones. Assertions are exact integer comparisons.
"""
from std.testing import assert_equal, TestSuite

from mtest.model import (
    Outcome,
    exit_code_for,
    EXIT_SUCCESS,
    EXIT_FAILURE,
    EXIT_NOTHING_RAN,
)


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


def test_exit_code_constants() raises:
    assert_equal(EXIT_SUCCESS, 0)
    assert_equal(EXIT_FAILURE, 1)
    assert_equal(EXIT_NOTHING_RAN, 5)


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


def test_multiple_failing_outcomes_still_one() raises:
    assert_equal(
        exit_code_for([Outcome.FAIL, Outcome.CRASH, Outcome.TIMEOUT]), 1
    )
    assert_equal(
        exit_code_for([Outcome.COMPILE_ERROR, Outcome.PASS, Outcome.FAIL]), 1
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
