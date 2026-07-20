"""Tests for the Layer 0 outcome vocabulary and its failing classification.

Verifies that the full v1 outcome vocabulary exists as distinct values and that
`is_failing` partitions it exactly into the failing class (which drives exit 1)
and everything else. The classification is asserted member by member over the
whole enumerated vocabulary, not sampled.
"""
from std.testing import assert_equal, assert_true, assert_false

from mtest.model import Outcome


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


def test_vocabulary_is_complete_and_distinct() raises:
    var all = _all_outcomes()
    # The full vocabulary is present exactly once, and COUNT agrees.
    assert_equal(len(all), Outcome.COUNT)
    for i in range(len(all)):
        for j in range(len(all)):
            if i == j:
                assert_true(all[i] == all[j])
            else:
                assert_true(all[i] != all[j])


def test_failing_class_membership_is_exact() raises:
    # The failing class contributes to exit 1: FAIL, CRASH, TIMEOUT,
    # COMPILE_ERROR, COMPILE_TIMEOUT, MALFORMED_SUITE, PRECOMPILE_ERROR.
    assert_true(Outcome.FAIL.is_failing())
    assert_true(Outcome.CRASH.is_failing())
    assert_true(Outcome.TIMEOUT.is_failing())
    assert_true(Outcome.COMPILE_ERROR.is_failing())
    assert_true(Outcome.COMPILE_TIMEOUT.is_failing())
    assert_true(Outcome.MALFORMED_SUITE.is_failing())
    assert_true(Outcome.PRECOMPILE_ERROR.is_failing())


def test_non_failing_outcomes_are_not_failing() raises:
    # PASS and SKIP are not failing; FLAKY is a passed annotation; the internal
    # states are not per-test failures either.
    assert_false(Outcome.PASS.is_failing())
    assert_false(Outcome.SKIP.is_failing())
    assert_false(Outcome.FLAKY.is_failing())
    assert_false(Outcome.DESELECTED.is_failing())
    assert_false(Outcome.EXCLUDED.is_failing())
    assert_false(Outcome.NOT_RUN.is_failing())


def test_failing_class_size_is_seven() raises:
    var failing = 0
    for o in _all_outcomes():
        if o.is_failing():
            failing += 1
    assert_equal(failing, 7)
