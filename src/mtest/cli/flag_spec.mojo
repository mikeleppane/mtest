"""The flag-spec table: the single source of truth for every flag spelling.

The parser is table-driven, not a pile of ad-hoc branches. Each accepted
*spelling* is one `FlagSpec` row carrying its own arity, whether it repeats,
whether this build serves it, and — for a flag whose feature is not built yet —
the roadmap milestone that brings it. Two spellings of the same flag (`-x` and
`--exitfirst`) are two rows sharing one `id`.

`flag_specs()` returns the whole table so a test can cross-check it against an
independently hand-written inventory of the command-line contract; the table can
never become its own oracle.
"""


struct FlagId:
    """Stable identity of a flag, shared by all its spellings.

    A thin namespace of integer discriminants so the parser routes a matched
    spelling to the right accumulation regardless of which spelling was typed.
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


@fieldwise_init
struct FlagSpec(Copyable, Movable):
    """One accepted flag spelling and everything the parser needs about it.

    Owns its `String` fields, so copies are explicit; reads never mutate or
    raise.
    """

    var spelling: String
    """The exact token that names this flag, e.g. `--exclude` or `-x`."""

    var id: Int
    """The flag identity (`FlagId.*`); shared across a flag's spellings."""

    var arity: Int
    """`0` for a valueless flag, `1` for a flag that takes one value."""

    var repeatable: Bool
    """Whether the flag may appear more than once, accumulating values."""

    var available: Bool
    """Whether this build serves the flag (else it is refused pre-run)."""

    var arrives_with: String
    """For a refused flag, the milestone that brings it; empty when available."""


def flag_specs() -> List[FlagSpec]:
    """The whole flag-spec table, one row per accepted spelling.

    The single source of truth the tokenizer looks flags up in and the
    inventory test cross-checks. Allocates a fresh list; does not mutate global
    state or raise.
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
        # Part of the v1 contract but not served by this build.
        FlagSpec("-n", FlagId.WORKERS, 1, False, False, "parallel workers"),
        FlagSpec(
            "--workers", FlagId.WORKERS, 1, False, False, "parallel workers"
        ),
        FlagSpec(
            "--compile-timeout",
            FlagId.COMPILE_TIMEOUT,
            1,
            False,
            False,
            "the module-cache quarantine",
        ),
        FlagSpec(
            "--retries",
            FlagId.RETRIES,
            1,
            False,
            False,
            "retries and flaky handling",
        ),
        FlagSpec(
            "--junit-xml",
            FlagId.JUNIT_XML,
            1,
            False,
            False,
            "machine report artifacts",
        ),
        FlagSpec(
            "--gh-annotations",
            FlagId.GH_ANNOTATIONS,
            1,
            False,
            False,
            "CI annotations",
        ),
        FlagSpec("--collect-only", FlagId.COLLECT_ONLY, 0, False, True, ""),
    ]
