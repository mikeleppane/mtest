"""The single lazy Python boundary for parsing `mtest.toml` text.

Only `_parse_toml_with_python` handles Python objects. It initializes Python,
imports stdlib `tomllib`, and converts the complete document immediately into
typed `FileConfig` data. Importing this Mojo module alone performs no Python
work; Python is acquired only when a parse function is called.
"""
from std.python import Python, PythonObject

from mtest.config.file_config import FileConfig, OverrideRule
from mtest.config.precompile import Precompile
from mtest.config.value_validation import (
    build_arg_rejection,
    parse_annotations_value,
    parse_color_value,
    parse_nonnegative_decimal,
    parse_precompile_value,
    parse_show_output_value,
    parse_verbosity_value,
    parse_worker_count,
)


@fieldwise_init
struct ConfigFailureKind(Equatable, ImplicitlyCopyable, Movable):
    """One caller-visible failure class from the TOML bridge."""

    var value: Int
    """The stable integer discriminant identifying this class."""

    comptime NONE = Self(0)
    comptime INITIALIZATION = Self(1)
    comptime TOMLLIB_IMPORT = Self(2)
    comptime DOCUMENT = Self(3)

    def __eq__(self, other: Self) -> Bool:
        """Whether both values name the same failure class."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether both values name different failure classes."""
        return self.value != other.value


@fieldwise_init
struct ConfigDiagnostic(Copyable, Movable):
    """One contained, mtest-owned configuration diagnostic."""

    var kind: ConfigFailureKind
    """The failure class used to choose the runner exit domain."""

    var framing: String
    """The stable mtest-owned first line."""

    var detail: String
    """Optional unstable Python detail, empty when absent."""

    def exit_code(self) -> Int:
        """Return the runner exit class for this failure.

        Returns:
            `3` for interpreter or impossible-import failures, otherwise `4`
            for invalid TOML syntax, shape, type, or value.
        """
        if (
            self.kind == ConfigFailureKind.INITIALIZATION
            or self.kind == ConfigFailureKind.TOMLLIB_IMPORT
        ):
            return 3
        return 4

    def render(self) -> String:
        """Render contained diagnostic text with at most one detail line.

        Returns:
            A newly allocated diagnostic whose first line is mtest-owned and
            whose optional Python detail is explicitly marked and C0-escaped.
        """
        if self.detail.byte_length() == 0:
            return self.framing.copy()
        return (
            self.framing
            + "\n  detail (unstable, from the Python parser): "
            + self.detail
        )

    @staticmethod
    def empty() -> ConfigDiagnostic:
        """Build the placeholder carried by a successful parse result.

        Returns:
            A diagnostic with no failure kind or rendered text.
        """
        return ConfigDiagnostic(
            kind=ConfigFailureKind.NONE,
            framing="",
            detail="",
        )


@fieldwise_init
struct TomlParseResult(Copyable, Movable):
    """A typed file config or one contained bridge diagnostic."""

    var is_ok: Bool
    """Whether `config` contains the successfully converted document."""

    var config: FileConfig
    """The converted file layer, or an empty placeholder on failure."""

    var failure: ConfigDiagnostic
    """The failure, or an empty placeholder on success."""


