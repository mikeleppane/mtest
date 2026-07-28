"""The build-artifact cache, observed where a user observes it: a whole session.

Every assertion here is made through `run_recording_session` — one real
`run_session` against a real temp tree, with a real compiler — because the cache
only exists to change what a SESSION does: build once, then never again while
nothing that matters changed. A unit test over `store_probe` can prove a hit is
served; only a session can prove the hit was actually taken, counted, and run.

The seam under test in this module is the SELECTION/collect build path
(`_build_for_selection`), which every case reaches by setting `config.keyword` —
selection is the only path wired to the cache at this point in the tree, so a
case that forgot the keyword would silently measure the uncached plain loop and
pass for the wrong reason.
"""
from std.os.path import exists, isdir
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from cache_fixtures import dir_listing, run_recording_session
from session_fixtures import (
    SRC_CHAMELEON,
    SRC_COMPILE_ERROR,
    SRC_PASS,
    base_config,
    write_file,
)
from tmptree import temp_root

comptime _STORE_DIR = ".mtest-cache/build-v1"
"""The store's generations directory, relative to a run root."""


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
