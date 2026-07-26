"""Focused tests for argv parsing into the typed configuration overlay.

The overlay records both each CLI-provided config value and whether argv
provided it. `ParseResult.config` remains the defaults-folded compatibility
view consumed by existing callers.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.cli import parse_args
from mtest.config import CliOverlay, ColorWhen, ShowOutput, Verbosity


def _assert_no_presence(overlay: CliOverlay) raises:
    assert_false(overlay.saw_paths)
    assert_false(overlay.saw_excludes)
    assert_false(overlay.saw_gates)
    assert_false(overlay.saw_serial)
    assert_false(overlay.saw_workers)
    assert_false(overlay.saw_timeout)
    assert_false(overlay.saw_retries)
    assert_false(overlay.saw_maxfail)
    assert_false(overlay.saw_state)
    assert_false(overlay.saw_mojo)
    assert_false(overlay.saw_include)
    assert_false(overlay.saw_build_args)
    assert_false(overlay.saw_precompile)
    assert_false(overlay.saw_compile_timeout)
    assert_false(overlay.saw_color)
    assert_false(overlay.saw_show_output)
    assert_false(overlay.saw_verbosity)
    assert_false(overlay.saw_durations)
    assert_false(overlay.saw_junit_xml)
    assert_false(overlay.saw_json)
    assert_false(overlay.saw_gh_annotations)


def test_absent_argv_has_no_config_presence() raises:
    var result = parse_args([])
    _assert_no_presence(result.overlay)
    assert_true(result.overlay.state)
    assert_equal(result.config.timeout_secs, 300)
    assert_equal(result.config.compile_timeout_secs, 600)


def test_every_cli_expressible_config_knob_is_present() raises:
    var argv: List[String] = [
        "tests/test_a.mojo",
        "--exclude",
        "build/*",
        "--gate",
        "tests/smoke.mojo",
        "--serial",
        "tests/gpu_*",
        "-n",
        "2",
        "--timeout",
        "10",
        "--retries",
        "1",
        "--maxfail",
        "3",
        "--mojo",
        "/opt/mojo",
        "-I",
        "vendor",
        "--build-arg",
        "-DDEBUG",
        "--precompile",
        "src/lib:build/lib.mojopkg",
        "--compile-timeout",
        "20",
        "--color",
        "never",
        "--show-output",
        "all",
        "-v",
        "--durations",
        "5",
        "--junit-xml",
        "tests/report.xml",
        "--json",
        "tests/events.ndjson",
        "--gh-annotations",
        "off",
    ]
    var result = parse_args(argv)
    var overlay = result.overlay.copy()

    assert_true(overlay.saw_paths)
    assert_true(overlay.saw_excludes)
    assert_true(overlay.saw_gates)
    assert_true(overlay.saw_serial)
    assert_true(overlay.saw_workers)
    assert_true(overlay.saw_timeout)
    assert_true(overlay.saw_retries)
    assert_true(overlay.saw_maxfail)
    assert_false(overlay.saw_state)
    assert_true(overlay.saw_mojo)
    assert_true(overlay.saw_include)
    assert_true(overlay.saw_build_args)
    assert_true(overlay.saw_precompile)
    assert_true(overlay.saw_compile_timeout)
    assert_true(overlay.saw_color)
    assert_true(overlay.saw_show_output)
    assert_true(overlay.saw_verbosity)
    assert_true(overlay.saw_durations)
    assert_true(overlay.saw_junit_xml)
    assert_true(overlay.saw_json)
    assert_true(overlay.saw_gh_annotations)

    assert_equal(overlay.paths[0], "tests/test_a.mojo")
    assert_equal(overlay.excludes[0], "build/*")
    assert_equal(overlay.timeout_secs, 10)
    assert_equal(overlay.mojo_path, "/opt/mojo")
    assert_equal(overlay.junit_dest, "tests/report.xml")
    assert_true(overlay.verbosity == Verbosity.VERBOSE)


def test_explicit_default_is_distinct_from_absence() raises:
    var absent = parse_args([])
    var explicit = parse_args(["--timeout", "300"])

    assert_false(absent.overlay.saw_timeout)
    assert_true(explicit.overlay.saw_timeout)
    assert_equal(absent.overlay.timeout_secs, 300)
    assert_equal(explicit.overlay.timeout_secs, 300)
    assert_equal(absent.config.timeout_secs, 300)
    assert_equal(explicit.config.timeout_secs, 300)


def test_non_config_flags_do_not_masquerade_as_presence() raises:
    var result = parse_args(["-x", "-k", "test_add", "--shard", "slice:1/2"])
    _assert_no_presence(result.overlay)
    assert_true(result.config.exitfirst)
    assert_equal(result.config.keyword, "test_add")
    assert_equal(result.config.shard_m, 1)
    assert_equal(result.config.shard_n, 2)


def test_positional_path_and_verbosity_have_typed_values() raises:
    var result = parse_args(["tests/", "-q"])
    assert_true(result.overlay.saw_paths)
    assert_true(result.overlay.saw_verbosity)
    assert_equal(result.overlay.paths[0], "tests/")
    assert_true(result.overlay.verbosity == Verbosity.QUIET)
    assert_equal(result.config.paths[0], "tests/")
    assert_true(result.config.verbosity == Verbosity.QUIET)


def test_defaults_folded_config_preserves_overlay_values() raises:
    var result = parse_args(
        [
            "--timeout",
            "7",
            "--show-output",
            "none",
            "--color",
            "always",
            "--gh-annotations",
            "off",
        ]
    )
    assert_equal(result.config.timeout_secs, 7)
    assert_true(result.config.show_output == ShowOutput.NONE)
    assert_true(result.config.color == ColorWhen.ALWAYS)
    assert_equal(result.config.gh_annotations.value, 0)
