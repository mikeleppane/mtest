"""Table tests for the PURE selection pipeline kernel (Layer 4).

`RunPipeline` holds where every run file sits between discovery and a verdict
and answers one question — which step the run wants performed now. It spawns
nothing and emits nothing, so every transition is pinned here with synthesized
completions: no processes, no filesystem, exactly as `test_session_retry_class`
and `test_session_verdict` pin their policies.

Every stage, every step kind, and every halt reason in the vocabulary is reached
by some case below, because the sequential driver reaches all of them today.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.session import (
    FileStage,
    PipelineHalt,
    RunPipeline,
    StepKind,
    StepRequest,
)


def _plain(file_count: Int) -> RunPipeline:
    """A pipeline with no retries and no early-stop limit."""
    return RunPipeline(file_count, 0, False, 0)


def _expect(
    step: StepRequest, kind: StepKind, index: Int, attempt: Int = 0
) raises:
    """Assert a step request's kind, file index, and attempt together."""
    assert_equal(step.kind.code, kind.code)
    assert_equal(step.file_index, index)
    assert_equal(step.attempt, attempt)


def _collect_one(mut p: RunPipeline, index: Int, selection_empty: Bool = False):
    """Drive one file through the collection pass: build, then probe."""
    p.record_build_ready(index)
    p.record_probe_qualified(index, selection_empty)


# --- the front half: build then probe, in discovery order -------------------


def test_a_fresh_pipeline_wants_the_first_file_built() raises:
    """Every admitted file starts at NEEDS_BUILD; file 0 is asked for first."""
    var p = _plain(2)
    assert_equal(p.stage_of(0).code, FileStage.NEEDS_BUILD.code)
    assert_equal(p.stage_of(1).code, FileStage.NEEDS_BUILD.code)
    _expect(p.next_step(), StepKind.BUILD_FILE, 0)


def test_a_built_file_is_probed_before_the_next_file_is_built() raises:
    """One file is carried build-then-probe before the next is touched."""
    var p = _plain(2)
    p.record_build_ready(0)
    assert_equal(p.stage_of(0).code, FileStage.NEEDS_PROBE.code)
    _expect(p.next_step(), StepKind.PROBE_FILE, 0)
    p.record_probe_qualified(0, False)
    assert_equal(p.stage_of(0).code, FileStage.COLLECTED.code)
    _expect(p.next_step(), StepKind.BUILD_FILE, 1)


def test_a_compile_error_collects_as_a_terminal_file() raises:
    """A build that produced a verdict is replayed in the run pass, in order."""
    var p = _plain(1)
    p.record_build_terminal(0)
    assert_equal(p.stage_of(0).code, FileStage.COLLECTED.code)
    _expect(p.next_step(), StepKind.ANNOUNCE_COLLECTION, -1)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.REPLAY_TERMINAL, 0)


def test_a_terminal_probe_collects_as_a_terminal_file() raises:
    """A probe crash/timeout/malformed suite replays like a compile error."""
    var p = _plain(1)
    p.record_build_ready(0)
    p.record_probe_terminal(0)
    assert_equal(p.stage_of(0).code, FileStage.COLLECTED.code)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.REPLAY_TERMINAL, 0)


# --- the collection barrier -------------------------------------------------


def test_no_file_runs_before_every_file_is_collected() raises:
    """The barrier is the two-pass structure: file 0 does not run while
    file 1 is still un-probed."""
    var p = _plain(2)
    _collect_one(p, 0)
    # File 0 is collected and runnable, but file 1 has not been built yet.
    _expect(p.next_step(), StepKind.BUILD_FILE, 1)
    p.record_build_ready(1)
    _expect(p.next_step(), StepKind.PROBE_FILE, 1)
    p.record_probe_qualified(1, False)
    # Only now is the collection announced, and only then does anything run.
    _expect(p.next_step(), StepKind.ANNOUNCE_COLLECTION, -1)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=1)


def test_the_collection_is_announced_exactly_once() raises:
    """Announcing passes the barrier; it is never requested a second time."""
    var p = _plain(1)
    _collect_one(p, 0)
    _expect(p.next_step(), StepKind.ANNOUNCE_COLLECTION, -1)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=1)
    p.record_verdict(0, False, 0)
    _expect(p.next_step(), StepKind.NOTHING, -1)


