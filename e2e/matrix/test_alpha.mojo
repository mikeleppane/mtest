"""Selection-matrix fixture: three distinctly named tests in one file.

Not in the default suite. Reached only by the selection scenarios, which prove
`-k` keyword filtering and node-id / `--only` selection against distinct names:
`-k one` selects the two `_one` tests, a node id selects exactly one, and the
mixed-operand union (dir + a node id under it) keeps the whole file.
"""
from std.testing import assert_equal, TestSuite


def test_alpha_one() raises:
    assert_equal(1, 1)


def test_alpha_two() raises:
    assert_equal(2, 2)


def test_alpha_three() raises:
    assert_equal(3, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
