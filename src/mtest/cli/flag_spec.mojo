"""The flag-spec table: the single source of truth for every flag spelling.

The parser is table-driven rather than a pile of ad-hoc branches. Each accepted
*spelling* is one `FlagSpec` row carrying its arity, repetition behavior, and
owned help metadata. Two spellings of the same flag (`-x` and `--exitfirst`)
are two rows sharing one `id`.

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
    comptime CONFIG = 27
    comptime NO_CONFIG = 28
    comptime LAST_FAILED = 29
    comptime FAILED_FIRST = 30
    comptime NO_CACHE = 31
    comptime CACHE_CLEAR = 32


struct FlagGroup:
    """Closed identities for the six user-facing help sections."""

    comptime SELECTION = 0
    comptime EXECUTION = 1
    comptime BUILDING = 2
    comptime REPORTING = 3
    comptime SESSION_STATE = 4
    comptime GENERAL = 5


def flag_group_name(group: Int) -> String:
    """Return the heading for a help-group identity.

    An invalid identity is rendered visibly rather than indexing a table or
    trapping. The inventory tests reject such an identity before release.

    Args:
        group: One of the `FlagGroup` integer constants.

    Returns:
        The user-facing section heading, or `Invalid` for a corrupt identity.
    """
    if group == FlagGroup.SELECTION:
        return "Selection"
    if group == FlagGroup.EXECUTION:
        return "Execution"
    if group == FlagGroup.BUILDING:
        return "Building"
    if group == FlagGroup.REPORTING:
        return "Reporting"
    if group == FlagGroup.SESSION_STATE:
        return "Session state"
    if group == FlagGroup.GENERAL:
        return "General"
    return "Invalid"


@fieldwise_init
struct FlagSpec(Copyable, Movable):
    """One accepted flag spelling and everything the parser needs about it.

    Owns its `String` fields, so every copy is an explicit `.copy()`.

    Examples:

    ```mojo
    from mtest.cli import flag_specs

    for spec in flag_specs():
        if spec.arity == 1:
            print(spec.spelling, spec.value_name)
    ```
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

    var help: String
    """The canonical one-line description for this spelling's help row."""

    var value_name: String
    """The rendered value placeholder, or empty for an arity-zero flag."""

    var group: Int
    """The closed `FlagGroup` identity that owns this spelling."""


