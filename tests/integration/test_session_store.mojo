"""Integration tests for the session store, its scaffolding, and its key inputs.

A classified module is its own program, so this one compiles the whole
`mtest.session` import closure by itself and a runner with no compiler cache
pays for that closure once per module rather than once per run. That is why the
store's key inputs are gathered here instead of being spread over a module
each: the sections below are separate subjects sharing one compilation.

**Source order is load-bearing at the end of this file.** `_TOOLCHAIN_MEMO` and
`_TOOLCHAIN_LIB_MEMO` are process-lifetime single slots keyed on a path and a
byte count, so the first case in a process that keys the compiler on PATH reads
and hashes the pinned toolchain executable and everything shipped beside it,
and every later case keying the same compiler answers out of those slots for
free. One case keying a stub or the wrapper evicts both. `TestSuite` runs a
module's tests in the order this file declares them, so every real-toolchain
case is declared LAST and CONTIGUOUSLY, after every stub and wrapper case, and
the whole module reads and hashes the real compiler exactly once. Moving one of
them above a stub case, or introducing a stub case between two of them, buys a
second full read and hash of a compiler upwards of a hundred megabytes, digested
in Mojo compiled without optimization -- the largest single item a suite in this
family can carry, and one that has timed this family out before.

Everything above that final block therefore keys a stub it stands up itself or
the transparent wrapper `session_fixtures.base_config` names, on purpose: their
subject is the store's own behavior rather than the pinned toolchain's layout,
and a stub or a wrapper proves that just as well for nothing.
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

from mtest.cache import ImportScan, KeyBuilder, scan_imports
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
    STORE_FAULT_ENV,
    STORE_DIR,
    CacheContext,
    FileKey,
    StoreBuildTarget,
    _MEMO_PATH_CAP,
    _ToolchainMemo,
    _discard_unreadable_generation,
    _toolchain_identity,
    cache_key_tags,
    clear_cache_root,
    collect_env_base,
    ensure_cache_root,
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

from cache_fixtures import (
    RecordedRun,
    base_digest,
    chmod_path,
    dir_listing,
    env_base,
    executable_stub,
    make_executable,
    run_recording_session,
    write_bytes,
)
from session_fixtures import (
    SRC_PASS,
    base_config,
    real_toolchain_config,
    write_file,
)
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


# --- The toolchain memo's fixed-width record ---------------------------------
#
# `_ToolchainMemo` is what the process-lifetime memo slot holds, and it is
# fixed-width so that slot owns no allocation to leak. Everything below is pure
# in-memory logic: no compiler is read, and nothing here spawns.


comptime _HEX64 = (
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
)
"""A well-formed 64-character digest rendering, standing in for a real one."""


# --- CacheContext: construction, disabling, and the env base -----------------


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


# --- CacheContext: finalize_includes -----------------------------------------


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


# --- The store: staging, probe, publish, adopt, and reap ---------------------


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

    The staged file is given the execute bit, because that is what `mojo build`
    leaves at `-o` and what a generation has to carry to be runnable. A probe
    checks it, so a payload without it would stand in for something the compiler
    never produces and every publish-then-hit case here would miss.

    Args:
        root: The invocation root.
        payload: The bytes standing in for a compiled binary.

    Returns:
        The staging target, with its `bin` already written and executable.

    Raises:
        Error: If the store could not stage a target.
    """
    var target = store_build_target(root, _mangle("tests/test_staged.mojo"))
    if not target.ok():
        raise Error("test: store_build_target produced no staging directory")
    write_bytes(root, target.out_rel, payload)
    make_executable(root + "/" + target.out_rel)
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


def test_a_cache_root_made_for_state_alone_is_still_marked() raises:
    """The directory mtest creates is always one mtest can prove it owns.

    `.mtest-cache` holds the last-run reselection state as well as the store,
    and the state is written whether the cache is on or off — so the directory
    can come into existence with no generation ever staged into it. Tying the
    marker to staging left that shape unmarked, and `--cache-clear` then refused
    to delete a tree this same binary had created moments earlier.
    """
    var root = temp_root()

    ensure_cache_root(root)

    assert_true(isdir(root + "/.mtest-cache"))
    assert_false(
        isdir(root + "/" + STORE_DIR),
        "no build was staged, so no store belongs here",
    )
    var tag = read_bounded_regular_file(
        root + "/.mtest-cache/CACHEDIR.TAG", 4096
    )
    assert_true(tag.is_regular)
    assert_true(
        tag.text.startswith("Signature: 8a477f597d28d172789f06886806bc55"),
        "the tag did not lead with the standard signature: " + tag.text,
    )
    # The ownership proof and the marker writer have to agree byte for byte, or
    # the directory is marked and still unclearable.
    assert_false(
        Bool(clear_cache_root(root)),
        "a directory mtest marked itself must clear without a refusal",
    )
    assert_false(exists(root + "/.mtest-cache"))


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


def test_probe_rejects_a_bin_that_lost_its_execute_bit() raises:
    var root = temp_root()
    var rel = String("tests/test_unrunnable.mojo")
    var key = _fixture_key(root, rel, "# unrunnable\n")
    var target = _stage_binary(root, [UInt8(1), UInt8(2), UInt8(3)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, _build_argv(rel, target.out_rel)
        ).kind,
        PUB_OK,
    )
    assert_equal(store_probe(root, key).kind, PROBE_HIT)

    # An archive restore, a `docker COPY`, or a `chmod -R` over the checkout
    # drops the mode bits while leaving every byte intact, so the content digest
    # still matches and only the permission has moved.
    chmod_path("600", root + "/" + key.gen_dir + "/bin")

    # A generation that cannot be spawned is not a usable generation. Reporting
    # it as a hit hands the runner a path it cannot execute, which surfaces as an
    # internal error on a run that would otherwise have passed.
    assert_equal(store_probe(root, key).kind, PROBE_MISS)
    # And it resolves like every other corruption: the generation is deleted, so
    # the next run rebuilds instead of failing again on the same artifact
    # forever.
    assert_false(isdir(root + "/" + key.gen_dir))
    assert_equal(store_probe(root, key).kind, PROBE_MISS)


def test_probe_heals_an_unreadable_generation() raises:
    var root = temp_root()
    var rel = String("tests/test_unreadable.mojo")
    var key = _fixture_key(root, rel, "# unreadable\n")
    var first = _stage_binary(root, [UInt8(1), UInt8(2), UInt8(3)])
    assert_equal(
        store_publish(
            root, key, first, 1.0, _build_argv(rel, first.out_rel)
        ).kind,
        PUB_OK,
    )

    # A cache directory can survive a permissions-damaging archive restore or
    # manual repair. It must not occupy this generation's final name forever:
    # the first probe misses, then the replacement publishes and the next probe
    # hits as if the unreadable directory had never existed.
    chmod_path("000", root + "/" + key.gen_dir)
    assert_equal(store_probe(root, key).kind, PROBE_MISS)
    var replacement = _stage_binary(root, [UInt8(4), UInt8(5), UInt8(6)])
    assert_equal(
        store_publish(
            root, key, replacement, 1.0, _build_argv(rel, replacement.out_rel)
        ).kind,
        PUB_OK,
    )
    assert_equal(store_probe(root, key).kind, PROBE_HIT)


