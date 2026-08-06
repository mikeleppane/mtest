"""Configured precompile steps: the per-step key and the invocation oracle.

Covers `mtest.session.store.stamps`: what a step's key forks from and covers,
when a stamp is withheld because an input churned under the compile, and — over
a counting stand-in for the compiler — that an unchanged step is not run a
second time.

Every case here keys a stub or the counting stand-in: none reads the pinned
toolchain, so none populates the process-lifetime toolchain memos.
"""
from std.os import getenv, makedirs, remove, symlink
from std.os.path import exists, islink
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from mtest.config import Precompile, RunnerConfig
from mtest.platform import read_regular_file_bytes, rename_path
from mtest.session.store.artifact import FileKey
from mtest.session.store.context import CacheContext, finalize_includes
from mtest.session.store.filesystem import STORE_DIR
from mtest.session.store.stamps import (
    PRECOMPILE_SUBDIR,
    precompile_key,
    precompile_probe,
    precompile_publish,
    precompile_stamp_rel,
)

from cache_fixtures import (
    RecordedRun,
    chmod_path,
    dir_listing,
    run_recording_session,
    write_bytes,
)
from session_fixtures import SRC_PASS, base_config, write_file
from store_fixtures import mutate_until_witnessed
from tmptree import temp_root


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


def _stamp_exists(root: String, key: FileKey) raises -> Bool:
    """Whether the step's stamp was written at all.

    The sharper question than `precompile_probe`, which also answers False for
    a stamp that exists and disagrees — a step that was never stamped and one
    stamped against the wrong output are different outcomes.

    Args:
        root: The invocation root.
        key: The step's key.

    Returns:
        True if a stamp file sits at this key's stamp path.
    """
    return exists(root + "/" + precompile_stamp_rel(key.gen_name))


def test_a_stamp_is_withheld_when_a_step_source_churned() raises:
    """A restored single-file source must not stamp the step as clean.

    The stamp records the pre-build key and digests only the OUTPUT, so an
    input edited while the step ran and restored afterwards matched the stamp
    forever — and every dependent binary compiled against the stale package,
    on every later session, with nothing to notice it.
    """
    var root = temp_root()
    write_file(root, "lib/helper.mojo", "# one\n")
    var out_path = String("build/helper.mojopkg")
    write_bytes(root, out_path, [UInt8(1)])
    var no_dirs = List[String]()
    var ctx = CacheContext()
    var key = _step_key(
        ctx, root, "lib/helper.mojo", no_dirs, no_dirs, out_path
    )
    var source = root + "/lib/helper.mojo"
    mutate_until_witnessed(source, "# other\n")
    mutate_until_witnessed(source, "# one\n")

    precompile_publish(root, key, out_path)
    assert_false(
        _stamp_exists(root, key),
        "a step whose source churned was stamped as clean",
    )
    assert_false(precompile_probe(root, key, out_path))


def test_a_stamp_is_withheld_when_a_dir_source_file_churned() raises:
    """Same, for a file inside a directory-shaped step source."""
    var root = _pkg_root()
    var out_path = String("build/pkg.mojopkg")
    write_bytes(root, out_path, [UInt8(1)])
    var no_dirs = List[String]()
    var ctx = CacheContext()
    var key = _step_key(ctx, root, "pkg", no_dirs, no_dirs, out_path)
    var inner = root + "/pkg/__init__.mojo"
    var original = String("def helper() -> Int:\n    return 1\n")
    mutate_until_witnessed(inner, "def helper() -> Int:\n    return 9\n")
    mutate_until_witnessed(inner, original)

    precompile_publish(root, key, out_path)
    assert_false(
        _stamp_exists(root, key),
        "a step whose package source churned was stamped as clean",
    )