def flag_specs() -> List[FlagSpec]:
    """The whole flag-spec table, one row per accepted spelling.

    Returns:
        A freshly allocated list holding every accepted spelling, in table
        order.
    """
    return [
        # Selection.
        FlagSpec(
            "--exclude",
            FlagId.EXCLUDE,
            1,
            True,
            "Exclude matching files (repeatable).",
            "GLOB",
            FlagGroup.SELECTION,
        ),
        FlagSpec(
            "-k",
            FlagId.SELECT,
            1,
            False,
            "Select node ids containing STR.",
            "STR",
            FlagGroup.SELECTION,
        ),
        FlagSpec(
            "--gate",
            FlagId.GATE,
            1,
            True,
            "Run PATH before ordinary files (repeatable).",
            "PATH",
            FlagGroup.SELECTION,
        ),
        FlagSpec(
            "--shard",
            FlagId.SHARD,
            1,
            False,
            "Run only the selected shard.",
            "[hash:|slice:]M/N",
            FlagGroup.SELECTION,
        ),
        # Execution.
        FlagSpec(
            "-x",
            FlagId.EXITFIRST,
            0,
            False,
            "Stop after the first failing file.",
            "",
            FlagGroup.EXECUTION,
        ),
        FlagSpec(
            "--exitfirst",
            FlagId.EXITFIRST,
            0,
            False,
            "Stop after the first failing file.",
            "",
            FlagGroup.EXECUTION,
        ),
        FlagSpec(
            "--maxfail",
            FlagId.MAXFAIL,
            1,
            False,
            "Stop after N failed tests (0 disables).",
            "N",
            FlagGroup.EXECUTION,
        ),
        FlagSpec(
            "--timeout",
            FlagId.TIMEOUT,
            1,
            False,
            "Set per-file run timeout (0 disables).",
            "SECS",
            FlagGroup.EXECUTION,
        ),
        FlagSpec(
            "--retries",
            FlagId.RETRIES,
            1,
            False,
            "Retry crash-class outcomes N times.",
            "N",
            FlagGroup.EXECUTION,
        ),
        FlagSpec(
            "-n",
            FlagId.WORKERS,
            1,
            False,
            "Set worker count (default: 1).",
            "N|auto",
            FlagGroup.EXECUTION,
        ),
        FlagSpec(
            "--workers",
            FlagId.WORKERS,
            1,
            False,
            "Set worker count (default: 1).",
            "N|auto",
            FlagGroup.EXECUTION,
        ),
        FlagSpec(
            "--serial",
            FlagId.SERIAL,
            1,
            True,
            "Run matching files serially (repeatable).",
            "GLOB",
            FlagGroup.EXECUTION,
        ),
        # CLI-only, exempt from mtest.toml by design (build-cache Task 9).
        FlagSpec(
            "--no-cache",
            FlagId.NO_CACHE,
            0,
            False,
            "Build without reading/writing the build cache.",
            "",
            FlagGroup.EXECUTION,
        ),
        FlagSpec(
            "--cache-clear",
            FlagId.CACHE_CLEAR,
            0,
            False,
            "Delete .mtest-cache (cache/last-run state), run.",
            "",
            FlagGroup.EXECUTION,
        ),
        # Building.
        FlagSpec(
            "-I",
            FlagId.INCLUDE,
            1,
            True,
            "Add a Mojo include path (repeatable).",
            "PATH",
            FlagGroup.BUILDING,
        ),
        FlagSpec(
            "--build-arg",
            FlagId.BUILD_ARG,
            1,
            True,
            "Forward one argument to mojo build (repeatable).",
            "ARG",
            FlagGroup.BUILDING,
        ),
        FlagSpec(
            "--precompile",
            FlagId.PRECOMPILE,
            1,
            True,
            "Precompile package before builds (repeatable).",
            "SRC[:OUT]",
            FlagGroup.BUILDING,
        ),
        FlagSpec(
            "--mojo",
            FlagId.MOJO,
            1,
            False,
            "Use this Mojo executable.",
            "PATH",
            FlagGroup.BUILDING,
        ),
        FlagSpec(
            "--compile-timeout",
            FlagId.COMPILE_TIMEOUT,
            1,
            False,
            "Set per-file build timeout (0 disables).",
            "SECS",
            FlagGroup.BUILDING,
        ),
        # Reporting.
        FlagSpec(
            "-s",
            FlagId.SHOW_ALL,
            0,
            False,
            "Show captured output for all files.",
            "",
            FlagGroup.REPORTING,
        ),
        FlagSpec(
            "--show-output",
            FlagId.SHOW_OUTPUT,
            1,
            False,
            "Choose failures|all|none captured output.",
            "MODE",
            FlagGroup.REPORTING,
        ),
        FlagSpec(
            "--durations",
            FlagId.DURATIONS,
            1,
            False,
            "Show N slowest file durations (0 disables).",
            "N",
            FlagGroup.REPORTING,
        ),
        FlagSpec(
            "-q",
            FlagId.QUIET,
            0,
            False,
            "Suppress passing file rows.",
            "",
            FlagGroup.REPORTING,
        ),
        FlagSpec(
            "-v",
            FlagId.VERBOSE,
            0,
            False,
            "Show build commands and step timings.",
            "",
            FlagGroup.REPORTING,
        ),
        FlagSpec(
            "--color",
            FlagId.COLOR,
            1,
            False,
            "Choose auto|always|never color output.",
            "WHEN",
            FlagGroup.REPORTING,
        ),
        FlagSpec(
            "--json",
            FlagId.JSON,
            1,
            False,
            "Write NDJSON events to PATH or stdout.",
            "PATH|-",
            FlagGroup.REPORTING,
        ),
        FlagSpec(
            "--junit-xml",
            FlagId.JUNIT_XML,
            1,
            False,
            "Write a JUnit XML report.",
            "PATH",
            FlagGroup.REPORTING,
        ),
        FlagSpec(
            "--gh-annotations",
            FlagId.GH_ANNOTATIONS,
            1,
            False,
            "Choose off|on|auto GitHub annotations.",
            "MODE",
            FlagGroup.REPORTING,
        ),
        # Session state.
        FlagSpec(
            "--config",
            FlagId.CONFIG,
            1,
            False,
            "Use this project configuration file.",
            "PATH",
            FlagGroup.SESSION_STATE,
        ),
        FlagSpec(
            "--no-config",
            FlagId.NO_CONFIG,
            0,
            False,
            "Disable project configuration discovery.",
            "",
            FlagGroup.SESSION_STATE,
        ),
        FlagSpec(
            "--lf",
            FlagId.LAST_FAILED,
            0,
            False,
            "Run only entries from the last-failed state.",
            "",
            FlagGroup.SESSION_STATE,
        ),
        FlagSpec(
            "--last-failed",
            FlagId.LAST_FAILED,
            0,
            False,
            "Run only entries from the last-failed state.",
            "",
            FlagGroup.SESSION_STATE,
        ),
        FlagSpec(
            "--ff",
            FlagId.FAILED_FIRST,
            0,
            False,
            "Run last-failed entries before the rest.",
            "",
            FlagGroup.SESSION_STATE,
        ),
        FlagSpec(
            "--failed-first",
            FlagId.FAILED_FIRST,
            0,
            False,
            "Run last-failed entries before the rest.",
            "",
            FlagGroup.SESSION_STATE,
        ),
        # General.
        FlagSpec(
            "--collect-only",
            FlagId.COLLECT_ONLY,
            0,
            False,
            "List node ids without running tests.",
            "",
            FlagGroup.GENERAL,
        ),
        FlagSpec(
            "-h",
            FlagId.HELP,
            0,
            False,
            "Show this help and exit.",
            "",
            FlagGroup.GENERAL,
        ),
        FlagSpec(
            "--help",
            FlagId.HELP,
            0,
            False,
            "Show this help and exit.",
            "",
            FlagGroup.GENERAL,
        ),
        FlagSpec(
            "--version",
            FlagId.VERSION,
            0,
            False,
            "Show the version and exit.",
            "",
            FlagGroup.GENERAL,
        ),
    ]
