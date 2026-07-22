"""Capacity-N supervision: the Supervisor and its per-slot lifecycle.

Drives multiple children at once through one `Supervisor` and asserts the
supervision invariants that only surface at N: completions correlate by the
caller's opaque tag (never a recycled slot index); a slow or draining slot never
blocks a live sibling; each child's deadline is independent; the fixed
observation order (deadline before interrupt, second activation escalates) picks
the right kill cause; a spawn failure is isolated; `kill_all` and a mid-flight
poll fault both leave zero surviving process groups through the two-pass
protocol; fd use stays flat at the effective cap; and a recycled slot rejects its
stale token.
"""
from std.ffi import external_call
from std.os import listdir, remove, rmdir
from std.os.path import exists
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false
from std.time import perf_counter_ns, sleep

from mtest.exec import (
    Completion,
    ExecRuntime,
    KillCause,
    ProcessSpec,
    Supervisor,
    query_effective_cap,
    run_supervised,
)
from mtest.exec.signals import _reset_interrupt, _raise_self

from exec_helpers import bytes_to_str, count_byte, target, true_binary, py_spec
from tmptree import temp_root

comptime _SIGINT = 2
comptime _EIO = 5
comptime _OP_POLL_SET = 36
comptime _BYTE_O: UInt8 = 111
comptime _BYTE_E: UInt8 = 101


def _reset_faults():
    """Clear the isolated testing adapter's native fault table."""
    # SAFETY: this test-only ABI takes no pointer, retains nothing, and mutates
    # only the testing adapter's single-threaded fault configuration.
    external_call["mtest_exec_test_fault_reset", NoneType]()


def _configure_fault(operation: Int, error_number: Int) raises:
    """Fail the first occurrence of one native adapter operation."""
    # SAFETY: the test-only ABI takes scalar discriminators only; both are exact
    # enum/errno constants and no pointer or state escapes the call.
    var result = external_call["mtest_exec_test_fault_configure", Int32](
        UInt32(operation), UInt32(1), Int32(error_number), Int64(0)
    )
    assert_equal(result, Int32(0), "could not configure native fault")


def _collect(mut supervisor: Supervisor, count: Int) raises -> List[Completion]:
    """Pump `wait_any` until `count` slots have finalized; return in tag order.
    """
    var out = List[Completion]()
    var guard = 0
    while len(out) < count and guard < 200000:
        guard += 1
        var completed = supervisor.wait_any(20)
        if completed:
            out.append(completed.take())
    assert_equal(len(out), count, "not every child finalized in time")
    return out^


def test_two_children_complete_and_correlate_by_tag() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var supervisor = Supervisor(2)
    _ = supervisor.spawn(ProcessSpec.command([true_binary()]), 11)
    _ = supervisor.spawn(ProcessSpec.command([true_binary()]), 22)
    var comps = _collect(supervisor, 2)
    assert_equal(supervisor.in_flight(), 0)
    runtime.close()

    var seen11 = False
    var seen22 = False
    for i in range(len(comps)):
        if comps[i].tag == 11:
            seen11 = True
        elif comps[i].tag == 22:
            seen22 = True
        assert_true(
            comps[i].result.termination.is_exited(),
            String(comps[i].result.termination),
        )
        assert_false(Bool(comps[i].kill_cause), "clean exit has no kill cause")
    assert_true(seen11 and seen22, "both tags must come back exactly once")


def test_slow_sibling_does_not_block_a_fast_completion() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var supervisor = Supervisor(2)
    # A sleeper with no deadline stays in flight; the quick child must finalize
    # first rather than waiting behind the slow slot's drain.
    _ = supervisor.spawn(py_spec([target("sleeper.py")], 0), 1)
    _ = supervisor.spawn(ProcessSpec.command([true_binary()]), 2)
    var first_tag = -1
    var guard = 0
    while guard < 200000:
        guard += 1
        var completed = supervisor.wait_any(20)
        if completed:
            first_tag = completed.take().tag
            break
    assert_equal(
        first_tag, 2, "the fast child must finalize before the sleeper"
    )
    assert_equal(supervisor.in_flight(), 1)
    supervisor.kill_all()
    assert_equal(supervisor.in_flight(), 0)
    runtime.close()


