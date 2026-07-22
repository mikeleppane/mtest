"""The hand-rolled full-contract argument parser.

`parse_args` turns an argument vector into a `ParseResult` — a configured run
or a help/version directive — or raises a `cli:`-prefixed usage error. It parses
the whole v1 grammar: flags this build does not yet serve are still recognized,
then refused with a message naming the milestone that brings them, so later work
only flips an availability bit rather than teaching the parser a new token.

Every raise names the offending token, states the expected form, and points at
`mtest --help`. This layer never prints and never exits; `main` prints help and
version to stdout with exit 0, and prints a usage error to stderr with exit 4.
"""
from std.os import getenv
from std.os.path import dirname, isdir

from mtest.cli.flag_spec import FlagId, FlagSpec, flag_specs
from mtest.cli.parse_result import ParseResult
from mtest.config import (
    AnnotationsMode,
    ColorWhen,
    Precompile,
    RunnerConfig,
    ShardMode,
    ShowOutput,
    Verbosity,
    resolve_mojo_path,
)

comptime MTEST_VERSION = "0.4.0"
"""The single source of the version string; `main` reuses this exact value."""

comptime SUPPORTED_SUMMARY = (
    "paths, --exclude, -I, --build-arg, --gate, --precompile, --mojo,"
    " -x/--exitfirst, --timeout, --compile-timeout, -s/--show-output, -q, -v,"
    " --color, -k, --maxfail, --durations, --shard, --retries, --json,"
    " --junit-xml, --gh-annotations, collect/--collect-only, --help, --version"
)
"""A stable one-line list of what this build serves, quoted in refusals."""


def version_text() -> String:
    """The version line `main` prints for `--version` / `version`."""
    return "mtest " + MTEST_VERSION


def help_text() -> String:
    """The usage text `main` prints for `--help` / `-h` / `help`."""
    return String(
        "mtest — a pytest-like test runner for Mojo\n\n",
        "usage: mtest [run] [PATHS...] [flags] [-- BUILD-ARGS...]\n\n",
        "This build serves: ",
        SUPPORTED_SUMMARY,
        "\n",
    )


# --- error builders (every message is `cli:`-prefixed and points at help) ---


def _err(body: String) -> Error:
    """A `cli:`-prefixed usage error ending in the `(see mtest --help)` tail."""
    return Error("cli: " + body + " (see mtest --help)")


def _refuse(spec: FlagSpec) -> Error:
    """The refusal for a flag in the contract but not served by this build."""
    return Error(
        "cli: '"
        + spec.spelling
        + "' is part of the mtest v1 contract but is not available in this"
        + " build (it arrives with "
        + spec.arrives_with
        + "); this build serves: "
        + SUPPORTED_SUMMARY
        + " (see mtest --help)"
    )


# --- value validation ---


def _all_digits(s: String) -> Bool:
    """Whether `s` is one or more ASCII decimal digits and nothing else."""
    if s.byte_length() == 0:
        return False
    for cp in s.codepoints():
        var v = Int(cp)
        if v < 48 or v > 57:
            return False
    return True


def _parse_timeout(value: String) raises -> Int:
    """Parse a `--timeout` value: a non-negative integer (`0` disables)."""
    if not _all_digits(value):
        raise _err("'--timeout' wants an integer >= 0, got '" + value + "'")
    return atol(value)


def _parse_maxfail(value: String) raises -> Int:
    """Parse a `--maxfail` value: a non-negative integer (`0` disables)."""
    if not _all_digits(value):
        raise _err("'--maxfail' wants an integer >= 0, got '" + value + "'")
    return atol(value)


def _parse_durations(value: String) raises -> Int:
    """Parse a `--durations` value: a non-negative integer (`0` disables)."""
    if not _all_digits(value):
        raise _err("'--durations' wants an integer >= 0, got '" + value + "'")
    return atol(value)


def _parse_retries(value: String) raises -> Int:
    """Parse a `--retries` value: a non-negative integer (`0` disables)."""
    if not _all_digits(value):
        raise _err("'--retries' wants an integer >= 0, got '" + value + "'")
    return atol(value)


def _parse_compile_timeout(value: String) raises -> Int:
    """Parse `--compile-timeout`: a non-negative integer, `0` disables."""
    if not _all_digits(value):
        raise _err(
            "'--compile-timeout' wants an integer >= 0, got '" + value + "'"
        )
    return atol(value)


def _parse_show_output(value: String) raises -> ShowOutput:
    """Parse a `--show-output` mode: `failures`, `all`, or `none`."""
    if value == "failures":
        return ShowOutput.FAILURES
    if value == "all":
        return ShowOutput.ALL
    if value == "none":
        return ShowOutput.NONE
    raise _err(
        "'--show-output' wants one of failures|all|none, got '" + value + "'"
    )


