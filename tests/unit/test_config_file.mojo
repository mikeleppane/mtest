"""Hostile-corpus tests for typed `mtest.toml` conversion.

The corpus exercises every accepted table and key family, rejects unknown or
mistyped input, pins presence separately from explicit empty values, and proves
native-parser detail text cannot forge another diagnostic line.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import (
    AnnotationsMode,
    ColorWhen,
    ConfigDiagnostic,
    ConfigFailureKind,
    FileConfig,
    TOML_SOURCE_MAX_BYTES,
    ShowOutput,
    Verbosity,
    parse_toml,
)


@fieldwise_init
struct InvalidCase(Copyable, Movable):
    """One invalid TOML document and its stable mtest-owned error fragment."""

    var text: String
    var expected: String


@fieldwise_init
struct HostileCase(Copyable, Movable):
    """One user-controlled document and source label that must be contained."""

    var text: String
    var source: String


def _failure(
    text: String, source: String = "hostile.toml"
) raises -> ConfigDiagnostic:
    var result = parse_toml(text, source)
    assert_false(result.is_ok)
    var rendered = result.failure.render()
    assert_true(rendered.startswith("config: " + source + ": "))
    assert_true(len(rendered.split("\n")) <= 2)
    return result.failure.copy()


def test_key_value_pair_must_end_at_its_line() raises:
    """TOML 1.0 terminates a pair at the line end; the parser must too.

    Without it `timeout = 1 state = false` was accepted as two settings, so a
    missing newline silently turned a typo into a second configured value.
    """
    _ = _failure("[run]\ntimeout = 1 state = false\n")
    _ = _failure("[run]\nretries = 0 maxfail = 2\n")

    var ok = parse_toml("[run]\ntimeout = 1\nstate = false\n", "fine.toml")
    assert_true(ok.is_ok)
    assert_true(ok.config.saw_timeout)
    assert_true(ok.config.saw_state)

    var trailing = parse_toml("[run]\ntimeout = 1  # note\n", "fine.toml")
    assert_true(trailing.is_ok)


def test_override_serial_false_is_refused() raises:
    """Serial membership is a union, so `false` can never exempt a file."""
    var failure = _failure(
        '[[override]]\nfiles = ["a"]\ntimeout = 1\nserial = false\n'
    )
    assert_true("serial" in failure.render())

    var ok = parse_toml(
        '[[override]]\nfiles = ["a"]\nserial = true\n', "fine.toml"
    )
    assert_true(ok.is_ok)


def test_documented_schema_fits_the_parser_budgets() raises:
    """No configuration the schema describes may trip a work budget.

    The table-update budget counted every top-level header AND every
    depth-zero assignment against a ceiling of 64, so the documented key set
    plus eight `[[override]]` tables — each carrying the five keys §25 shows —
    was refused outright at 70 updates. Seven tables passed and the eighth did
    not, which is an ordinary project size, not an abusive document.

    Deliberately cheap: it asserts the boundary that actually regressed rather
    than rebuilding a document large enough to approach the node ceiling, for
    which the vendored parser is superlinear.
    """
    var text = String(
        "[run]\n"
        'paths = ["tests"]\n'
        'exclude = ["build/*"]\n'
        'gates = ["tests/smoke.mojo"]\n'
        'serial = ["tests/gpu_*"]\n'
        "workers = 1\n"
        "timeout = 300\n"
        "retries = 0\n"
        "maxfail = 0\n"
        "state = true\n"
        "fail-on-flaky = false\n"
        "\n[build]\n"
        'mojo = "mojo"\n'
        'include = ["vendor"]\n'
        'build-args = ["-DDEBUG"]\n'
        'precompile = ["src/a.mojo"]\n'
        "compile-timeout = 600\n"
        "\n[report]\n"
        'color = "auto"\n'
        'show-output = "failures"\n'
        'verbosity = "normal"\n'
        "durations = 0\n"
        'gh-annotations = "auto"\n'
    )
    for index in range(8):
        text += '\n[[override]]\nfiles = ["g' + String(index) + '"]\n'
        text += "timeout = 60\ncompile-timeout = 900\nretries = 1\n"
        text += "serial = true\n"

    var result = parse_toml(text, "documented.toml")
    assert_true(result.is_ok, result.failure.render())
    assert_equal(len(result.config.overrides), 8)


def test_empty_document_has_no_present_values() raises:
    var result = parse_toml("", "empty.toml")
    assert_true(result.is_ok)
    var config = result.config.copy()

    assert_false(config.saw_paths)
    assert_false(config.saw_excludes)
    assert_false(config.saw_gates)
    assert_false(config.saw_serial)
    assert_false(config.saw_workers)
    assert_false(config.saw_timeout)
    assert_false(config.saw_retries)
    assert_false(config.saw_maxfail)
    assert_false(config.saw_fail_on_flaky)
    assert_false(config.saw_state)
    assert_false(config.saw_mojo)
    assert_false(config.saw_include)
    assert_false(config.saw_build_args)
    assert_false(config.saw_precompile)
    assert_false(config.saw_compile_timeout)
    assert_false(config.saw_color)
    assert_false(config.saw_show_output)
    assert_false(config.saw_verbosity)
    assert_false(config.saw_durations)
    assert_false(config.saw_junit_xml)
    assert_false(config.saw_json)
    assert_false(config.saw_gh_annotations)
    assert_equal(len(config.overrides), 0)


def test_full_document_converts_every_key_to_typed_values() raises:
    var text = (
        "[run]\n"
        'paths = ["tests", "integration"]\n'
        'exclude = ["build/*"]\n'
        'gates = ["tests/smoke.mojo"]\n'
        'serial = ["tests/gpu_*"]\n'
        'workers = "auto"\n'
        "timeout = 0\n"
        "retries = 2\n"
        "maxfail = 3\n"
        "state = false\n"
        "fail-on-flaky = true\n"
        "\n"
        "[build]\n"
        'mojo = "/opt/mojo"\n'
        'include = ["vendor"]\n'
        'build-args = ["-DDEBUG"]\n'
        'precompile = ["src/a.mojo", "src/b.mojo:build/b.mojopkg"]\n'
        "compile-timeout = 45\n"
        "\n"
        "[report]\n"
        'color = "never"\n'
        'show-output = "all"\n'
        'verbosity = "verbose"\n'
        "durations = 7\n"
        'junit-xml = "reports/junit.xml"\n'
        'json = "-"\n'
        'gh-annotations = "off"\n'
        "\n"
        "[[override]]\n"
        'files = "tests/gpu_*"\n'
        "timeout = 1\n"
        "serial = true\n"
        "\n"
        "[[override]]\n"
        'files = ["tests/a.mojo", "tests/b.mojo"]\n'
        "compile-timeout = 2\n"
        "retries = 4\n"
    )
    var result = parse_toml(text, "complete.toml")
    assert_true(result.is_ok, result.failure.render())
    var config = result.config.copy()

    assert_true(config.saw_paths)
    assert_equal(config.paths[1], "integration")
    assert_true(config.saw_excludes)
    assert_equal(config.excludes[0], "build/*")
    assert_true(config.saw_gates)
    assert_true(config.saw_serial)
    assert_true(config.saw_workers)
    assert_equal(config.workers, 0)
    assert_true(config.saw_timeout)
    assert_equal(config.timeout_secs, 0)
    assert_true(config.saw_retries)
    assert_equal(config.retries, 2)
    assert_true(config.saw_maxfail)
    assert_equal(config.maxfail, 3)
    assert_true(config.saw_state)
    assert_false(config.state)
    assert_true(config.saw_fail_on_flaky)
    assert_true(config.fail_on_flaky)

    assert_true(config.saw_mojo)
    assert_equal(config.mojo_path, "/opt/mojo")
    assert_true(config.saw_include)
    assert_equal(config.include_paths[0], "vendor")
    assert_true(config.saw_build_args)
    assert_equal(config.build_args[0], "-DDEBUG")
    assert_true(config.saw_precompile)
    assert_equal(config.precompiles[0].src, "src/a.mojo")
    assert_false(config.precompiles[0].out)
    assert_equal(config.precompiles[1].out.value(), "build/b.mojopkg")
    assert_true(config.saw_compile_timeout)
    assert_equal(config.compile_timeout_secs, 45)

    assert_true(config.saw_color)
    assert_true(config.color == ColorWhen.NEVER)
    assert_true(config.saw_show_output)
    assert_true(config.show_output == ShowOutput.ALL)
    assert_true(config.saw_verbosity)
    assert_true(config.verbosity == Verbosity.VERBOSE)
    assert_true(config.saw_durations)
    assert_equal(config.durations, 7)
    assert_true(config.saw_junit_xml)
    assert_equal(config.junit_dest, "reports/junit.xml")
    assert_true(config.saw_json)
    assert_equal(config.json_dest, "-")
    assert_true(config.saw_gh_annotations)
    assert_true(config.gh_annotations == AnnotationsMode.OFF)

    assert_equal(len(config.overrides), 2)
    assert_equal(config.overrides[0].files[0], "tests/gpu_*")
    assert_true(config.overrides[0].saw_timeout)
    assert_equal(config.overrides[0].timeout_secs, 1)
    assert_true(config.overrides[0].saw_serial)
    assert_true(config.overrides[0].serial)
    assert_equal(config.overrides[1].files[0], "tests/a.mojo")
    assert_true(config.overrides[1].saw_compile_timeout)
    assert_equal(config.overrides[1].compile_timeout_secs, 2)
    assert_true(config.overrides[1].saw_retries)
    assert_equal(config.overrides[1].retries, 4)


def test_explicit_empty_arrays_are_present_and_replaceable() raises:
    var result = parse_toml(
        (
            "[run]\n"
            "paths = []\n"
            "exclude = []\n"
            "gates = []\n"
            "serial = []\n"
            "[build]\n"
            "include = []\n"
            "build-args = []\n"
            "precompile = []\n"
        ),
        "empty-arrays.toml",
    )
    assert_true(result.is_ok, result.failure.render())
    var config = result.config.copy()

    assert_true(config.saw_paths)
    assert_equal(len(config.paths), 0)
    assert_true(config.saw_excludes)
    assert_equal(len(config.excludes), 0)
    assert_true(config.saw_gates)
    assert_equal(len(config.gates), 0)
    assert_true(config.saw_serial)
    assert_equal(len(config.serial_globs), 0)
    assert_true(config.saw_include)
    assert_equal(len(config.include_paths), 0)
    assert_true(config.saw_build_args)
    assert_equal(len(config.build_args), 0)
    assert_true(config.saw_precompile)
    assert_equal(len(config.precompiles), 0)


def test_unknown_tables_and_keys_fail_closed() raises:
    var cases: List[InvalidCase] = [
        InvalidCase(
            text="[mystery]\nvalue = 1\n",
            expected="unknown top-level table 'mystery'",
        ),
        InvalidCase(
            text="[run]\ntimout = 1\n",
            expected="[run] key 'timout': unknown key",
        ),
        # The legal-key list a `[run]` typo is measured against, spelled out so
        # a key added to the schema without joining the message is caught here.
        InvalidCase(
            text="[run]\nfail-on-flake = true\n",
            expected=(
                "expected paths, exclude, gates, serial, workers, timeout,"
                " retries, maxfail, state, or fail-on-flaky"
            ),
        ),
        InvalidCase(
            text='[build]\noutput = "x"\n',
            expected="[build] key 'output': unknown key",
        ),
        InvalidCase(
            text='[report]\nformat = "x"\n',
            expected="[report] key 'format': unknown key",
        ),
        InvalidCase(
            text='[[override]]\nfiles = "*"\npriority = 1\n',
            expected="[[override]] #1 key 'priority': unknown key",
        ),
    ]
    for invalid in cases:
        var failure = _failure(invalid.text)
        assert_true(invalid.expected in failure.render(), failure.render())


def test_noneligible_run_and_directive_keys_are_rejected() raises:
    var forbidden = [
        "exitfirst",
        "keyword",
        "select",
        "shard",
        "lf",
        "ff",
        "collect",
        "mode",
        "config",
        "no-config",
        "help",
        "version",
    ]
    for key in forbidden:
        var failure = _failure("[run]\n" + key + " = true\n")
        assert_true(
            "[run] key '" + key + "': unknown key" in failure.render(),
            failure.render(),
        )


def test_every_key_family_rejects_wrong_types_and_domains() raises:
    var cases: List[InvalidCase] = [
        InvalidCase(
            text="run = 1\n",
            expected="[run]: expected table; got 1",
        ),
        InvalidCase(
            text="build = []\n",
            expected="[build]: expected table; got []",
        ),
        InvalidCase(
            text='report = "loud"\n',
            expected="[report]: expected table; got 'loud'",
        ),
        InvalidCase(
            text="[run]\npaths = 1\n",
            expected="[run] key 'paths': expected array of strings",
        ),
        InvalidCase(
            text='[run]\npaths = ["ok", 1]\n',
            expected="[run] key 'paths': expected array of strings",
        ),
        InvalidCase(
            text='[run]\nexclude = ["ok", 1]\n',
            expected="[run] key 'exclude': expected array of strings",
        ),
        InvalidCase(
            text="[run]\ngates = false\n",
            expected="[run] key 'gates': expected array of strings",
        ),
        InvalidCase(
            text='[run]\ngates = ["ok", false]\n',
            expected="[run] key 'gates': expected array of strings",
        ),
        InvalidCase(
            text="[run]\nserial = {}\n",
            expected="[run] key 'serial': expected array of strings",
        ),
        InvalidCase(
            text='[run]\nserial = ["ok", {}]\n',
            expected="[run] key 'serial': expected array of strings",
        ),
        InvalidCase(
            text='[run]\nworkers = "2"\n',
            expected="[run] key 'workers': expected positive integer or 'auto'",
        ),
        InvalidCase(
            text="[run]\nworkers = 0\n",
            expected="[run] key 'workers': expected positive integer or 'auto'",
        ),
        InvalidCase(
            text="[run]\nworkers = true\n",
            expected="[run] key 'workers': expected positive integer or 'auto'",
        ),
        InvalidCase(
            text="[run]\nworkers = 999999999999999999999999999999999999\n",
            expected="TOML parse failed",
        ),
        InvalidCase(
            text="[run]\ntimeout = -1\n",
            expected="[run] key 'timeout': expected integer >= 0",
        ),
        InvalidCase(
            text="[run]\ntimeout = 999999999999999999999999999999999999\n",
            expected="TOML parse failed",
        ),
        InvalidCase(
            text='[run]\ntimeout = "slow"\n',
            expected="[run] key 'timeout': expected integer >= 0",
        ),
        InvalidCase(
            text="[run]\nretries = true\n",
            expected="[run] key 'retries': expected integer >= 0",
        ),
        InvalidCase(
            text="[run]\nretries = -1\n",
            expected="[run] key 'retries': expected integer >= 0",
        ),
        InvalidCase(
            text='[run]\nmaxfail = "none"\n',
            expected="[run] key 'maxfail': expected integer >= 0",
        ),
        InvalidCase(
            text="[run]\nmaxfail = -1\n",
            expected="[run] key 'maxfail': expected integer >= 0",
        ),
        InvalidCase(
            text="[run]\nstate = 1\n",
            expected="[run] key 'state': expected boolean",
        ),
        InvalidCase(
            text='[run]\nfail-on-flaky = "yes"\n',
            expected="[run] key 'fail-on-flaky': expected boolean",
        ),
        InvalidCase(
            text="[run]\nfail-on-flaky = 1\n",
            expected="[run] key 'fail-on-flaky': expected boolean",
        ),
        InvalidCase(
            text="[build]\nmojo = 1\n",
            expected="[build] key 'mojo': expected string",
        ),
        InvalidCase(
            text="[build]\ninclude = 1\n",
            expected="[build] key 'include': expected array of strings",
        ),
        InvalidCase(
            text='[build]\ninclude = ["ok", 1]\n',
            expected="[build] key 'include': expected array of strings",
        ),
        InvalidCase(
            text="[build]\nbuild-args = false\n",
            expected="[build] key 'build-args': expected array of strings",
        ),
        InvalidCase(
            text='[build]\nbuild-args = ["-DOK", 1]\n',
            expected="[build] key 'build-args': expected array of strings",
        ),
        InvalidCase(
            text='[build]\nprecompile = [""]\n',
            expected="[build] key 'precompile': expected array of SRC[:OUT]",
        ),
        InvalidCase(
            text='[build]\nprecompile = ["ok.mojo", 1]\n',
            expected="[build] key 'precompile': expected array of SRC[:OUT]",
        ),
        InvalidCase(
            text="[build]\ncompile-timeout = -1\n",
            expected="[build] key 'compile-timeout': expected integer >= 0",
        ),
        InvalidCase(
            text="[build]\ncompile-timeout = true\n",
            expected="[build] key 'compile-timeout': expected integer >= 0",
        ),
        InvalidCase(
            text='[build]\nbuild-args = ["-o"]\n',
            expected="mtest owns output selection",
        ),
        InvalidCase(
            text='[build]\ninclude = ["extra.mojo"]\n',
            expected="mtest owns the source list",
        ),
        InvalidCase(
            text="[report]\ncolor = true\n",
            expected="[report] key 'color': expected auto|always|never",
        ),
        InvalidCase(
            text='[report]\ncolor = "sometimes"\n',
            expected="[report] key 'color': expected auto|always|never",
        ),
        InvalidCase(
            text='[report]\nshow-output = "yes"\n',
            expected="[report] key 'show-output': expected failures|all|none",
        ),
        InvalidCase(
            text="[report]\nshow-output = true\n",
            expected="[report] key 'show-output': expected failures|all|none",
        ),
        InvalidCase(
            text='[report]\nverbosity = "debug"\n',
            expected="[report] key 'verbosity': expected quiet|normal|verbose",
        ),
        InvalidCase(
            text="[report]\nverbosity = 1\n",
            expected="[report] key 'verbosity': expected quiet|normal|verbose",
        ),
        InvalidCase(
            text="[report]\ndurations = -1\n",
            expected="[report] key 'durations': expected integer >= 0",
        ),
        InvalidCase(
            text="[report]\ndurations = true\n",
            expected="[report] key 'durations': expected integer >= 0",
        ),
        InvalidCase(
            text="[report]\njunit-xml = 1\n",
            expected="[report] key 'junit-xml': expected non-empty string",
        ),
        InvalidCase(
            text='[report]\njunit-xml = ""\n',
            expected="[report] key 'junit-xml': expected non-empty string",
        ),
        InvalidCase(
            text="[report]\njson = []\n",
            expected="[report] key 'json': expected non-empty string or '-'",
        ),
        InvalidCase(
            text='[report]\njson = ""\n',
            expected="[report] key 'json': expected non-empty string or '-'",
        ),
        InvalidCase(
            text='[report]\ngh-annotations = "sometimes"\n',
            expected="[report] key 'gh-annotations': expected off|on|auto",
        ),
        InvalidCase(
            text="[report]\ngh-annotations = false\n",
            expected="[report] key 'gh-annotations': expected off|on|auto",
        ),
    ]
    for invalid in cases:
        var failure = _failure(invalid.text)
        assert_true(invalid.expected in failure.render(), failure.render())


def test_override_shapes_fail_closed() raises:
    var cases: List[InvalidCase] = [
        InvalidCase(
            text="override = {}\n",
            expected="[[override]]: expected array of tables",
        ),
        InvalidCase(
            text="override = []\n",
            expected="[[override]]: expected at least one table; got []",
        ),
        InvalidCase(
            text="[[override]]\ntimeout = 1\n",
            expected="[[override]] #1 key 'files': expected non-empty string",
        ),
        InvalidCase(
            text="[[override]]\nfiles = 1\ntimeout = 1\n",
            expected="[[override]] #1 key 'files': expected non-empty string",
        ),
        InvalidCase(
            text='[[override]]\nfiles = ""\ntimeout = 1\n',
            expected="[[override]] #1 key 'files': expected non-empty string",
        ),
        InvalidCase(
            text="[[override]]\nfiles = []\ntimeout = 1\n",
            expected="[[override]] #1 key 'files': expected non-empty string",
        ),
        InvalidCase(
            text='[[override]]\nfiles = ["ok", 1]\ntimeout = 1\n',
            expected="[[override]] #1 key 'files': expected non-empty string",
        ),
        InvalidCase(
            text='[[override]]\nfiles = "*"\n',
            expected=(
                "must set timeout, compile-timeout, retries, or serial = true"
            ),
        ),
        InvalidCase(
            text='[[override]]\nfiles = "*"\nserial = false\n',
            expected="[[override]] #1 key 'serial': expected true; got false",
        ),
        InvalidCase(
            text='[[override]]\nfiles = "*"\ntimeout = -1\n',
            expected="[[override]] #1 key 'timeout': expected integer >= 0",
        ),
        InvalidCase(
            text='[[override]]\nfiles = "*"\ntimeout = "slow"\n',
            expected="[[override]] #1 key 'timeout': expected integer >= 0",
        ),
        InvalidCase(
            text='[[override]]\nfiles = "*"\ncompile-timeout = "slow"\n',
            expected=(
                "[[override]] #1 key 'compile-timeout': expected integer >= 0"
            ),
        ),
        InvalidCase(
            text='[[override]]\nfiles = "*"\ncompile-timeout = -1\n',
            expected=(
                "[[override]] #1 key 'compile-timeout': expected integer >= 0"
            ),
        ),
        InvalidCase(
            text='[[override]]\nfiles = "*"\nretries = true\n',
            expected="[[override]] #1 key 'retries': expected integer >= 0",
        ),
        InvalidCase(
            text='[[override]]\nfiles = "*"\nretries = -1\n',
            expected="[[override]] #1 key 'retries': expected integer >= 0",
        ),
        InvalidCase(
            text='[[override]]\nfiles = "*"\nserial = 1\n',
            expected="[[override]] #1 key 'serial': expected boolean",
        ),
    ]
    for invalid in cases:
        var failure = _failure(invalid.text)
        assert_true(invalid.expected in failure.render(), failure.render())


def test_node_id_shaped_config_path_is_rejected() raises:
    var failure = _failure('[run]\npaths = ["tests/a.mojo::test_a"]\n')
    assert_true(
        "[run] key 'paths': node-id-shaped path is not allowed"
        in failure.render()
    )
    assert_true("tests/a.mojo::test_a" in failure.render())


def test_syntax_and_duplicate_key_errors_have_owned_framing() raises:
    var malformed = parse_toml("[run\n", "syntax.toml")
    assert_false(malformed.is_ok)
    assert_true(
        malformed.failure.render().startswith(
            "config: syntax.toml: TOML parse failed\n"
            "  detail (unstable, from the TOML parser): "
        )
    )
    assert_equal(len(malformed.failure.render().split("\n")), 2)
    assert_equal(malformed.failure.exit_code(), 4)

    var duplicate = parse_toml(
        "[run]\ntimeout = 1\ntimeout = 2\n", "duplicate.toml"
    )
    assert_false(duplicate.is_ok)
    assert_true(
        duplicate.failure.render().startswith(
            "config: duplicate.toml: TOML parse failed\n"
            "  detail (unstable, from the TOML parser): "
        )
    )
    assert_equal(len(duplicate.failure.render().split("\n")), 2)


def test_native_parse_is_self_contained() raises:
    var result = parse_toml("[run]\ntimeout = 1\n", "forced-home.toml")
    assert_true(result.is_ok, result.failure.render())
    assert_true(result.config.saw_timeout)
    assert_equal(result.config.timeout_secs, 1)


def test_offending_value_controls_cannot_forge_a_line() raises:
    var failure = _failure(
        '[run]\ntimeout = "SENTINEL\\nFAIL config: forged"\n'
    )
    var rendered = failure.render()
    assert_equal(len(rendered.split("\n")), 1)
    assert_true("SENTINEL\\nFAIL config: forged" in rendered)
    assert_false("\nFAIL config: forged" in rendered)

    var hostile_build_values = [
        (
            "[build]\n"
            'include = ["SENTINEL\\nFAIL config: forged\\u001b\\u0001.mojo"]\n'
        ),
        (
            "[build]\n"
            'build-args = ["-o=SENTINEL\\nFAIL config: forged'
            '\\u001b\\u0002"]\n'
        ),
    ]
    for text in hostile_build_values:
        var hostile = _failure(text).render()
        assert_equal(len(hostile.split("\n")), 1)
        assert_true("SENTINEL\\nFAIL config: forged" in hostile)
        assert_true("\\x1b" in hostile)
        assert_false("\nFAIL config: forged" in hostile)
        assert_false("\x1b" in hostile)
        assert_false("\x01" in hostile)
        assert_false("\x02" in hostile)


def test_offending_value_c1_controls_cannot_drive_the_terminal() raises:
    """C1 is the control class TOML lets straight through to the diagnostic.

    TOML forbids a raw C0 control inside a basic string, so ESC never survives
    to be quoted back — but `U+0080..U+009F` are legal string characters, and
    `U+009B` is CSI, `U+009D` is OSC and `U+009C` is ST in their
    single-code-point form. `main` prints this diagnostic to stderr, so an
    unescaped C1 lets a hostile `mtest.toml` repaint the terminal through the
    very message that rejects it, with no ESC byte anywhere in the file.
    """
    var rejected_value = _failure(
        '[run]\nmojo = "csi\\u009B2J\\u009D0;pwned\\u009C"\n'
    ).render()
    assert_true("\\x9b2J\\x9d0;pwned\\x9c" in rejected_value)

    var rejected_key = _failure('[run]\n"osc\\u009D0;pwned" = 1\n').render()
    assert_true("\\x9d0;pwned" in rejected_key)

    for rendered in [rejected_value, rejected_key]:
        assert_equal(len(rendered.split("\n")), 1)
        for cp in rendered.codepoints():
            assert_false(Int(cp) >= 128 and Int(cp) <= 159)


def test_public_parse_contains_representative_hostile_input() raises:
    var cases: List[HostileCase] = [
        HostileCase(
            text="[run]\ntimeout = 999999999999999999999999999999999999\n",
            source="oversized.toml",
        ),
        HostileCase(
            text="[run]\nretries = -1\n",
            source="negative.toml",
        ),
        HostileCase(
            text="[run]\nmaxfail = true\n",
            source="bool-int.toml",
        ),
        HostileCase(
            text="[run]\nworkers = 1.5\n",
            source="float.toml",
        ),
        HostileCase(
            text='[run]\npaths = ["ok", ["nested"]]\n',
            source="nested-run-array.toml",
        ),
        HostileCase(
            text="[[run.paths]]\nvalue = 1\n",
            source="table-run-array.toml",
        ),
        HostileCase(
            text="[run.nested]\nvalue = 1\n",
            source="unknown-run-table.toml",
        ),
        HostileCase(
            text="[build]\ncompile-timeout = true\n",
            source="build-bool-int.toml",
        ),
        HostileCase(
            text="[build]\nmojo = 1979-05-27T07:32:00Z\n",
            source="datetime.toml",
        ),
        HostileCase(
            text='[build]\ninclude = ["ok", { nested = true }]\n',
            source="nested-build-array.toml",
        ),
        HostileCase(
            text=(
                "[build]\n"
                'build-args = ["-o=SENTINEL\\nFAIL config: forged'
                '\\u001b\\u0003"]\n'
            ),
            source="hostile-build-value.toml",
        ),
        HostileCase(
            text="[report]\ndurations = -1\n",
            source="report-negative.toml",
        ),
        HostileCase(
            text="[report]\ncolor = 1.5\n",
            source="report-float.toml",
        ),
        HostileCase(
            text="[report]\nverbosity = [{ nested = true }]\n",
            source="report-table-array.toml",
        ),
        HostileCase(
            text="[report]\nunknown = 1\n",
            source="unknown-report-key.toml",
        ),
        HostileCase(
            text="override = []\n",
            source="empty-overrides.toml",
        ),
        HostileCase(
            text="[[override]]\nfiles = []\ntimeout = 1\n",
            source="empty-override-files.toml",
        ),
        HostileCase(
            text='[[override]]\nfiles = ["ok", ["nested"]]\ntimeout = 1\n',
            source="nested-override-files.toml",
        ),
        HostileCase(
            text=(
                '[[override]]\nfiles = "*"\n'
                "timeout = 999999999999999999999999999999999999\n"
            ),
            source="oversized-override.toml",
        ),
        HostileCase(
            text="[run\n",
            source="malformed\nFAIL config: forged\x1b.toml",
        ),
        HostileCase(
            text="[run]\ntimeout = 1\ntimeout = 2\n",
            source="duplicate.toml",
        ),
    ]
    for hostile in cases:
        var result = parse_toml(hostile.text, hostile.source)
        assert_false(result.is_ok)
        assert_true(result.failure.kind == ConfigFailureKind.DOCUMENT)
        assert_equal(result.failure.exit_code(), 4)
        var rendered = result.failure.render()
        var lines = rendered.split("\n")
        assert_true(len(lines) >= 1)
        assert_true(len(lines) <= 2)
        if len(lines) == 2:
            assert_true(
                lines[1].startswith(
                    "  detail (unstable, from the TOML parser): "
                )
            )
        for cp in rendered.codepoints():
            var value = Int(cp)
            if value >= 0 and value < 32:
                assert_equal(value, 10)
        assert_false("\nFAIL config: forged" in rendered)


def test_source_and_complexity_limits_fail_closed() raises:
    var exact = String(" ")
    for _ in range(22):
        exact += exact.copy()
    assert_equal(exact.byte_length(), TOML_SOURCE_MAX_BYTES)
    var exact_result = parse_toml(exact, "exact-limit.toml")
    assert_true(exact_result.is_ok, exact_result.failure.render())

    var oversized = exact + " "
    var oversized_result = parse_toml(oversized, "oversized.toml")
    assert_false(oversized_result.is_ok)
    assert_true("4194304-byte limit" in oversized_result.failure.render())

    var items = String('""')
    for _ in range(16):
        items += "," + items.copy()
    var many_values = "[run]\nexclude = [" + items + "]\n"
    var complex = parse_toml(many_values, "complex.toml")
    assert_false(complex.is_ok)
    assert_true("complexity limit" in complex.failure.render())


def test_adversarial_numbers_and_datetime_fail_without_raise() raises:
    var spellings = [
        "1__0",
        "1_",
        "_1",
        "1.2.3",
        "1e",
        "1e+",
        "1e999999",
        "0x",
        "0x_1",
        "0xGG",
        "0o8",
        "0b2",
        "01",
        "999999999999999999999999999999999999",
        "inf",
        "nan",
        "1979-05-27T07:32:00Z",
        "07:32:00",
    ]
    for spelling in spellings:
        var result = parse_toml(
            "[run]\ntimeout = " + spelling + "\n", "number.toml"
        )
        assert_false(result.is_ok, spelling)
        assert_equal(result.failure.exit_code(), 4)


def test_deep_nesting_is_rejected_before_parser_recursion() raises:
    var value = String('"x"')
    for _ in range(65):
        value = "[" + value + "]"
    var result = parse_toml("[run]\npaths = " + value + "\n", "deep.toml")
    assert_false(result.is_ok)
    assert_true("nesting limit" in result.failure.render())


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