def test_per_child_deadline_is_independent() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var supervisor = Supervisor(2)
    _ = supervisor.spawn(py_spec([target("sleeper.py")], 120), 1)
    _ = supervisor.spawn(ProcessSpec.command([true_binary()]), 2)
    var comps = _collect(supervisor, 2)
    runtime.close()

    for i in range(len(comps)):
        if comps[i].tag == 1:
            assert_true(
                comps[i].result.termination.is_timed_out(),
                String(comps[i].result.termination),
            )
            assert_true(Bool(comps[i].kill_cause), "deadline latches a cause")
            assert_true(comps[i].kill_cause.value().is_deadline())
        else:
            assert_true(
                comps[i].result.termination.is_exited(),
                String(comps[i].result.termination),
            )
            assert_false(Bool(comps[i].kill_cause))


def test_noisy_child_beside_a_timeout_child() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var supervisor = Supervisor(2)
    # The flooder's concurrent drain must not stop the sleeper from being killed
    # on time, nor the sleeper's kill starve the flooder's byte-exact capture.
    _ = supervisor.spawn(py_spec([target("dual_flooder.py")], 0), 1)
    _ = supervisor.spawn(py_spec([target("sleeper.py")], 120), 2)
    var comps = _collect(supervisor, 2)
    runtime.close()

    for i in range(len(comps)):
        if comps[i].tag == 1:
            assert_true(
                comps[i].result.termination.is_exited(),
                String(comps[i].result.termination),
            )
            assert_equal(comps[i].result.termination.value, 0)
            assert_equal(
                count_byte(comps[i].result.stdout_bytes, _BYTE_O), 262144
            )
            assert_equal(
                count_byte(comps[i].result.stderr_bytes, _BYTE_E), 262144
            )
            assert_false(comps[i].result.stdout_truncated)
        else:
            assert_true(
                comps[i].result.termination.is_timed_out(),
                String(comps[i].result.termination),
            )
            assert_true(comps[i].kill_cause.value().is_deadline())


def test_flooders_at_n3_are_byte_exact() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var supervisor = Supervisor(3)
    for tag in range(3):
        _ = supervisor.spawn(py_spec([target("dual_flooder.py")], 0), tag)
    var comps = _collect(supervisor, 3)
    assert_equal(supervisor.in_flight(), 0)
    runtime.close()

    for i in range(len(comps)):
        assert_true(
            comps[i].result.termination.is_exited(),
            String(comps[i].result.termination),
        )
        assert_equal(count_byte(comps[i].result.stdout_bytes, _BYTE_O), 262144)
        assert_equal(count_byte(comps[i].result.stderr_bytes, _BYTE_E), 262144)
        assert_false(
            comps[i].result.stdout_truncated, "no drop under the bound"
        )
        assert_false(comps[i].result.stderr_truncated)


def test_flooders_under_the_sweep_budget_are_fair() raises:
    # More ready channels than one sweep's byte budget, so the rotating cursor
    # must revisit every slot across sweeps: none is starved and all capture
    # byte-exact.
    var runtime = ExecRuntime()
    runtime.open()
    var supervisor = Supervisor(8)
    for tag in range(8):
        _ = supervisor.spawn(py_spec([target("dual_flooder.py")], 0), tag)
    var comps = _collect(supervisor, 8)
    assert_equal(supervisor.in_flight(), 0)
    runtime.close()

    for i in range(len(comps)):
        assert_true(
            comps[i].result.termination.is_exited(),
            String(comps[i].result.termination),
        )
        assert_equal(
            count_byte(comps[i].result.stdout_bytes, _BYTE_O),
            262144,
            "a starved slot would be short of its bytes",
        )
        assert_equal(count_byte(comps[i].result.stderr_bytes, _BYTE_E), 262144)


def test_capacity_and_fd_hygiene_at_the_effective_cap() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var cap = query_effective_cap()
    assert_true(cap >= 1 and cap <= 64, String(cap))
    var supervisor = Supervisor(cap)

    # Warm up one full generation so any one-time mappings already exist.
    for tag in range(cap):
        _ = supervisor.spawn(ProcessSpec.command([true_binary()]), tag)
    var warm = _collect(supervisor, cap)
    assert_equal(len(warm), cap)

    var before = _open_fd_count()
    for _ in range(2):
        for tag in range(cap):
            _ = supervisor.spawn(ProcessSpec.command([true_binary()]), tag)
        var comps = _collect(supervisor, cap)
        assert_equal(len(comps), cap)
        for i in range(len(comps)):
            assert_true(comps[i].result.termination.is_exited())
    var after = _open_fd_count()
    assert_equal(supervisor.in_flight(), 0)
    runtime.close()
    assert_true(
        after <= before,
        String("fd leak at cap: before=")
        + String(before)
        + " after="
        + String(after),
    )


