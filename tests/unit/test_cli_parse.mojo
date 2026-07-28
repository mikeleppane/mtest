"""Tests for the cli parser: successful parses into a `RunnerConfig` and the
help/version directives.

Every flag is exercised for the value it lands in the config, both
short and long spellings where they exist, plus the subcommands and the two
non-error directives. Grammar edges (passthrough, forbidden args, arity errors,
and the frozen inventory) live in sibling files to keep each module's test
count modest.
"""
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

from mtest.cli import (
    ParseResult,
    flag_specs,
    help_text,
    parse_args,
    version_text,
)
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


def test_config_controls_are_parse_result_metadata() raises:
    var explicit: List[String] = ["run", "--config", "../mtest.toml"]
    var explicit_result = parse_args(explicit)
    assert_equal(explicit_result.config_path, "../mtest.toml")
    assert_false(explicit_result.no_config)

    var disabled: List[String] = ["collect", "--no-config"]
    var disabled_result = parse_args(disabled)
    assert_equal(disabled_result.config_path, "")
    assert_true(disabled_result.no_config)


def test_config_controls_are_mutually_exclusive() raises:
    var argv: List[String] = ["--config", "other.toml", "--no-config"]
    with assert_raises(
        contains="cli: '--config' and '--no-config' are mutually exclusive"
    ):
        _ = parse_args(argv)


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


def test_no_cache_sets_config() raises:
    var argv: List[String] = ["--no-cache"]
    assert_true(parse_args(argv).config.no_cache)


def test_no_cache_defaults_to_false() raises:
    var argv: List[String] = ["tests/"]
    assert_false(parse_args(argv).config.no_cache)


def test_cache_clear_sets_config() raises:
    var argv: List[String] = ["--cache-clear"]
    assert_true(parse_args(argv).config.cache_clear)


def test_cache_clear_defaults_to_false() raises:
    var argv: List[String] = ["tests/"]
    assert_false(parse_args(argv).config.cache_clear)


def test_timeout_sets_seconds() raises:
    var argv: List[String] = ["--timeout", "45"]
    assert_equal(parse_args(argv).config.timeout_secs, 45)


def test_timeout_zero_disables() raises:
    var argv: List[String] = ["--timeout", "0"]
    assert_equal(parse_args(argv).config.timeout_secs, 0)


def test_durations_sets_count() raises:
    var argv: List[String] = ["--durations", "5"]
    assert_equal(parse_args(argv).config.durations, 5)


def test_durations_defaults_to_zero() raises:
    var argv = List[String]()
    assert_equal(parse_args(argv).config.durations, 0)


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
    assert_equal(version_text(), "mtest 0.6.0")


def _rendered_option_spellings() -> List[String]:
    """Every flag spelling the generated help physically renders, in row order.

    Reads only the label region of each option row — the text before the
    padding that separates a label from its description — and splits the alias
    pairs the renderer collapses onto one physical row.
    """
    var spellings = List[String]()
    for line_slice in help_text().split("\n"):
        var line = String(line_slice)
        if not line.startswith("  -"):
            continue
        var row = String(line.removeprefix("  "))
        var label = String(row.split("  ")[0])
        for part_slice in label.split(", "):
            var spelling = String(String(part_slice).split(" ")[0])
            spellings.append(spelling^)
    return spellings^


def test_help_renders_exactly_the_flag_spec_option_set() raises:
    # The rendered option set IS the flag inventory: every spec reaches the
    # help exactly once, and the help invents nothing the parser cannot accept.
    var rendered = _rendered_option_spellings()
    var specs = flag_specs()
    assert_equal(len(rendered), len(specs))
    for spec in specs:
        var matches = 0
        for spelling in rendered:
            if spelling == spec.spelling:
                matches += 1
        assert_equal(matches, 1, "help does not render once: " + spec.spelling)
    for spelling in rendered:
        var declared = False
        for spec in specs:
            if spec.spelling == spelling:
                declared = True
        assert_true(declared, "help renders an unknown option: " + spelling)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
