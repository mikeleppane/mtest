"""The hand-rolled full-contract argument parser.

`parse_args` turns an argument vector into a `ParseResult`: a configured run, a
resolved-config display request, a doctor request, a scaffolding or bootstrap
request, or a help/version directive. Anything it refuses becomes a
`cli:`-prefixed usage error instead.

The parser is hand-rolled by decision. The `prism` argument-parsing library was
evaluated and rejected on source evidence: it has no `--` pass-through, and
repeated flags corrupt values containing spaces. Wrapping it was rejected too.

Every raise names the offending token, states the expected form, and points at
`mtest --help`. This layer never prints and never exits; `main` prints help and
version to stdout with exit 0, and prints a usage error to stderr with exit 4.
"""
from std.os import getenv
from std.os.path import dirname, isdir

from mtest.cli.flag_spec import (
    FlagId,
    FlagSpec,
    flag_group_name,
    flag_specs,
)
from mtest.cli.parse_result import ParseResult
from mtest.model import split_node_token
from mtest.config import (
    AnnotationsMode,
    CliOverlay,
    ColorWhen,
    Precompile,
    ReportStyle,
    RunnerConfig,
    ShardMode,
    ShowOutput,
    Verbosity,
    build_arg_rejection,
    parse_annotations_value,
    parse_color_value,
    parse_nonnegative_decimal,
    parse_precompile_value,
    parse_report_style_value,
    parse_report_value,
    parse_show_output_value,
    parse_worker_count,
    resolve_mojo_path,
    safe_path_label,
)

comptime MTEST_VERSION = "1.0.0"
"""The single source of the version string; `main` reuses this exact value.

`pixi run version-check` asserts it agrees with `pixi.toml`, with
`recipe/recipe.yaml`, and with the version this repo ships.
"""

comptime _HELP_COLUMN = 30


def version_text() -> String:
    """The version line `main` prints for `--version` / `version`."""
    return "mtest " + MTEST_VERSION


def _help_row(label: String, detail: String) -> String:
    """Render one aligned, single-line help row."""
    var row = "  " + label
    for _ in range(_HELP_COLUMN - row.count_codepoints()):
        row += " "
    return row + detail + "\n"


def help_text() -> String:
    """Build grouped usage text from the flag-spec table.

    Returns:
        The freshly allocated text printed for `--help`, `-h`, and `help`.
    """
    var rendered = String(
        "mtest — a pytest-like test runner for Mojo\n\n",
        "usage: mtest [run] [PATHS...] [flags] [-- BUILD-ARGS...]\n",
        "       mtest collect [PATHS...] [--format lines|json] [flags]\n",
        "       mtest config show [PATHS...] [flags] [-- BUILD-ARGS...]\n",
        (
            "       mtest doctor [--config PATH | --no-config]"
            " [--color WHEN] [-q | -v]\n"
        ),
        "       mtest debug PATH::TEST [build flags] [-- BUILD-ARGS...]\n",
        "       mtest new PATH\n",
        "       mtest init [--ci github]\n\n",
        "Subcommands:\n",
    )
    rendered += _help_row(
        "run [PATHS...] [flags]", "Run tests (the default subcommand)."
    )
    rendered += _help_row(
        "collect [PATHS...] [flags]", "List node ids without running tests."
    )
    rendered += _help_row(
        "config show [PATHS...]",
        "Show resolved configuration.",
    )
    rendered += _help_row(
        "doctor [flags]", "Diagnose the environment without running tests."
    )
    rendered += _help_row(
        "debug PATH::TEST", "Run one test with the terminal handed over."
    )
    rendered += _help_row("new PATH", "Create one runnable test file.")
    rendered += _help_row(
        "init [--ci github]", "Bootstrap a project in this directory."
    )
    rendered += _help_row("help", "Show this help and exit.")
    rendered += _help_row("version", "Show the version and exit.")

    var current_group = -1
    var specs = flag_specs()
    var index = 0
    while index < len(specs):
        var spec = specs[index].copy()
        if spec.group != current_group:
            rendered += "\n" + flag_group_name(spec.group) + ":\n"
            current_group = spec.group
        var label = spec.spelling.copy()
        var next_index = index + 1
        while next_index < len(specs) and specs[next_index].id == spec.id:
            label += ", " + specs[next_index].spelling
            next_index += 1
        if spec.value_name != "":
            label += " " + spec.value_name
        rendered += _help_row(label^, spec.help)
        index = next_index
    return rendered^


# --- error builders (every message is `cli:`-prefixed and points at help) ---


def _err(body: String) -> Error:
    """A `cli:`-prefixed usage error ending in the `(see mtest --help)` tail."""
    return Error("cli: " + body + " (see mtest --help)")


# --- value validation ---


def _parse_timeout(value: String) raises -> Int:
    """Parse a `--timeout` value: a non-negative integer (`0` disables)."""
    var parsed = parse_nonnegative_decimal(value)
    if not parsed:
        raise _err("'--timeout' wants an integer >= 0, got '" + value + "'")
    return parsed.value()


def _parse_maxfail(value: String) raises -> Int:
    """Parse a `--maxfail` value: a non-negative integer (`0` disables)."""
    var parsed = parse_nonnegative_decimal(value)
    if not parsed:
        raise _err("'--maxfail' wants an integer >= 0, got '" + value + "'")
    return parsed.value()


def _parse_durations(value: String) raises -> Int:
    """Parse a `--durations` value: a non-negative integer (`0` disables)."""
    var parsed = parse_nonnegative_decimal(value)
    if not parsed:
        raise _err("'--durations' wants an integer >= 0, got '" + value + "'")
    return parsed.value()


def _parse_retries(value: String) raises -> Int:
    """Parse a `--retries` value: a non-negative integer (`0` disables)."""
    var parsed = parse_nonnegative_decimal(value)
    if not parsed:
        raise _err("'--retries' wants an integer >= 0, got '" + value + "'")
    return parsed.value()


def _parse_seed(value: String) raises -> Int:
    """Parse a `--seed` value: a non-negative integer."""
    var parsed = parse_nonnegative_decimal(value)
    if not parsed:
        raise _err("'--seed' wants an integer >= 0, got '" + value + "'")
    return parsed.value()


