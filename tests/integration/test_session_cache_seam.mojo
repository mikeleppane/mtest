"""The build-artifact cache, observed where a user observes it: a whole session.

Every assertion here is made through `run_recording_session` — one real
`run_session` against a real temp tree, with a real compiler — because the cache
only exists to change what a SESSION does: build once, then never again while
nothing that matters changed. A unit test over `store_probe` can prove a hit is
served; only a session can prove the hit was actually taken, counted, and run.

Three seams are covered here, and which one a case exercises is decided by its
config, never by the assertions:

- The SELECTION/collect build path (`_build_for_selection`), reached by setting
  `config.keyword`. A case that forgot the keyword would silently measure the
  plain loop and pass for the wrong reason.
- The SEQUENTIAL attempt path (`_run_one`), reached by leaving `keyword` empty
  and `workers` at its default of 1. Those two defaults are asserted in the
  first sequential case rather than assumed, because the routing is what makes
  the rest of that case mean anything.
- The PARALLEL pool (`_run_pool_batch`), reached by leaving `keyword` empty and
  raising `workers` above one. The pool is the only seam whose build and run are
  two separate dispatches through a phase machine, so its cases also pin what
  the seam does BETWEEN them.

Cases that need the raw event stream — a retry's `AttemptFinished`, an
`InternalError`'s program — compose the recording triple themselves rather than
going through `run_recording_session`, which deliberately flattens the stream
away.
"""
from std.ffi import external_call
from std.os import getenv, makedirs, remove
from std.os.path import exists, isdir, islink
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import (
    CliOverlay,
    ConfigEnvironment,
    FileConfig,
    Precompile,
    ResolvedConfig,
    RunnerConfig,
    resolve_config,
)
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
from mtest.platform.cstring import c_string_bytes
from mtest.session import run_session
from mtest.session.store import PRECOMPILE_SUBDIR, clear_cache_root

from cache_fixtures import dir_listing, run_recording_session
from session_fixtures import (
    SRC_CHAMELEON,
    SRC_COMPILE_ERROR,
    SRC_CRASH,
    SRC_PASS,
    base_config,
    write_file,
)
from tmptree import link_dir, temp_root

comptime _CACHE_ROOT = ".mtest-cache"
"""The whole directory mtest owns, relative to a run root."""

comptime _STORE_DIR = ".mtest-cache/build-v1"
"""The store's generations directory, relative to a run root."""

comptime _MARKER_TEXT = (
    "Signature: 8a477f597d28d172789f06886806bc55\n"
    "# This file is a cache directory tag created by mtest.\n"
    "# For information about cache directory tags, see"
    " https://bford.info/cachedir/\n"
)
"""A hand-written `CACHEDIR.TAG` body, for cases with no session to write one.

Byte-identical to what the store writes, and it has to be: the clear proves
ownership by comparing the whole marker, so a fixture that abbreviated it would
be refused. The signature line alone would not do — it is the cachedir
convention's, shared by every tool that marks a cache directory, so a marker
carrying only that says nothing about who created this one.

Only `test_cache_clear_deletes_a_store_a_real_session_wrote` needs the marker a
session actually writes; every other clear case only needs a marker to be there,
so it writes this rather than paying for a compile.
"""

comptime _OP_PIPE_STDOUT = 11
"""`MTEST_EXEC_OP_PIPE_STDOUT`: the child's stdout pipe, opened per dispatch."""


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


def _reset_faults():
    """Clear the isolated testing adapter's native fault table."""
    # SAFETY: this test-only ABI takes no pointer, retains nothing, and mutates
    # only the testing adapter's single-threaded fault configuration.
    external_call["mtest_exec_test_fault_reset", NoneType]()


def _configure_fault(operation: Int, occurrence: Int, error_number: Int) raises:
    """Fail one occurrence of one native adapter operation.

    Args:
        operation: The `MTEST_EXEC_OP_*` discriminator to fault.
        occurrence: Which visit to that operation fails, counting from 1.
        error_number: The errno the faulted operation reports.

    Raises:
        Error: When the testing adapter rejects the configuration.
    """
    # SAFETY: the test-only ABI takes scalar discriminators only; all three are
    # exact enum/errno/count constants and no pointer or state escapes the call.
    var result = external_call["mtest_exec_test_fault_configure", Int32](
        UInt32(operation), UInt32(occurrence), Int32(error_number), Int64(0)
    )
    assert_equal(result, Int32(0), "could not configure native fault")


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


def _chmod(path: String, mode: Int) raises:
    """Set `path`'s permission bits.

    The pinned `std.os` exposes no `chmod`, and the partial-delete refusal
    cannot be reached without one: that path only opens when the removal fails
    on a child the process genuinely may not unlink, which is a permission fact
    and not something a fault injector can stand in for.

    Args:
        path: An existing path whose mode is replaced.
        mode: The POSIX permission bits, for example `0o500`.

    Raises:
        Error: If `chmod` reports a failure.
    """
    var c = c_string_bytes(path)
    # SAFETY: libc `chmod` has the exact ABI `int chmod(const char*, mode_t)` on
    # both Linux and Darwin — a fixed arity of two with no variadic tail, so the
    # NON-variadic call `external_call` emits is the correct one on every target
    # this suite builds for. The pointer names a complete, fully initialized,
    # NUL-terminated byte copy this function uniquely owns: `c_string_bytes`
    # allocates it here, nothing else holds a reference, and `c` stays a live
    # local that is consumed only after the call returns, so the pointer is valid
    # for the whole synchronous call and aliases nothing. It does not escape —
    # `chmod` reads the path and retains nothing past its return — and the callee
    # writes through it not at all. The mode is a plain scalar widened to the
    # `unsigned int` Linux uses; Darwin's narrower `mode_t` reads the same low
    # bits from the same register, and every value passed here fits in nine bits.
    # Nothing is allocated for the callee to free, and the result is a plain
    # status; `errno` is never read, so no ordering constraint against the
    # release of `c` exists.
    var rc = external_call["chmod", Int32](c.unsafe_ptr(), UInt32(mode))
    _ = c^
    assert_equal(rc, Int32(0), "could not chmod " + path)


