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

Two neighbouring modules hold the rest of the session-level coverage, split off
because every case here runs real compilers and one file's tests share one
process against one deadline: `test_session_cache_keys.mojo` for what moves a
key and what must not, and `test_session_cache_clear.mojo` for `--cache-clear`.
A case belongs here if what it proves is about a SEAM — which path built the
file, what it counted, what it published, and in which order.
"""
from std.ffi import external_call
from std.os import getenv, makedirs, remove, setenv, unsetenv
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
from mtest.session.store import PRECOMPILE_SUBDIR, STORE_FAULT_ENV

from cache_fixtures import RecordedRun, dir_listing, run_recording_session
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

comptime _OP_PIPE_STDOUT = 11
"""`MTEST_EXEC_OP_PIPE_STDOUT`: the child's stdout pipe, opened per dispatch."""


comptime _FAULT_PUBLISHED_ABSENT = "published-absent"
"""Hide a newly published generation just before this session executes it."""


comptime _CACHE_REBUILD_WARNING = (
    "cache-rebuild:the stored binary for 'tests/test_ok.mojo' could not be"
    " started, so the file is being rebuilt. Another mtest run may have"
    " replaced or quarantined that generation."
)
"""The exact cause-neutral warning from a vanished fresh generation."""


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


def test_werror_second_run_hits_cache_without_cache_off() raises:
    """`--Werror` remains cacheable through the exact argument digest."""
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.keyword = "test"
    config.build_args = ["--Werror"]

    var first = run_recording_session(config.copy(), root)
    assert_equal(first.code, 0, "the cold warning-strict build must pass")
    assert_equal(first.built_files, 1, "the cold run compiles the one file")
    assert_false(
        _saw_cache_off(first.warnings),
        "the known warning switch must not disable the cache",
    )

    var second = run_recording_session(config^, root)
    assert_equal(second.code, 0, "the warm run must pass on the cached binary")
    assert_equal(
        second.cached_files, 1, "the warm run is served from the store"
    )
    assert_equal(second.built_files, 0, "the warm run compiles nothing")
    assert_false(
        _saw_cache_off(second.warnings),
        "the known warning switch must emit zero cache-off events",
    )


def test_selection_rebuilds_a_freshly_published_binary_that_vanishes() raises:
    """The selection probe recovers a publish-to-exec cache ENOENT once."""
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.keyword = "test"  # forces the selection build/probe/run driver

    var saved = getenv(STORE_FAULT_ENV, "")
    var was_set = getenv(STORE_FAULT_ENV, "\x01unset") != "\x01unset"
    var run: RecordedRun
    try:
        _ = setenv(STORE_FAULT_ENV, _FAULT_PUBLISHED_ABSENT, True)
        run = run_recording_session(config, root)
    finally:
        if was_set:
            _ = setenv(STORE_FAULT_ENV, saved, True)
        else:
            _ = unsetenv(STORE_FAULT_ENV)

    assert_equal(
        run.code, 0, "a vanished fresh selection artifact must rebuild"
    )
    assert_equal(run.built_files, 1, "the cold admission stays singular")
    assert_equal(run.cached_files, 0, "the selection run had no warm hit")
    var saw_rebuild = False
    for warning in run.warnings:
        if String(warning) == _CACHE_REBUILD_WARNING:
            saw_rebuild = True
    assert_true(
        saw_rebuild, "the selection rebuild must carry the exact shared detail"
    )


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


comptime _SRC_PASS_ALTERNATE = (
    "from std.testing import TestSuite, assert_equal\n\n\n"
    "def test_pass() raises:\n"
    "    assert_equal(2, 1 + 1)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
"""A second passing body for one file, so an edit moves its key and nothing
else: same file, same test count, same verdict, a different binary."""


def test_an_edit_and_restore_cycle_ends_fully_cached() raises:
    """The second cycle of editing a file and putting it back is free.

    Switching a file between two states is what a branch switch and back does
    to every file that differs, and it is the case a store keeping one
    generation per source could never serve: the generation for the state being
    returned to was reaped when the other state published. Two live generations
    make the third run of the cycle compile nothing, with both states still
    live for the next switch.
    """
    var root = temp_root()
    var rel = String("tests/test_cycle.mojo")
    write_file(root, rel, SRC_PASS)
    var config = base_config()

    var cold = run_recording_session(config.copy(), root)
    assert_equal(cold.code, 0, "the cold run must pass")
    assert_equal(cold.built_files, 1, "the cold run compiles the one file")
    assert_equal(cold.cached_files, 0, "nothing is stored yet")

    write_file(root, rel, _SRC_PASS_ALTERNATE)
    var edited = run_recording_session(config.copy(), root)
    assert_equal(edited.code, 0, "the second body must pass too")
    assert_equal(
        edited.built_files, 1, "the edit moved the key, so it compiles"
    )
    assert_equal(edited.cached_files, 0, "no pre-edit generation may be served")

    write_file(root, rel, SRC_PASS)
    var restored = run_recording_session(config^, root)
    assert_equal(restored.code, 0, "the restored body must pass")
    assert_equal(
        restored.built_files,
        0,
        (
            "the generation the cold run published was reaped, so returning a"
            " file to a state the store has already built recompiles it"
        ),
    )
    assert_equal(
        restored.cached_files, 1, "the restored body is served from the store"
    )
    # Both ends of the alternation stay live, which is what makes the NEXT
    # switch free as well rather than merely this one.
    var entries = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(entries),
        2,
        "the store must hold both generations of the alternating file",
    )


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
