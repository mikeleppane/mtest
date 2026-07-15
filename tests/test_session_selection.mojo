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
    TestSuite,
)

from mtest.model import Event, EventKind, Outcome
from mtest.report import CompositeReporter, RecordingReporter
from mtest.session import run_session

from session_fixtures import (
    SRC_CHAMELEON,
    SRC_FAIL,
    SRC_MATRIX,
    SRC_MATRIX_FAIL,
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