def _clear_diagnostic(root: String) -> String:
    """Run `clear_cache_root` against `root` and render its answer as text.

    Args:
        root: The invocation root whose `.mtest-cache` is to be cleared.

    Returns:
        The refusal diagnostic, or the empty string when the clear succeeded.
        Flattening the `Optional` here keeps every case's assertion a plain
        string comparison, so a refusal that appears where none was expected
        prints its own reason instead of `False`.
    """
    var failure = clear_cache_root(root)
    if failure:
        return failure.value()
    return String("")


def _resolved(config: RunnerConfig) -> ResolvedConfig:
    """Layer `config` with no project file, environment, or CLI overlay.

    Args:
        config: The runner values the session should see.

    Returns:
        The resolved configuration, with `state_cleared` at its default.
    """
    return resolve_config(
        config,
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )


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


def _saw_cache_off(warnings: List[String]) -> Bool:
    """Whether the run emitted the once-per-session cache-off warning.

    Args:
        warnings: Every warning the run emitted, rendered `kind + ":" + detail`.

    Returns:
        True if any of them is a `cache-off` warning.
    """
    for w in warnings:
        if String(w).startswith("cache-off:"):
            return True
    return False


def _read_text(path: String) raises -> String:
    """Read a small file a fixture wrote, as text.

    Args:
        path: The file to read.

    Returns:
        Its contents.

    Raises:
        Error: If the file is missing, is not a regular file, or does not
            decode.
    """
    var opened = read_bounded_regular_file(path, 1 << 20)
    if not opened.is_regular:
        raise Error("not a regular file: " + path)
    return opened.text.copy()


