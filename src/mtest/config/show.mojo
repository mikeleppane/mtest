"""Pure TOML rendering for the human-facing `config show` command."""
from mtest.config.annotations_mode import AnnotationsMode
from mtest.config.color_when import ColorWhen
from mtest.config.precompile import Precompile
from mtest.config.provenance import Provenance
from mtest.config.resolve import ResolvedConfig
from mtest.config.show_output import ShowOutput
from mtest.config.verbosity import Verbosity


def _source(source: Provenance) -> String:
    """Render one closed provenance value as its public label."""
    if source == Provenance.MTEST_TOML:
        return "mtest.toml"
    if source == Provenance.ENV_MTEST_MOJO:
        return "env MTEST_MOJO"
    if source == Provenance.CLI:
        return "cli"
    return "default"


def _comment(source: Provenance) -> String:
    """Render the ordinary trailing source comment."""
    return "  # (" + _source(source) + ")\n"


def _toml_string(value: String) -> String:
    """Render `value` as one TOML basic string with control bytes escaped."""
    var rendered = String('"')
    comptime HEX = "0123456789abcdef"
    for cp in value.codepoints():
        var code = Int(cp)
        if code == 8:
            rendered += "\\b"
        elif code == 9:
            rendered += "\\t"
        elif code == 10:
            rendered += "\\n"
        elif code == 12:
            rendered += "\\f"
        elif code == 13:
            rendered += "\\r"
        elif code == 34:
            rendered += '\\"'
        elif code == 92:
            rendered += "\\\\"
        elif (code >= 0 and code < 32) or code == 127:
            rendered += "\\u00"
            rendered += String(HEX[byte=code // 16])
            rendered += String(HEX[byte=code % 16])
        else:
            rendered += String(cp)
    return rendered + '"'


def _string_array(values: List[String]) -> String:
    """Render a list as a TOML basic-string array."""
    var rendered = String("[")
    for i in range(len(values)):
        if i > 0:
            rendered += ", "
        rendered += _toml_string(values[i])
    return rendered + "]"


def _config_paths(values: List[String]) -> List[String]:
    """Copy config-eligible paths while omitting per-invocation node ids."""
    var paths = List[String]()
    for value in values:
        if value.find("::") == -1:
            paths.append(value)
    return paths^


def _precompile_array(values: List[Precompile]) -> String:
    """Render precompile entries in canonical `SRC` or `SRC:OUT` form."""
    var rendered = String("[")
    for i in range(len(values)):
        if i > 0:
            rendered += ", "
        var entry = values[i].src.copy()
        if values[i].out:
            entry += ":" + values[i].out.value()
        rendered += _toml_string(entry)
    return rendered + "]"


def _bool(value: Bool) -> String:
    """Render a TOML boolean."""
    return "true" if value else "false"


def _workers(value: Int) -> String:
    """Render the worker sentinel as `auto`, otherwise as an integer."""
    if value == 0:
        return '"auto"'
    return String(value)


def _color(value: ColorWhen) -> String:
    """Render the accepted lowercase color spelling."""
    if value == ColorWhen.ALWAYS:
        return '"always"'
    if value == ColorWhen.NEVER:
        return '"never"'
    return '"auto"'


def _show_output(value: ShowOutput) -> String:
    """Render the accepted lowercase show-output spelling."""
    if value == ShowOutput.ALL:
        return '"all"'
    if value == ShowOutput.NONE:
        return '"none"'
    return '"failures"'


def _verbosity(value: Verbosity) -> String:
    """Render the accepted lowercase verbosity spelling."""
    if value == Verbosity.QUIET:
        return '"quiet"'
    if value == Verbosity.VERBOSE:
        return '"verbose"'
    return '"normal"'


def _annotations(value: AnnotationsMode) -> String:
    """Render the accepted lowercase annotations spelling."""
    if value == AnnotationsMode.OFF:
        return '"off"'
    if value == AnnotationsMode.ON:
        return '"on"'
    return '"auto"'


def _comment_text(value: String) -> String:
    """Escape physical-line controls in a user-controlled trailer comment."""
    var rendered = String("")
    comptime HEX = "0123456789abcdef"
    for cp in value.codepoints():
        var code = Int(cp)
        if code == 9:
            rendered += "\\t"
        elif code == 10:
            rendered += "\\n"
        elif code == 13:
            rendered += "\\r"
        elif (code >= 0 and code < 32) or code == 127:
            rendered += "\\u00"
            rendered += String(HEX[byte=code // 16])
            rendered += String(HEX[byte=code % 16])
        else:
            rendered += String(cp)
    return rendered^


def render_config_show(resolved: ResolvedConfig, state_present: Bool) -> String:
    """Render resolved configuration as copy-pasteable TOML.

    Args:
        resolved: Effective values, ordered overrides, and provenance. Not
            mutated.
        state_present: Whether `.mtest-cache/lastrun` exists. The state file is
            never read by this function.

    Returns:
        A newly allocated human-facing TOML document in fixed table order.
    """
    var config = resolved.config.copy()
    var sources = resolved.provenance.copy()
    var paths = _config_paths(config.paths)
    var node_ids_omitted = len(paths) != len(config.paths)
    var rendered = String("[run]\n")
    # An unsupplied `paths` renders as a comment, like every other unset key.
    # Rendering it as `paths = []` would be a trap: this output is documented
    # as copy-pasteable, and an explicitly empty list means "select nothing",
    # so pasting it back would silently turn a working default into exit 5.
    if sources.paths == Provenance.DEFAULT:
        rendered += "# paths = (unset — discovery uses tests/, else .)\n"
    else:
        rendered += "paths = " + _string_array(paths) + _comment(sources.paths)
    rendered += (
        "exclude = "
        + _string_array(config.excludes)
        + _comment(sources.excludes)
    )
    rendered += (
        "gates = " + _string_array(config.gates) + _comment(sources.gates)
    )
    rendered += (
        "serial = "
        + _string_array(config.serial_globs)
        + _comment(sources.serial_globs)
    )
    rendered += (
        "workers = " + _workers(config.workers) + _comment(sources.workers)
    )
    rendered += (
        "timeout = "
        + String(config.timeout_secs)
        + _comment(sources.timeout_secs)
    )
    rendered += (
        "retries = " + String(config.retries) + _comment(sources.retries)
    )
    rendered += (
        "maxfail = " + String(config.maxfail) + _comment(sources.maxfail)
    )
    rendered += "state = " + _bool(resolved.state) + _comment(sources.state)

    rendered += "\n[build]\n"
    rendered += (
        "mojo = " + _toml_string(config.mojo_path) + _comment(sources.mojo_path)
    )
    rendered += (
        "include = "
        + _string_array(config.include_paths)
        + _comment(sources.include_paths)
    )
    rendered += (
        "build-args = "
        + _string_array(config.build_args)
        + _comment(sources.build_args)
    )
    rendered += (
        "precompile = "
        + _precompile_array(config.precompiles)
        + _comment(sources.precompiles)
    )
    rendered += (
        "compile-timeout = "
        + String(config.compile_timeout_secs)
        + _comment(sources.compile_timeout_secs)
    )

    rendered += "\n[report]\n"
    rendered += (
        "color = " + _color(config.color) + "  # (" + _source(sources.color)
    )
    if config.color == ColorWhen.AUTO and resolved.no_color:
        rendered += "; NO_COLOR active in this environment"
    rendered += ")\n"
    rendered += (
        "show-output = "
        + _show_output(config.show_output)
        + _comment(sources.show_output)
    )
    rendered += (
        "verbosity = "
        + _verbosity(config.verbosity)
        + _comment(sources.verbosity)
    )
    rendered += (
        "durations = " + String(config.durations) + _comment(sources.durations)
    )
    if config.junit_dest == "":
        rendered += "# junit-xml = (unset)\n"
    else:
        rendered += (
            "junit-xml = "
            + _toml_string(config.junit_dest)
            + _comment(sources.junit_dest)
        )
    if config.json_dest == "":
        rendered += "# json = (unset)\n"
    else:
        rendered += (
            "json = "
            + _toml_string(config.json_dest)
            + _comment(sources.json_dest)
        )
    rendered += (
        "gh-annotations = "
        + _annotations(config.gh_annotations)
        + _comment(sources.gh_annotations)
    )

    for override in resolved.overrides:
        rendered += "\n[[override]]\n"
        if len(override.files) == 1:
            rendered += "files = " + _toml_string(override.files[0])
        else:
            rendered += "files = " + _string_array(override.files)
        rendered += "  # (mtest.toml)\n"
        if override.saw_timeout:
            rendered += (
                "timeout = "
                + String(override.timeout_secs)
                + "  # (mtest.toml)\n"
            )
        if override.saw_compile_timeout:
            rendered += (
                "compile-timeout = "
                + String(override.compile_timeout_secs)
                + "  # (mtest.toml)\n"
            )
        if override.saw_retries:
            rendered += (
                "retries = " + String(override.retries) + "  # (mtest.toml)\n"
            )
        if override.saw_serial:
            rendered += (
                "serial = " + _bool(override.serial) + "  # (mtest.toml)\n"
            )

    rendered += "\n# config file: "
    if resolved.config_file == "":
        rendered += "none\n"
    else:
        rendered += _comment_text(resolved.config_file) + "\n"
    rendered += "# state file: .mtest-cache/lastrun ("
    rendered += "present" if state_present else "absent"
    rendered += ")\n"
    rendered += "# selection flags are per invocation and are not rendered\n"
    if node_ids_omitted:
        # Without this the empty `paths` above reads as "the command line
        # resolved paths to nothing", when in fact node-id operands replaced
        # the configured list and are deliberately not rendered.
        rendered += (
            "# node-id operands replaced [run] paths and are not rendered\n"
        )
    return rendered^
