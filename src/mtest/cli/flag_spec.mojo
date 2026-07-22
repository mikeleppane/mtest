"""The flag-spec table: the single source of truth for every flag spelling.

The parser is table-driven rather than a pile of ad-hoc branches. Each accepted
*spelling* is one `FlagSpec` row carrying its arity, whether it repeats, whether
this build serves it, and — for a flag whose feature is not built yet — the
roadmap milestone that brings it. Two spellings of the same flag (`-x` and
`--exitfirst`) are two rows sharing one `id`.

`flag_specs()` exposes the whole table so the command-line contract can be
checked against an independently written inventory rather than against itself.
"""


struct FlagId:
    """Stable identity of a flag, shared by all its spellings.

    A namespace of integer discriminants that lets the parser route a matched
    spelling to the right accumulation no matter which spelling was typed. Each
    name is the flag it identifies, but the authoritative mapping from an id to
    its spellings is the `flag_specs()` table below, which is where the less
    obvious pairings live: SELECT is `-k`, SHOW_ALL is `-s`, and WORKERS is
    `-n`/`--workers`.
    """

    comptime EXCLUDE = 0
    comptime INCLUDE = 1
    comptime BUILD_ARG = 2
    comptime PRECOMPILE = 3
    comptime MOJO = 4
    comptime EXITFIRST = 5
    comptime TIMEOUT = 6
    comptime SHOW_ALL = 7
    comptime SHOW_OUTPUT = 8
    comptime QUIET = 9
    comptime VERBOSE = 10
    comptime COLOR = 11
    comptime HELP = 12
    comptime VERSION = 13
    # Recognized but not served by this build (refused with a milestone note).
    comptime SELECT = 14
    comptime MAXFAIL = 15
    comptime WORKERS = 16
    comptime COMPILE_TIMEOUT = 17
    comptime RETRIES = 18
    comptime GATE = 19
    comptime JUNIT_XML = 20
    comptime GH_ANNOTATIONS = 21
    comptime COLLECT_ONLY = 22
    comptime DURATIONS = 23
    comptime SHARD = 24
    comptime SERIAL = 25
    comptime JSON = 26


@fieldwise_init
struct FlagSpec(Copyable, Movable):
    """One accepted flag spelling and everything the parser needs about it.

    Owns its `String` fields, so every copy is an explicit `.copy()`.
    """

    var spelling: String
    """The exact token that names this flag, e.g. `--exclude` or `-x`."""

    var id: Int
    """The flag identity (`FlagId.*`), shared across a flag's spellings."""

    var arity: Int
    """`0` for a valueless flag, `1` for a flag that takes one value."""

    var repeatable: Bool
    """Whether the flag may appear more than once, accumulating values.

    Documents the flag's contract; the tokenizer does not consult it. Whether a
    repeat accumulates or overwrites is decided by that flag's branch in
    `parse_args`."""

    var available: Bool
    """Whether this build serves the flag; if not, it is refused before the
    run starts."""

    var arrives_with: String
    """For a refused flag, the milestone that brings it; empty if available."""


def flag_specs() -> List[FlagSpec]:
    """The whole flag-spec table, one row per accepted spelling.

    Returns:
        A freshly allocated list holding every accepted spelling, in table
        order.
    """
    return [
        # Available in this build.
        FlagSpec("--exclude", FlagId.EXCLUDE, 1, True, True, ""),
        FlagSpec("-I", FlagId.INCLUDE, 1, True, True, ""),
        FlagSpec("--build-arg", FlagId.BUILD_ARG, 1, True, True, ""),
        FlagSpec("--gate", FlagId.GATE, 1, True, True, ""),
        FlagSpec("--precompile", FlagId.PRECOMPILE, 1, True, True, ""),
        FlagSpec("--mojo", FlagId.MOJO, 1, False, True, ""),
        FlagSpec("-x", FlagId.EXITFIRST, 0, False, True, ""),
        FlagSpec("--exitfirst", FlagId.EXITFIRST, 0, False, True, ""),
        FlagSpec("--timeout", FlagId.TIMEOUT, 1, False, True, ""),
        FlagSpec("-s", FlagId.SHOW_ALL, 0, False, True, ""),
        FlagSpec("--show-output", FlagId.SHOW_OUTPUT, 1, False, True, ""),
        FlagSpec("-q", FlagId.QUIET, 0, False, True, ""),
        FlagSpec("-v", FlagId.VERBOSE, 0, False, True, ""),
        FlagSpec("--color", FlagId.COLOR, 1, False, True, ""),
        FlagSpec("-h", FlagId.HELP, 0, False, True, ""),
        FlagSpec("--help", FlagId.HELP, 0, False, True, ""),
        FlagSpec("--version", FlagId.VERSION, 0, False, True, ""),
        FlagSpec("-k", FlagId.SELECT, 1, False, True, ""),
        FlagSpec("--maxfail", FlagId.MAXFAIL, 1, False, True, ""),
        FlagSpec("--durations", FlagId.DURATIONS, 1, False, True, ""),
        FlagSpec("--shard", FlagId.SHARD, 1, False, True, ""),
        FlagSpec("--retries", FlagId.RETRIES, 1, False, True, ""),
        FlagSpec(
            "--compile-timeout", FlagId.COMPILE_TIMEOUT, 1, False, True, ""
        ),
        FlagSpec("-n", FlagId.WORKERS, 1, False, True, ""),
        FlagSpec("--workers", FlagId.WORKERS, 1, False, True, ""),
        # Part of the v1 contract but not served by this build.
        FlagSpec(
            "--serial",
            FlagId.SERIAL,
            1,
            True,
            False,
            "serial execution pinning",
        ),
        FlagSpec("--json", FlagId.JSON, 1, False, True, ""),
        FlagSpec("--junit-xml", FlagId.JUNIT_XML, 1, False, True, ""),
        FlagSpec("--gh-annotations", FlagId.GH_ANNOTATIONS, 1, False, True, ""),
        FlagSpec("--collect-only", FlagId.COLLECT_ONLY, 0, False, True, ""),
    ]
