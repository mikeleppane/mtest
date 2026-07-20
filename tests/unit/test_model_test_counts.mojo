"""Tests for `TestCounts` (Layer 0): authoritative per-test totals.

Trivial Int fields, closed shape. These tests pin the field names, that
`zeros()` starts every field at zero, and that fields are independently
settable (no cross-field coupling hiding in a synthesized constructor).
"""
from std.testing import assert_equal

from mtest.model import TestCounts


def test_zeros_starts_every_field_at_zero() raises:
    var c = TestCounts.zeros()
    assert_equal(c.passed, 0)
    assert_equal(c.failed, 0)
    assert_equal(c.skipped, 0)
    assert_equal(c.deselected, 0)


def test_fields_are_independently_readable() raises:
    var c = TestCounts(passed=3, failed=1, skipped=2, deselected=4)
    assert_equal(c.passed, 3)
    assert_equal(c.failed, 1)
    assert_equal(c.skipped, 2)
    assert_equal(c.deselected, 4)