def test_unreadable_healer_leaves_a_readable_replacement_alone() raises:
    var root = temp_root()
    var rel = String("tests/test_replacement.mojo")
    var key = _fixture_key(root, rel, "# replacement\n")
    var target = _stage_binary(root, [UInt8(7), UInt8(8), UInt8(9)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, _build_argv(rel, target.out_rel)
        ).kind,
        PUB_OK,
    )

    # A concurrent publisher may replace the unreadable directory after the
    # detecting probe has returned. The healer must re-check the final name and
    # leave that readable replacement runnable rather than moving it aside.
    _discard_unreadable_generation(
        root + "/" + key.gen_dir, root + "/" + STORE_DIR
    )
    assert_equal(store_probe(root, key).kind, PROBE_HIT)


def test_unreadable_healer_restores_a_replacement_raced_before_quarantine() raises:
    var root = temp_root()
    var rel = String("tests/test_raced_replacement.mojo")
    var key = _fixture_key(root, rel, "# raced replacement\n")
    var target = _stage_binary(root, [UInt8(10), UInt8(11), UInt8(12)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, _build_argv(rel, target.out_rel)
        ).kind,
        PUB_OK,
    )
    var store_abs = root + "/" + STORE_DIR
    var replacement = store_abs + "/.tmp-unreadable-replacement"
    rename_path(root + "/" + key.gen_dir, replacement)
    makedirs(root + "/" + key.gen_dir)
    chmod_path("000", root + "/" + key.gen_dir)

    # The fault installs the valid replacement after the helper has observed
    # the unreadable directory but before the helper claims its quarantine.
    # That exact interleaving used to move the replacement into a tombstone and
    # immediately delete it.
    var saved = getenv(STORE_FAULT_ENV, "")
    var was_set = getenv(STORE_FAULT_ENV, "\x01unset") != "\x01unset"
    try:
        _ = setenv(STORE_FAULT_ENV, "unreadable-replacement", True)
        _discard_unreadable_generation(root + "/" + key.gen_dir, store_abs)
    finally:
        if was_set:
            _ = setenv(STORE_FAULT_ENV, saved, True)
        else:
            _ = unsetenv(STORE_FAULT_ENV)
    assert_equal(store_probe(root, key).kind, PROBE_HIT)


def test_unreadable_healer_restores_after_tombstone_inspection_failure() raises:
    """A failed identity read puts the moved generation back at its final path.
    """
    var root = temp_root()
    var rel = String("tests/test_tombstone_lstat.mojo")
    var key = _fixture_key(root, rel, "# tombstone lstat\n")
    var target = _stage_binary(root, [UInt8(13), UInt8(14), UInt8(15)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, _build_argv(rel, target.out_rel)
        ).kind,
        PUB_OK,
    )

    # The helper has already moved this directory when its identity inspection
    # faults. It must restore the original rather than strand the only
    # generation under a private tombstone and leave the final path absent.
    var final_abs = root + "/" + key.gen_dir
    chmod_path("000", final_abs)
    var saved = getenv(STORE_FAULT_ENV, "")
    var was_set = getenv(STORE_FAULT_ENV, "\x01unset") != "\x01unset"
    try:
        _ = setenv(STORE_FAULT_ENV, "unreadable-tombstone-lstat", True)
        _discard_unreadable_generation(final_abs, root + "/" + STORE_DIR)
    finally:
        if was_set:
            _ = setenv(STORE_FAULT_ENV, saved, True)
        else:
            _ = unsetenv(STORE_FAULT_ENV)

    assert_true(
        isdir(final_abs),
        "the identity-read failure must not leave the final generation absent",
    )
    chmod_path("755", final_abs)
    assert_equal(store_probe(root, key).kind, PROBE_HIT)


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
        src_dir=key.src_dir,
        dir_sha=key.dir_sha,
        dir_full=key.dir_full,
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


def test_probe_refuses_a_symlinked_binary_inside_a_generation() raises:
    """The no-follow discipline has to reach the thing that gets executed.

    A generation directory can be a perfectly real directory, with a record
    naming this exact key and a digest of whatever `bin` resolves to, while
    `bin` itself is a link to a binary outside the checkout. The probe then
    reports a hit and mtest runs that outside binary, which is free to emit a
    valid PASS report. Characterizing the directory without following links and
    then following one to reach its binary stops one level short.
    """
    var root = temp_root()
    var rel = String("tests/test_binlink.mojo")
    var key = _fixture_key(root, rel, "# binlink\n")
    var target = _stage_binary(root, [UInt8(3)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, _build_argv(rel, target.out_rel)
        ).kind,
        PUB_OK,
    )
    assert_equal(store_probe(root, key).kind, PROBE_HIT)

    # The binary moves outside the store and a link takes its place. Everything
    # else about the generation stays exactly as the cache wrote it, so the
    # record still names this key and still records the digest of the bytes the
    # link resolves to.
    write_bytes(root, "outside/bin", [UInt8(3)])
    chmod_path("755", root + "/outside/bin")
    remove(root + "/" + key.gen_dir + "/bin")
    symlink(root + "/outside/bin", root + "/" + key.gen_dir + "/bin")
    assert_equal(store_probe(root, key).kind, PROBE_MISS)
    # Deleted like any other corruption inside a generation the cache owns —
    # and the removal unlinks the child link rather than descending it, so what
    # it pointed at is still there.
    assert_false(isdir(root + "/" + key.gen_dir))
    assert_true(exists(root + "/outside/bin"))


def test_reaping_leaves_a_name_this_store_could_not_have_written() raises:
    """A sibling is a generation of this source, not merely a name near one.

    Reaping matched the mangled source name and the `_h` separator and deleted
    whatever followed. Nothing this store writes has anything but 32 hex digits
    there, so a name that does not is a directory somebody else put in the
    store, and deleting it is not the cache's to do.
    """
    var root = temp_root()
    var rel = String("tests/test_suffix.mojo")
    var key = _fixture_key(root, rel, "# suffix\n")
    var mangled = _mangle(rel)
    var foreign = STORE_DIR + "/" + mangled + "_hnotadigest"
    var short = STORE_DIR + "/" + mangled + "_h0123456789abcdef"
    write_bytes(root, foreign + "/keep", [UInt8(1)])
    write_bytes(root, short + "/keep", [UInt8(2)])
    var target = _stage_binary(root, [UInt8(3)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, _build_argv(rel, target.out_rel)
        ).kind,
        PUB_OK,
    )
    assert_true(
        isdir(root + "/" + foreign),
        "a name with no digest after `_h` was reaped as a generation",
    )
    assert_true(
        isdir(root + "/" + short),
        "a name with a short digest after `_h` was reaped as a generation",
    )


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


