"""Last-run state codec, outcome accumulation, and preservation-merge tests.

The state layer is pure: hostile text becomes typed diagnostics, normalized
verdict facts become a delta, and unobserved failures survive the merge.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.config import (
    LastRunRecord,
    LastRunRecordKind,
    LastRunState,
    StateDelta,
    encode_last_run_state,
    merge_last_run_state,
    parse_last_run_state,
)
from mtest.model import NodeId, Outcome


def _file(path: String) -> LastRunRecord:
    return LastRunRecord.file(path)


def _test(path: String, name: String) -> LastRunRecord:
    return LastRunRecord.test(NodeId(path, name))


def _state(var records: List[LastRunRecord]) -> LastRunState:
    return LastRunState(records=records^)


def _contains(
    state: LastRunState, kind: LastRunRecordKind, identifier: String
) -> Bool:
    for record in state.records:
        if record.kind == kind and record.identifier == identifier:
            return True
    return False


def _assert_one_record(
    delta: StateDelta, kind: LastRunRecordKind, identifier: String
) raises:
    assert_equal(len(delta.failures), 1)
    assert_true(delta.failures[0].kind == kind)
    assert_equal(delta.failures[0].identifier, identifier)


def _assert_delta_counts(
    delta: StateDelta,
    observed_tests: Int,
    observed_files: Int,
    fully_observed_files: Int,
    terminal_files: Int,
    failures: Int,
) raises:
    assert_equal(len(delta.observed_tests), observed_tests)
    assert_equal(len(delta.observed_files), observed_files)
    assert_equal(len(delta.fully_observed_files), fully_observed_files)
    assert_equal(len(delta.terminal_files), terminal_files)
    assert_equal(len(delta.failures), failures)


def _all_state_outcomes() -> List[Outcome]:
    """Return every model outcome exactly once for the delta totality guard."""
    return [
        Outcome.PASS,
        Outcome.FAIL,
        Outcome.SKIP,
        Outcome.CRASH,
        Outcome.TIMEOUT,
        Outcome.COMPILE_ERROR,
        Outcome.COMPILE_TIMEOUT,
        Outcome.MALFORMED_SUITE,
        Outcome.PRECOMPILE_ERROR,
        Outcome.FLAKY,
        Outcome.DESELECTED,
        Outcome.EXCLUDED,
        Outcome.NOT_RUN,
    ]


def _assert_no_identifier_controls(text: String) raises:
    assert_false("\x00" in text)
    assert_false("\x1b" in text)
    assert_false("\x1f" in text)
    assert_false("\x7f" in text)


def test_empty_state_has_only_header_and_final_newline() raises:
    var encoded = encode_last_run_state(LastRunState.empty())
    assert_equal(encoded.text, "mtest-lastrun v1\n")
    assert_equal(len(encoded.diagnostics), 0)

    var parsed = parse_last_run_state(encoded.text, "empty")
    assert_equal(len(parsed.state.records), 0)
    assert_equal(len(parsed.diagnostics), 0)


def test_codec_sorts_deduplicates_and_round_trips() raises:
    var state = _state(
        [
            _test("tests/z.mojo", "test_z"),
            _file("tests/b.mojo"),
            _test("tests/a.mojo", "test_b"),
            _file("tests/a.mojo"),
            _test("tests/a.mojo", "test_a"),
            _file("tests/b.mojo"),
        ]
    )
    var encoded = encode_last_run_state(state)
    assert_equal(
        encoded.text,
        (
            "mtest-lastrun v1\n"
            "file\ttests/a.mojo\n"
            "file\ttests/b.mojo\n"
            "test\ttests/a.mojo::test_a\n"
            "test\ttests/a.mojo::test_b\n"
            "test\ttests/z.mojo::test_z\n"
        ),
    )
    assert_equal(len(encoded.diagnostics), 0)

    var parsed = parse_last_run_state(encoded.text, "round-trip")
    assert_equal(len(parsed.state.records), 5)
    assert_equal(
        encode_last_run_state(parsed.state).text,
        encoded.text,
    )


def test_event_order_permutations_encode_identically() raises:
    var first = StateDelta.empty()
    first.observe_test(NodeId("tests/b.mojo", "test_b"), Outcome.FAIL)
    first.observe_file("tests/b.mojo", Outcome.FAIL, fully_observed=True)
    first.observe_test(NodeId("tests/a.mojo", "test_a"), Outcome.FAIL)
    first.observe_file("tests/a.mojo", Outcome.FAIL, fully_observed=True)

    var second = StateDelta.empty()
    second.observe_file("tests/a.mojo", Outcome.FAIL, fully_observed=True)
    second.observe_test(NodeId("tests/a.mojo", "test_a"), Outcome.FAIL)
    second.observe_file("tests/b.mojo", Outcome.FAIL, fully_observed=True)
    second.observe_test(NodeId("tests/b.mojo", "test_b"), Outcome.FAIL)

    var previous = LastRunState.empty()
    var first_text = encode_last_run_state(
        merge_last_run_state(previous, first)
    ).text
    var second_text = encode_last_run_state(
        merge_last_run_state(previous, second)
    ).text
    assert_equal(first_text, second_text)


def test_unknown_malformed_and_missing_headers_reject_the_whole_file() raises:
    var cases = [
        String(""),
        String("mtest-lastrun v2\nfile\ttests/a.mojo\n"),
        String("mtest-lastrun\nfile\ttests/a.mojo\n"),
        String("file\ttests/a.mojo\n"),
    ]
    for text in cases:
        var parsed = parse_last_run_state(text, "header")
        assert_equal(len(parsed.state.records), 0)
        assert_equal(len(parsed.diagnostics), 1)
        assert_true(parsed.diagnostics[0].kind.is_header())


def test_every_malformed_record_category_is_dropped_and_parsing_continues() raises:
    var text = (
        "mtest-lastrun v1\n"
        "file\ttests/good-a.mojo\n"
        "mystery\ttests/unknown-kind.mojo\n"
        "file\n"
        "file\ttoo\tmany\n"
        "file\t\n"
        "test\ttests/no-separator.mojo\n"
        "test\t::test_empty_path\n"
        "test\ttests/empty-name.mojo::\n"
        "test\ttests/many.mojo::test_a::extra\n"
        "file\ttests/carriage.mojo\r\n"
        "file\ttests/tab\tinside.mojo\n"
        "forged-after-newline\n"
        "test\ttests/good-b.mojo::test_ok\n"
    )
    var parsed = parse_last_run_state(text, "malformed")
    assert_equal(len(parsed.state.records), 2)
    assert_true(
        _contains(parsed.state, LastRunRecordKind.FILE, "tests/good-a.mojo")
    )
    assert_true(
        _contains(
            parsed.state,
            LastRunRecordKind.TEST,
            "tests/good-b.mojo::test_ok",
        )
    )
    assert_equal(len(parsed.diagnostics), 11)
    for diagnostic in parsed.diagnostics:
        assert_true(diagnostic.kind.is_record())


def test_duplicate_valid_records_are_accepted_and_canonicalized_once() raises:
    var parsed = parse_last_run_state(
        (
            "mtest-lastrun v1\n"
            "test\ttests/a.mojo::test_a\n"
            "file\ttests/b.mojo\n"
            "test\ttests/a.mojo::test_a\n"
            "file\ttests/b.mojo\n"
        ),
        "duplicates",
    )
    assert_equal(len(parsed.diagnostics), 0)
    assert_equal(
        encode_last_run_state(parsed.state).text,
        "mtest-lastrun v1\nfile\ttests/b.mojo\ntest\ttests/a.mojo::test_a\n",
    )


def test_hostile_diagnostics_are_bounded_c0_safe_and_single_line() raises:
    var source = (
        "evil\nsource\r\t\x1b"
        + "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        + "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        + "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    )
    var parsed = parse_last_run_state(
        "mtest-lastrun v1\nunknown\tbad\ridentifier\n",
        source,
    )
    assert_equal(len(parsed.diagnostics), 1)
    var rendered = parsed.diagnostics[0].render()
    assert_equal(len(rendered.split("\n")), 1)
    assert_false("\r" in rendered)
    assert_false("\t" in rendered)
    assert_false("\x1b" in rendered)
    assert_true("\\n" in rendered)
    assert_true("\\r" in rendered)
    assert_true("\\t" in rendered)
    assert_true(rendered.count_codepoints() <= 400)


def test_hostile_and_truncated_inputs_never_raise() raises:
    var cases = [
        String("\x00"),
        String("m"),
        String("mtest-lastrun v1"),
        String("mtest-lastrun v1\nf"),
        String("mtest-lastrun v1\nfile\t"),
        String("mtest-lastrun v1\ntest\t::"),
        String("mtest-lastrun v1\n💥\t雪"),
        String("mtest-lastrun v1\n\n\n"),
    ]
    for i in range(len(cases)):
        var parsed = parse_last_run_state(cases[i], "arbitrary")
        var canonical = encode_last_run_state(parsed.state)
        assert_true(canonical.text.startswith("mtest-lastrun v1\n"))


def test_encoder_drops_hostile_identifiers_with_typed_diagnostics() raises:
    var state = _state(
        [
            LastRunRecord(LastRunRecordKind.FILE, "tests/tab\tfile.mojo"),
            LastRunRecord(LastRunRecordKind.FILE, "tests/cr\rfile.mojo"),
            LastRunRecord(LastRunRecordKind.FILE, "tests/lf\nfile.mojo"),
            LastRunRecord(
                LastRunRecordKind.TEST, "tests/bad.mojo::test_bad::extra"
            ),
            _file("tests/good.mojo"),
        ]
    )
    var encoded = encode_last_run_state(state, "encode\nsource")
    assert_equal(
        encoded.text,
        "mtest-lastrun v1\nfile\ttests/good.mojo\n",
    )
    assert_equal(len(encoded.diagnostics), 4)
    for diagnostic in encoded.diagnostics:
        assert_true(diagnostic.kind.is_record())
        assert_equal(len(diagnostic.render().split("\n")), 1)


def test_codec_rejects_c0_and_del_in_file_and_test_identifiers() raises:
    var controls = [
        String("\x00"),
        String("\x1b"),
        String("\x1f"),
        String("\x7f"),
    ]
    var records = List[LastRunRecord]()
    var text = String("mtest-lastrun v1\n")
    for control in controls:
        var file_identifier = "tests/file" + control + ".mojo"
        var test_identifier = "tests/file.mojo::test" + control + "case"
        records.append(LastRunRecord(LastRunRecordKind.FILE, file_identifier))
        records.append(LastRunRecord(LastRunRecordKind.TEST, test_identifier))
        text += "file\t" + file_identifier + "\n"
        text += "test\t" + test_identifier + "\n"

    var encoded = encode_last_run_state(_state(records^), "encode-controls")
    assert_equal(encoded.text, "mtest-lastrun v1\n")
    assert_equal(len(encoded.diagnostics), len(controls) * 2)
    _assert_no_identifier_controls(encoded.text)
    for diagnostic in encoded.diagnostics:
        _assert_no_identifier_controls(diagnostic.render())

    var parsed = parse_last_run_state(text, "parse-controls")
    assert_equal(len(parsed.state.records), 0)
    assert_equal(len(parsed.diagnostics), len(controls) * 2)
    var reencoded = encode_last_run_state(parsed.state)
    assert_equal(reencoded.text, "mtest-lastrun v1\n")
    _assert_no_identifier_controls(reencoded.text)
    for diagnostic in parsed.diagnostics:
        _assert_no_identifier_controls(diagnostic.render())


def test_complete_outcome_table_maps_only_fresh_failures() raises:
    var node = NodeId("tests/table.mojo", "test_case")
    var outcomes = _all_state_outcomes()
    assert_equal(len(outcomes), Outcome.COUNT)

    for outcome in outcomes:
        var test_delta = StateDelta.empty()
        test_delta.observe_test(node.copy(), outcome)
        var file_delta = StateDelta.empty()
        file_delta.observe_file(
            "tests/table.mojo", outcome, fully_observed=True
        )

        var is_normal = (
            outcome == Outcome.PASS
            or outcome == Outcome.FAIL
            or outcome == Outcome.SKIP
            or outcome == Outcome.FLAKY
        )
        var is_abnormal = (
            outcome == Outcome.CRASH
            or outcome == Outcome.TIMEOUT
            or outcome == Outcome.COMPILE_ERROR
            or outcome == Outcome.COMPILE_TIMEOUT
            or outcome == Outcome.MALFORMED_SUITE
        )
        if is_normal:
            var test_failures = 1 if outcome == Outcome.FAIL else 0
            _assert_delta_counts(test_delta, 1, 0, 0, 0, test_failures)
            if outcome == Outcome.FAIL:
                _assert_one_record(
                    test_delta,
                    LastRunRecordKind.TEST,
                    "tests/table.mojo::test_case",
                )
            _assert_delta_counts(file_delta, 0, 1, 1, 0, 0)
        elif is_abnormal:
            _assert_delta_counts(test_delta, 0, 1, 0, 1, 1)
            _assert_one_record(
                test_delta, LastRunRecordKind.FILE, "tests/table.mojo"
            )
            _assert_delta_counts(file_delta, 0, 1, 0, 1, 1)
            _assert_one_record(
                file_delta, LastRunRecordKind.FILE, "tests/table.mojo"
            )
        else:
            # PRECOMPILE_ERROR is event-only and needs named casualties.
            # DESELECTED, EXCLUDED, and NOT_RUN carry no verdict.
            _assert_delta_counts(test_delta, 0, 0, 0, 0, 0)
            _assert_delta_counts(file_delta, 0, 0, 0, 0, 0)


def test_precompile_casualties_and_failed_gates_are_file_failures() raises:
    var delta = StateDelta.empty()
    delta.observe_precompile_casualties(
        ["tests/pre-a.mojo", "tests/pre-b.mojo"]
    )
    delta.observe_gate("tests/gate.mojo", failed=True)
    assert_equal(len(delta.failures), 3)
    assert_equal(len(delta.observed_files), 3)
    assert_equal(len(delta.terminal_files), 3)
    assert_true(
        _contains(
            _state(delta.failures.copy()),
            LastRunRecordKind.FILE,
            "tests/pre-a.mojo",
        )
    )
    assert_true(
        _contains(
            _state(delta.failures.copy()),
            LastRunRecordKind.FILE,
            "tests/pre-b.mojo",
        )
    )
    assert_true(
        _contains(
            _state(delta.failures.copy()),
            LastRunRecordKind.FILE,
            "tests/gate.mojo",
        )
    )


def test_sharded_out_is_not_an_observation_or_failure() raises:
    var delta = StateDelta.empty()
    delta.record_sharded_out("tests/sharded.mojo")
    _assert_delta_counts(delta, 0, 0, 0, 0, 0)


def test_partial_pass_clears_file_and_observed_test_only() raises:
    var previous = _state(
        [
            _file("tests/a.mojo"),
            _test("tests/a.mojo", "test_selected"),
            _test("tests/a.mojo", "test_unselected"),
            _test("tests/outside.mojo", "test_old"),
        ]
    )
    var delta = StateDelta.empty()
    delta.observe_test(NodeId("tests/a.mojo", "test_selected"), Outcome.PASS)
    delta.observe_file("tests/a.mojo", Outcome.PASS, fully_observed=False)

    var merged = merge_last_run_state(previous, delta)
    assert_false(
        _contains(
            merged,
            LastRunRecordKind.TEST,
            "tests/a.mojo::test_selected",
        )
    )
    assert_false(_contains(merged, LastRunRecordKind.FILE, "tests/a.mojo"))
    assert_true(
        _contains(
            merged,
            LastRunRecordKind.TEST,
            "tests/a.mojo::test_unselected",
        )
    )
    assert_true(
        _contains(
            merged,
            LastRunRecordKind.TEST,
            "tests/outside.mojo::test_old",
        )
    )


def test_partial_fail_replaces_file_and_preserves_unselected_test() raises:
    var previous = _state(
        [
            _file("tests/a.mojo"),
            _test("tests/a.mojo", "test_old"),
            _file("tests/outside.mojo"),
        ]
    )
    var delta = StateDelta.empty()
    delta.observe_test(NodeId("tests/a.mojo", "test_new"), Outcome.FAIL)
    delta.observe_file("tests/a.mojo", Outcome.FAIL, fully_observed=False)

    var merged = merge_last_run_state(previous, delta)
    assert_false(_contains(merged, LastRunRecordKind.FILE, "tests/a.mojo"))
    assert_true(
        _contains(merged, LastRunRecordKind.TEST, "tests/a.mojo::test_old")
    )
    assert_true(
        _contains(merged, LastRunRecordKind.TEST, "tests/a.mojo::test_new")
    )
    assert_true(_contains(merged, LastRunRecordKind.FILE, "tests/outside.mojo"))
    assert_equal(len(merged.records), 3)


def test_file_terminal_observation_replaces_every_record_for_that_file() raises:
    var previous = _state(
        [
            _file("tests/a.mojo"),
            _test("tests/a.mojo", "test_a"),
            _test("tests/a.mojo", "test_b"),
            _file("tests/outside.mojo"),
        ]
    )
    var delta = StateDelta.empty()
    delta.observe_test(NodeId("tests/a.mojo", "test_a"), Outcome.FAIL)
    delta.observe_file("tests/a.mojo", Outcome.CRASH, fully_observed=False)

    var merged = merge_last_run_state(previous, delta)
    assert_true(_contains(merged, LastRunRecordKind.FILE, "tests/a.mojo"))
    assert_false(
        _contains(merged, LastRunRecordKind.TEST, "tests/a.mojo::test_a")
    )
    assert_false(
        _contains(merged, LastRunRecordKind.TEST, "tests/a.mojo::test_b")
    )
    assert_true(_contains(merged, LastRunRecordKind.FILE, "tests/outside.mojo"))


def test_fully_observed_file_replaces_old_records_with_fresh_test_failures() raises:
    var previous = _state(
        [
            _file("tests/a.mojo"),
            _test("tests/a.mojo", "test_old"),
            _file("tests/outside.mojo"),
        ]
    )
    var delta = StateDelta.empty()
    delta.observe_test(NodeId("tests/a.mojo", "test_pass"), Outcome.PASS)
    delta.observe_test(NodeId("tests/a.mojo", "test_fail"), Outcome.FAIL)
    delta.observe_file("tests/a.mojo", Outcome.FAIL, fully_observed=True)

    var merged = merge_last_run_state(previous, delta)
    assert_false(_contains(merged, LastRunRecordKind.FILE, "tests/a.mojo"))
    assert_false(
        _contains(merged, LastRunRecordKind.TEST, "tests/a.mojo::test_old")
    )
    assert_true(
        _contains(merged, LastRunRecordKind.TEST, "tests/a.mojo::test_fail")
    )
    assert_true(_contains(merged, LastRunRecordKind.FILE, "tests/outside.mojo"))


def test_lf_exitfirst_preserves_b_when_b_receives_not_run() raises:
    var previous = _state(
        [
            _test("tests/a.mojo", "test_a"),
            _test("tests/b.mojo", "test_b"),
        ]
    )
    var delta = StateDelta.empty()
    delta.observe_test(NodeId("tests/a.mojo", "test_a"), Outcome.FAIL)
    delta.observe_file("tests/a.mojo", Outcome.FAIL, fully_observed=True)
    delta.observe_file("tests/b.mojo", Outcome.NOT_RUN, fully_observed=True)

    var merged = merge_last_run_state(previous, delta)
    assert_true(
        _contains(merged, LastRunRecordKind.TEST, "tests/a.mojo::test_a")
    )
    assert_true(
        _contains(merged, LastRunRecordKind.TEST, "tests/b.mojo::test_b")
    )
    assert_equal(len(merged.records), 2)


def test_full_green_selection_naturally_clears_state() raises:
    var previous = _state(
        [
            _file("tests/a.mojo"),
            _test("tests/a.mojo", "test_a"),
            _test("tests/b.mojo", "test_b"),
        ]
    )
    var delta = StateDelta.empty()
    delta.observe_test(NodeId("tests/a.mojo", "test_a"), Outcome.PASS)
    delta.observe_file("tests/a.mojo", Outcome.PASS, fully_observed=True)
    delta.observe_test(NodeId("tests/b.mojo", "test_b"), Outcome.SKIP)
    delta.observe_file("tests/b.mojo", Outcome.PASS, fully_observed=True)

    var merged = merge_last_run_state(previous, delta)
    assert_equal(len(merged.records), 0)


def test_passing_gate_clears_its_previous_failure() raises:
    var previous = _state([_file("tests/gate.mojo")])
    var delta = StateDelta.empty()
    delta.observe_gate("tests/gate.mojo", failed=False)
    var merged = merge_last_run_state(previous, delta)
    assert_equal(len(merged.records), 0)
