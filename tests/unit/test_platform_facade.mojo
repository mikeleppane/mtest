"""What `mtest.platform` re-exports: `EINTR`, the four `S_IF*` mode values,
`path_kind`, and the raw fd primitives.

A POSIX constant centralized at one owning site is only actually centralized
if the facade re-exports the same name callers reach for, and if the value is
the real POSIX one rather than a copy that drifted. These tests pin both: the
values against a real `lstat` and a real fd, not just the numeral.
"""
from std.os import lstat, mkdir, symlink
from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from mtest.platform import (
    CreatResult,
    EINTR,
    S_IFDIR,
    S_IFLNK,
    S_IFMT,
    S_IFREG,
    close_fd,
    create_truncate_fd_guarded,
    errno_now,
    path_kind,
    read_fd,
    write_fd,
)

from tmptree import remove_tree, temp_root


def test_eintr_is_the_posix_value_shared_by_linux_and_darwin() raises:
    assert_equal(EINTR, 4)


def test_s_if_constants_are_the_posix_mask_and_type_values() raises:
    assert_equal(S_IFMT, 0o170000)
    assert_equal(S_IFDIR, 0o40000)
    assert_equal(S_IFREG, 0o100000)
    assert_equal(S_IFLNK, 0o120000)


def test_s_ifmt_classifies_a_real_file_dir_and_symlink() raises:
    """Not just numerals: masking a live `st_mode` with these constants must
    recover the kind `lstat` actually reports for each of the three kinds
    `discover` and the build cache branch on."""
    var root = temp_root()
    try:
        var file_path = root + "/plain"
        with open(file_path, "w") as destination:
            destination.write("x")
        var dir_path = root + "/sub"
        mkdir(dir_path)
        var link_path = root + "/link"
        symlink(file_path, link_path)

        var file_mode = Int(lstat(file_path).st_mode)
        var dir_mode = Int(lstat(dir_path).st_mode)
        var link_mode = Int(lstat(link_path).st_mode)
        assert_equal(file_mode & S_IFMT, S_IFREG)
        assert_equal(dir_mode & S_IFMT, S_IFDIR)
        assert_equal(link_mode & S_IFMT, S_IFLNK)
    finally:
        remove_tree(root)


def test_path_kind_reports_the_link_never_its_target() raises:
    """The one property every no-follow caller depends on: a symlink to a
    directory reports `S_IFLNK`, not the `S_IFDIR` a following stat would."""
    var root = temp_root()
    try:
        var file_path = root + "/plain"
        with open(file_path, "w") as destination:
            destination.write("x")
        var dir_path = root + "/sub"
        mkdir(dir_path)
        symlink(file_path, root + "/file_link")
        symlink(dir_path, root + "/dir_link")

        assert_equal(path_kind(file_path), S_IFREG)
        assert_equal(path_kind(dir_path), S_IFDIR)
        assert_equal(path_kind(root + "/file_link"), S_IFLNK)
        assert_equal(path_kind(root + "/dir_link"), S_IFLNK)
    finally:
        remove_tree(root)


def test_path_kind_raises_for_a_path_it_cannot_characterize() raises:
    """An absent path is an error rather than a kind, so a caller cannot read
    "not a directory" out of a question the filesystem never answered."""
    var root = temp_root()
    try:
        with assert_raises():
            _ = path_kind(root + "/absent")
    finally:
        remove_tree(root)


def test_fd_primitives_round_trip_through_the_facade() raises:
    """`create_truncate_fd_guarded`, `write_fd`, and `close_fd` reached
    through `mtest.platform` behave exactly as `platform.stream` documents:
    the facade re-exports the same functions, not copies."""
    var root = temp_root()
    try:
        var path = root + "/via_facade.txt"
        var created: CreatResult = create_truncate_fd_guarded(path)
        assert_true(created.fd >= 0)
        var payload = String("through the facade")
        var bytes = payload.as_bytes()
        # SAFETY: `bytes` borrows `payload`'s live buffer for this statement;
        # `write_fd` reads at most `len(bytes)` bytes through the pointer,
        # retains nothing past its synchronous return, and the pointer does
        # not escape this call.
        var written = write_fd(created.fd, bytes.unsafe_ptr(), len(bytes))
        assert_equal(written, len(bytes))
        assert_equal(close_fd(created.fd), 0)

        with open(path, "r") as source:
            assert_equal(source.read(), payload)
    finally:
        remove_tree(root)


def test_read_fd_and_errno_now_report_a_write_only_descriptors_bad_read() raises:
    """`read(2)` on a descriptor opened write-only fails with `EBADF` (9),
    identical on Linux and Darwin. Exercises `read_fd` and `errno_now`
    together through the facade."""
    var root = temp_root()
    try:
        var created = create_truncate_fd_guarded(root + "/write_only.txt")
        assert_true(created.fd >= 0)
        var buf = List[UInt8]()
        for _ in range(8):
            buf.append(0)
        # SAFETY: `buf` owns 8 initialized writable bytes for this statement;
        # `read_fd` writes at most 8 bytes through the pointer, retains
        # nothing past its synchronous return, and the pointer does not
        # escape this call.
        var result = read_fd(created.fd, buf.unsafe_ptr(), 8)
        assert_true(result < 0)
        assert_equal(errno_now(), 9)
        assert_equal(close_fd(created.fd), 0)
    finally:
        remove_tree(root)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
