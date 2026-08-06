"""The cache root, its marker, no-follow deletion, and unreadable healing.

Covers `mtest.session.store.filesystem`: that a cache root this invocation
created carries the whole `CACHEDIR.TAG` text that authorizes deleting it, that
deletion never follows a symlink out of the tree it was pointed at, and that a
generation which cannot be read is quarantined rather than stranded — including
under the three test-only faults that land in the windows a real race would.

Every case here keys a stub or nothing at all: none reads the pinned toolchain,
so none populates the process-lifetime toolchain memos.
"""
from std.os import getenv, link, lstat, makedirs, setenv, symlink, unsetenv
from std.os.path import exists, isdir, islink
from std.sys.info import CompilationTarget
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from mtest.platform import (
    prepare_directory_for_rename,
    read_bounded_regular_file,
    rename_path,
    set_permissions,
)
from mtest.session.scratch import _mangle
from mtest.session.store.artifact import (
    PROBE_HIT,
    PUB_OK,
    store_build_target,
    store_probe,
    store_publish,
)
from mtest.session.store.filesystem import (
    STORE_DIR,
    STORE_FAULT_ENV,
    _discard_unreadable_generation,
    clear_cache_root,
    ensure_cache_root,
    remove_tree_no_follow,
)

from cache_fixtures import chmod_path, write_bytes
from session_fixtures import write_file
from store_fixtures import build_argv, fixture_key, stage_binary
from tmptree import temp_root


# --- The cache root and its deletion-authorization marker. -------------------


def test_marker_written_at_mtest_cache_root() raises:
    var root = temp_root()
    var target = store_build_target(root, _mangle("tests/test_marker.mojo"))
    assert_true(target.ok())
    assert_true(isdir(root + "/" + STORE_DIR))
    assert_true(isdir(root + "/" + target.tmp_dir_rel))
    # The tag covers the WHOLE cache root, not just the store, because that is
    # the directory `--cache-clear` deletes and the marker authorizes deletion
    # of that whole tree.
    var tag = read_bounded_regular_file(
        root + "/.mtest-cache/CACHEDIR.TAG", 4096
    )
    assert_true(tag.is_regular)
    assert_true(
        tag.text.startswith("Signature: 8a477f597d28d172789f06886806bc55"),
        "the tag did not lead with the standard signature: " + tag.text,
    )


