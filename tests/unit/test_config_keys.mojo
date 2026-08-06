"""The double-entry gate over the configuration-eligible key set.

One configuration key is spelled in six places: the flag table that accepts it,
`RunnerConfig` that holds the resolved value, `CliOverlay` and `FileConfig`
that carry a layer's value plus its presence bit, `ConfigProvenance` that
records which layer won, `ActiveConfigKeys` that says which commands consume
it, and `OverrideRule` where a per-file table may restate it. A key added to
some of those and forgotten in the rest is silent: the flag parses, the value
lands, and it is dropped on the way to the session.

The gate is double entry. The product's own `flag_specs()` table is the first
entry; the key table below is the second, written independently, and every
assertion here reconciles the two or drives a key through a real resolution
rather than reading it back from the same place it was written.

**What this cannot catch.** Mojo 1.0.0b2 has no field reflection, so no
assertion here can count a struct's fields. Every count is taken against a
projection this file enumerates. A key added to `flag_specs()` or to the table
below and forgotten in a struct path fails here; a field added to one struct
alone, reaching no flag and no layer, is invisible to this gate and is caught
only by review — the same boundary `tests/unit/test_cli_inventory.mojo` lives
with.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.cli import FlagId, flag_specs
from mtest.config import (
    ActiveConfigKeys,
    AnnotationsMode,
    CliOverlay,
    ColorWhen,
    ConfigEnvironment,
    FileConfig,
    OverrideRule,
    Precompile,
    Provenance,
    ReportStyle,
    ResolvedConfig,
    RunnerConfig,
    ShowOutput,
    Verbosity,
    resolve_config,
)


comptime _NO_FLAG = -1
"""Stands in for a key argv supplies without a flag, or does not supply."""

comptime _MARKER = "marker"
"""The non-default string every layer under test writes.

