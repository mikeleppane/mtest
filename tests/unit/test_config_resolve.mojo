"""Precedence-matrix tests for Layer 1 configuration resolution.

The resolver replaces whole values across defaults, file, environment, and
argv layers while recording an independent source for every eligible key.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.config import (
    ActiveConfigKeys,
    AnnotationsMode,
    CliOverlay,
    ColorWhen,
    ConfigEnvironment,
    ConfigProvenance,
    FileConfig,
    OverrideRule,
    Precompile,
    Provenance,
    RunnerConfig,
    ShardMode,
    ShowOutput,
    Verbosity,
    resolve_config,
    validate_resolved_config,
)


def _precompile(var src: String, var output_name: String) -> Precompile:
    return Precompile(src=src^, out=Optional[String](output_name^))


def _assert_string_list(actual: List[String], expected: List[String]) raises:
    assert_equal(len(actual), len(expected))
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i])


def _assert_all_sources(sources: ConfigProvenance, expected: Provenance) raises:
    assert_true(sources.paths == expected)
    assert_true(sources.excludes == expected)
    assert_true(sources.gates == expected)
    assert_true(sources.serial_globs == expected)
    assert_true(sources.workers == expected)
    assert_true(sources.timeout_secs == expected)
    assert_true(sources.retries == expected)
    assert_true(sources.maxfail == expected)
    assert_true(sources.state == expected)
    assert_true(sources.mojo_path == expected)
    assert_true(sources.include_paths == expected)
    assert_true(sources.build_args == expected)
    assert_true(sources.precompiles == expected)
    assert_true(sources.compile_timeout_secs == expected)
    assert_true(sources.color == expected)
    assert_true(sources.show_output == expected)
    assert_true(sources.verbosity == expected)
    assert_true(sources.durations == expected)
    assert_true(sources.junit_dest == expected)
    assert_true(sources.json_dest == expected)
    assert_true(sources.gh_annotations == expected)


def _assert_all_active(keys: ActiveConfigKeys) raises:
    assert_true(keys.paths)
    assert_true(keys.excludes)
    assert_true(keys.gates)
    assert_true(keys.serial_globs)
    assert_true(keys.workers)
    assert_true(keys.timeout_secs)
    assert_true(keys.retries)
    assert_true(keys.maxfail)
    assert_true(keys.state)
    assert_true(keys.mojo_path)
    assert_true(keys.include_paths)
    assert_true(keys.build_args)
    assert_true(keys.precompiles)
    assert_true(keys.compile_timeout_secs)
    assert_true(keys.color)
    assert_true(keys.show_output)
    assert_true(keys.verbosity)
    assert_true(keys.durations)
    assert_true(keys.junit_dest)
    assert_true(keys.json_dest)
    assert_true(keys.gh_annotations)


def _custom_defaults() -> RunnerConfig:
    var defaults = RunnerConfig.default()
    defaults.paths = ["default-path"]
    defaults.excludes = ["default-exclude"]
    defaults.gates = ["default-gate"]
    defaults.serial_globs = ["default-serial"]
    defaults.workers = 8
    defaults.timeout_secs = 31
    defaults.retries = 1
    defaults.maxfail = 2
    defaults.mojo_path = "default-mojo"
    defaults.include_paths = ["default-include"]
    defaults.build_args = ["default-build"]
    defaults.precompiles = [_precompile("default-src", "default-out")]
    defaults.compile_timeout_secs = 61
    defaults.color = ColorWhen.NEVER
    defaults.show_output = ShowOutput.NONE
    defaults.verbosity = Verbosity.QUIET
    defaults.durations = 3
    defaults.junit_dest = String("")
    defaults.json_dest = String("")
    defaults.gh_annotations = AnnotationsMode.OFF
    return defaults^


def _set_every_file_value(mut file: FileConfig):
    file.paths = ["file-path"]
    file.saw_paths = True
    file.excludes = ["file-exclude"]
    file.saw_excludes = True
    file.gates = ["file-gate"]
    file.saw_gates = True
    file.serial_globs = ["file-serial"]
    file.saw_serial = True
    file.workers = 3
    file.saw_workers = True
    file.timeout_secs = 41
    file.saw_timeout = True
    file.retries = 4
    file.saw_retries = True
    file.maxfail = 5
    file.saw_maxfail = True
    file.state = False
    file.saw_state = True
    file.mojo_path = "file-mojo"
    file.saw_mojo = True
    file.include_paths = ["file-include"]
    file.saw_include = True
    file.build_args = ["file-build"]
    file.saw_build_args = True
    file.precompiles = [_precompile("file-src", "file-out")]
    file.saw_precompile = True
    file.compile_timeout_secs = 71
    file.saw_compile_timeout = True
    file.color = ColorWhen.AUTO
    file.saw_color = True
    file.show_output = ShowOutput.ALL
    file.saw_show_output = True
    file.verbosity = Verbosity.NORMAL
    file.saw_verbosity = True
    file.durations = 6
    file.saw_durations = True
    file.junit_dest = "file.xml"
    file.saw_junit_xml = True
    file.json_dest = "file.ndjson"
    file.saw_json = True
    file.gh_annotations = AnnotationsMode.AUTO
    file.saw_gh_annotations = True


def _set_every_cli_value(mut overlay: CliOverlay):
    overlay.paths = ["cli-path-a", "cli-path-b"]
    overlay.saw_paths = True
    overlay.excludes = ["cli-exclude-a", "cli-exclude-b"]
    overlay.saw_excludes = True
    overlay.gates = ["cli-gate-a", "cli-gate-b"]
    overlay.saw_gates = True
    overlay.serial_globs = ["cli-serial-a", "cli-serial-b"]
    overlay.saw_serial = True
    overlay.workers = 4
    overlay.saw_workers = True
    overlay.timeout_secs = 42
    overlay.saw_timeout = True
    overlay.retries = 7
    overlay.saw_retries = True
    overlay.maxfail = 8
    overlay.saw_maxfail = True
    overlay.state = True
    overlay.saw_state = True
    overlay.mojo_path = "cli-mojo"
    overlay.saw_mojo = True
    overlay.include_paths = ["cli-include-a", "cli-include-b"]
    overlay.saw_include = True
    overlay.build_args = ["cli-build-a", "cli-build-b"]
    overlay.saw_build_args = True
    overlay.precompiles = [
        _precompile("cli-src-a", "cli-out-a"),
        _precompile("cli-src-b", "cli-out-b"),
    ]
    overlay.saw_precompile = True
    overlay.compile_timeout_secs = 72
    overlay.saw_compile_timeout = True
    overlay.color = ColorWhen.ALWAYS
    overlay.saw_color = True
    overlay.show_output = ShowOutput.NONE
    overlay.saw_show_output = True
    overlay.verbosity = Verbosity.VERBOSE
    overlay.saw_verbosity = True
    overlay.durations = 9
    overlay.saw_durations = True
    overlay.junit_dest = "cli.xml"
    overlay.saw_junit_xml = True
    overlay.json_dest = "cli.ndjson"
    overlay.saw_json = True
    overlay.gh_annotations = AnnotationsMode.OFF
    overlay.saw_gh_annotations = True


def test_defaults_only_resolve_every_key_with_default_provenance() raises:
    var defaults = _custom_defaults()
    var resolved = resolve_config(
        defaults,
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    var config = resolved.config.copy()

    _assert_string_list(config.paths, ["default-path"])
    _assert_string_list(config.excludes, ["default-exclude"])
    _assert_string_list(config.gates, ["default-gate"])
    _assert_string_list(config.serial_globs, ["default-serial"])
    assert_equal(config.workers, 8)
    assert_equal(config.timeout_secs, 31)
    assert_equal(config.retries, 1)
    assert_equal(config.maxfail, 2)
    assert_true(resolved.state)
    assert_equal(config.mojo_path, "default-mojo")
    _assert_string_list(config.include_paths, ["default-include"])
    _assert_string_list(config.build_args, ["default-build"])
    assert_equal(len(config.precompiles), 1)
    assert_equal(config.precompiles[0].src, "default-src")
    assert_equal(config.compile_timeout_secs, 61)
    assert_true(config.color == ColorWhen.NEVER)
    assert_true(config.show_output == ShowOutput.NONE)
    assert_true(config.verbosity == Verbosity.QUIET)
    assert_equal(config.durations, 3)
    assert_equal(config.junit_dest, "")
    assert_equal(config.json_dest, "")
    assert_true(config.gh_annotations == AnnotationsMode.OFF)
    assert_equal(len(resolved.overrides), 0)
    assert_false(resolved.no_color)
    _assert_all_sources(resolved.provenance, Provenance.DEFAULT)
    _assert_all_active(resolved.active_keys)


def test_file_values_replace_defaults_for_every_key() raises:
    var file = FileConfig.empty()
    _set_every_file_value(file)
    var resolved = resolve_config(
        _custom_defaults(),
        file,
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    var config = resolved.config.copy()

    _assert_string_list(config.paths, ["file-path"])
    _assert_string_list(config.excludes, ["file-exclude"])
    _assert_string_list(config.gates, ["file-gate"])
    _assert_string_list(config.serial_globs, ["file-serial"])
    assert_equal(config.workers, 3)
    assert_equal(config.timeout_secs, 41)
    assert_equal(config.retries, 4)
    assert_equal(config.maxfail, 5)
    assert_false(resolved.state)
    assert_equal(config.mojo_path, "file-mojo")
    _assert_string_list(config.include_paths, ["file-include"])
    _assert_string_list(config.build_args, ["file-build"])
    assert_equal(len(config.precompiles), 1)
    assert_equal(config.precompiles[0].src, "file-src")
    assert_equal(config.compile_timeout_secs, 71)
    assert_true(config.color == ColorWhen.AUTO)
    assert_true(config.show_output == ShowOutput.ALL)
    assert_true(config.verbosity == Verbosity.NORMAL)
    assert_equal(config.durations, 6)
    assert_equal(config.junit_dest, "file.xml")
    assert_equal(config.json_dest, "file.ndjson")
    assert_true(config.gh_annotations == AnnotationsMode.AUTO)
    _assert_all_sources(resolved.provenance, Provenance.MTEST_TOML)


def test_accumulated_cli_values_replace_file_values_for_every_key() raises:
    var file = FileConfig.empty()
    _set_every_file_value(file)
    var overlay = CliOverlay.default()
    _set_every_cli_value(overlay)
    var resolved = resolve_config(
        _custom_defaults(),
        file,
        ConfigEnvironment(mtest_mojo="env-mojo", no_color=False),
        overlay,
    )
    var config = resolved.config.copy()

    _assert_string_list(config.paths, ["cli-path-a", "cli-path-b"])
    _assert_string_list(config.excludes, ["cli-exclude-a", "cli-exclude-b"])
    _assert_string_list(config.gates, ["cli-gate-a", "cli-gate-b"])
    _assert_string_list(config.serial_globs, ["cli-serial-a", "cli-serial-b"])
    assert_equal(config.workers, 4)
    assert_equal(config.timeout_secs, 42)
    assert_equal(config.retries, 7)
    assert_equal(config.maxfail, 8)
    assert_true(resolved.state)
    assert_equal(config.mojo_path, "cli-mojo")
    _assert_string_list(
        config.include_paths, ["cli-include-a", "cli-include-b"]
    )
    _assert_string_list(config.build_args, ["cli-build-a", "cli-build-b"])
    assert_equal(len(config.precompiles), 2)
    assert_equal(config.precompiles[0].src, "cli-src-a")
    assert_equal(config.precompiles[1].src, "cli-src-b")
    assert_equal(config.compile_timeout_secs, 72)
    assert_true(config.color == ColorWhen.ALWAYS)
    assert_true(config.show_output == ShowOutput.NONE)
    assert_true(config.verbosity == Verbosity.VERBOSE)
    assert_equal(config.durations, 9)
    assert_equal(config.junit_dest, "cli.xml")
    assert_equal(config.json_dest, "cli.ndjson")
    assert_true(config.gh_annotations == AnnotationsMode.OFF)
    _assert_all_sources(resolved.provenance, Provenance.CLI)


def test_environment_mojo_beats_file_and_empty_environment_is_absent() raises:
    var file = FileConfig.empty()
    file.mojo_path = "file-mojo"
    file.saw_mojo = True

    var from_env = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment(mtest_mojo="env-mojo", no_color=False),
        CliOverlay.default(),
    )
    assert_equal(from_env.config.mojo_path, "env-mojo")
    assert_true(from_env.provenance.mojo_path == Provenance.ENV_MTEST_MOJO)

    var from_file = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment(mtest_mojo="", no_color=False),
        CliOverlay.default(),
    )
    assert_equal(from_file.config.mojo_path, "file-mojo")
    assert_true(from_file.provenance.mojo_path == Provenance.MTEST_TOML)


def test_all_layers_conflict_with_scalar_and_whole_list_replacement() raises:
    var defaults = RunnerConfig.default()
    defaults.mojo_path = "default-mojo"
    defaults.paths = ["default-path"]
    var file = FileConfig.empty()
    file.mojo_path = "file-mojo"
    file.saw_mojo = True
    file.paths = ["file-path"]
    file.saw_paths = True
    var overlay = CliOverlay.default()
    overlay.mojo_path = "cli-mojo"
    overlay.saw_mojo = True
    overlay.paths = ["cli-path-a", "cli-path-b"]
    overlay.saw_paths = True

    var resolved = resolve_config(
        defaults,
        file,
        ConfigEnvironment(mtest_mojo="env-mojo", no_color=False),
        overlay,
    )
    assert_equal(resolved.config.mojo_path, "cli-mojo")
    _assert_string_list(resolved.config.paths, ["cli-path-a", "cli-path-b"])
    assert_true(resolved.provenance.mojo_path == Provenance.CLI)
    assert_true(resolved.provenance.paths == Provenance.CLI)


def test_explicit_empty_file_lists_replace_nonempty_defaults() raises:
    var defaults = _custom_defaults()
    var file = FileConfig.empty()
    file.saw_paths = True
    file.saw_excludes = True
    file.saw_gates = True
    file.saw_serial = True
    file.saw_include = True
    file.saw_build_args = True
    file.saw_precompile = True

    var resolved = resolve_config(
        defaults,
        file,
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    assert_equal(len(resolved.config.paths), 0)
    assert_equal(len(resolved.config.excludes), 0)
    assert_equal(len(resolved.config.gates), 0)
    assert_equal(len(resolved.config.serial_globs), 0)
    assert_equal(len(resolved.config.include_paths), 0)
    assert_equal(len(resolved.config.build_args), 0)
    assert_equal(len(resolved.config.precompiles), 0)
    assert_true(resolved.provenance.paths == Provenance.MTEST_TOML)
    assert_true(resolved.provenance.excludes == Provenance.MTEST_TOML)
    assert_true(resolved.provenance.gates == Provenance.MTEST_TOML)
    assert_true(resolved.provenance.serial_globs == Provenance.MTEST_TOML)
    assert_true(resolved.provenance.include_paths == Provenance.MTEST_TOML)
    assert_true(resolved.provenance.build_args == Provenance.MTEST_TOML)
    assert_true(resolved.provenance.precompiles == Provenance.MTEST_TOML)


def test_explicit_default_values_keep_supplier_provenance() raises:
    var file = FileConfig.empty()
    file.color = ColorWhen.AUTO
    file.saw_color = True
    file.state = True
    file.saw_state = True
    var overlay = CliOverlay.default()
    overlay.timeout_secs = 300
    overlay.saw_timeout = True
    overlay.compile_timeout_secs = 600
    overlay.saw_compile_timeout = True

    var resolved = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment.empty(),
        overlay,
    )
    assert_equal(resolved.config.timeout_secs, 300)
    assert_equal(resolved.config.compile_timeout_secs, 600)
    assert_true(resolved.config.color == ColorWhen.AUTO)
    assert_true(resolved.state)
    assert_true(resolved.provenance.timeout_secs == Provenance.CLI)
    assert_true(resolved.provenance.compile_timeout_secs == Provenance.CLI)
    assert_true(resolved.provenance.color == Provenance.MTEST_TOML)
    assert_true(resolved.provenance.state == Provenance.MTEST_TOML)


def test_color_value_source_and_no_color_are_independent() raises:
    var auto = resolve_config(
        RunnerConfig.default(),
        FileConfig.empty(),
        ConfigEnvironment(mtest_mojo="", no_color=True),
        CliOverlay.default(),
    )
    assert_true(auto.config.color == ColorWhen.AUTO)
    assert_true(auto.provenance.color == Provenance.DEFAULT)
    assert_true(auto.no_color)

    var file = FileConfig.empty()
    file.color = ColorWhen.ALWAYS
    file.saw_color = True
    var always = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment(mtest_mojo="", no_color=True),
        CliOverlay.default(),
    )
    assert_true(always.config.color == ColorWhen.ALWAYS)
    assert_true(always.provenance.color == Provenance.MTEST_TOML)
    assert_true(always.no_color)

    var overlay = CliOverlay.default()
    overlay.color = ColorWhen.NEVER
    overlay.saw_color = True
    var never = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment(mtest_mojo="", no_color=True),
        overlay,
    )
    assert_true(never.config.color == ColorWhen.NEVER)
    assert_true(never.provenance.color == Provenance.CLI)
    assert_true(never.no_color)


def test_state_and_ordered_overrides_are_carried_unchanged() raises:
    var first = OverrideRule.empty()
    first.files = ["tests/first_b*", "tests/first_a*"]
    first.timeout_secs = 11
    first.saw_timeout = True
    first.compile_timeout_secs = 21
    first.saw_compile_timeout = False
    first.retries = 31
    first.saw_retries = True
    first.serial = False
    first.saw_serial = False
    var second = OverrideRule.empty()
    second.files = ["tests/second_c*", "tests/second_a*", "tests/second_b*"]
    second.timeout_secs = 12
    second.saw_timeout = False
    second.compile_timeout_secs = 22
    second.saw_compile_timeout = True
    second.retries = 32
    second.saw_retries = False
    second.serial = True
    second.saw_serial = True
    var file = FileConfig.empty()
    file.state = False
    file.saw_state = True
    file.overrides = [first^, second^]

    var resolved = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    assert_false(resolved.state)
    assert_true(resolved.provenance.state == Provenance.MTEST_TOML)
    assert_equal(len(resolved.overrides), 2)
    assert_equal(len(resolved.overrides[0].files), 2)
    assert_equal(resolved.overrides[0].files[0], "tests/first_b*")
    assert_equal(resolved.overrides[0].files[1], "tests/first_a*")
    assert_equal(resolved.overrides[0].timeout_secs, 11)
    assert_true(resolved.overrides[0].saw_timeout)
    assert_equal(resolved.overrides[0].compile_timeout_secs, 21)
    assert_false(resolved.overrides[0].saw_compile_timeout)
    assert_equal(resolved.overrides[0].retries, 31)
    assert_true(resolved.overrides[0].saw_retries)
    assert_false(resolved.overrides[0].serial)
    assert_false(resolved.overrides[0].saw_serial)
    assert_equal(len(resolved.overrides[1].files), 3)
    assert_equal(resolved.overrides[1].files[0], "tests/second_c*")
    assert_equal(resolved.overrides[1].files[1], "tests/second_a*")
    assert_equal(resolved.overrides[1].files[2], "tests/second_b*")
    assert_equal(resolved.overrides[1].timeout_secs, 12)
    assert_false(resolved.overrides[1].saw_timeout)
    assert_equal(resolved.overrides[1].compile_timeout_secs, 22)
    assert_true(resolved.overrides[1].saw_compile_timeout)
    assert_equal(resolved.overrides[1].retries, 32)
    assert_false(resolved.overrides[1].saw_retries)
    assert_true(resolved.overrides[1].serial)
    assert_true(resolved.overrides[1].saw_serial)


def test_non_config_invocation_fields_survive_resolution() raises:
    var defaults = RunnerConfig.default()
    defaults.exitfirst = True
    defaults.keyword = "selected"
    defaults.shard_mode = ShardMode.SLICE
    defaults.shard_m = 2
    defaults.shard_n = 3
    var file = FileConfig.empty()
    _set_every_file_value(file)
    var overlay = CliOverlay.default()
    _set_every_cli_value(overlay)

    var resolved = resolve_config(
        defaults,
        file,
        ConfigEnvironment(mtest_mojo="env-mojo", no_color=False),
        overlay,
    )
    assert_true(resolved.config.exitfirst)
    assert_equal(resolved.config.keyword, "selected")
    assert_false(resolved.config.collect)
    assert_true(resolved.config.shard_mode == ShardMode.SLICE)
    assert_equal(resolved.config.shard_m, 2)
    assert_equal(resolved.config.shard_n, 3)


def test_run_projection_activates_every_config_key() raises:
    var defaults = RunnerConfig.default()
    defaults.collect = False
    var resolved = resolve_config(
        defaults,
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    _assert_all_active(resolved.active_keys)


def test_collect_projection_excludes_run_and_report_only_keys() raises:
    var defaults = RunnerConfig.default()
    defaults.collect = True
    var file = FileConfig.empty()
    file.json_dest = "-"
    file.saw_json = True
    var resolved = resolve_config(
        defaults,
        file,
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    var keys = resolved.active_keys.copy()

    assert_true(keys.paths)
    assert_true(keys.excludes)
    assert_false(keys.gates)
    assert_false(keys.serial_globs)
    assert_false(keys.workers)
    assert_true(keys.timeout_secs)
    assert_false(keys.retries)
    assert_false(keys.maxfail)
    assert_false(keys.state)
    assert_true(keys.mojo_path)
    assert_true(keys.include_paths)
    assert_true(keys.build_args)
    assert_true(keys.precompiles)
    assert_true(keys.compile_timeout_secs)
    assert_false(keys.color)
    assert_false(keys.show_output)
    assert_false(keys.verbosity)
    assert_false(keys.durations)
    assert_false(keys.junit_dest)
    assert_false(keys.json_dest)
    assert_false(keys.gh_annotations)

    assert_equal(resolved.config.json_dest, "-")
    assert_true(resolved.config.gh_annotations == AnnotationsMode.AUTO)
    assert_true(resolved.provenance.json_dest == Provenance.MTEST_TOML)
    assert_true(resolved.provenance.gh_annotations == Provenance.DEFAULT)
    assert_false(Bool(validate_resolved_config(resolved)))


def test_run_cross_value_validation_names_each_value_where_it_was_set() raises:
    """The remedy must be one the reader can act on.

    The validator itself stays source-neutral — it reads resolved values, not
    argv — but the diagnostic it returns is not: telling someone to "drop
    '--json -'" is unactionable when the value lives in their project file,
    and telling them to edit `[report] json` is wrong when they typed the flag.
    """
    var file = FileConfig.empty()
    file.json_dest = "-"
    file.saw_json = True
    var from_file = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    var file_diagnostic = validate_resolved_config(from_file)
    assert_true(Bool(file_diagnostic))
    assert_true(
        file_diagnostic.value().startswith("config: mtest.toml: [report] json")
    )
    assert_true("set [report] json to a path" in file_diagnostic.value())
    assert_false("drop '--json -'" in file_diagnostic.value())

    var overlay = CliOverlay.default()
    overlay.json_dest = "-"
    overlay.saw_json = True
    var from_cli = resolve_config(
        RunnerConfig.default(),
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        overlay,
    )
    var cli_diagnostic = validate_resolved_config(from_cli)
    assert_true(Bool(cli_diagnostic))
    assert_true(cli_diagnostic.value().startswith("cli: '--json -'"))
    assert_true("use '--json PATH'" in cli_diagnostic.value())