def _parse_workers(value: String) raises -> Int:
    """Parse a `-n`/`--workers` value into a worker count.

    Args:
        value: The flag's value: the literal `auto`, or a positive decimal
            integer. `auto` selects a runner-chosen count; a `1` is the
            sequential default and every `N >= 2` is an explicit count.

    Returns:
        `0` for `auto` (the sentinel the resolver reads as runner-chosen), or
        the requested positive integer count.

    Raises:
        A usage error (exit 4) when the value is neither `auto` nor a positive
        integer: `0`, a negative, or any non-digit spelling.
    """
    var parsed = parse_worker_count(value)
    if not parsed:
        raise _err(
            "'-n'/'--workers' wants a positive integer or 'auto', got '"
            + value
            + "'"
        )
    return parsed.value()


def _parse_compile_timeout(value: String) raises -> Int:
    """Parse `--compile-timeout`: a non-negative integer, `0` disables."""
    var parsed = parse_nonnegative_decimal(value)
    if not parsed:
        raise _err(
            "'--compile-timeout' wants an integer >= 0, got '" + value + "'"
        )
    return parsed.value()


def _parse_format(value: String) raises -> Bool:
    """Parse a `--format` value into "render the collect stream".

    Args:
        value: The flag's value: `lines` (the plain listing) or `json` (the
            NDJSON collect stream).

    Returns:
        True for `json`, False for `lines`.

    Raises:
        Error: A usage error (exit 4) naming the offending value for anything
            else, an empty value included.
    """
    if value == "lines":
        return False
    if value == "json":
        return True
    raise _err("'--format' wants 'lines' or 'json', got '" + value + "'")


def _parse_show_output(value: String) raises -> ShowOutput:
    """Parse a `--show-output` mode: `failures`, `all`, or `none`."""
    var parsed = parse_show_output_value(value)
    if not parsed:
        raise _err(
            "'--show-output' wants one of failures|all|none, got '"
            + value
            + "'"
        )
    return parsed.value()


def _validate_json_dest(value: String, validate_parent: Bool) raises -> String:
    """Syntactically validate a `--json` destination; return it unchanged.

    `-` names the stdout stream and is always valid. Any other value is a
    filesystem path and must be non-empty. When `validate_parent` is True, its
    parent directory (when it names one) must already exist.

    This is the parse-time check only. An empty value is always a usage error
    (exit 4); a missing parent is also a usage error for a run, but resolution-
    only config display skips that filesystem check. A runtime open failure,
    such as a permissions problem or descriptor exhaustion, is the session's
    to detect under a different exit code.
    """
    if value == "-":
        return value
    if value.byte_length() == 0:
        raise _err(
            "'--json' wants a destination PATH or '-', got an empty value"
        )
    if validate_parent:
        var parent = String(dirname(value))
        if parent != "" and not isdir(parent):
            raise _err(
                "'--json' destination parent directory does not exist: '"
                + safe_path_label(parent)
                + "'"
            )
    return value


def _validate_junit_dest(value: String, validate_parent: Bool) raises -> String:
    """Syntactically validate a `--junit-xml` destination; return it unchanged.

    The value is always a filesystem path. There is no `-` stdout form, because
    a JUnit document is assembled and renamed atomically rather than streamed
    live. It must be non-empty. When `validate_parent` is True, its parent
    directory (when it names one) must already exist.

    This is the parse-time check only. An empty value is always a usage error
    (exit 4); a missing parent is also a usage error for a run, but resolution-
    only config display skips that filesystem check. A runtime creation
    failure, including the target directory being removed after this check, is
    the session's to detect under a different exit code.
    """
    if value.byte_length() == 0:
        raise _err("'--junit-xml' wants a destination PATH, got an empty value")
    if validate_parent:
        var parent = String(dirname(value))
        if parent != "" and not isdir(parent):
            raise _err(
                "'--junit-xml' destination parent directory does not exist: '"
                + safe_path_label(parent)
                + "'"
            )
    return value


def _validate_report_dest(
    format: String, value: String, validate_parent: Bool
) raises -> String:
    """Validate one `--report FORMAT:PATH` destination; return the path.

    The path half of the value is always a filesystem path. There is no `-`
    stdout form, for the same reason `--junit-xml` has none: the document is
    assembled and renamed atomically rather than streamed live. When
    `validate_parent` is True, its parent directory (when it names one) must
    already exist.

    This is the parse-time check only. `parse_report_value` has already refused
    an empty path, an unknown format, and a missing separator; a missing parent
    is also a usage error for a run, while resolution-only config display skips
    that filesystem check. A runtime creation failure is `main`'s to detect
    under a different exit code.

    Args:
        format: The already-validated `md` or `html` half, named in the
            diagnostic so a reader knows which destination is wrong.
        value: The destination path half of the `--report` value.
        validate_parent: Whether to require an existing parent directory.

    Returns:
        `value` unchanged.

    Raises:
        Error: A usage error (exit 4) when the parent directory is absent.
    """
    if validate_parent:
        var parent = String(dirname(value))
        if parent != "" and not isdir(parent):
            raise _err(
                "'--report "
                + format
                + ":' destination parent directory does not exist: '"
                + safe_path_label(parent)
                + "'"
            )
    return value


def _err_report_value(value: String) -> Error:
    """The standard `--report` usage error naming the offending value."""
    return _err(
        "'--report' wants md:PATH or html:PATH, got '"
        + safe_path_label(value)
        + "'"
    )


def _parse_report_style(value: String) raises -> ReportStyle:
    """Parse a `--report-style` value: `concise` or `full`."""
    var parsed = parse_report_style_value(value)
    if not parsed:
        raise _err(
            "'--report-style' wants 'concise' or 'full', got '" + value + "'"
        )
    return parsed.value()


def _parse_annotations(value: String) raises -> AnnotationsMode:
    """Parse a `--gh-annotations` mode: `off`, `on`, or `auto`."""
    var parsed = parse_annotations_value(value)
    if not parsed:
        raise _err(
            "'--gh-annotations' wants one of off|on|auto, got '" + value + "'"
        )
    return parsed.value()


