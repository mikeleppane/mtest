"""The parallel scheduler at capacity two, driven by a direct `workers=2` config.

The CLI still refuses `-n`, so these tests set `config.workers` directly to
exercise the pool the flag will one day reach. They pin the pool's observable
behavior — every file settles with the right verdict, admission follows
discovery order, `--maxfail` and a failing gate stop scheduling, and a pending
interrupt resolves to exit 2 with the rest accounted NOT-RUN — and the
capacity-one equivalence: a `workers=1` run matches the sequential path exactly
and never stamps a `--num-threads` flag onto its build reproduce line.

PROGRESS events are ephemeral: they appear in the recording stream but carry no
verdict, so every count assertion here filters by event kind rather than by raw
stream position.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.exec import ExecRuntime, interrupt_requested
from mtest.exec.signals import _raise_self, _reset_interrupt
from mtest.model import (
    EventKind,
    FileFinishedPayload,
    Outcome,
    SessionFinishedPayload,
    SessionStartedPayload,
)
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_session

from session_fixtures import (
    SRC_CRASH,
    SRC_FAIL,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)

comptime _SIGINT = 2


def _recorder() -> RecordingCoordinator[RecordingReporter]:
    return RecordingCoordinator(CompositeReporter(Tuple(RecordingReporter())))


def test_pool_runs_every_file_to_a_passing_verdict() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    write_file(root, "tests/test_c.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2

    var comp = _recorder()
    var code = run_session(config, root, comp)

    assert_equal(code, 0)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.PASS), 3
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 0
    )
    # The resolved worker count rides SessionStarted.
    assert_equal(rec.event_at(0).data[SessionStartedPayload].workers, 2)


def test_pool_settles_mixed_outcomes() raises:
    var root = temp_root()
    write_file(root, "tests/test_a_pass.mojo", SRC_PASS)
    write_file(root, "tests/test_b_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_c_crash.mojo", SRC_CRASH)

    var config = base_config()
    config.workers = 2

    var comp = _recorder()
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.PASS), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL), 1
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.CRASH), 1
    )


def test_pool_admits_in_discovery_order() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    write_file(root, "tests/test_c.mojo", SRC_PASS)
    write_file(root, "tests/test_d.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2

    var comp = _recorder()
    _ = run_session(config, root, comp)

    ref rec = comp.composite.reporters[0]
    # The first two files STARTED — filled into the two slots before the first
    # wait — are the first two in discovery order.
    var started = List[String]()
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_STARTED:
            started.append(rec.path_at(i))
    assert_true(len(started) >= 2)
    assert_equal(started[0], "tests/test_a.mojo")
    assert_equal(started[1], "tests/test_b.mojo")


def test_pool_maxfail_stops_scheduling_the_remainder() raises:
    var root = temp_root()
    write_file(root, "tests/test_a_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_b_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_c_fail.mojo", SRC_FAIL)
    write_file(root, "tests/test_d_fail.mojo", SRC_FAIL)

    var config = base_config()
    config.workers = 2
    config.maxfail = 1

    var comp = _recorder()
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    # The two files past the capacity window are never scheduled: at least the
    # third and fourth in discovery order land NOT-RUN.
    assert_true(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN)
        >= 2,
        "the tail of the run must be NOT-RUN once --maxfail stops scheduling",
    )
    assert_true(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL) >= 1
    )


def test_pool_failing_gate_aborts_the_run() raises:
    var root = temp_root()
    write_file(root, "tests/test_gate.mojo", SRC_FAIL)
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    write_file(root, "tests/test_y.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2
    config.gates.append("tests/test_gate.mojo")

    var comp = _recorder()
    var code = run_session(config, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    # The gate failed; both run files fan out to NOT-RUN and never start.
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 2
    )
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_STARTED:
            assert_true(
                rec.path_at(i) == "tests/test_gate.mojo",
                "no run file may start after a failing gate aborts the batch",
            )


def test_pool_interrupt_before_files_is_exit_2_all_not_run() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    write_file(root, "tests/test_c.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2

    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    _raise_self(_SIGINT)
    assert_true(interrupt_requested(), "the flag must be set before the pool")

    var comp = _recorder()
    var code = run_session(runtime, config, root, comp)
    _reset_interrupt()
    runtime.close()

    assert_equal(code, 2, "a pending interrupt resolves the pool run to exit 2")
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(last.data[SessionFinishedPayload].exit_code, 2)
    # Every file is abandoned NOT-RUN, none mislabelled a TIMEOUT, and the
    # driver returns rather than wedging on a surviving group.
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 3
    )
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.TIMEOUT), 0
    )


def test_pool_second_interrupt_activation_still_exit_2() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2

    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    _raise_self(_SIGINT)
    _raise_self(_SIGINT)

    var comp = _recorder()
    var code = run_session(runtime, config, root, comp)
    _reset_interrupt()
    runtime.close()

    assert_equal(code, 2, "a second activation still resolves to exit 2")
    ref rec = comp.composite.reporters[0]
    var last = rec.event_at(rec.count() - 1)
    assert_equal(
        last.data[SessionFinishedPayload].summary.count_of(Outcome.NOT_RUN), 2
    )


def test_capacity_one_matches_the_sequential_path() raises:
    # workers=1 IS the sequential path: same verdicts, same exit code, and a
    # build reproduce line with no `--num-threads` flag.
    var root = temp_root()
    write_file(root, "tests/test_a_pass.mojo", SRC_PASS)
    write_file(root, "tests/test_b_fail.mojo", SRC_FAIL)

    var seq_config = base_config()
    seq_config.workers = 1
    var seq_comp = _recorder()
    var seq_code = run_session(seq_config, root, seq_comp)

    assert_equal(seq_code, 1)
    ref seq_rec = seq_comp.composite.reporters[0]
    var seq_last = seq_rec.event_at(seq_rec.count() - 1)
    assert_equal(
        seq_last.data[SessionFinishedPayload].summary.count_of(Outcome.PASS), 1
    )
    assert_equal(
        seq_last.data[SessionFinishedPayload].summary.count_of(Outcome.FAIL), 1
    )
    # No worker header and no thread flag on the sequential path.
    assert_equal(seq_rec.event_at(0).data[SessionStartedPayload].workers, 1)
    for i in range(seq_rec.count()):
        if seq_rec.kind_at(i) == EventKind.FILE_FINISHED:
            for a in seq_rec.event_at(i).data[FileFinishedPayload].build_argv:
                assert_true(
                    a != "--num-threads",
                    "workers=1 build argv must carry no --num-threads flag",
                )


def test_pool_reproduce_line_stays_clean_for_an_ordinary_verdict() raises:
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2

    var comp = _recorder()
    _ = run_session(config, root, comp)

    ref rec = comp.composite.reporters[0]
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_FINISHED:
            for a in rec.event_at(i).data[FileFinishedPayload].build_argv:
                assert_true(
                    a != "--num-threads",
                    "an ordinary verdict's reproduce line stays clean",
                )
