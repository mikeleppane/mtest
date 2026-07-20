"""Tests for collect-mode parsing: the `collect` subcommand and `--collect-only`.

Collect mode is set by the `collect` subcommand OR the `--collect-only` flag, and
the two are identical. Run-only flags served by this build (`-x`/`--exitfirst`,
`--maxfail`, `--durations`, `--gate`, `-s`/`--show-output`, `--retries`, and the
reporters `--json`/`--junit-xml`/`--gh-annotations`) combined with collect are a
usage error — the reporters and `--retries` on PROVISION, so even
`--gh-annotations off` is refused; `--timeout` is NOT refused — it bounds the
collection probes. Operands (paths, node ids) and `-k` remain allowed.
"""
from std.testing import assert_equal, assert_raises, assert_true

from mtest.cli import parse_args


def test_collect_subcommand_sets_collect_and_keeps_operands() raises:
    var argv: List[String] = ["collect", "tests/"]
    var r = parse_args(argv)
    assert_true(r.config.collect, "the collect subcommand sets collect mode")
    assert_equal(len(r.config.paths), 1)
    assert_equal(r.config.paths[0], "tests/")


def test_collect_only_flag_sets_collect() raises:
    var argv: List[String] = ["--collect-only"]
    var r = parse_args(argv)
    assert_true(r.config.collect, "--collect-only sets collect mode")


def test_collect_only_flag_with_paths() raises:
    var argv: List[String] = ["--collect-only", "tests/", "src/"]
    var r = parse_args(argv)
    assert_true(r.config.collect)
    assert_equal(len(r.config.paths), 2)


def test_plain_run_is_not_collect() raises:
    var argv: List[String] = ["tests/"]
    var r = parse_args(argv)
    assert_true(not r.config.collect, "a plain run is not collect mode")


def test_run_subcommand_is_not_collect() raises:
    var argv: List[String] = ["run", "tests/"]
    var r = parse_args(argv)
    assert_true(not r.config.collect)


def test_maxfail_with_collect_is_usage_error() raises:
    var argv: List[String] = ["collect", "--maxfail", "1"]
    with assert_raises(contains="--maxfail"):
        _ = parse_args(argv)
    var argv2: List[String] = ["collect", "--maxfail", "1"]
    with assert_raises(contains="run-only"):
        _ = parse_args(argv2)


def test_durations_with_collect_is_usage_error() raises:
    var argv: List[String] = ["collect", "--durations", "5"]
    with assert_raises(contains="--durations"):
        _ = parse_args(argv)
    var argv2: List[String] = ["collect", "--durations", "5"]
    with assert_raises(contains="run-only"):
        _ = parse_args(argv2)


def test_exitfirst_with_collect_is_usage_error() raises:
    var argv: List[String] = ["--collect-only", "-x"]
    with assert_raises(contains="run-only"):
        _ = parse_args(argv)


def test_gate_with_collect_is_usage_error() raises:
    var argv: List[String] = ["collect", "--gate", "foo.mojo"]
    with assert_raises(contains="--gate"):
        _ = parse_args(argv)
    var argv2: List[String] = ["collect", "--gate", "foo.mojo"]
    with assert_raises(contains="run-only"):
        _ = parse_args(argv2)


def test_show_output_short_with_collect_is_usage_error() raises:
    var argv: List[String] = ["collect", "-s"]
    with assert_raises(contains="run-only"):
        _ = parse_args(argv)


def test_show_output_long_with_collect_is_usage_error() raises:
    var argv: List[String] = ["collect", "--show-output", "all"]
    with assert_raises(contains="--show-output"):
        _ = parse_args(argv)
    var argv2: List[String] = ["collect", "--show-output", "all"]
    with assert_raises(contains="run-only"):
        _ = parse_args(argv2)


def test_retries_with_collect_is_usage_error() raises:
    var argv: List[String] = ["collect", "--retries", "1"]
    with assert_raises(contains="--retries"):
        _ = parse_args(argv)
    var argv2: List[String] = ["collect", "--retries", "1"]
    with assert_raises(contains="run-only"):
        _ = parse_args(argv2)


def test_json_with_collect_is_usage_error() raises:
    var argv: List[String] = ["collect", "--json", "out.ndjson"]
    with assert_raises(contains="--json"):
        _ = parse_args(argv)
    var argv2: List[String] = ["collect", "--json", "out.ndjson"]
    with assert_raises(contains="run-only"):
        _ = parse_args(argv2)


def test_junit_xml_with_collect_is_usage_error() raises:
    var argv: List[String] = ["collect", "--junit-xml", "r.xml"]
    with assert_raises(contains="--junit-xml"):
        _ = parse_args(argv)


def test_gh_annotations_with_collect_is_usage_error_even_off() raises:
    # Refused on PROVISION, not value: an explicit `off` is still a usage error
    # (a caller must not pass a run-only reporter flag to a listing at all).
    var argv: List[String] = ["collect", "--gh-annotations", "off"]
    with assert_raises(contains="--gh-annotations"):
        _ = parse_args(argv)
    var argv2: List[String] = ["collect", "--gh-annotations", "off"]
    with assert_raises(contains="run-only"):
        _ = parse_args(argv2)


def test_timeout_with_collect_is_allowed() raises:
    var argv: List[String] = ["collect", "--timeout", "5"]
    var r = parse_args(argv)
    assert_true(r.config.collect)
    assert_equal(r.config.timeout_secs, 5)


def test_keyword_with_collect_is_allowed() raises:
    var argv: List[String] = ["collect", "-k", "add"]
    var r = parse_args(argv)
    assert_true(r.config.collect)
    assert_equal(r.config.keyword, "add")