def test_an_empty_run_set_still_announces_its_collection() raises:
    """A run with no files publishes zero totals, then has nothing to do."""
    var p = _plain(0)
    _expect(p.next_step(), StepKind.ANNOUNCE_COLLECTION, -1)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.NOTHING, -1)


# --- the back half: replay, skip, run ---------------------------------------


def test_a_fully_deselected_file_is_accounted_but_never_run() raises:
    """An empty selection asks for SKIP_DESELECTED, never RUN_SELECTION."""
    var p = _plain(1)
    _collect_one(p, 0, selection_empty=True)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.SKIP_DESELECTED, 0)
    p.record_settled(0)
    assert_equal(p.stage_of(0).code, FileStage.FINISHED.code)
    _expect(p.next_step(), StepKind.NOTHING, -1)


def test_files_run_in_discovery_order() raises:
    """The run pass settles file 0 before it asks for file 1."""
    var p = _plain(2)
    _collect_one(p, 0)
    _collect_one(p, 1)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=1)
    p.record_verdict(0, False, 0)
    _expect(p.next_step(), StepKind.RUN_SELECTION, 1, attempt=1)
    p.record_verdict(1, False, 0)
    _expect(p.next_step(), StepKind.NOTHING, -1)


# --- stale-name recover-once ------------------------------------------------


def test_a_stale_name_buys_exactly_one_rebuild_and_reprobe() raises:
    """The first refusal rebuilds and re-probes, then runs again."""
    var p = _plain(1)
    _collect_one(p, 0)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=1)

    assert_true(p.admit_stale_name_recovery(0))
    assert_equal(p.stage_of(0).code, FileStage.NEEDS_REBUILD.code)
    var rebuild = p.next_step()
    _expect(rebuild, StepKind.BUILD_FILE, 0)
    assert_true(rebuild.recovering)

    p.record_build_ready(0)
    assert_equal(p.stage_of(0).code, FileStage.NEEDS_REPROBE.code)
    var reprobe = p.next_step()
    _expect(reprobe, StepKind.PROBE_FILE, 0)
    assert_true(reprobe.recovering)

    p.record_probe_qualified(0, False)
    assert_equal(p.stage_of(0).code, FileStage.NEEDS_RUN.code)
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=1)


def test_a_second_stale_name_refuses_the_budget() raises:
    """The chameleon: a second refusal is the driver's to settle."""
    var p = _plain(1)
    _collect_one(p, 0)
    p.record_collection_announced()
    assert_true(p.admit_stale_name_recovery(0))
    p.record_build_ready(0)
    p.record_probe_qualified(0, False)
    assert_false(p.admit_stale_name_recovery(0))


def test_a_recovery_reselect_that_empties_still_runs() raises:
    """A re-probe never re-derives SKIP_DESELECTED: the recovery run happens
    on whatever it reselected, exactly as the loop it replaces did."""
    var p = _plain(1)
    _collect_one(p, 0)
    p.record_collection_announced()
    assert_true(p.admit_stale_name_recovery(0))
    p.record_build_ready(0)
    p.record_probe_qualified(0, True)
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=1)


def test_a_recovery_build_that_fails_settles_the_file_immediately() raises:
    """A recovery-pass compile error is not re-collected: its verdict stream
    is already open, so the file finishes now."""
    var p = _plain(1)
    _collect_one(p, 0)
    p.record_collection_announced()
    assert_true(p.admit_stale_name_recovery(0))
    p.record_build_terminal(0)
    assert_equal(p.stage_of(0).code, FileStage.FINISHED.code)
    _expect(p.next_step(), StepKind.NOTHING, -1)


def test_a_recovery_probe_that_fails_settles_the_file_immediately() raises:
    """The same for a recovery-pass probe that produced a verdict."""
    var p = _plain(1)
    _collect_one(p, 0)
    p.record_collection_announced()
    assert_true(p.admit_stale_name_recovery(0))
    p.record_build_ready(0)
    p.record_probe_terminal(0)
    assert_equal(p.stage_of(0).code, FileStage.FINISHED.code)
    _expect(p.next_step(), StepKind.NOTHING, -1)


