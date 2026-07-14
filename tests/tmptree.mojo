"""Temp-directory tree helpers for the `discover` tests.

Not a test module (no `test_` prefix, so the runner never builds it as a suite);
it is imported via `-I tests`. Each helper builds or tears down a real on-disk
tree so the walk can be exercised against actual directories, files, and
symlinks, then cleaned up.
"""
from std.os import listdir, makedirs, remove, rmdir, symlink, unlink
from std.os.path import dirname, exists, isdir, islink
from std.tempfile import mkdtemp
from std.testing import assert_equal


def _fmt(xs: List[String]) -> String:
    """Render a path list as `[a, b, c]` for assertion messages."""
    var out = String("[")
    for i in range(len(xs)):
        if i > 0:
            out += ", "
        out += xs[i]
    out += "]"
    return out^


def assert_paths(got: List[String], expected: List[String]) raises:
    """Assert `got` equals `expected` element-for-element, with a clear diff."""
    var msg = "paths mismatch: got " + _fmt(got) + " expected " + _fmt(expected)
    assert_equal(len(got), len(expected), msg)
    for i in range(len(expected)):
        assert_equal(got[i], expected[i], msg)


def temp_root() raises -> String:
    """Create and return a fresh, empty temp directory."""
    return mkdtemp()


def mkdirs(path: String) raises:
    """Create `path` and any missing parents (a no-op if it already exists)."""
    if not exists(path):
        makedirs(path)


def touch(root: String, rel: String) raises:
    """Create an empty file at `root/rel`, making parent directories as needed.
    """
    var full = root + "/" + rel
    var parent = dirname(full)
    if parent != "" and not exists(parent):
        makedirs(parent)
    with open(full, "w") as f:
        f.write("")


def link_dir(root: String, target_rel: String, link_rel: String) raises:
    """Create a symlink at `root/link_rel` pointing at `root/target_rel`."""
    symlink(root + "/" + target_rel, root + "/" + link_rel)


def remove_tree(path: String) raises:
    """Recursively delete `path`; a symlink is unlinked, never followed."""
    if islink(path):
        unlink(path)
        return
    if isdir(path):
        for entry in listdir(path):
            remove_tree(path + "/" + String(entry))
        rmdir(path)
    elif exists(path):
        remove(path)
