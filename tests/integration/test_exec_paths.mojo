"""Canonical-path helper invariants for `exec`: absolute, symlink-resolved, raising.

`canonicalize` must return the absolute, symlink-resolved path `mojo build` would
bake into a child's report — so an existing file resolves to an absolute path with
no `.`/`..` segments, a symlink resolves to its target's canonical path, and a
path that cannot be resolved raises an error naming the path.
"""
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from mtest.exec import canonicalize

from tmptree import temp_root, touch, link_dir, remove_tree


def test_existing_file_is_absolute_and_canonical() raises:
    var p = canonicalize("tests/fixtures/protocol/passing.mojo")
    assert_true(p.startswith("/"), p)
    assert_true(p.endswith("/tests/fixtures/protocol/passing.mojo"), p)
    assert_false("/./" in p, p)
    assert_false("/../" in p, p)


def test_symlink_resolves_to_target_canonical() raises:
    var root = temp_root()
    touch(root, "real/file.mojo")
    link_dir(root, "real/file.mojo", "link.mojo")
    var via_link = canonicalize(root + "/link.mojo")
    var via_real = canonicalize(root + "/real/file.mojo")
    assert_equal(via_link, via_real)
    assert_true(via_link.endswith("/real/file.mojo"), via_link)
    remove_tree(root)


def test_nonexistent_path_raises_naming_the_path() raises:
    with assert_raises(contains="/no/such/mtest/xyz123"):
        _ = canonicalize("/no/such/mtest/xyz123")
