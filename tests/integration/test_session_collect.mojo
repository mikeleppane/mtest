"""The COLLECT path, proven end to end through real build+probe.

`run_collect` reuses the selection probe machinery (`_build_for_selection` +
`_probe_file`) to learn every discovered file's node ids under `--skip-all`,
running no test body. STDOUT purity is a frozen contract, so these tests assert
the returned listing EXACTLY (sorted node ids), that every diagnostic is a
separate stderr line (never in the listing), and the total per-file policy:
qualifying files are listed; a compile error / crash / timeout / malformed suite
writes a diagnostic and the listing CONTINUES (exit-1 class); an off-grammar
probe is DRIFT (exit 3); nothing collectable is exit 5.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.session import run_collect

from exec_helpers import true_binary
from session_fixtures import (
    SRC_COMPILE_ERROR,
    SRC_CRASH,
    SRC_FLOOD_PROBE,
    SRC_HANG,
    SRC_LIAR,
    SRC_MATRIX,
    SRC_PASS,
    SRC_SILENT,
    SRC_ZERO,
    base_config,
    temp_root,
    write_file,
)


def _any_contains(items: List[String], needle: String) -> Bool:
    for x in items:
        if needle in x:
            return True
    return False


def test_all_qualifying_lists_sorted_node_ids_no_diagnostics() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.collect = True
    cfg.paths.append("tests")

    var res = run_collect(cfg, root)

    assert_equal(res.code, 0, "an all-qualifying collect exits 0")
    assert_equal(len(res.diagnostics), 0, "no diagnostics for clean probes")
    # The listing is byte-exact: sorted node ids, one entry per collected test.
    assert_equal(len(res.listing), 4)
    assert_equal(res.listing[0], "tests/test_a.mojo::test_pass")
    assert_equal(res.listing[1], "tests/test_matrix.mojo::test_add_one")
    assert_equal(res.listing[2], "tests/test_matrix.mojo::test_add_two")
    assert_equal(res.listing[3], "tests/test_matrix.mojo::test_sub_one")


def test_keyword_is_ignored_with_note_and_full_listing() raises:
    # `-k` is a run-time selection filter; collect ignores it and lists the
    # FULL discovered set with a stderr note, rather than filtering the
    # listing down to the keyword match.
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.collect = True
    cfg.paths.append("tests")
    cfg.keyword = "add"  # would match only test_add_one/test_add_two

    var res = run_collect(cfg, root)

    assert_equal(res.code, 0, "an all-qualifying collect exits 0")
    assert_true(
        _any_contains(res.diagnostics, "-k is ignored in collect mode"),
        "the -k-ignored note is on a diagnostic line",
    )
    # The listing stays the FULL unfiltered set: all three of the matrix
    # file's tests, not just the two "add" matches.
    assert_equal(len(res.listing), 3, "the full node-id listing is unfiltered")
    assert_true(
        _any_contains(res.listing, "tests/test_matrix.mojo::test_add_one")
    )
    assert_true(
        _any_contains(res.listing, "tests/test_matrix.mojo::test_add_two")
    )
    assert_true(
        _any_contains(res.listing, "tests/test_matrix.mojo::test_sub_one")
    )


def test_nothing_collectable_is_exit_5() raises:
    var root = temp_root()
    # A zero-test suite qualifies (all-SKIP, zero rows) but yields no node ids.
    write_file(root, "tests/test_zero.mojo", SRC_ZERO)
    var cfg = base_config()
    cfg.collect = True
    cfg.paths.append("tests")

    var res = run_collect(cfg, root)

    assert_equal(res.code, 5, "nothing collectable -> exit 5")
    assert_equal(len(res.listing), 0)
    assert_equal(len(res.diagnostics), 0, "a clean zero-test probe is silent")


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