def _parse_color(value: String) raises -> ColorWhen:
    """Parse a `--color` mode: `auto`, `always`, or `never`."""
    var parsed = parse_color_value(value)
    if not parsed:
        raise _err(
            "'--color' wants one of auto|always|never, got '" + value + "'"
        )
    return parsed.value()


def _parse_precompile(value: String) raises -> Precompile:
    """Parse a `--precompile SRC[:OUT]` value into its two parts."""
    var parsed = parse_precompile_value(value)
    if not parsed:
        raise _err("'--precompile' wants SRC[:OUT], got '" + value + "'")
    return parsed.value().copy()


def _parse_shard(value: String) raises -> Tuple[ShardMode, Int, Int]:
    """Parse a `--shard [hash:|slice:]M/N` value into (mode, M, N).

    Peels an optional `hash:` or `slice:` mode prefix, splitting on the first
    `:` and defaulting to `hash`, then splits the remainder on `/` into two
    integers and enforces `1 <= M <= N`. Any deviation raises the standard
    `--shard` usage error naming the offending value.
    """
    var mode = ShardMode.HASH
    var rest = value
    if value.find(":") != -1:
        var parts = value.split(":", 1)
        var prefix = String(parts[0])
        rest = String(parts[1])
        if prefix == "hash":
            mode = ShardMode.HASH
        elif prefix == "slice":
            mode = ShardMode.SLICE
        else:
            raise _err_shard(value)
    if rest.find("/") == -1:
        raise _err_shard(value)
    var mn = rest.split("/", 1)
    var ms = String(mn[0])
    var ns = String(mn[1])
    var parsed_m = parse_nonnegative_decimal(ms)
    var parsed_n = parse_nonnegative_decimal(ns)
    if not parsed_m or not parsed_n:
        raise _err_shard(value)
    var m = parsed_m.value()
    var n = parsed_n.value()
    if n < 1 or m < 1 or m > n:
        raise _err_shard(value)
    return (mode, m, n)


def _err_shard(value: String) -> Error:
    """The standard `--shard` usage error naming the offending value."""
    return _err(
        "'--shard' wants [hash:|slice:]M/N with 1<=M<=N, got '" + value + "'"
    )


def _check_build_arg(tok: String) raises:
    """Reject a build argument that would seize control mtest owns.

    Forbids output selection (`-o`), emit-type selection (`--emit`), and build
    parallelism (`-j`, `--num-threads`), because the runner owns the build
    thread budget. It also forbids any extra Mojo source operand: a bare
    `*.mojo` or `*.🔥` positional that would reach `mojo build`. A bare value
    that is not a source file, such as a forwarded flag's value, passes.
    """
    var rejection = build_arg_rejection(tok)
    if rejection:
        raise _err(rejection.value())


def _env_mojo() -> Optional[String]:
    """`MTEST_MOJO` if it is set and non-empty, else `None`."""
    var v = getenv("MTEST_MOJO", "")
    if v.byte_length() == 0:
        return Optional[String](None)
    return Optional[String](v)


def _lookup(name: String) -> Optional[FlagSpec]:
    """The spec for a flag spelling, or `None` if the token names no flag."""
    for spec in flag_specs():
        if spec.spelling == name:
            return spec.copy()
    return Optional[FlagSpec](None)


def _debug_refusal(name: String, id: Int) -> Error:
    """The usage error for a flag `debug` does not accept.

    Two refusals carry their reason, because the reason is not guessable from
    the flag: a command that replaces the mtest process leaves nothing behind
    to write a report with, and nothing to color.

    Args:
        name: The offending flag spelling, as typed.
        id: Its `FlagId`, which decides whether a reason is attached.

    Returns:
        The complete `cli:`-prefixed usage error.
    """
    var body = "'" + name + "' cannot be combined with 'debug'"
    if (
        id == FlagId.JSON
        or id == FlagId.JUNIT_XML
        or id == FlagId.GH_ANNOTATIONS
        or id == FlagId.REPORT
    ):
        return _err(
            body
            + ": debug replaces the mtest process, so no terminal record could"
            " be written"
        )
    if id == FlagId.COLOR:
        return _err(
            body
            + ": debug replaces the mtest process, so there is no reporter to"
            " color"
        )
    return _err(body)


def _debug_accepts(id: Int) -> Bool:
    """Whether `debug`'s grammar accepts this flag identity.

    The single gate, consulted before a flag's value is consumed. Deciding it
    inside the arity branches instead let `debug NODE --json` report a missing
    value and never state why the flag is refused at all, which is exactly the
    explanation the refusal exists to give.

    Args:
        id: The matched `FlagId`.

    Returns:
        True for `--help`, the configuration controls, `-q`/`-v`, and the three
        build controls; False for every other flag.
    """
    return (
        id == FlagId.HELP
        or id == FlagId.NO_CONFIG
        or id == FlagId.QUIET
        or id == FlagId.VERBOSE
        or id == FlagId.CONFIG
        or id == FlagId.INCLUDE
        or id == FlagId.BUILD_ARG
        or id == FlagId.MOJO
    )


def _err_debug_operand() -> Error:
    """The usage error for anything but exactly one node-id operand."""
    return _err("'debug' wants exactly one PATH::TEST node id")


