"""Tests for the two-phase store seam every build driver opens and closes.

The seam's own contract, tested away from any driver: what `seam_begin` learns,
what `seam_stage` claims, and what `seam_settle` and `seam_discard` leave
behind. The store protocol underneath it is pinned in
`test_session_store_artifact.mojo` (probe and publish) and
`test_session_store_keys.mojo` (keying); these cases pin the answers the seam
hands a driver, which is what decides which binary runs and which command line a
reproduce line quotes.

Every case keys a bare `CacheContext` over a stub source, never the pinned
toolchain: the subject is the seam's own routing, and an empty session prefix
proves it for nothing.
"""
from std.os.path import exists, isdir
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from mtest.session.scratch import _mangle
from mtest.session.store import (
    PROBE_HIT,
    PUB_OK,
    CacheContext,
    FileKey,
    file_key,
    store_probe,
    store_publish,
)
from mtest.session.store_seam import (
    SeamStaging,
    seam_begin,
    seam_discard,
    seam_settle,
    seam_stage,
)

from cache_fixtures import make_executable, write_bytes
from session_fixtures import write_file
from tmptree import temp_root


def _keyed(root: String, rel: String, body: String) raises -> FileKey:
    """Key a REAL source at `root/rel`, so the publication guard can pass."""
    write_file(root, rel, body)
    var ctx = CacheContext()
    var key = file_key(ctx, root, rel)
    if not key:
        raise Error("test: file_key failed for '" + rel + "'")
    return key.value().copy()


def _argv(rel: String, out_rel: String) -> List[String]:
    """The shape every build site emits: `-o` and its path as two tokens."""
    return ["mojo", "build", "-o", String(out_rel), String(rel)]


def _stage_through_seam(
    mut ctx: CacheContext, root: String, rel: String, payload: List[UInt8]
) raises -> SeamStaging:
    """Open the seam for `rel` and put `payload` where the compiler would.

    Args:
        ctx: The session's cache state.
        root: The invocation root.
        rel: The source, which must already exist.
        payload: The bytes standing in for a compiled binary. The execute bit
            is set, because a probe refuses a generation it cannot spawn.

    Returns:
        The staging, with its `bin` written and executable.

    Raises:
        Error: If the store staged nothing.
    """
    var staging = seam_begin(ctx, root, rel)
    seam_stage(ctx, staging, root, _mangle(rel))
    if not staging.target.ok():
        raise Error("test: seam_stage claimed no staging directory")
    write_bytes(root, staging.target.out_rel, payload)
    make_executable(root + "/" + staging.target.out_rel)
    return staging^


def test_seam_begin_under_a_disabled_context_owes_nothing() raises:
    var root = temp_root()
    var rel = String("tests/test_off.mojo")
    write_file(root, rel, "# off\n")
    var ctx = CacheContext.disabled("--no-cache")
    var staging = seam_begin(ctx, root, rel)
    assert_false(staging.hit)
    assert_false(Bool(staging.key))
    # Nothing was even created: a disabled context must not leave the cache
    # directory behind for a user who asked this run not to touch it.
    assert_false(exists(root + "/.mtest-cache"))
    # And staging is refused too, so a driver that calls both unconditionally
    # still compiles the ordinary way.
    seam_stage(ctx, staging, root, _mangle(rel))
    assert_false(staging.target.ok())


def test_seam_begin_disables_the_cache_over_an_unreadable_source() raises:
    var root = temp_root()
    var ctx = CacheContext()
    var staging = seam_begin(ctx, root, "tests/test_absent.mojo")
    assert_false(staging.hit)
    assert_false(Bool(staging.key))
    assert_false(ctx.enabled)
    assert_equal(
        ctx.disable_reason, "cannot read the test file 'tests/test_absent.mojo'"
    )


def test_seam_begin_carries_the_key_on_a_miss() raises:
    var root = temp_root()
    var rel = String("tests/test_miss.mojo")
    write_file(root, rel, "# miss\n")
    var ctx = CacheContext()
    var staging = seam_begin(ctx, root, rel)
    assert_false(staging.hit)
    assert_true(Bool(staging.key))
    assert_true(ctx.enabled)
    # A probe alone stages nothing: the pool keys its whole batch before the
    # scheduler starts, and a batch halted by `-x` would orphan one directory
    # per undispatched file.
    assert_false(staging.target.ok())


