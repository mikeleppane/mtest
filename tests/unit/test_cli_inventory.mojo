"""The independent frozen-inventory and generated-help cross-checks.

`frozen_inventory()` is a HAND-WRITTEN transcription of the command-line
contract's flag table — authored by reading the contract, never generated from
the parser's own `flag_specs()`. The cross-check asserts the parser's table is a
row-for-row bijection with this frozen list, so a drifted arity or dropped
spelling fails loudly and the spec table can never be its own oracle. The help
tests independently require complete metadata and one aligned, bounded line per
spelling.

Each row also transcribes how the flag's value completes and, for a closed
vocabulary, exactly which values it accepts. That half of the table is only
worth carrying while it is true, so it is checked twice: against the frozen
transcription for drift, and against `parse_args` itself, which must accept
every declared choice and refuse a value just outside the declared set.

The last field, `applicability`, is the same idea applied to the subcommands: a
bitmask of the heads that accept the spelling. The parser's per-flag refusals
are hand-written prose and cannot be generated from a mask, so the mask is
checked against them in both directions — every masked pair parses, and every
unmasked pair is refused by a message naming the spelling. Either direction
failing alone is the defect the pair exists to catch: a completion renderer
reading a drifted mask would offer a flag the parser rejects, or hide one that
works.
"""
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

from mtest.cli import (
    FlagGroup,
    Subcommand,
    SubcommandSpec,
    ValueKind,
    flag_group_name,
    flag_specs,
    help_text,
    parse_args,
    subcommand_specs,
)
from mtest.config import AnnotationsMode, ReportStyle, ShardMode


@fieldwise_init
struct InvRow(Copyable, Movable):
    """One hand-written inventory row: a spelling and its contract facts."""

    var spelling: String
    var arity: Int
    var repeatable: Bool
    var value_name: String
    var group: Int
    var help: String
    var help_label: String
    var value_kind: ValueKind
    var choices: List[String]
    var applicability: Int


