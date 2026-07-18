"""Known-outcome fixture: twelve failing tests in ONE file.

Verdict FAIL, exit-class 1. Twelve per-test failures produce twelve `::error`
annotation rows, which exceed the 10-error per-STEP cap: the tail keeps the first
nine node-id-sorted rows and collapses the rest into ONE `... and 3 more errors`
aggregate line, so the block never exceeds ten lines. Reached only by the
`annotations-caps` e2e cell — never in the default suite.
"""
from std.testing import assert_equal, TestSuite


def test_fail_01() raises:
    assert_equal(1, 2)


def test_fail_02() raises:
    assert_equal(1, 2)


def test_fail_03() raises:
    assert_equal(1, 2)


def test_fail_04() raises:
    assert_equal(1, 2)


def test_fail_05() raises:
    assert_equal(1, 2)


def test_fail_06() raises:
    assert_equal(1, 2)


def test_fail_07() raises:
    assert_equal(1, 2)


def test_fail_08() raises:
    assert_equal(1, 2)


def test_fail_09() raises:
    assert_equal(1, 2)


def test_fail_10() raises:
    assert_equal(1, 2)


def test_fail_11() raises:
    assert_equal(1, 2)


def test_fail_12() raises:
    assert_equal(1, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