def _parse_debug(argv: List[String]) raises -> ParseResult:
    """Parse the `debug` tail: one node id plus the build controls.

    `debug` prepares one test and then becomes it, so its grammar is the
    narrowest in the parser: exactly one `PATH::TEST` operand, the flags that
    decide how that file is compiled (`--mojo`, `-I`, `--build-arg`, and
    post-`--` passthrough), the configuration controls, and `-q`/`-v`.
    Everything else is refused rather than accepted-and-ignored, because a
    silently dropped `--retries` or `--json` would promise something the
    handoff cannot deliver.

    Args:
        argv: The complete argument vector; the `debug` head token is skipped.

    Returns:
        A result whose `kind` is `DEBUG`, or the help directive when `--help`
        appears anywhere in the tail.

    Raises:
        Error: A `cli:`-prefixed usage error for a missing, malformed, plain,
            or repeated operand, an unknown flag, a missing value, a forbidden
            build argument, `-q` with `-v`, `--config` with `--no-config`, or
            any flag outside the accepted set.
    """
    var operand = String("")
    var saw_operand = False
    var include_paths = List[String]()
    var saw_include = False
    var build_args = List[String]()
    var saw_build_args = False
    var mojo_flag = Optional[String](None)
    var saw_mojo = False
    var config_path = String("")
    var saw_config = False
    var no_config = False
    var saw_quiet = False
    var saw_verbose = False
    var passthrough = False

    var i = 1
    while i < len(argv):
        var tok = argv[i]

        if passthrough:
            _check_build_arg(tok)
            build_args.append(tok)
            saw_build_args = True
            i += 1
            continue

        if tok == "--":
            passthrough = True
            i += 1
            continue

        if not tok.startswith("-") or tok == "-":
            var split = split_node_token(tok)
            if (
                saw_operand
                or split.sep_count != 1
                or split.file_part == ""
                or split.name_part == ""
            ):
                raise _err_debug_operand()
            operand = tok
            saw_operand = True
            i += 1
            continue

        var name = tok
        var has_inline = False
        var inline_val = String("")
        if tok.find("=") != -1:
            var parts = tok.split("=", 1)
            name = String(parts[0])
            inline_val = String(parts[1])
            has_inline = True

        if (
            not name.startswith("--")
            and name.byte_length() > 2
            and not has_inline
        ):
            raise _err(
                "short flags cannot be bundled: '"
                + tok
                + "'; pass them separately like '-q -I src'"
            )

        var spec = _lookup(name)
        if not spec:
            raise _err("unknown flag '" + name + "'")
        var s = spec.value().copy()
        # Before the value: a refused flag's message must say WHY it is
        # refused, and a `--json` with no value would otherwise be reported as
        # a missing value instead.
        if not _debug_accepts(s.id):
            raise _debug_refusal(name, s.id)

        if s.arity == 0:
            if has_inline:
                raise _err(
                    "flag '"
                    + s.spelling
                    + "' takes no value, got '"
                    + tok
                    + "'"
                )
            if s.id == FlagId.HELP:
                return ParseResult.show_help()
            if s.id == FlagId.NO_CONFIG:
                no_config = True
            elif s.id == FlagId.QUIET:
                saw_quiet = True
            elif s.id == FlagId.VERBOSE:
                saw_verbose = True
            else:
                raise _debug_refusal(name, s.id)
            i += 1
            continue

        var value: String
        if has_inline:
            value = inline_val
        else:
            if i + 1 >= len(argv):
                raise _err("'" + name + "' requires a value")
            value = argv[i + 1]
            i += 1
        i += 1

        if s.id == FlagId.INCLUDE:
            _check_build_arg(value)
            include_paths.append(value)
            saw_include = True
        elif s.id == FlagId.BUILD_ARG:
            _check_build_arg(value)
            build_args.append(value)
            saw_build_args = True
        elif s.id == FlagId.MOJO:
            mojo_flag = value
            saw_mojo = True
        elif s.id == FlagId.CONFIG:
            if value == "":
                raise _err("'--config' requires a non-empty path")
            config_path = value
            saw_config = True
        else:
            raise _debug_refusal(name, s.id)

    if not saw_operand:
        raise _err_debug_operand()
    if saw_config and no_config:
        raise _err("'--config' and '--no-config' are mutually exclusive")
    if saw_quiet and saw_verbose:
        raise _err("'-q' and '-v' are mutually exclusive")

    var verbosity = Verbosity.NORMAL
    if saw_quiet:
        verbosity = Verbosity.QUIET
    elif saw_verbose:
        verbosity = Verbosity.VERBOSE

    var overlay_mojo = String("mojo")
    if mojo_flag:
        overlay_mojo = mojo_flag.value()
    var overlay = CliOverlay.default()
    overlay.mojo_path = overlay_mojo^
    overlay.saw_mojo = saw_mojo
    overlay.include_paths = include_paths^
    overlay.saw_include = saw_include
    overlay.build_args = build_args^
    overlay.saw_build_args = saw_build_args
    overlay.verbosity = verbosity
    overlay.saw_verbosity = saw_quiet or saw_verbose

    var defaults = RunnerConfig.default()
    defaults.mojo_path = resolve_mojo_path(Optional[String](None), _env_mojo())
    var cfg = overlay.fold(defaults)
    return ParseResult.debug(cfg^, overlay^, operand^, config_path^, no_config)


def _err_new_operand() -> Error:
    """The usage error for anything but exactly one path operand."""
    return _err("'new' wants exactly one PATH")


def _parse_new(argv: List[String]) raises -> ParseResult:
    """Parse the `new` tail: one path, and nothing else.

    Scaffolding a file reads no configuration, builds nothing, and runs
    nothing, so there is no flag whose value could reach it. Every one is
    refused by name rather than accepted and ignored. `--help` is the
    exception, because it describes a command rather than acting on one.

    Args:
        argv: The complete argument vector; the `new` head token is skipped.

    Returns:
        A result whose `kind` is `NEW`, or the help directive when `--help`
        appears anywhere in the tail.

    Raises:
        Error: A `cli:`-prefixed usage error for a missing or repeated
            operand, or for any flag other than `-h`/`--help`.
    """
    var operand = String("")
    var saw_operand = False
    var i = 1
    while i < len(argv):
        var tok = argv[i]
        if not tok.startswith("-") or tok == "-":
            if saw_operand:
                raise _err_new_operand()
            operand = tok
            saw_operand = True
            i += 1
            continue
        var name = tok
        var has_inline = False
        if tok.find("=") != -1:
            name = String(tok.split("=", 1)[0])
            has_inline = True
        if name == "-h" or name == "--help":
            if has_inline:
                raise _err(
                    "flag '" + name + "' takes no value, got '" + tok + "'"
                )
            return ParseResult.show_help()
        raise _err("'" + name + "' cannot be combined with 'new'")
    if not saw_operand:
        raise _err_new_operand()
    return ParseResult.scaffold(operand^)


