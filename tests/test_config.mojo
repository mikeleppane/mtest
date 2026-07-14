"""Tests for the Layer 1 config module: `RunnerConfig` defaults and the pure
mojo-path resolution helper.

`RunnerConfig` is data plus a couple of pure helpers — no parsing, no I/O. This
file asserts two things exhaustively: every field of a freshly-built config
sits at its contract default, and `resolve_mojo_path` implements the
flag > MTEST_MOJO env > "mojo" precedence for all four presence combinations.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.config import (
    ColorWhen,
    Precompile,
    RunnerConfig,
    ShowOutput,
    Verbosity,
    resolve_mojo_path,
)


def test_default_paths_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.paths), 0)


def test_default_excludes_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.excludes), 0)


def test_default_gates_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.gates), 0)


def test_default_precompiles_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.precompiles), 0)


def test_default_build_args_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.build_args), 0)


def test_default_include_paths_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.include_paths), 0)


def test_default_mojo_path_is_mojo() raises:
    var c = RunnerConfig.default()
    assert_equal(c.mojo_path, "mojo")


def test_default_timeout_secs_is_300() raises:
    var c = RunnerConfig.default()
    assert_equal(c.timeout_secs, 300)


def test_default_show_output_is_failures() raises:
    var c = RunnerConfig.default()
    assert_true(c.show_output == ShowOutput.FAILURES)


def test_default_verbosity_is_normal() raises:
    var c = RunnerConfig.default()
    assert_true(c.verbosity == Verbosity.NORMAL)


def test_default_color_is_auto() raises:
    var c = RunnerConfig.default()
    assert_true(c.color == ColorWhen.AUTO)


def test_default_exitfirst_is_false() raises:
    var c = RunnerConfig.default()
    assert_equal(c.exitfirst, False)


def test_precompile_holds_src_and_optional_out() raises:
    var with_out = Precompile(src="a.mojo", out=Optional[String]("a_out"))
    assert_equal(with_out.src, "a.mojo")
    assert_true(with_out.out)
    assert_equal(with_out.out.value(), "a_out")

    var without_out = Precompile(src="b.mojo", out=Optional[String](None))
    assert_equal(without_out.src, "b.mojo")
    assert_true(not without_out.out)


def test_resolve_mojo_path_flag_and_env_present_prefers_flag() raises:
    var got = resolve_mojo_path(
        Optional[String]("/flag/mojo"), Optional[String]("/env/mojo")
    )
    assert_equal(got, "/flag/mojo")


def test_resolve_mojo_path_flag_only() raises:
    var got = resolve_mojo_path(
        Optional[String]("/flag/mojo"), Optional[String](None)
    )
    assert_equal(got, "/flag/mojo")


def test_resolve_mojo_path_env_only() raises:
    var got = resolve_mojo_path(
        Optional[String](None), Optional[String]("/env/mojo")
    )
    assert_equal(got, "/env/mojo")


def test_resolve_mojo_path_neither_falls_back_to_mojo() raises:
    var got = resolve_mojo_path(Optional[String](None), Optional[String](None))
    assert_equal(got, "mojo")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
