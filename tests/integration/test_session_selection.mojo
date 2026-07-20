"""The SELECTION pipeline, proven end to end through real build+probe+run.

The pure selection logic is table-tested in `test_select_*`; this module proves
the WIRING against real suites built and executed for real: a `-k` subset runs
under `--only` with the rest suppressed as DESELECTED, a node id selects one
test, an unknown name is exit 4 after the probe, an empty final selection is
exit 5, a selected failing test reports FAIL, and the chameleon drives the
loud recollect-once then MALFORMED-SUITE (exit-1 class, never exit 3).
"""
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from mtest.model import Event, EventKind, Outcome, ParseDisposition
from mtest.report import CompositeReporter, RecordingReporter
from mtest.session import run_session

from session_fixtures import (
    SRC_CHAMELEON,
    SRC_FAIL,
    SRC_FAIL_PHRASE,
    SRC_MATRIX,
    SRC_MATRIX_FAIL,
    SRC_ONLY_FLOOD,
    SRC_ONLY_LIAR,
    base_config,
    temp_root,
    write_file,
)


def _finished(rec: RecordingReporter) raises -> Event:
    var found = -1
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_FINISHED:
            found = i
    assert_true(found >= 0, "no FILE_FINISHED event")
    return rec.event_at(found)


def _count_kind(rec: RecordingReporter, kind: EventKind) raises -> Int:
    var n = 0
    for i in range(rec.count()):
        if rec.kind_at(i) == kind:
            n += 1
    return n


def _collection_known(rec: RecordingReporter) raises -> Event:
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.COLLECTION_KNOWN:
            return rec.event_at(i)
    raise Error("no COLLECTION_KNOWN event")


def test_keyword_subset_runs_only_selected_and_counts_deselected() raises:
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.paths.append("tests/test_matrix.mojo")
    cfg.keyword = "add"

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(cfg, root, comp)

    assert_equal(code, 0, "a passing subset selection exits 0")
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(finished.outcome == Outcome.PASS)
    # Two selected tests passed; one (test_sub_one) was deselected.
    assert_equal(finished.passed_tests, 2)
    assert_equal(finished.deselected_tests, 1)
    # Exactly two per-test rows were reported (the deselected one is suppressed).
    assert_equal(_count_kind(rec, EventKind.TEST_REPORTED), 2)
    # Collection was announced before execution with the run-wide totals.
    var ck = _collection_known(rec)
    assert_equal(ck.selected_test_total, 2)
    assert_equal(ck.deselected_test_total, 1)
    # The session's authoritative per-test totals carry the deselected count.
    var last = rec.event_at(rec.count() - 1)
    assert_true(last.kind == EventKind.SESSION_FINISHED)
    assert_equal(last.test_counts.passed, 2)
    assert_equal(last.test_counts.deselected, 1)


def test_node_id_selects_a_single_test() raises:
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.paths.append("tests/test_matrix.mojo::test_sub_one")

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(cfg, root, comp)

    assert_equal(code, 0)
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_equal(finished.passed_tests, 1)
    assert_equal(finished.deselected_tests, 2)
    assert_equal(_count_kind(rec, EventKind.TEST_REPORTED), 1)


def test_unknown_test_name_raises_before_any_body() raises:
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.paths.append("tests/test_matrix.mojo::test_nope")

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    with assert_raises(contains="unknown test"):
        _ = run_session(cfg, root, comp)


def test_empty_final_selection_exits_5() raises:
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.paths.append("tests/test_matrix.mojo")
    cfg.keyword = "no_such_test_zzz"

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(cfg, root, comp)

    assert_equal(code, 5, "every test deselected -> nothing ran -> exit 5")
    ref rec = comp.reporters[0]
    # No per-test row was reported; all three tests were deselected.
    assert_equal(_count_kind(rec, EventKind.TEST_REPORTED), 0)
    var last = rec.event_at(rec.count() - 1)
    assert_equal(last.test_counts.deselected, 3)


def test_selected_failing_test_reports_fail() raises:
    var root = temp_root()
    write_file(root, "tests/test_mf.mojo", SRC_MATRIX_FAIL)
    var cfg = base_config()
    cfg.paths.append("tests/test_mf.mojo::test_bad")

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1, "a selected failing test -> exit 1")
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(finished.outcome == Outcome.FAIL)
    assert_equal(finished.failed_tests, 1)
    assert_equal(finished.deselected_tests, 1)


