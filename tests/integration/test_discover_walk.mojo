"""Filesystem tests for `discover`'s recursive walk.

Each test builds a real temp tree, runs `discover` against it as the root, and
asserts the exact sorted `run_files` list before tearing the tree down. Covers
the `test_*.mojo` pattern, per-directory sort order, and symlinked-directory
non-traversal.
"""
from std.testing import assert_equal, assert_false

from mtest.config import RunnerConfig
from mtest.discover import discover

from tmptree import assert_paths, link_dir, remove_tree, temp_root, touch


def _config_paths(paths: List[String]) -> RunnerConfig:
    """A default config with `paths` set (everything else at its default)."""
    var c = RunnerConfig.default()
    c.paths = paths.copy()
    return c^


def test_only_test_star_mojo_is_discovered() raises:
    var root = temp_root()
    touch(root, "test_a.mojo")
    touch(root, "helper.mojo")
    touch(root, "test_b.mojo")
    touch(root, "notes.txt")
    var result = discover(_config_paths(["."]), root)
    assert_paths(result.run_files, ["test_a.mojo", "test_b.mojo"])
    remove_tree(root)


def test_recursive_walk_is_sorted() raises:
    var root = temp_root()
    # Created in deliberately non-alphabetical order.
    touch(root, "zeta/test_z.mojo")
    touch(root, "test_top.mojo")
    touch(root, "alpha/test_a.mojo")
    touch(root, "alpha/sub/test_deep.mojo")
    var result = discover(_config_paths(["."]), root)
    assert_paths(
        result.run_files,
        [
            "alpha/sub/test_deep.mojo",
            "alpha/test_a.mojo",
            "test_top.mojo",
            "zeta/test_z.mojo",
        ],
    )
    remove_tree(root)


def test_symlinked_directory_is_not_traversed() raises:
    var root = temp_root()
    touch(root, "real/test_inside.mojo")
    link_dir(root, "real", "linked")
    var result = discover(_config_paths(["."]), root)
    # The real directory is walked; the symlink to it is never descended.
    assert_paths(result.run_files, ["real/test_inside.mojo"])
    for f in result.run_files:
        assert_false(f == "linked/test_inside.mojo")
    remove_tree(root)


def test_nested_directory_operand_is_walked() raises:
    var root = temp_root()
    touch(root, "tests/a/test_a.mojo")
    touch(root, "tests/b/test_b.mojo")
    touch(root, "other/test_c.mojo")
    var result = discover(_config_paths(["tests"]), root)
    assert_paths(
        result.run_files, ["tests/a/test_a.mojo", "tests/b/test_b.mojo"]
    )
    remove_tree(root)
