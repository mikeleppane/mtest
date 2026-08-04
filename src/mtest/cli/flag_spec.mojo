"""The flag-spec table: the single source of truth for every flag spelling.

The parser is table-driven rather than a pile of ad-hoc branches. Each accepted
*spelling* is one `FlagSpec` row carrying its arity, repetition behavior, owned
help metadata, and how its value is shaped. Two spellings of the same flag
(`-x` and `--exitfirst`) are two rows sharing one `id`.

A row's `value_kind` and `choices` describe what the parser actually accepts,
never an idealized domain: a `CHOICE` row's list is the exact closed set the
matching `parse_*_value` validates against, taken from `mtest.config` rather
than restated here, so the two cannot drift. Where the parser accepts more than
a kind can express, the row says so by naming the wider kind — `OTHER` for a
value with no useful completion, `CHOICE_OR_OTHER` where a closed arm sits
beside free text.

`flag_specs()` exposes the whole table so the command-line contract can be
checked against an independently written inventory rather than against itself.
"""
from mtest.config import (
    annotations_choices,
    collect_format_choices,
    color_choices,
    report_format_prefixes,
    report_style_choices,
    show_output_choices,
    workers_choices,
)


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
    comptime FAIL_ON_FLAKY = 33
    comptime SHUFFLE = 34
    comptime SEED = 35
    comptime FORMAT = 36
    comptime REPORT = 37
    comptime REPORT_STYLE = 38


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
struct ValueKind(Equatable, ImplicitlyCopyable, Movable):
    """How a flag's value completes.

    A wrapper over a stable integer discriminant, so the vocabulary is a closed
    set of named constants that compare by value. The kind describes the
    parser's real accepting behavior, which is what makes it safe for a
    completion renderer to act on: a kind that promised less than the parser
    accepts would refuse to offer a legal value, and one that promised more
    would offer a value the parser rejects.

    Examples:

    ```mojo
    from mtest.cli import ValueKind, flag_specs

    for spec in flag_specs():
        if spec.value_kind == ValueKind.CHOICE:
            print(spec.spelling, len(spec.choices))
    ```
    """

    var code: Int
    """The stable integer discriminant."""

    comptime NONE = Self(0)
    """Arity-0: the flag takes no value at all."""
    comptime PATH = Self(1)
    """A filesystem path: complete against the filesystem."""
    comptime CHOICE = Self(2)
    """Exactly the row's closed choice list, and nothing else."""
    comptime CHOICE_OR_OTHER = Self(3)
    """The closed list plus free text the list cannot enumerate."""
    comptime PREFIX_CHOICE = Self(4)
    """One of the row's closed prefixes, then a free path after it."""
    comptime OTHER = Self(5)
    """Free text with no useful completion: offer nothing."""

    def __eq__(self, other: Self) -> Bool:
        """Two kinds are equal when their discriminants are equal."""
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return self.code != other.code