comptime _SRC_RECORDS_ITS_OWN_PATH = (
    "from std.sys import argv\n"
    "from std.testing import TestSuite, assert_false\n\n\n"
    "def test_runs_what_the_record_names() raises:\n"
    '    var own = String("")\n'
    "    var first = True\n"
    "    for a in argv():\n"
    "        if first:\n"
    "            own = String(a)\n"
    "            first = False\n"
    '    with open("argv0.txt", "w") as f:\n'
    "        f.write(own)\n"
    '    assert_false(".tmp-" in own, "ran out of staging: " + own)\n\n\n'
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
"""A test that writes its own executable path down and refuses a staged one.

The one thing a test can observe about which binary the cache chose for it. The
run child's working directory is the invocation root, so `argv0.txt` lands
where the case can read it back.
"""


def test_a_cold_run_executes_the_artifact_it_records() raises:
    """The verdict and the recorded artifact must describe the same bytes.

    The sequential seam compiles into a staging directory and publishes it by
    renaming that directory onto the generation path. Running before publishing
    executes the staging binary and then records the generation — so a test that
    reads its own executable path, or anything else derived from it, sees one
    answer cold and a different one warm over inputs that never changed. That is
    a cold/warm equivalence break in the direction that reads as a real
    regression, and on an adopted publication it goes further: the verdict would
    belong to this process's own bytes while the record named the winner's.

    Publishing first is what makes the two the same, and this pins it from
    outside: the fixture refuses a staging path, and the path it recorded cold
    has to be the path it records warm.
    """
    var root = temp_root()
    write_file(root, "tests/test_argv.mojo", _SRC_RECORDS_ITS_OWN_PATH)
    var config = base_config()

    var cold = run_recording_session(config.copy(), root)
    assert_equal(
        cold.code,
        0,
        "the cold run executed a binary other than the one it recorded",
    )
    assert_equal(cold.built_files, 1, "the cold run compiles the one file")
    var cold_path = _read_text(root + "/argv0.txt")

    var warm = run_recording_session(config^, root)
    assert_equal(warm.code, 0, "the warm run must pass on the cached binary")
    assert_equal(warm.cached_files, 1, "the warm run is served from the store")
    var warm_path = _read_text(root + "/argv0.txt")

    assert_equal(
        cold_path,
        warm_path,
        "cold and warm ran different binaries for one unchanged file",
    )
    assert_true(
        cold_path.startswith(_STORE_DIR + "/tests_stest_uargv_h"),
        "the run did not come out of this file's generation: " + cold_path,
    )
    assert_true(exists(root + "/" + cold_path), "the path run is not there")


def test_selection_second_run_hits_cache() raises:
    """A second selection run over an untouched tree compiles nothing."""
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.keyword = "test"  # forces the selection path

    var first = run_recording_session(config.copy(), root)
    assert_equal(first.code, 0, "the cold run must pass")
    assert_equal(first.built_files, 1, "the cold run compiles the one file")
    assert_equal(first.cached_files, 0, "nothing is stored yet")

    var second = run_recording_session(config.copy(), root)
    assert_equal(second.code, 0, "the warm run must pass on the cached binary")
    assert_equal(
        second.cached_files, 1, "the warm run is served from the store"
    )
    assert_equal(second.built_files, 0, "the warm run compiles nothing")


def test_unknown_build_arg_warns_and_disables() raises:
    """An unclassifiable build argument turns the cache off, loudly and once."""
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.keyword = "test"
    config.build_args = ["--sysroot=/x"]

    var run = run_recording_session(config^, root)
    assert_true(
        _saw_cache_off(run.warnings),
        "an unrecognized build argument must say so once, in a warning",
    )
    assert_equal(
        run.built_files, 1, "a disabled cache still admits a real compile"
    )
    assert_equal(run.cached_files, 0, "a disabled cache serves nothing")
    assert_false(
        isdir(root + "/.mtest-cache"),
        "a session that never uses the store must not create it",
    )


def test_no_cache_selection_never_creates_the_store() raises:
    """`--no-cache` builds invocation-private, silently, and touches no store.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.keyword = "test"
    config.no_cache = True

    var run = run_recording_session(config^, root)
    assert_equal(run.code, 0, "--no-cache changes nothing about the verdict")
    assert_equal(run.built_files, 1, "the file is still compiled and counted")
    assert_equal(run.cached_files, 0, "nothing may be served from the store")
    assert_false(
        exists(root + "/.mtest-cache"),
        (
            "--no-cache must gate BEFORE staging: the store directory and its"
            " CACHEDIR.TAG are a side effect of staging one build"
        ),
    )
    assert_false(
        _saw_cache_off(run.warnings),
        "the user asked for the cache to be off; saying so back is noise",
    )


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


def test_stale_name_rebuild_is_invocation_private() raises:
    """The recover-once rebuild neither counts, nor probes, nor publishes.

    The chameleon lists `test_ghost` under `--skip-all` and refuses it under
    `--only`, which drives the bounded stale-name recovery: rebuild, re-probe,
    re-select, retry. That rebuild exists precisely to obtain a binary the
    store's answer would not give, so serving it the generation this same
    session just published would make the recovery a no-op — and a second
    publication would write a retry's binary into a store that other runs read.

    Both are pinned by what is observable: the counters move exactly once
    between them (the first-attempt compile), and the store ends the run holding
    exactly one entry — the first build's generation, with no second generation
    and no staging directory left behind by the rebuild.
    """
    var root = temp_root()
    write_file(root, "tests/test_chameleon.mojo", SRC_CHAMELEON)
    var config = base_config()
    config.paths.append("tests/test_chameleon.mojo")
    config.keyword = "ghost"

    var run = run_recording_session(config^, root)
    assert_equal(run.code, 1, "a chameleon suite is MALFORMED-SUITE, exit 1")
    assert_equal(
        run.built_files,
        1,
        (
            "only the first-attempt compile counts; the recovery rebuild is a"
            " retry"
        ),
    )
    assert_equal(
        run.cached_files,
        0,
        (
            "the recovery rebuild must not probe: a hit would serve back the"
            " generation this run just published and compile nothing"
        ),
    )
    var entries = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(entries),
        1,
        (
            "the store must hold exactly the first build's generation; the"
            " recovery rebuild publishes nothing and stages nothing"
        ),
    )
    assert_true(
        String(entries[0]).startswith("tests_stest_uchameleon_h"),
        "the one store entry is not this file's generation: " + entries[0],
    )


def test_sequential_second_run_hits_cache() raises:
    """A second PLAIN run over an untouched tree compiles nothing.

    The sequential attempt path is where a file is built and run by one
    function, so this is the case that proves the probe was consulted before
    the loop and the publication happened after the build inside it: the warm
    run's counters flip, and the store still holds exactly the one generation
    the cold run wrote — no second generation, and no staging directory left
    behind by a run that compiled nothing.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    # The routing, asserted rather than assumed: an empty keyword keeps
    # selection inactive and one worker keeps the pool out of it, which is what
    # sends both runs through `_run_one`.
    assert_equal(
        config.keyword, "", "a keyword would route to the selection seam"
    )
    assert_equal(
        config.workers, 1, "more than one worker would route to the pool seam"
    )

    var first = run_recording_session(config.copy(), root)
    assert_equal(first.code, 0, "the cold run must pass")
    assert_equal(first.built_files, 1, "the cold run compiles the one file")
    assert_equal(first.cached_files, 0, "nothing is stored yet")
    var cold = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(len(cold), 1, "the cold run publishes exactly one generation")
    assert_true(
        String(cold[0]).startswith("tests_stest_uok_h"),
        "the one store entry is not this file's generation: " + cold[0],
    )

    var second = run_recording_session(config^, root)
    assert_equal(second.code, 0, "the warm run must pass on the cached binary")
    assert_equal(
        second.cached_files, 1, "the warm run is served from the store"
    )
    assert_equal(second.built_files, 0, "the warm run compiles nothing")
    var warm = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(warm),
        1,
        "a run that compiled nothing must neither stage nor publish",
    )
    assert_equal(warm[0], cold[0], "the warm run replaced the generation")


