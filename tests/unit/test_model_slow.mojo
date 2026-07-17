"""Boundary tests for the pure SLOW threshold policy (Layer 0).

`is_slow` decides whether a file's BUILD or RUN step crossed the 60s SLOW
threshold; `slow_step_label` names WHICH step(s) crossed it, for `-v`. Both are
pure and total over any two non-negative durations. The threshold boundary is
pinned explicitly with synthetic values — 59.9s is never slow, 60.0s always is
— rather than derived from the constant, so a future edit to the constant
cannot silently move the boundary out from under an unchanged test.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.model import is_slow, slow_step_label


def test_below_threshold_build_and_run_is_not_slow() raises:
    assert_false(is_slow(59.9, 59.9))


def test_exactly_at_threshold_build_is_slow() raises:
    assert_true(is_slow(60.0, 0.0))


def test_exactly_at_threshold_run_is_slow() raises:
    assert_true(is_slow(0.0, 60.0))


def test_above_threshold_is_slow() raises:
    assert_true(is_slow(0.0, 61.0))
    assert_true(is_slow(600.0, 0.0))


def test_just_under_threshold_is_not_slow() raises:
    assert_false(is_slow(59.99, 0.0))
    assert_false(is_slow(0.0, 59.99))


def test_slow_build_fast_run_is_slow_and_names_build() raises:
    assert_true(is_slow(65.0, 1.2))
    assert_equal(slow_step_label(65.0, 1.2), "build")


def test_slow_run_fast_build_is_slow_and_names_run() raises:
    assert_true(is_slow(1.0, 90.0))
    assert_equal(slow_step_label(1.0, 90.0), "run")


def test_both_slow_names_both() raises:
    assert_true(is_slow(70.0, 80.0))
    assert_equal(slow_step_label(70.0, 80.0), "build and run")


def test_neither_slow_has_no_label() raises:
    assert_false(is_slow(1.0, 2.0))
    assert_equal(slow_step_label(1.0, 2.0), "")


def test_zero_durations_are_not_slow() raises:
    # Genuinely-absent durations (e.g. a file that never reached the run step)
    # must never read as slow.
    assert_false(is_slow(0.0, 0.0))
    assert_equal(slow_step_label(0.0, 0.0), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
