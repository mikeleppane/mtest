"""The pure worker-count and build-token arithmetic of the parallel scheduler.

No processes, no filesystem, no clock: every function under test is fed its
core count and returns, so the whole decision table pins deterministically. The
`auto` resolver, the effective-cap clamp and its loud note, and the build-token
budget (including the `workers == 1` value the sequential path never emits and
the `-n 64` oversubscription the token gate must bound) all live here.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.session.pool_plan import (
    build_tokens,
    partition_serial,
    resolve_auto_workers,
    resolve_workers,
    stale_serials,
)


def test_auto_is_half_the_cores_floored_at_one() raises:
    assert_equal(resolve_auto_workers(1), 1)
    assert_equal(resolve_auto_workers(2), 1)
    assert_equal(resolve_auto_workers(3), 1)
    assert_equal(resolve_auto_workers(4), 2)
    assert_equal(resolve_auto_workers(6), 3)


def test_auto_is_capped_at_four() raises:
    assert_equal(resolve_auto_workers(8), 4)
    assert_equal(resolve_auto_workers(16), 4)
    assert_equal(resolve_auto_workers(128), 4)


def test_auto_never_below_one_even_at_zero_cores() raises:
    assert_equal(resolve_auto_workers(0), 1)


def test_resolve_auto_request_uses_the_auto_count() raises:
    var plan = resolve_workers(0, 8, 64)
    assert_equal(plan.resolved, 4)
    assert_false(plan.clamped)
    assert_equal(plan.limiting_note(), "")


def test_resolve_explicit_request_stands_when_under_cap() raises:
    var plan = resolve_workers(2, 8, 64)
    assert_equal(plan.resolved, 2)
    assert_false(plan.clamped)


def test_resolve_clamps_to_the_cap_and_notes_it_loudly() raises:
    var plan = resolve_workers(8, 16, 4)
    assert_equal(plan.resolved, 4)
    assert_true(plan.clamped)
    var note = plan.limiting_note()
    assert_true("8" in note, "the note names the requested count")
    assert_true("4" in note, "the note names the cap it clamped to")


def test_resolve_clamps_an_auto_request_and_names_it_auto() raises:
    var plan = resolve_workers(0, 8, 2)
    assert_equal(plan.resolved, 2)
    assert_true(plan.clamped)
    assert_true("auto" in plan.limiting_note(), "an auto clamp says 'auto'")


def test_tokens_at_one_worker_take_every_core() raises:
    # The value the token budget yields at one worker. The sequential path
    # never consults it — it emits no `--num-threads` flag at all — but the
    # arithmetic is total and defined here regardless.
    assert_equal(build_tokens(1, 8), 8)
    assert_equal(build_tokens(1, 1), 1)


def test_tokens_split_the_cores_across_the_workers() raises:
    assert_equal(build_tokens(2, 8), 4)
    assert_equal(build_tokens(4, 8), 2)
    assert_equal(build_tokens(3, 8), 2)


def test_tokens_never_below_one_and_bound_oversubscription() raises:
    # -n 64 on an 8-core box: each build takes ONE thread, so the token gate
    # admits at most 8 concurrent builds (8 * 1 == cores), never 64.
    assert_equal(build_tokens(64, 8), 1)
    # The concurrent-build thread product never exceeds the cores.
    assert_true(min(64, 8) * build_tokens(64, 8) <= 8)
    assert_true(2 * build_tokens(2, 8) <= 8)
    assert_true(3 * build_tokens(3, 8) <= 8)


def test_tokens_are_one_when_cores_unknown() raises:
    assert_equal(build_tokens(4, 0), 1)


def test_partition_no_globs_leaves_everything_parallel() raises:
    var files: List[String] = ["a/x.mojo", "b/y.mojo"]
    var globs = List[String]()
    var split = partition_serial(files, globs)
    assert_equal(len(split.serial), 0)
    assert_equal(len(split.parallel), 2)
    assert_equal(split.parallel[0], "a/x.mojo")
    assert_equal(split.parallel[1], "b/y.mojo")


def test_partition_pins_matching_and_preserves_order() raises:
    # A glob whose whole-path match hits two of three files pins exactly those,
    # and each sub-list keeps the input order as a stable sub-sequence.
    var files: List[String] = [
        "e2e/p/test_a.mojo",
        "e2e/p/test_b.mojo",
        "e2e/p/test_c.mojo",
    ]
    var globs: List[String] = ["*test_[ac]*"]
    var split = partition_serial(files, globs)
    assert_equal(len(split.serial), 2)
    assert_equal(split.serial[0], "e2e/p/test_a.mojo")
    assert_equal(split.serial[1], "e2e/p/test_c.mojo")
    assert_equal(len(split.parallel), 1)
    assert_equal(split.parallel[0], "e2e/p/test_b.mojo")


def test_partition_file_matching_any_of_several_globs_goes_serial() raises:
    # Matching AT LEAST ONE glob is enough to pin a file; the two globs together
    # select two files, each from a different pattern.
    var files: List[String] = ["x/one.mojo", "y/two.mojo", "z/three.mojo"]
    var globs: List[String] = ["*one*", "*three*"]
    var split = partition_serial(files, globs)
    assert_equal(len(split.serial), 2)
    assert_equal(split.serial[0], "x/one.mojo")
    assert_equal(split.serial[1], "z/three.mojo")
    assert_equal(len(split.parallel), 1)
    assert_equal(split.parallel[0], "y/two.mojo")


def test_stale_serials_reports_globs_matching_nothing() raises:
    var files: List[String] = ["a/x.mojo", "b/y.mojo"]
    var globs: List[String] = ["*x*", "*nope*"]
    var stale = stale_serials(files, globs)
    assert_equal(len(stale), 1)
    assert_equal(stale[0], "*nope*")


def test_stale_serials_empty_when_all_match() raises:
    var files: List[String] = ["a/x.mojo", "b/y.mojo"]
    var globs: List[String] = ["*x*", "*y*"]
    var stale = stale_serials(files, globs)
    assert_equal(len(stale), 0)
