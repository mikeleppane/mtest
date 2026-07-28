"""Integration tests for the session store, its scaffolding, and its key inputs.
"""
from std.os import getenv, makedirs, remove, setenv, symlink, unsetenv
from std.os.path import exists, isdir, islink, realpath
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_raises,
    assert_true,
)

from mtest.cache import KeyBuilder
from mtest.config import Precompile, RunnerConfig
from mtest.exec import ExecRuntime, ProcessResult, ProcessSpec, run_supervised
from mtest.platform import (
    read_bounded_regular_file,
    read_regular_file_bytes,
    rename_path,
    resolve_executable,
)
from mtest.session.scratch import _mangle
from mtest.session.store import (
    PROBE_HIT,
    PROBE_MISS,
    PUB_ADOPTED,
    PRECOMPILE_SUBDIR,
    PUB_FAILED,
    PUB_OK,
    STORE_DIR,
    CacheContext,
    FileKey,
    StoreBuildTarget,
    cache_key_tags,
    collect_env_base,
    file_key,
    finalize_includes,
    precompile_key,
    precompile_probe,
    precompile_publish,
    precompile_stamp_rel,
    remove_tree_no_follow,
    store_build_target,
    store_probe,
    store_publish,
    walk_include_root,
)

from cache_fixtures import dir_listing, run_recording_session, write_bytes
from session_fixtures import SRC_PASS, base_config, write_file
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


def _chmod(mode: String, path: String) raises:
    """Set `path`'s mode through a supervised `chmod` child.

    The platform layer carries no permissions primitive
    (`grep -rn "chmod\\|permissions" src/mtest/platform/` finds nothing) and the
    pinned `std.os` exposes no `chmod` either, so the bit has to come from a
    real process. `mtest.exec` already owns every fork/exec in the tree, which
    makes a supervised spawn the fallback the brief names — cheaper than a
    foreign declaration written only for the tests.

    The runtime is closed in a `finally`. Without it a raising `run_supervised`
    would leave mtest's process-global signal dispositions owned by a runtime
    nobody can close, and every later test in this file that opens one would
    fail on "a runtime is already active".

    Args:
        mode: The mode argument to pass to `chmod`, e.g. `"755"` or `"000"`.
        path: The file or directory to change.

    Raises:
        Error: If the child did not exit, or exited non-zero.
    """
    var argv: List[String] = ["chmod", mode, path]
    var runtime = ExecRuntime()
    runtime.open()
    var result: ProcessResult
    try:
        result = run_supervised(runtime, ProcessSpec.command(argv^, 30000))
    finally:
        runtime.close()
    if not result.termination.is_exited() or result.termination.value != 0:
        raise Error("test setup: chmod " + mode + " failed for '" + path + "'")


def _make_executable(path: String) raises:
    """Give `path` the execute bit.

    Args:
        path: The file to make owner/group/other executable.

    Raises:
        Error: If the child did not exit, or exited non-zero.
    """
    _chmod("755", path)


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
    _chmod("000", root + "/inc/p")
    # No `try`/`finally`: `walk_include_root` is non-raising by contract, so the
    # restore below is unconditionally reached.
    #
    # `isdir`/`isfile` fold an unreadable directory into "not a package", which
    # would key this tree exactly like one with no `p` at all. `listdir` raises
    # instead, and the walk refuses.
    var outcome = walk_include_root(root, "inc", kb, "")
    _chmod("755", root + "/inc/p")
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
    _chmod("644", root + "/inc/p")
    var outcome = walk_include_root(root, "inc", kb, "")
    _chmod("755", root + "/inc/p")
    assert_false(
        outcome.ok, "an unsearchable package did not disable the cache"
    )
    assert_true(
        "cannot inspect" in outcome.reason,
        "reason was not the stat failure: " + outcome.reason,
    )


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


def _base_digest(ctx: CacheContext) raises -> String:
    """The full key of `ctx.base`, taken from a fork so `ctx` stays usable."""
    var forked = ctx.base.copy()
    return forked^.digest_full()


def test_env_base_digest_is_stable_across_calls() raises:
    var root = temp_root()
    var first = _env_base(base_config(), root)
    var second = _env_base(base_config(), root)
    assert_true(first.enabled, "cache off: " + first.disable_reason)
    assert_true(second.enabled, "cache off: " + second.disable_reason)
    # THE property every future cache hit rests on. If two collections over
    # unchanged inputs ever disagree — an unsorted listing, an absolute path
    # leaking into a frame, a memo returning something other than what it
    # replaced — the cache degrades to a rebuild every time and nothing else in
    # the suite would notice.
    assert_equal(_base_digest(first), _base_digest(second))


def test_env_base_digest_moves_with_build_args() raises:
    var root = temp_root()
    var plain = _env_base(base_config(), root)
    var one = base_config()
    one.build_args = ["-O2"]
    var flagged = _env_base(one^, root)
    assert_true(flagged.enabled, "cache off: " + flagged.disable_reason)
    assert_not_equal(_base_digest(plain), _base_digest(flagged))

    var forward = base_config()
    forward.build_args = ["-O2", "--no-optimization"]
    var backward = base_config()
    backward.build_args = ["--no-optimization", "-O2"]
    # Frame ORDER inside field 7: the same two flags in the other order are a
    # different command line and must be a different key.
    assert_not_equal(
        _base_digest(_env_base(forward^, root)),
        _base_digest(_env_base(backward^, root)),
    )


