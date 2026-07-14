"""Tests for `discover`'s lexical, root-relative path normalization.

Pure string work — no filesystem — so this module builds fast. It pins the
fold of `.`/`..`, absolute operands under the root, and the exit-4 raise for an
operand that escapes the invocation root (both a climbing `..` and an outside
absolute path).
"""
from std.testing import assert_equal, assert_raises, TestSuite

from mtest.discover import normalize_operand, normalize_root


def test_relative_operand_is_returned_root_relative() raises:
    assert_equal(
        normalize_operand("tests/test_a.mojo", "/root"), "tests/test_a.mojo"
    )


def test_dot_folds_to_root() raises:
    assert_equal(normalize_operand(".", "/root"), "")
    assert_equal(normalize_operand("./tests", "/root"), "tests")


def test_interior_dotdot_is_folded() raises:
    assert_equal(
        normalize_operand("tests/../tests/test_a.mojo", "/root"),
        "tests/test_a.mojo",
    )


def test_absolute_operand_under_root_is_made_relative() raises:
    assert_equal(
        normalize_operand("/root/tests/test_a.mojo", "/root"),
        "tests/test_a.mojo",
    )
    assert_equal(normalize_operand("/root", "/root"), "")


def test_trailing_slash_on_root_is_tolerated() raises:
    assert_equal(normalize_operand("/root/tests", "/root/"), "tests")


def test_normalize_root_is_idempotent() raises:
    assert_equal(normalize_root("/root/tests"), "/root/tests")
    assert_equal(normalize_root("/root/./tests/"), "/root/tests")


def test_climbing_dotdot_escapes_root_raises() raises:
    with assert_raises(
        contains="discover: operand '../x' escapes the invocation root"
    ):
        _ = normalize_operand("../x", "/root")


def test_outside_absolute_operand_escapes_root_raises() raises:
    with assert_raises(contains="escapes the invocation root"):
        _ = normalize_operand("/elsewhere/test_a.mojo", "/root")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
