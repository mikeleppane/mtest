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
        # In the v1 contract but not served by this build.
        InvRow("-k", 1, False, False),
        InvRow("--maxfail", 1, False, False),
        InvRow("-n", 1, False, False),
        InvRow("--workers", 1, False, False),
        InvRow("--compile-timeout", 1, False, False),
        InvRow("--retries", 1, False, False),
        InvRow("--gate", 1, True, False),
        InvRow("--junit-xml", 1, False, False),
        InvRow("--gh-annotations", 1, False, False),
        InvRow("--collect-only", 0, False, False),
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


def test_refuse_k() raises:
    _assert_refused("-k")


def test_refuse_maxfail() raises:
    _assert_refused("--maxfail")


def test_refuse_workers_short() raises:
    _assert_refused("-n")


def test_refuse_workers_long() raises:
    _assert_refused("--workers")


def test_refuse_compile_timeout() raises:
    _assert_refused("--compile-timeout")


def test_refuse_retries() raises:
    _assert_refused("--retries")


def test_refuse_gate() raises:
    _assert_refused("--gate")


def test_refuse_junit_xml() raises:
    _assert_refused("--junit-xml")


def test_refuse_gh_annotations() raises:
    _assert_refused("--gh-annotations")


def test_refuse_collect_only() raises:
    _assert_refused("--collect-only")


def test_refuse_collect_subcommand() raises:
    var argv: List[String] = ["collect", "tests/"]
    with assert_raises(contains="v1 contract"):
        _ = parse_args(argv)
    var argv2: List[String] = ["collect"]
    with assert_raises(contains="collect"):
        _ = parse_args(argv2)


def test_refuse_equals_form_still_names_flag() raises:
    var argv: List[String] = ["--maxfail=3"]
    with assert_raises(contains="--maxfail"):
        _ = parse_args(argv)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
