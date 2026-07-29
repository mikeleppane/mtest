"""A build the run did not keep: retried, killed, or superseded.

Split out of `test_session_cache_seam_faults.mojo` by weight, so that neither
suite carries two of the fixed per-process compiler payments a real session
makes.

The subject is the boundary between "this run compiled something" and "the
store may answer with it". A run retried after a crash compiled twice and kept
neither result; a compile killed mid-flight leaves a staging directory that must
never be published or counted; and a precompile stamp replaced by a directory is
refused rather than read. In each case the counters and the store have to agree
that nothing was added.
"""
from std.ffi import external_call
from std.os import getenv, makedirs, remove
from std.os.path import exists, isdir
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import Precompile
from mtest.model import (
    AttemptFinishedPayload,
    EventKind,
    FileFinishedPayload,
    InternalErrorPayload,
    Outcome,
    SessionFinishedPayload,
    WarningPayload,
)
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.platform import read_bounded_regular_file, read_regular_file_bytes
from mtest.session import run_session
from mtest.session.store import PRECOMPILE_SUBDIR

from cache_fixtures import dir_listing, run_recording_session
from session_fixtures import (
    SRC_CHAMELEON,
    SRC_COMPILE_ERROR,
    SRC_CRASH,
    SRC_PASS,
    base_config,
    write_file,
)
from tmptree import temp_root


comptime _STORE_DIR = ".mtest-cache/build-v1"
"""The store's generations directory, relative to a run root."""


def _recorder() -> RecordingCoordinator[RecordingReporter]:
    """The recording triple every raw-stream case in this module drives."""
    return RecordingCoordinator(CompositeReporter(Tuple(RecordingReporter())))


def _counters(rec: RecordingReporter) raises -> SessionFinishedPayload:
    """The session's one terminal payload, carrying the build/cache counters.

    Args:
        rec: The recorder to read back.

    Returns:
        A copy of the one recorded `SessionFinished` payload.

    Raises:
        Error: When the recording does not hold exactly one terminal record.
    """
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.SESSION_FINISHED:
            return rec.event_at(i).data[SessionFinishedPayload].copy()
    raise Error("the session never dispatched SessionFinished")


def _verdict_of(
    rec: RecordingReporter, path: String
) raises -> FileFinishedPayload:
    """One file's terminal verdict payload, found by kind and path.

    Args:
        rec: The recorder to read back.
        path: The root-relative file whose verdict is wanted.

    Returns:
        A copy of that file's `FileFinished` payload.

    Raises:
        Error: When the file never reached a verdict.
    """
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_FINISHED and rec.path_at(i) == path:
            return rec.event_at(i).data[FileFinishedPayload].copy()
    raise Error("no FileFinished for " + path)


comptime _COUNTING_MOJO = "/scripts/fixtures/toolchain/counting_mojo.py"
"""The invocation-counting compiler shim, relative to the repository root."""

comptime _COUNTER_REL = ".mtest-precompile-invocations"
"""Where that shim appends one line per `mojo precompile` it was started for."""


