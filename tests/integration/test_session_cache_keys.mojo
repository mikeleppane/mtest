"""What moves a cache key, and what must not.

The cache is only worth having if it is precise in both directions, and each
direction fails differently. Missing an input that changed serves a binary
compiled from source that is no longer on disk — a green run over code nobody
wrote. Keying an input that did not change costs a rebuild and nothing else,
which is why every uncertain case in the store resolves that way.

So these cases come in pairs. One edits something the key must cover and
asserts the rebuild; its neighbour changes something the key must ignore — a
setting the compiler never sees, a rewrite that produces identical bytes — and
asserts the hit. Both run whole sessions through `run_recording_session`,
because a key that changed is only interesting if the session it belongs to
actually recompiled.

The blast radius is asserted as carefully as the fact of a rebuild. A helper
beside a test invalidates that test; a file under an include root invalidates
everything; and a test file its neighbour imports invalidates the neighbour
alone, not the whole directory. Getting the radius wrong is how a cache turns
into a slow rebuild-everything loop while every assertion still passes.
"""
from std.os.path import exists
from std.testing import assert_equal, assert_true, TestSuite

from cache_fixtures import dir_listing, run_recording_session
from session_fixtures import SRC_PASS, base_config, write_file
from tmptree import temp_root

comptime _STORE_DIR = ".mtest-cache/build-v1"
"""The store's generations directory, relative to a run root."""

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
    # The store keeps the two newest generations of each source, so one edit to
    # a shared support file leaves both files holding their pre-edit and their
    # post-edit generation: bounded per source, and no more than that.
    var entries = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(entries),
        4,
        "the store must hold two live generations per file",
    )
    var a_generations = 0
    var b_generations = 0
    for entry in entries:
        var name = String(entry)
        if name.startswith("tests_stest_ua_h"):
            a_generations += 1
        elif name.startswith("tests_stest_ub_h"):
            b_generations += 1
    # Per SOURCE, never four of one and none of the other: a count alone would
    # pass while one file kept every edit and the other kept none.
    assert_equal(a_generations, 2, "'tests/test_a.mojo' is not retained twice")
    assert_equal(b_generations, 2, "'tests/test_b.mojo' is not retained twice")

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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
