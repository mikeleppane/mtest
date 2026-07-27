"""The SELECTION pipeline, proven end to end through real build+probe+run.

The pure selection logic is table-tested in `test_select_*`; this module proves
the WIRING against real suites built and executed for real: a `-k` subset runs
under `--only` with the rest suppressed as DESELECTED, a node id selects one
test, an unknown name is exit 4 after the probe, an empty final selection is
exit 5, a selected failing test reports FAIL, and the chameleon drives the
loud recollect-once then MALFORMED-SUITE (exit-1 class, never exit 3).

Two cases pin the RECONCILIATION the selection run performs against its own
probe: a run whose rows lost a collected test, and a run in which a deselected
test reports a real outcome instead of the selection-induced SKIP. Both are
user-controlled suite disagreements, so both stay MALFORMED-SUITE at exit 1 with
their own exact diagnostic — never DRIFT, never exit 3.
"""
from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from mtest.config import (
    CliOverlay,
    ConfigEnvironment,
    FileConfig,
    LastRunRecord,
    LastRunState,
    ResolvedConfig,
    RunnerConfig,
    resolve_config,
)
from mtest.model import (
    Event,
    EventKind,
    Outcome,
    ParseDisposition,
    AttributionDisposition,
    AttemptFinishedPayload,
    CollectionKnownPayload,
    CrashAttributionPayload,
    FileFinishedPayload,
    SessionFinishedPayload,
    SessionStartedPayload,
    WarningPayload,
    NodeId,
)
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_session

