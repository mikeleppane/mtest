"""Exclusive same-directory temporary-file regressions."""
from std.os import link, listdir, remove, symlink
from std.os.path import exists, islink
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

from mtest.platform import (
    close_checked_fd,
    create_unique_temp,
    process_id,
    read_bounded_regular_file,
    rename_path,
    write_all_fd,
)

from tmptree import remove_tree, temp_root


def _read(path: String) raises -> String:
    with open(path, "r") as source:
        return source.read()


def _write(path: String, text: String) raises:
    with open(path, "w") as destination:
        destination.write(text)


def test_unique_temp_never_reuses_predictable_links_or_collisions() raises:
    var root = temp_root()
    try:
        var target = root + "/lastrun"
        var victim = root + "/victim"
        var old_predictable = target + ".tmp." + String(process_id())
        var old_hardlink = old_predictable + ".hard"
        _write(victim, "sentinel")
        symlink(victim, old_predictable)
        link(victim, old_hardlink)

        var template = old_predictable + ".XXXXXX"
        var first = create_unique_temp(template)
        var second = create_unique_temp(template)
        assert_true(first.path != second.path)
        assert_true(first.path != old_predictable)
        assert_true(first.path != old_hardlink)
        assert_true(second.path != old_predictable)
        assert_true(second.path != old_hardlink)
        assert_true(first.path.startswith(old_predictable + "."))
        assert_true(second.path.startswith(old_predictable + "."))

        write_all_fd(first.fd, "first")
        write_all_fd(second.fd, "second")
        close_checked_fd(first.fd)
        close_checked_fd(second.fd)
        rename_path(first.path, target)
        assert_equal(_read(target), "first")
        rename_path(second.path, target)
        assert_equal(_read(target), "second")

        assert_false(exists(first.path))
        assert_false(exists(second.path))
        assert_true(islink(old_predictable))
        assert_equal(_read(victim), "sentinel")
        assert_equal(_read(old_hardlink), "sentinel")
    finally:
        remove_tree(root)


def test_create_and_write_failures_leave_cleanup_to_the_exact_owner() raises:
    var root = temp_root()
    try:
        with assert_raises(contains="mkstemp failed"):
            _ = create_unique_temp(root + "/missing-template")
        assert_equal(len(listdir(root)), 0)

        var temp = create_unique_temp(root + "/state.XXXXXX")
        close_checked_fd(temp.fd)
        with assert_raises(contains="write failed"):
            write_all_fd(temp.fd, "never written")
        assert_true(exists(temp.path))
        remove(temp.path)
        assert_equal(len(listdir(root)), 0)
    finally:
        remove_tree(root)


def test_bounded_read_validates_the_opened_regular_file() raises:
    var root = temp_root()
    try:
        var source = root + "/config.toml"
        var linked = root + "/linked.toml"
        _write(source, "abcd")
        symlink(source, linked)

        var direct = read_bounded_regular_file(source, 3)
        assert_true(direct.is_regular)
        assert_equal(direct.text, "abcd")

        var through_link = read_bounded_regular_file(linked, 4)
        assert_true(through_link.is_regular)
        assert_equal(through_link.text, "abcd")

        var directory = read_bounded_regular_file(root, 4)
        assert_false(directory.is_regular)
        assert_equal(directory.text, "")
    finally:
        remove_tree(root)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
