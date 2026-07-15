"""Tests for the cli parser: successful parses into a `RunnerConfig` and the
help/version directives.

Every available flag is exercised for the value it lands in the config, both
short and long spellings where they exist, plus the subcommands and the two
non-error directives. Grammar edges (passthrough, forbidden args, arity errors,
refusals, the frozen inventory) live in sibling files to keep each module's test
count modest.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.cli import ParseResult, parse_args, version_text, help_text
from mtest.config import ColorWhen, ShowOutput, Verbosity


def test_empty_argv_is_run_with_defaults() raises:
    var argv = List[String]()
    var r = parse_args(argv)
    assert_true(r.is_run())
    assert_equal(len(r.config.paths), 0)
    assert_equal(r.config.timeout_secs, 300)
    assert_false(r.config.exitfirst)


def test_single_path_operand() raises:
    var argv: List[String] = ["tests/"]
    var r = parse_args(argv)
    assert_true(r.is_run())
    assert_equal(len(r.config.paths), 1)
    assert_equal(r.config.paths[0], "tests/")


def test_multiple_path_operands_in_order() raises:
    var argv: List[String] = ["tests/a.mojo", "tests/b.mojo"]
    var r = parse_args(argv)
    assert_equal(len(r.config.paths), 2)
    assert_equal(r.config.paths[0], "tests/a.mojo")
    assert_equal(r.config.paths[1], "tests/b.mojo")


def test_empty_argv_has_no_keyword_filter() raises:
    var argv = List[String]()
    var r = parse_args(argv)
    assert_equal(r.config.keyword, "")


def test_k_captures_the_keyword_expression() raises:
    var argv: List[String] = ["tests/", "-k", "test_add"]
    var r = parse_args(argv)
    assert_true(r.is_run())
    assert_equal(r.config.keyword, "test_add")
    assert_equal(len(r.config.paths), 1)
    assert_equal(r.config.paths[0], "tests/")


def test_k_inline_equals_form() raises:
    var argv: List[String] = ["-k=slow OR fast"]
    var r = parse_args(argv)
    assert_equal(r.config.keyword, "slow OR fast")


def test_run_subcommand_is_consumed() raises:
    var argv: List[String] = ["run", "tests/"]
    var r = parse_args(argv)
    assert_true(r.is_run())
    assert_equal(len(r.config.paths), 1)
    assert_equal(r.config.paths[0], "tests/")


def test_run_subcommand_alone_is_defaults() raises:
    var argv: List[String] = ["run"]
    var r = parse_args(argv)
    assert_true(r.is_run())
    assert_equal(len(r.config.paths), 0)


def test_leading_nonsubcommand_token_is_a_path() raises:
    # A node id starts with a path, not a subcommand name.
    var argv: List[String] = ["tests/test_math.mojo::test_add"]
    var r = parse_args(argv)
    assert_true(r.is_run())
    assert_equal(r.config.paths[0], "tests/test_math.mojo::test_add")


def test_version_subcommand() raises:
    var argv: List[String] = ["version"]
    var r = parse_args(argv)
    assert_true(r.is_version())


def test_help_subcommand() raises:
    var argv: List[String] = ["help"]
    var r = parse_args(argv)
    assert_true(r.is_help())


def test_version_long_flag() raises:
    var argv: List[String] = ["--version"]
    assert_true(parse_args(argv).is_version())


def test_help_long_flag() raises:
    var argv: List[String] = ["--help"]
    assert_true(parse_args(argv).is_help())


def test_help_short_flag() raises:
    var argv: List[String] = ["-h"]
    assert_true(parse_args(argv).is_help())


def test_exclude_accumulates_and_preserves_spaces() raises:
    var argv: List[String] = [
        "--exclude",
        "tests/test_slow_*.mojo",
        "--exclude",
        "a b c",
    ]
    var r = parse_args(argv)
    assert_equal(len(r.config.excludes), 2)
    assert_equal(r.config.excludes[0], "tests/test_slow_*.mojo")
    assert_equal(r.config.excludes[1], "a b c")


def test_include_paths_accumulate() raises:
    var argv: List[String] = ["-I", "build", "-I", "vendor"]
    var r = parse_args(argv)
    assert_equal(len(r.config.include_paths), 2)
    assert_equal(r.config.include_paths[0], "build")
    assert_equal(r.config.include_paths[1], "vendor")


def test_build_args_accumulate() raises:
    var argv: List[String] = [
        "--build-arg",
        "--no-optimization",
        "--build-arg",
        "--debug-level=full",
    ]
    var r = parse_args(argv)
    assert_equal(len(r.config.build_args), 2)
    assert_equal(r.config.build_args[0], "--no-optimization")
    assert_equal(r.config.build_args[1], "--debug-level=full")


def test_precompile_with_and_without_out() raises:
    var argv: List[String] = [
        "--precompile",
        "src/mylib:build/mylib.mojopkg",
        "--precompile",
        "src/other",
    ]
    var r = parse_args(argv)
    assert_equal(len(r.config.precompiles), 2)
    assert_equal(r.config.precompiles[0].src, "src/mylib")
    assert_true(r.config.precompiles[0].out)
    assert_equal(r.config.precompiles[0].out.value(), "build/mylib.mojopkg")
    assert_equal(r.config.precompiles[1].src, "src/other")
    assert_false(Bool(r.config.precompiles[1].out))


def test_mojo_flag_sets_path() raises:
    var argv: List[String] = ["--mojo", "/opt/mojo/bin/mojo"]
    var r = parse_args(argv)
    assert_equal(r.config.mojo_path, "/opt/mojo/bin/mojo")


def test_exitfirst_short_and_long() raises:
    var short: List[String] = ["-x"]
    assert_true(parse_args(short).config.exitfirst)
    var long: List[String] = ["--exitfirst"]
    assert_true(parse_args(long).config.exitfirst)


def test_timeout_sets_seconds() raises:
    var argv: List[String] = ["--timeout", "45"]
    assert_equal(parse_args(argv).config.timeout_secs, 45)


def test_timeout_zero_disables() raises:
    var argv: List[String] = ["--timeout", "0"]
    assert_equal(parse_args(argv).config.timeout_secs, 0)


def test_dash_s_sets_show_output_all() raises:
    var argv: List[String] = ["-s"]
    assert_true(parse_args(argv).config.show_output == ShowOutput.ALL)


def test_show_output_modes() raises:
    var a: List[String] = ["--show-output", "all"]
    assert_true(parse_args(a).config.show_output == ShowOutput.ALL)
    var f: List[String] = ["--show-output", "failures"]
    assert_true(parse_args(f).config.show_output == ShowOutput.FAILURES)
    var n: List[String] = ["--show-output", "none"]
    assert_true(parse_args(n).config.show_output == ShowOutput.NONE)


def test_quiet_and_verbose_set_verbosity() raises:
    var q: List[String] = ["-q"]
    assert_true(parse_args(q).config.verbosity == Verbosity.QUIET)
    var v: List[String] = ["-v"]
    assert_true(parse_args(v).config.verbosity == Verbosity.VERBOSE)


def test_color_modes() raises:
    var a: List[String] = ["--color", "auto"]
    assert_true(parse_args(a).config.color == ColorWhen.AUTO)
    var al: List[String] = ["--color", "always"]
    assert_true(parse_args(al).config.color == ColorWhen.ALWAYS)
    var n: List[String] = ["--color", "never"]
    assert_true(parse_args(n).config.color == ColorWhen.NEVER)


def test_version_text_uses_version_constant() raises:
    assert_equal(version_text(), "mtest 0.1.0-dev")


def test_help_text_mentions_usage() raises:
    assert_true("usage: mtest" in help_text())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
