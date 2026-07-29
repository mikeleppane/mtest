"""What a compile failure counts as, on each of the three run paths.

Split out of `test_session_cache_seam_faults.mojo` by weight: a suite that
drives real sessions pays a fixed per-process price for the first build it puts
through the compiler, and keeping this group apart is what stops one per-file
deadline carrying two such payments.

The subject is one rule stated three times, once per path the product can take.
A compile that failed is still a compile: it counts as BUILT, because the run
paid the compiler's price and a counter that said otherwise would report a cache
hit rate the run did not have. It publishes nothing, because there is no
artifact to publish, and the diagnostic names `build/bin` so the reader can go
look.
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


def test_a_compile_failure_counts_as_built() raises:
    """The admission counts, not the outcome: a build that fails is still built.

    This is the counting rule's sharpest edge and the one a later seam is most
    likely to break, because moving `built_files += 1` past the spawn — the
    obvious place to put it — silently drops every compile error out of the
    accounting and quietly breaks `built_files + cached_files == first-attempt
    compile admissions`. The counter is therefore incremented at admission,
    before the compiler is spawned, and this is what pins that.
    """
    var root = temp_root()
    write_file(root, "tests/test_broken.mojo", SRC_COMPILE_ERROR)
    var config = base_config()
    config.keyword = "test"

    var run = run_recording_session(config^, root)
    assert_equal(run.code, 1, "a compile error is an exit-1 verdict")
    assert_equal(run.built_files, 1, "a compile that failed was still admitted")
    assert_equal(run.cached_files, 0, "nothing was served from the store")
    # Nothing may be published for a build that produced no binary, and the
    # staging directory it wrote into is debris the moment the compiler fails.
    assert_equal(
        len(dir_listing(root + "/" + _STORE_DIR)),
        0,
        "a failed build left something in the store",
    )


def test_sequential_compile_failure_counts_as_built() raises:
    """A first-attempt compile that FAILS is still an admission, and stores
    nothing.

    The counting rule's sharpest edge on this seam. `_run_one` spawns the
    compiler inside `_single_attempt`, one call below where the counter lives,
    so the tempting place to increment is after that call returns — which would
    drop every compile error out of the accounting. The counter is therefore
    advanced before the loop is entered, and this pins it. The staging directory
    the failed compile wrote into is debris the moment the compiler rejects the
    source, so the store must end the run empty.
    """
    var root = temp_root()
    write_file(root, "tests/test_broken.mojo", SRC_COMPILE_ERROR)

    var run = run_recording_session(base_config(), root)
    assert_equal(run.code, 1, "a compile error is an exit-1 verdict")
    assert_equal(run.built_files, 1, "a compile that failed was still admitted")
    assert_equal(run.cached_files, 0, "nothing was served from the store")
    assert_equal(
        len(dir_listing(root + "/" + _STORE_DIR)),
        0,
        "a failed build left something in the store",
    )


def test_pool_compile_failure_counts_and_names_build_bin() raises:
    """A pooled compile failure is an admission, stores nothing, and reproduces.

    Three claims the pool's build-completion branch owns and no other case here
    reaches. The counting rule first: the compiler is spawned from the dispatch
    loop and its verdict is folded a whole `wait_any` sweep later, so the only
    honest place to count is the dispatch — and a counter moved to the fold
    would drop this file out of the accounting entirely.

    Then the two things a failed pooled build must leave behind. The staging
    directory is debris the instant the compiler rejects the source, so the
    store must end the run holding exactly the healthy file's generation. And
    the reproduce line must name `build/bin/<mangled>`: the compile really did
    write to a staging directory, but that directory is deleted before the
    verdict is emitted, so a line naming it would be a line no user could run.
    """
    var root = temp_root()
    write_file(root, "tests/test_broken.mojo", SRC_COMPILE_ERROR)
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.workers = 2

    var comp = _recorder()
    var code = run_session(config, root, comp)
    assert_equal(code, 1, "a compile error is an exit-1 verdict")
    ref rec = comp.composite.reporters[0]

    var counters = _counters(rec)
    assert_equal(
        counters.built_files, 2, "a compile that failed was still admitted"
    )
    assert_equal(counters.cached_files, 0, "nothing was served from the store")

    var entries = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(entries),
        1,
        "only the file that built may leave a generation behind",
    )
    assert_true(
        String(entries[0]).startswith("tests_stest_uok_h"),
        "the one store entry is not the healthy file's generation: "
        + entries[0],
    )

    var verdict = _verdict_of(rec, "tests/test_broken.mojo")
    assert_true(
        verdict.outcome == Outcome.COMPILE_ERROR,
        "the broken file must end COMPILE-ERROR",
    )
    var saw_plain_out = False
    for token in verdict.build_argv:
        if String(token) == "build/bin/tests_stest_ubroken":
            saw_plain_out = True
    assert_true(
        saw_plain_out,
        (
            "the reproduce line must name build/bin, never the staging"
            " directory the seam deletes before emitting the verdict"
        ),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