def _parse_init(argv: List[String]) raises -> ParseResult:
    """Parse the `init` tail: `--ci VALUE` and nothing else.

    `--ci` is read here rather than from the flag-spec table on purpose. A row
    in that table is a `run` flag by construction, so `mtest --ci github tests`
    would parse as a run carrying a value nothing acts on. Keeping the flag
    local means the general loop refuses it, and the usage line and the
    subcommand row are where a reader learns it exists.

    The provider value is a closed enum and is refused here like every other
    one, so an unknown provider reads as the usage error it is and carries the
    pointer at `--help`. `run_init` refuses it a second time, because it is
    also reachable as a library call.

    Args:
        argv: The complete argument vector; the `init` head token is skipped.

    Returns:
        A result whose `kind` is `INIT`, or the help directive when `--help`
        appears anywhere in the tail.

    Raises:
        Error: A `cli:`-prefixed usage error for a path operand, an empty or
            unrecognized `--ci` value, or any flag but `--ci`, `-h`, and
            `--help`.
    """
    var ci = String("")
    var i = 1
    while i < len(argv):
        var tok = argv[i]
        if not tok.startswith("-") or tok == "-":
            raise _err("'init' takes no PATH operand; it writes into the root")
        var name = tok
        var value = String("")
        var has_inline = False
        if tok.find("=") != -1:
            var parts = tok.split("=", 1)
            name = String(parts[0])
            value = String(parts[1])
            has_inline = True
        if name == "-h" or name == "--help":
            if has_inline:
                raise _err(
                    "flag '" + name + "' takes no value, got '" + tok + "'"
                )
            return ParseResult.show_help()
        if name != "--ci":
            raise _err("'" + name + "' cannot be combined with 'init'")
        if not has_inline:
            if i + 1 >= len(argv):
                raise _err("'--ci' requires a provider name")
            value = argv[i + 1]
            i += 1
        if value == "":
            raise _err("'--ci' requires a provider name")
        if value != "github":
            raise _err(
                "'--ci' wants 'github', got '" + safe_path_label(value) + "'"
            )
        ci = value
        i += 1
    return ParseResult.bootstrap(ci^)


