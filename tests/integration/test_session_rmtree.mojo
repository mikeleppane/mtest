"""`_rmtree` must NOT follow a symlink out of the build tree (CWE-59).

The recursive cleanup deletes a failed compile's temp/quarantine dirs under
`build/`. If it recursed into a symlink-to-directory it would delete the
TARGET's contents — a symlink planted at a predictable temp/quarantine path
would let a failed compile's cleanup reach outside the tree. This test plants
exactly that symlink and asserts the outside directory's contents survive: the
symlink is unlinked, never traversed. Real filesystem I/O under a disposable
`build/` scratch dir, cleaned up before and after.
"""
from std.os import listdir, makedirs, rmdir, symlink
from std.os.path import exists, islink
from std.testing import assert_false, assert_true

from mtest.session.session import _rmtree


def _reset(path: String) raises:
    # Best-effort teardown so a rerun starts clean (the symlink, if present, is
    # unlinked as a plain child — never followed).
    if exists(path) or islink(path):
        try:
            _rmtree(path)
        except:
            pass


def test_rmtree_does_not_follow_symlink_out_of_tree() raises:
    var base = String("build/_rmtree_symlink_it")
    _reset(base)

    # An OUTSIDE directory holding a file the cleanup must never touch.
    makedirs(base + "/victim", exist_ok=True)
    with open(base + "/victim/keep.txt", "w") as f:
        f.write("precious")

    # The tree we clean up, holding a real child and a symlink to the sibling
    # `victim` dir (resolves to `<base>/victim`, OUTSIDE `<base>/tree`).
    makedirs(base + "/tree", exist_ok=True)
    with open(base + "/tree/inner.txt", "w") as f:
        f.write("disposable")
    symlink("../victim", base + "/tree/link")

    _rmtree(base + "/tree")

    # The symlink and the tree are gone...
    assert_false(exists(base + "/tree"), "the tree itself should be removed")
    # ...but the OUTSIDE directory and its file survive untouched.
    assert_true(
        exists(base + "/victim/keep.txt"),
        "_rmtree followed a symlink and deleted an outside file (CWE-59)",
    )

    _reset(base)
