"""The happy-path event stream of the session, driven through a real build+run.

Builds a tiny temp tree of known-outcome fixtures and runs the session against
it through a CompositeReporter of TWO recorders (the N=2 seam), then asserts the
whole event stream: ordering (SessionStarted -> excluded -> warning -> file
pairs -> SessionFinished), the selected/excluded counts, the per-file verdicts
(a real PASS and a real FAIL, kept distinct), the summary tally, and the exact
resolved exit code. Both recorders must observe the identical stream.

The `--shuffle` cases belong here for the same reason: what they assert is the
ORDER the stream announces its run files in, and the seed the opening event
carries.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.config import ShardMode
from mtest.model import (
    EventKind,
    NotRunReason,
    Outcome,
    ParseDisposition,
    SessionStartedPayload,
    SessionFinishedPayload,
    FileFinishedPayload,
    WarningPayload,
)
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_session

from session_fixtures import (
    SRC_FAIL,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


def _session_started(rec: RecordingReporter) raises -> SessionStartedPayload:
    """The stream's one `session_started` payload, located by event kind.

    Never by position. Anything a later feature adds to the prelude shifts
    index 0, and unpacking the wrong variant out of an event's payload union
    aborts the process — which takes every other test in this binary with it
    instead of failing one case.

    Args:
        rec: The recorder holding the run's whole event stream.

    Returns:
        A copy of the payload. Allocates it.

    Raises:
        Error: If the stream does not carry exactly one such event.
    """
    var found = -1
    var seen = 0
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.SESSION_STARTED:
            seen += 1
            found = i
    assert_equal(seen, 1, "want exactly one SESSION_STARTED event")
    return rec.event_at(found).data[SessionStartedPayload].copy()


def test_flow_pass_fail_excluded_warning_exit1() raises:
    var root = temp_root()
    write_file(root, "tests/test_a_pass.mojo", SRC_PASS)
    write_file(root, "tests/test_b_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_skipme.mojo", SRC_PASS)

    var config = base_config()
    config.excludes.append("*skipme*")
    config.excludes.append("ghost_*")  # matches nothing -> stale warning

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter(), RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1, "a FAIL must resolve to exit 1")

    ref rec = comp.composite.reporters[0]
    # Full ordered stream: 1 start + 1 excluded + 1 warning + 2 file triples
    # (started, one retrospective test_reported, finished) + 1 finish = 10.
    assert_equal(rec.count(), 10)

    assert_true(rec.kind_at(0) == EventKind.SESSION_STARTED)
    assert_equal(rec.event_at(0).data[SessionStartedPayload].selected_count, 2)
    assert_equal(rec.event_at(0).data[SessionStartedPayload].excluded_count, 1)

    assert_true(rec.kind_at(1) == EventKind.FILE_FINISHED)
    assert_true(rec.outcome_at(1) == Outcome.EXCLUDED)
    assert_equal(rec.path_at(1), "tests/test_skipme.mojo")
    assert_equal(
        rec.event_at(1).data[FileFinishedPayload].exclusion_pattern, "*skipme*"
    )

    assert_true(rec.kind_at(2) == EventKind.WARNING)
    assert_equal(
        rec.event_at(2).data[WarningPayload].warning_kind, "stale-exclusion"
    )

    # Run files, sorted: test_a_pass then test_b_fail. Each emits its per-test
    # TestReported row BETWEEN its file_started and file_finished.
    assert_true(rec.kind_at(3) == EventKind.FILE_STARTED)
    assert_equal(rec.path_at(3), "tests/test_a_pass.mojo")
    assert_true(rec.kind_at(4) == EventKind.TEST_REPORTED)
    assert_true(rec.test_at(4).outcome == Outcome.PASS)
    assert_equal(rec.test_at(4).node.path, "tests/test_a_pass.mojo")
    assert_true(rec.kind_at(5) == EventKind.FILE_FINISHED)
    assert_true(rec.outcome_at(5) == Outcome.PASS)
    assert_equal(rec.path_at(5), "tests/test_a_pass.mojo")
    # The verdict now rests on the PARSED report, not the exit status alone.
    assert_true(rec.parse_disposition_at(5) == ParseDisposition.PARSED)
    assert_equal(rec.event_at(5).data[FileFinishedPayload].passed_tests, 1)

    assert_true(rec.kind_at(6) == EventKind.FILE_STARTED)
    assert_equal(rec.path_at(6), "tests/test_b_fail.mojo")
    assert_true(rec.kind_at(7) == EventKind.TEST_REPORTED)
    assert_true(rec.test_at(7).outcome == Outcome.FAIL)
    assert_true(rec.kind_at(8) == EventKind.FILE_FINISHED)
    assert_true(rec.outcome_at(8) == Outcome.FAIL)
    assert_equal(rec.event_at(8).data[FileFinishedPayload].exit_status, 1)
    assert_equal(rec.event_at(8).data[FileFinishedPayload].failed_tests, 1)

    var last = rec.event_at(9)
    assert_true(last.kind == EventKind.SESSION_FINISHED)
    assert_equal(last.data[SessionFinishedPayload].exit_code, 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.PASS), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.EXCLUDED), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 0
    )
    # The authoritative per-test totals ride on SessionFinished.
    assert_equal(last.data[SessionFinishedPayload].test_counts.passed, 1)
    assert_equal(last.data[SessionFinishedPayload].test_counts.failed, 1)

    # The build command is faithful (the reproduce line), carried as argv.
    var argv = rec.event_at(5).data[FileFinishedPayload].build_argv.copy()
    assert_true("build" in argv)
    assert_true("tests/test_a_pass.mojo" in argv)

    # The N=2 seam: the second recorder observed the identical stream.
    assert_equal(comp.composite.reporters[1].count(), 10)
    assert_true(
        comp.composite.reporters[1].kind_at(9) == EventKind.SESSION_FINISHED
    )


def test_exitfirst_delivers_a_not_run_record_for_the_unrun_file() raises:
    # `-x` stops scheduling after the first failing file, so the second
    # selected file never produces a verdict. Both files are still selected
    # by construction, so both get a record; the never-ran one is classified
    # LIMIT_REACHED, the reason `-x`/`--maxfail` carries.
    var root = temp_root()
    write_file(root, "tests/test_a_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_b_fail.mojo", SRC_FAIL)

    var config = base_config()
    config.exitfirst = True

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1, "a FAIL must resolve to exit 1")
    assert_equal(len(comp.not_run_records), 2)
    assert_equal(comp.not_run_records[0].path, "tests/test_a_fail.mojo")
    assert_equal(comp.not_run_records[1].path, "tests/test_b_fail.mojo")
    assert_true(
        comp.not_run_records[1].reason == NotRunReason.LIMIT_REACHED,
        "the file -x stopped scheduling before must carry LIMIT_REACHED",
    )


def _shuffle_tree() raises -> String:
    """A four-file temp suite whose sorted order is a, b, c, d."""
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    write_file(root, "tests/test_c.mojo", SRC_PASS)
    write_file(root, "tests/test_d.mojo", SRC_PASS)
    return root^


def _run_shuffled(root: String, seed: Int) raises -> List[String]:
    """The ordered FILE_STARTED paths of one shuffled session over `root`."""
    var config = base_config()
    config.shuffle = True
    config.shuffle_seed = seed
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    _ = run_session(config, root, comp)
    ref rec = comp.composite.reporters[0]
    var started = List[String]()
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_STARTED:
            started.append(rec.path_at(i))
    return started^


def test_shuffle_draws_the_frozen_order_for_its_seed() raises:
    # The seed -> order mapping is a frozen 1.x contract, so the expected
    # permutation is written out rather than merely asserted to be "not sorted":
    # a shuffle applied to the wrong list still produces something unsorted.
    # WHERE the shuffle sits relative to the shard partition is a separate
    # property this case cannot see (nothing here is sharded);
    # `test_shard_membership_is_chosen_before_the_shuffle` owns it.
    var starts = _run_shuffled(_shuffle_tree(), 7)
    assert_equal(len(starts), 4)
    assert_equal(starts[0], "tests/test_b.mojo")
    assert_equal(starts[1], "tests/test_c.mojo")
    assert_equal(starts[2], "tests/test_a.mojo")
    assert_equal(starts[3], "tests/test_d.mojo")


def test_same_seed_repeats_and_a_different_seed_reorders() raises:
    var root = _shuffle_tree()
    var first = _run_shuffled(root, 7)
    var again = _run_shuffled(root, 7)
    var other = _run_shuffled(root, 9)
    assert_equal(len(again), 4)
    assert_equal(len(other), 4)
    for i in range(4):
        assert_equal(again[i], first[i], "a seed must reproduce its order")
    # Seed 9 draws c, d, b, a over the same four files: the seed is what the
    # order depends on, not the tree.
    assert_equal(other[0], "tests/test_c.mojo")
    assert_equal(other[1], "tests/test_d.mojo")
    assert_equal(other[2], "tests/test_b.mojo")
    assert_equal(other[3], "tests/test_a.mojo")


def test_shard_membership_is_chosen_before_the_shuffle() raises:
    # `slice:1/2` deals the SORTED list round-robin, so this shard owns sorted
    # indices 0 and 2 — a and c. Shuffling first would have dealt b and a from
    # seed 7's b, c, a, d, so the MEMBERSHIP assertion is what pins the order of
    # the two operations; the permutation below then proves the shuffle still
    # ran afterwards (seed 9 swaps a two-element list).
    var config = base_config()
    config.shard_mode = ShardMode.SLICE
    config.shard_m = 1
    config.shard_n = 2
    config.shuffle = True
    config.shuffle_seed = 9
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    _ = run_session(config, _shuffle_tree(), comp)
    ref rec = comp.composite.reporters[0]
    var started = List[String]()
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_STARTED:
            started.append(rec.path_at(i))
    assert_equal(len(started), 2)
    assert_equal(started[0], "tests/test_c.mojo")
    assert_equal(started[1], "tests/test_a.mojo")


def test_gate_files_keep_their_listed_order_under_shuffle() raises:
    # Gates are not in the shuffled list at all: they run first, in the order
    # they were listed, which is deliberately not sorted order here.
    var root = temp_root()
    write_file(root, "tests/test_gate_z.mojo", SRC_PASS)
    write_file(root, "tests/test_gate_m.mojo", SRC_PASS)
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)

    var config = base_config()
    config.gates.append("tests/test_gate_z.mojo")
    config.gates.append("tests/test_gate_m.mojo")
    config.shuffle = True
    config.shuffle_seed = 9
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    _ = run_session(config, root, comp)
    ref rec = comp.composite.reporters[0]
    var started = List[String]()
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_STARTED:
            started.append(rec.path_at(i))
    assert_equal(len(started), 4)
    assert_equal(started[0], "tests/test_gate_z.mojo")
    assert_equal(started[1], "tests/test_gate_m.mojo")
    # Seed 9 swaps the two-file run set, so the gates above are not merely
    # sitting in an order the shuffle happened to leave alone.
    assert_equal(started[2], "tests/test_b.mojo")
    assert_equal(started[3], "tests/test_a.mojo")


def test_seed_zero_is_a_seed_not_an_unset_sentinel() raises:
    # `-1` is the "no --seed given" sentinel; `0` is an ordinary seed. Widening
    # the session's check to `<= 0` would silently draw entropy instead, which
    # only a pinned seed-0 permutation plus the reported seed can catch.
    var config = base_config()
    config.shuffle = True
    config.shuffle_seed = 0
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    _ = run_session(config, _shuffle_tree(), comp)
    ref rec = comp.composite.reporters[0]
    assert_equal(_session_started(rec).shuffle_seed, 0)
    var started = List[String]()
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_STARTED:
            started.append(rec.path_at(i))
    assert_equal(len(started), 4)
    assert_equal(started[0], "tests/test_c.mojo")
    assert_equal(started[1], "tests/test_b.mojo")
    assert_equal(started[2], "tests/test_a.mojo")
    assert_equal(started[3], "tests/test_d.mojo")


def test_unseeded_shuffle_resolves_a_seed_before_announcing_the_run() raises:
    # The header has to be able to quote a seed for EVERY shuffled run, so the
    # derivation happens ahead of SessionStarted, never lazily at the epilogue.
    var config = base_config()
    config.shuffle = True
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    _ = run_session(config, _shuffle_tree(), comp)
    ref rec = comp.composite.reporters[0]
    var started = _session_started(rec)
    assert_true(started.shuffle)
    assert_true(
        started.shuffle_seed >= 0, "an unseeded --shuffle must resolve a seed"
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
