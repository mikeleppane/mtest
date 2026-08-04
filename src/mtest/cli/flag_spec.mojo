"""The flag-spec table: the single source of truth for every flag spelling.

The parser is table-driven rather than a pile of ad-hoc branches. Each accepted
*spelling* is one `FlagSpec` row carrying its arity, repetition behavior, owned
help metadata, and how its value is shaped. Two spellings of the same flag
(`-x` and `--exitfirst`) are two rows sharing one `id`.

A row's `applicability` names the subcommands whose grammar accepts the
spelling, as a bitmask over `Subcommand`. It is a description of the parser's
refusals, not their source: each refusal is hand-written prose naming the flag
and stating why that command cannot honor it, and a bit cannot reconstruct
prose. `tests/unit/test_cli_inventory.mojo` holds the two-directional check that
keeps the two from drifting — every masked pair parses, every unmasked pair is
refused. `subcommand_specs()` is the matching table for the heads themselves:
the `Subcommands` help block is rendered from it, and each row also carries the
applicability bit its token selects and the state a completion script enters
after it, so the token-to-head mapping is a field on the row rather than a
branch in whatever consumes it.

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


struct Subcommand:
    """Bit positions for flag applicability, one per flag-accepting head.

    `new`, `init`, and `completions` are absent because none has a flag table
    to describe: `new` and `completions` accept only `-h`/`--help` beside their
    one operand, and `init` accepts `--ci VALUE` beside them, which is
    deliberately not a `flag_specs()` row. `help` and `version` are absent
    because they are directives that consume the whole vector.
    """

    comptime RUN = 1
    """The default run mode (head token `run`, or no head token at all)."""
    comptime COLLECT = 2
    """The `collect` listing mode, and the `--collect-only` spelling of it."""
    comptime CONFIG_SHOW = 4
    """The two-token `config show` resolution display."""
    comptime DOCTOR = 8
    """The `doctor` environment diagnosis."""
    comptime DEBUG = 16
    """The `debug` single-test terminal handover."""


@fieldwise_init
struct SubcommandSpec(Copyable, Movable):
    """One head token: its help row, its flag grammar, and its completion.

    The usage lines above that block stay hand-written: each one spells out a
    different subset of a command's grammar, which is prose rather than a
    field. Owns its `String` fields, so every copy is an explicit `.copy()`.

    Examples:

    ```mojo
    from mtest.cli import subcommand_specs

    for spec in subcommand_specs():
        print(spec.token, spec.description)
    ```
    """

    var token: String
    """The head token; `config` carries its `show` tail in `label_args`."""

    var label_args: String
    """The argument part of the row's label, or empty when it takes none."""

    var description: String
    """The row's help text, at most 48 codepoints so the row fits 78."""

    var head_bit: Int
    """The `Subcommand` bit this token selects, or `0` for a token with none.

    Zero says the token has no flag grammar to describe, which is why the
    `Subcommand` namespace above holds five bits and this table ten rows. A
    nonzero bit is the same one `flag_specs()` masks against, so the head a
    completion script offers flags for and the head whose refusals the mask
    describes are one fact rather than two lists that agree today."""

    var completion_state: String
    """The state a completion script enters after this token, empty for none.

    Empty means the script offers nothing after the token, which is what makes
    a subcommand added to this table offer nothing rather than silently
    inheriting the run grammar. It is not derivable from `head_bit` and is
    deliberately a second field: `completions` has no bit at all yet completes
    its shell operand, so a token can carry a state without a grammar."""


def subcommand_specs() -> List[SubcommandSpec]:
    """The `Subcommands` help block, one row per head, in help order.

    Returns:
        A freshly allocated list holding every subcommand row, in the order
        `help_text` renders them.
    """
    return [
        SubcommandSpec(
            token="run",
            label_args="[PATHS...] [flags]",
            description="Run tests (the default subcommand).",
            head_bit=Subcommand.RUN,
            completion_state="run",
        ),
        SubcommandSpec(
            token="collect",
            label_args="[PATHS...] [flags]",
            description="List node ids without running tests.",
            head_bit=Subcommand.COLLECT,
            completion_state="collect",
        ),
        SubcommandSpec(
            token="config",
            label_args="show [PATHS...]",
            description="Show resolved configuration.",
            head_bit=Subcommand.CONFIG_SHOW,
            completion_state="config-show",
        ),
        SubcommandSpec(
            token="doctor",
            label_args="[flags]",
            description="Diagnose the environment without running tests.",
            head_bit=Subcommand.DOCTOR,
            completion_state="doctor",
        ),
        SubcommandSpec(
            token="debug",
            label_args="PATH::TEST",
            description="Run one test with the terminal handed over.",
            head_bit=Subcommand.DEBUG,
            completion_state="debug",
        ),
        SubcommandSpec(
            token="new",
            label_args="PATH",
            description="Create one runnable test file.",
            head_bit=0,
            completion_state="",
        ),
        SubcommandSpec(
            token="init",
            label_args="[--ci github]",
            description="Bootstrap a project in this directory.",
            head_bit=0,
            completion_state="",
        ),
        # The row where the two fields genuinely diverge: no flag grammar to
        # mask against, but a closed shell vocabulary to complete after it.
        SubcommandSpec(
            token="completions",
            label_args="SHELL",
            description="Print a bash, zsh, or fish completion script.",
            head_bit=0,
            completion_state="completions",
        ),
        SubcommandSpec(
            token="help",
            label_args="",
            description="Show this help and exit.",
            head_bit=0,
            completion_state="",
        ),
        SubcommandSpec(
            token="version",
            label_args="",
            description="Show the version and exit.",
            head_bit=0,
            completion_state="",
        ),
    ]


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

    var applicability: Int
    """The `Subcommand` bits whose grammar accepts this spelling.

    A set bit means the parser does not refuse the spelling under that head,
    which includes the flags it accepts and ignores: `-q` under `debug` and
    `--serial` under `collect` are applicable because they parse, even though
    neither changes anything. A cleared bit means some hand-written refusal in
    `parse_args` names this flag for that head."""


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
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DEBUG,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DEBUG,
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
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DEBUG,
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
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR,
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
            Subcommand.COLLECT,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
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
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR,
        ),
    ]
