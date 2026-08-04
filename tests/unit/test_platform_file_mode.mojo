"""What a published file's permission bits are, and what proves they took.

`set_permissions` raises when `chmod(2)` refuses. That is not the only way a
requested mode fails to arrive: a filesystem whose modes come from its mount
options — FAT, exFAT, several FUSE mounts — accepts the call and changes
nothing. A publisher that trusts the return status therefore promises a mode it
never verified, on exactly the filesystems where the promise is broken. These
tests pin the observing form: it reports what the file CARRIES afterwards, not
what the call answered.
"""
from std.os import remove
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.platform import (
    apply_permissions,
    close_checked_fd,
    create_unique_temp,
    default_file_mode,
    observe_path,
)

from tmptree import remove_tree, temp_root


def test_an_applied_mode_is_reported_only_once_the_file_carries_it() raises:
    var root = temp_root()
    try:
        var temp = create_unique_temp(root + "/report.XXXXXX")
        close_checked_fd(temp.fd)
        # `mkstemp` guarantees 0600, which is the mode a published report must
        # NOT keep: it is written to be read by a CI job or a reviewer.
        assert_equal(observe_path(temp.path).mode, 0o600)
        assert_true(apply_permissions(temp.path, 0o644))
        assert_equal(observe_path(temp.path).mode, 0o644)
        # Idempotent: applying the mode a file already carries still reports it
        # took, because the question is about the file and not about the call.
        assert_true(apply_permissions(temp.path, 0o644))
        remove(temp.path)
    finally:
        remove_tree(root)


def test_a_mode_that_could_not_be_applied_is_reported_as_such() raises:
    """Total rather than raising, and never optimistic: a path with no file
    behind it carries no mode, so the answer is that the mode did not take."""
    var root = temp_root()
    try:
        assert_false(apply_permissions(root + "/absent", 0o644))
        assert_false(exists(root + "/absent"))
    finally:
        remove_tree(root)
    assert_false(apply_permissions("/no/such/dir/absent", 0o644))


def test_the_pinned_open_ignores_the_umask_a_report_must_honor() raises:
    """Why a published report is given its mode explicitly at all.

    The pinned toolchain's `open` creates at a literal `0666`, umask and all —
    which is why `--junit-xml`'s artifact ships world-writable and why a report
    written beside it takes `default_file_mode()` instead of copying it. Pinned
    here so the claim is a measurement rather than a remembered fact: under any
    nonzero umask an `open` that started honoring it would turn this red.
    """
    var root = temp_root()
    try:
        var ordinary = root + "/plain"
        with open(ordinary, "w") as destination:
            destination.write("x")
        assert_equal(observe_path(ordinary).mode, 0o666)
        assert_true(default_file_mode() <= 0o666)
        remove(ordinary)
    finally:
        remove_tree(root)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
