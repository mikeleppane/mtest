"""Tests for the `debug` subcommand's grammar and its refusals.

`debug` is the narrowest grammar in the parser: exactly one `PATH::TEST`
operand and the build controls that decide how that one file is compiled.
Every other flag is refused, and the reporter flags carry the reason — a
command that replaces the mtest process can write no terminal record, and
colors no output, because there is no reporter left to do either.
"""
from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from mtest.cli import parse_args
from mtest.config import Verbosity


def test_debug_takes_one_node_id_operand() raises:
    var argv: List[String] = ["debug", "tests/test_a.mojo::test_x"]
    var r = parse_args(argv)
    assert_true(r.is_debug(), "the debug subcommand yields a debug result")
    assert_equal(r.operand, "tests/test_a.mojo::test_x")
    assert_equal(len(r.config.paths), 0, "the node id never becomes a path")


def test_debug_accepts_the_build_controls() raises:
    var argv: List[String] = [
        "debug",
        "--mojo",
        "/opt/mojo",
        "-I",
        "src",
        "--build-arg",
        "-D",
        "tests/test_a.mojo::test_x",
        "--",
        "--debug-level=full",
    ]
    var r = parse_args(argv)
    assert_true(r.is_debug())
    assert_equal(r.config.mojo_path, "/opt/mojo")
    assert_equal(len(r.config.include_paths), 1)
    assert_equal(r.config.include_paths[0], "src")
    assert_equal(len(r.config.build_args), 2)
    assert_equal(r.config.build_args[0], "-D")
    assert_equal(r.config.build_args[1], "--debug-level=full")


def test_debug_accepts_the_configuration_controls() raises:
    var explicit: List[String] = [
        "debug",
        "--config",
        "checks.toml",
        "tests/test_a.mojo::test_x",
    ]
    var r = parse_args(explicit)
    assert_true(r.is_debug())
    assert_equal(r.config_path, "checks.toml")

    var disabled: List[String] = [
        "debug",
        "--no-config",
        "-q",
        "tests/test_a.mojo::test_x",
    ]
    var d = parse_args(disabled)
    assert_true(d.is_debug())
    assert_true(d.no_config)
    assert_true(d.config.verbosity == Verbosity.QUIET)


def test_debug_help_still_prints_help() raises:
    var argv: List[String] = ["debug", "--help"]
    var r = parse_args(argv)
    assert_true(r.is_help(), "--help wins over the debug grammar")


def test_debug_without_an_operand_is_a_usage_error() raises:
    var argv: List[String] = ["debug"]
    with assert_raises(contains="exactly one PATH::TEST"):
        _ = parse_args(argv)


def test_debug_refuses_a_plain_path_operand() raises:
    var argv: List[String] = ["debug", "tests/test_a.mojo"]
    with assert_raises(contains="exactly one PATH::TEST"):
        _ = parse_args(argv)


def test_debug_refuses_a_second_separator() raises:
    var argv: List[String] = ["debug", "tests/test_a.mojo::a::b"]
    with assert_raises(contains="exactly one PATH::TEST"):
        _ = parse_args(argv)


def test_debug_refuses_two_operands() raises:
    var argv: List[String] = [
        "debug",
        "tests/test_a.mojo::test_x",
        "tests/test_b.mojo::test_y",
    ]
    with assert_raises(contains="exactly one PATH::TEST"):
        _ = parse_args(argv)


def test_debug_refuses_reporter_flags_with_the_reason() raises:
    var argv: List[String] = [
        "debug",
        "--json",
        "-",
        "tests/test_a.mojo::test_x",
    ]
    with assert_raises(contains="no terminal record could be written"):
        _ = parse_args(argv)
    var junit: List[String] = [
        "debug",
        "--junit-xml",
        "r.xml",
        "tests/test_a.mojo::test_x",
    ]
    with assert_raises(contains="no terminal record could be written"):
        _ = parse_args(junit)
    var annotations: List[String] = [
        "debug",
        "--gh-annotations",
        "off",
        "tests/test_a.mojo::test_x",
    ]
    with assert_raises(contains="no terminal record could be written"):
        _ = parse_args(annotations)


def test_debug_refuses_color_because_nothing_renders() raises:
    var argv: List[String] = [
        "debug",
        "--color",
        "never",
        "tests/test_a.mojo::test_x",
    ]
    with assert_raises(contains="no reporter to color"):
        _ = parse_args(argv)


def test_debug_refuses_retries_and_timeout_rather_than_overriding() raises:
    var retries: List[String] = [
        "debug",
        "--retries",
        "1",
        "tests/test_a.mojo::test_x",
    ]
    with assert_raises(contains="cannot be combined with 'debug'"):
        _ = parse_args(retries)
    var timeout: List[String] = [
        "debug",
        "--timeout",
        "5",
        "tests/test_a.mojo::test_x",
    ]
    with assert_raises(contains="cannot be combined with 'debug'"):
        _ = parse_args(timeout)