def test_no_cache_never_touches_store() raises:
    """`--no-cache` on the plain path builds private, silently, stores nothing.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.no_cache = True

    var run = run_recording_session(config^, root)
    assert_equal(run.code, 0, "--no-cache changes nothing about the verdict")
    assert_equal(run.built_files, 1, "the file is still compiled and counted")
    assert_equal(run.cached_files, 0, "nothing may be served from the store")
    assert_false(
        exists(root + "/.mtest-cache"),
        (
            "--no-cache must gate BEFORE staging: the store directory and its"
            " CACHEDIR.TAG are a side effect of staging one build"
        ),
    )
    assert_false(
        _saw_cache_off(run.warnings),
        "the user asked for the cache to be off; saying so back is noise",
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
    _configure_fault(_OP_PIPE_STDOUT, _RUN_SPAWN_OCCURRENCE, _EIO)
    try:
        code = run_session(base_config(), root, comp)
    finally:
        _reset_faults()

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
    _configure_fault(_OP_PIPE_STDOUT, _WARM_RUN_SPAWN_OCCURRENCE, _EIO)
    try:
        code = run_session(base_config(), root, comp)
    finally:
        _reset_faults()

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
    _configure_fault(_OP_PIPE_STDOUT, _WARM_RUN_SPAWN_OCCURRENCE, _EIO)
    try:
        code = run_session(config^, root, comp)
    finally:
        _reset_faults()

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


def test_gate_file_is_cached_like_any_other() raises:
    """A gate runs through the same seam, so it keys, publishes, and hits.

    Gates take a second, separate call into `_run_one`, and the counting rule
    says "gates included". A seam threaded into the run loop alone would leave
    this run compiling the gate on every invocation while reporting nothing
    about it, so the warm run's counters are what pin the second call site.
    """
    var root = temp_root()
    write_file(root, "tests/test_gate.mojo", SRC_PASS)
    write_file(root, "tests/test_run.mojo", SRC_PASS)
    var config = base_config()
    config.gates.append("tests/test_gate.mojo")

    var first = run_recording_session(config.copy(), root)
    assert_equal(first.code, 0, "the cold run must pass")
    assert_equal(first.built_files, 2, "the gate and the run file both compile")
    assert_equal(first.cached_files, 0, "nothing is stored yet")

    var second = run_recording_session(config^, root)
    assert_equal(second.code, 0, "the warm run must pass")
    assert_equal(second.cached_files, 2, "both files are served from the store")
    assert_equal(second.built_files, 0, "the warm run compiles nothing")


def test_pool_second_run_hits_cache() raises:
    """A second POOLED run over an untouched tree compiles nothing.

    The pool is the seam where a file's build and its run are two separate
    dispatches through a persistent phase machine, so a hit has to enter that
    machine already built: it never passes the build dispatch, and everything
    downstream — the run spawn, the verdict's reproduce line, the SLOW token —
    reads the facts the store handed back rather than facts a compiler produced.

    Two files at `workers = 2` so the batch genuinely runs them concurrently;
    one file would leave the concurrency claim untested. The routing is asserted
    rather than assumed, because an empty `keyword` is what keeps the selection
    seam out of it and `workers > 1` is the whole reason this case exists.
    """
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    var config = base_config()
    config.workers = 2
    assert_equal(
        config.keyword, "", "a keyword would route to the selection seam"
    )

    var first = run_recording_session(config.copy(), root)
    assert_equal(first.code, 0, "the cold run must pass")
    assert_equal(first.built_files, 2, "the cold run compiles both files")
    assert_equal(first.cached_files, 0, "nothing is stored yet")
    var cold = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(cold),
        2,
        (
            "the cold run publishes one generation per file and stages nothing"
            " else"
        ),
    )

    var second = run_recording_session(config^, root)
    assert_equal(
        second.code, 0, "the warm run must pass on the cached binaries"
    )
    assert_equal(second.cached_files, 2, "both files are served from the store")
    assert_equal(second.built_files, 0, "the warm run compiles nothing")
    var warm = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(warm),
        2,
        "a run that compiled nothing must neither stage nor publish",
    )
    assert_equal(warm[0], cold[0], "the warm run replaced a generation")
    assert_equal(warm[1], cold[1], "the warm run replaced a generation")


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


def test_cache_clear_removes_owned_store() raises:
    """A marked `.mtest-cache` is deleted whole — store, marker, and lastrun."""
    var root = temp_root()
    write_file(root, ".mtest-cache/CACHEDIR.TAG", _MARKER_TEXT)
    write_file(root, _STORE_DIR + "/tests_stest_uok_h00/bin", "not a binary")
    write_file(root, _STORE_DIR + "/tests_stest_uok_h00/meta", "not a record")
    write_file(root, ".mtest-cache/lastrun", "v1\n")

    var diagnostic = _clear_diagnostic(root)
    assert_equal(diagnostic, "", "clearing an owned store must not refuse")
    assert_false(
        exists(root + "/" + _CACHE_ROOT),
        "--cache-clear deletes the whole directory, not just the generations",
    )


def test_cache_clear_refuses_symlink() raises:
    """A symlinked `.mtest-cache` is refused before anything is followed.

    The link points at a directory holding a file that has nothing to do with
    mtest. Deleting through the link would take that file with it, so the case
    asserts on the SURVIVING target rather than only on the returned text: a
    refusal that still emptied the target would pass a message-only assertion.
    """
    var root = temp_root()
    write_file(root, "victim/precious.txt", "not mtest's to delete")
    link_dir(root, "victim", _CACHE_ROOT)

    var diagnostic = _clear_diagnostic(root)
    assert_true(diagnostic != "", "a symlinked cache root must be refused")
    assert_true(
        "symlink" in diagnostic,
        "the refusal must say what it refused: " + diagnostic,
    )
    assert_true(
        exists(root + "/victim/precious.txt"),
        "the link target's contents must be untouched",
    )
    assert_true(
        islink(root + "/" + _CACHE_ROOT),
        "the link itself is not mtest's to remove either",
    )


def test_cache_clear_refuses_unmarked() raises:
    """An unmarked `.mtest-cache` is refused, and the refusal is actionable.

    No "but everything in it looks like ours" exception exists on purpose: that
    heuristic is exactly how a directory somebody else created gets deleted, and
    neither does a run write the marker into a directory it merely found — that
    would manufacture the proof one invocation later. So the refusal is
    permanent until the user acts, and the text has to say so and hand over the
    manual removal rather than name a run that would fix it.
    """
    var root = temp_root()
    write_file(root, ".mtest-cache/build-v1/somebody_elses", "stray")

    var diagnostic = _clear_diagnostic(root)
    assert_true(diagnostic != "", "an unmarked cache root must be refused")
    assert_true(
        "CACHEDIR.TAG" in diagnostic,
        "the refusal must name the marker it looked for: " + diagnostic,
    )
    assert_true(
        "never into one it finds" in diagnostic,
        ("the refusal must say why no later run can fix it: " + diagnostic),
    )
    assert_false(
        "run mtest once" in diagnostic,
        (
            "the refusal must not name a run as the way out; a run that marked"
            " this directory would manufacture the proof: "
            + diagnostic
        ),
    )
    assert_true(
        "rm -rf .mtest-cache" in diagnostic,
        "the refusal must hand over the manual fix: " + diagnostic,
    )
    assert_true(
        exists(root + "/.mtest-cache/build-v1/somebody_elses"),
        "a refused clear must leave every byte where it was",
    )


def test_cache_clear_refuses_a_marker_it_did_not_write() raises:
    """A `CACHEDIR.TAG` holding somebody else's text proves nothing.

    `CACHEDIR.TAG` is a CONVENTION, not mtest's private name: the signature line
    is a fixed byte string every cache-marking tool writes, and users and backup
    scripts are actively encouraged to drop one into any directory they want
    backups to skip. So a marker's mere presence — even a marker leading with
    the standard signature — says only that somebody marked this as a cache, not
    that mtest created it. Ownership is proven against the whole text mtest
    writes, or the deletion does not happen.
    """
    var root = temp_root()
    write_file(root, ".mtest-cache/CACHEDIR.TAG", "Signature: deadbeef\n")
    write_file(root, ".mtest-cache/theirs.txt", "somebody else's cache")

    var diagnostic = _clear_diagnostic(root)
    assert_true(
        diagnostic != "", "a marker mtest did not write must be refused"
    )
    assert_true(
        "CACHEDIR.TAG" in diagnostic,
        "the refusal must name the marker it checked: " + diagnostic,
    )
    assert_true(
        "rm -rf .mtest-cache" in diagnostic,
        "the refusal must hand over the manual fix: " + diagnostic,
    )
    assert_true(
        exists(root + "/.mtest-cache/theirs.txt"),
        "a refused clear must leave every byte where it was",
    )


def test_cache_clear_refuses_a_marker_that_is_not_a_regular_file() raises:
    """A directory named `CACHEDIR.TAG` is not the marker mtest writes.

    The cheapest way to defeat an ownership proof is to satisfy it with the
    wrong kind of object: a bare existence test accepts a directory, a symlink,
    a socket, or a device node at the marker's path, and each of those
    authorizes deleting a tree mtest never created.
    """
    var root = temp_root()
    makedirs(root + "/.mtest-cache/CACHEDIR.TAG")
    write_file(root, ".mtest-cache/theirs.txt", "somebody else's cache")

    var diagnostic = _clear_diagnostic(root)
    assert_true(
        diagnostic != "", "a marker that is not a regular file must be refused"
    )
    assert_true(
        "regular file" in diagnostic,
        "the refusal must say what the marker is not: " + diagnostic,
    )
    assert_true(
        exists(root + "/.mtest-cache/theirs.txt"),
        "a refused clear must leave every byte where it was",
    )


def test_cache_clear_reports_a_partial_delete() raises:
    """The one refusal that changes the disk says so, and how to finish the job.

    `_remove_dir_contents_no_follow` raises on the FIRST entry it cannot remove,
    so an unwritable generation — or an `ENOTEMPTY` from a concurrent mtest
    writing into the store — stops the walk with part of the cache already gone.
    The other two refusals leave every byte where it was and can simply name a
    fix; this one has to admit the partial state first, or a user reading it has
    no way to know what is still there.

    The failure is induced with the permission bit rather than an injector,
    because that is the shape the real one takes: a directory whose contents the
    process may read but may not unlink from.
    """
    var root = temp_root()
    write_file(root, ".mtest-cache/CACHEDIR.TAG", _MARKER_TEXT)
    write_file(root, _STORE_DIR + "/tests_stest_uok_h00/bin", "not a binary")
    var locked = root + "/" + _STORE_DIR + "/tests_stest_uok_h00"
    # `r-x`: the walk can still list and characterize the generation, so it
    # reaches the `unlink` that the missing write bit denies.
    _chmod(locked, 0o500)

    var diagnostic = _clear_diagnostic(root)
    # Restored BEFORE the first assertion, so a failing case still leaves a
    # removable temp tree behind rather than an undeletable one.
    _chmod(locked, 0o700)

    assert_true(
        diagnostic != "",
        (
            "an entry the process may not unlink must refuse; a run as root"
            " would defeat this setup and is not a supported test environment"
        ),
    )
    assert_true(
        "could not delete the cache directory" in diagnostic,
        "the refusal must still name what failed: " + diagnostic,
    )
    assert_true(
        "may already have been removed" in diagnostic,
        "the one refusal that changes the disk must admit it: " + diagnostic,
    )
    assert_true(
        "rm -rf .mtest-cache" in diagnostic,
        "a partial delete must hand over the command that finishes it: "
        + diagnostic,
    )


def test_cache_clear_on_an_absent_store_succeeds() raises:
    """Nothing to delete is success, not a diagnostic."""
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)

    assert_equal(
        _clear_diagnostic(root),
        "",
        "an absent cache root is the ordinary first-run shape",
    )


def test_cache_clear_deletes_a_store_a_real_session_wrote() raises:
    """The marker a real session writes is the one the clear accepts.

    The two halves of this feature are written by different code: the store writes
    `CACHEDIR.TAG` at store creation and the clear reads it. A test that builds
    the marker by hand would pass even if the two spelled the path differently,
    so this one lets a session create the store and then clears it for real.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()

    var first = run_recording_session(config.copy(), root)
    assert_equal(first.code, 0, "the cold run must pass")
    assert_equal(first.built_files, 1, "the cold run compiles the one file")
    assert_true(
        exists(root + "/.mtest-cache/CACHEDIR.TAG"),
        "a cache-enabled session must have written the ownership marker",
    )

    assert_equal(
        _clear_diagnostic(root), "", "a store mtest wrote is a store it owns"
    )
    assert_false(
        exists(root + "/" + _CACHE_ROOT), "the cleared store must be gone"
    )

    var second = run_recording_session(config^, root)
    assert_equal(second.code, 0, "the cold-again run must pass")
    assert_equal(second.cached_files, 0, "a cleared store can serve no hit")
    assert_equal(second.built_files, 1, "the file is compiled from scratch")