def test_env_base_digest_moves_with_environment() raises:
    var root = temp_root()
    # `MODULAR_HOME` relocates the compiler's module cache, so it is keyed. It
    # is restored exactly, including the "was not set at all" case, which is a
    # different fact from "set to the empty string" and keys differently.
    var was_set = getenv("MODULAR_HOME", "\x01unset") != "\x01unset"
    var saved = getenv("MODULAR_HOME", "")
    # Collected into a list rather than three pre-declared strings so the
    # `finally` restore is never skipped and no dead initializer is needed.
    var digests = List[String]()
    try:
        _ = setenv("MODULAR_HOME", "/tmp/mtest-modular-here", True)
        digests.append(_base_digest(_env_base(base_config(), root)))
        _ = setenv("MODULAR_HOME", "/tmp/mtest-modular-there", True)
        digests.append(_base_digest(_env_base(base_config(), root)))
        _ = unsetenv("MODULAR_HOME")
        digests.append(_base_digest(_env_base(base_config(), root)))
    finally:
        if was_set:
            _ = setenv("MODULAR_HOME", saved, True)
        else:
            _ = unsetenv("MODULAR_HOME")
    assert_equal(len(digests), 3)
    assert_not_equal(digests[0], digests[1])
    assert_not_equal(digests[0], digests[2])
    assert_not_equal(digests[1], digests[2])


