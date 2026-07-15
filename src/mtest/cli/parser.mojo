"""The hand-rolled full-contract argument parser.

`parse_args` turns an argument vector into a `ParseResult` — a configured run or
a help/version directive — or raises a `cli:`-prefixed usage error. It parses the
*whole* v1 grammar: flags this build does not yet serve are recognized and
refused with a message naming the milestone that brings them, so later work only
flips an availability bit rather than teaching the parser a new token.

Every raise names the offending token, states the expected form, and points at
`mtest --help`. This layer never prints and never exits; `main` (a later layer)
prints help/version to stdout with exit 0 and prints a usage error to stderr with
exit 4.
"""
from std.os import getenv

from mtest.cli.flag_spec import FlagId, FlagSpec, flag_specs
from mtest.cli.parse_result import ParseResult
from mtest.config import (
    ColorWhen,
    Precompile,
    RunnerConfig,
    ShowOutput,
    Verbosity,
    resolve_mojo_path,
)

comptime MTEST_VERSION = "0.1.0-dev"
"""The single source of the version string; `main` reuses this exact value."""

comptime SUPPORTED_SUMMARY = (
    "paths, --exclude, -I, --build-arg, --gate, --precompile, --mojo,"
    " -x/--exitfirst, --timeout, -s/--show-output, -q, -v, --color, -k,"
    " --maxfail, collect/--collect-only, --help, --version"
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
    """A `cli:`-prefixed usage error ending in the `see mtest --help` pointer.
    """
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


def _check_build_arg(tok: String) raises:
    """Reject a build argument that would seize control mtest owns.

    Forbids output selection (`-o`), emit-type selection (`--emit`), and any
    extra Mojo source operand (a bare `*.mojo` / `*.🔥` positional handed to
    `mojo build`). A bare value that is not a source file (a forwarded flag's
    value) passes.
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

    Args:
        argv: The argument tokens, excluding the program name.

    Returns:
        A `ParseResult`: a configured run, or a help/version directive.

    Raises:
        A `cli:`-prefixed usage error for an unknown flag, a missing or
        malformed value, a forbidden build argument, a bundled short-flag group,
        `-q`/`-v` together, or a flag/subcommand this build does not yet serve.
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
    var show_output = ShowOutput.FAILURES
    var color = ColorWhen.AUTO
    var exitfirst = False
    var keyword = String("")
    var maxfail = 0
    var saw_maxfail = False
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

    if saw_quiet and saw_verbose:
        raise _err("'-q' and '-v' are mutually exclusive")
    var verbosity = Verbosity.NORMAL
    if saw_quiet:
        verbosity = Verbosity.QUIET
    elif saw_verbose:
        verbosity = Verbosity.VERBOSE

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
        collect=collect,
    )
    return ParseResult.run(cfg^)