def _validate_json_dest(value: String) raises -> String:
    """Syntactically validate a `--json` destination; return it unchanged.

    `-` names the stdout stream and is always valid. Any other value is a
    filesystem path: it must be non-empty and its parent directory (when it
    names one) must already exist.

    This is the parse-time check only. An empty value or a missing parent is a
    usage error (exit 4) raised before any build or run; a runtime open failure
    such as a permissions problem or descriptor exhaustion is the session's to
    detect, under a different exit code.
    """
    if value == "-":
        return value
    if value.byte_length() == 0:
        raise _err(
            "'--json' wants a destination PATH or '-', got an empty value"
        )
    var parent = String(dirname(value))
    if parent != "" and not isdir(parent):
        raise _err(
            "'--json' destination parent directory does not exist: '"
            + parent
            + "'"
        )
    return value


def _validate_junit_dest(value: String) raises -> String:
    """Syntactically validate a `--junit-xml` destination; return it unchanged.

    The value is always a filesystem path. There is no `-` stdout form, because
    a JUnit document is assembled and renamed atomically rather than streamed
    live. It must be non-empty and its parent directory (when it names one) must
    already exist.

    This is the parse-time check only. An empty value or a missing parent is a
    usage error (exit 4) raised before any build or run; a runtime creation
    failure, including the target directory being removed after this check, is
    the session's to detect, under a different exit code.
    """
    if value.byte_length() == 0:
        raise _err("'--junit-xml' wants a destination PATH, got an empty value")
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
    if value == "off":
        return AnnotationsMode.OFF
    if value == "on":
        return AnnotationsMode.ON
    if value == "auto":
        return AnnotationsMode.AUTO
    raise _err(
        "'--gh-annotations' wants one of off|on|auto, got '" + value + "'"
    )


def _parse_color(value: String) raises -> ColorWhen:
    """Parse a `--color` mode: `auto`, `always`, or `never`."""
    if value == "auto":
        return ColorWhen.AUTO
    if value == "always":
        return ColorWhen.ALWAYS
    if value == "never":
        return ColorWhen.NEVER
    raise _err("'--color' wants one of auto|always|never, got '" + value + "'")