from session_fixtures import (
    SRC_CHAMELEON,
    SRC_CHAMELEON_PROBE_CRASH,
    SRC_CHAMELEON_RENAME_CRASH,
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

# A suite whose --skip-all listing and --only registration DISAGREE about the
# universe: three names are collected, but a selection run registers only two,
# so the run's row set can never equal the collected set. The dropped name is
# NOT the selected one, so the stdlib never refuses a requested test and the
# stale-name recovery path is never entered — the disagreement surfaces purely
# as membership reconciliation.
comptime _SRC_SHRINKING_UNIVERSE = (
    "from std.sys import argv\n"
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_alpha() raises:\n    assert_true(True)\n\n\n"
    "def test_beta() raises:\n    assert_true(True)\n\n\n"
    "def test_gamma() raises:\n    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    var has_only = False\n"
    "    for a in argv():\n"
    '        if a == "--only":\n'
    "            has_only = True\n"
    "    var s = TestSuite()\n"
    "    s.test[test_alpha]()\n"
    "    s.test[test_beta]()\n"
    "    if not has_only:\n"
    "        s.test[test_gamma]()\n"
    "    s^.run()\n"
)

# A suite that collects honestly under --skip-all but, under --only, hand-forges
# a report in which the DESELECTED test claims PASS instead of the
# selection-induced SKIP. The row set still equals the collected set, so only the
# per-row selection check can catch it. The header path is resolved at runtime,
# so the forged report carries the same byte-exact canonical identity a genuine
# report would.
comptime _SRC_DESELECTED_RAN = (
    "from std.os.path import realpath\n"
    "from std.sys import argv\n"
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_one() raises:\n    assert_true(True)\n\n\n"
    "def test_two() raises:\n    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    var has_only = False\n"
    "    for a in argv():\n"
    '        if a == "--only":\n'
    "            has_only = True\n"
    "    if not has_only:\n"
    "        TestSuite.discover_tests[__functions_in_module()]().run()\n"
    "        return\n"
    '    var p = realpath("tests/test_deselected_ran.mojo")\n'
    '    print("Running 2 tests for " + p + " ")\n'
    '    print("    PASS [ 0.00s ] test_one")\n'
    '    print("    PASS [ 0.00s ] test_two")\n'
    '    print("--------")\n'
    '    print("Summary [ 0.00s ] 2 tests run: 2 passed , 0 failed ,'
    ' 0 skipped ")\n'
)

comptime _SRC_RETRY_THEN_STALE_BUILD_ERROR = (
    "from std.ffi import external_call\n"
    "from std.os.path import exists\n"
    "from std.sys import argv\n"
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_real() raises:\n    assert_true(True)\n\n\n"
    "def test_ghost() raises:\n    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    var probing = False\n"
    "    var has_only = False\n"
    "    for a in argv():\n"
    '        if a == "--skip-all":\n'
    "            probing = True\n"
    '        if a == "--only":\n'
    "            has_only = True\n"
    "    if probing:\n"
    "        var s = TestSuite()\n"
    "        s.test[test_real]()\n"
    "        s.test[test_ghost]()\n"
    "        s^.run()\n"
    "        return\n"
    '    if not exists("recovery_build_marker"):\n'
    '        with open("recovery_build_marker", "w") as f:\n'
    '            f.write("1")\n'
    '        _ = external_call["abort", Int32]()\n'
    '    with open("tests/test_retry_recovery_build.mojo", "a") as f:\n'
    '        f.write("\\ninvalid recovery source\\n")\n'
    "    var s = TestSuite()\n"
    "    s.test[test_real]()\n"
    "    s^.run()\n"
)

comptime _SRC_RETRY_THEN_STALE_PROBE_CRASH = (
    "from std.ffi import external_call\n"
    "from std.os.path import exists\n"
    "from std.sys import argv\n"
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_real() raises:\n    assert_true(True)\n\n\n"
    "def test_ghost() raises:\n    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    var probing = False\n"
    "    var has_only = False\n"
    "    for a in argv():\n"
    '        if a == "--skip-all":\n'
    "            probing = True\n"
    '        if a == "--only":\n'
    "            has_only = True\n"
    "    if probing:\n"
    '        if exists("recovery_probe_marker"):\n'
    '            _ = external_call["abort", Int32]()\n'
    "        var s = TestSuite()\n"
    "        s.test[test_real]()\n"
    "        s.test[test_ghost]()\n"
    "        s^.run()\n"
    "        return\n"
    '    if not exists("recovery_probe_marker"):\n'
    '        with open("recovery_probe_marker", "w") as f:\n'
    '            f.write("1")\n'
    '        _ = external_call["abort", Int32]()\n'
    "    var s = TestSuite()\n"
    "    s.test[test_real]()\n"
    "    s^.run()\n"
)


def _finished(rec: RecordingReporter) raises -> FileFinishedPayload:
    var found = -1
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_FINISHED:
            found = i
    assert_true(found >= 0, "no FILE_FINISHED event")
    return rec.event_at(found).data[FileFinishedPayload].copy()


def _resolved_state(
    config: RunnerConfig, state: LastRunState
) -> ResolvedConfig:
    var resolved = resolve_config(
        config,
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    resolved.last_run_state = state.copy()
    return resolved^


def _count_kind(rec: RecordingReporter, kind: EventKind) raises -> Int:
    var n = 0
    for i in range(rec.count()):
        if rec.kind_at(i) == kind:
            n += 1
    return n


def _collection_known(rec: RecordingReporter) raises -> CollectionKnownPayload:
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.COLLECTION_KNOWN:
            return rec.event_at(i).data[CollectionKnownPayload].copy()
    raise Error("no COLLECTION_KNOWN event")


def _crash_attribution(
    rec: RecordingReporter,
) raises -> CrashAttributionPayload:
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.CRASH_ATTRIBUTION:
            return rec.event_at(i).data[CrashAttributionPayload].copy()
    raise Error("no CRASH_ATTRIBUTION event")


def _assert_retry_then_recovery_terminal(
    rec: RecordingReporter, expected: Outcome
) raises:
    """Assert one TRY then stale recovery and an attempt-two terminal event."""
    var try_i = -1
    var stale_i = -1
    var finished_i = -1
    var tries = 0
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.ATTEMPT_FINISHED:
            tries += 1
            try_i = i
            ref attempt = rec.event_at(i).data[AttemptFinishedPayload]
            assert_equal(attempt.step, "run")
            assert_equal(attempt.attempt_index, 1)
            assert_equal(attempt.attempts_planned, 2)
            assert_true(attempt.retry_eligible)
        elif rec.kind_at(i) == EventKind.WARNING:
            if (
                rec.event_at(i).data[WarningPayload].warning_kind
                == "stale-name"
            ):
                stale_i = i
        elif rec.kind_at(i) == EventKind.FILE_FINISHED:
            finished_i = i

    assert_equal(tries, 1, "exactly one crash-class TRY precedes recovery")
    assert_true(try_i >= 0, "the first crash must emit AttemptFinished")
    assert_true(stale_i > try_i, "stale-name follows the first attempt's TRY")
    assert_true(
        finished_i > stale_i, "the recovery terminal follows its loud warning"
    )
    var finished = rec.event_at(finished_i).data[FileFinishedPayload].copy()
    assert_true(finished.outcome == expected)
    assert_equal(
        finished.attempts_used,
        2,
        "a terminal recovery step belongs to the second run attempt",
    )


def test_keyword_subset_runs_only_selected_and_counts_deselected() raises:
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.paths.append("tests/test_matrix.mojo")
    cfg.keyword = "add"

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 0, "a passing subset selection exits 0")
    ref rec = comp.composite.reporters[0]
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
    assert_equal(last.data[SessionFinishedPayload].test_counts.passed, 2)
    assert_equal(last.data[SessionFinishedPayload].test_counts.deselected, 1)


def test_selection_forces_one_worker_and_an_honest_header() raises:
    # Selection (`-k`/a node id) runs the sequential selection sub-session, which
    # the pool never drives. A worker request cannot be honored there, so the
    # header must report ONE worker, never the requested count — it must not
    # claim a parallelism the run does not use.
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.paths.append("tests/test_matrix.mojo")
    cfg.keyword = "add"
    cfg.workers = 4

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 0)
    ref rec = comp.composite.reporters[0]
    var workers_reported = -1
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.SESSION_STARTED:
            workers_reported = (
                rec.event_at(i).data[SessionStartedPayload].workers
            )
            break
    assert_equal(
        workers_reported,
        1,
        "selection must report a sequential (one-worker) header",
    )


