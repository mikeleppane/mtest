"""Tests for `build_flags_string`: the shell-ready echo of the build-affecting
options in effect, which the console splices into a run-failure `reproduce:` line.

The helper is the inverse of the parser for the flags that change how a file is
built: `--mojo` (only when non-default), `-I`, `--build-arg`, and `--precompile`.
This file asserts the empty case, the ordering across flag kinds, that a default
mojo path contributes nothing, and that a value needing the shell is quoted.
"""
from std.testing import assert_equal, assert_true

from mtest.cli import build_flags_string
from mtest.config import Precompile, RunnerConfig


def test_empty_config_yields_empty_string() raises:
    var c = RunnerConfig.default()
    assert_equal(build_flags_string(c), "")


def test_default_mojo_path_contributes_nothing() raises:
    var c = RunnerConfig.default()
    # default() leaves mojo_path == "mojo"; it must not appear.
    assert_equal(build_flags_string(c), "")


def test_non_default_mojo_path_is_echoed() raises:
    var c = RunnerConfig.default()
    c.mojo_path = "/opt/mojo/bin/mojo"
    assert_equal(build_flags_string(c), "--mojo /opt/mojo/bin/mojo")


def test_includes_build_args_and_precompiles_in_order() raises:
    var c = RunnerConfig.default()
    c.include_paths = ["build", "vendor"]
    c.build_args = ["-D", "FOO=1"]
    c.precompiles = [
        Precompile(src="a.mojo", out=Optional[String](None)),
        Precompile(src="b.mojo", out=Optional[String]("out/b.mojopkg")),
    ]
    var got = build_flags_string(c)
    assert_equal(
        got,
        (
            "-I build -I vendor --build-arg -D --build-arg FOO=1 "
            "--precompile a.mojo --precompile b.mojo:out/b.mojopkg"
        ),
    )


def test_space_containing_arg_is_shell_quoted() raises:
    var c = RunnerConfig.default()
    c.include_paths = ["my dir"]
    assert_equal(build_flags_string(c), "-I 'my dir'")


def test_mixed_with_quoted_value() raises:
    var c = RunnerConfig.default()
    c.mojo_path = "/opt/mojo"
    c.build_args = ["a b"]
    assert_equal(build_flags_string(c), "--mojo /opt/mojo --build-arg 'a b'")