def test_chameleon_recollects_once_then_malformed_suite() raises:
    var root = temp_root()
    write_file(root, "tests/test_chameleon.mojo", SRC_CHAMELEON)
    var cfg = base_config()
    # Select only the ghost -> a subset run under --only -> the stale-name path.
    cfg.paths.append("tests/test_chameleon.mojo")
    cfg.keyword = "ghost"

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(cfg, root, comp)

    # The stale-name path is MALFORMED-SUITE (exit-1 class), NEVER exit 3.
    assert_equal(code, 1, "a chameleon suite is MALFORMED-SUITE, exit 1")
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.outcome == Outcome.MALFORMED_SUITE,
        "a suite that refuses a name it listed twice is MALFORMED_SUITE",
    )
    # A loud stale-name warning fired during recovery.
    var saw_stale = False
    for i in range(rec.count()):
        if (
            rec.kind_at(i) == EventKind.WARNING
            and rec.event_at(i).warning_kind == "stale-name"
        ):
            saw_stale = True
    assert_true(saw_stale, "the recover-once flow must warn loudly")


def test_selected_off_grammar_run_is_drift_exit_3() raises:
    # The probe (--skip-all) is a clean two-test collection, but the selected
    # --only RUN emits an off-grammar trailing Summary. Selection must preserve
    # the same distinction the default path does: an OFF_GRAMMAR run is DRIFT
    # (exit 3), NOT collapsed to MALFORMED_SUITE (exit 1).
    var root = temp_root()
    write_file(root, "tests/test_ol.mojo", SRC_ONLY_LIAR)
    var cfg = base_config()
    cfg.paths.append("tests/test_ol.mojo::test_one")

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(cfg, root, comp)

    assert_equal(code, 3, "a selected off-grammar run is DRIFT, exit 3")
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.parse_disposition == ParseDisposition.DRIFT,
        "an off-grammar selected run is DRIFT, not malformed-suite",
    )
    var saw_drift = False
    for i in range(rec.count()):
        if (
            rec.kind_at(i) == EventKind.WARNING
            and rec.event_at(i).warning_kind == "drift"
        ):
            saw_drift = True
    assert_true(saw_drift, "a drifting selected run must warn loudly")


def test_selected_overflow_run_is_capture_overflow_exit_1() raises:
    # The probe is clean, but the selected --only RUN overflows the capture
    # bound. Selection must classify it as CAPTURE_OVERFLOW with the actionable
    # overflow hint (exit-1 class), not a generic MALFORMED_SUITE.
    var root = temp_root()
    write_file(root, "tests/test_of.mojo", SRC_ONLY_FLOOD)
    var cfg = base_config()
    cfg.timeout_secs = 30
    cfg.paths.append("tests/test_of.mojo::test_one")

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1, "a selected overflow run is exit-1 class")
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.parse_disposition == ParseDisposition.CAPTURE_OVERFLOW,
        "an overflowing selected run is CAPTURE_OVERFLOW",
    )
    var saw_overflow = False
    for i in range(rec.count()):
        if (
            rec.kind_at(i) == EventKind.WARNING
            and rec.event_at(i).warning_kind == "capture-overflow"
        ):
            saw_overflow = True
    assert_true(saw_overflow, "an overflowing run must warn with the hint")
    assert_true(
        finished.stdout_truncated,
        "the selected run's own overflow must mark stdout_truncated",
    )


def test_valid_fail_printing_stale_phrase_is_not_stale_name() raises:
    # A genuinely FAILING selected test that also prints the stale-name phrase in
    # its own body produces a VALID FAIL report. The anchored stale-name check
    # must treat it as a normal per-test FAIL (identity preserved), NEVER trip
    # the recover-once/MALFORMED_SUITE path off a bare substring.
    var root = temp_root()
    write_file(root, "tests/test_fp.mojo", SRC_FAIL_PHRASE)
    var cfg = base_config()
    cfg.paths.append("tests/test_fp.mojo::test_prints_phrase_and_fails")

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1, "a genuine FAIL resolves to exit 1")
    ref rec = comp.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.outcome == Outcome.FAIL,
        "a valid FAIL report is a per-test FAIL, not stale-name recovery",
    )
    assert_equal(finished.failed_tests, 1)
    var saw_stale = False
    for i in range(rec.count()):
        if (
            rec.kind_at(i) == EventKind.WARNING
            and rec.event_at(i).warning_kind == "stale-name"
        ):
            saw_stale = True
    assert_false(saw_stale, "a valid FAIL must not trip stale-name recovery")


def test_malformed_node_id_raises_even_when_a_gate_fails() raises:
    # The syntactic malformed-node-id check (pure over `config.paths`, needs no
    # probe universe) must raise its exit-4 usage error even when a gate fails
    # first — a failing gate must never mask it behind the gate's own exit 1.
    var root = temp_root()
    write_file(root, "tests/test_gate.mojo", SRC_FAIL)
    var cfg = base_config()
    cfg.gates.append("tests/test_gate.mojo")
    cfg.paths.append("bad::node::id")

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    with assert_raises(contains="malformed node id"):
        _ = run_session(cfg, root, comp)