def frozen_inventory() -> List[InvRow]:
    """Every flag spelling the command-line contract carries, by hand.

    Every field but one is a contract fact authored independently from
    `flag_specs()`. `help_label` is the complete label for the physical help
    row, so aliases intentionally share one expected label.

    `applicability` is the exception, and re-transcribing it from the contract
    alone will not reproduce it. It models what `parse_args` refuses, which the
    drift tests below hold it to; where the contract's §4 table and the parser
    disagree, the parser wins here and the row carries a comment saying so.
    """
    return [
        InvRow(
            "--exclude",
            1,
            True,
            "GLOB",
            FlagGroup.SELECTION,
            "Exclude matching files (repeatable).",
            "--exclude GLOB",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "-I",
            1,
            True,
            "PATH",
            FlagGroup.BUILDING,
            "Add a Mojo include path (repeatable).",
            "-I PATH",
            ValueKind.PATH,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DEBUG,
        ),
        InvRow(
            "--build-arg",
            1,
            True,
            "ARG",
            FlagGroup.BUILDING,
            "Forward one argument to mojo build (repeatable).",
            "--build-arg ARG",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DEBUG,
        ),
        InvRow(
            "--gate",
            1,
            True,
            "PATH",
            FlagGroup.SELECTION,
            "Run PATH before ordinary files (repeatable).",
            "--gate PATH",
            ValueKind.PATH,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--precompile",
            1,
            True,
            "SRC[:OUT]",
            FlagGroup.BUILDING,
            "Precompile package before builds (repeatable).",
            "--precompile SRC[:OUT]",
            ValueKind.PATH,
            List[String](),
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--mojo",
            1,
            False,
            "PATH",
            FlagGroup.BUILDING,
            "Use this Mojo executable.",
            "--mojo PATH",
            ValueKind.PATH,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DEBUG,
        ),
        InvRow(
            "-x",
            0,
            False,
            "",
            FlagGroup.EXECUTION,
            "Stop after the first failing file.",
            "-x, --exitfirst",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--exitfirst",
            0,
            False,
            "",
            FlagGroup.EXECUTION,
            "Stop after the first failing file.",
            "-x, --exitfirst",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--timeout",
            1,
            False,
            "SECS",
            FlagGroup.EXECUTION,
            "Set per-file run timeout (0 disables).",
            "--timeout SECS",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "-s",
            0,
            False,
            "",
            FlagGroup.REPORTING,
            "Show captured output for all files.",
            "-s",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--show-output",
            1,
            False,
            "MODE",
            FlagGroup.REPORTING,
            "Choose failures|all|none captured output.",
            "--show-output MODE",
            ValueKind.CHOICE,
            ["failures", "all", "none"],
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "-q",
            0,
            False,
            "",
            FlagGroup.REPORTING,
            "Suppress passing file rows.",
            "-q",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
        ),
        InvRow(
            "-v",
            0,
            False,
            "",
            FlagGroup.REPORTING,
            "Show build commands and step timings.",
            "-v",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
        ),
        InvRow(
            "--color",
            1,
            False,
            "WHEN",
            FlagGroup.REPORTING,
            "Choose auto|always|never color output.",
            "--color WHEN",
            ValueKind.CHOICE,
            ["auto", "always", "never"],
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR,
        ),
        InvRow(
            "-h",
            0,
            False,
            "",
            FlagGroup.GENERAL,
            "Show this help and exit.",
            "-h, --help",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
        ),
        InvRow(
            "--help",
            0,
            False,
            "",
            FlagGroup.GENERAL,
            "Show this help and exit.",
            "-h, --help",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
        ),
        InvRow(
            "--version",
            0,
            False,
            "",
            FlagGroup.GENERAL,
            "Show the version and exit.",
            "--version",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR,
        ),
        InvRow(
            "-k",
            1,
            False,
            "STR",
            FlagGroup.SELECTION,
            "Select node ids containing STR.",
            "-k STR",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--maxfail",
            1,
            False,
            "N",
            FlagGroup.EXECUTION,
            "Stop after N failed tests (0 disables).",
            "--maxfail N",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        # `--durations N`: non-negative int; 0 disables.
        InvRow(
            "--durations",
            1,
            False,
            "N",
            FlagGroup.REPORTING,
            "Show N slowest file durations (0 disables).",
            "--durations N",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        # `--shard [hash:|slice:]M/N`: 1<=M<=N, last-wins.
        InvRow(
            "--shard",
            1,
            False,
            "[hash:|slice:]M/N",
            FlagGroup.SELECTION,
            "Run only the selected shard.",
            "--shard [hash:|slice:]M/N",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
        ),
        # `--retries N`: non-negative int; 0 disables.
        InvRow(
            "--retries",
            1,
            False,
            "N",
            FlagGroup.EXECUTION,
            "Retry crash-class outcomes N times.",
            "--retries N",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        # `--fail-on-flaky`: valueless; a FLAKY file turns a would-be 0 into 1.
        InvRow(
            "--fail-on-flaky",
            0,
            False,
            "",
            FlagGroup.EXECUTION,
            "Exit 1 when any file passed only after retries.",
            "--fail-on-flaky",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        # `--compile-timeout SECS`: non-negative int; 0 disables.
        InvRow(
            "--compile-timeout",
            1,
            False,
            "SECS",
            FlagGroup.BUILDING,
            "Set per-file build timeout (0 disables).",
            "--compile-timeout SECS",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
        ),
        # `-n`/`--workers N|auto`: served, last-wins.
        InvRow(
            "-n",
            1,
            False,
            "N|auto",
            FlagGroup.EXECUTION,
            "Set worker count (default: 1).",
            "-n, --workers N|auto",
            ValueKind.CHOICE_OR_OTHER,
            ["auto"],
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--workers",
            1,
            False,
            "N|auto",
            FlagGroup.EXECUTION,
            "Set worker count (default: 1).",
            "-n, --workers N|auto",
            ValueKind.CHOICE_OR_OTHER,
            ["auto"],
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
        ),
        # `--serial GLOB`: repeatable, now served.
        InvRow(
            "--serial",
            1,
            True,
            "GLOB",
            FlagGroup.EXECUTION,
            "Run matching files serially (repeatable).",
            "--serial GLOB",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
        ),
        # CLI-only: never read from mtest.toml (order randomization).
        InvRow(
            "--shuffle",
            0,
            False,
            "",
            FlagGroup.EXECUTION,
            "Randomize run-file order (gates keep theirs).",
            "--shuffle",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--seed",
            1,
            False,
            "N",
            FlagGroup.EXECUTION,
            "Fix the --shuffle order to a reproducible seed.",
            "--seed N",
            ValueKind.OTHER,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        # CLI-only: never read from mtest.toml (build cache).
        #
        # The DOCTOR bit on both rows is deliberate and is NOT a transcription
        # slip. `doctor` renders its diagnosis and returns before the build
        # store is read or cleared, so it accepts both flags and honors
        # neither — the accepted-inert cell §4 also gives `-n` and `--serial`
        # under `collect`. Clearing the bit to match an older reading of the
        # table reds both drift tests, because `mtest doctor --no-cache` and
        # `mtest doctor --cache-clear` really do parse.
        InvRow(
            "--no-cache",
            0,
            False,
            "",
            FlagGroup.EXECUTION,
            "Build without reading/writing the build cache.",
            "--no-cache",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR,
        ),
        InvRow(
            "--cache-clear",
            0,
            False,
            "",
            FlagGroup.EXECUTION,
            "Delete .mtest-cache (cache/last-run state), run.",
            "--cache-clear",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR,
        ),
        # `--report FORMAT:PATH` and `--report-style concise|full`: now served.
        InvRow(
            "--report",
            1,
            True,
            "FORMAT:PATH",
            FlagGroup.REPORTING,
            "Write an md or html run report (once each).",
            "--report FORMAT:PATH",
            ValueKind.PREFIX_CHOICE,
            ["md:", "html:"],
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--report-style",
            1,
            False,
            "STYLE",
            FlagGroup.REPORTING,
            "Choose concise|full report detail.",
            "--report-style STYLE",
            ValueKind.CHOICE,
            ["concise", "full"],
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        # `--gh-annotations off|on|auto`: now served.
        InvRow(
            "--gh-annotations",
            1,
            False,
            "MODE",
            FlagGroup.REPORTING,
            "Choose off|on|auto GitHub annotations.",
            "--gh-annotations MODE",
            ValueKind.CHOICE,
            ["off", "on", "auto"],
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        # `--format lines|json`: collect-only; `lines` is the default.
        InvRow(
            "--format",
            1,
            False,
            "FORMAT",
            FlagGroup.REPORTING,
            "Collect output format: lines (default) or json.",
            "--format FORMAT",
            ValueKind.CHOICE,
            ["lines", "json"],
            Subcommand.COLLECT,
        ),
        # `--json PATH|-`: now served.
        InvRow(
            "--json",
            1,
            False,
            "PATH|-",
            FlagGroup.REPORTING,
            "Write NDJSON events to PATH or stdout.",
            "--json PATH|-",
            ValueKind.PATH,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        # `--junit-xml PATH`: now served.
        InvRow(
            "--junit-xml",
            1,
            False,
            "PATH",
            FlagGroup.REPORTING,
            "Write a JUnit XML report.",
            "--junit-xml PATH",
            ValueKind.PATH,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        # Served by this build (collect mode).
        InvRow(
            "--collect-only",
            0,
            False,
            "",
            FlagGroup.GENERAL,
            "List node ids without running tests.",
            "--collect-only",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN | Subcommand.COLLECT | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--config",
            1,
            False,
            "PATH",
            FlagGroup.SESSION_STATE,
            "Use this project configuration file.",
            "--config PATH",
            ValueKind.PATH,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
        ),
        InvRow(
            "--no-config",
            0,
            False,
            "",
            FlagGroup.SESSION_STATE,
            "Disable project configuration discovery.",
            "--no-config",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN
            | Subcommand.COLLECT
            | Subcommand.CONFIG_SHOW
            | Subcommand.DOCTOR
            | Subcommand.DEBUG,
        ),
        InvRow(
            "--lf",
            0,
            False,
            "",
            FlagGroup.SESSION_STATE,
            "Run only entries from the last-failed state.",
            "--lf, --last-failed",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--last-failed",
            0,
            False,
            "",
            FlagGroup.SESSION_STATE,
            "Run only entries from the last-failed state.",
            "--lf, --last-failed",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--ff",
            0,
            False,
            "",
            FlagGroup.SESSION_STATE,
            "Run last-failed entries before the rest.",
            "--ff, --failed-first",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
        InvRow(
            "--failed-first",
            0,
            False,
            "",
            FlagGroup.SESSION_STATE,
            "Run last-failed entries before the rest.",
            "--ff, --failed-first",
            ValueKind.NONE,
            List[String](),
            Subcommand.RUN | Subcommand.CONFIG_SHOW,
        ),
    ]


def _joined(values: List[String]) -> String:
    """Render a choice list as one `|`-separated line for exact comparison."""
    var rendered = String("")
    for i in range(len(values)):
        if i > 0:
            rendered += "|"
        rendered += values[i]
    return rendered^


def _spellings_with_kind(kind: ValueKind) -> String:
    """Every spelling declaring `kind`, `|`-separated in table order."""
    var rendered = String("")
    for spec in flag_specs():
        if spec.value_kind == kind:
            if rendered != "":
                rendered += "|"
            rendered += spec.spelling
    return rendered^


def _undeclared_probe(kind: ValueKind) -> String:
    """A value shaped for `kind` that no row declares.

    The probe has to be well-formed for its kind's own grammar, or the parser
    refuses it on a structural rule before the choice list is ever consulted
    and the list stays unconstrained. A bare `not-a-declared-choice` is refused
    by `--report` for carrying no `:` at all, which would leave the prefix list
    free to gain a bogus entry without any test noticing.

    Args:
        kind: The value kind the probe must be well-formed for.

    Returns:
        A newly allocated value the parser must refuse for that kind's own
        reason.
    """
    if kind == ValueKind.PREFIX_CHOICE:
        # A complete FORMAT:PATH value; only the prefix is undeclared, so the
        # prefix list is the only thing that can refuse it.
        return "txt:probe.out"
    # A bare word. The free arm of CHOICE_OR_OTHER is a positive decimal and
    # can never accept one, so closed-list membership is the only route in.
    return "not-a-declared-choice"


def _near_miss(kind: ValueKind, choice: String) -> String:
    """A one-character perturbation of `choice`, still shaped for `kind`.

    Args:
        kind: The value kind the perturbation must stay well-formed for.
        choice: One declared choice to perturb.

    Returns:
        A newly allocated value that differs from every declared choice.
    """
    if kind == ValueKind.PREFIX_CHOICE:
        # Perturb inside the prefix, not after it: `md:x` would be a legal
        # value with `x` as the path.
        var stem = String(choice[byte = : choice.byte_length() - 1])
        return stem + "x:probe.out"
    return choice + "x"


def _argv_for(spelling: String, value: String) -> List[String]:
    """The shortest argument vector that offers `value` to `spelling`."""
    var argv = List[String]()
    # `--format` shapes a listing, so the parser refuses it outside collect.
    if spelling == "--format":
        argv.append("collect")
    argv.append(spelling)
    argv.append(value)
    return argv^


def test_spec_table_matches_frozen_inventory_count() raises:
    assert_equal(len(flag_specs()), len(frozen_inventory()))


def test_every_spec_row_is_in_the_frozen_inventory() raises:
    var inv = frozen_inventory()
    for spec in flag_specs():
        var found = False
        for row in inv:
            if row.spelling == spec.spelling:
                found = True
                assert_equal(
                    spec.arity, row.arity, "arity drift: " + spec.spelling
                )
                assert_equal(
                    spec.repeatable,
                    row.repeatable,
                    "repeatable drift: " + spec.spelling,
                )
                assert_equal(
                    spec.value_name,
                    row.value_name,
                    "value name drift: " + spec.spelling,
                )
                assert_equal(
                    spec.group,
                    row.group,
                    "help group drift: " + spec.spelling,
                )
                assert_equal(
                    spec.help,
                    row.help,
                    "help description drift: " + spec.spelling,
                )
                assert_true(
                    spec.value_kind == row.value_kind,
                    "value kind drift: " + spec.spelling,
                )
                assert_equal(
                    _joined(spec.choices),
                    _joined(row.choices),
                    "choice list drift: " + spec.spelling,
                )
                assert_equal(
                    spec.applicability,
                    row.applicability,
                    "applicability drift: " + spec.spelling,
                )
        assert_true(found, "spec not in inventory: " + spec.spelling)


def test_every_frozen_row_is_in_the_spec_table() raises:
    var specs = flag_specs()
    for row in frozen_inventory():
        var found = False
        for spec in specs:
            if spec.spelling == row.spelling:
                found = True
        assert_true(found, "inventory row missing from table: " + row.spelling)


def test_spec_spellings_are_unique() raises:
    var specs = flag_specs()
    for i in range(len(specs)):
        for j in range(i + 1, len(specs)):
            assert_true(
                specs[i].spelling != specs[j].spelling,
                "duplicate spelling: " + specs[i].spelling,
            )


def test_every_spec_row_owns_complete_help_metadata() raises:
    for spec in flag_specs():
        assert_true(
            spec.help.byte_length() > 0,
            "missing help text: " + spec.spelling,
        )
        assert_true(
            "\n" not in spec.help and "\r" not in spec.help,
            "multiline help text: " + spec.spelling,
        )
        assert_true(
            spec.group >= FlagGroup.SELECTION
            and spec.group <= FlagGroup.GENERAL,
            "unknown help group: " + spec.spelling,
        )
        if spec.arity == 1:
            assert_true(
                spec.value_name.byte_length() > 0,
                "missing value name: " + spec.spelling,
            )
        else:
            assert_equal(
                spec.value_name,
                "",
                "valueless flag has a value name: " + spec.spelling,
            )


def test_help_renders_every_option_once_with_values_and_aligned_help() raises:
    var rendered = help_text()
    var option_rows = 0
    for line_slice in rendered.split("\n"):
        if String(line_slice).startswith("  -"):
            option_rows += 1
    # Five two-spelling aliases collapse 44 spellings into 39 physical rows.
    assert_equal(option_rows, 39)
    for row in frozen_inventory():
        var expected_line = "  " + row.help_label
        for _ in range(30 - expected_line.count_codepoints()):
            expected_line += " "
        expected_line += row.help
        var matches = 0
        for line_slice in rendered.split("\n"):
            var line = String(line_slice)
            if line == expected_line:
                matches += 1
        assert_equal(
            matches,
            1,
            "help row coverage drift: " + row.spelling,
        )


def test_help_has_grouped_sections_and_clear_subcommands() raises:
    var rendered = help_text()
    assert_true("Subcommands:\n" in rendered)
    assert_true("  run [PATHS...] [flags]" in rendered)
    assert_true("  collect [PATHS...] [flags]" in rendered)
    assert_true("  config show [PATHS...]" in rendered)
    assert_true("  doctor [flags]" in rendered)
    assert_true("  debug PATH::TEST" in rendered)
    assert_true("  new PATH" in rendered)
    assert_true("  init [--ci github]" in rendered)
    assert_true("  completions SHELL" in rendered)
    var previous_group_position = -1
    for group in [
        "Selection",
        "Execution",
        "Building",
        "Reporting",
        "Session state",
        "General",
    ]:
        var heading = group + ":"
        var matches = 0
        for line_slice in rendered.split("\n"):
            if String(line_slice) == heading:
                matches += 1
        assert_equal(matches, 1, "group heading count drift: " + group)
        var position = rendered.find("\n" + heading + "\n")
        assert_true(
            position > previous_group_position,
            "group order drift: " + group,
        )
        previous_group_position = position


def test_help_group_identities_have_exact_names_and_invalid_is_safe() raises:
    assert_equal(flag_group_name(FlagGroup.SELECTION), "Selection")
    assert_equal(flag_group_name(FlagGroup.EXECUTION), "Execution")
    assert_equal(flag_group_name(FlagGroup.BUILDING), "Building")
    assert_equal(flag_group_name(FlagGroup.REPORTING), "Reporting")
    assert_equal(flag_group_name(FlagGroup.SESSION_STATE), "Session state")
    assert_equal(flag_group_name(FlagGroup.GENERAL), "General")
    assert_equal(flag_group_name(-1), "Invalid")


def test_help_lines_never_exceed_78_columns() raises:
    for line_slice in help_text().split("\n"):
        var line = String(line_slice)
        assert_true(
            line.count_codepoints() <= 78,
            "overlong help line: " + line,
        )


def test_every_physical_help_label_fits_before_the_help_column() raises:
    """A label of 28+ codepoints would run into the 30-column help text.

    `_help_row` pads `"  " + label` out to column 30, so a 28-codepoint label
    leaves no separating space and a longer one pushes the description right
    and breaks the alignment every other row keeps.
    """
    for row in frozen_inventory():
        assert_true(
            row.help_label.count_codepoints() <= 27,
            "overlong help label: " + row.help_label,
        )


# --- typed value metadata: the kind and the closed list per spelling ---


def test_value_kind_discriminants_are_stable() raises:
    assert_equal(ValueKind.NONE.code, 0)
    assert_equal(ValueKind.PATH.code, 1)
    assert_equal(ValueKind.CHOICE.code, 2)
    assert_equal(ValueKind.CHOICE_OR_OTHER.code, 3)
    assert_equal(ValueKind.PREFIX_CHOICE.code, 4)
    assert_equal(ValueKind.OTHER.code, 5)


def test_value_kind_compares_by_discriminant() raises:
    assert_true(ValueKind.PATH == ValueKind(1))
    assert_true(ValueKind.PATH != ValueKind.OTHER)
    assert_false(ValueKind.PATH == ValueKind.OTHER)
    assert_false(ValueKind.PATH != ValueKind(1))


def test_valueless_flags_declare_no_value_kind_and_no_choices() raises:
    for spec in flag_specs():
        if spec.arity == 0:
            assert_true(
                spec.value_kind == ValueKind.NONE,
                "arity-0 flag completes a value: " + spec.spelling,
            )
            assert_equal(
                len(spec.choices),
                0,
                "arity-0 flag carries choices: " + spec.spelling,
            )


def test_value_taking_flags_never_declare_the_valueless_kind() raises:
    for spec in flag_specs():
        if spec.arity == 1:
            assert_true(
                spec.value_kind != ValueKind.NONE,
                "arity-1 flag declares no value kind: " + spec.spelling,
            )


def test_only_the_closed_kinds_carry_a_choice_list() raises:
    """A list on an open kind would be offered as if it were exhaustive."""
    for spec in flag_specs():
        var closed = (
            spec.value_kind == ValueKind.CHOICE
            or spec.value_kind == ValueKind.CHOICE_OR_OTHER
            or spec.value_kind == ValueKind.PREFIX_CHOICE
        )
        if closed:
            assert_true(
                len(spec.choices) > 0,
                "closed kind with an empty list: " + spec.spelling,
            )
        else:
            assert_equal(
                len(spec.choices),
                0,
                "open kind with a choice list: " + spec.spelling,
            )


def test_choice_flags_are_exactly_the_five_closed_vocabularies() raises:
    assert_equal(
        _spellings_with_kind(ValueKind.CHOICE),
        "--show-output|--color|--format|--report-style|--gh-annotations",
    )


def test_path_flags_are_exactly_the_seven_destination_takers() raises:
    assert_equal(
        _spellings_with_kind(ValueKind.PATH),
        "--gate|-I|--precompile|--mojo|--json|--junit-xml|--config",
    )


def test_workers_is_the_only_closed_list_beside_free_text() raises:
    assert_equal(
        _spellings_with_kind(ValueKind.CHOICE_OR_OTHER), "-n|--workers"
    )


def test_report_is_the_only_prefix_choice() raises:
    assert_equal(_spellings_with_kind(ValueKind.PREFIX_CHOICE), "--report")


def test_every_declared_choice_is_accepted_by_the_parser() raises:
    """The published list may never contain a value the parser refuses."""
    for spec in flag_specs():
        for choice in spec.choices:
            var value = choice.copy()
            if spec.value_kind == ValueKind.PREFIX_CHOICE:
                value += "out.txt"
            var accepted = True
            try:
                _ = parse_args(_argv_for(spec.spelling, value))
            except:
                accepted = False
            assert_true(
                accepted,
                "declared choice refused: " + spec.spelling + " " + value,
            )


def test_a_value_outside_every_closed_list_is_refused() raises:
    """A list is only closed while the parser refuses what it omits.

    The probe is shaped for the row's own kind (`_undeclared_probe`), so the
    refusal comes from the choice list rather than from a structural rule the
    list plays no part in.
    """
    for spec in flag_specs():
        if len(spec.choices) == 0:
            continue
        var probe = _undeclared_probe(spec.value_kind)
        var refused = False
        try:
            _ = parse_args(_argv_for(spec.spelling, probe))
        except:
            refused = True
        assert_true(
            refused,
            "declared list is not closed: " + spec.spelling + " " + probe,
        )


def test_a_near_miss_on_a_declared_choice_is_refused() raises:
    """Membership is exact: no prefix match, no fuzzy match, per member.

    One fixed probe per row cannot prove that; perturbing each declared member
    in turn constrains every entry of every list rather than only the row.
    """
    for spec in flag_specs():
        for choice in spec.choices:
            var probe = _near_miss(spec.value_kind, choice)
            var refused = False
            try:
                _ = parse_args(_argv_for(spec.spelling, probe))
            except:
                refused = True
            assert_true(
                refused,
                "near miss accepted: " + spec.spelling + " " + probe,
            )


def test_workers_free_arm_is_open_beside_its_closed_arm() raises:
    """CHOICE_OR_OTHER means both arms parse: `auto` and a bare integer."""
    var closed: List[String] = ["--workers", "auto"]
    var free: List[String] = ["--workers", "7"]
    assert_equal(parse_args(closed).config.workers, 0)
    assert_equal(parse_args(free).config.workers, 7)


def test_workers_short_parses_count() raises:
    # `-n N` is served: the count reaches the config.
    var argv: List[String] = ["-n", "2"]
    var r = parse_args(argv)
    assert_equal(r.config.workers, 2)


def test_failure_selection_spellings_are_served() raises:
    var lf_short: List[String] = ["--lf"]
    var lf_long: List[String] = ["--last-failed"]
    var ff_short: List[String] = ["--ff"]
    var ff_long: List[String] = ["--failed-first"]
    assert_true(parse_args(lf_short).config.last_failed)
    assert_true(parse_args(lf_long).config.last_failed)
    assert_true(parse_args(ff_short).config.failed_first)
    assert_true(parse_args(ff_long).config.failed_first)


def test_failure_selection_modes_are_mutually_exclusive() raises:
    var argv: List[String] = ["--last-failed", "--ff"]
    with assert_raises(contains="mutually exclusive"):
        _ = parse_args(argv)


def test_last_failed_is_incompatible_with_shard() raises:
    var argv: List[String] = ["--lf", "--shard", "1/2"]
    with assert_raises(contains="'--shard'"):
        _ = parse_args(argv)


def test_failed_first_is_incompatible_with_shard() raises:
    var argv: List[String] = ["--failed-first", "--shard", "1/2"]
    with assert_raises(contains="'--shard'"):
        _ = parse_args(argv)


def test_failure_selection_modes_are_run_only() raises:
    var lf_collect: List[String] = ["collect", "--lf"]
    var ff_alias: List[String] = ["--collect-only", "--failed-first"]
    with assert_raises(contains="run-only"):
        _ = parse_args(lf_collect)
    with assert_raises(contains="run-only"):
        _ = parse_args(ff_alias)


def test_workers_long_auto_is_sentinel_zero() raises:
    # `--workers auto` is the runner-chosen sentinel: it lands as 0.
    var argv: List[String] = ["--workers", "auto"]
    var r = parse_args(argv)
    assert_equal(r.config.workers, 0)


def test_workers_one_equals_no_flag_default() raises:
    # `-n 1` is the sequential default: identical to no flag at the parse layer.
    var explicit: List[String] = ["-n", "1"]
    assert_equal(parse_args(explicit).config.workers, 1)
    var absent: List[String] = ["tests/"]
    assert_equal(parse_args(absent).config.workers, 1)


def test_workers_last_wins() raises:
    var argv: List[String] = ["-n", "3", "--workers", "5"]
    var r = parse_args(argv)
    assert_equal(r.config.workers, 5)


def test_workers_zero_is_usage_error() raises:
    var argv: List[String] = ["-n", "0"]
    with assert_raises(contains="-n"):
        _ = parse_args(argv)


def test_workers_non_digit_is_usage_error() raises:
    var argv: List[String] = ["-n", "xyz"]
    with assert_raises(contains="'-n'/'--workers'"):
        _ = parse_args(argv)


def test_workers_negative_is_usage_error() raises:
    var argv: List[String] = ["-n", "-1"]
    with assert_raises(contains="positive integer or 'auto'"):
        _ = parse_args(argv)


def test_workers_empty_is_usage_error() raises:
    var argv: List[String] = ["-n", ""]
    with assert_raises(contains="'-n'/'--workers'"):
        _ = parse_args(argv)


def test_build_arg_j_short_is_forbidden() raises:
    var argv: List[String] = ["--build-arg", "-j"]
    with assert_raises(contains="forbidden build argument"):
        _ = parse_args(argv)


def test_build_arg_num_threads_is_forbidden() raises:
    var argv: List[String] = ["--build-arg", "--num-threads"]
    with assert_raises(contains="-n/--workers"):
        _ = parse_args(argv)


def test_build_arg_num_threads_equals_is_forbidden() raises:
    var argv: List[String] = ["--build-arg=--num-threads=4"]
    with assert_raises(contains="forbidden build argument"):
        _ = parse_args(argv)


def test_post_dash_dash_j_is_forbidden() raises:
    # A bare `-j 4` after `--` reaches build-arg validation on the `-j` token.
    var argv: List[String] = ["--", "-j", "4"]
    with assert_raises(contains="forbidden build argument"):
        _ = parse_args(argv)


def test_compile_timeout_is_served_and_parses() raises:
    # `--compile-timeout` is now served: a non-negative int parses cleanly.
    var argv: List[String] = ["--compile-timeout", "90"]
    var r = parse_args(argv)
    assert_equal(r.config.compile_timeout_secs, 90)


def test_compile_timeout_zero_disables() raises:
    var argv: List[String] = ["--compile-timeout", "0"]
    var r = parse_args(argv)
    assert_equal(r.config.compile_timeout_secs, 0)


def test_compile_timeout_default_is_600() raises:
    var argv: List[String] = ["tests/"]
    var r = parse_args(argv)
    assert_equal(r.config.compile_timeout_secs, 600)


def test_compile_timeout_last_wins() raises:
    # Not repeatable: a second `--compile-timeout` overwrites the first.
    var argv: List[String] = [
        "--compile-timeout",
        "5",
        "--compile-timeout",
        "7",
    ]
    var r = parse_args(argv)
    assert_equal(r.config.compile_timeout_secs, 7)


def test_compile_timeout_inline_value_parses() raises:
    var argv: List[String] = ["--compile-timeout=12"]
    var r = parse_args(argv)
    assert_equal(r.config.compile_timeout_secs, 12)


def test_compile_timeout_bad_value_is_usage_error() raises:
    var argv: List[String] = ["--compile-timeout", "-1"]
    with assert_raises(contains="integer >= 0"):
        _ = parse_args(argv)


def test_compile_timeout_non_numeric_names_the_flag() raises:
    var argv: List[String] = ["--compile-timeout", "soon"]
    with assert_raises(contains="'--compile-timeout'"):
        _ = parse_args(argv)


def test_retries_is_served_and_parses() raises:
    # `--retries` is now served: a non-negative int parses cleanly.
    var argv: List[String] = ["--retries", "3"]
    var r = parse_args(argv)
    assert_equal(r.config.retries, 3)


def test_retries_zero_disables() raises:
    var argv: List[String] = ["--retries", "0"]
    var r = parse_args(argv)
    assert_equal(r.config.retries, 0)


def test_retries_default_is_zero() raises:
    var argv: List[String] = ["tests/"]
    var r = parse_args(argv)
    assert_equal(r.config.retries, 0)


def test_retries_bad_value_is_usage_error() raises:
    var argv: List[String] = ["--retries", "-1"]
    with assert_raises(contains="integer >= 0"):
        _ = parse_args(argv)


def test_gate_is_served_and_accumulates() raises:
    var argv: List[String] = ["--gate", "x", "--gate", "y"]
    var r = parse_args(argv)
    assert_equal(len(r.config.gates), 2)
    assert_equal(r.config.gates[0], "x")
    assert_equal(r.config.gates[1], "y")


def test_junit_xml_path_is_served_when_parent_exists() raises:
    # `--junit-xml` is now served: a PATH whose parent directory exists parses
    # cleanly into the config rather than being refused.
    var argv: List[String] = ["--junit-xml", "tests/report.xml"]
    var r = parse_args(argv)
    assert_equal(r.config.junit_dest, "tests/report.xml")


def test_junit_xml_bare_filename_is_served() raises:
    # A bare filename (no directory part) targets the current directory.
    var argv: List[String] = ["--junit-xml", "report.xml"]
    var r = parse_args(argv)
    assert_equal(r.config.junit_dest, "report.xml")


def test_junit_xml_default_is_absent() raises:
    var argv: List[String] = ["tests/"]
    var r = parse_args(argv)
    assert_equal(r.config.junit_dest, "")


def test_junit_xml_empty_value_is_usage_error() raises:
    var argv: List[String] = ["--junit-xml", ""]
    with assert_raises(contains="--junit-xml"):
        _ = parse_args(argv)


def test_junit_xml_nonexistent_parent_is_usage_error() raises:
    var argv: List[String] = ["--junit-xml", "/no/such/dir/report.xml"]
    with assert_raises(contains="--junit-xml"):
        _ = parse_args(argv)


def test_junit_xml_has_no_stdout_dash_form() raises:
    # Unlike `--json -`, a bare `-` is NOT a stdout stream for `--junit-xml`
    # (the document is renamed atomically, never streamed): `-` is a normal
    # positional PATH operand and the flag itself is absent.
    var argv: List[String] = ["--junit-xml", "report.xml", "-"]
    var r = parse_args(argv)
    assert_equal(r.config.junit_dest, "report.xml")


def test_report_md_and_html_are_served_when_parents_exist() raises:
    # `--report` is served once per format: each destination lands in its own
    # config field, and the two are independent.
    var argv: List[String] = [
        "--report",
        "md:tests/run.md",
        "--report",
        "html:tests/run.html",
    ]
    var r = parse_args(argv)
    assert_equal(r.config.report_md_dest, "tests/run.md")
    assert_equal(r.config.report_html_dest, "tests/run.html")


def test_report_bare_filename_is_served() raises:
    var argv: List[String] = ["--report", "md:run.md"]
    var r = parse_args(argv)
    assert_equal(r.config.report_md_dest, "run.md")


def test_report_default_is_absent_for_both_formats() raises:
    var argv: List[String] = ["tests/"]
    var r = parse_args(argv)
    assert_equal(r.config.report_md_dest, "")
    assert_equal(r.config.report_html_dest, "")


def test_report_unknown_format_is_usage_error() raises:
    var argv: List[String] = ["--report", "xml:r.xml"]
    with assert_raises(contains="'--report' wants md:PATH or html:PATH"):
        _ = parse_args(argv)


def test_report_without_a_separator_is_usage_error() raises:
    var argv: List[String] = ["--report", "run.md"]
    with assert_raises(contains="'--report' wants md:PATH or html:PATH"):
        _ = parse_args(argv)


def test_report_empty_path_is_usage_error() raises:
    var argv: List[String] = ["--report", "md:"]
    with assert_raises(contains="'--report' wants md:PATH or html:PATH"):
        _ = parse_args(argv)


def test_report_repeated_format_is_usage_error() raises:
    var argv: List[String] = ["--report", "md:a.md", "--report", "md:b.md"]
    with assert_raises(contains="'--report md:' was given twice"):
        _ = parse_args(argv)


def test_report_repeated_html_format_is_usage_error() raises:
    var argv: List[String] = [
        "--report",
        "html:a.html",
        "--report",
        "html:b.html",
    ]
    with assert_raises(contains="'--report html:' was given twice"):
        _ = parse_args(argv)


def test_report_nonexistent_parent_is_usage_error() raises:
    var argv: List[String] = ["--report", "md:/no/such/dir/run.md"]
    with assert_raises(contains="destination parent directory does not exist"):
        _ = parse_args(argv)


def test_report_has_no_stdout_dash_form() raises:
    # There is no `-` destination: the document is renamed atomically, never
    # streamed, so `md:-` is an ordinary relative path named `-`.
    var argv: List[String] = ["--report", "md:-"]
    var r = parse_args(argv)
    assert_equal(r.config.report_md_dest, "-")


def test_report_style_is_served_and_defaults_to_concise() raises:
    var argv: List[String] = ["tests/"]
    assert_true(parse_args(argv).config.report_style == ReportStyle.CONCISE)
    var full: List[String] = ["--report-style", "full"]
    assert_true(parse_args(full).config.report_style == ReportStyle.FULL)
    var concise: List[String] = ["--report-style", "concise"]
    assert_true(parse_args(concise).config.report_style == ReportStyle.CONCISE)


def test_report_style_bad_value_is_usage_error() raises:
    var argv: List[String] = ["--report-style", "verbose"]
    with assert_raises(contains="'--report-style' wants 'concise' or 'full'"):
        _ = parse_args(argv)


def test_report_style_is_last_wins() raises:
    var argv: List[String] = [
        "--report-style",
        "full",
        "--report-style",
        "concise",
    ]
    assert_true(parse_args(argv).config.report_style == ReportStyle.CONCISE)


def test_report_style_alone_is_inert_but_accepted() raises:
    # The `--fail-on-flaky` inertness precedent: a style with no destination
    # parses cleanly and changes nothing.
    var argv: List[String] = ["--report-style", "full", "tests/"]
    var r = parse_args(argv)
    assert_true(r.config.report_style == ReportStyle.FULL)
    assert_equal(r.config.report_md_dest, "")
    assert_equal(r.config.report_html_dest, "")


def test_gh_annotations_auto_is_served_and_default() raises:
    # `--gh-annotations` is now served: `auto` parses cleanly and is the default.
    var argv: List[String] = ["--gh-annotations", "auto"]
    var r = parse_args(argv)
    assert_true(r.config.gh_annotations == AnnotationsMode.AUTO)


def test_gh_annotations_on_parses() raises:
    var argv: List[String] = ["--gh-annotations", "on"]
    var r = parse_args(argv)
    assert_true(r.config.gh_annotations == AnnotationsMode.ON)


def test_gh_annotations_off_parses() raises:
    var argv: List[String] = ["--gh-annotations", "off"]
    var r = parse_args(argv)
    assert_true(r.config.gh_annotations == AnnotationsMode.OFF)


def test_gh_annotations_default_is_auto() raises:
    var argv: List[String] = ["tests/"]
    var r = parse_args(argv)
    assert_true(r.config.gh_annotations == AnnotationsMode.AUTO)


def test_gh_annotations_bad_value_is_usage_error() raises:
    var argv: List[String] = ["--gh-annotations", "sometimes"]
    with assert_raises(contains="off|on|auto"):
        _ = parse_args(argv)


def test_gh_annotations_inline_value_parses() raises:
    var argv: List[String] = ["--gh-annotations=on"]
    var r = parse_args(argv)
    assert_true(r.config.gh_annotations == AnnotationsMode.ON)


def test_json_dash_with_annotations_on_reaches_resolved_validation() raises:
    # Cross-value constraints are source-neutral and run after layering.
    var argv: List[String] = ["--json", "-", "--gh-annotations", "on"]
    var result = parse_args(argv)
    assert_equal(result.config.json_dest, "-")
    assert_true(result.config.gh_annotations == AnnotationsMode.ON)


def test_json_dash_with_annotations_auto_reaches_resolved_validation() raises:
    # The default auto value also reaches the common resolved validator.
    var argv: List[String] = ["--json", "-"]
    var result = parse_args(argv)
    assert_equal(result.config.json_dest, "-")
    assert_true(result.config.gh_annotations == AnnotationsMode.AUTO)


def test_json_dash_with_annotations_off_runs_clean() raises:
    # Explicit off is the ONLY combination that runs beside `--json -`.
    var argv: List[String] = ["--json", "-", "--gh-annotations", "off"]
    var r = parse_args(argv)
    assert_equal(r.config.json_dest, "-")
    assert_true(r.config.gh_annotations == AnnotationsMode.OFF)


def test_json_path_with_annotations_on_runs_clean() raises:
    # `--json PATH` does NOT own stdout, so annotations may ride alongside it.
    var argv: List[String] = ["--json", "out.ndjson", "--gh-annotations", "on"]
    var r = parse_args(argv)
    assert_equal(r.config.json_dest, "out.ndjson")
    assert_true(r.config.gh_annotations == AnnotationsMode.ON)


def test_shard_is_served_hash_default() raises:
    # `--shard` is now served: a bare `M/N` parses cleanly, hash by default.
    var argv: List[String] = ["--shard", "2/5"]
    var r = parse_args(argv)
    assert_true(r.config.shard_mode == ShardMode.HASH)
    assert_equal(r.config.shard_m, 2)
    assert_equal(r.config.shard_n, 5)


def test_shard_is_served_slice_prefix() raises:
    var argv: List[String] = ["--shard", "slice:3/4"]
    var r = parse_args(argv)
    assert_true(r.config.shard_mode == ShardMode.SLICE)
    assert_equal(r.config.shard_m, 3)
    assert_equal(r.config.shard_n, 4)


def test_shard_last_wins() raises:
    # Not repeatable: a second `--shard` overwrites the first (like --timeout).
    var argv: List[String] = ["--shard", "1/9", "--shard", "hash:2/3"]
    var r = parse_args(argv)
    assert_equal(r.config.shard_m, 2)
    assert_equal(r.config.shard_n, 3)


def test_shard_bad_value_is_usage_error() raises:
    var argv: List[String] = ["--shard", "6/5"]
    with assert_raises(contains="1<=M<=N"):
        _ = parse_args(argv)


def test_serial_is_served_and_accumulates_one_glob() raises:
    # `--serial` reaches the config and preserves its glob byte-for-byte.
    var argv: List[String] = ["--serial", "*a*"]
    var r = parse_args(argv)
    assert_equal(len(r.config.serial_globs), 1)
    assert_equal(r.config.serial_globs[0], "*a*")


def test_serial_is_repeatable_and_accumulates_both_globs() raises:
    # Repeatable like `--exclude`: each occurrence adds one glob, in order.
    var argv: List[String] = ["--serial", "*a*", "--serial", "*b*"]
    var r = parse_args(argv)
    assert_equal(len(r.config.serial_globs), 2)
    assert_equal(r.config.serial_globs[0], "*a*")
    assert_equal(r.config.serial_globs[1], "*b*")


def test_serial_default_is_empty() raises:
    var argv: List[String] = ["tests/"]
    var r = parse_args(argv)
    assert_equal(len(r.config.serial_globs), 0)


def test_serial_inline_value_parses() raises:
    var argv: List[String] = ["--serial=*x*"]
    var r = parse_args(argv)
    assert_equal(len(r.config.serial_globs), 1)
    assert_equal(r.config.serial_globs[0], "*x*")


def test_json_dash_is_served_and_sets_stdout_destination() raises:
    # `--json -` is now served: the stream destination is stdout (`-`). It must
    # carry an explicit `--gh-annotations off`, since the default `auto` conflicts
    # with the byte-pure stream owning stdout.
    var argv: List[String] = ["--json", "-", "--gh-annotations", "off"]
    var r = parse_args(argv)
    assert_equal(r.config.json_dest, "-")


def test_json_path_is_served_when_parent_exists() raises:
    # A PATH whose parent directory exists parses cleanly.
    var argv: List[String] = ["--json", "tests/out.ndjson"]
    var r = parse_args(argv)
    assert_equal(r.config.json_dest, "tests/out.ndjson")


def test_json_bare_filename_is_served() raises:
    # A bare filename (no directory part) targets the current directory.
    var argv: List[String] = ["--json", "out.ndjson"]
    var r = parse_args(argv)
    assert_equal(r.config.json_dest, "out.ndjson")


def test_json_default_is_absent() raises:
    var argv: List[String] = ["tests/"]
    var r = parse_args(argv)
    assert_equal(r.config.json_dest, "")


def test_json_empty_value_is_usage_error() raises:
    var argv: List[String] = ["--json", ""]
    with assert_raises(contains="--json"):
        _ = parse_args(argv)


def test_json_nonexistent_parent_is_usage_error() raises:
    var argv: List[String] = ["--json", "/no/such/dir/out.ndjson"]
    with assert_raises(contains="--json"):
        _ = parse_args(argv)


def test_collect_only_is_served_and_sets_collect_mode() raises:
    # `--collect-only` is now served: it parses cleanly and turns on collect
    # mode rather than being refused as an unbuilt flag.
    var argv: List[String] = ["--collect-only"]
    var r = parse_args(argv)
    assert_true(r.config.collect)


def test_collect_subcommand_is_served() raises:
    var argv: List[String] = ["collect", "tests/"]
    var r = parse_args(argv)
    assert_true(r.config.collect)


def test_workers_equals_form_parses_count() raises:
    # The `=` form is served now: `--workers=3` sets the count to 3.
    var argv: List[String] = ["--workers=3"]
    var r = parse_args(argv)
    assert_equal(r.config.workers, 3)


# --- the Subcommands help rows ---


def frozen_subcommands() -> List[SubcommandSpec]:
    """The ten Subcommands rows, transcribed from the contract by hand."""
    return [
        SubcommandSpec(
            token="run",
            label_args="[PATHS...] [flags]",
            description="Run tests (the default subcommand).",
        ),
        SubcommandSpec(
            token="collect",
            label_args="[PATHS...] [flags]",
            description="List node ids without running tests.",
        ),
        SubcommandSpec(
            token="config",
            label_args="show [PATHS...]",
            description="Show resolved configuration.",
        ),
        SubcommandSpec(
            token="doctor",
            label_args="[flags]",
            description="Diagnose the environment without running tests.",
        ),
        SubcommandSpec(
            token="debug",
            label_args="PATH::TEST",
            description="Run one test with the terminal handed over.",
        ),
        SubcommandSpec(
            token="new",
            label_args="PATH",
            description="Create one runnable test file.",
        ),
        SubcommandSpec(
            token="init",
            label_args="[--ci github]",
            description="Bootstrap a project in this directory.",
        ),
        SubcommandSpec(
            token="completions",
            label_args="SHELL",
            description="Print a bash, zsh, or fish completion script.",
        ),
        SubcommandSpec(
            token="help",
            label_args="",
            description="Show this help and exit.",
        ),
        SubcommandSpec(
            token="version",
            label_args="",
            description="Show the version and exit.",
        ),
    ]


def _subcommand_label(spec: SubcommandSpec) -> String:
    """The physical help-row label for one Subcommands row."""
    if spec.label_args == "":
        return spec.token.copy()
    return spec.token + " " + spec.label_args


def test_subcommand_specs_match_the_frozen_rows_in_order() raises:
    var specs = subcommand_specs()
    var frozen = frozen_subcommands()
    assert_equal(len(specs), len(frozen))
    for i in range(len(frozen)):
        assert_equal(
            specs[i].token, frozen[i].token, "token drift at " + String(i)
        )
        assert_equal(
            specs[i].label_args,
            frozen[i].label_args,
            "label args drift: " + frozen[i].token,
        )
        assert_equal(
            specs[i].description,
            frozen[i].description,
            "description drift: " + frozen[i].token,
        )


def test_every_subcommand_row_is_rendered_once_into_the_help() raises:
    var rendered = help_text()
    for spec in frozen_subcommands():
        var expected_line = "  " + _subcommand_label(spec)
        for _ in range(30 - expected_line.count_codepoints()):
            expected_line += " "
        expected_line += spec.description
        var matches = 0
        for line_slice in rendered.split("\n"):
            if String(line_slice) == expected_line:
                matches += 1
        assert_equal(matches, 1, "subcommand row coverage drift: " + spec.token)


def test_subcommand_rows_fit_the_help_column_and_the_help_width() raises:
    for spec in subcommand_specs():
        assert_true(
            spec.token.byte_length() > 0, "subcommand row with no token"
        )
        assert_true(
            spec.description.byte_length() > 0,
            "subcommand row with no description: " + spec.token,
        )
        assert_true(
            _subcommand_label(spec).count_codepoints() <= 27,
            "overlong subcommand label: " + spec.token,
        )
        assert_true(
            spec.description.count_codepoints() <= 48,
            "overlong subcommand description: " + spec.token,
        )


# --- applicability: the mask against the parser's own refusals ---


def subcommand_bits() -> List[Int]:
    """Every flag-accepting head, as its applicability bit."""
    return [
        Subcommand.RUN,
        Subcommand.COLLECT,
        Subcommand.CONFIG_SHOW,
        Subcommand.DOCTOR,
        Subcommand.DEBUG,
    ]


def _head_tokens(subcommand: Int) -> List[String]:
    """The leading tokens that select `subcommand`, exactly as typed."""
    if subcommand == Subcommand.COLLECT:
        return ["collect"]
    if subcommand == Subcommand.CONFIG_SHOW:
        return ["config", "show"]
    if subcommand == Subcommand.DOCTOR:
        return ["doctor"]
    if subcommand == Subcommand.DEBUG:
        # `debug` wants exactly one node id, so the probe carries one. The
        # parser never touches the filesystem for it.
        return ["debug", "probe.mojo::test_probe"]
    return ["run"]


def _head_name(subcommand: Int) -> String:
    """A readable name for `subcommand`, for assertion messages."""
    if subcommand == Subcommand.COLLECT:
        return "collect"
    if subcommand == Subcommand.CONFIG_SHOW:
        return "config show"
    if subcommand == Subcommand.DOCTOR:
        return "doctor"
    if subcommand == Subcommand.DEBUG:
        return "debug"
    return "run"


def _probe_value(spelling: String) -> String:
    """A value every subcommand's grammar accepts for `spelling`.

    The probe has to be valid on its own terms, or the argument vector could be
    refused for the value rather than for applicability and the mask would go
    unconstrained. Bare filenames are deliberate: a destination with no
    directory part skips the parent-directory check.

    Args:
        spelling: The flag spelling the value is offered to.

    Returns:
        A newly allocated value the flag's own validator accepts.
    """
    if spelling == "--shard":
        return "1/2"
    if spelling == "--show-output":
        return "all"
    if spelling == "--color":
        return "auto"
    if spelling == "--format":
        return "lines"
    if spelling == "--gh-annotations":
        return "off"
    if spelling == "--report":
        return "md:probe.md"
    if spelling == "--report-style":
        return "concise"
    if spelling == "--json":
        return "probe.ndjson"
    if spelling == "--junit-xml":
        return "probe.xml"
    if spelling == "--build-arg":
        return "-O0"
    if spelling == "--precompile" or spelling == "-I":
        return "src"
    if spelling == "--mojo":
        return "mojo"
    if spelling == "--config":
        return "mtest.toml"
    if spelling == "--gate":
        return "probe_gate.mojo"
    if spelling == "-k":
        return "probe"
    if spelling == "--exclude" or spelling == "--serial":
        return "*probe*"
    if spelling == "-n" or spelling == "--workers":
        return "2"
    # Everything left takes a non-negative integer.
    return "1"


def _applicability_argv(
    spelling: String, arity: Int, subcommand: Int
) -> List[String]:
    """The shortest vector that offers `spelling` to `subcommand`."""
    var argv = _head_tokens(subcommand)
    argv.append(spelling)
    if arity == 1:
        argv.append(_probe_value(spelling))
    if spelling == "--seed":
        # A lone `--seed` is refused everywhere, `run` included, for wanting
        # `--shuffle` — an answer about a different rule than this probe asks
        # about — so the pair goes in together.
        #
        # That makes `--seed` the one probe carrying a second flag that is
        # itself inapplicable under `collect`, `doctor`, and `debug`, so the
        # pair stays decidable only because each refusal that fires names BOTH
        # spellings: `'--shuffle' and '--seed' are run-only flags…` under
        # collect, `…are run flags…` under doctor, and under debug the general
        # `'--seed' cannot be combined with 'debug'` (the loop reaches `--seed`
        # first, since it is appended first). Reword any of those three to drop
        # `--seed` and this probe stops proving anything about `--seed`; the
        # names-the-flag assertion in direction two is what catches that.
        argv.append("--shuffle")
    return argv^


def test_subcommand_bits_are_stable_and_disjoint() raises:
    assert_equal(Subcommand.RUN, 1)
    assert_equal(Subcommand.COLLECT, 2)
    assert_equal(Subcommand.CONFIG_SHOW, 4)
    assert_equal(Subcommand.DOCTOR, 8)
    assert_equal(Subcommand.DEBUG, 16)


def test_every_flag_applies_somewhere_and_names_no_unknown_head() raises:
    var every = 0
    for bit in subcommand_bits():
        every |= bit
    for spec in flag_specs():
        assert_true(
            spec.applicability != 0,
            "flag applies to no subcommand: " + spec.spelling,
        )
        assert_equal(
            spec.applicability & every,
            spec.applicability,
            "applicability names an unknown subcommand: " + spec.spelling,
        )


def test_the_mask_never_separates_run_from_config_show() raises:
    """A mask-shape invariant, not a parser probe.

    `config show` resolves the run grammar and adds no refusal of its own, so
    no row may set one bit without the other. The two drift tests below are
    what check that claim against `parse_args`; this one only stops a row from
    being written in a shape the parser could never produce.
    """
    for spec in flag_specs():
        assert_true(
            ((spec.applicability & Subcommand.RUN) != 0)
            == ((spec.applicability & Subcommand.CONFIG_SHOW) != 0),
            "run and config show disagree: " + spec.spelling,
        )


def test_every_masked_flag_parses_under_that_subcommand() raises:
    """Direction one: a mask bit may never promise a flag the parser refuses."""
    for spec in flag_specs():
        for subcommand in subcommand_bits():
            if (spec.applicability & subcommand) == 0:
                continue
            var argv = _applicability_argv(
                spec.spelling, spec.arity, subcommand
            )
            var message = String("")
            var refused = False
            try:
                _ = parse_args(argv)
            except e:
                refused = True
                message = String(e)
            assert_false(
                refused,
                "masked applicable but refused: "
                + _head_name(subcommand)
                + " "
                + spec.spelling
                + ": "
                + message,
            )


def test_every_unmasked_flag_is_refused_by_name_under_that_subcommand() raises:
    """Direction two: every refusal the parser performs is a cleared bit."""
    for spec in flag_specs():
        for subcommand in subcommand_bits():
            if (spec.applicability & subcommand) != 0:
                continue
            var argv = _applicability_argv(
                spec.spelling, spec.arity, subcommand
            )
            var message = String("")
            var refused = False
            try:
                _ = parse_args(argv)
            except e:
                refused = True
                message = String(e)
            assert_true(
                refused,
                "masked inapplicable but accepted: "
                + _head_name(subcommand)
                + " "
                + spec.spelling,
            )
            # Quoted, because every refusal quotes the spelling it names and a
            # bare substring would not mean what this assertion says: `-s`
            # occurs inside `--show-output`, and `--report` inside
            # `--report-style`, so an unquoted probe would accept a refusal
            # about the neighbouring flag as if it named this one.
            var quoted = "'" + spec.spelling + "'"
            assert_true(
                quoted in message,
                "refusal does not name the flag: "
                + _head_name(subcommand)
                + " "
                + spec.spelling
                + ": "
                + message,
            )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