def test_publish_refuses_a_helper_changed_mid_compile() raises:
    """A build input beside the test moved, so the artifact is not this key's.

    The entry source is one of the file's inputs, not all of them: the compiler
    resolves a bare import against the source's own directory, so a helper there
    is as much a build input as the test itself and moves in the same window.

    What makes it worth refusing rather than tolerating is that the damage
    outlives the edit. The binary is compiled from the helper's new bytes while
    the key still describes the old ones, so undoing the edit — an ordinary
    thing to do — leaves a tree that looks untouched and a stored artifact that
    was never built from it. Every later run over that tree hits.
    """
    var root = temp_root()
    var rel = String("tests/test_uses_helper.mojo")
    write_file(root, "tests/helper.mojo", "# before\n")
    var key = _fixture_key(root, rel, "# entry\n")
    var target = _stage_binary(root, [UInt8(1)])
    write_file(root, "tests/helper.mojo", "# after\n")

    var pub = store_publish(
        root, key, target, 1.0, _build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_FAILED)
    # The specific cause: the entry source never moved, so a guard that only
    # re-read that file would report PUB_OK here and this test would pass on
    # the wrong mechanism if it checked the kind alone.
    assert_true(
        "changed" in pub.warning and "beside" in pub.warning,
        "the warning did not name the cause: " + pub.warning,
    )
    assert_false(isdir(root + "/" + key.gen_dir))
    # A refusal is never a failure of the run: the caller keeps running exactly
    # what it built.
    assert_equal(pub.bin_rel, target.out_rel)
    assert_true(exists(root + "/" + target.out_rel))


def test_publish_accepts_an_untouched_directory() raises:
    """The guard must refuse a moved input and nothing else.

    A walk that disagreed with itself over an unchanged directory would refuse
    every publication, turning the cache into a pure cost — and every existing
    hit test would still pass, since they publish from directories holding one
    file. This one holds a helper the walk has to frame identically twice.
    """
    var root = temp_root()
    var rel = String("tests/test_stable.mojo")
    write_file(root, "tests/stable_helper.mojo", "# unchanged\n")
    var key = _fixture_key(root, rel, "# entry\n")
    var target = _stage_binary(root, [UInt8(1)])
    var pub = store_publish(
        root, key, target, 1.0, _build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_OK, "warning: " + pub.warning)
    assert_true(isdir(root + "/" + key.gen_dir))


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


def _keyed(root: String, rel: String) raises -> String:
    """The full key one file gets under a fresh context.

    A fresh context per call is the point: the per-directory walk is memoized,
    so reusing one would answer the second call from the first call's reading of
    a directory that has since changed.

    Args:
        root: The invocation root.
        rel: The test file's root-relative path.

    Returns:
        The 64-hex key.

    Raises:
        Error: If the file could not be keyed at all.
    """
    var ctx = CacheContext()
    var key = file_key(ctx, root, rel)
    if not key:
        raise Error("test: file_key failed for '" + rel + "'")
    return String(key.value().digest_full)


def test_file_key_covers_a_helper_beside_the_source() raises:
    """A module in the source's own directory is a build input, and is keyed.

    `mojo build tests/test_x.mojo` resolves a bare `from helper import ...` out
    of `tests/`, with no `-I` involved. A key blind to that directory serves a
    binary compiled against the previous helper.
    """
    var root = temp_root()
    write_file(root, "tests/helper.mojo", "# helper v1\n")
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    var before = _keyed(root, "tests/test_x.mojo")
    write_file(root, "tests/helper.mojo", "# helper v2\n")
    assert_not_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "the helper the compiler can reach changed, so the key must move",
    )


def test_file_key_ignores_a_test_sibling_nothing_imports() raises:
    """A discovered test file beside the source is left out of its key.

    Each such file is an entry point already keyed by its own source frame, so
    folding it into its neighbours would make one edit rebuild the whole
    directory — the cost that would make the cache worthless for the
    edit-one-file loop it exists to speed up.
    """
    var root = temp_root()
    write_file(root, "tests/helper.mojo", "# helper\n")
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    write_file(root, "tests/test_y.mojo", SRC_PASS)
    var before = _keyed(root, "tests/test_x.mojo")
    write_file(root, "tests/test_y.mojo", "# a different suite entirely\n")
    assert_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "a neighbour nothing imports cannot change this file's build",
    )


def test_file_key_covers_a_test_sibling_the_source_imports() raises:
    """Omitting test siblings is abandoned for a source that imports one."""
    var root = temp_root()
    write_file(root, "tests/test_y.mojo", "# neighbour v1\n")
    write_file(root, "tests/test_x.mojo", "from test_y import thing\n")
    var before = _keyed(root, "tests/test_x.mojo")
    write_file(root, "tests/test_y.mojo", "# neighbour v2\n")
    assert_not_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "the source imports the neighbour, so the neighbour is an input",
    )


def test_file_key_ignores_a_test_sibling_only_a_neighbour_imports() raises:
    """One test file importing another does not cost the rest their precision.

    A keyed file's own imports speak for that file alone. `test_b` reaching
    `test_c` means `test_b` keys over the whole directory; it says nothing about
    what `test_a` compiles against, so `test_a` keeps the omission and an edit
    to `test_c` leaves it in the store.

    This is the difference between scanning the file being keyed and escalating
    the whole directory. Escalating here would be sound but pointless, and its
    cost is real: `test_helpers.mojo` beside `test_session.mojo` is an everyday
    layout, and one such pair would put every unrelated test in the directory
    back on the unomitted walk for good.
    """
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", "from test_c import thing\n")
    write_file(root, "tests/test_c.mojo", "# neighbour v1\n")
    var before = _keyed(root, "tests/test_a.mojo")
    write_file(root, "tests/test_c.mojo", "# neighbour v2\n")
    assert_equal(
        before,
        _keyed(root, "tests/test_a.mojo"),
        "only the file that imported the neighbour keys over it",
    )
    # ...and the file that DID import it moved, or the omission would be a hole
    # rather than a precision choice.
    var b_before = _keyed(root, "tests/test_b.mojo")
    write_file(root, "tests/test_c.mojo", "# neighbour v3\n")
    assert_not_equal(
        b_before,
        _keyed(root, "tests/test_b.mojo"),
        "the importer must key over the neighbour it named",
    )


def test_file_key_covers_an_unreadable_test_sibling_its_importer_names() raises:
    """An omitted sibling is covered by the name that reaches it, not by itself.

    Omitted files are never scanned, and they never need to be: the match runs
    on the IMPORTER's side, against the directory's omitted names. So a sibling
    whose own bytes could not be scanned at all — here an embedded NUL, the
    plainest "this is not source text" — still invalidates the file that names
    it, because nothing about the sibling was ever consulted to decide that.
    """
    var root = temp_root()
    write_bytes(
        root,
        "tests/test_y.mojo",
        [UInt8(35), UInt8(0), UInt8(118), UInt8(49), UInt8(10)],
    )
    write_file(root, "tests/test_x.mojo", "from test_y import thing\n")
    var before = _keyed(root, "tests/test_x.mojo")
    write_bytes(
        root,
        "tests/test_y.mojo",
        [UInt8(35), UInt8(0), UInt8(118), UInt8(50), UInt8(10)],
    )
    assert_not_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "the importer named it, so it is an input whatever its bytes are",
    )


def test_file_key_covers_a_test_sibling_a_helper_imports() raises:
    """The same proof runs one hop out, over the helpers the walk does frame.

    A helper that imports a test file puts that file back on the compiler's
    path for everything importing the helper, so the omission is unsafe for the
    whole directory even though no test file names the neighbour itself.
    """
    var root = temp_root()
    write_file(root, "tests/test_y.mojo", "# neighbour v1\n")
    write_file(root, "tests/helper.mojo", "from test_y import thing\n")
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    var before = _keyed(root, "tests/test_x.mojo")
    write_file(root, "tests/test_y.mojo", "# neighbour v2\n")
    assert_not_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "a helper reaches the neighbour, so the neighbour is an input here too",
    )


