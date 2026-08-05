"""What a store key reads: bounded byte reads, compiler resolution, and walks.

Covers `mtest.session.store.walk` and the two Layer 0 primitives every key
derivation goes through before it reaches a walk — the bounded regular-file read
that turns a build input into frame bytes, and the `PATH` resolution that names
the compiler the key is about. They sit together because a key that reads the
wrong bytes and a key that walks the wrong tree are the same defect seen from
two ends.

Every case here keys a stub or nothing at all: none reads the pinned toolchain,
so none populates the process-lifetime toolchain memos.
"""
from std.os import getenv, setenv, symlink, unsetenv
from std.os.path import isdir, realpath
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_raises,
    assert_true,
)

from mtest.cache import KeyBuilder
from mtest.platform import (
    read_bounded_regular_file,
    read_regular_file_bytes,
    resolve_executable,
)
from mtest.session.store.walk import walk_include_root

from cache_fixtures import (
    chmod_path,
    dir_listing,
    executable_stub,
    write_bytes,
)
from session_fixtures import write_file
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


def test_resolve_absolute_path() raises:
    var root = temp_root()
    var stub = executable_stub(root, "bin/stub")
    var found = resolve_executable(stub)
    assert_true(Bool(found))
    assert_equal(found.value(), realpath(stub))


def test_resolve_via_path_order() raises:
    var root = temp_root()
    var first = executable_stub(root, "a/tool")
    var second = executable_stub(root, "b/tool")
    var forward = resolve_executable("tool", root + "/a:" + root + "/b")
    assert_true(Bool(forward))
    assert_equal(forward.value(), realpath(first))
    var backward = resolve_executable("tool", root + "/b:" + root + "/a")
    assert_true(Bool(backward))
    assert_equal(backward.value(), realpath(second))


def test_resolve_skips_non_executable_candidate() raises:
    var root = temp_root()
    write_bytes(root, "a/tool", [UInt8(35), UInt8(10)])
    var second = executable_stub(root, "b/tool")
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
    var only = executable_stub(root, "b/tool")
    # An empty component is the cwd entry. Asserting that it RESOLVES to cwd
    # would need an executable inside the test's own working directory, which
    # is the repo checkout — writing one there would dirty the tree the fmt
    # gate diffs. What is assertable is that the empty component neither aborts
    # the search nor swallows the separator behind it: the components after it
    # are still tried, in order.
    var found = resolve_executable("tool", ":" + root + "/a:" + root + "/b")
    assert_true(Bool(found))
    assert_equal(found.value(), realpath(only))


def test_resolve_without_environment_path_is_fail_closed() raises:
    var root = temp_root()
    # The stub (and its `chmod` child) is built while PATH is still intact.
    var stub = executable_stub(root, "b/tool")
    var saved = getenv("PATH", "")
    var bare: Optional[String]
    var slashed: Optional[String]
    var injected: Optional[String]
    try:
        _ = unsetenv("PATH")
        bare = resolve_executable("tool")
        slashed = resolve_executable(stub)
        injected = resolve_executable("tool", root + "/b")
    finally:
        _ = setenv("PATH", saved, True)
    # A bare name refuses rather than falling back to a cwd search: guessing
    # would key a cwd file as the compiler while the supervisor exec'd the one
    # `confstr(_CS_PATH)` names.
    assert_false(Bool(bare))
    # A spelling with a slash needs no search, so it still resolves.
    assert_true(Bool(slashed))
    assert_equal(slashed.value(), realpath(stub))
    # An injected PATH is unaffected by the environment lacking one: the
    # fail-closed branch is reached only when no `path_env` was supplied.
    assert_true(Bool(injected))
    assert_equal(injected.value(), realpath(stub))
    # An EXPLICIT empty PATH is a different thing entirely: one cwd component,
    # searched, and reported as a plain miss.
    assert_false(Bool(resolve_executable("tool", "")))


def test_resolve_rejects_directory_candidate() raises:
    var root = temp_root()
    write_bytes(root, "a/tool/keep.txt", [UInt8(107)])
    var found = resolve_executable("tool", root + "/a")
    assert_false(Bool(found))


