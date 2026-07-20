"""Pipeline tests for `discover`: dedup, gates, excludes, defaults, and raises.

Each builds a real temp tree, runs `discover`, and asserts the exact result
(run files, gate files, excluded entries, stale patterns) or the exact raise.
Covers explicit-file bypass, operand dedup, gate-overlap promotion, exclusion
(and its win over gates), stale excludes, the default-path rule, and the exit-4
raises for a node id, a nonexistent path, and a root escape.
"""
from std.testing import assert_equal, assert_raises

from mtest.config import RunnerConfig
from mtest.discover import discover

from tmptree import assert_paths, remove_tree, temp_root, touch


def _cfg(
    paths: List[String], excludes: List[String], gates: List[String]
) -> RunnerConfig:
    """A default config with `paths`, `excludes`, and `gates` set."""
    var c = RunnerConfig.default()
    c.paths = paths.copy()
    c.excludes = excludes.copy()
    c.gates = gates.copy()
    return c^


def test_explicit_file_operand_bypasses_pattern() raises:
    var root = temp_root()
    touch(root, "checks/my_checks.mojo")  # not a test_ file
    var result = discover(
        _cfg(["checks/my_checks.mojo"], List[String](), List[String]()), root
    )
    assert_paths(result.run_files, ["checks/my_checks.mojo"])
    remove_tree(root)


def test_overlapping_operands_are_deduplicated() raises:
    var root = temp_root()
    touch(root, "tests/test_a.mojo")
    touch(root, "tests/test_b.mojo")
    var result = discover(
        _cfg(["tests", "tests/test_a.mojo"], List[String](), List[String]()),
        root,
    )
    assert_paths(result.run_files, ["tests/test_a.mojo", "tests/test_b.mojo"])
    remove_tree(root)


def test_gate_overlap_is_promoted_to_gate_only() raises:
    var root = temp_root()
    touch(root, "tests/test_smoke.mojo")
    touch(root, "tests/test_a.mojo")
    var result = discover(
        _cfg(["tests"], List[String](), ["tests/test_smoke.mojo"]), root
    )
    assert_paths(result.gate_files, ["tests/test_smoke.mojo"])
    assert_paths(result.run_files, ["tests/test_a.mojo"])
    remove_tree(root)


def test_exclude_removes_and_records_and_flags_stale() raises:
    var root = temp_root()
    touch(root, "tests/test_a.mojo")
    touch(root, "tests/test_slow_1.mojo")
    var result = discover(
        _cfg(
            ["tests"],
            ["tests/test_slow_*.mojo", "tests/test_missing_*.mojo"],
            List[String](),
        ),
        root,
    )
    assert_paths(result.run_files, ["tests/test_a.mojo"])
    assert_equal(len(result.excluded), 1)
    assert_equal(result.excluded[0].path, "tests/test_slow_1.mojo")
    assert_equal(result.excluded[0].pattern, "tests/test_slow_*.mojo")
    assert_paths(result.stale_excludes, ["tests/test_missing_*.mojo"])
    remove_tree(root)


def test_exclude_wins_over_gate() raises:
    var root = temp_root()
    touch(root, "tests/test_smoke.mojo")
    var result = discover(
        _cfg(
            ["tests"],
            ["tests/test_smoke.mojo"],
            ["tests/test_smoke.mojo"],
        ),
        root,
    )
    assert_equal(len(result.gate_files), 0)
    assert_equal(len(result.run_files), 0)
    assert_equal(len(result.excluded), 1)
    assert_equal(result.excluded[0].path, "tests/test_smoke.mojo")
    remove_tree(root)


def test_default_path_prefers_tests_dir() raises:
    var root = temp_root()
    touch(root, "tests/test_a.mojo")
    touch(root, "test_top.mojo")
    var result = discover(
        _cfg(List[String](), List[String](), List[String]()), root
    )
    assert_paths(result.run_files, ["tests/test_a.mojo"])
    remove_tree(root)


def test_default_path_falls_back_to_root() raises:
    var root = temp_root()
    touch(root, "test_top.mojo")  # no tests/ directory
    var result = discover(
        _cfg(List[String](), List[String](), List[String]()), root
    )
    assert_paths(result.run_files, ["test_top.mojo"])
    remove_tree(root)


def test_empty_walk_is_not_an_error() raises:
    var root = temp_root()
    touch(root, "notes.txt")  # nothing matches test_*.mojo
    var result = discover(_cfg(["."], List[String](), List[String]()), root)
    assert_equal(len(result.run_files), 0)
    remove_tree(root)


def test_node_id_operand_resolves_to_its_file() raises:
    var root = temp_root()
    touch(root, "tests/test_a.mojo")
    var result = discover(
        _cfg(
            ["tests/test_a.mojo::test_foo"],
            List[String](),
            List[String](),
        ),
        root,
    )
    # The node id implies its file; the run set carries that file once.
    assert_equal(len(result.run_files), 1)
    assert_equal(result.run_files[0], "tests/test_a.mojo")
    remove_tree(root)


def test_two_node_ids_same_file_dedup_to_one_file() raises:
    var root = temp_root()
    touch(root, "tests/test_a.mojo")
    var result = discover(
        _cfg(
            ["tests/test_a.mojo::test_foo", "tests/test_a.mojo::test_bar"],
            List[String](),
            List[String](),
        ),
        root,
    )
    assert_equal(len(result.run_files), 1)
    assert_equal(result.run_files[0], "tests/test_a.mojo")
    remove_tree(root)


def test_malformed_node_id_operand_raises() raises:
    var root = temp_root()
    touch(root, "tests/test_a.mojo")
    with assert_raises(contains="malformed node id"):
        _ = discover(
            _cfg(
                ["tests/test_a.mojo::test_foo::extra"],
                List[String](),
                List[String](),
            ),
            root,
        )
    remove_tree(root)


def test_node_id_naming_a_directory_raises() raises:
    # A node id's path must be a FILE. Pointing it at a directory must not
    # silently drop the ::TEST selector and walk the whole tree — it is an
    # exit-4 malformed node id, the same class as the other node-id shape errors.
    var root = temp_root()
    touch(root, "tests/test_a.mojo")
    touch(root, "tests/test_b.mojo")
    with assert_raises(contains="malformed node id"):
        _ = discover(
            _cfg(["tests::test_a"], List[String](), List[String]()),
            root,
        )
    remove_tree(root)


def test_nonexistent_operand_raises() raises:
    var root = temp_root()
    with assert_raises(contains="discover: no such path 'nope/test_x.mojo'"):
        _ = discover(
            _cfg(["nope/test_x.mojo"], List[String](), List[String]()), root
        )
    remove_tree(root)


def test_root_escaping_operand_raises() raises:
    var root = temp_root()
    with assert_raises(contains="escapes the invocation root"):
        _ = discover(_cfg(["../outside"], List[String](), List[String]()), root)
    remove_tree(root)