def test_debug_refuses_selection_and_state_flags() raises:
    var keyword: List[String] = [
        "debug",
        "-k",
        "fast",
        "tests/test_a.mojo::test_x",
    ]
    with assert_raises(contains="-k"):
        _ = parse_args(keyword)
    var state: List[String] = ["debug", "--lf", "tests/test_a.mojo::test_x"]
    with assert_raises(contains="--lf"):
        _ = parse_args(state)
    var clear: List[String] = [
        "debug",
        "--cache-clear",
        "tests/test_a.mojo::test_x",
    ]
    with assert_raises(contains="--cache-clear"):
        _ = parse_args(clear)


def test_debug_refuses_an_unknown_flag_as_an_unknown_flag() raises:
    var argv: List[String] = ["debug", "--nope", "tests/test_a.mojo::test_x"]
    with assert_raises(contains="unknown flag"):
        _ = parse_args(argv)


def test_debug_refuses_quiet_with_verbose() raises:
    var argv: List[String] = ["debug", "-q", "-v", "tests/test_a.mojo::test_x"]
    with assert_raises(contains="mutually exclusive"):
        _ = parse_args(argv)


def test_debug_refuses_config_with_no_config() raises:
    var argv: List[String] = [
        "debug",
        "--config",
        "a.toml",
        "--no-config",
        "tests/test_a.mojo::test_x",
    ]
    with assert_raises(contains="mutually exclusive"):
        _ = parse_args(argv)


def test_debug_refuses_a_forbidden_build_argument() raises:
    var argv: List[String] = [
        "debug",
        "tests/test_a.mojo::test_x",
        "--",
        "-o",
        "mine",
    ]
    with assert_raises(contains="-o"):
        _ = parse_args(argv)


def test_debug_missing_flag_value_is_a_usage_error() raises:
    var argv: List[String] = ["debug", "tests/test_a.mojo::test_x", "--mojo"]
    with assert_raises(contains="requires a value"):
        _ = parse_args(argv)


def test_a_refused_flag_says_why_even_without_its_value() raises:
    """The reason must survive the arity check, not be pre-empted by it.

    Refusing a flag only after consuming its value meant `debug NODE --json`
    reported a missing value and never said that a process which replaces
    itself can write no report — the one thing the refusal exists to explain.
    """
    var json: List[String] = ["debug", "tests/test_a.mojo::test_x", "--json"]
    with assert_raises(contains="no terminal record could be written"):
        _ = parse_args(json)
    var junit: List[String] = [
        "debug",
        "tests/test_a.mojo::test_x",
        "--junit-xml",
    ]
    with assert_raises(contains="no terminal record could be written"):
        _ = parse_args(junit)
    var annotations: List[String] = [
        "debug",
        "tests/test_a.mojo::test_x",
        "--gh-annotations",
    ]
    with assert_raises(contains="no terminal record could be written"):
        _ = parse_args(annotations)
    var color: List[String] = ["debug", "tests/test_a.mojo::test_x", "--color"]
    with assert_raises(contains="no reporter to color"):
        _ = parse_args(color)
    var retries: List[String] = [
        "debug",
        "tests/test_a.mojo::test_x",
        "--retries",
    ]
    with assert_raises(contains="cannot be combined with 'debug'"):
        _ = parse_args(retries)


def test_an_accepted_flag_still_reports_its_missing_value() raises:
    var argv: List[String] = ["debug", "tests/test_a.mojo::test_x", "-I"]
    with assert_raises(contains="requires a value"):
        _ = parse_args(argv)


def test_other_results_carry_an_empty_operand() raises:
    """The operand ledger: every factory but `debug` leaves it empty.

    `ParseResult` has no field defaults, so each factory sets `operand`
    explicitly, and a missed one would surface as a stale node id on a result
    that never had an operand at all.
    """
    var run: List[String] = ["tests/"]
    assert_equal(parse_args(run).operand, "")
    var collect: List[String] = ["collect", "tests/"]
    assert_equal(parse_args(collect).operand, "")
    var config_show: List[String] = ["config", "show"]
    assert_equal(parse_args(config_show).operand, "")
    var doctor: List[String] = ["doctor"]
    assert_equal(parse_args(doctor).operand, "")
    var version: List[String] = ["version"]
    assert_equal(parse_args(version).operand, "")
    var help: List[String] = ["help"]
    assert_equal(parse_args(help).operand, "")
    var help_flag: List[String] = ["--help"]
    assert_equal(parse_args(help_flag).operand, "")


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
