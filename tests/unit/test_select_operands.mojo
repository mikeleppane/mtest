"""Stage 1 of selection: parsing raw operands into per-invocation intent.

`parse_operands` is pure: a plain operand becomes a whole-file operand, a single
`::` becomes a node-id target (file_part, name), and more than one `::` is a
MALFORMED node id that raises an exit-4 usage error naming the bad token and the
phrase "malformed node id" — never "unknown test". `selection_active` decides
whether the pipeline engages at all.
"""
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
)

from mtest.select import parse_operands, selection_active


def test_plain_operands_carry_no_node_id() raises:
    var ops: List[String] = ["tests/", "tests/test_a.mojo"]
    var p = parse_operands(ops)
    assert_false(p.has_node_id)
    assert_equal(len(p.plain_operands), 2)
    assert_equal(len(p.named_targets), 0)
    assert_equal(p.plain_operands[0], "tests/")
    assert_equal(p.plain_operands[1], "tests/test_a.mojo")


def test_single_node_id_splits_file_and_name() raises:
    var ops: List[String] = ["tests/test_a.mojo::test_foo"]
    var p = parse_operands(ops)
    assert_true(p.has_node_id)
    assert_equal(len(p.plain_operands), 0)
    assert_equal(len(p.named_targets), 1)
    assert_equal(p.named_targets[0].file_part, "tests/test_a.mojo")
    assert_equal(p.named_targets[0].name, "test_foo")


def test_mixed_plain_and_node_id_operands() raises:
    var ops: List[String] = ["tests/", "tests/test_a.mojo::test_foo"]
    var p = parse_operands(ops)
    assert_true(p.has_node_id)
    assert_equal(len(p.plain_operands), 1)
    assert_equal(p.plain_operands[0], "tests/")
    assert_equal(len(p.named_targets), 1)


def test_two_named_targets_same_file() raises:
    var ops: List[String] = [
        "t/a.mojo::test_one",
        "t/a.mojo::test_two",
    ]
    var p = parse_operands(ops)
    assert_equal(len(p.named_targets), 2)
    assert_equal(p.named_targets[0].name, "test_one")
    assert_equal(p.named_targets[1].name, "test_two")


def test_more_than_one_separator_is_malformed_node_id() raises:
    var ops: List[String] = ["a.mojo::test::extra"]
    with assert_raises(contains="malformed node id"):
        _ = parse_operands(ops)


def test_malformed_node_id_never_says_unknown_test() raises:
    var ops: List[String] = ["a.mojo::b::c::d"]
    var saw = String("")
    try:
        _ = parse_operands(ops)
    except e:
        saw = String(e)
    assert_true("malformed node id" in saw)
    assert_false("unknown test" in saw)


def test_selection_active_by_keyword() raises:
    var ops = List[String]()
    assert_true(selection_active(ops, "test_add"))


def test_selection_active_by_node_id() raises:
    var ops: List[String] = ["tests/test_a.mojo::test_foo"]
    assert_true(selection_active(ops, ""))


def test_selection_inactive_for_plain_operands_no_keyword() raises:
    var ops: List[String] = ["tests/", "tests/test_a.mojo"]
    assert_false(selection_active(ops, ""))