def test_seam_begin_serves_a_published_build_with_its_own_facts() raises:
    var root = temp_root()
    var rel = String("tests/test_warm.mojo")
    var ctx = CacheContext()
    write_file(root, rel, "# warm\n")
    var staging = _stage_through_seam(ctx, root, rel, [UInt8(1), UInt8(2)])
    var staged_out = String(staging.target.out_rel)
    var settled = seam_settle(staging^, root, 2.5, _argv(rel, staged_out))
    assert_true(settled.settled)

    var warm = seam_begin(ctx, root, rel)
    assert_true(warm.hit)
    # Nothing is owed on a hit: the generation this binary came from is already
    # the store's, so a later settle must publish nothing.
    assert_false(Bool(warm.key))
    assert_equal(warm.bin_rel, settled.bin_rel)
    # The stored build's OWN duration, not zero: the SLOW token has to read the
    # same on a warm run as it did on the cold one.
    assert_true(
        warm.build_seconds > 2.4 and warm.build_seconds < 2.6,
        "the stored build duration did not survive: "
        + String(warm.build_seconds),
    )
    # The reproduce line names the generation, never the staging directory the
    # compile actually wrote to, which the publishing rename consumed.
    assert_equal(len(warm.argv), 5)
    assert_equal(warm.argv[3], settled.bin_rel)
    assert_true(exists(root + "/" + warm.argv[3]))
    assert_false(exists(root + "/" + staged_out))


def test_seam_settle_publishes_and_hands_back_the_generation() raises:
    var root = temp_root()
    var rel = String("tests/test_pub.mojo")
    var ctx = CacheContext()
    write_file(root, rel, "# pub\n")
    var key = _keyed(root, rel, "# pub\n")
    var staging = _stage_through_seam(ctx, root, rel, [UInt8(7)])
    var staged_dir = String(staging.target.tmp_dir_rel)
    var out = seam_settle(staging^, root, 1.0, _argv(rel, staged_dir + "/bin"))
    assert_true(out.settled)
    # The store owns the binary now, which is the one fact a driver needs: a
    # generation can be reaped or briefly quarantined before this process execs
    # it, and that is a file to compile rather than an internal error.
    assert_true(out.owned)
    assert_equal(out.warning, "")
    assert_equal(out.bin_rel, key.gen_dir + "/bin")
    # Run `bin_rel`, record `argv`: the argv's `-o` was repointed at the
    # generation, because the staging directory the build ran with is gone.
    assert_equal(len(out.argv), 5)
    assert_equal(out.argv[3], key.gen_dir + "/bin")
    assert_false(isdir(root + "/" + staged_dir))
    assert_equal(store_probe(root, key).kind, PROBE_HIT)


def test_seam_settle_adopts_a_winner_and_records_its_command_line() raises:
    var root = temp_root()
    var rel = String("tests/test_adopted.mojo")
    var ctx = CacheContext()
    write_file(root, rel, "# adopted\n")
    var key = _keyed(root, rel, "# adopted\n")

    # Both stagings are opened BEFORE either publishes: the seam's own probe
    # would hit the winner's generation and carry no key, which is the shape
    # this case is not about.
    var winner = _stage_through_seam(ctx, root, rel, [UInt8(3)])
    var loser = _stage_through_seam(ctx, root, rel, [UInt8(3)])
    assert_equal(
        store_publish(
            root, key, winner.target, 1.0, _argv(rel, winner.target.out_rel)
        ).kind,
        PUB_OK,
    )

    var loser_argv = _argv(rel, loser.target.out_rel)
    # A sixth token the winner's command line does not carry, so an adopted
    # argv can be told apart from a merely rewritten one.
    loser_argv.append("--loser-only")
    var out = seam_settle(loser^, root, 1.0, loser_argv^)
    assert_true(out.settled)
    assert_true(out.owned)
    assert_equal(out.warning, "")
    assert_equal(out.bin_rel, key.gen_dir + "/bin")
    # The adopted binary is the winner's, so the reproduce line is the winner's
    # too: this run's own command line describes bytes nobody will run.
    assert_equal(len(out.argv), 5)
    assert_equal(out.argv[3], key.gen_dir + "/bin")