def test_node_id_selects_a_single_test() raises:
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.paths.append("tests/test_matrix.mojo::test_sub_one")

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 0)
    ref rec = comp.composite.reporters[0]
    var finished = _finished(rec)
    assert_equal(finished.passed_tests, 1)
    assert_equal(finished.deselected_tests, 2)
    assert_equal(_count_kind(rec, EventKind.TEST_REPORTED), 1)


def test_unknown_test_name_raises_before_any_body() raises:
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.paths.append("tests/test_matrix.mojo::test_nope")

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    with assert_raises(contains="unknown test"):
        _ = run_session(cfg, root, comp)


def test_empty_final_selection_exits_5() raises:
    var root = temp_root()
    write_file(root, "tests/test_matrix.mojo", SRC_MATRIX)
    var cfg = base_config()
    cfg.paths.append("tests/test_matrix.mojo")
    cfg.keyword = "no_such_test_zzz"

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 5, "every test deselected -> nothing ran -> exit 5")
    ref rec = comp.composite.reporters[0]
    # No per-test row was reported; all three tests were deselected.
    assert_equal(_count_kind(rec, EventKind.TEST_REPORTED), 0)
    var last = rec.event_at(rec.count() - 1)
    assert_equal(last.data[SessionFinishedPayload].test_counts.deselected, 3)


def test_selected_failing_test_reports_fail() raises:
    var root = temp_root()
    write_file(root, "tests/test_mf.mojo", SRC_MATRIX_FAIL)
    var cfg = base_config()
    cfg.paths.append("tests/test_mf.mojo::test_bad")

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1, "a selected failing test -> exit 1")
    ref rec = comp.composite.reporters[0]
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

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    # The stale-name path is MALFORMED-SUITE (exit-1 class), NEVER exit 3.
    assert_equal(code, 1, "a chameleon suite is MALFORMED-SUITE, exit 1")
    ref rec = comp.composite.reporters[0]
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
            and rec.event_at(i).data[WarningPayload].warning_kind
            == "stale-name"
        ):
            saw_stale = True
    assert_true(saw_stale, "the recover-once flow must warn loudly")


