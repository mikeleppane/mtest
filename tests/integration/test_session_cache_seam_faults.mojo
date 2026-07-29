"""What a failed, retried, or unstartable build must not publish or count.

Split out of `test_session_cache_seam.mojo` by weight: a suite that drives real
sessions pays a fixed per-process price for the first build it puts through the
compiler, so two suites cost two payments however the tests are divided, and the
seam is chosen among those that balance.

The subject is the store's negative space. A cache is only worth having if a
run that went wrong leaves nothing behind that a later run would trust: a
compile that failed counts as built and publishes nothing, a run retried after a
crash neither counts nor publishes, a staging directory deleted under a failed
spawn is never named in a diagnostic, and a cached binary that will not start
costs a rebuild rather than a false pass.
"""
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
from foreign_abi import configure_native_fault, reset_native_faults
from session_fixtures import (
    SRC_CHAMELEON,
    SRC_COMPILE_ERROR,
    SRC_CRASH,
    SRC_PASS,
    base_config,
    write_file,
)
from tmptree import temp_root


comptime _OP_PIPE_STDOUT = 11
"""`MTEST_EXEC_OP_PIPE_STDOUT`: the child's stdout pipe, opened per dispatch."""


comptime _STORE_DIR = ".mtest-cache/build-v1"
"""The store's generations directory, relative to a run root."""


comptime _EIO = 5
"""`EIO`, the errno a faulted native adapter operation reports."""

comptime _RUN_SPAWN_OCCURRENCE = 3
"""Which stdout-pipe open is the RUN spawn of a one-file cached session.

Three children are dispatched, in this order: `<compiler> --version` (the cache
key's toolchain-version frame), the build, then the run. The case that uses this
does not trust the arithmetic — it asserts the faulted step is `"run"`, so a
miscount fails loudly instead of quietly measuring the build spawn.
"""


comptime _WARM_RUN_SPAWN_OCCURRENCE = 2
"""Which stdout-pipe open is the RUN dispatch of a one-file WARM session.

Two children are dispatched, in this order: `<compiler> --version`, which feeds
the key's toolchain-version frame and is not memoized across sessions, and the
run of the stored binary. There is no build, which is what a warm run means.
The cases that use this do not trust the arithmetic — they assert the
`cache-rebuild` warning only a failed cache-hit run can produce, so a fault that
landed on the `--version` child fails loudly rather than passing over a run that
never reached the store.
"""


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


def _saw_warning_kind(rec: RecordingReporter, kind: String) raises -> Bool:
    """Whether the recording holds a `WARNING` event of `kind`.

    Found BY KIND, never by position: this module's cases insert and remove
    warnings, and an index-addressed assertion would break every time one moved.

    Args:
        rec: The recorder to read back.
        kind: The warning kind to look for, as `Event.warning` spells it.

    Returns:
        True if at least one warning carries that kind.

    Raises:
        Error: If the recording cannot be read back.
    """
    for i in range(rec.count()):
        var e = rec.event_at(i)
        if e.kind == EventKind.WARNING:
            if e.data[WarningPayload].warning_kind == kind:
                return True
    return False


