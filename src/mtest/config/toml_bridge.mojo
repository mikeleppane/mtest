"""Typed `mtest.toml` conversion over the vendored native parser.

The vendored parser owns only TOML syntax and generic values. This module owns
every accepted table, key, type, domain, and diagnostic. It is pure Mojo and
performs no process or file I/O.
"""
from toml import TomlValue, parse

from mtest.config.file_config import FileConfig, OverrideRule
from mtest.config.precompile import Precompile
from mtest.model.control_chars import is_interpreted_control
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

comptime TOML_SOURCE_MAX_BYTES = 4 * 1024 * 1024
"""The maximum UTF-8 source size accepted by the native parser."""
comptime _TOML_MAX_DEPTH = 64
"""The maximum structural nesting depth accepted before parsing."""
comptime _TOML_MAX_NODES = 16_384
"""The maximum structural nodes (`[`, `{`, `=`, `,`) accepted before parsing.

Sized above anything the documented schema expresses. A budget of 1,024 would
refuse an ordinary `[run] exclude` list of about a thousand globs, which a
generated-test project reaches without doing anything unusual. The bound
still exists because the pre-scan is what keeps pathological input from
reaching the parser at all, and it stays well under the adversarial corpus so
that corpus keeps tripping it cheaply.
"""
comptime _TOML_MAX_TABLE_UPDATES = 512
"""The maximum top-level table headers and assignments accepted.

The pre-scan counts every top-level `[` and every depth-zero `=`, so this is
an assignment budget, not a table-count budget. A budget of 64 would refuse
the documented key set plus eight `[[override]]` tables, a configuration §25
describes as valid. 512 clears roughly eighty such tables, far past any real
project, while staying small enough that the adversarial corpus can prove the
ceiling cheaply: the parser costs milliseconds per assignment.
"""
comptime _TOML_MAX_SCALAR_BYTES = 1024 * 1024
"""The maximum bytes accepted in a single scalar token."""


@fieldwise_init
struct ConfigFailureKind(Equatable, ImplicitlyCopyable, Movable):
    """One caller-visible failure class from the TOML boundary."""

    var value: Int
    """The stable integer discriminant identifying this class."""

    comptime NONE = Self(0)
    comptime DOCUMENT = Self(1)

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
    """Optional unstable parser detail, empty when absent."""

    def exit_code(self) -> Int:
        """Return the owned usage-error exit for selected-config failures.

        Returns:
            `4`, the usage-error exit domain every selected-config failure
            reports under.
        """
        return 4

    def render(self) -> String:
        """Render owned framing with at most one control-escaped detail line.

        Returns:
            The framing alone when no detail is present, otherwise the framing
            followed by one indented detail line.
        """
        if self.detail.byte_length() == 0:
            return self.framing.copy()
        return (
            self.framing
            + "\n  detail (unstable, from the TOML parser): "
            + self.detail
        )

    @staticmethod
    def empty() -> Self:
        """Build the placeholder carried by a successful parse result.

        Returns:
            A diagnostic whose kind is `NONE` and whose framing and detail are
            both empty.
        """
        return Self(ConfigFailureKind.NONE, "", "")


@fieldwise_init
struct TomlParseResult(Copyable, Movable):
    """A typed file config or one contained parser diagnostic."""

    var is_ok: Bool
    """Whether `config` contains the successfully converted document."""
    var config: FileConfig
    """The converted file layer, or an empty placeholder on failure."""
    var failure: ConfigDiagnostic
    """The failure, or an empty placeholder on success."""