# --- CacheContext: the include walk ------------------------------------------


def _walk_digest(root: String, dir: String, exclude: String) raises -> String:
    """The full key of a fresh builder fed by exactly one include walk.

    Comparing two of these compares the SETS OF FRAMES two walks produced, which
    is the only property that matters: the cache key is the digest, so "the walk
    saw the same thing" and "the digests match" are the same statement.

    Args:
        root: The invocation root the walk resolves `dir` and `exclude` against.
        dir: The include root to walk.
        exclude: A root-relative path to skip, or empty for none.

    Returns:
        The 64-hex digest of a builder fed only by this walk.

    Raises:
        Error: If the walk reported failure.
    """
    var kb = KeyBuilder()
    var outcome = walk_include_root(root, dir, kb, exclude)
    if not outcome.ok:
        raise Error(
            "test: walk_include_root failed for '"
            + dir
            + "': "
            + outcome.reason
        )
    return kb^.digest_full()


def test_walk_hashes_top_level_sources() raises:
    var a = temp_root()
    write_file(a, "inc/top.mojo", "# a")
    var b = temp_root()
    write_file(b, "inc/top.mojo", "# a")
    # Frames name paths RELATIVE TO the walked dir, so two identical trees in
    # different scratch roots key alike — otherwise no run could ever hit.
    assert_equal(_walk_digest(a, "inc", ""), _walk_digest(b, "inc", ""))
    var c = temp_root()
    write_file(c, "inc/top.mojo", "# b")
    assert_not_equal(_walk_digest(a, "inc", ""), _walk_digest(c, "inc", ""))


def test_walk_covers_every_source_suffix() raises:
    var bare = temp_root()
    write_file(bare, "inc/top.mojo", "# a")
    for suffix in ["🔥", "mojopkg", "mojoc"]:
        var full = temp_root()
        write_file(full, "inc/top.mojo", "# a")
        write_file(full, "inc/extra." + String(suffix), "# x")
        assert_not_equal(
            _walk_digest(bare, "inc", ""), _walk_digest(full, "inc", "")
        )
    # A suffix the compiler does not consume is not part of the build input.
    var noise = temp_root()
    write_file(noise, "inc/top.mojo", "# a")
    write_file(noise, "inc/README.md", "# x")
    assert_equal(_walk_digest(bare, "inc", ""), _walk_digest(noise, "inc", ""))


def test_walk_skips_dot_entries_and_plain_subdirs() raises:
    var bare = temp_root()
    write_file(bare, "inc/top.mojo", "# a")
    var noisy = temp_root()
    write_file(noisy, "inc/top.mojo", "# a")
    write_file(noisy, "inc/.hidden.mojo", "# x")
    write_file(noisy, "inc/.dotdir/__init__.mojo", "# x")
    # A subdirectory with no `__init__` is not a package, so `-I` never reaches
    # its contents and the key must not depend on them.
    write_file(noisy, "inc/plain/deep.mojo", "# x")
    assert_equal(_walk_digest(bare, "inc", ""), _walk_digest(noisy, "inc", ""))


def test_walk_recurses_into_package_subdirs() raises:
    var bare = temp_root()
    write_file(bare, "inc/top.mojo", "# a")
    var pkg = temp_root()
    write_file(pkg, "inc/top.mojo", "# a")
    write_file(pkg, "inc/p/__init__.mojo", "# i")
    write_file(pkg, "inc/p/mod.mojo", "# m")
    var with_pkg = _walk_digest(pkg, "inc", "")
    assert_not_equal(_walk_digest(bare, "inc", ""), with_pkg)
    # The recursion reads the nested file's CONTENT, not just its name.
    write_file(pkg, "inc/p/mod.mojo", "# n")
    assert_not_equal(with_pkg, _walk_digest(pkg, "inc", ""))


