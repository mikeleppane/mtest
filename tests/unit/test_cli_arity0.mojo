"""Arity-0 parameterized tests plus placement, after-`--`, and unknown flags.

Every valueless spelling (`-x`, `--exitfirst`, `-s`, `-q`, `-v`, `-h`,
`--help`, `--version`) rejects an attached `=value`. Placement cases prove a
flag is recognized wherever it sits, after-`--` cases prove a flag token is
forwarded verbatim once passthrough starts, and the unknown-flag cases prove an
unrecognized token is a located usage error.
"""
from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from mtest.cli import parse_args


# --- valueless spellings reject an attached value ---


def test_exitfirst_short_rejects_value() raises:
    var argv: List[String] = ["-x=1"]
    with assert_raises(contains="takes no value"):
        _ = parse_args(argv)


def test_exitfirst_long_rejects_value() raises:
    var argv: List[String] = ["--exitfirst=1"]
    with assert_raises(contains="takes no value"):
        _ = parse_args(argv)


def test_show_all_rejects_value() raises:
    var argv: List[String] = ["-s=1"]
    with assert_raises(contains="takes no value"):
        _ = parse_args(argv)


def test_quiet_rejects_value() raises:
    var argv: List[String] = ["-q=1"]
    with assert_raises(contains="takes no value"):
        _ = parse_args(argv)


def test_verbose_rejects_value() raises:
    var argv: List[String] = ["-v=1"]
    with assert_raises(contains="takes no value"):
        _ = parse_args(argv)


def test_help_short_rejects_value() raises:
    var argv: List[String] = ["-h=1"]
    with assert_raises(contains="takes no value"):
        _ = parse_args(argv)


def test_help_long_rejects_value() raises:
    var argv: List[String] = ["--help=1"]
    with assert_raises(contains="takes no value"):
        _ = parse_args(argv)


def test_version_rejects_value() raises:
    var argv: List[String] = ["--version=1"]
    with assert_raises(contains="takes no value"):
        _ = parse_args(argv)


# --- placement: a flag is recognized wherever it sits ---


def test_exitfirst_placement_leading() raises:
    var argv: List[String] = ["-x", "tests/"]
    assert_true(parse_args(argv).config.exitfirst)


def test_exitfirst_placement_trailing() raises:
    var argv: List[String] = ["tests/", "-x"]
    assert_true(parse_args(argv).config.exitfirst)


def test_show_all_placement_between_paths() raises:
    var argv: List[String] = ["a.mojo", "-s", "b.mojo"]
    var r = parse_args(argv)
    assert_equal(len(r.config.paths), 2)
    assert_true(r.config.show_output.value == 1)


# --- after-`--`: a flag token becomes a verbatim build arg ---


def test_flag_after_double_dash_is_a_build_arg() raises:
    var argv: List[String] = ["--", "-x"]
    var r = parse_args(argv)
    assert_true(r.is_run())
    assert_equal(len(r.config.build_args), 1)
    assert_equal(r.config.build_args[0], "-x")
    # ...and it did NOT set exitfirst.
    assert_true(not r.config.exitfirst)


def test_value_flag_after_double_dash_not_parsed() raises:
    var argv: List[String] = ["--", "--exclude", "pat"]
    var r = parse_args(argv)
    assert_equal(len(r.config.excludes), 0)
    assert_equal(len(r.config.build_args), 2)
    assert_equal(r.config.build_args[0], "--exclude")
    assert_equal(r.config.build_args[1], "pat")


# --- unknown flags ---


def test_unknown_long_flag() raises:
    var argv: List[String] = ["--frobnicate"]
    with assert_raises(contains="unknown flag '--frobnicate'"):
        _ = parse_args(argv)


def test_unknown_short_flag() raises:
    var argv: List[String] = ["-z"]
    with assert_raises(contains="unknown flag '-z'"):
        _ = parse_args(argv)


def test_unknown_flag_with_equals_value() raises:
    var argv: List[String] = ["--frobnicate=1"]
    with assert_raises(contains="unknown flag '--frobnicate'"):
        _ = parse_args(argv)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