def test_env_base_digest_moves_with_root() raises:
    var here = temp_root()
    var there = temp_root()
    # Field 6 is the CANONICAL root, so two runs of the same sources from two
    # checkouts do not share a generation.
    assert_not_equal(
        _base_digest(_env_base(base_config(), here)),
        _base_digest(_env_base(base_config(), there)),
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


# --- The store: staging, probe, publish, adopt, and reap (Task 7) ------------


def _fixture_key(root: String, rel: String, body: String) raises -> FileKey:
    """Key a REAL source file at `root/rel`, so `src_sha` describes real bytes.

    The publication guard re-digests the source and compares it to `src_sha`,
    so a key built from an invented digest would fail every publish and prove
    nothing. The context is a bare `CacheContext`, whose `prefix` is an empty
    builder: the store protocol does not care what the session prefix covers,
    only that two different sources key differently, and skipping
    `collect_env_base` keeps each of these tests off the 141 MB toolchain
    digest.

    Args:
        root: The scratch root the source is written under.
        rel: The source's root-relative path; parent directories are created.
        body: The source text to write. Two calls with different bodies at the
            same `rel` produce two keys sharing a mangled prefix — which is
            exactly what the reaping test needs.

    Returns:
        The key a session would compute for that file.

    Raises:
        Error: If the source cannot be written or keyed.
    """
    write_file(root, rel, body)
    var ctx = CacheContext()
    var key = file_key(ctx, root, rel)
    if not key:
        raise Error("test: file_key failed for '" + rel + "'")
    return key.value().copy()


def _stage_binary(
    root: String, payload: List[UInt8]
) raises -> StoreBuildTarget:
    """Stage a build target and put `payload` exactly where `-o` would land.

    Args:
        root: The invocation root.
        payload: The bytes standing in for a compiled binary.

    Returns:
        The staging target, with its `bin` already written.

    Raises:
        Error: If the store could not stage a target.
    """
    var target = store_build_target(root, _mangle("tests/test_staged.mojo"))
    if not target.ok():
        raise Error("test: store_build_target produced no staging directory")
    write_bytes(root, target.out_rel, payload)
    return target^


def _build_argv(rel: String, out_rel: String) -> List[String]:
    """The shape every build site emits: `-o` and its path as two tokens."""
    var argv = List[String]()
    argv.append("mojo")
    argv.append("build")
    argv.append("-o")
    argv.append(String(out_rel))
    argv.append(String(rel))
    return argv^


def _near(a: Float64, b: Float64) -> Bool:
    """Whether two durations agree to the meta format's microsecond grid."""
    var d = a - b
    if d < 0.0:
        d = -d
    return d < 1.0e-6


def test_staging_directory_name_carries_the_mangled_source() raises:
    # A first-attempt cached build is compiled into staging AND RUN from
    # staging: the rename into a generation happens only after the file's
    # verdict is settled. So the staged path is the only name a live test child
    # has, and anything identifying that child from outside the process — the
    # release contract's SIGINT probe, a `ps` a human reads during a hang — has
    # nothing else to match on. A name built from pid and clock alone hid every
    # running child from `pgrep`.
    var root = temp_root()
    var mangled = _mangle("irq/test_1hang.mojo")
    assert_equal(mangled, "irq_stest_u1hang")
    var target = store_build_target(root, mangled)
    assert_true(target.ok())
    var name = String(target.tmp_dir_rel.removeprefix(STORE_DIR + "/"))
    assert_true(
        name.startswith(".tmp-" + mangled + "-"),
        "the staging directory did not name its source: " + name,
    )
    # Dot-prefixed, so `walk_include_root` skips it and the cache's own staged
    # bytes never feed the key that decides what the cache serves.
    assert_true(
        name.startswith("."), "staging name is no longer hidden: " + name
    )
    # Free of `_h`, so a staging directory can never be read as the generation
    # `<mangled>_h<digest32>`. `_mangle` escapes literal `_` as `_u`, and the
    # decoration adds only `-` and decimal digits.
    assert_equal(name.find("_h"), -1)
    assert_equal(target.out_rel, target.tmp_dir_rel + "/bin")


def test_marker_written_at_mtest_cache_root() raises:
    var root = temp_root()
    var target = store_build_target(root, _mangle("tests/test_marker.mojo"))
    assert_true(target.ok())
    assert_true(isdir(root + "/" + STORE_DIR))
    assert_true(isdir(root + "/" + target.tmp_dir_rel))
    # The tag marks the WHOLE owned directory, not just the store, because that
    # is the directory `--cache-clear` deletes and the marker is what proves the
    # directory is mtest's before anything is removed.
    var tag = read_bounded_regular_file(
        root + "/.mtest-cache/CACHEDIR.TAG", 4096
    )
    assert_true(tag.is_regular)
    assert_true(
        tag.text.startswith("Signature: 8a477f597d28d172789f06886806bc55"),
        "the tag did not lead with the standard signature: " + tag.text,
    )


def test_publish_then_probe_hits() raises:
    var root = temp_root()
    var rel = String("tests/test_hit.mojo")
    var key = _fixture_key(root, rel, "# hit\n")
    var target = _stage_binary(root, [UInt8(1), UInt8(2), UInt8(3)])
    var pub = store_publish(
        root, key, target, 2.5, _build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_OK)
    assert_equal(pub.bin_rel, key.gen_dir + "/bin")
    assert_equal(pub.warning, "")
    # The staging directory was RENAMED into place, not copied out of.
    assert_false(isdir(root + "/" + target.tmp_dir_rel))
    # The caller records THIS argv, not the one it passed in: the `-o` it built
    # with names the staging directory, which the rename just consumed. The
    # caller cannot fix that up itself, so publication hands it back fixed.
    assert_equal(len(pub.argv), 5)
    assert_equal(pub.argv[3], key.gen_dir + "/bin")
    assert_true(exists(root + "/" + pub.argv[3]))

    var hit = store_probe(root, key)
    assert_equal(hit.kind, PROBE_HIT)
    assert_equal(hit.bin_rel, key.gen_dir + "/bin")
    # `secs` round-trips through a fixed-point field with six decimals, so exact
    # float equality is the wrong question to ask of it.
    assert_true(_near(hit.build_seconds, 2.5), "build seconds did not survive")
    # The reproduce line must name a path that exists AFTER publication; the
    # staging path it was built with is gone by then.
    assert_equal(len(hit.argv), 5)
    assert_equal(hit.argv[3], key.gen_dir + "/bin")


def test_probe_rejects_corrupted_bin() raises:
    var root = temp_root()
    var rel = String("tests/test_corrupt.mojo")
    var key = _fixture_key(root, rel, "# corrupt\n")
    var target = _stage_binary(root, [UInt8(1), UInt8(2), UInt8(3)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, _build_argv(rel, target.out_rel)
        ).kind,
        PUB_OK,
    )
    write_bytes(root, key.gen_dir + "/bin", [UInt8(9), UInt8(9)])
    # The recorded digest is the ONLY thing binding `meta` to `bin`; a key match
    # alone would have served these two bytes as a green test run.
    assert_equal(store_probe(root, key).kind, PROBE_MISS)
    # A failed check deletes the generation, so the corruption cannot be re-read
    # on the next probe either.
    assert_false(isdir(root + "/" + key.gen_dir))
    assert_equal(store_probe(root, key).kind, PROBE_MISS)


def test_probe_rejects_wrong_key_meta() raises:
    var root = temp_root()
    var rel = String("tests/test_collide.mojo")
    var key = _fixture_key(root, rel, "# collide\n")
    var target = _stage_binary(root, [UInt8(7)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, _build_argv(rel, target.out_rel)
        ).kind,
        PUB_OK,
    )
    # The generation NAME carries only the first 128 bits of the key. A prefix
    # collision would put a foreign build at exactly this path, so the FULL
    # digest recorded in `meta` is what a hit is checked against.
    var collided = FileKey(
        digest32=key.digest32,
        digest_full=String("a") * 64,
        gen_name=key.gen_name,
        gen_dir=key.gen_dir,
        src_rel=key.src_rel,
        src_sha=key.src_sha,
    )
    assert_equal(store_probe(root, collided).kind, PROBE_MISS)
    assert_false(isdir(root + "/" + key.gen_dir))


def test_partial_tmp_generation_is_inert() raises:
    var root = temp_root()
    var key = _fixture_key(root, "tests/test_partial.mojo", "# partial\n")
    makedirs(root + "/" + STORE_DIR + "/.tmp-999-zz")
    assert_equal(store_probe(root, key).kind, PROBE_MISS)
    # A half-built staging directory is not a generation, and a probe does not
    # reap it: another process may be compiling into it right now.
    assert_true(isdir(root + "/" + STORE_DIR + "/.tmp-999-zz"))


def test_publish_adopts_existing_same_key() raises:
    var root = temp_root()
    var rel = String("tests/test_adopt.mojo")
    var key = _fixture_key(root, rel, "# adopt\n")
    var first = _stage_binary(root, [UInt8(1)])
    assert_equal(
        store_publish(
            root, key, first, 1.0, _build_argv(rel, first.out_rel)
        ).kind,
        PUB_OK,
    )
    var second = _stage_binary(root, [UInt8(1)])
    # A sixth token this run's command line carries and the winner's does not,
    # so the adopted argv can be told apart from a merely rewritten one.
    var loser_argv = _build_argv(rel, second.out_rel)
    loser_argv.append("--loser-only")
    var again = store_publish(root, key, second, 1.0, loser_argv^)
    # A concurrent run reached the path first. Its generation revalidated, so
    # this one adopts it rather than failing or clobbering it.
    assert_equal(again.kind, PUB_ADOPTED)
    assert_equal(again.bin_rel, key.gen_dir + "/bin")
    assert_false(isdir(root + "/" + second.tmp_dir_rel))
    # The adopted binary is the WINNER's, so the reproduce line must be the
    # winner's too — this run's own command line describes bytes nobody will
    # run, and its `-o` names a staging directory that is already gone.
    assert_equal(len(again.argv), 5)
    assert_equal(again.argv[3], key.gen_dir + "/bin")
    assert_true(exists(root + "/" + again.argv[3]))


def test_adoption_revalidates_winner() raises:
    var root = temp_root()
    var rel = String("tests/test_garbage.mojo")
    var key = _fixture_key(root, rel, "# garbage\n")
    # A generation that EXISTS but does not validate — the shape a killed run
    # leaves behind. Adopting it unchecked is how one corrupt generation spreads
    # to every process that loses a rename against it.
    write_bytes(root, key.gen_dir + "/bin", [UInt8(4)])
    write_bytes(root, key.gen_dir + "/meta", [UInt8(110), UInt8(111)])
    var target = _stage_binary(root, [UInt8(5)])
    var pub = store_publish(
        root, key, target, 1.0, _build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_FAILED)
    # The SPECIFIC warning, because a regression that short-circuited at the
    # source-changed guard — or anywhere else before the rename — would also
    # produce a bare PUB_FAILED and this test would sail past it.
    assert_true(
        "could not publish the cached build" in pub.warning,
        "publication failed somewhere other than the commit: " + pub.warning,
    )
    # THE observable difference between "re-probed the winner and rejected it"
    # and "never looked": only a real re-probe deletes the corrupt generation.
    assert_false(isdir(root + "/" + key.gen_dir))
    # The caller runs the binary it just built, so the staging copy SURVIVES a
    # failed publication; only session end discards it.
    assert_equal(pub.bin_rel, target.out_rel)
    assert_true(exists(root + "/" + target.out_rel))
    # Nothing was published, so the caller's own command line still names a
    # path that exists — it is handed back untouched.
    assert_equal(len(pub.argv), 5)
    assert_equal(pub.argv[3], target.out_rel)


def test_publish_reaps_stale_sibling() raises:
    var root = temp_root()
    var rel = String("tests/test_reap.mojo")
    var old = _fixture_key(root, rel, "# one\n")
    var first = _stage_binary(root, [UInt8(1)])
    assert_equal(
        store_publish(
            root, old, first, 1.0, _build_argv(rel, first.out_rel)
        ).kind,
        PUB_OK,
    )
    var new = _fixture_key(root, rel, "# two\n")
    assert_not_equal(old.gen_name, new.gen_name)
    var second = _stage_binary(root, [UInt8(2)])
    assert_equal(
        store_publish(
            root, new, second, 1.0, _build_argv(rel, second.out_rel)
        ).kind,
        PUB_OK,
    )
    # One live generation per source file: an editing loop must not grow the
    # store without bound.
    assert_false(isdir(root + "/" + old.gen_dir))
    assert_true(isdir(root + "/" + new.gen_dir))


def test_probe_refuses_symlinked_generation() raises:
    var root = temp_root()
    var rel = String("tests/test_link.mojo")
    var key = _fixture_key(root, rel, "# link\n")
    var target = _stage_binary(root, [UInt8(3)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, _build_argv(rel, target.out_rel)
        ).kind,
        PUB_OK,
    )
    assert_equal(store_probe(root, key).kind, PROBE_HIT)
    # Move the VALID generation aside and leave a symlink in its place. A probe
    # that followed the link would still hit — and the same followed link would
    # let the store's remover delete whatever the link names.
    rename_path(root + "/" + key.gen_dir, root + "/decoy")
    symlink(root + "/decoy", root + "/" + key.gen_dir)
    assert_equal(store_probe(root, key).kind, PROBE_MISS)
    # REFUSED, not removed: the link is not the cache's to delete either.
    assert_true(islink(root + "/" + key.gen_dir))
    assert_true(isdir(root + "/decoy"))


def test_publish_refuses_a_source_changed_mid_compile() raises:
    var root = temp_root()
    var rel = String("tests/test_race.mojo")
    var key = _fixture_key(root, rel, "# before\n")
    var target = _stage_binary(root, [UInt8(1)])
    write_file(root, rel, "# after\n")
    var pub = store_publish(
        root, key, target, 1.0, _build_argv(rel, target.out_rel)
    )
    # The binary was compiled from bytes this key does not describe. Publishing
    # it would serve it to a later run whose key still says "before".
    assert_equal(pub.kind, PUB_FAILED)
    assert_true(
        "source changed" in pub.warning,
        "the warning did not name the cause: " + pub.warning,
    )
    assert_false(isdir(root + "/" + key.gen_dir))
    assert_equal(pub.bin_rel, target.out_rel)
    assert_true(exists(root + "/" + target.out_rel))


def test_file_key_tracks_the_source_and_misses_a_vanished_one() raises:
    var root = temp_root()
    var rel = String("tests/test_key.mojo")
    var before = _fixture_key(root, rel, "# before\n")
    var after = _fixture_key(root, rel, "# after\n")
    assert_not_equal(before.digest_full, after.digest_full)
    assert_not_equal(before.src_sha, after.src_sha)
    # `digest32` is a true prefix of the full key, so the two are one digest
    # read at two lengths and can never disagree about which build this is.
    assert_true(after.digest_full.startswith(after.digest32))
    # The generation name keeps the mangled source so a human can read the
    # store; only the digest moves.
    assert_true(after.gen_name.startswith("tests_stest_ukey_h"))
    assert_equal(after.gen_dir, STORE_DIR + "/" + after.gen_name)
    # A source that cannot be read is the one `None`: the caller turns it into
    # a per-file miss and switches the cache off.
    var ctx = CacheContext()
    assert_false(Bool(file_key(ctx, root, "tests/absent.mojo")))


def test_remove_tree_no_follow_refuses_a_symlinked_root() raises:
    var root = temp_root()
    write_file(root, "outside/keep.txt", "k")
    symlink(root + "/outside", root + "/link")
    # Recursing through the link would delete the TARGET's contents. That is the
    # whole reason the store does not reuse `scratch.mojo`'s remover, which
    # never lstats its root and swallows what it cannot delete.
    with assert_raises(contains="symlink"):
        remove_tree_no_follow(root + "/link")
    assert_true(exists(root + "/outside/keep.txt"))
    assert_true(islink(root + "/link"))


def test_remove_tree_no_follow_unlinks_child_symlinks() raises:
    var root = temp_root()
    write_file(root, "outside/keep.txt", "k")
    write_file(root, "doomed/inner/file.txt", "f")
    symlink(root + "/outside", root + "/doomed/link")
    remove_tree_no_follow(root + "/doomed")
    assert_false(exists(root + "/doomed"))
    # The child link was UNLINKED, never traversed.
    assert_true(exists(root + "/outside/keep.txt"))


# --- Configured precompile steps: the per-step key (Task 14) -----------------


def _step_key(
    mut ctx: CacheContext,
    root: String,
    src: String,
    includes: List[String],
    priors: List[String],
    out_path: String,
) raises -> FileKey:
    """Key one precompile step, failing the test if the key could not be built.

    Args:
        ctx: The session context; disabled on any failure, as in production.
        root: The invocation root.
        src: The step's source.
        includes: The include roots the step would be given.
        priors: Every earlier step's output path.
        out_path: This step's output path.

    Returns:
        The step's key.

    Raises:
        Error: If `precompile_key` declined to build one, which every caller
            here treats as a test failure rather than a case to assert on.
    """
    var key = precompile_key(ctx, root, src, includes, priors, out_path)
    if not key:
        raise Error(
            "test: precompile_key failed for '"
            + src
            + "': "
            + ctx.disable_reason
        )
    return key.value().copy()


def _pkg_root() raises -> String:
    """A scratch root holding a one-file package at `pkg/`."""
    var root = temp_root()
    write_file(
        root, "pkg/__init__.mojo", "def helper() -> Int:\n    return 1\n"
    )
    return root^


def test_precompile_key_is_stable_and_tracks_its_source() raises:
    var root = _pkg_root()
    var no_dirs = List[String]()
    var first_ctx = CacheContext()
    var first = _step_key(
        first_ctx, root, "pkg", no_dirs, no_dirs, "build/pkg.mojopkg"
    )
    var again_ctx = CacheContext()
    var again = _step_key(
        again_ctx, root, "pkg", no_dirs, no_dirs, "build/pkg.mojopkg"
    )
    # Byte identity over unchanged inputs is the whole premise: a key that
    # wandered would make every stamp a permanent miss.
    assert_equal(first.digest_full, again.digest_full)
    assert_equal(first.gen_name, again.gen_name)
    # The name is readable and the stamp path is derived from it.
    assert_true(first.gen_name.startswith("pkg_h"))
    assert_equal(first.gen_dir, precompile_stamp_rel(first.gen_name))
    assert_true(first.digest_full.startswith(first.digest32))

    # The source is walked as a package: editing anything inside it moves the
    # key, exactly as it changes what the step would produce.
    write_file(
        root, "pkg/__init__.mojo", "def helper() -> Int:\n    return 2\n"
    )
    var edited_ctx = CacheContext()
    var edited = _step_key(
        edited_ctx, root, "pkg", no_dirs, no_dirs, "build/pkg.mojopkg"
    )
    assert_not_equal(first.digest_full, edited.digest_full)

    # The OUT spelling is part of the step's identity: the same source built to
    # a different package is a different step.
    var moved_ctx = CacheContext()
    var moved = _step_key(
        moved_ctx, root, "pkg", no_dirs, no_dirs, "build/other.mojopkg"
    )
    assert_not_equal(edited.digest_full, moved.digest_full)


def test_precompile_key_keys_a_single_file_source() raises:
    var root = temp_root()
    write_file(root, "lib/helper.mojo", "# one\n")
    var no_dirs = List[String]()
    var before_ctx = CacheContext()
    var before = _step_key(
        before_ctx,
        root,
        "lib/helper.mojo",
        no_dirs,
        no_dirs,
        "build/helper.mojopkg",
    )
    # A single-file source contributes its own bytes rather than a walk, and
    # `src_sha` describes them.
    assert_equal(before.src_sha.byte_length(), 64)
    write_file(root, "lib/helper.mojo", "# two\n")
    var after_ctx = CacheContext()
    var after = _step_key(
        after_ctx,
        root,
        "lib/helper.mojo",
        no_dirs,
        no_dirs,
        "build/helper.mojopkg",
    )
    assert_not_equal(before.digest_full, after.digest_full)


def test_precompile_key_excludes_its_own_output() raises:
    # The circularity the `exclude` parameter exists to break. A step's output
    # ordinarily lands inside a directory that is already an include root, so a
    # key that digested it would describe the step's RESULT: the cold run would
    # key one way, the warm run another, and no stamp could ever be hit.
    var root = _pkg_root()
    var out_path = String("build/pkg.mojopkg")
    write_bytes(root, out_path, [UInt8(1), UInt8(2)])
    write_bytes(root, "build/neighbour.mojopkg", [UInt8(3)])
    var includes: List[String] = ["build"]
    var no_dirs = List[String]()
    var first_ctx = CacheContext()
    var first = _step_key(first_ctx, root, "pkg", includes, no_dirs, out_path)

    # The step's own output changing does NOT move the key.
    write_bytes(root, out_path, [UInt8(9), UInt8(9), UInt8(9)])
    var republished_ctx = CacheContext()
    var republished = _step_key(
        republished_ctx, root, "pkg", includes, no_dirs, out_path
    )
    assert_equal(first.digest_full, republished.digest_full)

    # ...while everything else in that same include root still does, which is
    # what proves the exclusion is narrow and the root really is walked.
    write_bytes(root, "build/neighbour.mojopkg", [UInt8(4)])
    var neighbour_ctx = CacheContext()
    var neighbour = _step_key(
        neighbour_ctx, root, "pkg", includes, no_dirs, out_path
    )
    assert_not_equal(first.digest_full, neighbour.digest_full)


def test_precompile_key_tracks_earlier_step_outputs() raises:
    var root = _pkg_root()
    write_bytes(root, "build/first.mojopkg", [UInt8(1)])
    var no_dirs = List[String]()
    var priors: List[String] = ["build/first.mojopkg"]
    var before_ctx = CacheContext()
    var before = _step_key(
        before_ctx, root, "pkg", no_dirs, priors, "build/pkg.mojopkg"
    )
    # An earlier step's package is on this step's include path, so rebuilding
    # that step must rebuild this one.
    write_bytes(root, "build/first.mojopkg", [UInt8(2)])
    var after_ctx = CacheContext()
    var after = _step_key(
        after_ctx, root, "pkg", no_dirs, priors, "build/pkg.mojopkg"
    )
    assert_not_equal(before.digest_full, after.digest_full)


def test_precompile_key_forks_the_base_not_the_prefix() raises:
    # `prefix` is `base` plus the include walks, and a step's output BECOMES an
    # include root the moment the step succeeds — so keying a step on `prefix`
    # would key it on a walk its own output takes part in. The key must be
    # indifferent to whether `finalize_includes` has run.
    var root = _pkg_root()
    var no_dirs = List[String]()
    var ctx = CacheContext()
    var before = _step_key(
        ctx, root, "pkg", no_dirs, no_dirs, "build/pkg.mojopkg"
    )
    finalize_includes(ctx, root, ["pkg"])
    assert_true(ctx.enabled, "cache off: " + ctx.disable_reason)
    var after = _step_key(
        ctx, root, "pkg", no_dirs, no_dirs, "build/pkg.mojopkg"
    )
    assert_equal(before.digest_full, after.digest_full)


def test_precompile_key_walks_extra_include_dirs() raises:
    var root = _pkg_root()
    write_file(root, "extra/two.mojo", "# two")
    var no_dirs = List[String]()
    var plain_ctx = CacheContext()
    var plain = _step_key(
        plain_ctx, root, "pkg", no_dirs, no_dirs, "build/pkg.mojopkg"
    )
    var extra_ctx = CacheContext()
    extra_ctx.extra_walk_dirs.append("extra")
    var extra = _step_key(
        extra_ctx, root, "pkg", no_dirs, no_dirs, "build/pkg.mojopkg"
    )
    # A `-I` inside `--build-arg` reaches the step exactly like a configured
    # include root, so it has to reach the step's key the same way.
    assert_not_equal(plain.digest_full, extra.digest_full)


def test_precompile_key_disables_on_an_unreadable_source() raises:
    var root = temp_root()
    var no_dirs = List[String]()
    var ctx = CacheContext()
    var key = precompile_key(
        ctx, root, "absent.mojo", no_dirs, no_dirs, "build/absent.mojopkg"
    )
    # A step whose inputs cannot be characterized must RUN, unconditionally,
    # and take the cache down with it.
    assert_false(Bool(key))
    assert_false(ctx.enabled)
    assert_true(
        "absent.mojo" in ctx.disable_reason,
        "reason did not name the source: " + ctx.disable_reason,
    )


def test_precompile_key_disables_on_an_unwalkable_include_root() raises:
    var root = _pkg_root()
    var no_dirs = List[String]()
    var includes: List[String] = ["nowhere"]
    var ctx = CacheContext()
    var key = precompile_key(
        ctx, root, "pkg", includes, no_dirs, "build/pkg.mojopkg"
    )
    assert_false(Bool(key))
    assert_false(ctx.enabled)
    assert_true(
        "nowhere" in ctx.disable_reason,
        "reason did not name the include root: " + ctx.disable_reason,
    )


def test_precompile_key_disables_on_an_unreadable_prior_output() raises:
    var root = _pkg_root()
    var no_dirs = List[String]()
    var priors: List[String] = ["build/vanished.mojopkg"]
    var ctx = CacheContext()
    var key = precompile_key(
        ctx, root, "pkg", no_dirs, priors, "build/pkg.mojopkg"
    )
    assert_false(Bool(key))
    assert_false(ctx.enabled)
    assert_true(
        "vanished" in ctx.disable_reason,
        "reason did not name the earlier output: " + ctx.disable_reason,
    )


def test_precompile_key_declines_for_a_disabled_context() raises:
    var root = _pkg_root()
    var no_dirs = List[String]()
    var ctx = CacheContext()
    ctx.disable("earlier cause")
    var key = precompile_key(
        ctx, root, "pkg", no_dirs, no_dirs, "build/pkg.mojopkg"
    )
    assert_false(Bool(key))
    # The FIRST cause is the actionable one; keying an off cache must not bury
    # it under a second reason.
    assert_equal(ctx.disable_reason, "earlier cause")


def test_precompile_stamp_round_trips_and_guards_its_output() raises:
    var root = _pkg_root()
    var out_path = String("build/pkg.mojopkg")
    write_bytes(root, out_path, [UInt8(1), UInt8(2), UInt8(3)])
    var no_dirs = List[String]()
    var ctx = CacheContext()
    var key = _step_key(ctx, root, "pkg", no_dirs, no_dirs, out_path)

    # Cold: no stamp, no skip.
    assert_false(precompile_probe(root, key, out_path))

    precompile_publish(root, key, out_path)
    var stamp_rel = precompile_stamp_rel(key.gen_name)
    assert_true(exists(root + "/" + stamp_rel))
    assert_true(
        stamp_rel.startswith(STORE_DIR + "/" + PRECOMPILE_SUBDIR + "/"),
        "the stamp escaped the store: " + stamp_rel,
    )
    assert_true(precompile_probe(root, key, out_path))

    # A stamp is a claim ABOUT an artifact, never a substitute for it: the
    # output lives in the user's tree, where a stray build can reach it.
    write_bytes(root, out_path, [UInt8(9)])
    assert_false(precompile_probe(root, key, out_path))
    # ...and the record that outlived its output is gone, so the next probe
    # cannot re-read it.
    assert_false(exists(root + "/" + stamp_rel))

    # A vanished output is a miss too, not a crash.
    precompile_publish(root, key, out_path)
    remove(root + "/" + out_path)
    assert_false(precompile_probe(root, key, out_path))
    assert_false(precompile_probe(root, key, out_path))


def test_precompile_publish_reaps_the_steps_stale_stamps() raises:
    var root = _pkg_root()
    var out_path = String("build/pkg.mojopkg")
    write_bytes(root, out_path, [UInt8(1)])
    var no_dirs = List[String]()
    var first_ctx = CacheContext()
    var first = _step_key(first_ctx, root, "pkg", no_dirs, no_dirs, out_path)
    precompile_publish(root, first, out_path)

    # A new key for the same step: an editing loop produces one per edit.
    write_file(
        root, "pkg/__init__.mojo", "def helper() -> Int:\n    return 3\n"
    )
    var second_ctx = CacheContext()
    var second = _step_key(second_ctx, root, "pkg", no_dirs, no_dirs, out_path)
    assert_not_equal(first.gen_name, second.gen_name)
    precompile_publish(root, second, out_path)

    var stamps = dir_listing(root + "/" + STORE_DIR + "/" + PRECOMPILE_SUBDIR)
    assert_equal(len(stamps), 1, "the superseded stamp was not reaped")
    assert_equal(stamps[0], second.gen_name)


# --- Configured precompile steps: the invocation oracle (Task 14) ------------

comptime _COUNTING_MOJO = "/scripts/fixtures/toolchain/counting_mojo.py"
"""The invocation-counting compiler shim, relative to the repository root."""

comptime _COUNTER_REL = ".mtest-precompile-invocations"
"""Where that shim appends one line per `mojo precompile` it was started for."""


def _precompile_invocations(root: String) raises -> Int:
    """How many times the compiler was started for a precompile step under
    `root`.

    The ONE honest oracle for "the step was skipped". A result field saying so
    is written by the code under test, so a bug that sets the field and compiles
    anyway would read as a pass; a process that never started cannot be faked.
    `counting_mojo.py` appends one line per `mojo precompile` invocation to a
    counter in its current directory, and mtest runs every compile child with
    the invocation root as its current directory, so the counter is this run's
    own and nothing outside `root` can move it.

    Args:
        root: The invocation root the sessions ran in.

    Returns:
        The number of recorded invocations; 0 when the counter does not exist,
        which is what a run that never started a precompile leaves behind.

    Raises:
        Error: If the counter exists but cannot be read.
    """
    var path = root + "/" + _COUNTER_REL
    if not exists(path):
        return 0
    var data = read_regular_file_bytes(path, 1 << 20)
    var lines = 0
    for b in data:
        if b == UInt8(10):
            lines += 1
    return lines


def _counting_config() raises -> RunnerConfig:
    """A base config whose compiler is the invocation-counting shim."""
    var config = base_config()
    config.mojo_path = getenv("PIXI_PROJECT_ROOT", "") + _COUNTING_MOJO
    config.precompiles.append(Precompile("goodpkg", None))
    return config^


def test_unchanged_precompile_step_is_not_recompiled() raises:
    # The headline claim, proven by invocation count rather than by any field
    # mtest reports about itself: a configured precompile step whose inputs and
    # whose output are both unchanged does not start the compiler a second time,
    # and every way that premise can break brings the compiler straight back.
    var root = temp_root()
    write_file(
        root, "goodpkg/__init__.mojo", "def helper() -> Int:\n    return 7\n"
    )
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    var config = _counting_config()

    # --- Cold: the step must run. -------------------------------------------
    var cold = run_recording_session(config, root)
    assert_equal(cold.code, 0, "a clean step plus a passing file is exit 0")
    assert_equal(
        _precompile_invocations(root), 1, "the cold run must build the step"
    )
    assert_equal(cold.built_files, 1, "the test file was compiled")
    assert_equal(
        cold.cached_files, 0, "nothing could be served from a cold store"
    )

    # --- Warm: the step must NOT run. ---------------------------------------
    var warm = run_recording_session(config, root)
    assert_equal(warm.code, 0, "a warm run is still exit 0")
    assert_equal(
        _precompile_invocations(root),
        1,
        (
            "the warm run started the compiler for an unchanged precompile"
            " step; the stamp did not skip it"
        ),
    )
    # The cache really was on — otherwise the count above would be trivially
    # unchanged only because nothing ran at all.
    assert_equal(warm.cached_files, 1, "the test file came from the store")
    # A skipped step is not a compile admission: `built_files + cached_files`
    # counts FIRST-ATTEMPT TEST FILE compiles, and precompile sits outside that
    # invariant entirely, skipped or run.
    assert_equal(warm.built_files, 0, "a skipped step is not an admission")

    # --- The output removed: the stamp must not survive its artifact. -------
    remove(root + "/build/goodpkg.mojopkg")
    var restored = run_recording_session(config, root)
    assert_equal(restored.code, 0)
    assert_equal(
        _precompile_invocations(root),
        2,
        (
            "a stamp whose output is gone must not skip the step: the probe"
            " checks the artifact, not just the key"
        ),
    )
    assert_true(exists(root + "/build/goodpkg.mojopkg"))

    # --- The source edited: the key must move. ------------------------------
    write_file(
        root, "goodpkg/__init__.mojo", "def helper() -> Int:\n    return 8\n"
    )
    var edited = run_recording_session(config, root)
    assert_equal(edited.code, 0)
    assert_equal(
        _precompile_invocations(root),
        3,
        "an edited step source must rebuild the step",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
