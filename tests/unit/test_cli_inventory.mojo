"""The independent frozen-inventory and generated-help cross-checks.

`frozen_inventory()` is a HAND-WRITTEN transcription of the command-line
contract's flag table — authored by reading the contract, never generated from
the parser's own `flag_specs()`. The cross-check asserts the parser's table is a
row-for-row bijection with this frozen list, so a drifted arity or dropped
spelling fails loudly and the spec table can never be its own oracle. The help
tests independently require complete metadata and one aligned, bounded line per
spelling.
"""
from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from mtest.cli import (
    FlagGroup,
    flag_group_name,
    flag_specs,
    help_text,
    parse_args,
)
from mtest.config import AnnotationsMode, ShardMode


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


def frozen_inventory() -> List[InvRow]:
    """Every flag spelling in the v1 contract, transcribed by hand.

    Every field is a contract fact authored independently from `flag_specs()`.
    `help_label` is the complete label for the physical help row, so aliases
    intentionally share one expected label.
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
        ),
        InvRow(
            "-I",
            1,
            True,
            "PATH",
            FlagGroup.BUILDING,
            "Add a Mojo include path (repeatable).",
            "-I PATH",
        ),
        InvRow(
            "--build-arg",
            1,
            True,
            "ARG",
            FlagGroup.BUILDING,
            "Forward one argument to mojo build (repeatable).",
            "--build-arg ARG",
        ),
        InvRow(
            "--gate",
            1,
            True,
            "PATH",
            FlagGroup.SELECTION,
            "Run PATH before ordinary files (repeatable).",
            "--gate PATH",
        ),
        InvRow(
            "--precompile",
            1,
            True,
            "SRC[:OUT]",
            FlagGroup.BUILDING,
            "Precompile package before builds (repeatable).",
            "--precompile SRC[:OUT]",
        ),
        InvRow(
            "--mojo",
            1,
            False,
            "PATH",
            FlagGroup.BUILDING,
            "Use this Mojo executable.",
            "--mojo PATH",
        ),
        InvRow(
            "-x",
            0,
            False,
            "",
            FlagGroup.EXECUTION,
            "Stop after the first failing file.",
            "-x, --exitfirst",
        ),
        InvRow(
            "--exitfirst",
            0,
            False,
            "",
            FlagGroup.EXECUTION,
            "Stop after the first failing file.",
            "-x, --exitfirst",
        ),
        InvRow(
            "--timeout",
            1,
            False,
            "SECS",
            FlagGroup.EXECUTION,
            "Set per-file run timeout (0 disables).",
            "--timeout SECS",
        ),
        InvRow(
            "-s",
            0,
            False,
            "",
            FlagGroup.REPORTING,
            "Show captured output for all files.",
            "-s",
        ),
        InvRow(
            "--show-output",
            1,
            False,
            "MODE",
            FlagGroup.REPORTING,
            "Choose failures|all|none captured output.",
            "--show-output MODE",
        ),
        InvRow(
            "-q",
            0,
            False,
            "",
            FlagGroup.REPORTING,
            "Suppress passing file rows.",
            "-q",
        ),
        InvRow(
            "-v",
            0,
            False,
            "",
            FlagGroup.REPORTING,
            "Show build commands and step timings.",
            "-v",
        ),
        InvRow(
            "--color",
            1,
            False,
            "WHEN",
            FlagGroup.REPORTING,
            "Choose auto|always|never color output.",
            "--color WHEN",
        ),
        InvRow(
            "-h",
            0,
            False,
            "",
            FlagGroup.GENERAL,
            "Show this help and exit.",
            "-h, --help",
        ),
        InvRow(
            "--help",
            0,
            False,
            "",
            FlagGroup.GENERAL,
            "Show this help and exit.",
            "-h, --help",
        ),
        InvRow(
            "--version",
            0,
            False,
            "",
            FlagGroup.GENERAL,
            "Show the version and exit.",
            "--version",
        ),
        InvRow(
            "-k",
            1,
            False,
            "STR",
            FlagGroup.SELECTION,
            "Select node ids containing STR.",
            "-k STR",
        ),
        InvRow(
            "--maxfail",
            1,
            False,
            "N",
            FlagGroup.EXECUTION,
            "Stop after N failed tests (0 disables).",
            "--maxfail N",
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
        ),
        InvRow(
            "--workers",
            1,
            False,
            "N|auto",
            FlagGroup.EXECUTION,
            "Set worker count (default: 1).",
            "-n, --workers N|auto",
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
        ),
        InvRow(
            "--seed",
            1,
            False,
            "N",
            FlagGroup.EXECUTION,
            "Fix the --shuffle order to a reproducible seed.",
            "--seed N",
        ),
        # CLI-only: never read from mtest.toml (build cache).
        InvRow(
            "--no-cache",
            0,
            False,
            "",
            FlagGroup.EXECUTION,
            "Build without reading/writing the build cache.",
            "--no-cache",
        ),
        InvRow(
            "--cache-clear",
            0,
            False,
            "",
            FlagGroup.EXECUTION,
            "Delete .mtest-cache (cache/last-run state), run.",
            "--cache-clear",
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
        ),
        InvRow(
            "--config",
            1,
            False,
            "PATH",
            FlagGroup.SESSION_STATE,
            "Use this project configuration file.",
            "--config PATH",
        ),
        InvRow(
            "--no-config",
            0,
            False,
            "",
            FlagGroup.SESSION_STATE,
            "Disable project configuration discovery.",
            "--no-config",
        ),
        InvRow(
            "--lf",
            0,
            False,
            "",
            FlagGroup.SESSION_STATE,
            "Run only entries from the last-failed state.",
            "--lf, --last-failed",
        ),
        InvRow(
            "--last-failed",
            0,
            False,
            "",
            FlagGroup.SESSION_STATE,
            "Run only entries from the last-failed state.",
            "--lf, --last-failed",
        ),
        InvRow(
            "--ff",
            0,
            False,
            "",
            FlagGroup.SESSION_STATE,
            "Run last-failed entries before the rest.",
            "--ff, --failed-first",
        ),
        InvRow(
            "--failed-first",
            0,
            False,
            "",
            FlagGroup.SESSION_STATE,
            "Run last-failed entries before the rest.",
            "--ff, --failed-first",
        ),
    ]


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
    # Five two-spelling aliases collapse 42 spellings into 37 physical rows.
    assert_equal(option_rows, 37)
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


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
