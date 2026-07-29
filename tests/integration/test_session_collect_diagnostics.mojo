"""What `--collect-only` reports when a probe goes wrong.

Split out of `test_session_collect.mojo` by weight: a suite that drives real
sessions pays a fixed per-process price for the first file it puts through the
compiler, and the original paid it twice, so the two halves each carry one.

The subject is the diagnostic half of collection. Listing is only trustworthy if
a file that cannot be listed says so instead of vanishing: a compile error, a
crashing probe, a probe that hangs past its deadline, a malformed suite, a probe
that answers off-grammar, and one that forges a truncated head report each has
its own exit code and its own diagnostic, and listing continues past the ones
that are merely diagnostic.
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
    # A fake compiler (`/usr/bin/true`) exits 0 without producing the binary.
    # The build "succeeds" but the probe cannot spawn the nonexistent binary: a
    # SpawnFailed termination. That is an internal machinery failure (exit 3),
    # NOT a malformed suite (exit 1).
    var root = temp_root()
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    var cfg = base_config()
    cfg.collect = True
    cfg.mojo_path = true_binary()
    cfg.paths.append("tests")

    var res = run_collect(cfg, root)

    assert_equal(res.code, 3, "a probe spawn failure is internal, exit 3")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
