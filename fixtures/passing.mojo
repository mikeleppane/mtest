"""Probe fixture: an all-passing suite.

Function order is deliberately NON-alphabetical (zeta, alpha, mid) so the
transcript pins TestSuite's discovery order as a gate — the stdlib registers
tests in source order, and this file is where that fact stops being a memory.
"""
from std.testing import assert_equal, TestSuite


def test_zeta_passes() raises:
    assert_equal(1, 1)


def test_alpha_passes() raises:
    assert_equal(2, 2)


def test_mid_passes() raises:
    assert_equal(3, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
