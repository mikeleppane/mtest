"""The independent frozen-inventory cross-check and the refusal messages.

`frozen_inventory()` is a HAND-WRITTEN transcription of the command-line
contract's flag table — authored by reading the contract, never generated from
the parser's own `flag_specs()`. The cross-check asserts the parser's table is a
row-for-row bijection with this frozen list, so a drifted arity, a flipped
availability bit, or a dropped spelling fails loudly and the spec table can
never be its own oracle.

The remaining tests pin every refused spelling's message shape: it names the
token, states it is part of the mtest v1 contract, and says it is not available
in this build.
"""
from std.testing import assert_equal, assert_raises, assert_true, TestSuite

from mtest.cli import flag_specs, parse_args
from mtest.config import ShardMode


@fieldwise_init
struct InvRow(Copyable, Movable):
    """One hand-written inventory row: a spelling and its contract facts."""

    var spelling: String
    var arity: Int
    var repeatable: Bool
    var available: Bool


def frozen_inventory() -> List[InvRow]:
    """Every flag spelling in the v1 contract, transcribed by hand.

    Availability reflects what THIS build serves; arity and repeatability are
    contract facts independent of availability. Authored from the contract, not
    from `flag_specs()`.
    """
    return [
        # Served by this build.
        InvRow("--exclude", 1, True, True),
        InvRow("-I", 1, True, True),
        InvRow("--build-arg", 1, True, True),
        InvRow("--gate", 1, True, True),
        InvRow("--precompile", 1, True, True),
        InvRow("--mojo", 1, False, True),
        InvRow("-x", 0, False, True),
        InvRow("--exitfirst", 0, False, True),
        InvRow("--timeout", 1, False, True),
        InvRow("-s", 0, False, True),
        InvRow("--show-output", 1, False, True),
        InvRow("-q", 0, False, True),
        InvRow("-v", 0, False, True),
        InvRow("--color", 1, False, True),
        InvRow("-h", 0, False, True),
        InvRow("--help", 0, False, True),
        InvRow("--version", 0, False, True),
        InvRow("-k", 1, False, True),
        InvRow("--maxfail", 1, False, True),
        # `--durations N`: non-negative int; 0 disables.
        InvRow("--durations", 1, False, True),
        # `--shard [hash:|slice:]M/N`: 1<=M<=N, last-wins.
        InvRow("--shard", 1, False, True),
        # `--retries N`: non-negative int; 0 disables.
        InvRow("--retries", 1, False, True),
        # `--compile-timeout SECS`: non-negative int; 0 disables.
        InvRow("--compile-timeout", 1, False, True),
        # In the v1 contract but not served by this build.
        InvRow("-n", 1, False, False),
        InvRow("--workers", 1, False, False),
        InvRow("--gh-annotations", 1, False, False),
        # `--serial GLOB`: repeatable.
        InvRow("--serial", 1, True, False),
        # `--json PATH|-`: now served.
        InvRow("--json", 1, False, True),
        # `--junit-xml PATH`: now served.
        InvRow("--junit-xml", 1, False, True),
        # Served by this build (collect mode).
        InvRow("--collect-only", 0, False, True),
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
                    spec.available,
                    row.available,
                    "availability drift: " + spec.spelling,
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


# --- refusal message shape for every unserved spelling ---


def _assert_refused(spelling: String) raises:
    var argv: List[String] = [spelling]
    with assert_raises(contains="v1 contract"):
        _ = parse_args(argv)
    var argv2: List[String] = [spelling]
    with assert_raises(contains="not available in this build"):
        _ = parse_args(argv2)
    var argv3: List[String] = [spelling]
    with assert_raises(contains=spelling):
        _ = parse_args(argv3)


def test_refuse_workers_short() raises:
    _assert_refused("-n")


def test_refuse_workers_long() raises:
    _assert_refused("--workers")


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


def test_refuse_gh_annotations() raises:
    _assert_refused("--gh-annotations")


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


def test_refuse_serial() raises:
    _assert_refused("--serial")


def test_json_dash_is_served_and_sets_stdout_destination() raises:
    # `--json -` is now served: the stream destination is stdout (`-`).
    var argv: List[String] = ["--json", "-"]
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


def test_refuse_equals_form_still_names_flag() raises:
    var argv: List[String] = ["--workers=3"]
    with assert_raises(contains="--workers"):
        _ = parse_args(argv)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
