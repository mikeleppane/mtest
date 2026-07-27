"""Pure last-failed filtering and failed-first admission-order tests."""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import LastRunRecord, LastRunState
from mtest.model import NodeId
from mtest.select.failure_selection import (
    CollectedNames,
    order_failed_first,
    remembered_file_matches,
    resolve_last_failed,
)


def _file(path: String) -> LastRunRecord:
    return LastRunRecord.file(path)


def _test(path: String, name: String) -> LastRunRecord:
    return LastRunRecord.test(NodeId(path, name))


def _collected(path: String, var names: List[String]) -> CollectedNames:
    var selected = names.copy()
    return CollectedNames(path, names^, selected^)


def _selected(
    path: String, var names: List[String], var selected: List[String]
) -> CollectedNames:
    return CollectedNames(path, names^, selected^)


def test_file_record_selects_the_discovered_file() raises:
    var files: List[String] = ["tests/a.mojo", "tests/b.mojo"]
    var names = [
        _collected("tests/a.mojo", ["test_a"]),
        _collected("tests/b.mojo", ["test_b"]),
    ]
    var state = LastRunState([_file("tests/b.mojo")])
    var selected = resolve_last_failed(files, names, state)
    assert_true(selected.matched)
    assert_equal(len(selected.files), 1)
    assert_equal(selected.files[0].path, "tests/b.mojo")
    assert_true(selected.files[0].whole_file)


def test_test_record_selects_only_a_live_collected_name() raises:
    var files: List[String] = ["tests/a.mojo"]
    var names = [_collected("tests/a.mojo", ["test_a", "test_b"])]
    var state = LastRunState([_test("tests/a.mojo", "test_b")])
    var selected = resolve_last_failed(files, names, state)
    assert_true(selected.matched)
    assert_false(selected.files[0].whole_file)
    assert_equal(len(selected.files[0].names), 1)
    assert_equal(selected.files[0].names[0], "test_b")


def test_missing_file_and_missing_test_drop_loudly_without_raising() raises:
    var files: List[String] = ["tests/a.mojo"]
    var names = [_collected("tests/a.mojo", ["test_live"])]
    var state = LastRunState(
        [
            _file("tests/gone.mojo"),
            _test("tests/a.mojo", "test_gone"),
            _test("tests/a.mojo", "test_live"),
        ]
    )
    var selected = resolve_last_failed(files, names, state)
    assert_true(selected.matched)
    assert_equal(len(selected.stale_ids), 2)
    assert_equal(selected.stale_ids[0], "tests/gone.mojo")
    assert_equal(selected.stale_ids[1], "tests/a.mojo::test_gone")
    assert_equal(selected.files[0].names[0], "test_live")


def test_empty_and_all_stale_state_fall_back() raises:
    var files: List[String] = ["tests/a.mojo"]
    var names = [_collected("tests/a.mojo", ["test_a"])]
    var empty = resolve_last_failed(files, names, LastRunState.empty())
    assert_false(empty.matched)
    assert_equal(len(empty.stale_ids), 0)
    var stale = resolve_last_failed(
        files, names, LastRunState([_test("tests/a.mojo", "gone")])
    )
    assert_false(stale.matched)
    assert_equal(len(stale.stale_ids), 1)


def test_gate_records_are_live_not_stale() raises:
    """A record naming a gate file must never be reported as gone.

    Discovery keeps gate files out of the ordinary run set, so a gate record
    looked exactly like a deleted file: a failing gate wrote the record, and
    the next --lf run announced that the gate no longer existed on the line
    after the gate itself passed.
    """
    var files: List[String] = ["tests/a.mojo"]
    var gates: List[String] = ["tests/test_smoke.mojo"]
    var names = [_collected("tests/a.mojo", ["test_a"])]
    var by_file = resolve_last_failed(
        files, names, LastRunState([_file("tests/test_smoke.mojo")]), gates
    )
    assert_equal(len(by_file.stale_ids), 0)
    # No run file is selected, but the record IS live: reporting `matched`
    # alone as false made the caller announce that nothing matched and re-run
    # the whole suite, for a state file that was entirely current.
    assert_false(by_file.matched)
    assert_true(by_file.gate_matched)

    var by_test = resolve_last_failed(
        files,
        names,
        LastRunState([_test("tests/test_smoke.mojo", "test_smoke")]),
        gates,
    )
    assert_equal(len(by_test.stale_ids), 0)
    assert_false(by_test.matched)
    assert_true(by_test.gate_matched)

    # A genuinely absent file is still stale when gates are present.
    var gone = resolve_last_failed(
        files, names, LastRunState([_file("tests/gone.mojo")]), gates
    )
    assert_equal(len(gone.stale_ids), 1)
    assert_equal(gone.stale_ids[0], "tests/gone.mojo")
    assert_false(gone.gate_matched)