def test_deadline_before_interrupt_latches_the_deadline() raises:
    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    var supervisor = Supervisor(1)
    _ = supervisor.spawn(py_spec([target("sleeper.py")], 5), 1)
    # Let the 5 ms deadline pass, then set the interrupt: within the sweep the
    # deadline is observed FIRST, so the latched cause is DEADLINE, not INTERRUPT.
    sleep(0.05)
    _raise_self(_SIGINT)
    var comps = _collect(supervisor, 1)
    _reset_interrupt()
    runtime.close()
    assert_true(
        comps[0].result.termination.is_timed_out(),
        String(comps[0].result.termination),
    )
    assert_true(comps[0].kill_cause.value().is_deadline(), "deadline must win")


def test_interrupt_before_deadline_latches_the_interrupt() raises:
    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    var supervisor = Supervisor(1)
    # No deadline at all: the only kill cause available is the interrupt.
    _ = supervisor.spawn(py_spec([target("sleeper.py")], 0), 1)
    _raise_self(_SIGINT)
    var comps = _collect(supervisor, 1)
    _reset_interrupt()
    runtime.close()
    assert_true(
        comps[0].result.termination.is_timed_out(),
        String(comps[0].result.termination),
    )
    assert_true(comps[0].kill_cause.value().is_interrupt())


def test_second_activation_escalates_to_sigkill() raises:
    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    var supervisor = Supervisor(1)
    _ = supervisor.spawn(py_spec([target("sleeper.py")], 0), 1)
    # Two observed activations: the live group is SIGKILLed at once, skipping the
    # SIGTERM grace, so the recorded death escalated.
    _raise_self(_SIGINT)
    _raise_self(_SIGINT)
    var comps = _collect(supervisor, 1)
    _reset_interrupt()
    runtime.close()
    assert_true(
        comps[0].result.termination.is_timed_out(),
        String(comps[0].result.termination),
    )
    assert_true(comps[0].result.termination.escalated, "escalate-to-kill")
    assert_true(comps[0].kill_cause.value().is_interrupt())


def test_spawn_failure_isolated_from_a_healthy_sibling() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var supervisor = Supervisor(2)
    _ = supervisor.spawn(
        ProcessSpec.command(["/nonexistent/mtest_missing_binary"]), 1
    )
    _ = supervisor.spawn(ProcessSpec.command([true_binary()]), 2)
    var comps = _collect(supervisor, 2)
    assert_equal(supervisor.in_flight(), 0)
    runtime.close()

    for i in range(len(comps)):
        if comps[i].tag == 1:
            assert_true(
                comps[i].result.termination.is_spawn_failed(),
                String(comps[i].result.termination),
            )
            assert_equal(len(comps[i].result.stdout_bytes), 0)
        else:
            assert_true(
                comps[i].result.termination.is_exited(),
                String(comps[i].result.termination),
            )


def test_kill_all_sweeps_grandchildren_leaving_zero_survivors() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var scratch = temp_root()
    var supervisor = Supervisor(3)
    var sentinels = List[String]()
    for tag in range(3):
        var path = (
            scratch
            + "/killall-"
            + String(tag)
            + "-"
            + String(perf_counter_ns())
        )
        sentinels.append(path)
        _ = supervisor.spawn(
            py_spec([target("grandchild_spawner.py"), path], 0), tag
        )
    # Let every child exec python and fork its grandchild into the group.
    for _ in range(8):
        _ = supervisor.wait_any(40)
    supervisor.kill_all()
    assert_equal(supervisor.in_flight(), 0)
    runtime.close()

    # Past the grandchildren's 2 s survival window: the group sweep reached them.
    sleep(2.4)
    var survivors = 0
    for i in range(len(sentinels)):
        if exists(sentinels[i]):
            survivors += 1
            remove(sentinels[i])
    rmdir(scratch)
    assert_equal(survivors, 0, "a grandchild survived kill_all's group sweep")


