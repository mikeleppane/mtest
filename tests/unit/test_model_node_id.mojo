"""Tests for NodeId (lexical file::name identity) and the raw token splitter.

NodeId's identity is BOTH path and name -- a real regression here would compare
only one field and silently merge two distinct tests. `split_node_token` is
pure and policy-free: these tests pin its behavior across every separator count
the session's classifier depends on (0/1/2/3, plus the empty-part edges).

`split_rendered_node_id` is the inverse of `render()` and splits at the LAST
separator instead, because a test NAME can never contain one while the text
before it is whatever the producer put there. Discovery refuses a path carrying
the separator (§5), so an id this runner emits holds exactly one and the two
splitters agree on it; the round-trip cases below pin the function on the
harder inputs anyway, since it is the inverse of `render()` for any id and not
only for the ones this build can produce.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.model import (
    NodeId,
    NodeIdSplit,
    split_node_token,
    split_rendered_node_id,
)


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


def test_rendered_split_recovers_an_ordinary_node_id() raises:
    var n = split_rendered_node_id("tests/test_a.mojo::test_foo")
    assert_equal(n.path, "tests/test_a.mojo")
    assert_equal(n.name, "test_foo")


def test_rendered_split_keeps_a_path_that_contains_the_separator() raises:
    # The defect this pins: splitting at the FIRST `::` reports the path as
    # `we` and folds the rest of the path into the test name.
    var n = split_rendered_node_id("we::ird/test_x.mojo::test_x_one")
    assert_equal(n.path, "we::ird/test_x.mojo")
    assert_equal(n.name, "test_x_one")


def test_rendered_split_round_trips_every_render() raises:
    for path in [
        "tests/test_a.mojo",
        "we::ird/test_x.mojo",
        "::/test_y.mojo",
        "a::b::c/test_z.mojo",
    ]:
        var original = NodeId(path, "test_one")
        var recovered = split_rendered_node_id(original.render())
        assert_true(recovered == original, "round-trip drift for path: " + path)


def test_rendered_split_of_a_bare_path_leaves_the_name_empty() raises:
    var n = split_rendered_node_id("tests/test_a.mojo")
    assert_equal(n.path, "tests/test_a.mojo")
    assert_equal(n.name, "")


def test_rendered_split_trailing_separator_yields_empty_name() raises:
    var n = split_rendered_node_id("a::")
    assert_equal(n.path, "a")
    assert_equal(n.name, "")


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