def test_recovery_probe_crash_still_reaches_crash_attribution() raises:
    # Recover-once fires, the rebuild succeeds, and the re-probe dies by signal.
    # That CRASH is a crash like any other: it must be handed to the bounded
    # attribution post-pass, or the pass sees an empty candidate list, never
    # announces itself, and the file's culprit is never named.
    var root = temp_root()
    write_file(root, "tests/test_probe_crash.mojo", SRC_CHAMELEON_PROBE_CRASH)
    var cfg = base_config()
    # Select only the ghost -> a subset run under --only -> the stale-name path.
    cfg.paths.append("tests/test_probe_crash.mojo")
    cfg.keyword = "ghost"

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    _ = run_session(cfg, root, comp)

    ref rec = comp.composite.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.outcome == Outcome.CRASH,
        "a recovery re-probe that dies by signal is a CRASH",
    )
    # Recovery really did fire -- otherwise this proves nothing about recovery.
    var saw_stale = False
    for i in range(rec.count()):
        if (
            rec.kind_at(i) == EventKind.WARNING
            and rec.event_at(i).data[WarningPayload].warning_kind
            == "stale-name"
        ):
            saw_stale = True
    assert_true(saw_stale, "the run must have gone through recover-once")
    # The guard: the attribution pass announces itself only when it was handed
    # at least one crashed file. Drop the file and this warning vanishes.
    var saw_attribution = False
    for i in range(rec.count()):
        if (
            rec.kind_at(i) == EventKind.WARNING
            and rec.event_at(i).data[WarningPayload].warning_kind
            == "crash-attribution-start"
        ):
            saw_attribution = True
    assert_true(
        saw_attribution,
        "a recovery-probe CRASH must reach the crash-attribution pass",
    )


def test_last_failed_recovery_keeps_the_soft_selection() raises:
    var root = temp_root()
    write_file(root, "tests/test_lf_recovery.mojo", SRC_CHAMELEON)
    var cfg = base_config()
    cfg.paths.append("tests/test_lf_recovery.mojo")
    cfg.last_failed = True
    var state = LastRunState(
        [
            LastRunRecord.test(
                NodeId("tests/test_lf_recovery.mojo", "test_ghost")
            )
        ]
    )
    var resolved = _resolved_state(cfg, state)
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    _ = run_session(resolved, root, comp)

    var finished = _finished(comp.composite.reporters[0])
    assert_equal(
        finished.deselected_tests,
        1,
        "stale recovery must retain only the effective --lf test",
    )


def test_retry_then_recovery_build_terminal_reports_attempt_two() raises:
    var root = temp_root()
    write_file(
        root,
        "tests/test_retry_recovery_build.mojo",
        _SRC_RETRY_THEN_STALE_BUILD_ERROR,
    )
    var cfg = base_config()
    cfg.timeout_secs = 10
    cfg.retries = 1
    cfg.paths.append("tests/test_retry_recovery_build.mojo::test_ghost")

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1)
    _assert_retry_then_recovery_terminal(
        comp.composite.reporters[0], Outcome.COMPILE_ERROR
    )


def test_retry_then_recovery_probe_terminal_reports_attempt_two() raises:
    var root = temp_root()
    write_file(
        root,
        "tests/test_retry_recovery_probe.mojo",
        _SRC_RETRY_THEN_STALE_PROBE_CRASH,
    )
    var cfg = base_config()
    cfg.timeout_secs = 10
    cfg.retries = 1
    cfg.paths.append("tests/test_retry_recovery_probe.mojo::test_ghost")

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1)
    _assert_retry_then_recovery_terminal(
        comp.composite.reporters[0], Outcome.CRASH
    )