def _escape_controls(text: String) -> String:
    """Neutralize every terminal-interpreted control in one diagnostic.

    A config diagnostic quotes `mtest.toml`'s own bytes (the source label, an
    offending key, a rejected value), and `main` prints it to stderr, so it is
    a terminal surface carrying text from a file the user may not have written.
    The set escaped is `mtest.model.control_chars`'s: the C0 controls, DEL, and
    the C1 controls `U+0080..U+009F`.

    C1 matters most here. TOML forbids a raw C0 control inside a basic string,
    so the parser rejects ESC before it reaches a diagnostic. But C1 is a legal
    TOML string character, and `U+009B` is CSI, `U+009D` is OSC and `U+009C` is
    ST in their single-code-point form. A hostile `mtest.toml` therefore drives
    the terminal through the very message that rejects it, with no ESC byte
    anywhere in the file.

    Args:
        text: Untrusted diagnostic text, already valid UTF-8.

    Returns:
        `text` with every interpreted control replaced by visible escape text,
        rendering it single-line so a value cannot forge a diagnostic line.
    """
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
        elif is_interpreted_control(value, preserve_lf_tab=False):
            escaped += "\\x"
            escaped += String(HEX[byte=value // 16])
            escaped += String(HEX[byte=value % 16])
        else:
            escaped += String(cp)
    return escaped


def _safe_repr(representation: String) -> String:
    var escaped = _escape_controls(representation)
    if escaped.count_codepoints() <= 240:
        return escaped
    var shortened = String("")
    var count = 0
    for cp in escaped.codepoint_slices():
        if count == 237:
            break
        shortened += String(cp)
        count += 1
    return shortened + "..."


def _source_scan_kind(text: String) -> Int:
    var whitespace_only = True
    for byte in text.as_bytes():
        if byte == UInt8(0):
            return 2
        if (
            byte != UInt8(ord(" "))
            and byte != UInt8(ord("\t"))
            and byte != UInt8(ord("\n"))
            and byte != UInt8(ord("\r"))
        ):
            whitespace_only = False
    return 1 if whitespace_only else 0


def _source_complexity_error(text: String) -> Optional[String]:
    """Check scalar, container-depth, and node bounds without tokenizing."""
    var bytes = text.as_bytes()
    var index = 0
    var depth = 0
    var nodes = 0
    var table_updates = 0
    var scalar_bytes = 0
    var quote = UInt8(0)
    var triple = False
    var comment = False
    var line_has_content = False
    while index < len(bytes):
        var byte = bytes[index]
        if comment:
            if byte == UInt8(ord("\n")):
                comment = False
                scalar_bytes = 0
                line_has_content = False
            else:
                scalar_bytes += 1
                if scalar_bytes > _TOML_MAX_SCALAR_BYTES:
                    return Optional[String](
                        "TOML token exceeds "
                        + String(_TOML_MAX_SCALAR_BYTES)
                        + "-byte limit"
                    )
            index += 1
            continue
        if quote != UInt8(0):
            scalar_bytes += 1
            if scalar_bytes > _TOML_MAX_SCALAR_BYTES:
                return Optional[String](
                    "TOML scalar exceeds "
                    + String(_TOML_MAX_SCALAR_BYTES)
                    + "-byte limit"
                )
            if (
                quote == UInt8(ord('"'))
                and byte == UInt8(ord("\\"))
                and index + 1 < len(bytes)
            ):
                scalar_bytes += 1
                if scalar_bytes > _TOML_MAX_SCALAR_BYTES:
                    return Optional[String](
                        "TOML scalar exceeds "
                        + String(_TOML_MAX_SCALAR_BYTES)
                        + "-byte limit"
                    )
                index += 2
                continue
            if byte == quote:
                if triple:
                    if (
                        index + 2 < len(bytes)
                        and bytes[index + 1] == quote
                        and bytes[index + 2] == quote
                    ):
                        quote = UInt8(0)
                        triple = False
                        scalar_bytes = 0
                        index += 3
                        continue
                else:
                    quote = UInt8(0)
                    scalar_bytes = 0
            index += 1
            continue
        if byte == UInt8(ord("#")):
            comment = True
            scalar_bytes = 0
        elif byte == UInt8(ord('"')) or byte == UInt8(ord("'")):
            quote = byte
            scalar_bytes = 0
            line_has_content = True
            if (
                index + 2 < len(bytes)
                and bytes[index + 1] == byte
                and bytes[index + 2] == byte
            ):
                triple = True
                index += 2
        elif byte == UInt8(ord("[")) or byte == UInt8(ord("{")):
            if byte == UInt8(ord("[")) and depth == 0 and not line_has_content:
                table_updates += 1
                if table_updates > _TOML_MAX_TABLE_UPDATES:
                    return Optional[String](
                        "TOML table-update limit exceeded: at most "
                        + String(_TOML_MAX_TABLE_UPDATES)
                        + " top-level headers and assignments"
                    )
            line_has_content = True
            depth += 1
            nodes += 1
            if depth > _TOML_MAX_DEPTH:
                return Optional[String](
                    "TOML nesting limit exceeded: at most "
                    + String(_TOML_MAX_DEPTH)
                    + " levels"
                )
        elif byte == UInt8(ord("]")) or byte == UInt8(ord("}")):
            line_has_content = True
            if depth > 0:
                depth -= 1
        elif byte == UInt8(ord("=")):
            nodes += 1
            scalar_bytes = 0
            line_has_content = True
            if depth == 0:
                table_updates += 1
                if table_updates > _TOML_MAX_TABLE_UPDATES:
                    return Optional[String](
                        "TOML table-update limit exceeded: at most "
                        + String(_TOML_MAX_TABLE_UPDATES)
                        + " top-level headers and assignments"
                    )
        elif byte == UInt8(ord(",")):
            nodes += 1
            scalar_bytes = 0
            line_has_content = True
        elif (
            byte == UInt8(ord(" "))
            or byte == UInt8(ord("\t"))
            or byte == UInt8(ord("\n"))
            or byte == UInt8(ord("\r"))
        ):
            scalar_bytes = 0
            if byte == UInt8(ord("\n")):
                line_has_content = False
        else:
            line_has_content = True
            scalar_bytes += 1
            if scalar_bytes > _TOML_MAX_SCALAR_BYTES:
                return Optional[String](
                    "TOML scalar exceeds "
                    + String(_TOML_MAX_SCALAR_BYTES)
                    + "-byte limit"
                )
        if nodes > _TOML_MAX_NODES:
            return Optional[String](
                "TOML complexity limit exceeded: at most "
                + String(_TOML_MAX_NODES)
                + " structural nodes"
            )
        index += 1
    return Optional[String](None)


def _diagnostic(
    source: String,
    kind: ConfigFailureKind,
    summary: String,
    detail: String = "",
) -> ConfigDiagnostic:
    return ConfigDiagnostic(
        kind,
        "config: "
        + _escape_controls(source)
        + ": "
        + _escape_controls(summary),
        _safe_repr(detail) if detail.byte_length() > 0 else String(""),
    )


def _success(var config: FileConfig) -> TomlParseResult:
    return TomlParseResult(True, config^, ConfigDiagnostic.empty())


def _failure(var diagnostic: ConfigDiagnostic) -> TomlParseResult:
    return TomlParseResult(False, FileConfig.empty(), diagnostic^)


def _invalid(
    source: String, location: String, expected: String, got: String
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
            + _escape_controls(key)
            + "': unknown key; expected "
            + expected
            + "; got "
            + got,
        )
    )


def _invalid_string_array(
    source: String, location: String, got: String
) -> TomlParseResult:
    return _invalid(source, location, "array of strings", got)


def _invalid_nonnegative(
    source: String, location: String, got: String
) -> TomlParseResult:
    return _invalid(source, location, "integer >= 0", got)


def _forbidden_build_argument(
    source: String, location: String, rejection: String, got: String
) -> TomlParseResult:
    return _failure(
        _diagnostic(
            source,
            ConfigFailureKind.DOCUMENT,
            location + ": " + _safe_repr(rejection) + "; got " + got,
        )
    )


def _keys(value: TomlValue) -> List[String]:
    var keys = List[String]()
    for entry in value.table_value.items():
        keys.append(entry.key)
    return keys^


def _contains(value: TomlValue, key: String) -> Bool:
    return value.table_value.__contains__(key)


def _get(value: TomlValue, key: String) raises -> TomlValue:
    return value.table_value[key].copy()


def _got(value: TomlValue) -> String:
    if value.is_string():
        return _safe_repr("'" + value.string_value + "'")
    if value.is_int():
        return String(value.int_value)
    if value.is_float():
        return String(value.float_value)
    if value.is_bool():
        return "True" if value.bool_value else "False"
    if value.is_array():
        var out = String("[")
        for i in range(len(value.array_value)):
            if i > 0:
                out += ", "
            out += _got(value.array_value[i])
        return _safe_repr(out + "]")
    var out = String("{")
    var index = 0
    for entry in value.table_value.items():
        if index > 0:
            out += ", "
        out += "'" + entry.key + "': " + _got(entry.value)
        index += 1
    return _safe_repr(out + "}")


def _convert_document(
    document: TomlValue, source: String
) raises -> TomlParseResult:
    if not document.is_table():
        return _invalid(source, "document", "table", _got(document))
    for key in _keys(document):
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
                    + _escape_controls(key)
                    + "'; expected [run], [build], [report], or [[override]]",
                )
            )

    var config = FileConfig.empty()

    if _contains(document, "run"):
        var table = _get(document, "run")
        if not table.is_table():
            return _invalid(source, "[run]", "table", _got(table))
        for key in _keys(table):
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
                and key != "fail-on-flaky"
            ):
                var value = _get(table, key)
                return _unknown(
                    source,
                    "[run]",
                    key,
                    (
                        "paths, exclude, gates, serial, workers, timeout,"
                        " retries, maxfail, state, or fail-on-flaky"
                    ),
                    _got(value),
                )

        for key in ["paths", "exclude", "gates", "serial"]:
            if not _contains(table, key):
                continue
            var value = _get(table, key)
            var location = "[run] key '" + key + "'"
            if not value.is_array():
                return _invalid_string_array(source, location, _got(value))
            var values = List[String]()
            for item in value.array_value:
                if not item.is_string():
                    return _invalid_string_array(source, location, _got(value))
                var spelling = item.string_value.copy()
                if key == "paths" and "::" in spelling:
                    return _failure(
                        _diagnostic(
                            source,
                            ConfigFailureKind.DOCUMENT,
                            location
                            + ": node-id-shaped path is not allowed; expected"
                            " filesystem path without '::'; got "
                            + _got(item),
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

        if _contains(table, "workers"):
            var value = _get(table, "workers")
            var parsed = Optional[Int](None)
            if value.is_int():
                parsed = parse_worker_count(String(value.int_value))
            elif value.is_string() and value.string_value == "auto":
                parsed = parse_worker_count(value.string_value)
            if not parsed:
                return _invalid(
                    source,
                    "[run] key 'workers'",
                    "positive integer or 'auto'",
                    _got(value),
                )
            config.workers = parsed.value()
            config.saw_workers = True

        for key in ["timeout", "retries", "maxfail"]:
            if not _contains(table, key):
                continue
            var value = _get(table, key)
            var parsed = Optional[Int](None)
            if value.is_int():
                parsed = parse_nonnegative_decimal(String(value.int_value))
            if not parsed:
                return _invalid_nonnegative(
                    source, "[run] key '" + key + "'", _got(value)
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

        if _contains(table, "state"):
            var value = _get(table, "state")
            if not value.is_bool():
                return _invalid(
                    source, "[run] key 'state'", "boolean", _got(value)
                )
            config.state = value.bool_value
            config.saw_state = True

        if _contains(table, "fail-on-flaky"):
            var value = _get(table, "fail-on-flaky")
            if not value.is_bool():
                return _invalid(
                    source, "[run] key 'fail-on-flaky'", "boolean", _got(value)
                )
            config.fail_on_flaky = value.bool_value
            config.saw_fail_on_flaky = True

    if _contains(document, "build"):
        var table = _get(document, "build")
        if not table.is_table():
            return _invalid(source, "[build]", "table", _got(table))
        for key in _keys(table):
            if (
                key != "mojo"
                and key != "include"
                and key != "build-args"
                and key != "precompile"
                and key != "compile-timeout"
            ):
                var value = _get(table, key)
                return _unknown(
                    source,
                    "[build]",
                    key,
                    "mojo, include, build-args, precompile, or compile-timeout",
                    _got(value),
                )

        if _contains(table, "mojo"):
            var value = _get(table, "mojo")
            if not value.is_string():
                return _invalid(
                    source, "[build] key 'mojo'", "string", _got(value)
                )
            config.mojo_path = value.string_value.copy()
            config.saw_mojo = True

        for key in ["include", "build-args", "precompile"]:
            if not _contains(table, key):
                continue
            var value = _get(table, key)
            var location = "[build] key '" + key + "'"
            var expected = String(
                "array of SRC[:OUT]"
            ) if key == "precompile" else String("array of strings")
            if not value.is_array():
                return _invalid(source, location, expected, _got(value))
            var string_values = List[String]()
            var precompile_values = List[Precompile]()
            for item in value.array_value:
                if not item.is_string():
                    return _invalid(source, location, expected, _got(value))
                var spelling = item.string_value.copy()
                if key == "precompile":
                    var parsed = parse_precompile_value(spelling)
                    if not parsed:
                        return _invalid(source, location, expected, _got(value))
                    precompile_values.append(parsed.value().copy())
                else:
                    var rejection = build_arg_rejection(spelling)
                    if rejection:
                        return _forbidden_build_argument(
                            source,
                            location,
                            rejection.value(),
                            _got(item),
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

        if _contains(table, "compile-timeout"):
            var value = _get(table, "compile-timeout")
            var parsed = Optional[Int](None)
            if value.is_int():
                parsed = parse_nonnegative_decimal(String(value.int_value))
            if not parsed:
                return _invalid_nonnegative(
                    source, "[build] key 'compile-timeout'", _got(value)
                )
            config.compile_timeout_secs = parsed.value()
            config.saw_compile_timeout = True

    if _contains(document, "report"):
        var table = _get(document, "report")
        if not table.is_table():
            return _invalid(source, "[report]", "table", _got(table))
        for key in _keys(table):
            if (
                key != "color"
                and key != "show-output"
                and key != "verbosity"
                and key != "durations"
                and key != "junit-xml"
                and key != "json"
                and key != "gh-annotations"
            ):
                var value = _get(table, key)
                return _unknown(
                    source,
                    "[report]",
                    key,
                    (
                        "color, show-output, verbosity, durations, junit-xml,"
                        " json, or gh-annotations"
                    ),
                    _got(value),
                )

        if _contains(table, "color"):
            var value = _get(table, "color")
            var parsed = parse_color_value("")
            if value.is_string():
                parsed = parse_color_value(value.string_value)
            if not parsed:
                return _invalid(
                    source,
                    "[report] key 'color'",
                    "auto|always|never",
                    _got(value),
                )
            config.color = parsed.value()
            config.saw_color = True

        if _contains(table, "show-output"):
            var value = _get(table, "show-output")
            var parsed = parse_show_output_value("")
            if value.is_string():
                parsed = parse_show_output_value(value.string_value)
            if not parsed:
                return _invalid(
                    source,
                    "[report] key 'show-output'",
                    "failures|all|none",
                    _got(value),
                )
            config.show_output = parsed.value()
            config.saw_show_output = True

        if _contains(table, "verbosity"):
            var value = _get(table, "verbosity")
            var parsed = parse_verbosity_value("")
            if value.is_string():
                parsed = parse_verbosity_value(value.string_value)
            if not parsed:
                return _invalid(
                    source,
                    "[report] key 'verbosity'",
                    "quiet|normal|verbose",
                    _got(value),
                )
            config.verbosity = parsed.value()
            config.saw_verbosity = True

        if _contains(table, "durations"):
            var value = _get(table, "durations")
            var parsed = Optional[Int](None)
            if value.is_int():
                parsed = parse_nonnegative_decimal(String(value.int_value))
            if not parsed:
                return _invalid_nonnegative(
                    source, "[report] key 'durations'", _got(value)
                )
            config.durations = parsed.value()
            config.saw_durations = True

        if _contains(table, "junit-xml"):
            var value = _get(table, "junit-xml")
            if not value.is_string() or value.string_value.byte_length() == 0:
                return _invalid(
                    source,
                    "[report] key 'junit-xml'",
                    "non-empty string",
                    _got(value),
                )
            config.junit_dest = value.string_value.copy()
            config.saw_junit_xml = True

        if _contains(table, "json"):
            var value = _get(table, "json")
            if not value.is_string() or value.string_value.byte_length() == 0:
                return _invalid(
                    source,
                    "[report] key 'json'",
                    "non-empty string or '-'",
                    _got(value),
                )
            config.json_dest = value.string_value.copy()
            config.saw_json = True

        if _contains(table, "gh-annotations"):
            var value = _get(table, "gh-annotations")
            var parsed = parse_annotations_value("")
            if value.is_string():
                parsed = parse_annotations_value(value.string_value)
            if not parsed:
                return _invalid(
                    source,
                    "[report] key 'gh-annotations'",
                    "off|on|auto",
                    _got(value),
                )
            config.gh_annotations = parsed.value()
            config.saw_gh_annotations = True

    if _contains(document, "override"):
        var overrides = _get(document, "override")
        if not overrides.is_array():
            return _invalid(
                source, "[[override]]", "array of tables", _got(overrides)
            )
        if len(overrides.array_value) == 0:
            return _invalid(source, "[[override]]", "at least one table", "[]")
        for index in range(len(overrides.array_value)):
            var table = overrides.array_value[index].copy()
            var location = "[[override]] #" + String(index + 1)
            if not table.is_table():
                return _invalid(source, location, "table", _got(table))
            for key in _keys(table):
                if (
                    key != "files"
                    and key != "timeout"
                    and key != "compile-timeout"
                    and key != "retries"
                    and key != "serial"
                ):
                    var value = _get(table, key)
                    return _unknown(
                        source,
                        location,
                        key,
                        "files, timeout, compile-timeout, retries, or serial",
                        _got(value),
                    )
            if not _contains(table, "files"):
                return _invalid(
                    source,
                    location + " key 'files'",
                    "non-empty string or non-empty array of strings",
                    "<absent>",
                )
            var rule = OverrideRule.empty()
            var files = _get(table, "files")
            if files.is_string():
                if files.string_value.byte_length() == 0:
                    return _invalid(
                        source,
                        location + " key 'files'",
                        "non-empty string or non-empty array of strings",
                        _got(files),
                    )
                rule.files.append(files.string_value.copy())
            elif files.is_array():
                if len(files.array_value) == 0:
                    return _invalid(
                        source,
                        location + " key 'files'",
                        "non-empty string or non-empty array of strings",
                        "[]",
                    )
                for item in files.array_value:
                    if (
                        not item.is_string()
                        or item.string_value.byte_length() == 0
                    ):
                        return _invalid(
                            source,
                            location + " key 'files'",
                            "non-empty string or non-empty array of strings",
                            _got(files),
                        )
                    rule.files.append(item.string_value.copy())
            else:
                return _invalid(
                    source,
                    location + " key 'files'",
                    "non-empty string or non-empty array of strings",
                    _got(files),
                )

            for key in ["timeout", "compile-timeout", "retries"]:
                if not _contains(table, key):
                    continue
                var value = _get(table, key)
                var parsed = Optional[Int](None)
                if value.is_int():
                    parsed = parse_nonnegative_decimal(String(value.int_value))
                if not parsed:
                    return _invalid_nonnegative(
                        source, location + " key '" + key + "'", _got(value)
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

            if _contains(table, "serial"):
                var value = _get(table, "serial")
                if not value.is_bool():
                    return _invalid(
                        source,
                        location + " key 'serial'",
                        "boolean",
                        _got(value),
                    )
                # Serial membership is a union across every matching table, so
                # `false` cannot turn off a pin another table sets. Accepting
                # it would read as a way to exempt a file that it never was.
                if not value.bool_value:
                    return _invalid(
                        source,
                        location + " key 'serial'",
                        "true",
                        "false",
                    )
                rule.serial = value.bool_value
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
                        + ": must set timeout, compile-timeout, retries, or"
                        " serial = true",
                    )
                )
            config.overrides.append(rule^)

    return _success(config^)


def parse_toml(toml_text: String, source: String) -> TomlParseResult:
    """Parse and validate one complete TOML document natively.

    Args:
        toml_text: The UTF-8 TOML source. Not mutated.
        source: The path label used in all owned diagnostics.

    Returns:
        A typed file model or an owned exit-4 syntax/schema diagnostic. No
        parser error escapes.

    Examples:

    ```mojo
    from mtest.config import parse_toml

    var text = "[run]\\ntimeout = 1\\nstate = false\\n"
    var result = parse_toml(text, "fine.toml")
    var ok = result.is_ok and result.config.saw_timeout
    ```
    """
    if toml_text.byte_length() > TOML_SOURCE_MAX_BYTES:
        return _failure(
            _diagnostic(
                source,
                ConfigFailureKind.DOCUMENT,
                "configuration file exceeds "
                + String(TOML_SOURCE_MAX_BYTES)
                + "-byte limit",
            )
        )
    var source_kind = _source_scan_kind(toml_text)
    if source_kind == 2:
        return _failure(
            _diagnostic(
                source,
                ConfigFailureKind.DOCUMENT,
                "TOML parse failed",
                "NUL byte is not valid TOML source",
            )
        )
    if source_kind == 1:
        return _success(FileConfig.empty())
    var complexity_error = _source_complexity_error(toml_text)
    if complexity_error:
        return _failure(
            _diagnostic(
                source,
                ConfigFailureKind.DOCUMENT,
                complexity_error.value(),
            )
        )
    try:
        var document = parse(toml_text)
        return _convert_document(TomlValue(document^), source)
    except error:
        return _failure(
            _diagnostic(
                source,
                ConfigFailureKind.DOCUMENT,
                "TOML parse failed",
                String(error),
            )
        )
