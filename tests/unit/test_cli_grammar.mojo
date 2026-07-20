"""Tests for cli grammar edges: `--` passthrough, forbidden build arguments,
short-flag bundling rejection, `-q`/`-v` mutual exclusion, and free
interleaving of flags with positional paths.

These are the rules that make the parser hand-rolled rather than a library: a
repeated flag never re-splits its value on spaces, everything after `--` is
forwarded verbatim yet still policed for forbidden arguments, and bundled short
flags are refused.
"""
from std.testing import assert_equal, assert_raises, assert_true

from mtest.cli import parse_args


def test_double_dash_forwards_verbatim_as_build_args() raises:
    var argv: List[String] = ["tests/", "--", "--no-optimization", "-D", "FOO"]
    var r = parse_args(argv)
    assert_equal(len(r.config.paths), 1)
    assert_equal(len(r.config.build_args), 3)
    assert_equal(r.config.build_args[0], "--no-optimization")
    assert_equal(r.config.build_args[1], "-D")
    assert_equal(r.config.build_args[2], "FOO")


def test_double_dash_preserves_spaces_byte_exact() raises:
    var argv: List[String] = ["--", "--flag=a b c"]
    var r = parse_args(argv)
    assert_equal(len(r.config.build_args), 1)
    assert_equal(r.config.build_args[0], "--flag=a b c")


def test_build_arg_flag_and_passthrough_combine() raises:
    var argv: List[String] = ["--build-arg", "--first", "--", "--second"]
    var r = parse_args(argv)
    assert_equal(len(r.config.build_args), 2)
    assert_equal(r.config.build_args[0], "--first")
    assert_equal(r.config.build_args[1], "--second")


def test_bare_double_dash_with_nothing_after() raises:
    var argv: List[String] = ["tests/", "--"]
    var r = parse_args(argv)
    assert_equal(len(r.config.build_args), 0)
    assert_equal(len(r.config.paths), 1)


def test_forbidden_output_selection_in_build_arg() raises:
    var argv: List[String] = ["--build-arg", "-o"]
    with assert_raises(contains="forbidden build argument '-o'"):
        _ = parse_args(argv)


def test_forbidden_output_selection_equals_form() raises:
    var argv: List[String] = ["--build-arg", "-o=out.bin"]
    with assert_raises(contains="output selection"):
        _ = parse_args(argv)


def test_forbidden_emit_in_build_arg() raises:
    var argv: List[String] = ["--build-arg", "--emit"]
    with assert_raises(contains="emit-type selection"):
        _ = parse_args(argv)


def test_forbidden_emit_equals_form_after_double_dash() raises:
    var argv: List[String] = ["--", "--emit=llvm"]
    with assert_raises(contains="emit-type selection"):
        _ = parse_args(argv)


def test_forbidden_output_selection_after_double_dash() raises:
    var argv: List[String] = ["--", "-o", "out.bin"]
    with assert_raises(contains="forbidden build argument '-o'"):
        _ = parse_args(argv)


def test_forbidden_extra_source_operand_after_double_dash() raises:
    var argv: List[String] = ["--", "extra_source.mojo"]
    with assert_raises(contains="owns the source list"):
        _ = parse_args(argv)


def test_forbidden_output_selection_in_include_value() raises:
    var argv: List[String] = ["-I", "-o"]
    with assert_raises(contains="forbidden build argument '-o'"):
        _ = parse_args(argv)


def test_forbidden_emit_equals_form_in_include_value() raises:
    var argv: List[String] = ["-I", "--emit=llvm"]
    with assert_raises(contains="emit-type selection"):
        _ = parse_args(argv)


def test_bundled_short_flags_rejected() raises:
    var argv: List[String] = ["-xq"]
    with assert_raises(contains="cannot be bundled"):
        _ = parse_args(argv)


def test_bundled_short_flags_names_the_token() raises:
    var argv: List[String] = ["-xq"]
    with assert_raises(contains="'-xq'"):
        _ = parse_args(argv)


def test_quiet_and_verbose_mutually_exclusive() raises:
    var argv: List[String] = ["-q", "-v"]
    with assert_raises(contains="mutually exclusive"):
        _ = parse_args(argv)


def test_verbose_then_quiet_also_mutually_exclusive() raises:
    var argv: List[String] = ["-v", "-q"]
    with assert_raises(contains="mutually exclusive"):
        _ = parse_args(argv)


def test_flags_and_paths_interleave() raises:
    var argv: List[String] = ["tests/a.mojo", "-x", "tests/b.mojo"]
    var r = parse_args(argv)
    assert_equal(len(r.config.paths), 2)
    assert_equal(r.config.paths[0], "tests/a.mojo")
    assert_equal(r.config.paths[1], "tests/b.mojo")
    assert_true(r.config.exitfirst)


def test_equals_form_value_with_spaces_preserved() raises:
    var argv: List[String] = ["--exclude=a b c"]
    var r = parse_args(argv)
    assert_equal(len(r.config.excludes), 1)
    assert_equal(r.config.excludes[0], "a b c")


def test_duplicate_exitfirst_is_idempotent() raises:
    var argv: List[String] = ["-x", "-x"]
    assert_true(parse_args(argv).config.exitfirst)


def test_show_output_last_occurrence_wins() raises:
    var argv: List[String] = ["-s", "--show-output", "none"]
    var r = parse_args(argv)
    # -s means all; the later --show-output none overrides it.
    assert_true(r.config.show_output.value == 2)