def test_recovery_crash_is_attributed_against_original_selection() raises:
    # The stale-name recovery re-probe RENAMES the universe: `-k old` first
    # selects test_old, the run is refused, and the rebuilt re-probe now lists
    # only test_new, so re-selecting `-k old` collapses to EMPTY. The recovery
    # run then executes a bare `--only` and dies by signal.
    #
    # A crash must be attributed against the run's ORIGINAL pre-recovery
    # selection [test_old], NOT the empty re-selection. [test_old] does not
    # intersect the renamed universe [test_new], so attribution finds no
    # candidate -> NO_REPRODUCTION, empty culprit, zero isolation reruns. Were
    # the crash record to store the empty re-selection instead, "empty" would
    # widen to the whole universe [test_new] and falsely name test_new -- a test
    # the run deselected and never invoked.
    var root = temp_root()
    write_file(root, "tests/test_rename_crash.mojo", SRC_CHAMELEON_RENAME_CRASH)
    var cfg = base_config()
    cfg.paths.append("tests/test_rename_crash.mojo")
    cfg.keyword = "old"

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    _ = run_session(cfg, root, comp)

    ref rec = comp.composite.reporters[0]
    # The recovery run really crashed -- otherwise this proves nothing.
    var finished = _finished(rec)
    assert_true(
        finished.outcome == Outcome.CRASH,
        "the recovery run under the renamed universe dies by signal",
    )
    # Recovery really fired: the loud stale-name warning was emitted.
    var saw_stale = False
    for i in range(rec.count()):
        if (
            rec.kind_at(i) == EventKind.WARNING
            and rec.event_at(i).data[WarningPayload].warning_kind
            == "stale-name"
        ):
            saw_stale = True
    assert_true(saw_stale, "the run must have gone through recover-once")
    # The load-bearing assertion: attribution used the ORIGINAL selection.
    var attr = _crash_attribution(rec)
    assert_true(
        attr.attribution_disposition == AttributionDisposition.NO_REPRODUCTION,
        (
            "attributing against the original [test_old] finds no candidate in"
            " the renamed universe: NO_REPRODUCTION, never a false ATTRIBUTED"
        ),
    )
    assert_equal(
        attr.culprit_test,
        "",
        "no culprit may be named -- test_new was deselected by `-k old`",
    )
    assert_equal(
        attr.isolation_reruns,
        0,
        "an empty candidate set performs zero isolation reruns",
    )


def test_selected_off_grammar_run_is_drift_exit_3() raises:
    # The probe (--skip-all) is a clean two-test collection, but the selected
    # --only RUN emits an off-grammar trailing Summary. Selection must preserve
    # the same distinction the default path does: an OFF_GRAMMAR run is DRIFT
    # (exit 3), NOT collapsed to MALFORMED_SUITE (exit 1).
    var root = temp_root()
    write_file(root, "tests/test_ol.mojo", SRC_ONLY_LIAR)
    var cfg = base_config()
    cfg.paths.append("tests/test_ol.mojo::test_one")

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 3, "a selected off-grammar run is DRIFT, exit 3")
    ref rec = comp.composite.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.parse_disposition == ParseDisposition.DRIFT,
        "an off-grammar selected run is DRIFT, not malformed-suite",
    )
    var saw_drift = False
    for i in range(rec.count()):
        if (
            rec.kind_at(i) == EventKind.WARNING
            and rec.event_at(i).data[WarningPayload].warning_kind == "drift"
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

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1, "a selected overflow run is exit-1 class")
    ref rec = comp.composite.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.parse_disposition == ParseDisposition.CAPTURE_OVERFLOW,
        "an overflowing selected run is CAPTURE_OVERFLOW",
    )
    var saw_overflow = False
    for i in range(rec.count()):
        if (
            rec.kind_at(i) == EventKind.WARNING
            and rec.event_at(i).data[WarningPayload].warning_kind
            == "capture-overflow"
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

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1, "a genuine FAIL resolves to exit 1")
    ref rec = comp.composite.reporters[0]
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
            and rec.event_at(i).data[WarningPayload].warning_kind
            == "stale-name"
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

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    with assert_raises(contains="malformed node id"):
        _ = run_session(cfg, root, comp)