@fieldwise_init
struct FlagSpec(Copyable, Movable):
    """One accepted flag spelling and everything the parser needs about it.

    Owns its `String` and `List` fields, so every copy is an explicit
    `.copy()`.

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

    var value_kind: ValueKind
    """How this spelling's value completes; `NONE` for an arity-zero flag."""

    var choices: List[String]
    """The closed values this spelling accepts, empty unless the kind is closed.

    Non-empty exactly for `CHOICE`, `CHOICE_OR_OTHER`, and `PREFIX_CHOICE`, and
    always the same list the matching `mtest.config` validator decides
    membership against, never a second transcription of it."""


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
            ValueKind.OTHER,
            List[String](),
        ),
        FlagSpec(
            "-k",
            FlagId.SELECT,
            1,
            False,
            "Select node ids containing STR.",
            "STR",
            FlagGroup.SELECTION,
            ValueKind.OTHER,
            List[String](),
        ),
        FlagSpec(
            "--gate",
            FlagId.GATE,
            1,
            True,
            "Run PATH before ordinary files (repeatable).",
            "PATH",
            FlagGroup.SELECTION,
            ValueKind.PATH,
            List[String](),
        ),
        FlagSpec(
            "--shard",
            FlagId.SHARD,
            1,
            False,
            "Run only the selected shard.",
            "[hash:|slice:]M/N",
            FlagGroup.SELECTION,
            ValueKind.OTHER,
            List[String](),
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
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--exitfirst",
            FlagId.EXITFIRST,
            0,
            False,
            "Stop after the first failing file.",
            "",
            FlagGroup.EXECUTION,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--maxfail",
            FlagId.MAXFAIL,
            1,
            False,
            "Stop after N failed tests (0 disables).",
            "N",
            FlagGroup.EXECUTION,
            ValueKind.OTHER,
            List[String](),
        ),
        FlagSpec(
            "--timeout",
            FlagId.TIMEOUT,
            1,
            False,
            "Set per-file run timeout (0 disables).",
            "SECS",
            FlagGroup.EXECUTION,
            ValueKind.OTHER,
            List[String](),
        ),
        FlagSpec(
            "--retries",
            FlagId.RETRIES,
            1,
            False,
            "Retry crash-class outcomes N times.",
            "N",
            FlagGroup.EXECUTION,
            ValueKind.OTHER,
            List[String](),
        ),
        FlagSpec(
            "--fail-on-flaky",
            FlagId.FAIL_ON_FLAKY,
            0,
            False,
            "Exit 1 when any file passed only after retries.",
            "",
            FlagGroup.EXECUTION,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "-n",
            FlagId.WORKERS,
            1,
            False,
            "Set worker count (default: 1).",
            "N|auto",
            FlagGroup.EXECUTION,
            ValueKind.CHOICE_OR_OTHER,
            workers_choices(),
        ),
        FlagSpec(
            "--workers",
            FlagId.WORKERS,
            1,
            False,
            "Set worker count (default: 1).",
            "N|auto",
            FlagGroup.EXECUTION,
            ValueKind.CHOICE_OR_OTHER,
            workers_choices(),
        ),
        FlagSpec(
            "--serial",
            FlagId.SERIAL,
            1,
            True,
            "Run matching files serially (repeatable).",
            "GLOB",
            FlagGroup.EXECUTION,
            ValueKind.OTHER,
            List[String](),
        ),
        FlagSpec(
            "--shuffle",
            FlagId.SHUFFLE,
            0,
            False,
            "Randomize run-file order (gates keep theirs).",
            "",
            FlagGroup.EXECUTION,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--seed",
            FlagId.SEED,
            1,
            False,
            "Fix the --shuffle order to a reproducible seed.",
            "N",
            FlagGroup.EXECUTION,
            ValueKind.OTHER,
            List[String](),
        ),
        # CLI-only, exempt from mtest.toml by design (build cache).
        FlagSpec(
            "--no-cache",
            FlagId.NO_CACHE,
            0,
            False,
            "Build without reading/writing the build cache.",
            "",
            FlagGroup.EXECUTION,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--cache-clear",
            FlagId.CACHE_CLEAR,
            0,
            False,
            "Delete .mtest-cache (cache/last-run state), run.",
            "",
            FlagGroup.EXECUTION,
            ValueKind.NONE,
            List[String](),
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
            ValueKind.PATH,
            List[String](),
        ),
        FlagSpec(
            "--build-arg",
            FlagId.BUILD_ARG,
            1,
            True,
            "Forward one argument to mojo build (repeatable).",
            "ARG",
            FlagGroup.BUILDING,
            ValueKind.OTHER,
            List[String](),
        ),
        FlagSpec(
            "--precompile",
            FlagId.PRECOMPILE,
            1,
            True,
            "Precompile package before builds (repeatable).",
            "SRC[:OUT]",
            FlagGroup.BUILDING,
            ValueKind.PATH,
            List[String](),
        ),
        FlagSpec(
            "--mojo",
            FlagId.MOJO,
            1,
            False,
            "Use this Mojo executable.",
            "PATH",
            FlagGroup.BUILDING,
            ValueKind.PATH,
            List[String](),
        ),
        FlagSpec(
            "--compile-timeout",
            FlagId.COMPILE_TIMEOUT,
            1,
            False,
            "Set per-file build timeout (0 disables).",
            "SECS",
            FlagGroup.BUILDING,
            ValueKind.OTHER,
            List[String](),
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
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--show-output",
            FlagId.SHOW_OUTPUT,
            1,
            False,
            "Choose failures|all|none captured output.",
            "MODE",
            FlagGroup.REPORTING,
            ValueKind.CHOICE,
            show_output_choices(),
        ),
        FlagSpec(
            "--durations",
            FlagId.DURATIONS,
            1,
            False,
            "Show N slowest file durations (0 disables).",
            "N",
            FlagGroup.REPORTING,
            ValueKind.OTHER,
            List[String](),
        ),
        FlagSpec(
            "-q",
            FlagId.QUIET,
            0,
            False,
            "Suppress passing file rows.",
            "",
            FlagGroup.REPORTING,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "-v",
            FlagId.VERBOSE,
            0,
            False,
            "Show build commands and step timings.",
            "",
            FlagGroup.REPORTING,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--color",
            FlagId.COLOR,
            1,
            False,
            "Choose auto|always|never color output.",
            "WHEN",
            FlagGroup.REPORTING,
            ValueKind.CHOICE,
            color_choices(),
        ),
        FlagSpec(
            "--format",
            FlagId.FORMAT,
            1,
            False,
            "Collect output format: lines (default) or json.",
            "FORMAT",
            FlagGroup.REPORTING,
            ValueKind.CHOICE,
            collect_format_choices(),
        ),
        # `PATH` understates this one row by a single token: `--json` also
        # accepts a bare `-` for stdout, which no other destination flag does
        # (`--junit-xml` and `--report` are assembled and renamed, so they have
        # no stream form). Path completion is the useful behavior and stays;
        # a caller that wants to offer the dash too has to special-case it
        # here rather than read it off the kind.
        FlagSpec(
            "--json",
            FlagId.JSON,
            1,
            False,
            "Write NDJSON events to PATH or stdout.",
            "PATH|-",
            FlagGroup.REPORTING,
            ValueKind.PATH,
            List[String](),
        ),
        FlagSpec(
            "--junit-xml",
            FlagId.JUNIT_XML,
            1,
            False,
            "Write a JUnit XML report.",
            "PATH",
            FlagGroup.REPORTING,
            ValueKind.PATH,
            List[String](),
        ),
        FlagSpec(
            "--report",
            FlagId.REPORT,
            1,
            True,
            "Write an md or html run report (once each).",
            "FORMAT:PATH",
            FlagGroup.REPORTING,
            ValueKind.PREFIX_CHOICE,
            report_format_prefixes(),
        ),
        FlagSpec(
            "--report-style",
            FlagId.REPORT_STYLE,
            1,
            False,
            "Choose concise|full report detail.",
            "STYLE",
            FlagGroup.REPORTING,
            ValueKind.CHOICE,
            report_style_choices(),
        ),
        FlagSpec(
            "--gh-annotations",
            FlagId.GH_ANNOTATIONS,
            1,
            False,
            "Choose off|on|auto GitHub annotations.",
            "MODE",
            FlagGroup.REPORTING,
            ValueKind.CHOICE,
            annotations_choices(),
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
            ValueKind.PATH,
            List[String](),
        ),
        FlagSpec(
            "--no-config",
            FlagId.NO_CONFIG,
            0,
            False,
            "Disable project configuration discovery.",
            "",
            FlagGroup.SESSION_STATE,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--lf",
            FlagId.LAST_FAILED,
            0,
            False,
            "Run only entries from the last-failed state.",
            "",
            FlagGroup.SESSION_STATE,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--last-failed",
            FlagId.LAST_FAILED,
            0,
            False,
            "Run only entries from the last-failed state.",
            "",
            FlagGroup.SESSION_STATE,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--ff",
            FlagId.FAILED_FIRST,
            0,
            False,
            "Run last-failed entries before the rest.",
            "",
            FlagGroup.SESSION_STATE,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--failed-first",
            FlagId.FAILED_FIRST,
            0,
            False,
            "Run last-failed entries before the rest.",
            "",
            FlagGroup.SESSION_STATE,
            ValueKind.NONE,
            List[String](),
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
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "-h",
            FlagId.HELP,
            0,
            False,
            "Show this help and exit.",
            "",
            FlagGroup.GENERAL,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--help",
            FlagId.HELP,
            0,
            False,
            "Show this help and exit.",
            "",
            FlagGroup.GENERAL,
            ValueKind.NONE,
            List[String](),
        ),
        FlagSpec(
            "--version",
            FlagId.VERSION,
            0,
            False,
            "Show the version and exit.",
            "",
            FlagGroup.GENERAL,
            ValueKind.NONE,
            List[String](),
        ),
    ]