def _precompile_invocations(root: String) raises -> Int:
    """How many times the compiler was started for a precompile step under
    `root`.

    The one oracle for "the step was skipped" that the code under test does not
    write: a result field saying so is set by that code, so a bug that sets it
    and compiles anyway reads as a pass, while a process that never started
    cannot be faked. The shim appends one line per `mojo precompile` to a counter
    in its current directory, and every compile child runs with the invocation
    root as its current directory, so the counter belongs to this run alone.

    Args:
        root: The invocation root the sessions ran in.

    Returns:
        The number of recorded invocations, and 0 when the counter does not
        exist at all.

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


def test_sequential_run_retry_neither_counts_nor_publishes() raises:
    """A crash-class RUN retry re-enters the loop and stays out of the store.

    The retry loop is the trap this seam has to survive: a second pass through
    the loop must not count, must not probe, and must not publish a second time.
    A crashing binary with one retry drives exactly that — the file is compiled
    once, published once, then re-run — so the counters move exactly once
    between them and the store ends the run holding the single generation the
    first attempt wrote, with no staging directory beside it.

    The retry itself is asserted, not assumed. Every counter claim below is also
    true of a file that never retried at all, so without the `AttemptFinished`
    evidence this case would keep passing while silently testing nothing if
    `SRC_CRASH` ever stopped being retry-eligible.
    """
    var root = temp_root()
    write_file(root, "tests/test_boom.mojo", SRC_CRASH)
    var config = base_config()
    config.retries = 1

    var comp = _recorder()
    var code = run_session(config, root, comp)
    assert_equal(code, 1, "a signalled binary is a CRASH, exit 1")
    ref rec = comp.composite.reporters[0]

    # The premise: a first attempt was recorded as non-final, and the verdict
    # spent two attempts. Only a real retry produces both.
    var retries_seen = 0
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.ATTEMPT_FINISHED:
            ref ap = rec.event_at(i).data[AttemptFinishedPayload]
            retries_seen += 1
            assert_equal(ap.step, "run", "the retried step must be the RUN")
            assert_equal(
                ap.attempt_index, 1, "the retried attempt is the first"
            )
            assert_equal(ap.attempts_planned, 2, "--retries 1 plans 2 attempts")
    assert_equal(retries_seen, 1, "exactly one attempt was retried")
    var verdict = _verdict_of(rec, "tests/test_boom.mojo")
    assert_true(verdict.outcome == Outcome.CRASH, "the file must end CRASH")
    assert_equal(
        verdict.attempts_used, 2, "the file must have spent 2 attempts"
    )

    var counters = _counters(rec)
    assert_equal(
        counters.built_files, 1, "only the first attempt's compile is admitted"
    )
    assert_equal(
        counters.cached_files,
        0,
        "a retry must not probe: the store holds only what this run just wrote",
    )
    var entries = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(entries),
        1,
        "the retry must publish nothing and stage nothing of its own",
    )
    assert_true(
        String(entries[0]).startswith("tests_stest_uboom_h"),
        "the one store entry is not this file's generation: " + entries[0],
    )


def test_compile_kill_rebuild_neither_counts_nor_publishes() raises:
    """The compile-kill rebuild is the retry that re-enters with `do_build`.

    This is the one control-flow claim the seam rests on that no other case can
    reach. A crash-class BUILD failure is the only retry that comes back around
    with `do_build = True`, so a first-attempt guard written as `do_build` alone
    would fire a second time here — probing a key this session already answered,
    and publishing a quarantined retry's binary into a store other runs read.
    The guard also tests `attempt_index == 1`, and this pins that it must.

    `fake_retry_crash_mojo.py` makes the shape deterministic rather than
    wall-clock dependent: its first build takes the `-o` path, writes nothing
    runnable, and then sleeps far past any deadline, so `compile_timeout_secs =
    1` ALWAYS kills it — there is no race in which the compile finishes early
    and the scenario silently degrades. Its second build (chosen by the marker
    the first one dropped, not by argv) succeeds at the retry's fresh
    `.attempt-2` path under `build/bin`.

    What that leaves observable: the counters moved exactly once, for the
    first-attempt compile that was killed — a compile FAILURE is still an
    admission — and the store is EMPTY, because the killed first attempt's
    staging directory was discarded and the rebuild never staged one at all.
    """
    var marker = (
        getenv("PIXI_PROJECT_ROOT", "")
        + "/build/e2e-scratch/retry_crash_build_marker"
    )
    # The shim picks its branch off a marker under the REPO root, not the test's
    # temp tree, so it is shared state: a marker left by an earlier run would
    # make the FIRST build succeed and the scenario evaporate. Clear it on both
    # sides rather than trusting whatever ran last.
    if exists(marker):
        remove(marker)

    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.retries = 1
    config.compile_timeout_secs = 1
    config.mojo_path = (
        getenv("PIXI_PROJECT_ROOT", "")
        + "/scripts/fixtures/toolchain/fake_retry_crash_mojo.py"
    )

    var comp = _recorder()
    var code: Int
    try:
        code = run_session(config, root, comp)
    finally:
        if exists(marker):
            remove(marker)

    ref rec = comp.composite.reporters[0]
    # The premise: the first BUILD was killed and retried. Without this the
    # counter claims below would also hold for a run that never retried.
    var build_retries = 0
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.ATTEMPT_FINISHED:
            ref ap = rec.event_at(i).data[AttemptFinishedPayload]
            if ap.step == "build":
                build_retries += 1
                assert_equal(
                    ap.attempt_index, 1, "the killed compile is attempt 1"
                )
    assert_equal(
        build_retries, 1, "the first compile must have been killed and retried"
    )

    var counters = _counters(rec)
    assert_equal(
        counters.built_files,
        1,
        (
            "the killed first compile is one admission; the rebuild that"
            " followed it is a retry and must not count"
        ),
    )
    assert_equal(counters.cached_files, 0, "no hit was possible on a cold tree")
    assert_equal(
        len(dir_listing(root + "/" + _STORE_DIR)),
        0,
        (
            "the store must be empty: the killed attempt's staging directory is"
            " discarded, and the rebuild neither stages nor publishes"
        ),
    )
    # The rebuild is invocation-private, and `build/bin` is where it lands.
    assert_true(
        exists(root + "/build/bin"),
        "the retry path still needs build/bin in the tree",
    )
    # A second settle would try to publish the FIRST attempt's staging directory
    # a second time — it was discarded when that compile failed, so the publish
    # fails and says so. Nothing here may produce that warning.
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.WARNING:
            assert_false(
                rec.event_at(i).data[WarningPayload].warning_kind
                == "cache-publish",
                (
                    "the rebuild attempted a publication; the settle must fire"
                    " once, on the first attempt only"
                ),
            )
    assert_equal(code, 1, "the rebuilt binary crashes, so the file is CRASH")


def test_pool_run_retry_neither_counts_nor_publishes() raises:
    """A pooled crash-class retry stays out of both the counters and the store.

    The pool is the third seam, and the only one where a file's build and its
    run are separate dispatches through a persistent phase machine: a retry
    re-enters that machine at the run phase for a file whose build already
    published. A guard written against the phase rather than against the attempt
    index would fire again here, counting a second admission for a file that
    reached the compiler once and writing a retry's binary into a store other
    runs read.

    The retry is asserted rather than assumed, because every counter claim below
    is equally true of a file that never retried at all.
    """
    var root = temp_root()
    write_file(root, "tests/test_boom.mojo", SRC_CRASH)
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.workers = 2
    config.retries = 1

    var comp = _recorder()
    var code = run_session(config.copy(), root, comp)
    assert_equal(code, 1, "a signalled binary is a CRASH, exit 1")
    ref rec = comp.composite.reporters[0]

    var retries_seen = 0
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.ATTEMPT_FINISHED:
            ref ap = rec.event_at(i).data[AttemptFinishedPayload]
            retries_seen += 1
            assert_equal(ap.step, "run", "the retried step must be the RUN")
            assert_equal(
                ap.attempt_index, 1, "the retried attempt is the first"
            )
    assert_equal(retries_seen, 1, "exactly one attempt was retried")

    var counters = _counters(rec)
    assert_equal(counters.built_files, 2, "each file is admitted exactly once")
    assert_equal(counters.cached_files, 0, "no hit was possible on a cold tree")
    var entries = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(entries),
        2,
        (
            "the store must hold one generation per file; the retry publishes"
            " nothing and stages nothing of its own"
        ),
    )

    # What the store holds is the FIRST attempt's work, and it validates: a
    # warm run serves both files rather than rebuilding either.
    var warm = run_recording_session(config^, root)
    assert_equal(warm.code, 1, "the cached binary still crashes")
    assert_equal(warm.cached_files, 2, "both files are served from the store")
    assert_equal(warm.built_files, 0, "the warm run compiles nothing")


def test_a_precompile_stamp_replaced_by_a_directory_is_refused() raises:
    """A stamp that is not a regular file can never grant a skip.

    A stamp is the one cache record that lives at a name a later run looks up by
    key alone, so "the name exists" must never be enough. A directory is the
    sharpest way to say the name is occupied by something the store did not
    write: it survives an `unlink`, it cannot be parsed, and a probe that
    accepted the name's existence would skip a step whose output nothing has
    verified. The refusal is silent and self-healing — the occupant is removed
    no-follow, the step runs, and the record it then writes is a real stamp.
    """
    var root = temp_root()
    write_file(
        root, "goodpkg/__init__.mojo", "def helper() -> Int:\n    return 7\n"
    )
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.mojo_path = getenv("PIXI_PROJECT_ROOT", "") + _COUNTING_MOJO
    config.precompiles.append(Precompile("goodpkg", None))

    var cold = run_recording_session(config.copy(), root)
    assert_equal(cold.code, 0, "a clean step plus a passing file is exit 0")
    assert_equal(
        _precompile_invocations(root), 1, "the cold run must build the step"
    )

    var warm = run_recording_session(config.copy(), root)
    assert_equal(warm.code, 0, "a warm run is still exit 0")
    assert_equal(
        _precompile_invocations(root),
        1,
        "the premise: an unchanged step is skipped before anything is broken",
    )

    var stamp_dir = root + "/" + _STORE_DIR + "/" + PRECOMPILE_SUBDIR
    var stamps = dir_listing(stamp_dir)
    assert_equal(len(stamps), 1, "the step must have left exactly one stamp")
    var stamp = stamp_dir + "/" + stamps[0]
    remove(stamp)
    makedirs(stamp)
    assert_true(isdir(stamp), "the stamp name must now be a directory")

    var blocked = run_recording_session(config.copy(), root)
    assert_equal(
        blocked.code,
        0,
        "an unusable stamp may never fail an otherwise green run",
    )
    assert_equal(
        _precompile_invocations(root),
        2,
        (
            "the step was skipped against a stamp that is not a regular file;"
            " existence of the name is not a record"
        ),
    )
    assert_false(
        isdir(stamp),
        "the occupant must be removed so the step can record itself again",
    )

    var healed = run_recording_session(config^, root)
    assert_equal(healed.code, 0)
    assert_equal(
        _precompile_invocations(root),
        2,
        "the replacement stamp must skip the step exactly as the first did",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
