"""Arity-1 parameterized tests: every value-taking spelling gets a
missing-value case, an `=`-form case, and — where the value is validated — a
bad-value case.

The available arity-1 spellings are enumerated, not sampled: `--exclude`, `-I`,
`--build-arg`, `--precompile`, `--mojo`, `--timeout`, `--show-output`,
`--color`, `--gate`, `--maxfail`, `--durations`. Each proves that omitting the
value is a located usage error and that the `--flag=value` spelling lands the
same value as `--flag value`.
"""
from std.testing import assert_equal, assert_raises, assert_true

from mtest.cli import parse_args
from mtest.config import ColorWhen, ShowOutput


# --- missing-value cases (flag is the final token) ---


def test_exclude_missing_value() raises:
    var argv: List[String] = ["--exclude"]
    with assert_raises(contains="'--exclude' requires a value"):
        _ = parse_args(argv)


def test_include_missing_value() raises:
    var argv: List[String] = ["-I"]
    with assert_raises(contains="'-I' requires a value"):
        _ = parse_args(argv)


def test_build_arg_missing_value() raises:
    var argv: List[String] = ["--build-arg"]
    with assert_raises(contains="'--build-arg' requires a value"):
        _ = parse_args(argv)


def test_precompile_missing_value() raises:
    var argv: List[String] = ["--precompile"]
    with assert_raises(contains="'--precompile' requires a value"):
        _ = parse_args(argv)


def test_mojo_missing_value() raises:
    var argv: List[String] = ["--mojo"]
    with assert_raises(contains="'--mojo' requires a value"):
        _ = parse_args(argv)


def test_timeout_missing_value() raises:
    var argv: List[String] = ["--timeout"]
    with assert_raises(contains="'--timeout' requires a value"):
        _ = parse_args(argv)


def test_show_output_missing_value() raises:
    var argv: List[String] = ["--show-output"]
    with assert_raises(contains="'--show-output' requires a value"):
        _ = parse_args(argv)


def test_color_missing_value() raises:
    var argv: List[String] = ["--color"]
    with assert_raises(contains="'--color' requires a value"):
        _ = parse_args(argv)


def test_gate_missing_value() raises:
    var argv: List[String] = ["--gate"]
    with assert_raises(contains="'--gate' requires a value"):
        _ = parse_args(argv)


def test_maxfail_missing_value() raises:
    var argv: List[String] = ["--maxfail"]
    with assert_raises(contains="'--maxfail' requires a value"):
        _ = parse_args(argv)


def test_durations_missing_value() raises:
    var argv: List[String] = ["--durations"]
    with assert_raises(contains="'--durations' requires a value"):
        _ = parse_args(argv)


# --- equals-form cases ---


def test_exclude_equals_form() raises:
    var argv: List[String] = ["--exclude=pat"]
    assert_equal(parse_args(argv).config.excludes[0], "pat")


def test_include_equals_form() raises:
    var argv: List[String] = ["-I=build"]
    assert_equal(parse_args(argv).config.include_paths[0], "build")


def test_build_arg_equals_form() raises:
    var argv: List[String] = ["--build-arg=--no-optimization"]
    assert_equal(parse_args(argv).config.build_args[0], "--no-optimization")


def test_precompile_equals_form() raises:
    var argv: List[String] = ["--precompile=src:out.mojopkg"]
    var r = parse_args(argv)
    assert_equal(r.config.precompiles[0].src, "src")
    assert_equal(r.config.precompiles[0].out.value(), "out.mojopkg")


def test_mojo_equals_form() raises:
    var argv: List[String] = ["--mojo=/bin/mojo"]
    assert_equal(parse_args(argv).config.mojo_path, "/bin/mojo")


def test_timeout_equals_form() raises:
    var argv: List[String] = ["--timeout=90"]
    assert_equal(parse_args(argv).config.timeout_secs, 90)


def test_show_output_equals_form() raises:
    var argv: List[String] = ["--show-output=none"]
    assert_true(parse_args(argv).config.show_output == ShowOutput.NONE)


