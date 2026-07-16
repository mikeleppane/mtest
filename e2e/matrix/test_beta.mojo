"""Selection-matrix sibling: two more distinctly named tests.

Its role is to sit alongside test_alpha.mojo under e2e/matrix so the
mixed-operand union scenario (`mtest e2e/matrix e2e/matrix/
test_alpha.mojo::test_alpha_one`) proves the directory operand keeps the whole
tree while the node id adds nothing (union -> everything runs).
"""
from std.testing import assert_equal, TestSuite


def test_beta_one() raises:
    assert_equal(1, 1)


def test_beta_two() raises:
    assert_equal(2, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
