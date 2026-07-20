"""Tests for the `discover` fnmatch-style glob matcher.

The matcher is its own focused unit: `*` (which crosses `/`), `?`, `[...]`
classes with ranges and negation, exact-equality of a metacharacter-free
pattern, and non-matches. Kept in its own module (no filesystem) so it builds
fast and stays clear of the temp-tree tests.
"""
from std.testing import assert_false, assert_true

from mtest.discover import fnmatch


def test_exact_equality_no_metacharacters() raises:
    assert_true(fnmatch("tests/test_a.mojo", "tests/test_a.mojo"))
    assert_false(fnmatch("tests/test_a.mojo", "tests/test_b.mojo"))


def test_star_matches_any_run() raises:
    assert_true(fnmatch("test_addition.mojo", "test_*.mojo"))
    assert_true(fnmatch("test_.mojo", "test_*.mojo"))
    assert_false(fnmatch("helper.mojo", "test_*.mojo"))


def test_star_crosses_slash() raises:
    # Documented: fnmatch '*' crosses '/', so a whole-path glob spans dirs.
    assert_true(fnmatch("tests/sub/test_slow.mojo", "tests/*slow*"))
    assert_true(fnmatch("tests/a/b/test_x.mojo", "*"))
    assert_true(fnmatch("tests/deep/nested/test_x.mojo", "tests/*.mojo"))


def test_question_matches_one_char() raises:
    assert_true(fnmatch("test_a.mojo", "test_?.mojo"))
    assert_false(fnmatch("test_ab.mojo", "test_?.mojo"))
    assert_false(fnmatch("test_.mojo", "test_?.mojo"))


def test_char_class_membership() raises:
    assert_true(fnmatch("test_a.mojo", "test_[abc].mojo"))
    assert_true(fnmatch("test_c.mojo", "test_[abc].mojo"))
    assert_false(fnmatch("test_d.mojo", "test_[abc].mojo"))


def test_char_class_range() raises:
    assert_true(fnmatch("test_5.mojo", "test_[0-9].mojo"))
    assert_false(fnmatch("test_x.mojo", "test_[0-9].mojo"))


def test_char_class_negation() raises:
    assert_true(fnmatch("test_x.mojo", "test_[!0-9].mojo"))
    assert_false(fnmatch("test_7.mojo", "test_[!0-9].mojo"))


def test_star_and_class_combined() raises:
    assert_true(fnmatch("tests/test_slow_01.mojo", "tests/test_slow_*.mojo"))
    assert_false(fnmatch("tests/test_fast_01.mojo", "tests/test_slow_*.mojo"))