def _escape_c0(text: String) -> String:
    var escaped = String("")
    comptime HEX = "0123456789abcdef"
    for cp in text.codepoints():
        var value = Int(cp)
        if value == 10:
            escaped += "\\n"
        elif value == 13:
            escaped += "\\r"
        elif value == 9:
            escaped += "\\t"
        elif value >= 0 and value < 32:
            escaped += "\\x"
            escaped += String(HEX[byte=value // 16])
            escaped += String(HEX[byte=value % 16])
        else:
            escaped += String(cp)
    return escaped


def _safe_repr(representation: String) -> String:
    var escaped = _escape_c0(representation)
    if escaped.count_codepoints() <= 240:
        return escaped
    var shortened = String("")
    var count = 0
    for cp in escaped.codepoint_slices():
        if count == 237:
            break
        shortened += String(cp)
        count += 1
    shortened += "..."
    return shortened


def _parse_nonnegative_bounded(value: String) -> Optional[Int]:
    try:
        return parse_nonnegative_decimal(value)
    except:
        return Optional[Int](None)


def _parse_worker_count_bounded(value: String) -> Optional[Int]:
    try:
        return parse_worker_count(value)
    except:
        return Optional[Int](None)


def _diagnostic(
    source: String,
    kind: ConfigFailureKind,
    summary: String,
    detail: String = "",
) -> ConfigDiagnostic:
    return ConfigDiagnostic(
        kind=kind,
        framing=("config: " + _escape_c0(source) + ": " + _escape_c0(summary)),
        detail=_escape_c0(detail),
    )


def _success(var config: FileConfig) -> TomlParseResult:
    return TomlParseResult(
        is_ok=True,
        config=config^,
        failure=ConfigDiagnostic.empty(),
    )


def _failure(var diagnostic: ConfigDiagnostic) -> TomlParseResult:
    return TomlParseResult(
        is_ok=False,
        config=FileConfig.empty(),
        failure=diagnostic^,
    )


def _invalid(
    source: String,
    location: String,
    expected: String,
    got: String,
) -> TomlParseResult:
    var suffix = String("")
    if got.byte_length() > 0:
        suffix = "; got " + got
    return _failure(
        _diagnostic(
            source,
            ConfigFailureKind.DOCUMENT,
            location + ": expected " + expected + suffix,
        )
    )


def _invalid_string_array(
    source: String,
    location: String,
    got: String,
) -> TomlParseResult:
    return _invalid(source, location, "array of strings", got)


def _invalid_nonnegative(
    source: String,
    location: String,
    got: String,
) -> TomlParseResult:
    return _invalid(source, location, "integer >= 0", got)


def _forbidden_build_argument(
    source: String,
    location: String,
    rejection: String,
    got: String,
) -> TomlParseResult:
    return _failure(
        _diagnostic(
            source,
            ConfigFailureKind.DOCUMENT,
            location + ": " + _safe_repr(rejection) + "; got " + got,
        )
    )


def _unknown(
    source: String,
    location: String,
    key: String,
    expected: String,
    got: String,
) -> TomlParseResult:
    return _failure(
        _diagnostic(
            source,
            ConfigFailureKind.DOCUMENT,
            location
            + " key '"
            + _escape_c0(key)
            + "': unknown key; expected "
            + expected
            + "; got "
            + got,
        )
    )


def _parse_toml_with_python(
    toml_text: String,
    source: String,
    injected_kind: ConfigFailureKind,
    injected_detail: String,
) -> TomlParseResult:
    """Own the complete Python-object-to-`FileConfig` conversion.

    Python objects are local to this function and are converted before return.
    Validation returns a typed diagnostic rather than raising, while unexpected
    errors from an initialized Python runtime become one contained detail line.

    Args:
        toml_text: The complete TOML document text. Not mutated.
        source: The file path or test label used in every diagnostic.
        injected_kind: Test seam selecting initialization or document failure;
            `NONE` performs a real parse.
        injected_detail: Hostile detail text used only by the test seam.

    Returns:
        A typed file model on success, or one normalized diagnostic. Allocates
        the model and any rendered diagnostic strings.
    """
    if injected_kind == ConfigFailureKind.INITIALIZATION:
        return _failure(
            _diagnostic(
                source,
                ConfigFailureKind.INITIALIZATION,
                "Python runtime initialization failed",
                injected_detail,
            )
        )

    # Importing the intrinsic builtins module is the acquisition step. If it
    # fails, no initialized runtime exists and callers must use exit 3.
    var builtins: PythonObject
    try:
        builtins = Python.import_module("builtins")
    except initialization_error:
        return _failure(
            _diagnostic(
                source,
                ConfigFailureKind.INITIALIZATION,
                "Python runtime initialization failed",
                String(initialization_error),
            )
        )

    # `tomllib` exists throughout the declared Python >=3.11 runtime floor.
    # Keeping this class distinct prevents an impossible packaging failure from
    # being mislabeled as invalid user configuration.
    var tomllib: PythonObject
    try:
        tomllib = Python.import_module("tomllib")
    except import_error:
        return _failure(
            _diagnostic(
                source,
                ConfigFailureKind.TOMLLIB_IMPORT,
                "stdlib tomllib import failed despite Python >=3.11",
                String(import_error),
            )
        )

    if injected_kind == ConfigFailureKind.DOCUMENT:
        return _failure(
            _diagnostic(
                source,
                ConfigFailureKind.DOCUMENT,
                "TOML parse failed",
                injected_detail,
            )
        )

    try:
        var document = tomllib.loads(toml_text)
        var dict_type = builtins.dict
        var list_type = builtins.list
        var str_type = builtins.str
        var int_type = builtins.int
        var bool_type = builtins.bool

        if not Python.type(document).__is__(dict_type):
            var got = _safe_repr(String(py=builtins.repr(document)))
            return _invalid(source, "document", "table", got)

        var top_keys = builtins.list(document.keys())
        for i in range(len(top_keys)):
            var key = String(py=top_keys[i])
            if (
                key != "run"
                and key != "build"
                and key != "report"
                and key != "override"
            ):
                return _failure(
                    _diagnostic(
                        source,
                        ConfigFailureKind.DOCUMENT,
                        "unknown top-level table '"
                        + _escape_c0(key)
                        + "'; expected [run], [build], [report], or"
                        " [[override]]",
                    )
                )

        var config = FileConfig.empty()

        if "run" in document:
            var run_table = document["run"]
            if not Python.type(run_table).__is__(dict_type):
                var got = _safe_repr(String(py=builtins.repr(run_table)))
                return _invalid(source, "[run]", "table", got)

            var run_keys = builtins.list(run_table.keys())
            for i in range(len(run_keys)):
                var key = String(py=run_keys[i])
                if (
                    key != "paths"
                    and key != "exclude"
                    and key != "gates"
                    and key != "serial"
                    and key != "workers"
                    and key != "timeout"
                    and key != "retries"
                    and key != "maxfail"
                    and key != "state"
                ):
                    var value = run_table[key]
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _unknown(
                        source,
                        "[run]",
                        key,
                        (
                            "paths, exclude, gates, serial, workers, timeout,"
                            " retries, maxfail, or state"
                        ),
                        got,
                    )

            var run_list_keys = ["paths", "exclude", "gates", "serial"]
            for key in run_list_keys:
                if key not in run_table:
                    continue
                var value = run_table[key]
                var location = "[run] key '" + key + "'"
                if not Python.type(value).__is__(list_type):
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid_string_array(source, location, got)
                var values = List[String]()
                for i in range(len(value)):
                    var item = value[i]
                    if not Python.type(item).__is__(str_type):
                        var got = _safe_repr(String(py=builtins.repr(value)))
                        return _invalid_string_array(source, location, got)
                    var spelling = String(py=item)
                    if key == "paths" and "::" in spelling:
                        return _failure(
                            _diagnostic(
                                source,
                                ConfigFailureKind.DOCUMENT,
                                location
                                + ": node-id-shaped path is not allowed;"
                                " expected filesystem path without '::'; got "
                                + _safe_repr(String(py=builtins.repr(item))),
                            )
                        )
                    values.append(spelling^)
                if key == "paths":
                    config.paths = values^
                    config.saw_paths = True
                elif key == "exclude":
                    config.excludes = values^
                    config.saw_excludes = True
                elif key == "gates":
                    config.gates = values^
                    config.saw_gates = True
                else:
                    config.serial_globs = values^
                    config.saw_serial = True

            if "workers" in run_table:
                var value = run_table["workers"]
                var parsed_workers = Optional[Int](None)
                if Python.type(value).__is__(int_type):
                    parsed_workers = _parse_worker_count_bounded(
                        String(py=builtins.str(value))
                    )
                elif Python.type(value).__is__(str_type):
                    var spelling = String(py=value)
                    if spelling == "auto":
                        parsed_workers = _parse_worker_count_bounded(spelling)
                if not parsed_workers:
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[run] key 'workers'",
                        "positive integer or 'auto'",
                        got,
                    )
                config.workers = parsed_workers.value()
                config.saw_workers = True

            var run_numeric_keys = ["timeout", "retries", "maxfail"]
            for key in run_numeric_keys:
                if key not in run_table:
                    continue
                var value = run_table[key]
                var parsed = Optional[Int](None)
                if Python.type(value).__is__(int_type):
                    parsed = _parse_nonnegative_bounded(
                        String(py=builtins.str(value))
                    )
                if not parsed:
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid_nonnegative(
                        source,
                        "[run] key '" + key + "'",
                        got,
                    )
                if key == "timeout":
                    config.timeout_secs = parsed.value()
                    config.saw_timeout = True
                elif key == "retries":
                    config.retries = parsed.value()
                    config.saw_retries = True
                else:
                    config.maxfail = parsed.value()
                    config.saw_maxfail = True

            if "state" in run_table:
                var value = run_table["state"]
                if not Python.type(value).__is__(bool_type):
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[run] key 'state'",
                        "boolean",
                        got,
                    )
                config.state = Bool(py=value)
                config.saw_state = True

        if "build" in document:
            var build_table = document["build"]
            if not Python.type(build_table).__is__(dict_type):
                var got = _safe_repr(String(py=builtins.repr(build_table)))
                return _invalid(source, "[build]", "table", got)

            var build_keys = builtins.list(build_table.keys())
            for i in range(len(build_keys)):
                var key = String(py=build_keys[i])
                if (
                    key != "mojo"
                    and key != "include"
                    and key != "build-args"
                    and key != "precompile"
                    and key != "compile-timeout"
                ):
                    var value = build_table[key]
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _unknown(
                        source,
                        "[build]",
                        key,
                        (
                            "mojo, include, build-args, precompile, or"
                            " compile-timeout"
                        ),
                        got,
                    )

            if "mojo" in build_table:
                var value = build_table["mojo"]
                if not Python.type(value).__is__(str_type):
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[build] key 'mojo'",
                        "string",
                        got,
                    )
                config.mojo_path = String(py=value)
                config.saw_mojo = True

            var build_list_keys = ["include", "build-args", "precompile"]
            for key in build_list_keys:
                if key not in build_table:
                    continue
                var value = build_table[key]
                var location = "[build] key '" + key + "'"
                var expected = String("array of strings")
                if key == "precompile":
                    expected = "array of SRC[:OUT]"
                if not Python.type(value).__is__(list_type):
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(source, location, expected, got)
                var string_values = List[String]()
                var precompile_values = List[Precompile]()
                for i in range(len(value)):
                    var item = value[i]
                    if not Python.type(item).__is__(str_type):
                        var got = _safe_repr(String(py=builtins.repr(value)))
                        return _invalid(source, location, expected, got)
                    var spelling = String(py=item)
                    if key == "precompile":
                        var parsed = parse_precompile_value(spelling)
                        if not parsed:
                            var got = _safe_repr(
                                String(py=builtins.repr(value))
                            )
                            return _invalid(source, location, expected, got)
                        precompile_values.append(parsed.value().copy())
                    else:
                        var rejection = build_arg_rejection(spelling)
                        if rejection:
                            var got = _safe_repr(String(py=builtins.repr(item)))
                            return _forbidden_build_argument(
                                source,
                                location,
                                rejection.value(),
                                got,
                            )
                        string_values.append(spelling^)
                if key == "include":
                    config.include_paths = string_values^
                    config.saw_include = True
                elif key == "build-args":
                    config.build_args = string_values^
                    config.saw_build_args = True
                else:
                    config.precompiles = precompile_values^
                    config.saw_precompile = True

            if "compile-timeout" in build_table:
                var value = build_table["compile-timeout"]
                var parsed = Optional[Int](None)
                if Python.type(value).__is__(int_type):
                    parsed = _parse_nonnegative_bounded(
                        String(py=builtins.str(value))
                    )
                if not parsed:
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid_nonnegative(
                        source,
                        "[build] key 'compile-timeout'",
                        got,
                    )
                config.compile_timeout_secs = parsed.value()
                config.saw_compile_timeout = True

        if "report" in document:
            var report_table = document["report"]
            if not Python.type(report_table).__is__(dict_type):
                var got = _safe_repr(String(py=builtins.repr(report_table)))
                return _invalid(source, "[report]", "table", got)

            var report_keys = builtins.list(report_table.keys())
            for i in range(len(report_keys)):
                var key = String(py=report_keys[i])
                if (
                    key != "color"
                    and key != "show-output"
                    and key != "verbosity"
                    and key != "durations"
                    and key != "junit-xml"
                    and key != "json"
                    and key != "gh-annotations"
                ):
                    var value = report_table[key]
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _unknown(
                        source,
                        "[report]",
                        key,
                        (
                            "color, show-output, verbosity, durations,"
                            " junit-xml, json, or gh-annotations"
                        ),
                        got,
                    )

            if "color" in report_table:
                var value = report_table["color"]
                var parsed = parse_color_value("")
                if Python.type(value).__is__(str_type):
                    parsed = parse_color_value(String(py=value))
                if not parsed:
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[report] key 'color'",
                        "auto|always|never",
                        got,
                    )
                config.color = parsed.value()
                config.saw_color = True

            if "show-output" in report_table:
                var value = report_table["show-output"]
                var parsed = parse_show_output_value("")
                if Python.type(value).__is__(str_type):
                    parsed = parse_show_output_value(String(py=value))
                if not parsed:
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[report] key 'show-output'",
                        "failures|all|none",
                        got,
                    )
                config.show_output = parsed.value()
                config.saw_show_output = True

            if "verbosity" in report_table:
                var value = report_table["verbosity"]
                var parsed = parse_verbosity_value("")
                if Python.type(value).__is__(str_type):
                    parsed = parse_verbosity_value(String(py=value))
                if not parsed:
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[report] key 'verbosity'",
                        "quiet|normal|verbose",
                        got,
                    )
                config.verbosity = parsed.value()
                config.saw_verbosity = True

            if "durations" in report_table:
                var value = report_table["durations"]
                var parsed = Optional[Int](None)
                if Python.type(value).__is__(int_type):
                    parsed = _parse_nonnegative_bounded(
                        String(py=builtins.str(value))
                    )
                if not parsed:
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid_nonnegative(
                        source,
                        "[report] key 'durations'",
                        got,
                    )
                config.durations = parsed.value()
                config.saw_durations = True

            if "junit-xml" in report_table:
                var value = report_table["junit-xml"]
                if not Python.type(value).__is__(str_type):
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[report] key 'junit-xml'",
                        "non-empty string",
                        got,
                    )
                var destination = String(py=value)
                if destination.byte_length() == 0:
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[report] key 'junit-xml'",
                        "non-empty string",
                        got,
                    )
                config.junit_dest = destination^
                config.saw_junit_xml = True

            if "json" in report_table:
                var value = report_table["json"]
                if not Python.type(value).__is__(str_type):
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[report] key 'json'",
                        "non-empty string or '-'",
                        got,
                    )
                var destination = String(py=value)
                if destination.byte_length() == 0:
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[report] key 'json'",
                        "non-empty string or '-'",
                        got,
                    )
                config.json_dest = destination^
                config.saw_json = True

            if "gh-annotations" in report_table:
                var value = report_table["gh-annotations"]
                var parsed = parse_annotations_value("")
                if Python.type(value).__is__(str_type):
                    parsed = parse_annotations_value(String(py=value))
                if not parsed:
                    var got = _safe_repr(String(py=builtins.repr(value)))
                    return _invalid(
                        source,
                        "[report] key 'gh-annotations'",
                        "off|on|auto",
                        got,
                    )
                config.gh_annotations = parsed.value()
                config.saw_gh_annotations = True

        if "override" in document:
            var override_tables = document["override"]
            if not Python.type(override_tables).__is__(list_type):
                var got = _safe_repr(String(py=builtins.repr(override_tables)))
                return _invalid(
                    source,
                    "[[override]]",
                    "array of tables",
                    got,
                )
            if len(override_tables) == 0:
                return _invalid(
                    source,
                    "[[override]]",
                    "at least one table",
                    "[]",
                )

            for index in range(len(override_tables)):
                var table = override_tables[index]
                var location = "[[override]] #" + String(index + 1)
                if not Python.type(table).__is__(dict_type):
                    var got = _safe_repr(String(py=builtins.repr(table)))
                    return _invalid(source, location, "table", got)

                var keys = builtins.list(table.keys())
                for i in range(len(keys)):
                    var key = String(py=keys[i])
                    if (
                        key != "files"
                        and key != "timeout"
                        and key != "compile-timeout"
                        and key != "retries"
                        and key != "serial"
                    ):
                        var value = table[key]
                        var got = _safe_repr(String(py=builtins.repr(value)))
                        return _unknown(
                            source,
                            location,
                            key,
                            (
                                "files, timeout, compile-timeout, retries, or"
                                " serial"
                            ),
                            got,
                        )

                if "files" not in table:
                    return _invalid(
                        source,
                        location + " key 'files'",
                        "non-empty string or non-empty array of strings",
                        "<absent>",
                    )

                var rule = OverrideRule.empty()
                var files_value = table["files"]
                if Python.type(files_value).__is__(str_type):
                    var file = String(py=files_value)
                    if file.byte_length() == 0:
                        var got = _safe_repr(
                            String(py=builtins.repr(files_value))
                        )
                        return _invalid(
                            source,
                            location + " key 'files'",
                            "non-empty string or non-empty array of strings",
                            got,
                        )
                    rule.files.append(file^)
                elif Python.type(files_value).__is__(list_type):
                    if len(files_value) == 0:
                        return _invalid(
                            source,
                            location + " key 'files'",
                            "non-empty string or non-empty array of strings",
                            "[]",
                        )
                    for i in range(len(files_value)):
                        var item = files_value[i]
                        if not Python.type(item).__is__(str_type):
                            var got = _safe_repr(
                                String(py=builtins.repr(files_value))
                            )
                            return _invalid(
                                source,
                                location + " key 'files'",
                                (
                                    "non-empty string or non-empty array of"
                                    " strings"
                                ),
                                got,
                            )
                        var file = String(py=item)
                        if file.byte_length() == 0:
                            var got = _safe_repr(
                                String(py=builtins.repr(files_value))
                            )
                            return _invalid(
                                source,
                                location + " key 'files'",
                                (
                                    "non-empty string or non-empty array of"
                                    " strings"
                                ),
                                got,
                            )
                        rule.files.append(file^)
                else:
                    var got = _safe_repr(String(py=builtins.repr(files_value)))
                    return _invalid(
                        source,
                        location + " key 'files'",
                        "non-empty string or non-empty array of strings",
                        got,
                    )

                var override_numeric_keys = [
                    "timeout",
                    "compile-timeout",
                    "retries",
                ]
                for key in override_numeric_keys:
                    if key not in table:
                        continue
                    var value = table[key]
                    var parsed = Optional[Int](None)
                    if Python.type(value).__is__(int_type):
                        parsed = _parse_nonnegative_bounded(
                            String(py=builtins.str(value))
                        )
                    if not parsed:
                        var got = _safe_repr(String(py=builtins.repr(value)))
                        return _invalid_nonnegative(
                            source,
                            location + " key '" + key + "'",
                            got,
                        )
                    if key == "timeout":
                        rule.timeout_secs = parsed.value()
                        rule.saw_timeout = True
                    elif key == "compile-timeout":
                        rule.compile_timeout_secs = parsed.value()
                        rule.saw_compile_timeout = True
                    else:
                        rule.retries = parsed.value()
                        rule.saw_retries = True

                if "serial" in table:
                    var value = table["serial"]
                    if not Python.type(value).__is__(bool_type):
                        var got = _safe_repr(String(py=builtins.repr(value)))
                        return _invalid(
                            source,
                            location + " key 'serial'",
                            "boolean",
                            got,
                        )
                    rule.serial = Bool(py=value)
                    rule.saw_serial = True

                if not (
                    rule.saw_timeout
                    or rule.saw_compile_timeout
                    or rule.saw_retries
                    or (rule.saw_serial and rule.serial)
                ):
                    return _failure(
                        _diagnostic(
                            source,
                            ConfigFailureKind.DOCUMENT,
                            location
                            + ": must set timeout, compile-timeout, retries,"
                            " or serial = true",
                        )
                    )
                config.overrides.append(rule^)

        return _success(config^)
    except runtime_error:
        return _failure(
            _diagnostic(
                source,
                ConfigFailureKind.DOCUMENT,
                "TOML parse failed",
                String(runtime_error),
            )
        )