def test_file_key_covers_the_directory_when_a_source_cannot_be_scanned() raises:
    """A file whose imports cannot be read proves nothing, so nothing is
    omitted.

    The embedded NUL is the plainest case: those bytes are not source text, so
    the scanner refuses to say what they import rather than reporting that they
    import nothing. Refusing has to cost a wider key, never a narrower one.
    """
    var root = temp_root()
    write_file(root, "tests/test_y.mojo", "# neighbour v1\n")
    write_bytes(
        root,
        "tests/helper.mojo",
        [UInt8(35), UInt8(0), UInt8(35), UInt8(10)],
    )
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    var before = _keyed(root, "tests/test_x.mojo")
    write_file(root, "tests/test_y.mojo", "# neighbour v2\n")
    assert_not_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "an unscannable helper cannot license leaving the neighbour out",
    )


def _keyed_with_includes(
    root: String, rel: String, includes: List[String]
) raises -> String:
    """The full key one file gets under a context carrying include roots.

    Args:
        root: The invocation root.
        rel: The test file's root-relative path.
        includes: The include roots the session would pass as `-I`.

    Returns:
        The 64-hex key.

    Raises:
        Error: If the file could not be keyed at all.
    """
    var ctx = CacheContext()
    finalize_includes(ctx, root, includes)
    var key = file_key(ctx, root, rel)
    if not key:
        raise Error("test: file_key failed for '" + rel + "'")
    return String(key.value().digest_full)


def test_file_key_covers_a_test_sibling_an_include_root_module_imports() raises:
    """The omission proof reaches through the include roots too.

    `-I support` frames `libhelper.mojo`'s bytes, but not what those bytes
    IMPORT. `test_peer.mojo` is a discovered test file, so the walk of the test
    directory leaves it out — and the entry file never names it, so nothing on
    the keyed file's own side escalates either. Without reading the include
    root's sources, editing `test_peer.mojo` would move no keyed region at all
    and `test_main.mojo` could serve a binary compiled against the old one.
    """
    var root = temp_root()
    write_file(root, "tests/test_main.mojo", "from libhelper import thing\n")
    write_file(root, "tests/test_peer.mojo", "# neighbour v1\n")
    write_file(root, "support/libhelper.mojo", "from test_peer import thing\n")
    var includes: List[String] = [String("support")]

    var before = _keyed_with_includes(root, "tests/test_main.mojo", includes)
    write_file(root, "tests/test_peer.mojo", "# neighbour v2\n")
    assert_not_equal(
        before,
        _keyed_with_includes(root, "tests/test_main.mojo", includes),
        (
            "a module under an include root reaches the omitted neighbour, so"
            " the neighbour is an input"
        ),
    )


def test_an_include_root_import_leaves_unrelated_directories_precise() raises:
    """Escalation follows the NAME, so it stops at the directories that omit it.

    The include root names `test_peer`, which only `tests/` leaves out. A
    directory with no such name keeps the omission and its ordinary one-file
    edit-and-rerun loop: widening every directory in the session because one
    library imported one test module would trade the whole feature for the
    proof.
    """
    var root = temp_root()
    write_file(root, "tests/test_main.mojo", SRC_PASS)
    write_file(root, "tests/test_peer.mojo", "# neighbour v1\n")
    write_file(root, "other/test_alpha.mojo", SRC_PASS)
    write_file(root, "other/test_beta.mojo", "# unrelated v1\n")
    write_file(root, "support/libhelper.mojo", "from test_peer import thing\n")
    var includes: List[String] = [String("support")]

    var before = _keyed_with_includes(root, "other/test_alpha.mojo", includes)
    write_file(root, "other/test_beta.mojo", "# unrelated v2\n")
    assert_equal(
        before,
        _keyed_with_includes(root, "other/test_alpha.mojo", includes),
        "a directory the include root never names keeps its precise key",
    )


def test_an_unscannable_include_root_source_widens_every_omission() raises:
    """A source under `-I` whose imports cannot be read could name anything.

    The scan is what licenses leaving a directory's test files out, so a
    library the scanner refuses to read withdraws that licence everywhere —
    the same direction every other refusal takes, and for the same reason.
    """
    var root = temp_root()
    write_file(root, "tests/test_main.mojo", SRC_PASS)
    write_file(root, "tests/test_peer.mojo", "# neighbour v1\n")
    write_bytes(
        root,
        "support/libhelper.mojo",
        [UInt8(35), UInt8(0), UInt8(35), UInt8(10)],
    )
    var includes: List[String] = [String("support")]

    var before = _keyed_with_includes(root, "tests/test_main.mojo", includes)
    write_file(root, "tests/test_peer.mojo", "# neighbour v2\n")
    assert_not_equal(
        before,
        _keyed_with_includes(root, "tests/test_main.mojo", includes),
        "an unreadable library cannot license leaving a neighbour out",
    )


def test_a_test_directory_that_cannot_be_walked_disables_the_cache() raises:
    """A directory the walk cannot characterize takes the cache off with it.

    Same posture as an include root behind a symlinked package: the directory is
    a search path, its contents are build inputs, and a key that cannot cover
    them must not be written. The reason names the directory so the message is
    something to act on rather than a bare refusal.
    """
    var root = temp_root()
    write_file(root, "elsewhere/__init__.mojo", "# a package\n")
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    symlink(root + "/elsewhere", root + "/tests/pkg")
    var ctx = CacheContext()
    assert_false(
        Bool(file_key(ctx, root, "tests/test_x.mojo")),
        "an uncharacterizable directory has no key",
    )
    assert_false(ctx.enabled, "and it must switch the cache off")
    assert_true(
        "test directory 'tests'" in ctx.disable_reason,
        "the reason must name the directory: " + ctx.disable_reason,
    )
    assert_true(
        "directory symlink" in ctx.disable_reason,
        "and what about it could not be walked: " + ctx.disable_reason,
    )


def _scanned(text: String) -> ImportScan:
    """Scan a source given as text.

    Args:
        text: The source.

    Returns:
        The scan of its bytes.
    """
    var data = List[UInt8]()
    for b in text.as_bytes():
        data.append(b)
    return scan_imports(data)