A key whose value is not carried comes back at its contract default, so every
marker below has to differ from that default or the check cannot fail.
"""


@fieldwise_init
struct _KeyRow(Copyable, Movable):
    """One configuration-eligible key and everything the layers owe it."""

    var key: String
    """The field name the resolver, the layers, and the provenance share."""

    var flag_ids: List[Int]
    """Every `FlagId` whose spelling supplies this key, possibly none."""

    var in_runner_config: Bool
    """Whether `RunnerConfig` holds the resolved value."""

    var overridable: Bool
    """Whether one `[[override]]` rule may restate this key per file."""

    var in_collect: Bool
    """Whether the collect projection consumes this key."""

    var in_debug: Bool
    """Whether the debug projection consumes this key."""


def _config_keys() -> List[_KeyRow]:
    """The configuration-eligible keys, transcribed independently.

    Returns:
        A freshly allocated table, one row per key, in resolution order.
    """
    return [
        _KeyRow("paths", [], True, False, True, False),
        _KeyRow("excludes", [FlagId.EXCLUDE], True, False, True, False),
        _KeyRow("gates", [FlagId.GATE], True, False, False, False),
        _KeyRow("serial_globs", [FlagId.SERIAL], True, True, False, False),
        _KeyRow("workers", [FlagId.WORKERS], True, False, False, False),
        _KeyRow("timeout_secs", [FlagId.TIMEOUT], True, True, True, True),
        _KeyRow("retries", [FlagId.RETRIES], True, True, False, False),
        _KeyRow("maxfail", [FlagId.MAXFAIL], True, False, False, False),
        _KeyRow(
            "fail_on_flaky", [FlagId.FAIL_ON_FLAKY], True, False, False, False
        ),
        _KeyRow("state", [], False, False, False, False),
        _KeyRow("mojo_path", [FlagId.MOJO], True, False, True, True),
        _KeyRow("include_paths", [FlagId.INCLUDE], True, False, True, True),
        _KeyRow("build_args", [FlagId.BUILD_ARG], True, False, True, True),
        _KeyRow("precompiles", [FlagId.PRECOMPILE], True, False, True, True),
        _KeyRow(
            "compile_timeout_secs",
            [FlagId.COMPILE_TIMEOUT],
            True,
            True,
            True,
            True,
        ),
        _KeyRow("color", [FlagId.COLOR], True, False, False, False),
        _KeyRow(
            "show_output",
            [FlagId.SHOW_OUTPUT, FlagId.SHOW_ALL],
            True,
            False,
            False,
            False,
        ),
        _KeyRow(
            "verbosity",
            [FlagId.VERBOSE, FlagId.QUIET],
            True,
            False,
            False,
            False,
        ),
        _KeyRow("durations", [FlagId.DURATIONS], True, False, False, False),
        _KeyRow("junit_dest", [FlagId.JUNIT_XML], True, False, False, False),
        _KeyRow("json_dest", [FlagId.JSON], True, False, False, False),
        _KeyRow(
            "gh_annotations",
            [FlagId.GH_ANNOTATIONS],
            True,
            False,
            False,
            False,
        ),
        _KeyRow("report_md_dest", [FlagId.REPORT], True, False, False, False),
        _KeyRow("report_html_dest", [FlagId.REPORT], True, False, False, False),
        _KeyRow(
            "report_style", [FlagId.REPORT_STYLE], True, False, False, False
        ),
    ]


def _non_config_flag_ids() -> List[Int]:
    """Every flag identity that supplies no configuration key.

    Transcribed from the flags with no `mtest.toml` spelling, so a new flag is
    a decision rather than a default: it either names a key in the table above
    or it is listed here.

    Returns:
        A freshly allocated list of `FlagId` constants.
    """
    return [
        FlagId.EXITFIRST,
        FlagId.SELECT,
        FlagId.HELP,
        FlagId.VERSION,
        FlagId.COLLECT_ONLY,
        FlagId.SHARD,
        FlagId.CONFIG,
        FlagId.NO_CONFIG,
        FlagId.LAST_FAILED,
        FlagId.FAILED_FIRST,
        FlagId.NO_CACHE,
        FlagId.CACHE_CLEAR,
        FlagId.SHUFFLE,
        FlagId.SEED,
        FlagId.FORMAT,
    ]


def _file_with(key: String) raises -> FileConfig:
    """A project-file layer supplying exactly `key`, at a non-default value.

    Args:
        key: The configuration key to supply.

    Returns:
        A freshly allocated file layer with one value and one presence bit set.

    Raises:
        Error: If `key` names no configuration key.
    """
    var file = FileConfig.empty()
    if key == "paths":
        file.paths = [_MARKER]
        file.saw_paths = True
    elif key == "excludes":
        file.excludes = [_MARKER]
        file.saw_excludes = True
    elif key == "gates":
        file.gates = [_MARKER]
        file.saw_gates = True
    elif key == "serial_globs":
        file.serial_globs = [_MARKER]
        file.saw_serial = True
    elif key == "workers":
        file.workers = 6
        file.saw_workers = True
    elif key == "timeout_secs":
        file.timeout_secs = 11
        file.saw_timeout = True
    elif key == "retries":
        file.retries = 3
        file.saw_retries = True
    elif key == "maxfail":
        file.maxfail = 4
        file.saw_maxfail = True
    elif key == "fail_on_flaky":
        file.fail_on_flaky = True
        file.saw_fail_on_flaky = True
    elif key == "state":
        file.state = False
        file.saw_state = True
    elif key == "mojo_path":
        file.mojo_path = _MARKER
        file.saw_mojo = True
    elif key == "include_paths":
        file.include_paths = [_MARKER]
        file.saw_include = True
    elif key == "build_args":
        file.build_args = [_MARKER]
        file.saw_build_args = True
    elif key == "precompiles":
        file.precompiles = [Precompile(src=_MARKER, out=Optional[String](None))]
        file.saw_precompile = True
    elif key == "compile_timeout_secs":
        file.compile_timeout_secs = 12
        file.saw_compile_timeout = True
    elif key == "color":
        file.color = ColorWhen.NEVER
        file.saw_color = True
    elif key == "show_output":
        file.show_output = ShowOutput.ALL
        file.saw_show_output = True
    elif key == "verbosity":
        file.verbosity = Verbosity.VERBOSE
        file.saw_verbosity = True
    elif key == "durations":
        file.durations = 5
        file.saw_durations = True
    elif key == "junit_dest":
        file.junit_dest = _MARKER
        file.saw_junit_xml = True
    elif key == "json_dest":
        file.json_dest = _MARKER
        file.saw_json = True
    elif key == "gh_annotations":
        file.gh_annotations = AnnotationsMode.OFF
        file.saw_gh_annotations = True
    elif key == "report_md_dest":
        file.report_md_dest = _MARKER
        file.saw_report_md = True
    elif key == "report_html_dest":
        file.report_html_dest = _MARKER
        file.saw_report_html = True
    elif key == "report_style":
        file.report_style = ReportStyle.FULL
        file.saw_report_style = True
    else:
        raise Error("no [mtest.toml] layer for key '" + key + "'")
    return file^


def _overlay_with(key: String) raises -> CliOverlay:
    """An argv layer supplying exactly `key`, at the same non-default value.

    Args:
        key: The configuration key to supply.

    Returns:
        A freshly allocated overlay with one value and one presence bit set.

    Raises:
        Error: If `key` names no configuration key.
    """
    var overlay = CliOverlay.default()
    if key == "paths":
        overlay.paths = [_MARKER]
        overlay.saw_paths = True
    elif key == "excludes":
        overlay.excludes = [_MARKER]
        overlay.saw_excludes = True
    elif key == "gates":
        overlay.gates = [_MARKER]
        overlay.saw_gates = True
    elif key == "serial_globs":
        overlay.serial_globs = [_MARKER]
        overlay.saw_serial = True
    elif key == "workers":
        overlay.workers = 6
        overlay.saw_workers = True
    elif key == "timeout_secs":
        overlay.timeout_secs = 11
        overlay.saw_timeout = True
    elif key == "retries":
        overlay.retries = 3
        overlay.saw_retries = True
    elif key == "maxfail":
        overlay.maxfail = 4
        overlay.saw_maxfail = True
    elif key == "fail_on_flaky":
        overlay.fail_on_flaky = True
        overlay.saw_fail_on_flaky = True
    elif key == "state":
        overlay.state = False
        overlay.saw_state = True
    elif key == "mojo_path":
        overlay.mojo_path = _MARKER
        overlay.saw_mojo = True
    elif key == "include_paths":
        overlay.include_paths = [_MARKER]
        overlay.saw_include = True
    elif key == "build_args":
        overlay.build_args = [_MARKER]
        overlay.saw_build_args = True
    elif key == "precompiles":
        overlay.precompiles = [
            Precompile(src=_MARKER, out=Optional[String](None))
        ]
        overlay.saw_precompile = True
    elif key == "compile_timeout_secs":
        overlay.compile_timeout_secs = 12
        overlay.saw_compile_timeout = True
    elif key == "color":
        overlay.color = ColorWhen.NEVER
        overlay.saw_color = True
    elif key == "show_output":
        overlay.show_output = ShowOutput.ALL
        overlay.saw_show_output = True
    elif key == "verbosity":
        overlay.verbosity = Verbosity.VERBOSE
        overlay.saw_verbosity = True
    elif key == "durations":
        overlay.durations = 5
        overlay.saw_durations = True
    elif key == "junit_dest":
        overlay.junit_dest = _MARKER
        overlay.saw_junit_xml = True
    elif key == "json_dest":
        overlay.json_dest = _MARKER
        overlay.saw_json = True
    elif key == "gh_annotations":
        overlay.gh_annotations = AnnotationsMode.OFF
        overlay.saw_gh_annotations = True
    elif key == "report_md_dest":
        overlay.report_md_dest = _MARKER
        overlay.saw_report_md = True
    elif key == "report_html_dest":
        overlay.report_html_dest = _MARKER
        overlay.saw_report_html = True
    elif key == "report_style":
        overlay.report_style = ReportStyle.FULL
        overlay.saw_report_style = True
    else:
        raise Error("no argv layer for key '" + key + "'")
    return overlay^


def _carries_marker(config: RunnerConfig, key: String) raises -> Bool:
    """Whether `config` holds the marker value `key`'s layers supplied.

    Args:
        config: The resolved or folded values.
        key: The configuration key to read.

    Returns:
        True when the field holds the marker rather than its contract default.

    Raises:
        Error: If `key` names no `RunnerConfig` field.
    """
    if key == "paths":
        return len(config.paths) == 1 and config.paths[0] == _MARKER
    if key == "excludes":
        return len(config.excludes) == 1 and config.excludes[0] == _MARKER
    if key == "gates":
        return len(config.gates) == 1 and config.gates[0] == _MARKER
    if key == "serial_globs":
        return (
            len(config.serial_globs) == 1 and config.serial_globs[0] == _MARKER
        )
    if key == "workers":
        return config.workers == 6
    if key == "timeout_secs":
        return config.timeout_secs == 11
    if key == "retries":
        return config.retries == 3
    if key == "maxfail":
        return config.maxfail == 4
    if key == "fail_on_flaky":
        return config.fail_on_flaky
    if key == "mojo_path":
        return config.mojo_path == _MARKER
    if key == "include_paths":
        return (
            len(config.include_paths) == 1
            and config.include_paths[0] == _MARKER
        )
    if key == "build_args":
        return len(config.build_args) == 1 and config.build_args[0] == _MARKER
    if key == "precompiles":
        return (
            len(config.precompiles) == 1
            and config.precompiles[0].src == _MARKER
        )
    if key == "compile_timeout_secs":
        return config.compile_timeout_secs == 12
    if key == "color":
        return config.color == ColorWhen.NEVER
    if key == "show_output":
        return config.show_output == ShowOutput.ALL
    if key == "verbosity":
        return config.verbosity == Verbosity.VERBOSE
    if key == "durations":
        return config.durations == 5
    if key == "junit_dest":
        return config.junit_dest == _MARKER
    if key == "json_dest":
        return config.json_dest == _MARKER
    if key == "gh_annotations":
        return config.gh_annotations == AnnotationsMode.OFF
    if key == "report_md_dest":
        return config.report_md_dest == _MARKER
    if key == "report_html_dest":
        return config.report_html_dest == _MARKER
    if key == "report_style":
        return config.report_style == ReportStyle.FULL
    raise Error("no RunnerConfig field for key '" + key + "'")


def _provenance_of(resolved: ResolvedConfig, key: String) raises -> Provenance:
    """The layer that won `key`.

    Args:
        resolved: The layered configuration to read.
        key: The configuration key to read.

    Returns:
        The recorded source of that key.

    Raises:
        Error: If `key` names no `ConfigProvenance` field.
    """
    var sources = resolved.provenance.copy()
    if key == "paths":
        return sources.paths
    if key == "excludes":
        return sources.excludes
    if key == "gates":
        return sources.gates
    if key == "serial_globs":
        return sources.serial_globs
    if key == "workers":
        return sources.workers
    if key == "timeout_secs":
        return sources.timeout_secs
    if key == "retries":
        return sources.retries
    if key == "maxfail":
        return sources.maxfail
    if key == "fail_on_flaky":
        return sources.fail_on_flaky
    if key == "state":
        return sources.state
    if key == "mojo_path":
        return sources.mojo_path
    if key == "include_paths":
        return sources.include_paths
    if key == "build_args":
        return sources.build_args
    if key == "precompiles":
        return sources.precompiles
    if key == "compile_timeout_secs":
        return sources.compile_timeout_secs
    if key == "color":
        return sources.color
    if key == "show_output":
        return sources.show_output
    if key == "verbosity":
        return sources.verbosity
    if key == "durations":
        return sources.durations
    if key == "junit_dest":
        return sources.junit_dest
    if key == "json_dest":
        return sources.json_dest
    if key == "gh_annotations":
        return sources.gh_annotations
    if key == "report_md_dest":
        return sources.report_md_dest
    if key == "report_html_dest":
        return sources.report_html_dest
    if key == "report_style":
        return sources.report_style
    raise Error("no ConfigProvenance field for key '" + key + "'")


def _active_in(keys: ActiveConfigKeys, key: String) raises -> Bool:
    """Whether one command projection consumes `key`.

    Args:
        keys: The projection to read.
        key: The configuration key to read.

    Returns:
        Whether that command consumes and cross-validates the key.

    Raises:
        Error: If `key` names no `ActiveConfigKeys` field.
    """
    if key == "paths":
        return keys.paths
    if key == "excludes":
        return keys.excludes
    if key == "gates":
        return keys.gates
    if key == "serial_globs":
        return keys.serial_globs
    if key == "workers":
        return keys.workers
    if key == "timeout_secs":
        return keys.timeout_secs
    if key == "retries":
        return keys.retries
    if key == "maxfail":
        return keys.maxfail
    if key == "fail_on_flaky":
        return keys.fail_on_flaky
    if key == "state":
        return keys.state
    if key == "mojo_path":
        return keys.mojo_path
    if key == "include_paths":
        return keys.include_paths
    if key == "build_args":
        return keys.build_args
    if key == "precompiles":
        return keys.precompiles
    if key == "compile_timeout_secs":
        return keys.compile_timeout_secs
    if key == "color":
        return keys.color
    if key == "show_output":
        return keys.show_output
    if key == "verbosity":
        return keys.verbosity
    if key == "durations":
        return keys.durations
    if key == "junit_dest":
        return keys.junit_dest
    if key == "json_dest":
        return keys.json_dest
    if key == "gh_annotations":
        return keys.gh_annotations
    if key == "report_md_dest":
        return keys.report_md_dest
    if key == "report_html_dest":
        return keys.report_html_dest
    if key == "report_style":
        return keys.report_style
    raise Error("no ActiveConfigKeys field for key '" + key + "'")


def _override_restates(rule: OverrideRule, key: String) -> Bool:
    """Whether `rule` restates `key` for the files it matches."""
    if key == "timeout_secs":
        return rule.saw_timeout
    if key == "compile_timeout_secs":
        return rule.saw_compile_timeout
    if key == "retries":
        return rule.saw_retries
    if key == "serial_globs":
        return rule.saw_serial
    return False


def _fully_stated_override() -> OverrideRule:
    """A rule that restates every key a `[[override]]` table may carry."""
    var rule = OverrideRule.empty()
    rule.timeout_secs = 11
    rule.saw_timeout = True
    rule.compile_timeout_secs = 12
    rule.saw_compile_timeout = True
    rule.retries = 3
    rule.saw_retries = True
    rule.serial = True
    rule.saw_serial = True
    return rule^


def _resolve_file(key: String) raises -> ResolvedConfig:
    """Resolve with the project file as the only layer supplying `key`."""
    return resolve_config(
        RunnerConfig.default(),
        _file_with(key),
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )


def _resolve_cli(key: String) raises -> ResolvedConfig:
    """Resolve with argv as the only layer supplying `key`."""
    return resolve_config(
        RunnerConfig.default(),
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        _overlay_with(key),
    )


def test_the_key_table_is_exactly_the_eligible_set() raises:
    var keys = _config_keys()
    assert_equal(len(keys), 25)
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            assert_true(
                keys[i].key != keys[j].key,
                "duplicate key '" + keys[i].key + "'",
            )


def test_every_key_flag_is_a_row_in_the_flag_table() raises:
    """A key may only claim a spelling the parser actually accepts."""
    var specs = flag_specs()
    for row in _config_keys():
        for flag_id in row.flag_ids:
            var found = False
            for spec in specs:
                if spec.id == flag_id:
                    found = True
            assert_true(
                found,
                "key '" + row.key + "' claims an unknown flag identity",
            )


def test_every_flag_either_names_a_key_or_is_listed_as_supplying_none() raises:
    """The reconciliation between the two entries.

    A flag added without a decision about its configuration key lands in
    neither list and fails here.
    """
    var supplying = List[Int]()
    for row in _config_keys():
        for flag_id in row.flag_ids:
            var seen = False
            for known in supplying:
                if known == flag_id:
                    seen = True
            if not seen:
                supplying.append(flag_id)
    var non_config = _non_config_flag_ids()
    assert_equal(len(supplying), 24)
    assert_equal(len(non_config), 15)

    for flag_id in supplying:
        for other in non_config:
            assert_true(
                flag_id != other,
                "flag identity " + String(flag_id) + " is on both lists",
            )

    var accounted = 0
    var distinct = List[Int]()
    for spec in flag_specs():
        var seen = False
        for known in distinct:
            if known == spec.id:
                seen = True
        if seen:
            continue
        distinct.append(spec.id)
        var found = False
        for flag_id in supplying:
            if flag_id == spec.id:
                found = True
        for flag_id in non_config:
            if flag_id == spec.id:
                found = True
        assert_true(
            found,
            (
                "flag identity "
                + String(spec.id)
                + " ('"
                + spec.spelling
                + "') names no configuration key and is not listed as"
                " supplying none"
            ),
        )
        accounted += 1
    assert_equal(accounted, len(supplying) + len(non_config))


def test_every_key_resolves_from_the_project_file() raises:
    """`FileConfig` carries the value and `resolve_config` stamps the source."""
    for row in _config_keys():
        var resolved = _resolve_file(row.key)
        assert_true(
            _provenance_of(resolved, row.key) == Provenance.MTEST_TOML,
            "key '" + row.key + "' lost its project-file provenance",
        )
        if row.in_runner_config:
            assert_true(
                _carries_marker(resolved.config, row.key),
                "key '" + row.key + "' lost its project-file value",
            )
        else:
            assert_false(
                resolved.state, "key '" + row.key + "' lost its file value"
            )


def test_every_key_resolves_from_argv() raises:
    """`CliOverlay` carries the value and the CLI layer outranks the rest."""
    for row in _config_keys():
        var resolved = _resolve_cli(row.key)
        assert_true(
            _provenance_of(resolved, row.key) == Provenance.CLI,
            "key '" + row.key + "' lost its command-line provenance",
        )
        if row.in_runner_config:
            assert_true(
                _carries_marker(resolved.config, row.key),
                "key '" + row.key + "' lost its command-line value",
            )
        else:
            assert_false(
                resolved.state, "key '" + row.key + "' lost its argv value"
            )


def test_every_key_survives_the_parser_fold() raises:
    """The overlay's two consumers apply exactly the same keys.

    `fold` serves the parser and layered resolution serves the run. A key one
    of them applies and the other does not is a value that reaches the
    resolver and never the parsed config.
    """
    for row in _config_keys():
        if not row.in_runner_config:
            continue
        var folded = _overlay_with(row.key).fold(RunnerConfig.default())
        assert_true(
            _carries_marker(folded, row.key),
            "key '" + row.key + "' is dropped by the fold",
        )


def test_each_projection_answers_for_every_key() raises:
    var run = ActiveConfigKeys.run()
    var collect = ActiveConfigKeys.collect()
    var debug = ActiveConfigKeys.debug()
    var run_count = 0
    var collect_count = 0
    var debug_count = 0
    for row in _config_keys():
        assert_true(
            _active_in(run, row.key),
            "key '" + row.key + "' is inactive on the run path",
        )
        assert_equal(
            _active_in(collect, row.key),
            row.in_collect,
            "key '" + row.key + "' disagrees about collect",
        )
        assert_equal(
            _active_in(debug, row.key),
            row.in_debug,
            "key '" + row.key + "' disagrees about debug",
        )
        run_count += 1 if _active_in(run, row.key) else 0
        collect_count += 1 if _active_in(collect, row.key) else 0
        debug_count += 1 if _active_in(debug, row.key) else 0
    assert_equal(run_count, 25)
    assert_equal(collect_count, 8)
    assert_equal(debug_count, 6)


def test_the_override_table_restates_exactly_the_per_file_keys() raises:
    var rule = _fully_stated_override()
    var stated = 0
    for row in _config_keys():
        assert_equal(
            _override_restates(rule, row.key),
            row.overridable,
            "key '" + row.key + "' disagrees about per-file overrides",
        )
        stated += 1 if row.overridable else 0
    assert_equal(stated, 4)
    # An empty rule restates nothing, so the presence bits above are read and
    # not merely present.
    var empty = OverrideRule.empty()
    for row in _config_keys():
        assert_false(_override_restates(empty, row.key))


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
