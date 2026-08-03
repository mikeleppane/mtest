"""Filesystem tests for `discover`'s recursive walk.

Each test builds a real temp tree, runs `discover` against it as the root, and
asserts the exact sorted `run_files` list before tearing the tree down. Covers
the `test_*.mojo` pattern, per-directory sort order, symlinks by kind, the loud
channel carrying test-named entries that are not runnable files, the refusal of
a tree that cannot be characterized, and the dedup-and-sort discipline both
loud channels share.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import RunnerConfig
from mtest.discover import discover
from mtest.platform import set_permissions

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
    assert_equal(len(result.skipped_nonregular), 0)
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


def test_a_test_named_directory_is_skipped_not_descended() raises:
    """A DIRECTORY named like a test file is an accident, never a suite.

    Descending it silently changed the selected set: tests ran from under a
    name no tool treats as a container, or an empty one shrank the run with
    no trace. The honest move is a loud per-entry skip, exactly as a
    refused symlink gets.
    """
    var root = temp_root()
    touch(root, "tests/test_plain.mojo")
    # `touch` creates parents, so this creates a directory named like a
    # test file with a real test inside — the walk must skip the whole
    # entry, not harvest its contents.
    touch(root, "tests/test_shape.mojo/test_inside.mojo")
    var result = discover(_config_paths(["tests"]), root)
    assert_paths(result.run_files, ["tests/test_plain.mojo"])
    assert_paths(result.skipped_nonregular, ["tests/test_shape.mojo"])
    remove_tree(root)


def test_a_non_test_named_directory_is_still_descended() raises:
    """The name gate applies to the entry, never to ordinary traversal."""
    var root = temp_root()
    touch(root, "tests/helpers/test_deep.mojo")
    var result = discover(_config_paths(["tests"]), root)
    assert_paths(result.run_files, ["tests/helpers/test_deep.mojo"])
    assert_equal(len(result.skipped_nonregular), 0)
    remove_tree(root)


def test_an_explicit_test_named_directory_operand_is_walked() raises:
    """Naming a directory selects its contents, whatever it is called."""
    var root = temp_root()
    touch(root, "tests/test_shape.mojo/test_inside.mojo")
    var result = discover(_config_paths(["tests/test_shape.mojo"]), root)
    assert_paths(result.run_files, ["tests/test_shape.mojo/test_inside.mojo"])
    assert_equal(len(result.skipped_nonregular), 0)
    remove_tree(root)


def test_an_excluded_nonregular_path_still_warns() raises:
    """Exclusion filters the runnable set, not the tree's honesty.

    The pattern also counts stale: it matched no discovered regular file.
    Both channels stay loud, exactly as an excluded refused symlink does.
    """
    var root = temp_root()
    touch(root, "tests/test_plain.mojo")
    touch(root, "tests/test_shape.mojo/test_inside.mojo")
    var cfg = _config_paths(["tests"])
    cfg.excludes.append("tests/test_shape.mojo")
    var result = discover(cfg, root)
    assert_paths(result.run_files, ["tests/test_plain.mojo"])
    assert_paths(result.skipped_nonregular, ["tests/test_shape.mojo"])
    assert_paths(result.stale_excludes, ["tests/test_shape.mojo"])
    remove_tree(root)


def test_a_test_named_link_whose_target_is_unreachable_is_loud() raises:
    """A link mtest cannot resolve still names itself, whatever the cause.

    Target typing follows the link, and a target inside a directory this
    process may read but not search is indistinguishable from one that was
    deleted: both resolve to nothing. A `test_*.mojo` link is reported either
    way, so the selection the user believes is running never goes quiet.
    """
    var root = temp_root()
    touch(root, "tests/test_plain.mojo")
    touch(root, "blocked/inner/test_target.mojo")
    link_dir(root, "blocked/inner/test_target.mojo", "tests/test_linked.mojo")
    set_permissions(root + "/blocked", 0o644)
    var result = discover(_config_paths(["tests"]), root)
    set_permissions(root + "/blocked", 0o755)
    assert_paths(result.run_files, ["tests/test_plain.mojo"])
    assert_paths(result.skipped_links, ["tests/test_linked.mojo"])
    assert_equal(len(result.skipped_nonregular), 0)
    remove_tree(root)


def test_overlapping_operands_report_each_entry_once_in_order() raises:
    """Two walks over one tree warn once per entry, sorted, never doubled.

    Overlapping operands walk the same subtree twice, so an entry reachable
    from both would otherwise be announced twice; and entries are created in
    reverse order here, so a channel that merely accumulated would report them
    out of order.
    """
    var root = temp_root()
    touch(root, "tests/test_z.mojo/test_in_z.mojo")
    touch(root, "tests/test_a.mojo/test_in_a.mojo")
    touch(root, "tests/test_plain.mojo")
    var result = discover(_config_paths(["tests", "tests"]), root)
    assert_paths(result.run_files, ["tests/test_plain.mojo"])
    assert_paths(
        result.skipped_nonregular, ["tests/test_a.mojo", "tests/test_z.mojo"]
    )
    remove_tree(root)


def test_an_entry_the_walk_cannot_inspect_refuses_discovery() raises:
    """A tree the walk cannot characterize is refused, never framed smaller.

    A directory this process may read but not search (mode 0644) lists its
    names while every child stat fails; folding those errors into "not a
    file" would silently frame the subtree as empty.
    """
    var root = temp_root()
    touch(root, "tests/sub/test_hidden.mojo")
    set_permissions(root + "/tests/sub", 0o644)
    var message = String("")
    try:
        _ = discover(_config_paths(["tests"]), root)
    except e:
        message = String(e)
    set_permissions(root + "/tests/sub", 0o755)
    assert_true("cannot inspect" in message)
    remove_tree(root)


def test_a_test_file_under_a_separator_path_is_skipped_and_announced() raises:
    """`::` in a path costs the file its identity, so the walk refuses it.

    The separator is reserved for node ids (§5), so nothing could name this
    file afterwards: not an operand, not a node id, not a last-run entry.
    Collecting it put a test in the run that the runner could not be pointed
    at, and refusing it silently would shrink the run with no trace — so it
    joins the loud channels the refused symlinks and non-regular entries use.
    """
    var root = temp_root()
    touch(root, "tests/test_plain.mojo")
    touch(root, "tests/co::l/test_x.mojo")
    var result = discover(_config_paths(["tests"]), root)
    assert_paths(result.run_files, ["tests/test_plain.mojo"])
    assert_paths(result.skipped_unaddressable, ["tests/co::l/test_x.mojo"])
    assert_equal(len(result.skipped_nonregular), 0)
    assert_equal(len(result.skipped_links), 0)
    remove_tree(root)


def test_a_separator_in_the_file_name_itself_is_refused_too() raises:
    """The rule is about the whole path, not only its directory components."""
    var root = temp_root()
    touch(root, "tests/test_plain.mojo")
    touch(root, "tests/test_a::b.mojo")
    var result = discover(_config_paths(["tests"]), root)
    assert_paths(result.run_files, ["tests/test_plain.mojo"])
    assert_paths(result.skipped_unaddressable, ["tests/test_a::b.mojo"])
    remove_tree(root)


def test_every_unaddressable_entry_is_announced_once_and_sorted() raises:
    """One warning per file, never one per subtree, and never doubled.

    A directory carrying the separator is still descended: reporting the
    directory alone would leave the reader to work out which tests it held,
    and overlapping operands would otherwise announce each of them twice.
    """
    var root = temp_root()
    touch(root, "tests/z::z/test_z.mojo")
    touch(root, "tests/a::a/test_a.mojo")
    touch(root, "tests/a::a/deep/test_deep.mojo")
    touch(root, "tests/test_plain.mojo")
    var result = discover(_config_paths(["tests", "tests"]), root)
    assert_paths(result.run_files, ["tests/test_plain.mojo"])
    assert_paths(
        result.skipped_unaddressable,
        [
            "tests/a::a/deep/test_deep.mojo",
            "tests/a::a/test_a.mojo",
            "tests/z::z/test_z.mojo",
        ],
    )
    remove_tree(root)


def test_a_clean_walk_reports_nothing_unaddressable() raises:
    var root = temp_root()
    touch(root, "tests/test_a.mojo")
    touch(root, "tests/helpers/test_b.mojo")
    var result = discover(_config_paths(["tests"]), root)
    assert_paths(
        result.run_files, ["tests/helpers/test_b.mojo", "tests/test_a.mojo"]
    )
    assert_equal(len(result.skipped_unaddressable), 0)
    remove_tree(root)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