def test_import_scanning_reads_the_forms_a_key_depends_on() raises:
    """The shapes the scanner understands, and the ones it refuses to guess at.

    Every refusal costs a wider key and never a narrower one, so this pins the
    direction as much as the cases: `parsed` False must never be reachable by
    something that would let a build input out of the key.
    """
    var plain = _scanned("from helper import value\n")
    assert_true(plain.parsed)
    assert_equal(len(plain.modules), 1)
    assert_equal(plain.modules[0], "helper")

    var dotted = _scanned("import pkg.mod as m, other\n")
    assert_true(dotted.parsed)
    assert_equal(len(dotted.modules), 2)
    assert_equal(dotted.modules[0], "pkg")
    assert_equal(dotted.modules[1], "other")

    # A docstring and a comment are erased before the line is read, so prose
    # about importing is not an import — nor a reason to refuse.
    var prose = _scanned(
        '"""One layer never imports another.\nAnd from a to b."""\n'
        "# from x import y\n"
        "from real import thing\n"
    )
    assert_true(prose.parsed)
    assert_equal(len(prose.modules), 1)
    assert_equal(prose.modules[0], "real")

    # An import hiding after a statement separator: understood well enough to
    # know it is there, not well enough to say what it names.
    assert_false(_scanned("x = 1; import y\n").parsed)
    # The same separator, on the far side of a `from` statement. What follows
    # `import` on a `from` line ordinarily names symbols and is not examined, so
    # this is the one place a second statement could pass unread.
    assert_false(_scanned("from helper import value; import peer\n").parsed)
    assert_false(_scanned("from a import b; from c import d\n").parsed)
    # A second statement that cannot name a module keeps the precise key.
    var trailing = _scanned("from helper import value; x = 1\n")
    assert_true(trailing.parsed)
    assert_equal(len(trailing.modules), 1)
    assert_equal(trailing.modules[0], "helper")
    # A form this scanner does not model.
    assert_false(_scanned("from . import sibling\n").parsed)
    # A statement continued onto the next line.
    assert_false(_scanned("import a, \\\n    b\n").parsed)
    # A literal left open, so the file does not lex at all.
    assert_false(_scanned('var s = "open\n').parsed)


def test_import_scanning_refuses_bytes_that_are_not_utf8() raises:
    """A source that is not UTF-8 is refused instead of tokenized.

    Any byte at or above 0x80 counts as an identifier byte, so a Latin-1 module
    name or a half-written multi-byte sequence would otherwise be read as a
    token. The scanner exists to decide whether a key may be narrow, and a file
    whose bytes it cannot read is exactly the case where it may not be.
    """
    var latin1 = List[UInt8]()
    for b in "import caf".as_bytes():
        latin1.append(b)
    # 'é' as Latin-1: a lone continuation-range byte, never valid UTF-8.
    latin1.append(0xE9)
    latin1.append(UInt8(ord("\n")))
    assert_false(
        scan_imports(latin1).parsed,
        "a Latin-1 module name must refuse, not tokenize",
    )

    var truncated = List[UInt8]()
    for b in "import a".as_bytes():
        truncated.append(b)
    # A two-byte sequence whose continuation byte never arrived.
    truncated.append(0xC3)
    truncated.append(UInt8(ord("\n")))
    assert_false(
        scan_imports(truncated).parsed,
        "a truncated multi-byte sequence must refuse",
    )

    # The refusal is about malformed bytes, not about non-ASCII names: a module
    # name that IS valid UTF-8 still scans, and still reports its own spelling.
    var accented = _scanned("import café\n")
    assert_true(accented.parsed, "a valid UTF-8 module name still scans")
    assert_equal(len(accented.modules), 1)
    assert_equal(accented.modules[0], "café")


def test_import_scanning_reads_past_a_byte_order_mark() raises:
    """A source opening with a UTF-8 BOM still has its imports read.

    Every byte at or above 0x80 is an identifier byte, so the three bytes an
    editor writes to mark a file as UTF-8 glue themselves onto whatever token
    follows. `import helper` on the first line lexed as one token that is
    neither `import` nor `from`, matched no whole `import` token either, and the
    line came back understood with nothing found — the one answer this scanner
    may never give wrongly, since the caller then keys a file whose helper is
    not in the key.
    """
    var marked = List[UInt8]()
    marked.append(0xEF)
    marked.append(0xBB)
    marked.append(0xBF)
    for b in "import helper\n".as_bytes():
        marked.append(b)
    var scan = scan_imports(marked)
    assert_true(scan.parsed, "a marked source is ordinary UTF-8 and must scan")
    assert_equal(len(scan.modules), 1, "and its import must be reported")
    assert_equal(scan.modules[0], "helper")

    # The same on a `from` line, which takes the other branch of the dispatch.
    var from_marked = List[UInt8]()
    from_marked.append(0xEF)
    from_marked.append(0xBB)
    from_marked.append(0xBF)
    for b in "from helper import value\n".as_bytes():
        from_marked.append(b)
    var from_scan = scan_imports(from_marked)
    assert_true(from_scan.parsed)
    assert_equal(len(from_scan.modules), 1)
    assert_equal(from_scan.modules[0], "helper")

    # Only a LEADING mark is a mark. The same bytes in the middle of a file are
    # a zero-width no-break space inside an identifier, which is a token this
    # scanner cannot read as a keyword and must not read as ordinary code.
    var interior = List[UInt8]()
    for b in "x = 1\n".as_bytes():
        interior.append(b)
    interior.append(0xEF)
    interior.append(0xBB)
    interior.append(0xBF)
    for b in "import helper\n".as_bytes():
        interior.append(b)
    assert_false(
        scan_imports(interior).parsed,
        "an import glued to an invisible character is not understood",
    )


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


# --- Configured precompile steps: the per-step key ---------------------------


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


