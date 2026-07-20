"""Tests for `TestResult` (Layer 0): one test's node, outcome, and raw detail.

`TestResult` is the per-test record the protocol layer will emit and the
console will later render. `detail` and `timing` are stored VERBATIM -- these
tests pin that nothing here interprets or reformats them -- and the
convenience two-arg constructor must leave both empty.
"""
from std.testing import assert_equal, assert_true

from mtest.model import NodeId, Outcome, TestResult


def test_fieldwise_constructor_carries_every_field() raises:
    var n = NodeId("tests/test_a.mojo", "test_foo")
    var r = TestResult(
        n.copy(), Outcome.FAIL, "AssertionError: 1 != 2", "[ 0.004 ]"
    )
    assert_true(r.node == n)
    assert_true(r.outcome == Outcome.FAIL)
    assert_equal(r.detail, "AssertionError: 1 != 2")
    assert_equal(r.timing, "[ 0.004 ]")


def test_two_arg_constructor_leaves_detail_and_timing_empty() raises:
    var n = NodeId("tests/test_a.mojo", "test_foo")
    var r = TestResult(n.copy(), Outcome.PASS)
    assert_true(r.node == n)
    assert_true(r.outcome == Outcome.PASS)
    assert_equal(r.detail, "")
    assert_equal(r.timing, "")


def test_copy_is_independent_and_equal_in_value() raises:
    var n = NodeId("tests/test_a.mojo", "test_foo")
    var r = TestResult(n.copy(), Outcome.SKIP, "", "")
    var c = r.copy()
    assert_true(c.node == r.node)
    assert_true(c.outcome == r.outcome)
    assert_equal(c.detail, r.detail)