def test_run_spawn_failure_never_names_a_deleted_staging_path() raises:
    """A run-step internal error names a path that is still there.

    `_single_attempt` bakes the binary path into its RUN-step internal-error
    diagnostic before returning, and reporting a path mtest itself had just
    removed would send a user looking for a directory that no longer exists.
    The seam publishes the staged build before dispatching the run, so the path
    the run was given is the generation — which the failed spawn leaves exactly
    where it is. The build succeeded; only this process's dispatch machinery
    did not, so the artifact is good and the next run may have it.

    The fault adapter is what makes a run spawn fail on demand; the case asserts
    the faulted STEP as well as the program, so a miscounted occurrence fails
    loudly instead of quietly measuring the build spawn.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)

    var comp = _recorder()
    var code: Int
    configure_native_fault(_OP_PIPE_STDOUT, _RUN_SPAWN_OCCURRENCE, _EIO)
    try:
        code = run_session(base_config(), root, comp)
    finally:
        reset_native_faults()

    assert_equal(code, 3, "a run-dispatch machinery fault resolves to exit 3")
    ref rec = comp.composite.reporters[0]
    var found = 0
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.INTERNAL_ERROR:
            found += 1
            ref ie = rec.event_at(i).data[InternalErrorPayload]
            assert_equal(
                ie.step,
                "run",
                (
                    "the fault landed on the wrong spawn; this case is only"
                    " about the RUN step"
                ),
            )
            assert_true(
                String(ie.program).startswith(
                    _STORE_DIR + "/tests_stest_uok_h"
                ),
                (
                    "the diagnostic must name the published generation, which"
                    " is what the run was dispatched over: "
                    + ie.program
                ),
            )
            assert_true(
                exists(root + "/" + ie.program),
                "the diagnostic names a path that is not there: " + ie.program,
            )
    assert_equal(found, 1, "exactly one internal error is emitted")
    var entries = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(entries),
        1,
        (
            "the build succeeded and was published before the run was"
            " dispatched, so its generation survives a failed dispatch"
        ),
    )


def test_a_cached_binary_that_will_not_start_costs_a_rebuild() raises:
    """A validated artifact this process cannot start rebuilds, not fails.

    Publishing an artifact deletes that source's older ones, so a second run
    over the same checkout — another terminal, another shard with different
    build arguments — can remove an artifact this run has already validated, in
    the window between the probe and the exec. Resolving that to an internal
    error turns an unrelated concurrent invocation into exit 3 on a run that
    would otherwise have passed.

    The removal belongs to another process and cannot be timed from here, so the
    fault adapter fails the dispatch instead. Both leave the driver holding the
    same fact: a run that could not start on a binary the cache served rather
    than one this run compiled.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)

    var cold = run_recording_session(base_config(), root)
    assert_equal(cold.code, 0, "the cold run must pass")
    assert_equal(cold.built_files, 1, "the cold run compiles the one file")

    var comp = _recorder()
    var code: Int
    configure_native_fault(_OP_PIPE_STDOUT, _WARM_RUN_SPAWN_OCCURRENCE, _EIO)
    try:
        code = run_session(base_config(), root, comp)
    finally:
        reset_native_faults()

    assert_equal(
        code, 0, "a cached binary that will not start must cost a rebuild"
    )
    ref rec = comp.composite.reporters[0]
    assert_true(
        _saw_warning_kind(rec, "cache-rebuild"),
        (
            "the rebuild must be announced; its absence would also mean the"
            " fault landed on a spawn other than the cached run"
        ),
    )
    var totals = _counters(rec)
    assert_equal(totals.cached_files, 1, "the file was admitted as a hit")
    assert_equal(
        totals.built_files,
        0,
        (
            "the recovery compile is not a second admission: one file is one"
            " admission, exactly as a stale-name recovery rebuild is not one"
        ),
    )


def test_a_pooled_cached_binary_that_will_not_start_costs_a_rebuild() raises:
    """The same degradation in the pool, whose dispatch is a separate seam.

    The pool admits a hit straight into its run phase and resolves a run that
    will not start in two places of its own, so the sequential driver being
    right says nothing about this one.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.workers = 2

    var cold = run_recording_session(config.copy(), root)
    assert_equal(cold.code, 0, "the cold run must pass")
    assert_equal(cold.built_files, 1, "the cold run compiles the one file")

    var comp = _recorder()
    var code: Int
    configure_native_fault(_OP_PIPE_STDOUT, _WARM_RUN_SPAWN_OCCURRENCE, _EIO)
    try:
        code = run_session(config^, root, comp)
    finally:
        reset_native_faults()

    assert_equal(
        code, 0, "a cached binary that will not start must cost a rebuild"
    )
    ref rec = comp.composite.reporters[0]
    assert_true(
        _saw_warning_kind(rec, "cache-rebuild"),
        "the pool must announce the rebuild the same way",
    )
    var totals = _counters(rec)
    assert_equal(totals.cached_files, 1, "the file was admitted as a hit")
    assert_equal(totals.built_files, 0, "and admitted exactly once")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