def test_a_cache_root_made_for_state_alone_is_still_marked() raises:
    """A directory mtest creates carries the marker authorizing its deletion.

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
    # The deletion check and marker writer have to agree byte for byte, or the
    # directory is marked and still unclearable.
    assert_false(
        Bool(clear_cache_root(root)),
        "a directory mtest marked itself must clear without a refusal",
    )
    assert_false(exists(root + "/.mtest-cache"))


# --- Preparing and healing a generation that will not read. ------------------


def test_permission_repair_never_follows_a_replaced_symlink() raises:
    var root = temp_root()
    var outside = root + "/outside"
    makedirs(outside)
    set_permissions(outside, 0o755)
    var replacement = root + "/replacement"
    makedirs(replacement)
    var observed = lstat(replacement)
    rename_path(replacement, root + "/old-observed")
    symlink(outside, replacement)

    # A peer can replace the observed cache directory before Darwin prepares it
    # for repair. The anchored no-follow lookup must reject the replacement
    # rather than chmod its target.
    try:
        prepare_directory_for_rename(
            root, "replacement", Int(observed.st_dev), Int(observed.st_ino)
        )
    except:
        pass
    assert_equal(Int(lstat(outside).st_mode) & 0o777, 0o755)


def test_permission_repair_rejects_a_symlinked_ancestor() raises:
    var root = temp_root()
    var ancestor = root + "/ancestor"
    var generation = ancestor + "/generation"
    makedirs(generation)
    set_permissions(generation, 0o755)
    var observed = lstat(generation)
    var moved_ancestor = root + "/moved-ancestor"
    rename_path(ancestor, moved_ancestor)
    symlink(moved_ancestor, ancestor)

    # The final component still resolves to the originally observed directory,
    # so final-only O_NOFOLLOW plus the identity check would accept it.
    # O_NOFOLLOW_ANY must reject the substituted ancestor before fchmod.
    try:
        prepare_directory_for_rename(
            root,
            "ancestor/generation",
            Int(observed.st_dev),
            Int(observed.st_ino),
        )
    except:
        pass
    assert_equal(
        Int(lstat(moved_ancestor + "/generation").st_mode) & 0o777, 0o755
    )


def test_permission_repair_never_mutates_a_hard_link_replacement() raises:
    var root = temp_root()
    var outside = root + "/outside.bin"
    write_bytes(root, "outside.bin", [UInt8(1)])
    set_permissions(outside, 0o644)
    var replacement = root + "/replacement"
    makedirs(replacement)
    var observed = lstat(replacement)
    rename_path(replacement, root + "/old-observed")
    link(outside, replacement)

    # The anchored identity check rejects the hard-linked regular file before
    # fchmodat. Even though its inode is shared with a path outside the cache,
    # that outside object's mode must remain untouched.
    try:
        prepare_directory_for_rename(
            root, "replacement", Int(observed.st_dev), Int(observed.st_ino)
        )
    except:
        pass
    assert_equal(Int(lstat(outside).st_mode) & 0o777, 0o644)


def test_unreadable_healer_leaves_a_readable_replacement_alone() raises:
    var root = temp_root()
    var rel = String("tests/test_replacement.mojo")
    var key = fixture_key(root, rel, "# replacement\n")
    var target = stage_binary(root, [UInt8(7), UInt8(8), UInt8(9)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, build_argv(rel, target.out_rel)
        ).kind,
        PUB_OK,
    )

    # A concurrent publisher may replace the unreadable directory after the
    # detecting probe has returned. The healer must re-check the final name and
    # leave that readable replacement runnable rather than moving it aside.
    _discard_unreadable_generation(
        root + "/" + key.gen_dir, root + "/" + STORE_DIR, key.gen_name
    )
    assert_equal(store_probe(root, key).kind, PROBE_HIT)


def test_unreadable_healer_restores_a_replacement_raced_before_quarantine() raises:
    var root = temp_root()
    var rel = String("tests/test_raced_replacement.mojo")
    var key = fixture_key(root, rel, "# raced replacement\n")
    var target = stage_binary(root, [UInt8(10), UInt8(11), UInt8(12)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, build_argv(rel, target.out_rel)
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
        _discard_unreadable_generation(
            root + "/" + key.gen_dir, store_abs, key.gen_name
        )
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
    var key = fixture_key(root, rel, "# tombstone lstat\n")
    var target = stage_binary(root, [UInt8(13), UInt8(14), UInt8(15)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, build_argv(rel, target.out_rel)
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
        _discard_unreadable_generation(
            final_abs, root + "/" + STORE_DIR, key.gen_name
        )
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


def test_unreadable_healer_still_quarantines_after_preparation_failure() raises:
    comptime if CompilationTarget.is_macos():
        # Darwin is the platform that needs successful preparation to rename a
        # mode-000 directory. Linux isolates the separate contract under test:
        # a failed preparation must not suppress a rename the parent permits.
        return

    var root = temp_root()
    var store_abs = root + "/" + STORE_DIR
    var final_rel = (
        STORE_DIR + "/tests_stest_empty_h00000000000000000000000000000000"
    )
    var final_abs = root + "/" + final_rel
    makedirs(final_abs)
    write_bytes(root, final_rel + "/damage", [UInt8(1)])
    set_permissions(final_abs, 0o000)

    # Linux authorizes this rename through the writable parent even though the
    # directory itself cannot be listed. Faulting the best-effort preparation
    # proves its error never suppresses that authoritative rename attempt.
    var saved = getenv(STORE_FAULT_ENV, "")
    var was_set = getenv(STORE_FAULT_ENV, "\x01unset") != "\x01unset"
    try:
        _ = setenv(STORE_FAULT_ENV, "unreadable-prepare-failure", True)
        _discard_unreadable_generation(
            final_abs,
            store_abs,
            "tests_stest_empty_h00000000000000000000000000000000",
        )
    finally:
        if was_set:
            _ = setenv(STORE_FAULT_ENV, saved, True)
        else:
            _ = unsetenv(STORE_FAULT_ENV)
    if exists(final_abs):
        # Restore before asserting so a regression still leaves a removable
        # temporary tree rather than an inaccessible one.
        set_permissions(final_abs, 0o700)
    assert_false(exists(final_abs))


# --- No-follow deletion. -----------------------------------------------------


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