def parse_args(argv: List[String]) raises -> ParseResult:
    """Parse `argv` into a run, inspection, scaffolding, or directive result.

    A leading `help` or `version` token returns that directive immediately. A
    leading `run`, `collect`, or `doctor` token is consumed as a subcommand,
    with `collect` equivalent to `--collect-only`. A leading `debug`, `new`, or
    `init` token hands the rest of the vector to that subcommand's own narrow
    walk, and a leading `config show` pair requests resolution-only display
    while reusing the run grammar. Any other
    first token is left to the general token loop, which reads it as a flag
    when it starts with `-` (a bare `-` excepted) and as a path operand
    otherwise, so an argument vector may open with a flag. Everything after a
    bare `--` is forwarded as a build argument.

    The `--json -` conflict with the annotation tail is not refused here.
    Either value can also come from `mtest.toml`, so `validate_resolved_config`
    refuses the pair after layering and `main` exits 4.

    Args:
        argv: The argument tokens, excluding the program name.

    Returns:
        A configured run, config-display request, doctor request, debug
        request, scaffolding or bootstrap request, or help/version directive.

    Raises:
        Error: A `cli:`-prefixed usage error, raised for an unknown flag, a
            missing or malformed value, a forbidden build argument, a bundled
            short-flag group, `-q` and `-v` together, `--config` with
            `--no-config`, `--lf` with `--ff`, either of those with `--shard`,
            `--seed` without `--shuffle`, `--shuffle` with `--lf`/`--ff`,
            `--format` outside collect mode,
            a run-only flag combined with collect mode, a run, build, or
            reporter flag combined with doctor, under `new` anything but
            exactly one path operand and any flag but `-h`/`--help`, or —
            under `init` — a path operand, an empty or unrecognized `--ci`
            value, and any flag but `--ci`/`-h`/`--help`.

    Examples:

    ```mojo
    from mtest.cli import parse_args

    var argv: List[String] = ["run", "tests/", "--timeout", "45"]
    var result = parse_args(argv)
    print(result.is_run(), result.config.timeout_secs)
    ```
    """
    var start = 0
    var collect = False
    var config_show = False
    var doctor = False
    if len(argv) > 0:
        var head = argv[0]
        if head == "version":
            return ParseResult.show_version()
        if head == "help":
            return ParseResult.show_help()
        if head == "collect":
            # The `collect` subcommand is exactly `--collect-only`: it turns on
            # collect mode and consumes the head token like `run` does.
            collect = True
            start = 1
        if head == "run":
            start = 1
        if head == "doctor":
            doctor = True
            start = 1
        if head == "debug":
            # `debug` owns its own tail walk: its grammar accepts a handful of
            # build controls and refuses everything else by name, which the
            # general loop would have to unlearn flag by flag.
            return _parse_debug(argv)
        if head == "new":
            # `new` owns its tail for the opposite reason: it accepts no flag
            # at all, so the general loop's whole table is wrong for it.
            return _parse_new(argv)
        if head == "init":
            # `init` owns its tail because its one flag is deliberately not in
            # the table: a `--ci` row there would also make it a `run` flag.
            return _parse_init(argv)
        if head == "config":
            if len(argv) < 2 or argv[1] != "show":
                raise _err(
                    "'config' requires the two-token subcommand 'config show'"
                )
            config_show = True
            start = 2

    var paths = List[String]()
    var saw_paths = False
    var excludes = List[String]()
    var saw_excludes = False
    var serials = List[String]()
    var saw_serial = False
    var gates = List[String]()
    var saw_gates = False
    var precompiles = List[Precompile]()
    var saw_precompile = False
    var build_args = List[String]()
    var saw_build_args = False
    var include_paths = List[String]()
    var saw_include = False
    var mojo_flag = Optional[String](None)
    var saw_mojo = False
    var timeout_secs = 300
    var saw_timeout = False
    var compile_timeout_secs = 600
    var saw_compile_timeout = False
    var show_output = ShowOutput.FAILURES
    var color = ColorWhen.AUTO
    var saw_color = False
    var exitfirst = False
    var keyword = String("")
    var maxfail = 0
    var saw_maxfail = False
    var durations = 0
    var saw_durations = False
    var shard_mode = ShardMode.HASH
    var shard_m = 0
    var shard_n = 0
    var retries = 0
    var saw_retries = False
    # One worker is the sequential default: no flag runs files in order and
    # leaves the build argv byte-identical to a single-worker build.
    var workers = 1
    var saw_workers = False
    var json_dest = String("")
    var saw_json = False
    var junit_dest = String("")
    var saw_junit = False
    var report_md_dest = String("")
    var saw_report_md = False
    var report_html_dest = String("")
    var saw_report_html = False
    var report_style = ReportStyle.CONCISE
    var saw_report_style = False
    var gh_annotations = AnnotationsMode.AUTO
    var saw_annotations = False
    var saw_show_output = False
    var saw_quiet = False
    var saw_verbose = False
    var config_path = String("")
    var saw_config = False
    var no_config = False
    var last_failed = False
    var failed_first = False
    var no_cache = False
    var cache_clear = False
    var fail_on_flaky = False
    var saw_fail_on_flaky = False
    var shuffle = False
    # `-1` is the parser's "no seed given" sentinel; the session derives one.
    var shuffle_seed = -1
    var saw_seed = False
    var collect_json = False
    var saw_format = False
    var saw_select = False
    var saw_shard = False
    var saw_passthrough = False

    var passthrough = False
    var i = start
    while i < len(argv):
        var tok = argv[i]

        if passthrough:
            _check_build_arg(tok)
            build_args.append(tok)
            saw_build_args = True
            i += 1
            continue

        if tok == "--":
            passthrough = True
            saw_passthrough = True
            i += 1
            continue

        if not tok.startswith("-") or tok == "-":
            paths.append(tok)
            saw_paths = True
            i += 1
            continue

        # A flag token: split off an inline `=value` if present.
        var name = tok
        var has_inline = False
        var inline_val = String("")
        if tok.find("=") != -1:
            var parts = tok.split("=", 1)
            name = String(parts[0])
            inline_val = String(parts[1])
            has_inline = True

        # A single-dash group longer than one letter is a forbidden bundle.
        if (
            not name.startswith("--")
            and name.byte_length() > 2
            and not has_inline
        ):
            raise _err(
                "short flags cannot be bundled: '"
                + tok
                + "'; pass them separately like '-x -q'"
            )

        var spec = _lookup(name)
        if not spec:
            raise _err("unknown flag '" + name + "'")
        var s = spec.value().copy()
        if s.arity == 0:
            if has_inline:
                raise _err(
                    "flag '"
                    + s.spelling
                    + "' takes no value, got '"
                    + tok
                    + "'"
                )
            if s.id == FlagId.HELP:
                return ParseResult.show_help()
            if s.id == FlagId.VERSION:
                return ParseResult.show_version()
            if s.id == FlagId.EXITFIRST:
                exitfirst = True
            elif s.id == FlagId.SHOW_ALL:
                show_output = ShowOutput.ALL
                saw_show_output = True
            elif s.id == FlagId.QUIET:
                saw_quiet = True
            elif s.id == FlagId.VERBOSE:
                saw_verbose = True
            elif s.id == FlagId.COLLECT_ONLY:
                collect = True
            elif s.id == FlagId.NO_CONFIG:
                no_config = True
            elif s.id == FlagId.LAST_FAILED:
                last_failed = True
            elif s.id == FlagId.FAILED_FIRST:
                failed_first = True
            elif s.id == FlagId.NO_CACHE:
                no_cache = True
            elif s.id == FlagId.CACHE_CLEAR:
                cache_clear = True
            elif s.id == FlagId.FAIL_ON_FLAKY:
                fail_on_flaky = True
                saw_fail_on_flaky = True
            elif s.id == FlagId.SHUFFLE:
                shuffle = True
            i += 1
            continue

        # arity == 1
        var value: String
        if has_inline:
            value = inline_val
        else:
            if i + 1 >= len(argv):
                raise _err("'" + name + "' requires a value")
            value = argv[i + 1]
            i += 1
        i += 1

        if s.id == FlagId.EXCLUDE:
            excludes.append(value)
            saw_excludes = True
        elif s.id == FlagId.SERIAL:
            serials.append(value)
            saw_serial = True
        elif s.id == FlagId.INCLUDE:
            _check_build_arg(value)
            include_paths.append(value)
            saw_include = True
        elif s.id == FlagId.BUILD_ARG:
            _check_build_arg(value)
            build_args.append(value)
            saw_build_args = True
        elif s.id == FlagId.GATE:
            gates.append(value)
            saw_gates = True
        elif s.id == FlagId.PRECOMPILE:
            precompiles.append(_parse_precompile(value))
            saw_precompile = True
        elif s.id == FlagId.MOJO:
            mojo_flag = value
            saw_mojo = True
        elif s.id == FlagId.TIMEOUT:
            timeout_secs = _parse_timeout(value)
            saw_timeout = True
        elif s.id == FlagId.COMPILE_TIMEOUT:
            compile_timeout_secs = _parse_compile_timeout(value)
            saw_compile_timeout = True
        elif s.id == FlagId.SHOW_OUTPUT:
            show_output = _parse_show_output(value)
            saw_show_output = True
        elif s.id == FlagId.COLOR:
            color = _parse_color(value)
            saw_color = True
        elif s.id == FlagId.SELECT:
            keyword = value
            saw_select = True
        elif s.id == FlagId.MAXFAIL:
            maxfail = _parse_maxfail(value)
            saw_maxfail = True
        elif s.id == FlagId.DURATIONS:
            durations = _parse_durations(value)
            saw_durations = True
        elif s.id == FlagId.SHARD:
            var parsed = _parse_shard(value)
            shard_mode = parsed[0]
            shard_m = parsed[1]
            shard_n = parsed[2]
            saw_shard = True
        elif s.id == FlagId.RETRIES:
            retries = _parse_retries(value)
            saw_retries = True
        elif s.id == FlagId.SEED:
            shuffle_seed = _parse_seed(value)
            saw_seed = True
        elif s.id == FlagId.WORKERS:
            workers = _parse_workers(value)
            saw_workers = True
        elif s.id == FlagId.FORMAT:
            collect_json = _parse_format(value)
            saw_format = True
        elif s.id == FlagId.JSON:
            json_dest = _validate_json_dest(
                value, not config_show and not doctor
            )
            saw_json = True
        elif s.id == FlagId.JUNIT_XML:
            junit_dest = _validate_junit_dest(
                value, not config_show and not doctor
            )
            saw_junit = True
        elif s.id == FlagId.REPORT:
            var report = parse_report_value(value)
            if not report:
                raise _err_report_value(value)
            var destination = _validate_report_dest(
                report.value().format,
                report.value().path,
                not config_show and not doctor,
            )
            # Repeatable ONCE PER FORMAT: a second `md:` is a typo whose two
            # destinations cannot both be honored, so it is refused rather
            # than silently last-wins.
            if report.value().format == "md":
                if saw_report_md:
                    raise _err(
                        "'--report md:' was given twice; pass at most one"
                        " destination per format"
                    )
                report_md_dest = destination
                saw_report_md = True
            else:
                if saw_report_html:
                    raise _err(
                        "'--report html:' was given twice; pass at most one"
                        " destination per format"
                    )
                report_html_dest = destination
                saw_report_html = True
        elif s.id == FlagId.REPORT_STYLE:
            report_style = _parse_report_style(value)
            saw_report_style = True
        elif s.id == FlagId.GH_ANNOTATIONS:
            gh_annotations = _parse_annotations(value)
            saw_annotations = True
        elif s.id == FlagId.CONFIG:
            if value == "":
                raise _err("'--config' requires a non-empty path")
            config_path = value
            saw_config = True

    if saw_config and no_config:
        raise _err("'--config' and '--no-config' are mutually exclusive")
    if last_failed and failed_first:
        raise _err(
            "'--lf'/'--last-failed' and '--ff'/'--failed-first' are mutually"
            " exclusive"
        )
    if (last_failed or failed_first) and shard_n > 0:
        raise _err(
            "'--lf'/'--last-failed' and '--ff'/'--failed-first' cannot be"
            " combined with '--shard'"
        )
    if saw_seed and not shuffle:
        raise _err("'--seed' requires '--shuffle'")
    if shuffle and (last_failed or failed_first):
        raise _err(
            "'--shuffle' and '--lf'/'--ff' choose conflicting orders; pick one"
        )
    # `--format` shapes a listing, so it is refused wherever there is no
    # listing. Checked here rather than in the doctor and collect blocks below
    # because those refuse run flags under collect, and this is the mirror
    # image: the one flag collect alone accepts.
    if saw_format and not collect:
        raise _err("'--format' is a collect-only flag")

    if doctor:
        if saw_paths:
            raise _err("path operands cannot be combined with doctor")
        if saw_passthrough:
            raise _err(
                "build-argument passthrough cannot be combined with doctor"
            )
        if saw_select:
            raise _err(
                "'-k' is a run/collect flag and cannot be combined with doctor"
            )
        if last_failed or failed_first:
            raise _err(
                "'--lf'/'--last-failed' and '--ff'/'--failed-first' are state"
                " selection flags and cannot be combined with doctor"
            )
        if collect:
            raise _err(
                "'--collect-only' is a run/collect flag and cannot be combined"
                " with doctor"
            )
        if exitfirst:
            raise _err(
                "'-x'/'--exitfirst' is a run flag and cannot be combined with"
                " doctor"
            )
        if saw_timeout:
            raise _err(
                "'--timeout' is a run flag and cannot be combined with doctor"
            )
        if saw_maxfail:
            raise _err(
                "'--maxfail' is a run flag and cannot be combined with doctor"
            )
        if saw_durations:
            raise _err(
                "'--durations' is a run flag and cannot be combined with doctor"
            )
        if saw_fail_on_flaky:
            raise _err(
                "'--fail-on-flaky' is a run flag and cannot be combined with"
                " doctor"
            )
        # `--seed` alone was already refused above for wanting `--shuffle`, so
        # gating on `shuffle` covers the pair.
        if shuffle:
            raise _err(
                "'--shuffle' and '--seed' are run flags and cannot be combined"
                " with doctor"
            )
        if saw_retries:
            raise _err(
                "'--retries' is a run flag and cannot be combined with doctor"
            )
        if saw_workers:
            raise _err(
                "'-n'/'--workers' is a run flag and cannot be combined with"
                " doctor"
            )
        if saw_shard:
            raise _err(
                "'--shard' is a run flag and cannot be combined with doctor"
            )
        if saw_excludes:
            raise _err(
                "'--exclude' is a selection flag and cannot be combined with"
                " doctor"
            )
        if saw_serial:
            raise _err(
                "'--serial' is a run flag and cannot be combined with doctor"
            )
        if saw_gates:
            raise _err(
                "'--gate' is a run flag and cannot be combined with doctor"
            )
        if saw_show_output:
            raise _err(
                "'-s'/'--show-output' is a run flag and cannot be combined with"
                " doctor"
            )
        if saw_mojo:
            raise _err(
                "'--mojo' is a build flag and cannot be combined with doctor"
            )
        if saw_include:
            raise _err(
                "'-I' is a build flag and cannot be combined with doctor"
            )
        if saw_build_args:
            raise _err(
                "'--build-arg' is a build flag and cannot be combined with"
                " doctor"
            )
        if saw_precompile:
            raise _err(
                "'--precompile' is a build flag and cannot be combined with"
                " doctor"
            )
        if saw_compile_timeout:
            raise _err(
                "'--compile-timeout' is a build flag and cannot be combined"
                " with doctor"
            )
        if saw_json:
            raise _err(
                "'--json' is a reporter flag and cannot be combined with doctor"
            )
        if saw_junit:
            raise _err(
                "'--junit-xml' is a reporter flag and cannot be combined with"
                " doctor"
            )
        if saw_annotations:
            raise _err(
                "'--gh-annotations' is a reporter flag and cannot be combined"
                " with doctor"
            )
        if saw_report_md or saw_report_html:
            raise _err(
                "'--report' is a reporter flag and cannot be combined with"
                " doctor"
            )
        if saw_report_style:
            raise _err(
                "'--report-style' is a reporter flag and cannot be combined"
                " with doctor"
            )

    # Collect mode is a listing, not a run: the run-only knobs that shape which
    # tests execute or when to stop scheduling are meaningless against it and are
    # refused loudly. `--timeout` is NOT refused — it bounds the collection
    # probes exactly as it bounds a run (a hanging probe is a TIMEOUT).
    if collect:
        if last_failed or failed_first:
            raise _err(
                "'--lf'/'--last-failed' and '--ff'/'--failed-first' are"
                " run-only flags and cannot be combined with collect mode"
            )
        if exitfirst:
            raise _err(
                "'-x'/'--exitfirst' is a run-only flag and cannot be combined"
                " with collect mode"
            )
        if saw_maxfail:
            raise _err(
                "'--maxfail' is a run-only flag and cannot be combined with"
                " collect mode"
            )
        if len(gates) > 0:
            raise _err(
                "'--gate' is a run-only flag and cannot be combined with"
                " collect mode"
            )
        if saw_show_output:
            raise _err(
                "'-s'/'--show-output' is a run-only flag and cannot be"
                " combined with collect mode"
            )
        if saw_durations:
            raise _err(
                "'--durations' is a run-only flag and cannot be combined"
                " with collect mode"
            )
        if saw_fail_on_flaky:
            raise _err(
                "'--fail-on-flaky' is a run-only flag and cannot be combined"
                " with collect mode"
            )
        # `--seed` alone was already refused above for wanting `--shuffle`, so
        # gating on `shuffle` covers the pair.
        if shuffle:
            raise _err(
                "'--shuffle' and '--seed' are run-only flags and cannot be"
                " combined with collect mode"
            )
        if saw_retries:
            raise _err(
                "'--retries' is a run-only flag and cannot be combined with"
                " collect mode"
            )
        if saw_json:
            raise _err(
                "'--json' is a run-only flag and cannot be combined with"
                " collect mode"
            )
        if saw_junit:
            raise _err(
                "'--junit-xml' is a run-only flag and cannot be combined with"
                " collect mode"
            )
        if saw_annotations:
            raise _err(
                "'--gh-annotations' is a run-only flag and cannot be combined"
                " with collect mode"
            )
        if saw_report_md or saw_report_html:
            raise _err(
                "'--report' is a run-only flag and cannot be combined with"
                " collect mode"
            )
        if saw_report_style:
            raise _err(
                "'--report-style' is a run-only flag and cannot be combined"
                " with collect mode"
            )

    if saw_quiet and saw_verbose:
        raise _err("'-q' and '-v' are mutually exclusive")
    var verbosity = Verbosity.NORMAL
    if saw_quiet:
        verbosity = Verbosity.QUIET
    elif saw_verbose:
        verbosity = Verbosity.VERBOSE

    var overlay_mojo = String("mojo")
    if mojo_flag:
        overlay_mojo = mojo_flag.value()
    var overlay = CliOverlay(
        paths=paths^,
        saw_paths=saw_paths,
        excludes=excludes^,
        saw_excludes=saw_excludes,
        serial_globs=serials^,
        saw_serial=saw_serial,
        gates=gates^,
        saw_gates=saw_gates,
        workers=workers,
        saw_workers=saw_workers,
        timeout_secs=timeout_secs,
        saw_timeout=saw_timeout,
        retries=retries,
        saw_retries=saw_retries,
        maxfail=maxfail,
        saw_maxfail=saw_maxfail,
        fail_on_flaky=fail_on_flaky,
        saw_fail_on_flaky=saw_fail_on_flaky,
        state=True,
        saw_state=False,
        mojo_path=overlay_mojo^,
        saw_mojo=saw_mojo,
        include_paths=include_paths^,
        saw_include=saw_include,
        build_args=build_args^,
        saw_build_args=saw_build_args,
        precompiles=precompiles^,
        saw_precompile=saw_precompile,
        compile_timeout_secs=compile_timeout_secs,
        saw_compile_timeout=saw_compile_timeout,
        color=color,
        saw_color=saw_color,
        show_output=show_output,
        saw_show_output=saw_show_output,
        verbosity=verbosity,
        saw_verbosity=saw_quiet or saw_verbose,
        durations=durations,
        saw_durations=saw_durations,
        junit_dest=junit_dest^,
        saw_junit_xml=saw_junit,
        json_dest=json_dest^,
        saw_json=saw_json,
        gh_annotations=gh_annotations,
        saw_gh_annotations=saw_annotations,
        report_md_dest=report_md_dest^,
        saw_report_md=saw_report_md,
        report_html_dest=report_html_dest^,
        saw_report_html=saw_report_html,
        report_style=report_style,
        saw_report_style=saw_report_style,
    )
    var defaults = RunnerConfig.default()
    defaults.mojo_path = resolve_mojo_path(Optional[String](None), _env_mojo())
    defaults.exitfirst = exitfirst
    defaults.keyword = keyword^
    defaults.collect = collect
    defaults.collect_json = collect_json
    defaults.last_failed = last_failed
    defaults.failed_first = failed_first
    defaults.shard_mode = shard_mode
    defaults.shard_m = shard_m
    defaults.shard_n = shard_n
    defaults.shuffle = shuffle
    defaults.shuffle_seed = shuffle_seed
    defaults.no_cache = no_cache
    defaults.cache_clear = cache_clear
    var cfg = overlay.fold(defaults)
    if doctor:
        return ParseResult.doctor(cfg^, overlay^, config_path^, no_config)
    if config_show:
        return ParseResult.config_show(cfg^, overlay^, config_path^, no_config)
    return ParseResult.run(cfg^, overlay^, config_path^, no_config)