def test_cache_clear_warns_when_lf_lost_its_state() raises:
    """`--cache-clear` with `--lf` says the state it would have read is gone.

    Emitted at session start rather than from main because that is where a
    reporter exists, and gated on the plumbed flag rather than on the config so
    an ordinary `--lf` run's event stream is byte-for-byte what it was.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.last_failed = True

    var cleared = _resolved(config.copy())
    cleared.state_cleared = True
    var comp = _recorder()
    var code = run_session(cleared, root, comp)
    assert_equal(code, 0, "the full-selection fallback still runs the file")
    assert_true(
        _saw_warning_kind(comp.composite.reporters[0], "cache-clear"),
        "a cleared state under --lf must be reported, not silently ignored",
    )

    var untouched = _resolved(config^)
    assert_false(
        untouched.state_cleared,
        "the plumbed flag must default to False everywhere",
    )
    var quiet = _recorder()
    _ = run_session(untouched, root, quiet)
    assert_false(
        _saw_warning_kind(quiet.composite.reporters[0], "cache-clear"),
        "a plain --lf run must not gain a warning it never had",
    )


comptime _SRC_SUPPORT = "fn shared_constant() -> Int:\n    return 1\n"
"""A support module that lives under an include root and nothing imports.

The key walks every `-I` root whether or not the compiler resolves anything out
of it, which is the conservative half of the invalidation rule: mtest cannot
know which file the compiler would have read, so a change to any of them
invalidates everything. A fixture that imported this would test the compiler's
resolution instead of the walk's.
"""


def test_editing_a_walked_support_file_rebuilds_every_file() raises:
    """A change under an include root invalidates every file, not just readers.

    The include walk is the conservative frame of the key: `mojo build` emits no
    dependency information, so mtest cannot know which walked file a given
    compile actually consumed. Every file therefore keys over the whole walked
    closure, and one edit inside it must take the entire selection back to the
    compiler. Over-rebuilding here is the intended price; a file served from the
    store after its support tree moved would be the failure this forbids.
    """
    var root = temp_root()
    write_file(root, "lib/shared.mojo", _SRC_SUPPORT)
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    var config = base_config()
    config.include_paths = ["lib"]

    var cold = run_recording_session(config.copy(), root)
    assert_equal(cold.code, 0, "the cold run must pass")
    assert_equal(cold.built_files, 2, "the cold run compiles both files")

    var warm = run_recording_session(config.copy(), root)
    assert_equal(warm.cached_files, 2, "both files are served from the store")
    assert_equal(warm.built_files, 0, "the warm run compiles nothing")

    write_file(
        root, "lib/shared.mojo", "fn shared_constant() -> Int:\n    return 2\n"
    )
    var edited = run_recording_session(config.copy(), root)
    assert_equal(edited.code, 0, "an edited support file must not fail the run")
    assert_equal(
        edited.built_files,
        2,
        (
            "a walked support file changed, so every file's key moved; serving"
            " either of them from the store would be serving a stale binary"
        ),
    )
    assert_equal(edited.cached_files, 0, "no pre-edit generation may be served")
    # The superseded generations are reaped as their replacements publish, so
    # the store stays one generation per file rather than one per edit.
    assert_equal(
        len(dir_listing(root + "/" + _STORE_DIR)),
        2,
        "the store must hold one live generation per file",
    )

    var settled = run_recording_session(config^, root)
    assert_equal(
        settled.cached_files, 2, "the post-edit generations must serve in turn"
    )
    assert_equal(settled.built_files, 0, "a settled tree compiles nothing")


comptime _SRC_SIBLING_HELPER = "def helper_value() -> Int:\n    return 7\n"
"""A helper module sitting BESIDE the test files, which import it by bare name.

