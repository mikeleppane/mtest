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


def test_compile_error_is_diagnostic_and_listing_continues() raises:
    var root = temp_root()
    write_file(root, "tests/test_broken.mojo", SRC_COMPILE_ERROR)
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.collect = True
    cfg.paths.append("tests")

    var res = run_collect(cfg, root)

    # The good file's node ids are still listed; the broken one is a diagnostic.
    assert_equal(res.code, 1, "a compile-error file is exit-1 class")
    assert_equal(len(res.listing), 3, "the good file's tests are still listed")
    assert_true(_any_contains(res.listing, "test_matrix.mojo::test_add_one"))
    assert_true(
        _any_contains(res.diagnostics, "tests/test_broken.mojo"),
        "the compile error names the offending file on a diagnostic line",
    )


def test_crashing_probe_is_diagnostic_exit_1() raises:
    var root = temp_root()
    write_file(root, "tests/test_crash.mojo", SRC_CRASH)
    var cfg = base_config()
    cfg.collect = True
    cfg.paths.append("tests")

    var res = run_collect(cfg, root)

    assert_equal(res.code, 1, "a crashing probe is exit-1 class")
    assert_equal(len(res.listing), 0)
    assert_true(_any_contains(res.diagnostics, "tests/test_crash.mojo"))


def test_hanging_probe_times_out_exit_1() raises:
    var root = temp_root()
    write_file(root, "tests/test_hang.mojo", SRC_HANG)
    var cfg = base_config()
    cfg.collect = True
    cfg.timeout_secs = 1
    cfg.paths.append("tests")

    var res = run_collect(cfg, root)

    assert_equal(res.code, 1, "a hanging probe times out -> exit-1 class")
    assert_true(_any_contains(res.diagnostics, "tests/test_hang.mojo"))


def test_malformed_suite_is_diagnostic_exit_1() raises:
    var root = temp_root()
    write_file(root, "tests/test_silent.mojo", SRC_SILENT)
    var cfg = base_config()
    cfg.collect = True
    cfg.paths.append("tests")

    var res = run_collect(cfg, root)

    assert_equal(res.code, 1, "a malformed suite is exit-1 class")
    assert_true(_any_contains(res.diagnostics, "tests/test_silent.mojo"))


def test_off_grammar_probe_is_drift_exit_3() raises:
    var root = temp_root()
    write_file(root, "tests/test_liar.mojo", SRC_LIAR)
    var cfg = base_config()
    cfg.collect = True
    cfg.paths.append("tests")

    var res = run_collect(cfg, root)

    assert_equal(res.code, 3, "an off-grammar probe is DRIFT, exit 3")
    assert_true(_any_contains(res.diagnostics, "tests/test_liar.mojo"))


def test_truncated_probe_refuses_forged_head_report_exit_1() raises:
    # The probe output carries a complete exact-path all-SKIP report in the
    # retained HEAD, then floods past the capture bound so the genuine report is
    # lost to truncation. The probe must apply the run path's truncation policy
    # (only a report wholly in the TAIL is trusted): the forged head report is
    # refused, no node ids are listed, and the file is a failing outcome — never
    # exit 0 with forged ids.
    var root = temp_root()
    write_file(root, "tests/test_flood.mojo", SRC_FLOOD_PROBE)
    var cfg = base_config()
    cfg.collect = True
    cfg.timeout_secs = 30
    cfg.paths.append("tests")

    var res = run_collect(cfg, root)

    assert_equal(res.code, 1, "a truncated probe is a failing outcome, not 0")
    assert_equal(
        len(res.listing), 0, "no forged node ids survive truncation refusal"
    )
    assert_true(_any_contains(res.diagnostics, "tests/test_flood.mojo"))


def test_probe_spawn_failure_is_internal_exit_3() raises:
    # A fake compiler (`/bin/true`) exits 0 without producing the binary, so the
    # build "succeeds" but the probe cannot spawn the (nonexistent) binary: a
    # SpawnFailed termination. That is an internal machinery failure (exit 3),
    # NOT a malformed suite (exit 1).
    var root = temp_root()
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    var cfg = base_config()
    cfg.collect = True
    cfg.mojo_path = "/bin/true"
    cfg.paths.append("tests")

    var res = run_collect(cfg, root)

    assert_equal(res.code, 3, "a probe spawn failure is internal, exit 3")


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
    TestSuite.discover_tests[__functions_in_module()]().run()
