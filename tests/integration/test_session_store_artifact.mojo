"""The store protocol: stage, probe, publish, adopt, reap, and rank.

Covers `mtest.session.store.artifact`'s protocol half — the questions
`store_probe` resolves toward a miss, what `store_publish` refuses when an input
moved underneath the compile, which generations survive a reap, and how the
recency record orders them. The key-derivation half is in
`test_session_store_keys`.

Every case here keys a stub or nothing at all: none reads the pinned toolchain,
so none populates the process-lifetime toolchain memos.
"""
from std.os import lstat, makedirs, remove, symlink
from std.os.path import exists, isdir, islink
from std.time import sleep
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from mtest.platform import rename_path
from mtest.session.scratch import _mangle
from mtest.session.store.artifact import (
    FileKey,
    PROBE_HIT,
    PROBE_MISS,
    PUB_ADOPTED,
    PUB_FAILED,
    PUB_OK,
    _GenRecord,
    _RETAIN_GENERATIONS,
    _SEQ_MAX,
    _SEQ_NAME,
    _correct_visibility_seq,
    _discard_ranked_out,
    _read_seq,
    _reap_siblings,
    _sibling_generations,
    file_key,
    store_build_target,
    store_probe,
    store_publish,
)
from mtest.session.store.context import CacheContext
from mtest.session.store.filesystem import STORE_DIR, remove_tree_no_follow

from cache_fixtures import chmod_path, dir_listing, write_bytes
from session_fixtures import write_file
from store_fixtures import (
    build_argv,
    fixture_key,
    mutate_until_witnessed,
    stage_binary,
)
from tmptree import temp_root


def _plant_generation(root: String, gen_dir: String, seq: Int) raises:
    """Put a generation carrying `seq` where another run published one.

    Reaping ranks and deletes by NAME and recency record; it never opens `bin`
    or `meta`. Standing a generation up directly is therefore how a test can
    place a rival at an exact point in the recency order without racing a
    second publisher for it.

    Args:
        root: The invocation root.
        gen_dir: The generation's root-relative directory.
        seq: The recency record to write, in the store's own format.

    Raises:
        Error: If any of the three files cannot be written.
    """
    write_bytes(root, gen_dir + "/bin", [UInt8(9)])
    write_bytes(root, gen_dir + "/meta", [UInt8(110)])
    write_file(root, gen_dir + "/" + _SEQ_NAME, String(seq) + "\n")


def _near(a: Float64, b: Float64) -> Bool:
    """Whether two durations agree to the meta format's microsecond grid."""
    var d = a - b
    if d < 0.0:
        d = -d
    return d < 1.0e-6


def _churn_until_witnessed(dir_abs: String, file_abs: String) raises:
    """Create and remove `file_abs` until `dir_abs`'s own times record it.

    The membership case has no file record to compare — the entry is gone by
    the time anything looks — so the directory's times are the only evidence,
    and they are subject to the same tick quantization a file's are. Repeat the
    create-and-remove until the directory moved against its state before this
    call.

    Args:
        dir_abs: The absolute directory whose membership churns.
        file_abs: The absolute path created and removed inside it.

    Raises:
        Error: If the directory never recorded the churn.
    """
    var before = lstat(dir_abs)
    for _ in range(200):
        with open(file_abs, "w") as f:
            f.write("# transient\n")
        remove(file_abs)
        var now = lstat(dir_abs)
        if (
            Int(now.st_ctimespec.tv_sec) != Int(before.st_ctimespec.tv_sec)
            or Int(now.st_ctimespec.tv_subsec)
            != Int(before.st_ctimespec.tv_subsec)
            or Int(now.st_mtimespec.tv_sec) != Int(before.st_mtimespec.tv_sec)
            or Int(now.st_mtimespec.tv_subsec)
            != Int(before.st_mtimespec.tv_subsec)
        ):
            return
        sleep(0.005)
    raise Error("test: the filesystem never recorded the membership change")


def test_staging_directory_name_carries_the_mangled_source() raises:
    # The compiler child writes to staging for the whole first-attempt build.
    # Publication normally finishes before the test child starts, so the test
    # child runs there only when publication fails. Anything identifying either
    # live child from outside the process — the release contract's SIGINT probe,
    # a `ps` a human reads during a hang — has only that path to go on. A name
    # built from pid and clock alone hid every running child from `pgrep`.
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


