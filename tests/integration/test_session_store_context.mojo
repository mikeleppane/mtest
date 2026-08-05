"""The session's cache state: the tag namespace, the env base, and the prefix.

Covers `mtest.session.store.context` and the `mtest.session.store.tags`
namespace it feeds from: what disabling remembers, that no tag can forge a frame
boundary, what an env base frames about the toolchain, what the include prefix
is sensitive to, and what the process-lifetime toolchain memo record can hold.

**Source order is load-bearing at the end of this file.** `_TOOLCHAIN_MEMO` and
`_TOOLCHAIN_LIB_MEMO` are process-lifetime single slots keyed on a path and a
byte count, so the first case in a process that keys the compiler on PATH reads
and hashes the pinned toolchain executable and everything shipped beside it, and
every later case keying the same compiler answers out of those slots for free.
One case keying a stub or the wrapper evicts both. `TestSuite` runs a module's
tests in the order this file declares them, so every real-toolchain case is
declared LAST and CONTIGUOUSLY, after every stub and wrapper case, and the whole
module reads and hashes the real compiler exactly once. Moving one of them above
a stub case, or introducing a stub case between two of them, buys a second full
read and hash of a compiler upwards of a hundred megabytes, digested in Mojo
compiled without optimization -- the largest single item a suite in this family
can carry, and one that has timed this family out before.

Everything above that final block therefore keys a stub it stands up itself or
the transparent wrapper `session_fixtures.base_config` names, on purpose: their
subject is the store's own behavior rather than the pinned toolchain's layout,
and a stub or a wrapper proves that just as well for nothing.
"""
from std.os import getenv, setenv, unsetenv
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from mtest.cache import unsafe_tag_reason
from mtest.platform import resolve_executable
from mtest.session.store.context import (
    CacheContext,
    refuse_unsafe_tags,
    _MEMO_PATH_CAP,
    _ToolchainMemo,
    _toolchain_identity,
    finalize_includes,
)
from mtest.session.store.tags import cache_key_tags

from cache_fixtures import base_digest, chmod_path, env_base, executable_stub
from session_fixtures import base_config, real_toolchain_config, write_file
from tmptree import temp_root


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
    """The registered set passes the same check `collect_env_base` applies.

    The rules live in `mtest.cache` beside the `feed` and `feed_file` that
    impose them, so this asserts the SET rather than restating them.
    Uniqueness is only answerable over a whole set and has no per-tag rule to
    share, so it stays here.
    """
    var tags = cache_key_tags()
    assert_true(len(tags) > 0)
    assert_equal(unsafe_tag_reason(tags), "")
    for i in range(len(tags)):
        for j in range(i + 1, len(tags)):
            assert_not_equal(
                tags[i], tags[j], "duplicate tag '" + tags[i] + "'"
            )


def test_an_unframeable_tag_switches_the_cache_off() raises:
    """A namespace that cannot key safely takes the fail-closed channel.

    `collect_env_base` runs this over `cache_key_tags()` before it hashes or
    spawns anything, so a tag that would make two builds key alike costs a
    rebuild instead of serving a stale binary. Neither `feed` nor `feed_file`
    can refuse one itself: both are total by contract, as is every caller of
    theirs in the store's key path.
    """
    var nul = CacheContext()
    assert_true(refuse_unsafe_tags(nul, ["root", String("a\x00b")]))
    assert_false(nul.enabled)
    assert_equal(nul.disable_reason, "cache key tag 1 contains a NUL byte")
    assert_false(nul.warned)

    var reserved = CacheContext()
    assert_true(refuse_unsafe_tags(reserved, ["source.sha"]))
    assert_false(reserved.enabled)
    assert_equal(
        reserved.disable_reason,
        "cache key tag 'source.sha' ends in the reserved '.sha' suffix",
    )

    var clean = CacheContext()
    assert_false(refuse_unsafe_tags(clean, cache_key_tags()))
    assert_true(clean.enabled)


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


comptime _HEX64 = (
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
)
"""A well-formed 64-character digest rendering, standing in for a real one."""


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
    assert_equal(
        ctx.disable_reason,
        "cache cannot characterize -Xlinker argument 'absent.o'",
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
