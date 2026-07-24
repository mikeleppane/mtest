"""The hand-rolled full-contract argument parser.

`parse_args` turns an argument vector into a `ParseResult` — a configured run,
a resolved-config display request, a doctor request, or a help/version
directive — or raises a `cli:`-prefixed usage error.

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
from mtest.config import (
    AnnotationsMode,
    CliOverlay,
    ColorWhen,
    Precompile,
    RunnerConfig,
    ShardMode,
    ShowOutput,
    Verbosity,
    build_arg_rejection,
    parse_annotations_value,
    parse_color_value,
    parse_nonnegative_decimal,
    parse_precompile_value,
    parse_show_output_value,
    parse_worker_count,
    resolve_mojo_path,
)

comptime MTEST_VERSION = "0.5.0"
"""The single source of the version string; `main` reuses this exact value."""

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
        "       mtest config show [PATHS...] [flags] [-- BUILD-ARGS...]\n",
        (
            "       mtest doctor [--config PATH | --no-config]"
            " [--color WHEN] [-q | -v]\n\n"
        ),
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
        integer — `0`, a negative, or any non-digit spelling.
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
                + parent
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
                + parent
                + "'"
            )
    return value


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

    Forbids output selection (`-o`), emit-type selection (`--emit`), build
    parallelism (`-j`, `--num-threads` — the runner owns the build thread
    budget), and any extra Mojo source operand — a bare `*.mojo` or `*.🔥`
    positional that would reach `mojo build`. A bare value that is not a source
    file, such as a forwarded flag's value, passes.
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


def parse_args(argv: List[String]) raises -> ParseResult:
    """Parse `argv` into a run, config-display, doctor, help, or version result.

    A leading `help` or `version` token returns that directive immediately. A
    leading `run` or `collect` token is consumed as a subcommand, with `collect`
    equivalent to `--collect-only`. A leading `config show` pair requests
    resolution-only display while reusing the run grammar. Any other first
    token is left to the general token loop, which reads it as a flag when it
    starts with `-` (a bare `-` excepted) and as a path operand otherwise, so
    an argument vector may open with a flag. Everything after a bare `--` is
    forwarded as a build argument.

    Args:
        argv: The argument tokens, excluding the program name.

    Returns:
        A configured run, config-display request, or help/version directive.

    Raises:
        Error: A `cli:`-prefixed usage error, raised for an unknown flag, a
            missing or malformed value, a forbidden build argument, a bundled
            short-flag group, `-q` and `-v` together, a run-only flag combined
            with collect mode, `--json -` alongside an annotation tail that is
            not explicitly off.
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
        elif s.id == FlagId.WORKERS:
            workers = _parse_workers(value)
            saw_workers = True
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
    )
    var defaults = RunnerConfig.default()
    defaults.mojo_path = resolve_mojo_path(Optional[String](None), _env_mojo())
    defaults.exitfirst = exitfirst
    defaults.keyword = keyword^
    defaults.collect = collect
    defaults.last_failed = last_failed
    defaults.failed_first = failed_first
    defaults.shard_mode = shard_mode
    defaults.shard_m = shard_m
    defaults.shard_n = shard_n
    var cfg = overlay.fold(defaults)
    if doctor:
        return ParseResult.doctor(cfg^, overlay^, config_path^, no_config)
    if config_show:
        return ParseResult.config_show(cfg^, overlay^, config_path^, no_config)
    return ParseResult.run(cfg^, overlay^, config_path^, no_config)
