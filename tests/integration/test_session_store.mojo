"""Integration tests for the session store, its scaffolding, and its key inputs.
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
from mtest.config import RunnerConfig
from mtest.exec import ExecRuntime, ProcessSpec, run_supervised
from mtest.platform import (
    read_bounded_regular_file,
    read_regular_file_bytes,
    resolve_executable,
)
from mtest.session.store import (
    CacheContext,
    cache_key_tags,
    collect_env_base,
    finalize_includes,
    walk_include_root,
)

from cache_fixtures import dir_listing, write_bytes
from session_fixtures import base_config, write_file
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


def test_resolve_without_environment_path_is_fail_closed() raises:
    var root = temp_root()
    # The stub (and its `chmod` child) is built while PATH is still intact.
    var stub = _executable_stub(root, "b/tool")
    var saved = getenv("PATH", "")
    var bare = Optional[String](None)
    var slashed = Optional[String](None)
    var injected = Optional[String](None)
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


# --- CacheContext: the include walk (Task 6) ---------------------------------


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
    if not walk_include_root(root, dir, kb, exclude):
        raise Error("test: walk_include_root failed for '" + dir + "'")
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


def test_walk_skips_directory_symlinks() raises:
    var bare = temp_root()
    write_file(bare, "inc/top.mojo", "# a")
    var root = temp_root()
    write_file(root, "inc/top.mojo", "# a")
    write_file(root, "pkgsrc/__init__.mojo", "# i")
    write_file(root, "pkgsrc/mod.mojo", "# m")
    symlink(root + "/pkgsrc", root + "/inc/p")
    # `inc/p` is a package by content, so only the `islink` check keeps the walk
    # out of it — and out of the cycle a self-referential link would close.
    assert_equal(_walk_digest(bare, "inc", ""), _walk_digest(root, "inc", ""))


def test_walk_reports_failure_for_missing_dir() raises:
    var root = temp_root()
    var kb = KeyBuilder()
    assert_false(walk_include_root(root, "absent", kb, ""))


# --- CacheContext: construction, disabling, and the env base (Task 6) --------


def _env_base(config: RunnerConfig, root: String) raises -> CacheContext:
    """Collect an env base over a runtime this helper opens and closes.

    No `try`/`finally` is needed and none is written: `collect_env_base` is
    non-raising by contract — every failure it can meet becomes a disabled
    context — so there is no path on which `runtime.close()` is skipped. That
    contract is what keeps this helper from repeating `_make_executable`'s
    shape above, where a raising `run_supervised` would leak an open runtime
    into every later test in this file.

    Args:
        config: The config to key.
        root: The invocation root.

    Returns:
        The collected context.
    """
    var runtime = ExecRuntime()
    runtime.open()
    var ctx = collect_env_base(runtime, config, root)
    runtime.close()
    return ctx^


def test_disable_keeps_the_first_reason() raises:
    var ctx = CacheContext()
    assert_true(ctx.enabled)
    assert_equal(ctx.disable_reason, "")
    ctx.disable("first")
    ctx.disable("second")
    assert_false(ctx.enabled)
    # The FIRST cause is the one the user can act on; a later symptom would
    # bury it.
    assert_equal(ctx.disable_reason, "first")


def test_tag_namespace_is_frame_safe() raises:
    var tags = cache_key_tags()
    assert_true(len(tags) > 0)
    for i in range(len(tags)):
        var tag = tags[i]
        assert_true(tag.byte_length() > 0, "empty tag at " + String(i))
        for b in tag.as_bytes():
            # A NUL inside a tag forges a frame boundary: `feed` writes the tag
            # bytes then one NUL, so `"a\0b"` and `"a"` with payload `b...`
            # become the same byte stream and two different builds key alike.
            assert_true(Int(b) != 0, "NUL in tag '" + tag + "'")
        # `feed_file` derives `tag + ".size"` and `tag + ".sha"`, so a base tag
        # spelled that way could collide with another tag's derived frames.
        assert_false(tag.endswith(".size"), "reserved suffix in '" + tag + "'")
        assert_false(tag.endswith(".sha"), "reserved suffix in '" + tag + "'")
        for j in range(i + 1, len(tags)):
            assert_not_equal(tag, tags[j], "duplicate tag '" + tag + "'")


def test_env_base_enabled_for_default_config() raises:
    var root = temp_root()
    var ctx = _env_base(base_config(), root)
    assert_true(ctx.enabled, "cache off: " + ctx.disable_reason)
    assert_equal(ctx.disable_reason, "")
    assert_false(ctx.warned)
    assert_equal(ctx.built_files, 0)
    assert_equal(ctx.cached_files, 0)
    assert_equal(len(ctx.extra_walk_dirs), 0)


def test_env_base_disables_on_unknown_arg() raises:
    var root = temp_root()
    var config = base_config()
    config.build_args = ["--sysroot=/x"]
    var ctx = _env_base(config^, root)
    assert_false(ctx.enabled)
    # The reason names the token, because that is the thing the user can remove.
    assert_true(
        "--sysroot=/x" in ctx.disable_reason,
        "reason did not name the token: " + ctx.disable_reason,
    )


def test_env_base_disables_on_unresolvable_compiler() raises:
    var root = temp_root()
    var config = base_config()
    config.mojo_path = "mtest-absent-compiler"
    var ctx = _env_base(config^, root)
    assert_false(ctx.enabled)
    assert_true(
        "mtest-absent-compiler" in ctx.disable_reason,
        "reason did not name the compiler: " + ctx.disable_reason,
    )


def test_env_base_disables_on_missing_arg_file() raises:
    var root = temp_root()
    var config = base_config()
    config.build_args = ["-Xlinker", "absent.o"]
    var ctx = _env_base(config^, root)
    assert_false(ctx.enabled)
    assert_true(
        "absent.o" in ctx.disable_reason,
        "reason did not name the token: " + ctx.disable_reason,
    )


def test_env_base_records_include_dir_args() raises:
    var root = temp_root()
    write_file(root, "extra/top.mojo", "# a")
    var config = base_config()
    config.build_args = ["-I", "extra"]
    var ctx = _env_base(config^, root)
    assert_true(ctx.enabled, "cache off: " + ctx.disable_reason)
    assert_equal(len(ctx.extra_walk_dirs), 1)
    assert_equal(ctx.extra_walk_dirs[0], "extra")


# --- CacheContext: finalize_includes (Task 6) --------------------------------


def _prefix_digest(ctx: CacheContext) raises -> String:
    """The full key of `ctx.prefix`, taken from a fork so `ctx` stays usable."""
    var forked = ctx.prefix.copy()
    return forked^.digest_full()


def test_finalize_includes_is_order_sensitive() raises:
    var root = temp_root()
    write_file(root, "a/one.mojo", "# one")
    write_file(root, "b/two.mojo", "# two")
    var forward = CacheContext()
    finalize_includes(forward, root, ["a", "b"])
    assert_true(forward.enabled, "cache off: " + forward.disable_reason)
    var backward = CacheContext()
    finalize_includes(backward, root, ["b", "a"])
    assert_true(backward.enabled, "cache off: " + backward.disable_reason)
    # Frame ORDER is the wire contract: `-I a -I b` and `-I b -I a` are
    # different command lines and must be different keys.
    assert_not_equal(_prefix_digest(forward), _prefix_digest(backward))


def test_finalize_includes_tracks_content() raises:
    var root = temp_root()
    write_file(root, "a/one.mojo", "# one")
    var before = CacheContext()
    finalize_includes(before, root, ["a"])
    write_file(root, "a/one.mojo", "# changed")
    var after = CacheContext()
    finalize_includes(after, root, ["a"])
    assert_not_equal(_prefix_digest(before), _prefix_digest(after))


def test_finalize_includes_disables_on_unwalkable_root() raises:
    var root = temp_root()
    var ctx = CacheContext()
    finalize_includes(ctx, root, ["absent"])
    assert_false(ctx.enabled)
    assert_true(
        "absent" in ctx.disable_reason,
        "reason did not name the include root: " + ctx.disable_reason,
    )


def test_finalize_includes_walks_recorded_extra_dirs() raises:
    var root = temp_root()
    write_file(root, "a/one.mojo", "# one")
    write_file(root, "extra/two.mojo", "# two")
    var plain = CacheContext()
    finalize_includes(plain, root, ["a"])
    var with_extra = CacheContext()
    with_extra.extra_walk_dirs.append("extra")
    finalize_includes(with_extra, root, ["a"])
    assert_true(with_extra.enabled, "cache off: " + with_extra.disable_reason)
    # A `-I` inside `--build-arg` reaches the compiler exactly like a configured
    # include root, so it has to reach the key the same way.
    assert_not_equal(_prefix_digest(plain), _prefix_digest(with_extra))


def test_finalize_includes_leaves_a_disabled_context_alone() raises:
    var root = temp_root()
    var ctx = CacheContext()
    ctx.disable("earlier cause")
    finalize_includes(ctx, root, ["absent"])
    assert_false(ctx.enabled)
    assert_equal(ctx.disable_reason, "earlier cause")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