# --- crash-class retries ----------------------------------------------------


def test_no_retries_budget_refuses_the_first_crash_retry() raises:
    """`--retries 0` plans exactly one attempt."""
    var p = _plain(1)
    _collect_one(p, 0)
    p.record_collection_announced()
    assert_false(p.admit_crash_retry(0))


def test_retries_advance_the_attempt_counter_to_the_ceiling() raises:
    """`--retries 2` plans three attempts, then refuses the fourth."""
    var p = RunPipeline(1, 2, False, 0)
    _collect_one(p, 0)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=1)
    assert_true(p.admit_crash_retry(0))
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=2)
    assert_true(p.admit_crash_retry(0))
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=3)
    assert_false(p.admit_crash_retry(0))
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=3)


def test_a_retry_budget_is_per_file() raises:
    """One file's spent attempts never shorten another's."""
    var p = RunPipeline(2, 1, False, 0)
    _collect_one(p, 0)
    _collect_one(p, 1)
    p.record_collection_announced()
    assert_true(p.admit_crash_retry(0))
    assert_false(p.admit_crash_retry(0))
    p.record_verdict(0, False, 0)
    _expect(p.next_step(), StepKind.RUN_SELECTION, 1, attempt=1)
    assert_true(p.admit_crash_retry(1))


def test_the_two_recovery_budgets_are_independent() raises:
    """A spent stale-name recovery leaves the crash-retry budget intact."""
    var p = RunPipeline(1, 1, False, 0)
    _collect_one(p, 0)
    p.record_collection_announced()
    assert_true(p.admit_stale_name_recovery(0))
    p.record_build_ready(0)
    p.record_probe_qualified(0, False)
    assert_true(p.admit_crash_retry(0))
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=2)


# --- the stop policy --------------------------------------------------------


def test_exitfirst_halts_on_the_first_failing_verdict() raises:
    """`-x` stops scheduling; the remaining files are never asked for."""
    var p = RunPipeline(2, 0, True, 0)
    _collect_one(p, 0)
    _collect_one(p, 1)
    p.record_collection_announced()
    p.record_verdict(0, True, 1)
    assert_equal(p.halt().code, PipelineHalt.LIMIT_REACHED.code)
    _expect(p.next_step(), StepKind.NOTHING, -1)


def test_exitfirst_does_not_halt_on_a_passing_verdict() raises:
    """`-x` reacts to the file's own failing-class outcome, nothing else."""
    var p = RunPipeline(2, 0, True, 0)
    _collect_one(p, 0)
    _collect_one(p, 1)
    p.record_collection_announced()
    p.record_verdict(0, False, 0)
    assert_equal(p.halt().code, PipelineHalt.RUNNING.code)
    _expect(p.next_step(), StepKind.RUN_SELECTION, 1, attempt=1)


def test_maxfail_halts_when_the_failing_total_reaches_the_ceiling() raises:
    """`--maxfail 2` compares the driver's accumulated failing count."""
    var p = RunPipeline(3, 0, False, 2)
    _collect_one(p, 0)
    _collect_one(p, 1)
    _collect_one(p, 2)
    p.record_collection_announced()
    p.record_verdict(0, True, 1)
    assert_equal(p.halt().code, PipelineHalt.RUNNING.code)
    _expect(p.next_step(), StepKind.RUN_SELECTION, 1, attempt=1)
    p.record_verdict(1, True, 2)
    assert_equal(p.halt().code, PipelineHalt.LIMIT_REACHED.code)
    _expect(p.next_step(), StepKind.NOTHING, -1)


def test_maxfail_zero_never_halts() raises:
    """An unset `--maxfail` imposes no ceiling."""
    var p = RunPipeline(2, 0, False, 0)
    _collect_one(p, 0)
    _collect_one(p, 1)
    p.record_collection_announced()
    p.record_verdict(0, True, 99)
    assert_equal(p.halt().code, PipelineHalt.RUNNING.code)


def test_a_fully_deselected_file_moves_neither_limit() raises:
    """A file that never ran contributes nothing to `-x` or `--maxfail`."""
    var p = RunPipeline(2, 0, True, 1)
    _collect_one(p, 0, selection_empty=True)
    _collect_one(p, 1)
    p.record_collection_announced()
    p.record_settled(0)
    assert_equal(p.halt().code, PipelineHalt.RUNNING.code)
    _expect(p.next_step(), StepKind.RUN_SELECTION, 1, attempt=1)


