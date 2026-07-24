"""Tests for the `config show` parser directive and pure TOML renderer."""
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from mtest.cli import ParseResult, parse_args
from mtest.config import (
    AnnotationsMode,
    CliOverlay,
    ColorWhen,
    ConfigEnvironment,
    FileConfig,
    OverrideRule,
    Precompile,
    ResolvedConfig,
    RunnerConfig,
    ShowOutput,
    Verbosity,
    render_config_show,
    resolve_config,
)


def _resolved_defaults() -> ResolvedConfig:
    return resolve_config(
        RunnerConfig.default(),
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )


def test_config_show_is_a_distinct_parse_result() raises:
    var argv: List[String] = ["config", "show"]
    var result = parse_args(argv)
    assert_true(result.is_config_show())
    assert_false(result.is_run())
    assert_equal(result.kind, ParseResult.CONFIG_SHOW)

    var missing: List[String] = ["config"]
    with assert_raises(contains="requires the two-token subcommand"):
        _ = parse_args(missing)
    var unknown: List[String] = ["config", "unknown"]
    with assert_raises(contains="requires the two-token subcommand"):
        _ = parse_args(unknown)


def test_config_show_accepts_the_full_run_grammar() raises:
    var argv: List[String] = [
        "config",
        "show",
        "tests/",
        "tests/test_math.mojo::test_add",
        "--lf",
        "-k",
        "add",
        "--timeout",
        "7",
        "--workers",
        "auto",
    ]
    var result = parse_args(argv)
    assert_true(result.is_config_show())
    assert_equal(result.config.paths[0], "tests/")
    assert_equal(result.config.paths[1], "tests/test_math.mojo::test_add")
    assert_true(result.config.last_failed)
    assert_equal(result.config.keyword, "add")
    assert_equal(result.config.timeout_secs, 7)
    assert_equal(result.config.workers, 0)
    var resolved = resolve_config(
        RunnerConfig.default(),
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        result.overlay,
    )
    var rendered = render_config_show(resolved, state_present=False)
    assert_true('paths = ["tests/"]  # (cli)' in rendered)
    assert_false("tests/test_math.mojo::test_add" in rendered)

    var node_only_argv: List[String] = [
        "config",
        "show",
        "tests/test_math.mojo::test_add",
    ]
    var node_only = parse_args(node_only_argv)
    var node_only_resolved = resolve_config(
        RunnerConfig.default(),
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        node_only.overlay,
    )
    assert_true(
        "paths = []  # (cli)"
        in render_config_show(node_only_resolved, state_present=False)
    )


def test_config_show_skips_report_destination_parent_checks() raises:
    var argv: List[String] = [
        "config",
        "show",
        "--json",
        "missing/events.ndjson",
        "--junit-xml",
        "missing/junit.xml",
    ]
    var result = parse_args(argv)
    assert_true(result.is_config_show())
    assert_equal(result.config.json_dest, "missing/events.ndjson")
    assert_equal(result.config.junit_dest, "missing/junit.xml")


def test_config_show_help_and_version_flags_keep_global_meaning() raises:
    var help_argv: List[String] = ["config", "show", "--help"]
    assert_true(parse_args(help_argv).is_help())
    var version_argv: List[String] = ["config", "show", "--version"]
    assert_true(parse_args(version_argv).is_version())


def test_config_show_defaults_render_every_key_in_fixed_order() raises:
    var resolved = _resolved_defaults()
    var rendered = render_config_show(resolved, state_present=False)
    assert_equal(
        rendered,
        (
            "[run]\n"
            "paths = []  # (default)\n"
            "exclude = []  # (default)\n"
            "gates = []  # (default)\n"
            "serial = []  # (default)\n"
            "workers = 1  # (default)\n"
            "timeout = 300  # (default)\n"
            "retries = 0  # (default)\n"
            "maxfail = 0  # (default)\n"
            "state = true  # (default)\n"
            "\n"
            "[build]\n"
            'mojo = "mojo"  # (default)\n'
            "include = []  # (default)\n"
            "build-args = []  # (default)\n"
            "precompile = []  # (default)\n"
            "compile-timeout = 600  # (default)\n"
            "\n"
            "[report]\n"
            'color = "auto"  # (default)\n'
            'show-output = "failures"  # (default)\n'
            'verbosity = "normal"  # (default)\n'
            "durations = 0  # (default)\n"
            "# junit-xml = (unset)\n"
            "# json = (unset)\n"
            'gh-annotations = "auto"  # (default)\n'
            "\n"
            "# config file: none\n"
            "# state file: .mtest-cache/lastrun (absent)\n"
            "# selection flags are per invocation and are not rendered\n"
        ),
    )


