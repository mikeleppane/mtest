"""Filesystem tests for `discover`'s recursive walk.

Each test builds a real temp tree, runs `discover` against it as the root, and
asserts the exact sorted `run_files` list before tearing the tree down. Covers
the `test_*.mojo` pattern, per-directory sort order, and symlinked-directory
non-traversal.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.config import RunnerConfig
from mtest.discover import discover

from tmptree import (
    assert_paths,
    link_broken,
    link_dir,
    remove_tree,
    temp_root,
    touch,
)


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


def test_symlinked_test_file_is_discovered() raises:
    """A symlinked test file is a REAL selection, not a thing to drop silently.

    Symlinking a shared suite into a project is an ordinary layout. Skipping
    the link produced a green run over the wrong set — the summary read
    `0 excluded, 0 not run` while the linked file never ran. A symlinked FILE
    cannot create a walk cycle, so nothing about cycle safety justified it.
    """
    var root = temp_root()
    touch(root, "real/test_alpha.mojo")
    touch(root, "tests/test_plain.mojo")
    link_dir(root, "real/test_alpha.mojo", "tests/test_linked.mojo")
    var result = discover(_config_paths(["tests"]), root)
    assert_paths(
        result.run_files, ["tests/test_linked.mojo", "tests/test_plain.mojo"]
    )
    remove_tree(root)


def test_symlinked_file_not_matching_the_glob_is_ignored() raises:
    """The `test_*.mojo` gate applies to a link exactly as to a real file."""
    var root = temp_root()
    touch(root, "real/helper.mojo")
    touch(root, "tests/test_plain.mojo")
    link_dir(root, "real/helper.mojo", "tests/helper.mojo")
    var result = discover(_config_paths(["tests"]), root)
    assert_paths(result.run_files, ["tests/test_plain.mojo"])
    remove_tree(root)


def test_broken_symlink_is_reported_not_silently_dropped() raises:
    """A dangling `test_*.mojo` link is unusable, so it must be LOUD.

    This is the shape a moved or deleted link target leaves behind; the file
    the user believes is running has quietly stopped existing.
    """
    var root = temp_root()
    touch(root, "tests/test_plain.mojo")
    link_broken(root, "tests/test_gone.mojo")
    var result = discover(_config_paths(["tests"]), root)
    assert_paths(result.run_files, ["tests/test_plain.mojo"])
    assert_paths(result.skipped_links, ["tests/test_gone.mojo"])
    remove_tree(root)


def test_symlinked_directory_skip_is_reported() raises:
    """Cycle safety keeps the skip, but the skip stops being silent."""
    var root = temp_root()
    touch(root, "real/test_inside.mojo")
    link_dir(root, "real", "linked")
    var result = discover(_config_paths(["."]), root)
    assert_paths(result.run_files, ["real/test_inside.mojo"])
    assert_paths(result.skipped_links, ["linked"])
    remove_tree(root)


def test_clean_walk_reports_no_skipped_links() raises:
    """No link, no warning: the channel stays quiet on an ordinary tree."""
    var root = temp_root()
    touch(root, "tests/test_a.mojo")
    var result = discover(_config_paths(["tests"]), root)
    assert_equal(len(result.skipped_links), 0)
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
