"""What `prepare_debug` decides before mtest hands over the terminal.

`debug` is the one command that ends by becoming another process, so every
refusal it can ever make has to be made here, while mtest is still the process
that exits. This suite drives the preparation against real builds and real
`--skip-all` probes and asserts the mapped exit code for each class, plus the
plan a ready preparation hands back: the binary is the deterministic build
path, and the run argv, the printed run line, and the exec target are the same
three tokens, so what a reader is told to rerun is what actually ran.
"""
from std.os import getenv
from std.testing import assert_equal, assert_true, TestSuite

from mtest.config import Precompile
from mtest.session import prepare_debug

from session_fixtures import (
    SRC_COMPILE_ERROR,
    SRC_CRASH,
    SRC_LIAR,
    SRC_MATRIX,
    SRC_PASS,
    SRC_SILENT,
    base_config,
    temp_root,
    write_file,
)


def _joined(items: List[String]) -> String:
    var out = String("")
    for x in items:
        out += x
    return out^


def test_ready_plan_names_the_binary_and_the_only_flag() raises:
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()

    var outcome = prepare_debug(
        cfg, root, "tests/test_matrix.mojo::test_add_two"
    )

    assert_equal(outcome.code, 0, "a known test in a good file is ready")
    assert_equal(len(outcome.diagnostics), 0, "a ready plan says nothing")
    assert_true(
        outcome.plan.binary.startswith("build/bin/"),
        "the binary is the deterministic build path: " + outcome.plan.binary,
    )
    assert_equal(len(outcome.plan.run_argv), 3)
    assert_equal(outcome.plan.run_argv[0], outcome.plan.binary)
    assert_equal(outcome.plan.run_argv[1], "--only")
    assert_equal(outcome.plan.run_argv[2], "test_add_two")
    assert_true(
        outcome.plan.run_line.endswith("--only test_add_two"),
        "the printed run line ends in the selector: " + outcome.plan.run_line,
    )
    assert_true(
        outcome.plan.binary in outcome.plan.run_line,
        "the printed run line names the binary it will exec",
    )
    assert_true(
        "tests/test_matrix.mojo" in outcome.plan.build_line,
        "the printed build line names the source: " + outcome.plan.build_line,
    )
    assert_true(
        " build " in outcome.plan.build_line,
        "the printed build line is a mojo build invocation",
    )


def test_unknown_test_name_is_a_usage_refusal() raises:
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()

    var outcome = prepare_debug(cfg, root, "tests/test_matrix.mojo::test_nope")

    assert_equal(outcome.code, 4, "an unknown test is a pre-handoff refusal")
    assert_true(
        "unknown test" in _joined(outcome.diagnostics),
        "the refusal names the unknown test: " + _joined(outcome.diagnostics),
    )


def test_malformed_node_id_is_a_usage_refusal() raises:
    var root = temp_root()
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    var cfg = base_config()

    var outcome = prepare_debug(cfg, root, "tests/test_pass.mojo::a::b")

    assert_equal(outcome.code, 4)
    assert_true("PATH::TEST" in _joined(outcome.diagnostics))


def test_plain_path_operand_is_a_usage_refusal() raises:
    var root = temp_root()
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    var cfg = base_config()

    var outcome = prepare_debug(cfg, root, "tests/test_pass.mojo")

    assert_equal(outcome.code, 4, "debug needs a test name, not a file")
    assert_true("PATH::TEST" in _joined(outcome.diagnostics))


def test_unknown_path_is_a_usage_refusal() raises:
    var root = temp_root()
    var cfg = base_config()

    var outcome = prepare_debug(cfg, root, "tests/test_gone.mojo::test_x")

    assert_equal(outcome.code, 4)
    assert_true("no such path" in _joined(outcome.diagnostics))


def test_compile_error_is_the_failing_class() raises:
    var root = temp_root()
    write_file(root, "tests/test_broken.mojo", SRC_COMPILE_ERROR)
    var cfg = base_config()

    var outcome = prepare_debug(cfg, root, "tests/test_broken.mojo::test_x")

    assert_equal(outcome.code, 1, "a file that will not compile is exit 1")
    assert_true(
        "the build failed to compile" in _joined(outcome.diagnostics),
        "the diagnostic names the build, not the probe: "
        + _joined(outcome.diagnostics),
    )


def test_crashing_probe_is_the_failing_class() raises:
    var root = temp_root()
    write_file(root, "tests/test_crash.mojo", SRC_CRASH)
    var cfg = base_config()

    var outcome = prepare_debug(cfg, root, "tests/test_crash.mojo::test_x")

    assert_equal(outcome.code, 1, "a probe that crashes is exit 1")
    assert_true("crashed" in _joined(outcome.diagnostics))


def test_malformed_suite_is_the_failing_class() raises:
    var root = temp_root()
    write_file(root, "tests/test_silent.mojo", SRC_SILENT)
    var cfg = base_config()

    var outcome = prepare_debug(cfg, root, "tests/test_silent.mojo::test_x")

    assert_equal(outcome.code, 1, "a probe that lists nothing is exit 1")
    assert_true("malformed suite" in _joined(outcome.diagnostics))