def test_config_show_renders_all_provenance_labels_and_no_color() raises:
    var file = FileConfig.empty()
    file.paths = ["from-file"]
    file.saw_paths = True
    file.color = ColorWhen.AUTO
    file.saw_color = True
    file.show_output = ShowOutput.ALL
    file.saw_show_output = True
    file.verbosity = Verbosity.VERBOSE
    file.saw_verbosity = True
    file.junit_dest = "file.xml"
    file.saw_junit_xml = True
    file.json_dest = "file.ndjson"
    file.saw_json = True
    file.gh_annotations = AnnotationsMode.OFF
    file.saw_gh_annotations = True
    var overlay = CliOverlay.default()
    overlay.timeout_secs = 9
    overlay.saw_timeout = True
    var resolved = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment(mtest_mojo="env-mojo", no_color=True),
        overlay,
    )
    resolved.config_file = "mtest.toml"
    var rendered = render_config_show(resolved, state_present=True)
    assert_true('paths = ["from-file"]  # (mtest.toml)' in rendered)
    assert_true("timeout = 9  # (cli)" in rendered)
    assert_true('mojo = "env-mojo"  # (env MTEST_MOJO)' in rendered)
    assert_true(
        'color = "auto"  # (mtest.toml; NO_COLOR active in this environment)'
        in rendered
    )
    assert_true('show-output = "all"  # (mtest.toml)' in rendered)
    assert_true('verbosity = "verbose"  # (mtest.toml)' in rendered)
    assert_true('junit-xml = "file.xml"  # (mtest.toml)' in rendered)
    assert_true('json = "file.ndjson"  # (mtest.toml)' in rendered)
    assert_true('gh-annotations = "off"  # (mtest.toml)' in rendered)
    assert_true("workers = 1  # (default)" in rendered)
    assert_true("# config file: mtest.toml" in rendered)
    assert_true("# state file: .mtest-cache/lastrun (present)" in rendered)


def test_config_show_no_color_qualifier_only_applies_to_auto() raises:
    var file = FileConfig.empty()
    file.color = ColorWhen.ALWAYS
    file.saw_color = True
    var resolved = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment(mtest_mojo="", no_color=True),
        CliOverlay.default(),
    )
    var rendered = render_config_show(resolved, state_present=False)
    assert_true('color = "always"  # (mtest.toml)' in rendered)
    assert_false("NO_COLOR" in rendered)


def test_config_show_escapes_strings_and_renders_precompile_canonically() raises:
    var overlay = CliOverlay.default()
    overlay.paths = ['quote"slash\\line\n']
    overlay.saw_paths = True
    overlay.workers = 0
    overlay.saw_workers = True
    overlay.precompiles = [
        Precompile(src="src\\a", out=Optional[String](None)),
        Precompile(src='src"b', out=Optional[String]("out\npkg")),
    ]
    overlay.saw_precompile = True
    var resolved = resolve_config(
        RunnerConfig.default(),
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        overlay,
    )
    var rendered = render_config_show(resolved, state_present=False)
    assert_true('paths = ["quote\\"slash\\\\line\\n"]  # (cli)' in rendered)
    assert_true('workers = "auto"  # (cli)' in rendered)
    assert_true(
        'precompile = ["src\\\\a", "src\\"b:out\\npkg"]  # (cli)' in rendered
    )


def test_config_show_keeps_ordered_overrides_and_present_keys_only() raises:
    var first = OverrideRule.empty()
    first.files = ["tests/gpu_*"]
    first.timeout_secs = 3
    first.saw_timeout = True
    first.serial = False
    first.saw_serial = True
    var second = OverrideRule.empty()
    second.files = ["tests/a.mojo", "tests/b.mojo"]
    second.compile_timeout_secs = 4
    second.saw_compile_timeout = True
    second.retries = 2
    second.saw_retries = True
    var file = FileConfig.empty()
    file.overrides = [first^, second^]
    var resolved = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    var rendered = render_config_show(resolved, state_present=False)
    var expected = (
        '[[override]]\nfiles = "tests/gpu_*"  # (mtest.toml)\n'
        "timeout = 3  # (mtest.toml)\n"
        "serial = false  # (mtest.toml)\n"
        "\n"
        "[[override]]\n"
        'files = ["tests/a.mojo", "tests/b.mojo"]  # (mtest.toml)\n'
        "compile-timeout = 4  # (mtest.toml)\n"
        "retries = 2  # (mtest.toml)\n"
    )
    assert_true(expected in rendered)