def _parse_precompile(value: String) raises -> Precompile:
    """Parse a `--precompile SRC[:OUT]` value into its two parts."""
    var colon = value.find(":")
    if colon == -1:
        if value.byte_length() == 0:
            raise _err("'--precompile' wants SRC[:OUT], got '" + value + "'")
        return Precompile(src=value, out=Optional[String](None))
    var parts = value.split(":", 1)
    var src = String(parts[0])
    var out = String(parts[1])
    if src.byte_length() == 0 or out.byte_length() == 0:
        raise _err("'--precompile' wants SRC[:OUT], got '" + value + "'")
    return Precompile(src=src, out=Optional[String](out))


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
    if not _all_digits(ms) or not _all_digits(ns):
        raise _err_shard(value)
    var m = atol(ms)
    var n = atol(ns)
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

    Forbids output selection (`-o`), emit-type selection (`--emit`), and any
    extra Mojo source operand — a bare `*.mojo` or `*.🔥` positional that would
    reach `mojo build`. A bare value that is not a source file, such as a
    forwarded flag's value, passes.
    """
    if tok == "-o" or tok.startswith("-o="):
        raise _err(
            "forbidden build argument '"
            + tok
            + "': mtest owns output selection"
        )
    if tok == "--emit" or tok.startswith("--emit="):
        raise _err(
            "forbidden build argument '"
            + tok
            + "': mtest owns emit-type selection"
        )
    if not tok.startswith("-") and (
        tok.endswith(".mojo") or tok.endswith(".🔥")
    ):
        raise _err(
            "forbidden build argument '" + tok + "': mtest owns the source list"
        )


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
    """Parse `argv` into a run config or a help/version directive.

    A leading `help` or `version` token returns that directive immediately. A
    leading `run` or `collect` token is consumed as a subcommand, with `collect`
    equivalent to `--collect-only`. Any other first token is left to the
    general token loop, which reads it as a flag when it starts with `-` (a
    bare `-` excepted) and as a path operand otherwise, so an argument vector
    may open with a flag. Everything after a bare `--` is forwarded as a build
    argument.

    Args:
        argv: The argument tokens, excluding the program name.

    Returns:
        A `ParseResult`: a configured run, or a help/version directive.

    Raises:
        Error: A `cli:`-prefixed usage error, raised for an unknown flag, a
            missing or malformed value, a forbidden build argument, a bundled
            short-flag group, `-q` and `-v` together, a run-only flag combined
            with collect mode, `--json -` alongside an annotation tail that is
            not explicitly off, or a flag this build does not yet serve.
    """
    var start = 0
    var collect = False
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

    var paths = List[String]()
    var excludes = List[String]()
    var gates = List[String]()
    var precompiles = List[Precompile]()
    var build_args = List[String]()
    var include_paths = List[String]()
    var mojo_flag = Optional[String](None)
    var timeout_secs = 300
    var compile_timeout_secs = 600
    var show_output = ShowOutput.FAILURES
    var color = ColorWhen.AUTO
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
    var json_dest = String("")
    var saw_json = False
    var junit_dest = String("")
    var saw_junit = False
    var gh_annotations = AnnotationsMode.AUTO
    var saw_annotations = False
    var saw_show_output = False
    var saw_quiet = False
    var saw_verbose = False

    var passthrough = False
    var i = start
    while i < len(argv):
        var tok = argv[i]

        if passthrough:
            _check_build_arg(tok)
            build_args.append(tok)
            i += 1
            continue

        if tok == "--":
            passthrough = True
            i += 1
            continue

        if not tok.startswith("-") or tok == "-":
            paths.append(tok)
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
        if not s.available:
            raise _refuse(s)

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
        elif s.id == FlagId.INCLUDE:
            _check_build_arg(value)
            include_paths.append(value)
        elif s.id == FlagId.BUILD_ARG:
            _check_build_arg(value)
            build_args.append(value)
        elif s.id == FlagId.GATE:
            gates.append(value)
        elif s.id == FlagId.PRECOMPILE:
            precompiles.append(_parse_precompile(value))
        elif s.id == FlagId.MOJO:
            mojo_flag = value
        elif s.id == FlagId.TIMEOUT:
            timeout_secs = _parse_timeout(value)
        elif s.id == FlagId.COMPILE_TIMEOUT:
            compile_timeout_secs = _parse_compile_timeout(value)
        elif s.id == FlagId.SHOW_OUTPUT:
            show_output = _parse_show_output(value)
            saw_show_output = True
        elif s.id == FlagId.COLOR:
            color = _parse_color(value)
        elif s.id == FlagId.SELECT:
            keyword = value
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
        elif s.id == FlagId.RETRIES:
            retries = _parse_retries(value)
            saw_retries = True
        elif s.id == FlagId.JSON:
            json_dest = _validate_json_dest(value)
            saw_json = True
        elif s.id == FlagId.JUNIT_XML:
            junit_dest = _validate_junit_dest(value)
            saw_junit = True
        elif s.id == FlagId.GH_ANNOTATIONS:
            gh_annotations = _parse_annotations(value)
            saw_annotations = True

    # Collect mode is a listing, not a run: the run-only knobs that shape which
    # tests execute or when to stop scheduling are meaningless against it and are
    # refused loudly. `--timeout` is NOT refused — it bounds the collection
    # probes exactly as it bounds a run (a hanging probe is a TIMEOUT).
    if collect:
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

    # `--json -` owns stdout for the byte-pure event stream, so nothing else may
    # write there. The annotation tail renders to stdout too, so the ONLY way the
    # two combine is with annotations EXPLICITLY off. The default `auto` and an
    # explicit `on` are BOTH usage errors here, detected at parse time; the
    # message names both fixes so a reader can resolve it either way.
    if json_dest == "-" and gh_annotations != AnnotationsMode.OFF:
        raise _err(
            "'--json -' streams machine output to stdout, which the"
            " '--gh-annotations' tail cannot share; drop '--json -' (use"
            " '--json PATH'), or set '--gh-annotations off'"
        )

    var mojo_path = resolve_mojo_path(mojo_flag, _env_mojo())

    var cfg = RunnerConfig(
        paths=paths^,
        excludes=excludes^,
        gates=gates^,
        precompiles=precompiles^,
        build_args=build_args^,
        include_paths=include_paths^,
        mojo_path=mojo_path,
        timeout_secs=timeout_secs,
        show_output=show_output,
        verbosity=verbosity,
        color=color,
        exitfirst=exitfirst,
        keyword=keyword^,
        maxfail=maxfail,
        durations=durations,
        collect=collect,
        shard_mode=shard_mode,
        shard_m=shard_m,
        shard_n=shard_n,
        retries=retries,
        workers=1,
        compile_timeout_secs=compile_timeout_secs,
        json_dest=json_dest^,
        gh_annotations=gh_annotations,
        junit_dest=junit_dest^,
    )
    return ParseResult.run(cfg^)