def test_a_terminal_file_honors_the_early_stop_limits() raises:
    """A compile error is a failing verdict like any other under `-x`."""
    var p = RunPipeline(2, 0, True, 0)
    p.record_build_terminal(0)
    _collect_one(p, 1)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.REPLAY_TERMINAL, 0)
    p.record_verdict(0, True, 1)
    assert_equal(p.halt().code, PipelineHalt.LIMIT_REACHED.code)
    _expect(p.next_step(), StepKind.NOTHING, -1)


# --- the short-circuit halts ------------------------------------------------


def test_an_interrupt_during_collection_halts_before_announcing() raises:
    """An interrupt in the front half never publishes collection totals."""
    var p = _plain(2)
    p.record_build_ready(0)
    p.halt_interrupted()
    assert_equal(p.halt().code, PipelineHalt.INTERRUPTED.code)
    _expect(p.next_step(), StepKind.NOTHING, -1)


def test_an_interrupt_during_the_run_pass_halts_scheduling() raises:
    """An interrupt in the back half stops the remaining files."""
    var p = _plain(2)
    _collect_one(p, 0)
    _collect_one(p, 1)
    p.record_collection_announced()
    p.record_verdict(0, False, 0)
    p.halt_interrupted()
    _expect(p.next_step(), StepKind.NOTHING, -1)


def test_an_internal_error_halts_the_pipeline() raises:
    """A spawn or machinery failure stops scheduling and routes to exit 3."""
    var p = _plain(2)
    p.record_build_ready(0)
    p.halt_internal_error()
    assert_equal(p.halt().code, PipelineHalt.INTERNAL_ERROR.code)
    _expect(p.next_step(), StepKind.NOTHING, -1)


def test_next_step_is_pure() raises:
    """Asking twice without recording a completion answers identically."""
    var p = _plain(2)
    _collect_one(p, 0)
    _collect_one(p, 1)
    p.record_collection_announced()
    var first = p.next_step()
    var second = p.next_step()
    assert_equal(first.kind.code, second.kind.code)
    assert_equal(first.file_index, second.file_index)
    assert_equal(first.attempt, second.attempt)


# --- dispatch reservation (the pool's double-dispatch guard) -----------------


def test_a_dispatched_file_is_not_handed_out_again() raises:
    """Marking a file in flight makes the scheduler skip it, so a driver that
    fills more than one slot receives the next file rather than the same one."""
    var p = _plain(2)
    _collect_one(p, 0)
    _collect_one(p, 1)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=1)
    p.mark_in_flight(0)
    # File 0 is in flight; the scheduler moves on to file 1 rather than
    # re-offering file 0.
    _expect(p.next_step(), StepKind.RUN_SELECTION, 1, attempt=1)
    p.mark_in_flight(1)
    _expect(p.next_step(), StepKind.NOTHING, -1)


def test_folding_a_completion_releases_the_dispatch_reservation() raises:
    """A dispatched file that is folded back — here a crash-class retry — is no
    longer in flight, so the scheduler offers its next attempt."""
    var p = RunPipeline(1, 1, False, 0)
    _collect_one(p, 0)
    p.record_collection_announced()
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=1)
    p.mark_in_flight(0)
    _expect(p.next_step(), StepKind.NOTHING, -1)
    assert_true(p.admit_crash_retry(0))
    _expect(p.next_step(), StepKind.RUN_SELECTION, 0, attempt=2)


def test_a_latched_interrupt_survives_a_straggling_limit_verdict() raises:
    """A verdict folded after an interrupt latched never downgrades the halt to
    `LIMIT_REACHED` — the guard the pool relies on to keep exit 2 when a
    straggling `-x` failure drains against an already-interrupted run."""
    var p = RunPipeline(2, 0, True, 0)
    _collect_one(p, 0)
    _collect_one(p, 1)
    p.record_collection_announced()
    p.halt_interrupted()
    p.record_verdict(0, True, 1)
    assert_equal(p.halt().code, PipelineHalt.INTERRUPTED.code)