def test_precompile_key_covers_a_single_file_sources_siblings() raises:
    """A module beside the named file is an input the step's key must cover.

    The compiler resolves a bare import against the source file's own
    directory, so `lib/sibling.mojo` is compiled into the package `lib/pkg.mojo`
    produces. Keying only the named file left the step's stamp unmoved by an
    edit to the sibling, and a stamp that still validates skips the compile —
    after which every test binary built against the stale package can hit too.
    """
    var root = temp_root()
    write_file(root, "lib/pkg.mojo", "from sibling import value\n")
    write_file(root, "lib/sibling.mojo", "def value() -> Int:\n    return 1\n")
    var no_dirs = List[String]()
    var before_ctx = CacheContext()
    var before = _step_key(
        before_ctx,
        root,
        "lib/pkg.mojo",
        no_dirs,
        no_dirs,
        "build/pkg.mojopkg",
    )

    write_file(root, "lib/sibling.mojo", "def value() -> Int:\n    return 2\n")
    var after_ctx = CacheContext()
    var after = _step_key(
        after_ctx,
        root,
        "lib/pkg.mojo",
        no_dirs,
        no_dirs,
        "build/pkg.mojopkg",
    )
    assert_not_equal(
        before.digest_full,
        after.digest_full,
        "editing a module beside the step's source must move the step's key",
    )

    # A file the compiler cannot reach from there is not an input, and adding
    # one must not move the key: the walk covers what `-I` on that directory
    # makes visible, not everything on disk.
    write_file(root, "lib/notes.txt", "unrelated\n")
    var noise_ctx = CacheContext()
    var noise = _step_key(
        noise_ctx,
        root,
        "lib/pkg.mojo",
        no_dirs,
        no_dirs,
        "build/pkg.mojopkg",
    )
    assert_equal(after.digest_full, noise.digest_full)


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
    # An include root that EXISTS but cannot be characterized is a build input
    # this key cannot represent, so it still takes the cache down — unlike one
    # that is merely absent, which a step is expected to create.
    var root = _pkg_root()
    write_file(root, "inc/top.mojo", "# a")
    var no_dirs = List[String]()
    var includes: List[String] = ["inc"]
    var ctx = CacheContext()
    chmod_path("000", root + "/inc")
    # No `try`/`finally`: `precompile_key` is non-raising by contract, so the
    # restore below is unconditionally reached.
    var key = precompile_key(
        ctx, root, "pkg", includes, no_dirs, "build/pkg.mojopkg"
    )
    chmod_path("755", root + "/inc")
    assert_false(Bool(key))
    assert_false(ctx.enabled)
    assert_true(
        "inc" in ctx.disable_reason,
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


def test_precompile_key_frames_an_absent_include_root() raises:
    # The ordinary `-I build` shape has a precompile step CREATE the include
    # root, so on a cold tree it does not exist when the step is keyed.
    # Disabling there would cost the whole session its cache on the first run of
    # a legitimate config — but absent still may not key like present-and-empty,
    # or a directory that later grew contents would serve a stale hit.
    var root = _pkg_root()
    var no_dirs = List[String]()
    var includes: List[String] = ["build"]
    var cold_ctx = CacheContext()
    var cold = _step_key(
        cold_ctx, root, "pkg", includes, no_dirs, "build/pkg.mojopkg"
    )
    assert_true(cold_ctx.enabled, "cache off: " + cold_ctx.disable_reason)

    # Present and empty is a DIFFERENT state from absent.
    makedirs(root + "/build")
    var empty_ctx = CacheContext()
    var empty = _step_key(
        empty_ctx, root, "pkg", includes, no_dirs, "build/pkg.mojopkg"
    )
    assert_true(empty_ctx.enabled, "cache off: " + empty_ctx.disable_reason)
    assert_not_equal(cold.digest_full, empty.digest_full)

    # ...and so is present with contents, so a root that fills up takes a miss.
    write_bytes(root, "build/other.mojopkg", [UInt8(7)])
    var filled_ctx = CacheContext()
    var filled = _step_key(
        filled_ctx, root, "pkg", includes, no_dirs, "build/pkg.mojopkg"
    )
    assert_not_equal(empty.digest_full, filled.digest_full)
    assert_not_equal(cold.digest_full, filled.digest_full)

    # An include root that EXISTS but cannot be characterized still disables: a
    # plain file where a directory belongs is an input this key cannot cover.
    var file_root = _pkg_root()
    write_file(file_root, "build", "not a directory\n")
    var file_ctx = CacheContext()
    var refused = precompile_key(
        file_ctx, file_root, "pkg", includes, no_dirs, "build/pkg.mojopkg"
    )
    assert_false(Bool(refused))
    assert_false(file_ctx.enabled)
    assert_true(
        "build" in file_ctx.disable_reason,
        "reason did not name the include root: " + file_ctx.disable_reason,
    )


def test_precompile_probe_refuses_a_symlinked_stamp() raises:
    # `store_probe` refuses a symlink at the generation path and leaves it
    # exactly where it is; the two probes must not disagree about that at the
    # same structural position. Re-digesting the output means a followed link
    # cannot serve stale bytes TODAY — this pins that the asymmetry is closed
    # before some later change starts depending on it.
    var root = _pkg_root()
    var out_path = String("build/pkg.mojopkg")
    write_bytes(root, out_path, [UInt8(1), UInt8(2)])
    var no_dirs = List[String]()
    var ctx = CacheContext()
    var key = _step_key(ctx, root, "pkg", no_dirs, no_dirs, out_path)

    # A perfectly valid stamp, moved aside and replaced by a link to itself.
    precompile_publish(root, key, out_path)
    var stamp_abs = root + "/" + precompile_stamp_rel(key.gen_name)
    assert_true(precompile_probe(root, key, out_path))
    var elsewhere = root + "/elsewhere-stamp"
    rename_path(stamp_abs, elsewhere)
    symlink(elsewhere, stamp_abs)

    assert_false(
        precompile_probe(root, key, out_path),
        "a symlinked stamp was followed",
    )
    # Refused, never removed: a link the cache did not create is not the
    # cache's to delete, and deleting it would hide whoever planted it.
    assert_true(islink(stamp_abs))
    assert_true(exists(elsewhere))


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


# --- Configured precompile steps: the invocation oracle ----------------------

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


def _cache_off_reasons(run: RecordedRun) raises -> List[String]:
    """Every `cache-off` warning a recorded run emitted, in emission order."""
    var reasons = List[String]()
    for entry in run.warnings:
        var warning = String(entry)
        if warning.startswith("cache-off:"):
            reasons.append(warning)
    return reasons^


def test_cold_tree_include_root_created_by_a_step_keeps_the_cache_on() raises:
    # The `-I build` shape: a configured include root that a precompile step
    # itself creates. On a COLD tree it does not exist when the step is keyed,
    # and treating that as a failure to characterize took the whole session's
    # cache down on the first run of a legitimate config — the run on which
    # people decide whether the feature is worth having.
    var root = temp_root()
    write_file(
        root, "goodpkg/__init__.mojo", "def helper() -> Int:\n    return 7\n"
    )
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    var config = _counting_config()
    config.include_paths = ["build"]
    assert_false(exists(root + "/build"), "the tree must start cold")

    # --- Run 1: cold, and the cache must stay ON. ---------------------------
    var first = run_recording_session(config, root)
    assert_equal(first.code, 0)
    assert_equal(
        len(_cache_off_reasons(first)),
        0,
        (
            "an include root a step had not created yet switched the whole"
            " session's cache off"
        ),
    )
    assert_equal(_precompile_invocations(root), 1)
    assert_equal(first.built_files, 1, "the file was compiled and published")
    assert_true(exists(root + "/build"), "step 1 created the include root")

    # --- Run 2: one re-key, by design. --------------------------------------
    # Absent and present-but-empty are deliberately DIFFERENT states — a root
    # that later grew contents must take a miss, not a stale hit — so the step
    # is keyed afresh exactly once as the tree stops being cold.
    var second = run_recording_session(config, root)
    assert_equal(second.code, 0)
    assert_equal(len(_cache_off_reasons(second)), 0)
    assert_equal(
        _precompile_invocations(root),
        2,
        "the absent-to-present transition re-keys the step exactly once",
    )

    # --- Run 3: converged, and now the store serves. ------------------------
    var third = run_recording_session(config, root)
    assert_equal(third.code, 0)
    assert_equal(len(_cache_off_reasons(third)), 0)
    assert_equal(
        _precompile_invocations(root),
        2,
        "the step must be skipped once the include root has settled",
    )
    # `mojo precompile` is not byte-deterministic, so a step that RERUNS
    # rewrites its package and moves the session prefix every file keys from.
    # Skipping the step is therefore what makes the file cache hit at all in a
    # config that precompiles anything.
    assert_equal(third.cached_files, 1, "the test file came from the store")
    assert_equal(third.built_files, 0)


# --- What an env base frames about the toolchain. ----------------------------
#
# The toolchain is a build input, and the key has to say so. Nothing in this
# section keys the toolchain executable itself: three cases stand up a stub
# whose layout they control outright, and
# `test_env_base_frames_the_compiler_selection_environment` is about an
# environment variable and holds over any compiler, so it takes the wrapper
# `session_fixtures.base_config` names.


def test_env_base_frames_a_toolchain_without_a_library_directory() raises:
    """A layout with no `lib/mojo` beside the compiler keys, it does not fail.

    A `--mojo` spelling that names a wrapper script somewhere else in the tree
    is the ordinary case here, and nothing beside it looks like a toolchain.
    The compiler's own digest still identifies it, so the absence is a fact to
    record rather than a reason to switch the cache off.
    """
    var root = temp_root()
    var stub = executable_stub(root, "tc/bin/mojo")
    var config = base_config()
    config.mojo_path = stub
    var ctx = env_base(config^, root)
    assert_true(ctx.enabled, "cache off: " + ctx.disable_reason)


def test_env_base_disables_when_the_toolchain_libraries_cannot_be_read() raises:
    """A library directory that will not open is a question, not an absence.

    The two have to lead in opposite directions: a toolchain with no library
    directory keys perfectly well, while one whose libraries this process
    cannot read is a build input the key cannot represent, so the cache goes
    off. A single `isdir` answers False to both, which let an unreadable
    directory key as though the toolchain shipped no libraries at all.

    The path is closed at the PARENT, which is what makes the case sharp: the
    directory can then be neither listed nor even stat'd, so nothing about the
    path itself can separate it from a directory that was never there.
    """
    var root = temp_root()
    var stub = executable_stub(root, "tc/bin/mojo")
    write_file(root, "tc/lib/mojo/std.mojopkg", "# stands in for a library")
    var config = base_config()
    config.mojo_path = stub
    chmod_path("000", root + "/tc/lib")
    var ctx = env_base(config^, root)
    chmod_path("755", root + "/tc/lib")
    assert_false(
        ctx.enabled, "an unreadable library directory must disable the cache"
    )
    assert_true(
        "lib/mojo" in ctx.disable_reason,
        "reason did not name the directory: " + ctx.disable_reason,
    )


def test_env_base_frames_every_entry_of_the_library_directory() raises:
    """What ships beside the compiler's packages is toolchain too.

    Framing only the two extensions the packages happen to use left the shared
    objects, resource files, and anything else a toolchain drops in that
    directory outside the key, so replacing one of them left every stored
    generation valid. An extension list is also a guess that goes stale the
    next time the toolchain ships something new.
    """
    var root = temp_root()
    var stub = executable_stub(root, "tc/bin/mojo")
    write_file(root, "tc/lib/mojo/std.mojopkg", "# stands in for a package")
    write_file(root, "tc/lib/mojo/libsupport.so", "# one")
    var config = base_config()
    config.mojo_path = stub
    var before = env_base(config^, root)
    assert_true(before.enabled, "cache off: " + before.disable_reason)

    # A different length as well as different bytes: the content digest is
    # memoized per process on the directory's total byte count, so a
    # same-length edit inside one process is the case that memo does not see.
    write_file(root, "tc/lib/mojo/libsupport.so", "# two, and longer")
    var second = base_config()
    second.mojo_path = stub
    var after = env_base(second^, root)
    assert_true(after.enabled, "cache off: " + after.disable_reason)
    assert_not_equal(
        base_digest(before),
        base_digest(after),
        "a library outside the package extensions must still be keyed",
    )

    # An entry appearing moves the key without anything being read: names and
    # types are framed on every collection.
    write_file(root, "tc/lib/mojo/extra.dat", "# three")
    var third = base_config()
    third.mojo_path = stub
    var grown = env_base(third^, root)
    assert_true(grown.enabled, "cache off: " + grown.disable_reason)
    assert_not_equal(base_digest(after), base_digest(grown))


def test_env_base_frames_the_compiler_selection_environment() raises:
    """A variable that picks a tool the compiler invokes belongs in the key.

    `MODULAR_NVPTX_COMPILER_PATH` selects the NVIDIA assembler, and a build
    child inherits it. Two runs that differ only there are not the same build,
    so a warm entry from one of them must not answer for the other.
    """
    var root = temp_root()
    var name = String("MODULAR_NVPTX_COMPILER_PATH")
    var was_set = getenv(name, "\x01unset") != "\x01unset"
    var saved = getenv(name, "")
    var digests = List[String]()
    try:
        _ = unsetenv(name)
        digests.append(base_digest(env_base(base_config(), root)))
        _ = setenv(name, "/opt/ptxas-here", True)
        digests.append(base_digest(env_base(base_config(), root)))
        _ = setenv(name, "/opt/ptxas-there", True)
        digests.append(base_digest(env_base(base_config(), root)))
    finally:
        if was_set:
            _ = setenv(name, saved, True)
        else:
            _ = unsetenv(name)
    assert_equal(len(digests), 3)
    assert_not_equal(digests[0], digests[1])
    assert_not_equal(digests[0], digests[2])
    assert_not_equal(digests[1], digests[2])


# --- The toolchain memo record, from below. ----------------------------------
#
# What the record can hold, what it refuses, and what it discriminates on. The
# end-to-end property the record exists for is asserted over the real compiler
# in the final section, where its payment is shared.


def test_toolchain_memo_starts_matching_nothing() raises:
    # The empty slot every process starts with. If it ever matched, the first
    # lookup in a process would answer with a digest nobody computed.
    var empty = _ToolchainMemo()
    assert_false(empty.matches("/usr/bin/mojo", 141))
    assert_false(empty.matches("", 0))


def test_toolchain_memo_round_trips_a_stored_digest() raises:
    var stored = _ToolchainMemo.of("/usr/bin/mojo", 141, _HEX64)
    assert_true(stored, "a plain path and digest were refused")
    var memo = stored.value().copy()
    assert_true(memo.matches("/usr/bin/mojo", 141))
    # The rebuilt string is the property a hit rests on: a memoized run and a
    # cold run must frame identical bytes, so the digest has to come back
    # character for character.
    assert_equal(memo.sha_hex(), _HEX64)


def test_toolchain_memo_discriminates_path_and_size() raises:
    var memo = _ToolchainMemo.of("/usr/bin/mojo", 141, _HEX64).value().copy()
    # Size is the field that catches a toolchain swap changing the binary's
    # length; path is the field that catches a different compiler entirely.
    assert_false(memo.matches("/usr/bin/mojo", 142))
    assert_false(memo.matches("/usr/local/bin/mojo", 141))
    # A prefix and an extension of the stored path are both misses: the
    # comparison is on the whole path, not on what fits.
    assert_false(memo.matches("/usr/bin/moj", 141))
    assert_false(memo.matches("/usr/bin/mojoo", 141))


def test_toolchain_memo_refuses_what_it_cannot_hold_exactly() raises:
    # Every refusal costs one recomputation and nothing else. Truncating instead
    # is what would be dangerous: two compilers sharing a long prefix would
    # start matching each other.
    var long_path = String("/")
    while long_path.byte_length() <= _MEMO_PATH_CAP:
        long_path += "abcdefgh"
    assert_false(
        Bool(_ToolchainMemo.of(long_path, 141, _HEX64)),
        "an over-long path was stored rather than refused",
    )
    assert_false(
        Bool(_ToolchainMemo.of("", 141, _HEX64)),
        "an empty path was stored, forging the empty-slot marker",
    )
    assert_false(
        Bool(_ToolchainMemo.of("/usr/bin/mojo", 141, "abc")),
        "a short digest was stored rather than refused",
    )
    assert_false(
        Bool(_ToolchainMemo.of("/usr/bin/mojo", 141, _HEX64 + "0")),
        "an over-long digest was stored rather than refused",
    )
    # The longest path that still fits is stored, so the refusal is a boundary
    # and not an off-by-one that quietly shrinks the memo.
    var exact = String("/")
    while exact.byte_length() < _MEMO_PATH_CAP:
        exact += "a"
    var stored = _ToolchainMemo.of(exact, 141, _HEX64)
    assert_true(stored, "a path of exactly the capacity was refused")
    assert_true(stored.value().matches(exact, 141))


def test_a_relative_compiler_resolves_against_the_run_root() raises:
    """The key must name the compiler the build child will actually execute.

    A spelling containing `/` is never PATH-searched — it is taken verbatim
    against a working directory — and the two processes involved do not share
    one. The build child `chdir`s to the run root before `execve`, while mtest
    resolves in its own. Against a root that is not mtest's own directory,
    `tools/mojo` therefore named one file in the key and ran another.

    The observable form of the divergence: the compiler exists under the root
    and nowhere near mtest's working directory, so resolving in the wrong place
    finds nothing at all and turns the cache off.
    """
    var root = temp_root()
    _ = executable_stub(root, "tools/mojo")
    var config = base_config()
    config.mojo_path = String("tools/mojo")

    var ctx = env_base(config^, root)
    assert_true(
        ctx.enabled,
        "the cache was disabled over a compiler that is right there: "
        + ctx.disable_reason,
    )


# --- Refusals that never reach a compiler at all. ----------------------------
#
# Whether a config collects a base is the same question the section below
# answers the other way, and these three answer it before anything is read: an
# argument the key cannot represent, a compiler that does not resolve, and a
# file an argument names that is not there.


def test_env_base_disables_on_unknown_arg() raises:
    var root = temp_root()
    var config = base_config()
    config.build_args = ["--sysroot=/x"]
    var ctx = env_base(config^, root)
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
    var ctx = env_base(config^, root)
    assert_false(ctx.enabled)
    assert_true(
        "mtest-absent-compiler" in ctx.disable_reason,
        "reason did not name the compiler: " + ctx.disable_reason,
    )


def test_env_base_disables_on_missing_arg_file() raises:
    var root = temp_root()
    var config = base_config()
    config.build_args = ["-Xlinker", "absent.o"]
    var ctx = env_base(config^, root)
    assert_false(ctx.enabled)
    assert_true(
        "absent.o" in ctx.disable_reason,
        "reason did not name the token: " + ctx.disable_reason,
    )


# --- LAST AND CONTIGUOUS: the cases whose subject IS the real toolchain. -----
#
# Everything from here down keys the compiler on PATH through
# `session_fixtures.real_toolchain_config` or resolves it by name, so the first
# case below reads and hashes that executable and the library directory beside
# it, and every case after it answers out of the process-lifetime memos that
# read populated. Nothing keying a stub or the wrapper may be declared between
# them or after them: either eviction makes this module read and hash the whole
# compiler a second time. See this module's docstring for why that matters, and
# `session_fixtures.base_config` for why every other case avoids it.
#
# What the section asserts is the frame no wrapper can stand in for. A digest
# that fails to move when a build input changes is the one failure a cache must
# never have, so each case changes exactly one input and demands a different
# key, and keying the real toolchain is what puts the library directory shipped
# beside the compiler into every one of those digests.


def test_env_base_enabled_for_the_real_toolchain() raises:
    # The bare `mojo` spelling is the contract default, so this is the shape a
    # user's first run takes: PATH resolution, the compiler's own digest, the
    # version banner, and the library directory shipped beside it all have to
    # come back before a key exists at all. Nothing here stands in for any of
    # them — a stub would prove the layout of the stub.
    var root = temp_root()
    var ctx = env_base(real_toolchain_config(), root)
    assert_true(ctx.enabled, "cache off: " + ctx.disable_reason)
    assert_equal(ctx.disable_reason, "")
    assert_false(ctx.warned)
    assert_equal(ctx.built_files, 0)
    assert_equal(ctx.cached_files, 0)
    assert_equal(len(ctx.extra_walk_dirs), 0)


def test_toolchain_identity_memoizes_the_same_answer() raises:
    # The end-to-end property, over the real compiler: the second call must
    # answer identically to the first. A memo that returned anything else would
    # move the key bytes between two sessions of one process.
    var resolved = resolve_executable("mojo")
    assert_true(resolved, "the pinned compiler did not resolve")
    var path = resolved.value()
    var first = _toolchain_identity(path)
    var second = _toolchain_identity(path)
    assert_true(first, "the compiler could not be read")
    assert_true(second, "the memoized lookup failed")
    assert_equal(first.value().path, second.value().path)
    assert_equal(first.value().size, second.value().size)
    assert_equal(first.value().sha_hex, second.value().sha_hex)


def test_env_base_digest_is_stable_across_calls() raises:
    var root = temp_root()
    var first = env_base(real_toolchain_config(), root)
    var second = env_base(real_toolchain_config(), root)
    assert_true(first.enabled, "cache off: " + first.disable_reason)
    assert_true(second.enabled, "cache off: " + second.disable_reason)
    # THE property every future cache hit rests on. If two collections over
    # unchanged inputs ever disagree — an unsorted listing, an absolute path
    # leaking into a frame, a memo returning something other than what it
    # replaced — the cache degrades to a rebuild every time and nothing else in
    # the suite would notice.
    assert_equal(base_digest(first), base_digest(second))


def test_env_base_digest_moves_with_build_args() raises:
    var root = temp_root()
    var plain = env_base(real_toolchain_config(), root)
    var one = real_toolchain_config()
    one.build_args = ["-O2"]
    var flagged = env_base(one^, root)
    assert_true(flagged.enabled, "cache off: " + flagged.disable_reason)
    assert_not_equal(base_digest(plain), base_digest(flagged))

    var forward = real_toolchain_config()
    forward.build_args = ["-O2", "--no-optimization"]
    var backward = real_toolchain_config()
    backward.build_args = ["--no-optimization", "-O2"]
    # Frame ORDER inside field 7: the same two flags in the other order are a
    # different command line and must be a different key.
    assert_not_equal(
        base_digest(env_base(forward^, root)),
        base_digest(env_base(backward^, root)),
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
        digests.append(base_digest(env_base(real_toolchain_config(), root)))
        _ = setenv("MODULAR_HOME", "/tmp/mtest-modular-there", True)
        digests.append(base_digest(env_base(real_toolchain_config(), root)))
        _ = unsetenv("MODULAR_HOME")
        digests.append(base_digest(env_base(real_toolchain_config(), root)))
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
        base_digest(env_base(real_toolchain_config(), here)),
        base_digest(env_base(real_toolchain_config(), there)),
    )


def test_env_base_records_include_dir_args() raises:
    var root = temp_root()
    write_file(root, "extra/top.mojo", "# a")
    var config = real_toolchain_config()
    config.build_args = ["-I", "extra"]
    var ctx = env_base(config^, root)
    assert_true(ctx.enabled, "cache off: " + ctx.disable_reason)
    assert_equal(len(ctx.extra_walk_dirs), 1)
    assert_equal(ctx.extra_walk_dirs[0], "extra")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