No `-I` reaches this file. The compiler resolves a bare `from helper import ...`
against the source file's OWN directory, which is a second search path beside
the include roots and the ordinary way neighbouring suites share fixtures.
"""

comptime _SRC_SIBLING_HELPER_POISONED = (
    "def helper_value() -> Int:\n    return 999\n"
)
"""The same helper, returning a value that makes its readers' assertions fail."""

comptime _SRC_READS_HELPER = (
    "from sibling_helper import helper_value\n"
    "from std.testing import TestSuite, assert_equal\n\n\n"
    "def test_helper_value() raises:\n"
    "    assert_equal(helper_value(), 7)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
"""A suite whose verdict is decided by the helper next to it."""

comptime _SRC_READS_HELPER_TWICE = (
    "from sibling_helper import helper_value\n"
    "from std.testing import TestSuite, assert_equal\n\n\n"
    "def test_helper_value_once() raises:\n"
    "    assert_equal(helper_value(), 7)\n\n\n"
    "def test_helper_value_again() raises:\n"
    "    assert_equal(helper_value(), 7)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
"""A second suite over the same helper, with a different body of its own.

Different bytes from `_SRC_READS_HELPER`, so rewriting one file with this is a
real edit rather than the content-identical case.
"""

comptime _SRC_TEST_SIBLING_LIBRARY = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def shared_value() -> Int:\n"
    "    return 7\n\n\n"
    "def test_sibling_of_its_own() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
"""A file that is BOTH a discovered test file and a library for its neighbour."""

comptime _SRC_TEST_SIBLING_LIBRARY_POISONED = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def shared_value() -> Int:\n"
    "    return 999\n\n\n"
    "def test_sibling_of_its_own() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
"""The same file, exporting a value that makes its importer's assertion fail."""

comptime _SRC_READS_TEST_SIBLING = (
    "from test_shared import shared_value\n"
    "from std.testing import TestSuite, assert_equal\n\n\n"
    "def test_reads_the_sibling() raises:\n"
    "    assert_equal(shared_value(), 7)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
"""A suite that imports a neighbour which is itself a discovered test file."""


def test_editing_a_helper_beside_the_test_rebuilds_it() raises:
    """A module in the test file's own directory is a build input, and is keyed.

    `mojo build tests/test_x.mojo` resolves `from helper import ...` out of
    `tests/`, with no `-I` involved and no way to ask the compiler afterwards
    what it read. The file's own directory is therefore walked into its key
    exactly as an include root is, and this case is why: the helper here decides
    the suite's verdict, so a key blind to it serves a binary compiled against
    the OLD helper and reports PASS over source that now fails. That is a green
    run which never compiled the change — the one failure the cache must not
    have.

    The edit flips the verdict rather than merely moving bytes: a counter
    assertion alone would pass on a suite whose result never depended on the
    helper at all.
    """
    var root = temp_root()
    write_file(root, "tests/sibling_helper.mojo", _SRC_SIBLING_HELPER)
    write_file(root, "tests/test_reads_helper.mojo", _SRC_READS_HELPER)
    var config = base_config()

    var cold = run_recording_session(config.copy(), root)
    assert_equal(cold.code, 0, "the cold run must pass")
    assert_equal(cold.built_files, 1, "the cold run compiles the one suite")

    var warm = run_recording_session(config.copy(), root)
    assert_equal(
        warm.cached_files, 1, "an unchanged tree serves from the store"
    )
    assert_equal(warm.built_files, 0, "the warm run compiles nothing")

    write_file(root, "tests/sibling_helper.mojo", _SRC_SIBLING_HELPER_POISONED)
    var edited = run_recording_session(config^, root)
    assert_equal(
        edited.built_files,
        1,
        (
            "the helper the compiler read changed, so the key must have moved;"
            " a hit here is a binary built against the previous helper"
        ),
    )
    assert_equal(edited.cached_files, 0, "no pre-edit generation may be served")
    assert_equal(
        edited.code,
        1,
        (
            "the edited helper makes the suite's assertion fail, so the run"
            " must fail; a green run here is a stale binary reporting a verdict"
            " for source that no longer exists"
        ),
    )


def test_editing_one_test_file_rebuilds_only_that_file() raises:
    """Editing one test file leaves its neighbours in the store.

    The directory walk that closes the sibling-helper hole omits exactly the
    entries mtest would discover as test files, and this is the reason: each of
    those is an independent entry point already keyed by its own source frame,
    so folding them in would make editing any one file in a directory rebuild
    every test in it — destroying the single-file edit-and-rerun loop the cache
    exists to make fast.

    The helper is in the directory on purpose. It makes the walk non-empty, so a
    pass here means the omission really happened rather than the directory
    having nothing to omit. A key that swept the whole directory in, or that
    hashed the selection or the discovery root, would still satisfy every
    warm-run case in this module while rebuilding the world on every edit.
    """
    var root = temp_root()
    write_file(root, "tests/sibling_helper.mojo", _SRC_SIBLING_HELPER)
    write_file(root, "tests/test_a.mojo", _SRC_READS_HELPER)
    write_file(root, "tests/test_b.mojo", _SRC_READS_HELPER)
    var config = base_config()

    var cold = run_recording_session(config.copy(), root)
    assert_equal(cold.built_files, 2, "the cold run compiles both files")
    var warm = run_recording_session(config.copy(), root)
    assert_equal(warm.cached_files, 2, "both files are served from the store")

    # A different suite body, so the file's bytes really change; rewriting it
    # with its own content would be the mtime case, not this one.
    write_file(root, "tests/test_a.mojo", _SRC_READS_HELPER_TWICE)
    var edited = run_recording_session(config^, root)
    assert_equal(edited.code, 0, "both files still pass")
    assert_equal(edited.built_files, 1, "exactly the edited file recompiles")
    assert_equal(
        edited.cached_files,
        1,
        "the neighbour's key did not move, so it must still be served",
    )


def test_a_test_file_read_by_its_neighbour_invalidates_that_neighbour() raises:
    """Omitting test siblings is abandoned for a file that imports one.

    Leaving discovered test files out of the walk is safe only while no file in
    that directory imports one. That is not assumed, it is proved per file: the
    source is scanned for its imports, and a file naming an omitted neighbour
    keys over the whole directory instead — the same conservative walk an `-I`
    root gets.

    Here the neighbour is both a test file in its own right and the library
    deciding this suite's verdict, so an unconditional omission would serve a
    binary compiled against the previous version of it and report PASS over
    source that now fails.
    """
    var root = temp_root()
    write_file(root, "tests/test_shared.mojo", _SRC_TEST_SIBLING_LIBRARY)
    write_file(root, "tests/test_reader.mojo", _SRC_READS_TEST_SIBLING)
    var config = base_config()

    var cold = run_recording_session(config.copy(), root)
    assert_equal(cold.code, 0, "the cold run must pass")
    assert_equal(cold.built_files, 2, "the cold run compiles both files")

    var warm = run_recording_session(config.copy(), root)
    assert_equal(warm.cached_files, 2, "both files are served from the store")
    assert_equal(warm.built_files, 0, "the warm run compiles nothing")

    write_file(
        root, "tests/test_shared.mojo", _SRC_TEST_SIBLING_LIBRARY_POISONED
    )
    var edited = run_recording_session(config^, root)
    assert_equal(
        edited.built_files,
        2,
        (
            "the edited file keys itself, and its reader imported it, so the"
            " reader's key must have moved with it"
        ),
    )
    assert_equal(edited.cached_files, 0, "no pre-edit generation may be served")
    assert_equal(
        edited.code,
        1,
        (
            "the reader asserts on the value its neighbour exports, so the"
            " edit must fail the run; a green run here is the stale binary"
        ),
    )


def test_a_content_identical_rewrite_rebuilds_nothing() raises:
    """A file rewritten with its own bytes is not a change, and is not rebuilt.

    Modification times are deliberately absent from the key. Every git checkout,
    stash, rebase, and editor save-without-edit moves them, and a cache keyed on
    them would miss on every one of those while still missing the case that
    matters — a file whose content changed inside one timestamp granule. The key
    reads content, so rewriting a file with exactly what it already held is
    invisible to it, and this pins that as the feature it is rather than an
    accident of what the walk happens to digest.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()

    var cold = run_recording_session(config.copy(), root)
    assert_equal(cold.built_files, 1, "the cold run compiles the one file")
    var generations = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(len(generations), 1, "the cold run publishes one generation")

    # Written again, byte for byte. The file is created afresh, so its
    # modification time moves and its inode may too.
    write_file(root, "tests/test_ok.mojo", SRC_PASS)

    var touched = run_recording_session(config^, root)
    assert_equal(touched.code, 0, "the run must pass on the cached binary")
    assert_equal(
        touched.cached_files,
        1,
        "a rewrite that changed no byte must still be served from the store",
    )
    assert_equal(touched.built_files, 0, "nothing may be recompiled")
    var after = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(len(after), 1, "a run that compiled nothing published nothing")
    assert_equal(
        after[0],
        generations[0],
        "the key moved: the generation the cold run published was superseded",
    )


def test_a_compile_irrelevant_setting_change_still_hits() raises:
    """Settings that cannot change a binary's bytes must not move the key.

    The key never digests the configuration file. Every compile-affecting
    setting reaches it through its EFFECT instead — the compiler through the
    toolchain identity, includes through the walked roots, build arguments
    through the classified argument list — so the settings that reach no compile
    at all reach no key either. Digesting the configuration wholesale would be
    the easy implementation and would rebuild the entire suite the first time
    anyone raised a timeout or asked for a duration ranking.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()

    var cold = run_recording_session(config.copy(), root)
    assert_equal(cold.built_files, 1, "the cold run compiles the one file")
    var generations = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(len(generations), 1, "the cold run publishes one generation")

    # A run deadline, a duration ranking, and a retry budget: three settings a
    # project changes routinely, none of which reaches `mojo build` at all.
    var retuned = base_config()
    retuned.timeout_secs = config.timeout_secs + 5
    retuned.durations = 5
    retuned.retries = 2

    var warm = run_recording_session(retuned^, root)
    assert_equal(warm.code, 0, "the retuned run must pass")
    assert_equal(
        warm.cached_files,
        1,
        (
            "a setting that cannot change a compiled byte moved the key; the"
            " key must reflect compile inputs, never configuration text"
        ),
    )
    assert_equal(warm.built_files, 0, "nothing may be recompiled")
    var after = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(len(after), 1, "a run that compiled nothing published nothing")
    assert_equal(
        after[0],
        generations[0],
        "the retuned run published a second generation for the same inputs",
    )


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