def test_poll_fault_two_pass_leaves_zero_survivors() raises:
    var runtime = ExecRuntime()
    runtime.open()
    _reset_faults()
    var scratch = temp_root()
    var supervisor = Supervisor(3)
    var sentinels = List[String]()
    for tag in range(3):
        var path = (
            scratch
            + "/pollfault-"
            + String(tag)
            + "-"
            + String(perf_counter_ns())
        )
        sentinels.append(path)
        _ = supervisor.spawn(
            py_spec([target("grandchild_spawner.py"), path], 0), tag
        )
    # Let the group establish, then fault the shared multiplex mid-flight.
    for _ in range(8):
        _ = supervisor.wait_any(40)
    _configure_fault(_OP_POLL_SET, _EIO)
    var message = String("")
    try:
        _ = supervisor.wait_any(40)
    except e:
        message = String(e)
    _reset_faults()
    assert_equal(supervisor.in_flight(), 0)
    runtime.close()

    assert_true(
        "exec: poll set failed" in message,
        "the primary poll-set fault must be preserved: " + message,
    )
    sleep(2.4)
    var survivors = 0
    for i in range(len(sentinels)):
        if exists(sentinels[i]):
            survivors += 1
            remove(sentinels[i])
    rmdir(scratch)
    assert_equal(survivors, 0, "a group survived the two-pass cleanup")


def test_slot_reuse_rejects_a_stale_token() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var supervisor = Supervisor(1)
    var first = supervisor.spawn(ProcessSpec.command([true_binary()]), 1)
    _ = _collect(supervisor, 1)
    assert_false(supervisor.slot_is_live(first), "a finalized token is dead")

    var second = supervisor.spawn(ProcessSpec.command([true_binary()]), 2)
    assert_equal(first.index, second.index, "the slot is recycled")
    assert_true(first.generation != second.generation, "generations differ")
    assert_true(supervisor.slot_is_live(second), "the fresh token is live")
    assert_false(
        supervisor.slot_is_live(first), "the stale token stays rejected"
    )
    _ = _collect(supervisor, 1)
    runtime.close()


def test_leaked_grandchild_pipe_finalizes_within_the_window() raises:
    var runtime = ExecRuntime()
    runtime.open()
    var scratch = temp_root()
    var control = scratch + "/leaked-" + String(perf_counter_ns())
    var supervisor = Supervisor(2)
    _ = supervisor.spawn(
        py_spec([target("escaped_pipe_holder.py"), "spawn", control], 0), 1
    )
    _ = supervisor.spawn(ProcessSpec.command([true_binary()]), 2)

    var got_true = False
    var message = String("")
    var started_ns = perf_counter_ns()
    var guard = 0
    while guard < 200000:
        guard += 1
        try:
            var completed = supervisor.wait_any(20)
            if completed:
                var comp = completed.take()
                if comp.tag == 2:
                    got_true = True
                    assert_true(comp.result.termination.is_exited())
        except e:
            message = String(e)
            break
    var elapsed_ms = (perf_counter_ns() - started_ns) // 1_000_000

    # Cooperatively shut the escapee down; it self-expires regardless.
    var cleanup = run_supervised(
        runtime,
        py_spec([target("escaped_pipe_holder.py"), "cleanup", control], 6000),
    )
    runtime.close()

    var ready_path = control + ".ready"
    var stop_path = control + ".stop"
    if exists(ready_path):
        remove(ready_path)
    if exists(stop_path):
        remove(stop_path)
    rmdir(scratch)

    assert_true(got_true, "the live sibling finalized while the leak drained")
    assert_equal(
        message,
        "exec: descendant retained a capture pipe past the cleanup deadline",
    )
    assert_true(elapsed_ms < 5000, String(elapsed_ms))
    assert_true(cleanup.termination.is_exited(), String(cleanup.termination))


def _open_fd_count() raises -> Int:
    """Count open fds through the target platform's descriptor directory."""
    var n = 0
    comptime if CompilationTarget.is_macos():
        for _ in listdir("/dev/fd"):
            n += 1
    else:
        for _ in listdir("/proc/self/fd"):
            n += 1
    return n