def test_seam_settle_reports_a_failed_publication_without_a_verdict() raises:
    var root = temp_root()
    var rel = String("tests/test_pubfail.mojo")
    var ctx = CacheContext()
    write_file(root, rel, "# pubfail\n")
    var key = _keyed(root, rel, "# pubfail\n")
    var staging = _stage_through_seam(ctx, root, rel, [UInt8(5)])
    var staged_out = String(staging.target.out_rel)
    # A generation that EXISTS but does not validate: adoption re-probes it,
    # rejects it, and the publication loses. Planted AFTER the seam opened,
    # because the seam's own probe would have discarded it as corruption.
    write_bytes(root, key.gen_dir + "/bin", [UInt8(4)])
    write_bytes(root, key.gen_dir + "/meta", [UInt8(110)])

    var out = seam_settle(staging^, root, 1.0, _argv(rel, staged_out))
    assert_true(out.settled)
    # Not owned: nothing entered the store, so the driver must not treat a
    # later spawn failure as the store's quarantine gap.
    assert_false(out.owned)
    assert_true(
        "could not publish the cached build" in out.warning,
        "publication failed somewhere other than the commit: " + out.warning,
    )
    # The caller runs the binary it just built, so the staged copy survives and
    # both the run path and the record name it.
    assert_equal(out.bin_rel, staged_out)
    assert_equal(out.argv[3], staged_out)
    assert_true(exists(root + "/" + staged_out))


def test_seam_settle_publishes_nothing_when_nothing_was_staged() raises:
    var root = temp_root()
    var rel = String("tests/test_unstaged.mojo")
    write_file(root, rel, "# unstaged\n")
    var ctx = CacheContext()
    var staging = seam_begin(ctx, root, rel)
    assert_true(Bool(staging.key))
    var out = seam_settle(staging^, root, 1.0, _argv(rel, "build/bin/x"))
    # A keyed but unstaged file settles nothing, so the driver keeps the binary
    # and the command line it already had.
    assert_false(out.settled)
    assert_false(out.owned)
    assert_equal(out.bin_rel, "")
    assert_equal(len(out.argv), 0)
    assert_equal(out.warning, "")


def test_seam_discard_removes_the_staging_a_dead_build_left() raises:
    var root = temp_root()
    var rel = String("tests/test_discard.mojo")
    var ctx = CacheContext()
    write_file(root, rel, "# discard\n")
    var key = _keyed(root, rel, "# discard\n")
    var staging = _stage_through_seam(ctx, root, rel, [UInt8(6)])
    var staged_dir = String(staging.target.tmp_dir_rel)
    assert_true(isdir(root + "/" + staged_dir))
    seam_discard(staging^, root)
    assert_false(isdir(root + "/" + staged_dir))
    # Nothing was published: an aborted build must not leave a generation other
    # runs would serve.
    assert_false(isdir(root + "/" + key.gen_dir))


def test_taking_a_staging_leaves_the_slot_owing_nothing() raises:
    var root = temp_root()
    var rel = String("tests/test_taken.mojo")
    var ctx = CacheContext()
    write_file(root, rel, "# taken\n")
    var staging = _stage_through_seam(ctx, root, rel, [UInt8(8)])
    var staged_out = String(staging.target.out_rel)

    var detached = staging.take()
    # The slot is empty, so the second settle a reshaped scheduler might make
    # publishes nothing rather than publishing this file twice.
    assert_false(Bool(staging.key))
    assert_false(staging.target.ok())
    assert_false(
        seam_settle(staging^, root, 1.0, _argv(rel, staged_out)).settled
    )

    var out = seam_settle(detached^, root, 1.0, _argv(rel, staged_out))
    assert_true(out.settled)
    assert_true(out.owned)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