def test_color_equals_form() raises:
    var argv: List[String] = ["--color=always"]
    assert_true(parse_args(argv).config.color == ColorWhen.ALWAYS)


def test_gate_equals_form() raises:
    var argv: List[String] = ["--gate=smoke"]
    assert_equal(parse_args(argv).config.gates[0], "smoke")


def test_maxfail_equals_form() raises:
    var argv: List[String] = ["--maxfail=2"]
    assert_equal(parse_args(argv).config.maxfail, 2)


def test_durations_equals_form() raises:
    var argv: List[String] = ["--durations=5"]
    assert_equal(parse_args(argv).config.durations, 5)


def test_maxfail_space_form() raises:
    var argv: List[String] = ["--maxfail", "2"]
    assert_equal(parse_args(argv).config.maxfail, 2)


def test_maxfail_zero_means_no_limit() raises:
    var argv: List[String] = ["--maxfail", "0"]
    assert_equal(parse_args(argv).config.maxfail, 0)


def test_maxfail_defaults_to_zero() raises:
    var argv: List[String] = []
    assert_equal(parse_args(argv).config.maxfail, 0)


def test_durations_space_form() raises:
    var argv: List[String] = ["--durations", "5"]
    assert_equal(parse_args(argv).config.durations, 5)


def test_durations_zero_means_disabled() raises:
    var argv: List[String] = ["--durations", "0"]
    assert_equal(parse_args(argv).config.durations, 0)


def test_durations_defaults_to_zero() raises:
    var argv: List[String] = []
    assert_equal(parse_args(argv).config.durations, 0)


def test_gate_accumulates_and_preserves_spaces() raises:
    var argv: List[String] = [
        "--gate",
        "tests/test_smoke_*.mojo",
        "--gate",
        "a b c",
    ]
    var r = parse_args(argv)
    assert_equal(len(r.config.gates), 2)
    assert_equal(r.config.gates[0], "tests/test_smoke_*.mojo")
    assert_equal(r.config.gates[1], "a b c")


# --- bad-value cases (validated values only) ---


def test_timeout_rejects_non_integer() raises:
    var argv: List[String] = ["--timeout", "soon"]
    with assert_raises(contains="wants an integer"):
        _ = parse_args(argv)


def test_timeout_rejects_negative() raises:
    var argv: List[String] = ["--timeout", "-5"]
    with assert_raises(contains="wants an integer"):
        _ = parse_args(argv)


def test_maxfail_rejects_non_integer() raises:
    var argv: List[String] = ["--maxfail", "abc"]
    with assert_raises(contains="wants an integer"):
        _ = parse_args(argv)


def test_maxfail_rejects_negative() raises:
    var argv: List[String] = ["--maxfail", "-1"]
    with assert_raises(contains="wants an integer"):
        _ = parse_args(argv)


def test_durations_rejects_non_integer() raises:
    var argv: List[String] = ["--durations", "abc"]
    with assert_raises(contains="wants an integer"):
        _ = parse_args(argv)


def test_durations_rejects_negative() raises:
    var argv: List[String] = ["--durations", "-1"]
    with assert_raises(contains="wants an integer"):
        _ = parse_args(argv)


def test_show_output_rejects_unknown_mode() raises:
    var argv: List[String] = ["--show-output", "loud"]
    with assert_raises(contains="one of failures|all|none"):
        _ = parse_args(argv)


def test_color_rejects_unknown_mode() raises:
    var argv: List[String] = ["--color", "rainbow"]
    with assert_raises(contains="one of auto|always|never"):
        _ = parse_args(argv)


def test_precompile_rejects_empty_source() raises:
    var argv: List[String] = ["--precompile", ":out"]
    with assert_raises(contains="wants SRC[:OUT]"):
        _ = parse_args(argv)


def test_precompile_rejects_empty_value() raises:
    var argv: List[String] = ["--precompile="]
    with assert_raises(contains="wants SRC[:OUT]"):
        _ = parse_args(argv)


def test_precompile_rejects_trailing_colon() raises:
    var argv: List[String] = ["--precompile", "src:"]
    with assert_raises(contains="wants SRC[:OUT]"):
        _ = parse_args(argv)