def test_publish_then_probe_hits() raises:
    var root = temp_root()
    var rel = String("tests/test_hit.mojo")
    var key = fixture_key(root, rel, "# hit\n")
    var target = stage_binary(root, [UInt8(1), UInt8(2), UInt8(3)])
    var pub = store_publish(
        root, key, target, 2.5, build_argv(rel, target.out_rel)
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
    var key = fixture_key(root, rel, "# corrupt\n")
    var target = stage_binary(root, [UInt8(1), UInt8(2), UInt8(3)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, build_argv(rel, target.out_rel)
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
    var key = fixture_key(root, rel, "# unrunnable\n")
    var target = stage_binary(root, [UInt8(1), UInt8(2), UInt8(3)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, build_argv(rel, target.out_rel)
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
    var key = fixture_key(root, rel, "# unreadable\n")
    var first = stage_binary(root, [UInt8(1), UInt8(2), UInt8(3)])
    assert_equal(
        store_publish(
            root, key, first, 1.0, build_argv(rel, first.out_rel)
        ).kind,
        PUB_OK,
    )

    # A cache directory can survive a permissions-damaging archive restore or
    # manual repair. It must not occupy this generation's final name forever:
    # the first probe misses, then the replacement publishes and the next probe
    # hits as if the unreadable directory had never existed.
    chmod_path("000", root + "/" + key.gen_dir)
    assert_equal(store_probe(root, key).kind, PROBE_MISS)
    var replacement = stage_binary(root, [UInt8(4), UInt8(5), UInt8(6)])
    assert_equal(
        store_publish(
            root, key, replacement, 1.0, build_argv(rel, replacement.out_rel)
        ).kind,
        PUB_OK,
    )
    assert_equal(store_probe(root, key).kind, PROBE_HIT)


def test_probe_rejects_wrong_key_meta() raises:
    var root = temp_root()
    var rel = String("tests/test_collide.mojo")
    var key = fixture_key(root, rel, "# collide\n")
    var target = stage_binary(root, [UInt8(7)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, build_argv(rel, target.out_rel)
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
        input_witnesses=key.input_witnesses.copy(),
    )
    assert_equal(store_probe(root, collided).kind, PROBE_MISS)
    assert_false(isdir(root + "/" + key.gen_dir))


def test_partial_tmp_generation_is_inert() raises:
    var root = temp_root()
    var key = fixture_key(root, "tests/test_partial.mojo", "# partial\n")
    makedirs(root + "/" + STORE_DIR + "/.tmp-999-zz")
    assert_equal(store_probe(root, key).kind, PROBE_MISS)
    # A half-built staging directory is not a generation, and a probe does not
    # reap it: another process may be compiling into it right now.
    assert_true(isdir(root + "/" + STORE_DIR + "/.tmp-999-zz"))


def test_publish_adopts_existing_same_key() raises:
    var root = temp_root()
    var rel = String("tests/test_adopt.mojo")
    var key = fixture_key(root, rel, "# adopt\n")
    var first = stage_binary(root, [UInt8(1)])
    assert_equal(
        store_publish(
            root, key, first, 1.0, build_argv(rel, first.out_rel)
        ).kind,
        PUB_OK,
    )
    var second = stage_binary(root, [UInt8(1)])
    # A sixth token this run's command line carries and the winner's does not,
    # so the adopted argv can be told apart from a merely rewritten one.
    var loser_argv = build_argv(rel, second.out_rel)
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
    var key = fixture_key(root, rel, "# garbage\n")
    # A generation that EXISTS but does not validate — the shape a killed run
    # leaves behind. Adopting it unchecked is how one corrupt generation spreads
    # to every process that loses a rename against it.
    write_bytes(root, key.gen_dir + "/bin", [UInt8(4)])
    write_bytes(root, key.gen_dir + "/meta", [UInt8(110), UInt8(111)])
    var target = stage_binary(root, [UInt8(5)])
    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
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
    var old = fixture_key(root, rel, "# one\n")
    var first = stage_binary(root, [UInt8(1)])
    assert_equal(
        store_publish(
            root, old, first, 1.0, build_argv(rel, first.out_rel)
        ).kind,
        PUB_OK,
    )
    var middle = fixture_key(root, rel, "# two\n")
    assert_not_equal(old.gen_name, middle.gen_name)
    var second = stage_binary(root, [UInt8(2)])
    assert_equal(
        store_publish(
            root, middle, second, 1.0, build_argv(rel, second.out_rel)
        ).kind,
        PUB_OK,
    )
    var new = fixture_key(root, rel, "# three\n")
    assert_not_equal(middle.gen_name, new.gen_name)
    var third = stage_binary(root, [UInt8(3)])
    assert_equal(
        store_publish(
            root, new, third, 1.0, build_argv(rel, third.out_rel)
        ).kind,
        PUB_OK,
    )
    # A bounded number of live generations per source file: an editing loop
    # must not grow the store without bound, and the ones that survive are the
    # newest by name, not merely the right count.
    assert_false(isdir(root + "/" + old.gen_dir))
    assert_true(isdir(root + "/" + middle.gen_dir))
    assert_true(isdir(root + "/" + new.gen_dir))


def test_probe_refuses_symlinked_generation() raises:
    var root = temp_root()
    var rel = String("tests/test_link.mojo")
    var key = fixture_key(root, rel, "# link\n")
    var target = stage_binary(root, [UInt8(3)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, build_argv(rel, target.out_rel)
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
    var key = fixture_key(root, rel, "# binlink\n")
    var target = stage_binary(root, [UInt8(3)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, build_argv(rel, target.out_rel)
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
    var key = fixture_key(root, rel, "# suffix\n")
    var mangled = _mangle(rel)
    var foreign = STORE_DIR + "/" + mangled + "_hnotadigest"
    var short = STORE_DIR + "/" + mangled + "_h0123456789abcdef"
    write_bytes(root, foreign + "/keep", [UInt8(1)])
    write_bytes(root, short + "/keep", [UInt8(2)])
    var target = stage_binary(root, [UInt8(3)])
    assert_equal(
        store_publish(
            root, key, target, 1.0, build_argv(rel, target.out_rel)
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


def test_the_top_two_of_three_generations_survive() raises:
    """A third publication for one source keeps exactly the two newest.

    Publish contents A, then B, then C. Exactly B's and C's generation
    directories survive, by exact name; A's is gone. One live generation per
    source made every branch switch recompile both directions; two make the
    alternation hit while an editing loop stays bounded.
    """
    var root = temp_root()
    var rel = String("tests/test_retain.mojo")
    var oldest = fixture_key(root, rel, "# one\n")
    var first = stage_binary(root, [UInt8(1)])
    assert_equal(
        store_publish(
            root, oldest, first, 1.0, build_argv(rel, first.out_rel)
        ).kind,
        PUB_OK,
    )
    var middle = fixture_key(root, rel, "# two\n")
    var second = stage_binary(root, [UInt8(2)])
    assert_equal(
        store_publish(
            root, middle, second, 1.0, build_argv(rel, second.out_rel)
        ).kind,
        PUB_OK,
    )
    var newest = fixture_key(root, rel, "# three\n")
    var third = stage_binary(root, [UInt8(3)])
    assert_equal(
        store_publish(
            root, newest, third, 1.0, build_argv(rel, third.out_rel)
        ).kind,
        PUB_OK,
    )
    assert_not_equal(oldest.gen_name, middle.gen_name)
    assert_not_equal(middle.gen_name, newest.gen_name)
    # Exact names, never a count: a bound that held while the wrong two
    # survived would be no bound at all.
    assert_false(
        isdir(root + "/" + oldest.gen_dir),
        "the oldest generation outlived both of its successors",
    )
    assert_true(
        isdir(root + "/" + middle.gen_dir),
        "the second-newest generation was reaped",
    )
    assert_true(isdir(root + "/" + newest.gen_dir))


def test_alternating_content_hits_both_ways() raises:
    """Publish A, publish B; probe A's key and B's key: both HIT."""
    var root = temp_root()
    var rel = String("tests/test_alternate.mojo")
    var one = fixture_key(root, rel, "# one\n")
    var first = stage_binary(root, [UInt8(1)])
    assert_equal(
        store_publish(
            root, one, first, 1.0, build_argv(rel, first.out_rel)
        ).kind,
        PUB_OK,
    )
    var two = fixture_key(root, rel, "# two\n")
    var second = stage_binary(root, [UInt8(2)])
    assert_equal(
        store_publish(
            root, two, second, 1.0, build_argv(rel, second.out_rel)
        ).kind,
        PUB_OK,
    )
    # Switching a file between two states and back is the ordinary route, and
    # the second cycle has to compile nothing in either direction.
    assert_equal(
        store_probe(root, one).kind,
        PROBE_HIT,
        "the superseded generation was reaped, so going back rebuilds",
    )
    assert_equal(store_probe(root, two).kind, PROBE_HIT)


def test_a_straggler_ranks_globally_not_selfishly() raises:
    """A late-renaming early-allocated publisher must not evict newer.

    A publisher that allocated its recency record into an empty store and
    renamed last would rank itself oldest and, keeping the top two, delete the
    generation that really is newest. Correcting the record against what is
    VISIBLE after the rename is what makes the two questions agree.
    """
    var root = temp_root()
    var rel = String("tests/test_straggler.mojo")
    # Published into an empty store, so it allocated the lowest record there is.
    var straggler = fixture_key(root, rel, "# straggler\n")
    var staged = stage_binary(root, [UInt8(1)])
    assert_equal(
        store_publish(
            root, straggler, staged, 1.0, build_argv(rel, staged.out_rel)
        ).kind,
        PUB_OK,
    )
    # Two rivals that became visible while this one was still compiling.
    var middle = fixture_key(root, rel, "# middle\n")
    var newest = fixture_key(root, rel, "# newest\n")
    _plant_generation(root, middle.gen_dir, 2)
    _plant_generation(root, newest.gen_dir, 3)
    # Exactly what publication does once its own rename has landed.
    _correct_visibility_seq(root, straggler)
    _reap_siblings(root, straggler)
    assert_true(
        isdir(root + "/" + straggler.gen_dir),
        "the generation just published was reaped by its own publication",
    )
    assert_true(
        isdir(root + "/" + newest.gen_dir),
        "a strictly newer generation was evicted by a late publisher",
    )
    assert_false(
        isdir(root + "/" + middle.gen_dir),
        "three generations of one source survived a publication",
    )


def test_a_discard_is_skipped_when_the_sibling_was_republished() raises:
    """A ranked-out name whose generation changed under the reaper is spared.

    Generation names are deterministic, so the directory a listing ranked out
    can be a DIFFERENT, freshly published generation by the time the deletion
    runs. Re-reading the victim's identity immediately before removing it is
    what keeps a paused reaper from deleting a rival's new work.
    """
    var root = temp_root()
    var rel = String("tests/test_guard.mojo")
    var mine = fixture_key(root, rel, "# mine\n")
    var rival = fixture_key(root, rel, "# rival\n")
    _plant_generation(root, rival.gen_dir, 1)
    # The listing a reaper ranks from, read before the rival republishes.
    var stale = _sibling_generations(root, mine)
    assert_equal(len(stale), 1)
    assert_equal(stale[0].name, rival.gen_name)
    assert_equal(stale[0].seq, 1)
    # The rival republishes at the same deterministic name.
    remove_tree_no_follow(root + "/" + rival.gen_dir)
    _plant_generation(root, rival.gen_dir, 7)
    _discard_ranked_out(root + "/" + STORE_DIR, stale[0])
    assert_true(
        isdir(root + "/" + rival.gen_dir),
        "a republished generation was deleted from a stale listing",
    )
    # The guard narrows the window; it does not stop the reaper reaping. A
    # record that still describes what is on disk is discarded as before.
    var fresh = _sibling_generations(root, mine)
    assert_equal(len(fresh), 1)
    assert_equal(fresh[0].seq, 7)
    _discard_ranked_out(root + "/" + STORE_DIR, fresh[0])
    assert_false(isdir(root + "/" + rival.gen_dir))


def test_a_saturated_order_still_converges_to_the_retained_count() raises:
    """A planted maximum record must not stop the store converging.

    Once any generation of a source carries the largest value the format can
    express, every later one saturates there too and the order collapses to a
    comparison of names. Retention still has to end at the retained count: a
    publication whose name happens to sort lowest would otherwise rank itself
    out, refuse to delete itself, and leave the source one generation over the
    target for good rather than transiently.
    """
    var root = temp_root()
    var rel = String("tests/test_saturated.mojo")
    var bodies: List[String] = ["# one\n", "# two\n", "# three\n"]
    var keys = List[FileKey]()
    for body in bodies:
        keys.append(fixture_key(root, rel, body))
    # Rank the three deterministic names, so the scenario does not depend on
    # which digest a given body happens to produce.
    var hi = 0
    var lo = 0
    for i in range(1, len(keys)):
        if keys[i].gen_name > keys[hi].gen_name:
            hi = i
        if keys[i].gen_name < keys[lo].gen_name:
            lo = i
    var mid = 3 - hi - lo
    assert_not_equal(hi, lo)
    assert_not_equal(mid, hi)
    assert_not_equal(mid, lo)

    _plant_generation(root, keys[hi].gen_dir, _SEQ_MAX)
    # The lowest-named generation publishes LAST, which is the ordering that
    # leaves it ranked below both saturated siblings. Each body is re-keyed
    # immediately before its publication: the keys above have been overtaken by
    # the writes that produced the later ones, and publishing against a key
    # whose inputs have since moved is refused on purpose.
    var publication_order: List[Int] = [mid, lo]
    for idx in publication_order:
        var key = fixture_key(root, rel, bodies[idx])
        assert_equal(
            key.gen_name,
            keys[idx].gen_name,
            "the same bytes keyed to a different generation",
        )
        var target = stage_binary(root, [UInt8(idx + 1)])
        assert_equal(
            store_publish(
                root, key, target, 1.0, build_argv(rel, target.out_rel)
            ).kind,
            PUB_OK,
        )

    var survivors = dir_listing(root + "/" + STORE_DIR)
    assert_equal(
        len(survivors),
        _RETAIN_GENERATIONS,
        "a saturated order left the source permanently over the target",
    )
    # The generation just published is one of them — the caller is running the
    # binary inside it — and the planted maximum is the other.
    assert_true(isdir(root + "/" + keys[lo].gen_dir))
    assert_true(isdir(root + "/" + keys[hi].gen_dir))
    assert_false(isdir(root + "/" + keys[mid].gen_dir))


def test_a_ranked_out_generation_whose_inode_moved_is_spared() raises:
    """The identity guard's inode half, on its own.

    A directory replaced between the listing and the deletion can come back
    carrying the same recency record, so the record half of the guard would
    wave it through. Only the inode distinguishes the two, and testing the two
    halves together cannot say whether both are wired.
    """
    var root = temp_root()
    var rel = String("tests/test_inode_guard.mojo")
    var mine = fixture_key(root, rel, "# mine\n")
    var rival = fixture_key(root, rel, "# rival\n")
    _plant_generation(root, rival.gen_dir, 4)
    var seen = _sibling_generations(root, mine)
    assert_equal(len(seen), 1)
    assert_equal(seen[0].seq, 4)
    # The record still describes what is on disk; only the inode is wrong. The
    # directory is untouched, so nothing but the inode check can spare it.
    var moved = _GenRecord(seen[0].name, seen[0].seq, seen[0].ino + 1)
    _discard_ranked_out(root + "/" + STORE_DIR, moved)
    assert_true(
        isdir(root + "/" + rival.gen_dir),
        "a generation whose inode no longer matches the listing was deleted",
    )
    # And the unmodified record still reaps, so the guard did not simply
    # switch reaping off.
    _discard_ranked_out(root + "/" + STORE_DIR, seen[0])
    assert_false(isdir(root + "/" + rival.gen_dir))


def test_publication_records_a_generations_place_in_the_order() raises:
    """Each publication ranks itself above every generation already visible.

    The record is what makes retention keep the NEWEST few rather than an
    arbitrary few, and it is allocated from the store rather than from a clock,
    so two generations can never claim the same place.
    """
    var root = temp_root()
    var rel = String("tests/test_order.mojo")
    var one = fixture_key(root, rel, "# one\n")
    var first = stage_binary(root, [UInt8(1)])
    assert_equal(
        store_publish(
            root, one, first, 1.0, build_argv(rel, first.out_rel)
        ).kind,
        PUB_OK,
    )
    # An empty store seeds the highest record at 0, so the first generation of
    # a source is 1 and never collides with a generation carrying none.
    assert_equal(_read_seq(root + "/" + one.gen_dir + "/" + _SEQ_NAME), 1)
    var two = fixture_key(root, rel, "# two\n")
    var second = stage_binary(root, [UInt8(2)])
    assert_equal(
        store_publish(
            root, two, second, 1.0, build_argv(rel, second.out_rel)
        ).kind,
        PUB_OK,
    )
    assert_equal(_read_seq(root + "/" + two.gen_dir + "/" + _SEQ_NAME), 2)
    assert_equal(_read_seq(root + "/" + one.gen_dir + "/" + _SEQ_NAME), 1)
    # The retained count is the constant, not a number this test invented.
    assert_equal(_RETAIN_GENERATIONS, 2)


def test_a_generation_without_a_recency_record_reads_as_oldest() raises:
    """A generation carrying no record ranks first out.

    That is the whole of the compatibility story: generations published before
    the record existed read as the oldest there is, so they are what the next
    publication reaps rather than something it has to reason about.
    """
    var root = temp_root()
    assert_equal(_read_seq(root + "/absent/" + _SEQ_NAME), 0)


def test_a_damaged_recency_record_reads_as_oldest() raises:
    """Every deviation from the one canonical format reads as 0.

    A record is ranking input, so a parser that raised would turn damage inside
    the cache into a failed run, and one that guessed at a near-miss would turn
    it into a wrong order. Reading damage as "oldest" converges instead: the
    generation ages out and is rebuilt once.
    """
    var root = temp_root()
    write_file(root, "empty/" + _SEQ_NAME, "")
    write_file(root, "unterminated/" + _SEQ_NAME, "5")
    write_file(root, "twice/" + _SEQ_NAME, "5\n\n")
    write_file(root, "padded/" + _SEQ_NAME, "05\n")
    write_file(root, "signed/" + _SEQ_NAME, "+5\n")
    write_file(root, "negative/" + _SEQ_NAME, "-5\n")
    write_file(root, "leading_space/" + _SEQ_NAME, " 5\n")
    write_file(root, "trailing_space/" + _SEQ_NAME, "5 \n")
    write_file(root, "sixteen_digits/" + _SEQ_NAME, "1000000000000000\n")
    write_bytes(
        root, "not_utf8/" + _SEQ_NAME, [UInt8(0xC3), UInt8(0x28), UInt8(10)]
    )
    # Past the byte cap, so it is characterized and then not read at all.
    write_file(root, "oversized/" + _SEQ_NAME, String("9") * 40 + "\n")
    makedirs(root + "/directory/" + _SEQ_NAME)
    var damaged: List[String] = [
        "empty",
        "unterminated",
        "twice",
        "padded",
        "signed",
        "negative",
        "leading_space",
        "trailing_space",
        "sixteen_digits",
        "not_utf8",
        "oversized",
        "directory",
    ]
    for name in damaged:
        assert_equal(
            _read_seq(root + "/" + name + "/" + _SEQ_NAME),
            0,
            "'" + name + "' was accepted as a recency record",
        )


def test_the_boundary_recency_records_are_read_whole() raises:
    """Zero, one, and the format's maximum are values, not deviations.

    The digit cap is what keeps `max + 1` from overflowing, so the largest
    value the format can express has to parse exactly rather than fall into the
    damage case beside it.
    """
    var root = temp_root()
    write_file(root, "zero/" + _SEQ_NAME, "0\n")
    assert_equal(_read_seq(root + "/zero/" + _SEQ_NAME), 0)
    write_file(root, "one/" + _SEQ_NAME, "1\n")
    assert_equal(_read_seq(root + "/one/" + _SEQ_NAME), 1)
    write_file(root, "max/" + _SEQ_NAME, String(_SEQ_MAX) + "\n")
    assert_equal(_read_seq(root + "/max/" + _SEQ_NAME), _SEQ_MAX)


def test_publish_refuses_a_source_changed_mid_compile() raises:
    var root = temp_root()
    var rel = String("tests/test_race.mojo")
    var key = fixture_key(root, rel, "# before\n")
    var target = stage_binary(root, [UInt8(1)])
    write_file(root, rel, "# after\n")
    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    # The binary was compiled from bytes this key does not describe. Publishing
    # it would serve it to a later run whose key still says "before".
    assert_equal(pub.kind, PUB_FAILED)
    assert_true(
        "changed while the build ran" in pub.warning,
        "the warning did not name the cause: " + pub.warning,
    )
    # The entry source by name. A guard that refused on the directory instead
    # would also produce PUB_FAILED, and this case would stop discriminating
    # the two inputs it exists to tell apart.
    assert_true(
        rel in pub.warning,
        "the warning did not name the input: " + pub.warning,
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
    var key = fixture_key(root, rel, "# entry\n")
    var target = stage_binary(root, [UInt8(1)])
    write_file(root, "tests/helper.mojo", "# after\n")

    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_FAILED)
    # The specific cause: the entry source never moved, so a guard that only
    # re-read that file would report PUB_OK here and this test would pass on
    # the wrong mechanism if it checked the kind alone.
    assert_true(
        "changed while the build ran" in pub.warning
        and "helper.mojo" in pub.warning,
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
    var key = fixture_key(root, rel, "# entry\n")
    var target = stage_binary(root, [UInt8(1)])
    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_OK, "warning: " + pub.warning)
    assert_true(isdir(root + "/" + key.gen_dir))


def test_publish_refuses_a_helper_restored_after_an_edit() raises:
    """An edit-and-undo across the build window must not publish.

    Both content samples agree — the bytes were restored — but the binary was
    built while the helper held OTHER bytes, and every later run over the
    restored tree would hit that binary. Identity and change times cannot be
    restored from userspace, so publication refuses on those instead.
    """
    var root = temp_root()
    var rel = String("tests/test_undo_helper.mojo")
    write_file(root, "tests/helper.mojo", "# before\n")
    var key = fixture_key(root, rel, "# entry\n")
    var target = stage_binary(root, [UInt8(1)])
    var helper = root + "/tests/helper.mojo"
    mutate_until_witnessed(helper, "# other\n")
    mutate_until_witnessed(helper, "# before\n")

    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_FAILED)
    # The helper by its whole label, not a substring of it: `helper.mojo`
    # also occurs inside `test_uses_helper.mojo`, so a bare membership test
    # would be satisfied by a warning naming the entry source instead.
    assert_equal(pub.warning, "'tests/helper.mojo' changed while the build ran")
    assert_false(isdir(root + "/" + key.gen_dir))
    # A refusal is never a failure of the run: the caller keeps running exactly
    # what it built.
    assert_equal(pub.bin_rel, target.out_rel)
    assert_true(exists(root + "/" + target.out_rel))


def test_publish_refuses_a_source_restored_after_an_edit() raises:
    """The entry source gets the same treatment as its helpers."""
    var root = temp_root()
    var rel = String("tests/test_undo_source.mojo")
    var key = fixture_key(root, rel, "# entry\n")
    var target = stage_binary(root, [UInt8(1)])
    var source = root + "/" + rel
    mutate_until_witnessed(source, "# other\n")
    mutate_until_witnessed(source, "# entry\n")

    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_FAILED)
    assert_equal(pub.warning, "'" + rel + "' changed while the build ran")
    assert_false(isdir(root + "/" + key.gen_dir))


def test_publish_refuses_a_helper_replaced_with_identical_bytes() raises:
    """Write-temp-and-rename-over changes identity while the bytes agree.

    The everyday shape of an editor saving a file. Content re-sampling cannot
    see it at all — the bytes never differ — and no timestamp tick can hide it,
    because the name resolves to a different inode afterwards.
    """
    var root = temp_root()
    var rel = String("tests/test_replaced.mojo")
    write_file(root, "tests/helper.mojo", "# same\n")
    var key = fixture_key(root, rel, "# entry\n")
    var target = stage_binary(root, [UInt8(1)])
    write_file(root, "tests/helper.mojo.tmp", "# same\n")
    rename_path(root + "/tests/helper.mojo.tmp", root + "/tests/helper.mojo")

    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_FAILED)
    # The rename also moves the DIRECTORY's times, so a guard that only held
    # directories would refuse here too and this case would stop testing the
    # identity comparison it is named for.
    assert_equal(pub.warning, "'tests/helper.mojo' changed while the build ran")
    assert_false(isdir(root + "/" + key.gen_dir))


def test_publish_refuses_a_retargeted_and_restored_helper_link() raises:
    """A symlinked helper repointed mid-build and repointed back.

    Both targets keep their own stat, and the bytes behind the link are the
    original ones again by the time publication looks, so a sample that
    followed the link would agree with the key. The link's OWN identity moved.
    """
    var root = temp_root()
    var rel = String("tests/test_relink.mojo")
    write_file(root, "tests/helper_a.mojo", "# a\n")
    write_file(root, "tests/helper_b.mojo", "# b\n")
    symlink(root + "/tests/helper_a.mojo", root + "/tests/helper.mojo")
    var key = fixture_key(root, rel, "# entry\n")
    var target = stage_binary(root, [UInt8(1)])
    remove(root + "/tests/helper.mojo")
    symlink(root + "/tests/helper_b.mojo", root + "/tests/helper.mojo")
    remove(root + "/tests/helper.mojo")
    symlink(root + "/tests/helper_a.mojo", root + "/tests/helper.mojo")

    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_FAILED)
    # Removing and recreating the link moves the directory's times as well, so
    # only the LINK's own label proves the no-follow record is what refused.
    assert_equal(pub.warning, "'tests/helper.mojo' changed while the build ran")
    assert_false(isdir(root + "/" + key.gen_dir))


def test_publish_refuses_a_retargeted_and_restored_source_dir_link() raises:
    """The walked directory itself was reached through a link that moved.

    Everything the walk framed is reached BY FOLLOWING that link, so a link
    repointed at another tree and repointed back hands the compiler a whole
    different directory while both targets hold still. The followed record
    reproduces exactly — it describes the restored target — and only the walk
    root's own identity moved.
    """
    var root = temp_root()
    var rel = String("tests/test_dir_link.mojo")
    write_file(root, "real_tests/helper.mojo", "# a\n")
    write_file(root, "other_tests/helper.mojo", "# b\n")
    symlink(root + "/real_tests", root + "/tests")
    var key = fixture_key(root, rel, "# entry\n")
    var target = stage_binary(root, [UInt8(1)])
    remove(root + "/tests")
    symlink(root + "/other_tests", root + "/tests")
    remove(root + "/tests")
    symlink(root + "/real_tests", root + "/tests")

    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_FAILED)
    assert_equal(pub.warning, "'tests' changed while the build ran")
    assert_false(isdir(root + "/" + key.gen_dir))


def test_publish_refuses_an_edit_behind_a_stable_helper_link() raises:
    """The bytes behind a link moved while the link itself did not.

    The counterpart of the retargeting case, and the only shape that isolates
    the FOLLOWED record. The link's own identity is untouched, its directory's
    membership is untouched, and the target lives outside the walked directory
    so it has no record of its own — the walk read it only by following the
    link. Nothing but the followed sample can refuse this.
    """
    var root = temp_root()
    var rel = String("tests/test_behind_link.mojo")
    write_file(root, "outside/helper_a.mojo", "# a\n")
    # The entry source first: it is what creates `tests/` for the link to
    # land in. `fixture_key` rewrites the same bytes there a moment later.
    write_file(root, rel, "# entry\n")
    symlink(root + "/outside/helper_a.mojo", root + "/tests/helper.mojo")
    var key = fixture_key(root, rel, "# entry\n")
    var target = stage_binary(root, [UInt8(1)])
    var behind = root + "/outside/helper_a.mojo"
    mutate_until_witnessed(behind, "# other\n")
    mutate_until_witnessed(behind, "# a\n")

    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_FAILED)
    assert_equal(pub.warning, "'tests/helper.mojo' changed while the build ran")
    assert_false(isdir(root + "/" + key.gen_dir))


def test_publish_refuses_a_file_that_came_and_went() raises:
    """A source created beside the test mid-build and deleted again.

    No file record exists for it — it was absent when the key was taken and
    absent again when publication looked — and the content re-walk therefore
    agrees with the key-time walk exactly. The DIRECTORY's own times moved, and
    that is the only evidence there is.
    """
    var root = temp_root()
    var rel = String("tests/test_transient.mojo")
    var key = fixture_key(root, rel, "# entry\n")
    var target = stage_binary(root, [UInt8(1)])
    _churn_until_witnessed(root + "/tests", root + "/tests/transient.mojo")
    assert_false(exists(root + "/tests/transient.mojo"))

    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_FAILED)
    # No file moved, so the directory is the only input that CAN be named —
    # the other side of the pairing every case above asserts.
    assert_equal(pub.warning, "'tests' changed while the build ran")
    assert_false(isdir(root + "/" + key.gen_dir))


def test_publish_accepts_an_untouched_tree_with_witness() raises:
    """The no-op control: nothing moved, publication proceeds.

    A capture that could not reproduce itself over a held-still tree would
    refuse every publication and turn the cache into a pure cost. The tree here
    holds the shapes the capture treats specially — a helper, a symlinked
    helper, and a package subdirectory the walk recurses into — so a record
    that cannot be re-taken for any of them fails here rather than in the
    field.
    """
    var root = temp_root()
    var rel = String("tests/test_untouched.mojo")
    write_file(root, "tests/helper_a.mojo", "# a\n")
    symlink(root + "/tests/helper_a.mojo", root + "/tests/helper.mojo")
    write_file(root, "tests/pkg/__init__.mojo", "")
    write_file(root, "tests/pkg/mod.mojo", "# mod\n")
    var key = fixture_key(root, rel, "# entry\n")
    var target = stage_binary(root, [UInt8(1)])

    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_OK, "warning: " + pub.warning)
    assert_true(isdir(root + "/" + key.gen_dir))


def test_publish_succeeds_for_a_test_file_at_the_invocation_root() raises:
    """A cold store must not read as churn in the directory it is created in.

    A test file sitting at the invocation root makes that root the walked
    directory, and `.mtest-cache` is created inside it. Created AFTER the key,
    that is a new entry beside the source and moves the directory's times, so
    the run refuses its own publication — every file of the session under the
    pool, where all of them are keyed before the first staging. It also
    self-heals on the next run, which is exactly what makes it easy to miss.
    """
    var root = temp_root()
    var rel = String("test_flat.mojo")
    var key = fixture_key(root, rel, "# flat\n")
    var target = stage_binary(root, [UInt8(1)])

    var pub = store_publish(
        root, key, target, 1.0, build_argv(rel, target.out_rel)
    )
    assert_equal(pub.kind, PUB_OK, "warning: " + pub.warning)
    assert_true(isdir(root + "/" + key.gen_dir))


def test_a_later_sibling_key_carries_the_directory_witness() raises:
    """Two siblings share one memoized walk; both keys must carry it.

    The directory is walked once per session and every file in it forks that
    one result, so a witness recorded into the walk but not copied out to each
    key would protect the first file and silently leave every later one on the
    old behavior.
    """
    var root = temp_root()
    var ctx = CacheContext()
    write_file(root, "tests/helper.mojo", "# before\n")
    write_file(root, "tests/test_one.mojo", "# one\n")
    write_file(root, "tests/test_two.mojo", "# two\n")
    var first = file_key(ctx, root, "tests/test_one.mojo")
    assert_true(Bool(first))
    var second = file_key(ctx, root, "tests/test_two.mojo")
    assert_true(Bool(second))
    var key = second.value().copy()
    var target = stage_binary(root, [UInt8(1)])
    var helper = root + "/tests/helper.mojo"
    mutate_until_witnessed(helper, "# other\n")
    mutate_until_witnessed(helper, "# before\n")

    var pub = store_publish(
        root,
        key,
        target,
        1.0,
        build_argv("tests/test_two.mojo", target.out_rel),
    )
    assert_equal(pub.kind, PUB_FAILED)
    assert_true(
        "changed while the build ran" in pub.warning,
        "the warning did not name the cause: " + pub.warning,
    )
    assert_false(isdir(root + "/" + key.gen_dir))


def test_file_key_tracks_the_source_and_misses_a_vanished_one() raises:
    var root = temp_root()
    var rel = String("tests/test_key.mojo")
    var before = fixture_key(root, rel, "# before\n")
    var after = fixture_key(root, rel, "# after\n")
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