def test_live_test_outside_ordinary_selection_is_not_stale() raises:
    var files: List[String] = ["tests/a.mojo"]
    var names = [_selected("tests/a.mojo", ["test_a", "test_b"], ["test_b"])]
    var state = LastRunState([_test("tests/a.mojo", "test_a")])
    var selected = resolve_last_failed(files, names, state)
    assert_false(selected.matched)
    assert_equal(len(selected.stale_ids), 0)


def test_last_failed_preserves_discovery_and_collection_order() raises:
    var files: List[String] = [
        "tests/a.mojo",
        "tests/b.mojo",
        "tests/c.mojo",
    ]
    var names = [
        _collected("tests/a.mojo", ["test_a", "test_b"]),
        _collected("tests/b.mojo", ["test_b"]),
        _collected("tests/c.mojo", ["test_c"]),
    ]
    var state = LastRunState(
        [
            _test("tests/c.mojo", "test_c"),
            _test("tests/a.mojo", "test_b"),
            _file("tests/b.mojo"),
            _test("tests/a.mojo", "test_a"),
        ]
    )
    var selected = resolve_last_failed(files, names, state)
    assert_equal(selected.files[0].path, "tests/a.mojo")
    assert_equal(selected.files[0].names[0], "test_a")
    assert_equal(selected.files[0].names[1], "test_b")
    assert_equal(selected.files[1].path, "tests/b.mojo")
    assert_equal(selected.files[2].path, "tests/c.mojo")


def test_hostile_stale_identifier_is_one_safe_physical_line() raises:
    var files: List[String] = ["tests/a.mojo"]
    var names = [_collected("tests/a.mojo", ["test_a"])]
    var state = LastRunState(
        [_file("gone\nforged\t\x1b\u0085\u2028\u2029.mojo")]
    )
    var selected = resolve_last_failed(files, names, state)
    assert_equal(len(selected.stale_ids), 1)
    assert_false("\n" in selected.stale_ids[0])
    assert_false("\t" in selected.stale_ids[0])
    assert_false("\x1b" in selected.stale_ids[0])
    assert_false("\u0085" in selected.stale_ids[0])
    assert_false("\u2028" in selected.stale_ids[0])
    assert_false("\u2029" in selected.stale_ids[0])
    assert_true("\\n" in selected.stale_ids[0])
    assert_true("\\x85" in selected.stale_ids[0])
    assert_true("\\u2028" in selected.stale_ids[0])
    assert_true("\\u2029" in selected.stale_ids[0])


def test_failed_first_reorders_each_band_stably_and_leaves_gates() raises:
    var gates: List[String] = ["gate/z.mojo", "gate/a.mojo"]
    var parallel: List[String] = ["p/a.mojo", "p/b.mojo", "p/c.mojo"]
    var serial: List[String] = ["s/a.mojo", "s/b.mojo", "s/c.mojo"]
    var state = LastRunState(
        [
            _test("p/c.mojo", "test_c"),
            _file("p/a.mojo"),
            _file("s/b.mojo"),
        ]
    )
    var ordered = order_failed_first(gates, parallel, serial, state)
    assert_equal(ordered.gates[0], "gate/z.mojo")
    assert_equal(ordered.gates[1], "gate/a.mojo")
    assert_equal(ordered.parallel[0], "p/a.mojo")
    assert_equal(ordered.parallel[1], "p/c.mojo")
    assert_equal(ordered.parallel[2], "p/b.mojo")
    assert_equal(ordered.serial[0], "s/b.mojo")
    assert_equal(ordered.serial[1], "s/a.mojo")
    assert_equal(ordered.serial[2], "s/c.mojo")


def test_failed_first_recognizes_a_remembered_gate_as_live() raises:
    var all_discovered: List[String] = [
        "g/failing.mojo",
        "tests/passing.mojo",
    ]
    var state = LastRunState([_test("g/failing.mojo", "test_gate")])
    assert_true(remembered_file_matches(all_discovered, state))


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