def test_walk_exclude_skips_path() raises:
    var bare = temp_root()
    write_file(bare, "inc/top.mojo", "# a")
    var root = temp_root()
    write_file(root, "inc/top.mojo", "# a")
    write_file(root, "inc/gen.mojopkg", "# generated")
    assert_not_equal(
        _walk_digest(bare, "inc", ""), _walk_digest(root, "inc", "")
    )
    # Excluding the generated artifact leaves exactly the tree without it: a
    # precompile step's own output must not feed the key that decides whether
    # that step runs.
    assert_equal(
        _walk_digest(bare, "inc", ""),
        _walk_digest(root, "inc", "inc/gen.mojopkg"),
    )


def test_walk_disables_on_symlinked_package() raises:
    var root = temp_root()
    write_file(root, "inc/top.mojo", "# a")
    write_file(root, "pkgsrc/__init__.mojo", "# i")
    write_file(root, "pkgsrc/mod.mojo", "# m")
    symlink(root + "/pkgsrc", root + "/inc/p")
    # `inc/p` IS a package, so the compiler imports `p.mod` — but the walk
    # cannot descend a link without risking a cycle. Skipping it silently was a
    # stale-hit hole: editing `pkgsrc/mod.mojo` left the key untouched and
    # served the previous binary on a green run. Off, loudly, is the only
    # honest answer.
    var kb = KeyBuilder()
    var outcome = walk_include_root(root, "inc", kb, "")
    assert_false(outcome.ok)
    assert_true(
        "symlink" in outcome.reason and "p" in outcome.reason,
        "reason did not name the symlinked package: " + outcome.reason,
    )


def test_walk_skips_symlinked_non_package_dirs() raises:
    var bare = temp_root()
    write_file(bare, "inc/top.mojo", "# a")
    var root = temp_root()
    write_file(root, "inc/top.mojo", "# a")
    write_file(root, "plainsrc/mod.mojo", "# m")
    symlink(root + "/plainsrc", root + "/inc/p")
    # No `__init__`, so `-I inc` does not reach inside `p` whether it is a link
    # or not. Nothing to key, nothing to refuse.
    assert_equal(_walk_digest(bare, "inc", ""), _walk_digest(root, "inc", ""))


def test_walk_reports_failure_for_missing_dir() raises:
    var root = temp_root()
    var kb = KeyBuilder()
    assert_false(walk_include_root(root, "absent", kb, "").ok)


def test_walk_disables_on_unlistable_subdir() raises:
    var root = temp_root()
    write_file(root, "inc/top.mojo", "# a")
    write_file(root, "inc/p/__init__.mojo", "# i")
    write_file(root, "inc/p/mod.mojo", "# m")
    var kb = KeyBuilder()
    chmod_path("000", root + "/inc/p")
    # No `try`/`finally`: `walk_include_root` is non-raising by contract, so the
    # restore below is unconditionally reached.
    #
    # `isdir`/`isfile` fold an unreadable directory into "not a package", which
    # would key this tree exactly like one with no `p` at all. `listdir` raises
    # instead, and the walk refuses.
    var outcome = walk_include_root(root, "inc", kb, "")
    chmod_path("755", root + "/inc/p")
    assert_false(outcome.ok, "an unreadable package did not disable the cache")
    assert_true(
        "p" in outcome.reason,
        "reason did not name the directory: " + outcome.reason,
    )


def test_walk_disables_on_unsearchable_subdir() raises:
    var root = temp_root()
    write_file(root, "inc/top.mojo", "# a")
    write_file(root, "inc/p/__init__.mojo", "# i")
    write_file(root, "inc/p/mod.mojo", "# m")
    var kb = KeyBuilder()
    # Readable but not searchable: `listdir` succeeds and every `stat` of an
    # entry inside fails. Under `isdir`/`isfile` every entry would answer "not a
    # directory, not a source file" and the package would frame NOTHING while
    # the walk reported success — the same stale-hit hole, one level down.
    chmod_path("644", root + "/inc/p")
    var outcome = walk_include_root(root, "inc", kb, "")
    chmod_path("755", root + "/inc/p")
    assert_false(
        outcome.ok, "an unsearchable package did not disable the cache"
    )
    assert_true(
        "cannot inspect" in outcome.reason,
        "reason was not the stat failure: " + outcome.reason,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
