"""Integration tests for the session store, its scaffolding, and its key inputs.
"""
from std.os.path import isdir, realpath
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from mtest.exec import ExecRuntime, ProcessSpec, run_supervised
from mtest.platform import (
    read_bounded_regular_file,
    read_regular_file_bytes,
    resolve_executable,
)

from cache_fixtures import dir_listing, write_bytes
from tmptree import temp_root


def test_write_bytes_round_trips_invalid_utf8() raises:
    var root = temp_root()
    write_bytes(root, "blob.bin", [UInt8(0), UInt8(255), UInt8(195), UInt8(40)])
    assert_true(isdir(root))
    assert_equal(len(dir_listing(root)), 1)
    assert_equal(dir_listing(root)[0], "blob.bin")


def test_reads_binary_bytes_verbatim() raises:
    var root = temp_root()
    write_bytes(root, "blob.bin", [UInt8(0), UInt8(255), UInt8(195), UInt8(40)])
    var data = read_regular_file_bytes(root + "/blob.bin", 64)
    assert_equal(len(data), 4)
    assert_equal(Int(data[0]), 0)
    assert_equal(Int(data[2]), 195)


def test_rejects_missing_file() raises:
    var root = temp_root()
    with assert_raises(contains="could not open regular file"):
        _ = read_regular_file_bytes(root + "/absent.bin", 64)


def test_reads_across_chunk_boundaries() raises:
    var root = temp_root()
    var payload = List[UInt8](capacity=70000)
    for i in range(70000):
        payload.append(UInt8(i % 251))
    write_bytes(root, "large.bin", payload)
    var data = read_regular_file_bytes(root + "/large.bin", 1 << 20)
    assert_equal(len(data), 70000)
    assert_equal(Int(data[65535]), 65535 % 251)
    assert_equal(Int(data[65536]), 65536 % 251)
    assert_equal(Int(data[69999]), 69999 % 251)


def test_bounded_read_rejects_invalid_utf8() raises:
    var root = temp_root()
    write_bytes(root, "bad.toml", [UInt8(97), UInt8(195), UInt8(40), UInt8(98)])
    with assert_raises(contains="platform: regular file is not valid UTF-8"):
        _ = read_bounded_regular_file(root + "/bad.toml", 64)


def test_rejects_over_cap() raises:
    var root = temp_root()
    write_bytes(root, "blob.bin", [UInt8(1), UInt8(2), UInt8(3), UInt8(4)])
    var exact = read_regular_file_bytes(root + "/blob.bin", 4)
    assert_equal(len(exact), 4)
    with assert_raises(contains="exceeds"):
        _ = read_regular_file_bytes(root + "/blob.bin", 3)


def _make_executable(path: String) raises:
    """Give `path` the execute bit through a supervised `chmod` child.

    The platform layer carries no permissions primitive
    (`grep -rn "chmod\\|permissions" src/mtest/platform/` finds nothing) and the
    pinned `std.os` exposes no `chmod` either, so the bit has to come from a
    real process. `mtest.exec` already owns every fork/exec in the tree, which
    makes a supervised spawn the fallback the brief names — cheaper than a
    foreign declaration written only for the tests.

    Args:
        path: The file to make owner/group/other executable.

    Raises:
        Error: If the child did not exit, or exited non-zero.
    """
    var argv: List[String] = ["chmod", "755", path]
    var runtime = ExecRuntime()
    runtime.open()
    var result = run_supervised(runtime, ProcessSpec.command(argv^, 30000))
    runtime.close()
    if not result.termination.is_exited() or result.termination.value != 0:
        raise Error("test setup: chmod failed for '" + path + "'")


def _executable_stub(root: String, rel: String) raises -> String:
    """Write a trivial executable shell script at `root/rel` and return its path.

    Args:
        root: The scratch directory the relative path is resolved against.
        rel: The path relative to `root`; parent directories are created.

    Returns:
        The absolute (but not canonicalized) path of the stub.

    Raises:
        Error: If the file cannot be written or the execute bit cannot be set.
    """
    var source = String("#!/bin/sh\nexit 0\n")
    var data = List[UInt8]()
    for b in source.as_bytes():
        data.append(b)
    write_bytes(root, rel, data)
    var full = root + "/" + rel
    _make_executable(full)
    return full^


def test_resolve_absolute_path() raises:
    var root = temp_root()
    var stub = _executable_stub(root, "bin/stub")
    var found = resolve_executable(stub)
    assert_true(Bool(found))
    assert_equal(found.value(), realpath(stub))


def test_resolve_via_path_order() raises:
    var root = temp_root()
    var first = _executable_stub(root, "a/tool")
    var second = _executable_stub(root, "b/tool")
    var forward = resolve_executable("tool", root + "/a:" + root + "/b")
    assert_true(Bool(forward))
    assert_equal(forward.value(), realpath(first))
    var backward = resolve_executable("tool", root + "/b:" + root + "/a")
    assert_true(Bool(backward))
    assert_equal(backward.value(), realpath(second))


def test_resolve_skips_non_executable_candidate() raises:
    var root = temp_root()
    write_bytes(root, "a/tool", [UInt8(35), UInt8(10)])
    var second = _executable_stub(root, "b/tool")
    var found = resolve_executable("tool", root + "/a:" + root + "/b")
    assert_true(Bool(found))
    assert_equal(found.value(), realpath(second))


def test_resolve_missing_returns_none() raises:
    var root = temp_root()
    assert_false(Bool(resolve_executable("mtest-absent-tool", root)))
    assert_false(Bool(resolve_executable(root + "/absent/tool")))
    assert_false(Bool(resolve_executable("mtest-absent-tool", "")))


def test_resolve_traverses_empty_path_entries() raises:
    var root = temp_root()
    var only = _executable_stub(root, "b/tool")
    # An empty component is the cwd entry. Asserting that it RESOLVES to cwd
    # would need an executable inside the test's own working directory, which
    # is the repo checkout — writing one there would dirty the tree the fmt
    # gate diffs. What is assertable is that the empty component neither aborts
    # the search nor swallows the separator behind it: the components after it
    # are still tried, in order.
    var found = resolve_executable("tool", ":" + root + "/a:" + root + "/b")
    assert_true(Bool(found))
    assert_equal(found.value(), realpath(only))


def test_resolve_rejects_directory_candidate() raises:
    var root = temp_root()
    write_bytes(root, "a/tool/keep.txt", [UInt8(107)])
    var found = resolve_executable("tool", root + "/a")
    assert_false(Bool(found))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