def test_a_stamp_is_withheld_when_an_include_file_churned() raises:
    """Same, for a file under one of the step's include roots."""
    var root = _pkg_root()
    write_file(root, "inc/lib.mojo", "# lib\n")
    var out_path = String("build/pkg.mojopkg")
    write_bytes(root, out_path, [UInt8(1)])
    var no_dirs = List[String]()
    var includes: List[String] = ["inc"]
    var ctx = CacheContext()
    var key = _step_key(ctx, root, "pkg", includes, no_dirs, out_path)
    var included = root + "/inc/lib.mojo"
    mutate_until_witnessed(included, "# other\n")
    mutate_until_witnessed(included, "# lib\n")

    precompile_publish(root, key, out_path)
    assert_false(
        _stamp_exists(root, key),
        "a step whose include root churned was stamped as clean",
    )


def test_a_stamp_is_withheld_when_a_prior_output_churned() raises:
    """Same, for an earlier step's output this step consumes.

    An earlier step's package is on this step's include path, so it is an
    input of this step however it was produced.
    """
    var root = _pkg_root()
    var out_path = String("build/pkg.mojopkg")
    write_bytes(root, out_path, [UInt8(1)])
    write_file(root, "build/earlier.mojopkg", "# earlier\n")
    var no_dirs = List[String]()
    var priors: List[String] = ["build/earlier.mojopkg"]
    var ctx = CacheContext()
    var key = _step_key(ctx, root, "pkg", no_dirs, priors, out_path)
    var earlier = root + "/build/earlier.mojopkg"
    mutate_until_witnessed(earlier, "# other\n")
    mutate_until_witnessed(earlier, "# earlier\n")

    precompile_publish(root, key, out_path)
    assert_false(
        _stamp_exists(root, key),
        "a step whose prior output churned was stamped as clean",
    )


def test_a_stamp_is_written_for_an_untouched_step() raises:
    """The no-op control: capture alone must not break stamping.

    All four input classes are present and none of them moves, so a capture
    that cannot reproduce itself would leave every configured step permanently
    unstamped and recompiling — the failure mode that costs the most and
    announces itself the least.
    """
    var root = _pkg_root()
    write_file(root, "inc/lib.mojo", "# lib\n")
    write_file(root, "build/earlier.mojopkg", "# earlier\n")
    var out_path = String("build/pkg.mojopkg")
    write_bytes(root, out_path, [UInt8(1)])
    var includes: List[String] = ["inc"]
    var priors: List[String] = ["build/earlier.mojopkg"]
    var ctx = CacheContext()
    var key = _step_key(ctx, root, "pkg", includes, priors, out_path)

    precompile_publish(root, key, out_path)
    assert_true(_stamp_exists(root, key), "an untouched step was not stamped")
    assert_true(precompile_probe(root, key, out_path))


def test_a_stamp_is_written_when_a_step_writes_into_its_include_root() raises:
    """A step's own output lands in a directory its own walks cover.

    That is the ordinary shape — `-I build` with a step that produces
    `build/*.mojopkg`, and every step after the first is given the previous
    step's output directory. The step therefore changes that directory's
    membership while it runs, by design, so the directory cannot be held to a
    membership claim: doing so would leave every such step unstamped and
    recompiling on every run, forever and silently. Its FILES are still held to
    theirs, which is where an actual input would show up.
    """
    var root = _pkg_root()
    var out_path = String("build/pkg.mojopkg")
    var includes: List[String] = ["build"]
    var no_dirs = List[String]()
    # An earlier step's package, already in the include root the walk frames.
    write_file(root, "build/earlier.mojopkg", "# earlier\n")
    var ctx = CacheContext()
    var key = _step_key(ctx, root, "pkg", includes, no_dirs, out_path)

    # The step runs and creates its output inside that include root, which is
    # what moves the directory's times.
    write_bytes(root, out_path, [UInt8(1)])
    precompile_publish(root, key, out_path)
    assert_true(
        _stamp_exists(root, key),
        "a step that wrote its output into its own include root was refused",
    )
    assert_true(precompile_probe(root, key, out_path))


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