def _warning_details(rec: RecordingReporter, kind: String) -> List[String]:
    """Every recorded warning detail carried under one warning kind.

    Args:
        rec: The recorder to read back.
        kind: The `warning_kind` tag to collect.

    Returns:
        The details, in emission order. Allocates the returned list.
    """
    var out = List[String]()
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.WARNING:
            ref w = rec.event_at(i).data[WarningPayload]
            if w.warning_kind == kind:
                out.append(w.warning_pattern.copy())
    return out^


def test_selection_run_losing_a_collected_test_is_malformed_suite() raises:
    # The probe lists three names; the selection run registers only two, so the
    # run's row set can never equal the collected set. That is a USER-controlled
    # suite disagreement, not machinery drift: MALFORMED-SUITE, exit 1, never
    # DRIFT/exit 3.
    var root = temp_root()
    write_file(root, "tests/test_shrink.mojo", _SRC_SHRINKING_UNIVERSE)
    var cfg = base_config()
    # Select a name the suite DOES still register, so the stdlib never refuses a
    # requested test and the stale-name recovery path is never entered.
    cfg.paths.append("tests/test_shrink.mojo::test_alpha")

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1, "a suite/selection disagreement is exit 1")
    ref rec = comp.composite.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.outcome == Outcome.MALFORMED_SUITE,
        "a run whose rows lost a collected test is MALFORMED_SUITE",
    )
    assert_true(
        finished.parse_disposition == ParseDisposition.NO_REPORT,
        "the reconciled run carries no trustworthy report",
    )
    assert_false(
        finished.parse_disposition == ParseDisposition.DRIFT,
        "user suite disagreement is never DRIFT",
    )
    # The exact disagreement diagnostic, and only it.
    var details = _warning_details(rec, "malformed-suite")
    assert_equal(len(details), 1)
    assert_equal(
        details[0],
        (
            "the selection run's tests did not match the collected set (a test"
            " appeared or vanished between collection and run)"
        ),
    )
    # No drift warning fired: the grammar was never violated.
    assert_equal(len(_warning_details(rec, "drift")), 0)
    var last = rec.event_at(rec.count() - 1)
    assert_true(last.kind == EventKind.SESSION_FINISHED)
    assert_equal(last.data[SessionFinishedPayload].exit_code, 1)


def test_deselected_test_reporting_pass_is_malformed_suite() raises:
    # The row set MATCHES the collected set, so membership reconciles; what
    # disagrees is the per-row selection contract — a deselected test must
    # report the selection-induced SKIP, never a real outcome. Still a user
    # suite disagreement: MALFORMED-SUITE, exit 1, never DRIFT/exit 3.
    var root = temp_root()
    write_file(root, "tests/test_deselected_ran.mojo", _SRC_DESELECTED_RAN)
    var cfg = base_config()
    cfg.paths.append("tests/test_deselected_ran.mojo::test_one")

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(cfg, root, comp)

    assert_equal(code, 1, "a deselected test that ran is exit 1")
    ref rec = comp.composite.reporters[0]
    var finished = _finished(rec)
    assert_true(
        finished.outcome == Outcome.MALFORMED_SUITE,
        "a deselected test reporting PASS is MALFORMED_SUITE",
    )
    assert_false(
        finished.parse_disposition == ParseDisposition.DRIFT,
        "user suite disagreement is never DRIFT",
    )
    var details = _warning_details(rec, "malformed-suite")
    assert_equal(len(details), 1)
    assert_equal(
        details[0],
        (
            "a deselected test ran under --only instead of reporting a"
            " selection-induced SKIP: test_two"
        ),
    )
    assert_equal(len(_warning_details(rec, "drift")), 0)
    var last = rec.event_at(rec.count() - 1)
    assert_true(last.kind == EventKind.SESSION_FINISHED)
    assert_equal(last.data[SessionFinishedPayload].exit_code, 1)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
