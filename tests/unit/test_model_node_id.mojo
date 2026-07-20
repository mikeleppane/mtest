"""Tests for NodeId (lexical file::name identity) and the raw token splitter.

NodeId's identity is BOTH path and name -- a real regression here would compare
only one field and silently merge two distinct tests. `split_node_token` is
pure and policy-free: these tests pin its behavior across every separator count
the session's classifier depends on (0/1/2/3, plus the empty-part edges).
"""
from std.testing import assert_equal, assert_true, assert_false

from mtest.model import NodeId, NodeIdSplit, split_node_token


def test_render_joins_path_and_name_with_double_colon() raises:
    var n = NodeId("tests/test_a.mojo", "test_foo")
    assert_equal(n.render(), "tests/test_a.mojo::test_foo")


def test_eq_requires_both_path_and_name_to_match() raises:
    var a = NodeId("tests/test_a.mojo", "test_foo")
    var b = NodeId("tests/test_a.mojo", "test_foo")
    assert_true(a == b)
    assert_false(a != b)


def test_eq_false_when_only_name_matches() raises:
    var a = NodeId("tests/test_a.mojo", "test_foo")
    var b = NodeId("tests/test_b.mojo", "test_foo")
    assert_false(a == b)
    assert_true(a != b)


def test_eq_false_when_only_path_matches() raises:
    var a = NodeId("tests/test_a.mojo", "test_foo")
    var b = NodeId("tests/test_a.mojo", "test_bar")
    assert_false(a == b)
    assert_true(a != b)


def test_split_zero_separators_is_the_whole_token() raises:
    var s = split_node_token("tests/test_a.mojo")
    assert_equal(s.sep_count, 0)
    assert_equal(s.file_part, "tests/test_a.mojo")
    assert_equal(s.name_part, "")


def test_split_one_separator() raises:
    var s = split_node_token("tests/test_a.mojo::test_foo")
    assert_equal(s.sep_count, 1)
    assert_equal(s.file_part, "tests/test_a.mojo")
    assert_equal(s.name_part, "test_foo")


def test_split_two_separators_splits_only_at_the_first() raises:
    var s = split_node_token("a::b::c")
    assert_equal(s.sep_count, 2)
    assert_equal(s.file_part, "a")
    assert_equal(s.name_part, "b::c")


def test_split_three_separators() raises:
    var s = split_node_token("a::b::c::d")
    assert_equal(s.sep_count, 3)
    assert_equal(s.file_part, "a")
    assert_equal(s.name_part, "b::c::d")


def test_split_leading_separator_yields_empty_file_part() raises:
    var s = split_node_token("::x")
    assert_equal(s.sep_count, 1)
    assert_equal(s.file_part, "")
    assert_equal(s.name_part, "x")


def test_split_trailing_separator_yields_empty_name_part() raises:
    var s = split_node_token("a::")
    assert_equal(s.sep_count, 1)
    assert_equal(s.file_part, "a")
    assert_equal(s.name_part, "")