def parse_toml(toml_text: String, source: String) -> TomlParseResult:
    """Parse TOML text lazily into typed file configuration.

    Args:
        toml_text: The complete TOML document text. Not mutated.
        source: The file path or test label used in every diagnostic.

    Returns:
        A typed file model on success, or a contained diagnostic classified
        for exit 3 or 4. Initializes Python only when this function is called.
    """
    return _parse_toml_with_python(
        toml_text,
        source,
        ConfigFailureKind.NONE,
        "",
    )


def parse_toml_with_injected_failure(
    toml_text: String,
    source: String,
    kind: ConfigFailureKind,
    detail: String,
) -> TomlParseResult:
    """Inject one bridge failure for containment and exit-class tests.

    `INITIALIZATION` fails before interpreter acquisition. `DOCUMENT` acquires
    the runtime and imports `tomllib` before returning the injected parse
    failure. Other kinds perform a real parse.

    Args:
        toml_text: The document used when no supported failure is injected.
        source: The source label used in the normalized diagnostic.
        kind: The failure point to inject.
        detail: Hostile foreign detail text to contain.

    Returns:
        A normalized failure for a supported injection, otherwise a real parse
        result. Allocates the result and diagnostic strings.
    """
    return _parse_toml_with_python(toml_text, source, kind, detail)
