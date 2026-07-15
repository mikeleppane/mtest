"""Stage 3 of selection: universe + intent + `-k` -> selected/deselected.

`select_from` is pure and exhaustively table-tested here: a whole file keeps its
whole universe; an explicit name-set keeps only those names; `-k` intersects the
base with a case-insensitive substring over the whole `rel::name`; an explicit
name absent from the universe raises the exit-4 unknown-test error. `selected`
and `deselected` partition the universe and preserve its order.
"""
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)

from mtest.select import FileIntent, contains_ci, select_from


def _u(a: String, b: String, c: String) -> List[String]:
    var xs = List[String]()
    xs.append(a)
    xs.append(b)
    xs.append(c)
    return xs^


def _names(a: String, b: String) -> List[String]:
    var xs = List[String]()
    xs.append(a)
    xs.append(b)
    return xs^


def test_whole_file_selects_the_whole_universe() raises:
    var u = _u("test_a", "test_b", "test_c")
    var r = select_from(u, "f.mojo", FileIntent.whole_file(), "")
    assert_equal(len(r.selected), 3)
    assert_equal(len(r.deselected), 0)
    # Universe order preserved.
    assert_equal(r.selected[0], "test_a")
    assert_equal(r.selected[2], "test_c")


def test_named_subset_selects_only_those_names() raises:
    var u = _u("test_a", "test_b", "test_c")
    var r = select_from(
        u, "f.mojo", FileIntent.named(_names("test_c", "test_a")), ""
    )
    # Selected preserves UNIVERSE order (a before c), not operand order.
    assert_equal(len(r.selected), 2)
    assert_equal(r.selected[0], "test_a")
    assert_equal(r.selected[1], "test_c")
    assert_equal(len(r.deselected), 1)
    assert_equal(r.deselected[0], "test_b")


def test_named_selecting_none_leaves_empty_selection() raises:
    var u = _u("test_a", "test_b", "test_c")
    var one = List[String]()
    one.append("test_b")
    var r = select_from(u, "f.mojo", FileIntent.named(one^), "")
    assert_equal(len(r.selected), 1)
    assert_equal(len(r.deselected), 2)


def test_keyword_intersects_a_whole_file() raises:
    var u = _u("test_add", "test_sub", "test_addmul")
    var r = select_from(u, "f.mojo", FileIntent.whole_file(), "add")
    assert_equal(len(r.selected), 2)
    assert_equal(r.selected[0], "test_add")
    assert_equal(r.selected[1], "test_addmul")
    assert_equal(len(r.deselected), 1)
    assert_equal(r.deselected[0], "test_sub")


def test_keyword_is_case_insensitive() raises:
    var u = _u("test_Add", "test_sub", "test_MUL")
    var r = select_from(u, "f.mojo", FileIntent.whole_file(), "mul")
    assert_equal(len(r.selected), 1)
    assert_equal(r.selected[0], "test_MUL")


def test_keyword_matches_over_the_whole_rel_scope() raises:
    # The keyword scope is the whole `rel::name`, so the path participates.
    var u = _u("test_a", "test_b", "test_c")
    var r = select_from(u, "tests/math/f.mojo", FileIntent.whole_file(), "math")
    assert_equal(len(r.selected), 3)


def test_keyword_narrows_a_named_subset_further() raises:
    var u = _u("test_add", "test_sub", "test_mul")
    var r = select_from(
        u, "f.mojo", FileIntent.named(_names("test_add", "test_sub")), "add"
    )
    assert_equal(len(r.selected), 1)
    assert_equal(r.selected[0], "test_add")
    assert_equal(len(r.deselected), 2)


def test_unknown_named_test_raises_unknown_test() raises:
    var u = _u("test_a", "test_b", "test_c")
    var bad = List[String]()
    bad.append("test_nope")
    with assert_raises(contains="unknown test"):
        _ = select_from(u, "f.mojo", FileIntent.named(bad^), "")


def test_unknown_test_error_names_the_node_id() raises:
    var u = _u("test_a", "test_b", "test_c")
    var bad = List[String]()
    bad.append("test_nope")
    var saw = String("")
    try:
        _ = select_from(u, "f.mojo", FileIntent.named(bad^), "")
    except e:
        saw = String(e)
    assert_true("f.mojo::test_nope" in saw)


def test_contains_ci_basic() raises:
    assert_true(contains_ci("test_ADD", "add"))
    assert_true(contains_ci("test_add", "ADD"))
    assert_false(contains_ci("test_add", "sub"))
    assert_true(contains_ci("anything", ""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