def test_unspawnable_compiler_is_an_internal_error() raises:
    var root = temp_root()
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    var cfg = base_config()
    cfg.mojo_path = String("/nonexistent/mojo")

    var outcome = prepare_debug(cfg, root, "tests/test_pass.mojo::test_pass")

    assert_equal(outcome.code, 3, "a compiler that will not spawn is exit 3")
    assert_true(
        "internal build failure" in _joined(outcome.diagnostics),
        "the diagnostic names the machinery that failed, and never blames the"
        " test file's own report: "
        + _joined(outcome.diagnostics),
    )


def test_compile_error_surfaces_the_compiler_output() raises:
    """The banner travels on the diagnostic channel, since nothing echoes it.

    A run prints the compiler's own words under a COMPILE-ERROR verdict. Debug
    has no reporter to do that, so a preparation that says only "the build
    failed to compile" would send a developer back to a command line to learn
    what a process that already knew refused to tell them.
    """
    var root = temp_root()
    write_file(root, "tests/test_broken.mojo", SRC_COMPILE_ERROR)
    var cfg = base_config()

    var outcome = prepare_debug(cfg, root, "tests/test_broken.mojo::test_x")

    assert_equal(outcome.code, 1)
    assert_true(
        len(outcome.diagnostics) > 1,
        "the compiler's output follows the diagnostic line",
    )
    assert_true(
        "error" in _joined(outcome.diagnostics),
        "the compiler's own words reach stderr: "
        + _joined(outcome.diagnostics),
    )


def test_compile_timeout_is_named_as_itself() raises:
    """A build killed at its deadline is not a malformed suite.

    `COMPILE_TIMEOUT` had no phrase of its own, so it fell through to the
    probe's malformed-suite wording — a report about a probe that never ran,
    for a compiler mtest killed itself.
    """
    var root = temp_root()
    write_file(root, "tests/test_slow.mojo", SRC_PASS)
    var cfg = base_config()
    cfg.compile_timeout_secs = 1
    cfg.mojo_path = (
        getenv("PIXI_PROJECT_ROOT", "")
        + "/scripts/fixtures/toolchain/fake_slow_mojo.py"
    )

    var outcome = prepare_debug(cfg, root, "tests/test_slow.mojo::test_pass")

    assert_equal(outcome.code, 1, "a build killed at its deadline is exit 1")
    assert_true(
        "--compile-timeout" in _joined(outcome.diagnostics),
        "the diagnostic names the deadline that killed it: "
        + _joined(outcome.diagnostics),
    )
    assert_true(
        "malformed suite" not in _joined(outcome.diagnostics),
        "and never borrows the probe's wording: "
        + _joined(outcome.diagnostics),
    )


def test_failed_precompile_step_is_the_failing_class() raises:
    """A compiler that rejected a package is exit 1, as it is for a run.

    Folding it in with the spawn failures reported an ordinary compile error as
    an internal mtest error, which points the reader at the runner instead of
    at their own source.
    """
    var root = temp_root()
    write_file(root, "badpkg/__init__.mojo", SRC_COMPILE_ERROR)
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    var cfg = base_config()
    cfg.precompiles.append(Precompile("badpkg", None))

    var outcome = prepare_debug(cfg, root, "tests/test_pass.mojo::test_pass")

    assert_equal(outcome.code, 1, "a rejected precompile step is exit 1")
    assert_true(
        "precompile step 'badpkg'" in _joined(outcome.diagnostics),
        "the diagnostic names the step: " + _joined(outcome.diagnostics),
    )
    assert_true(
        len(outcome.diagnostics) > 1,
        "and carries the compiler output that explains it",
    )


def test_unspawnable_precompile_compiler_stays_an_internal_error() raises:
    """The other half of the split: machinery failures are still exit 3."""
    var root = temp_root()
    write_file(
        root, "goodpkg/__init__.mojo", "def value() -> Int:\n    return 1\n"
    )
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    var cfg = base_config()
    cfg.mojo_path = String("/nonexistent/mojo")
    cfg.precompiles.append(Precompile("goodpkg", None))

    var outcome = prepare_debug(cfg, root, "tests/test_pass.mojo::test_pass")

    assert_equal(outcome.code, 3, "a compiler that will not spawn is exit 3")
    assert_true(
        "could not be spawned" in _joined(outcome.diagnostics),
        "the diagnostic names the machinery: " + _joined(outcome.diagnostics),
    )


def test_off_grammar_probe_is_drift() raises:
    var root = temp_root()
    write_file(root, "tests/test_liar.mojo", SRC_LIAR)
    var cfg = base_config()

    var outcome = prepare_debug(cfg, root, "tests/test_liar.mojo::test_one")

    assert_equal(outcome.code, 3, "drift is an internal error, never a verdict")
    assert_true("drift" in _joined(outcome.diagnostics))


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
