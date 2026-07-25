"""Capacity-N supervision: the Supervisor and its per-slot lifecycle.

Drives multiple children at once through one `Supervisor` and asserts the
supervision invariants that only surface at N: completions correlate by the
caller's opaque tag (never a recycled slot index); a slow or draining slot never
blocks a live sibling; each child's deadline is independent; the fixed
observation order (deadline before interrupt, second activation escalates) picks
the right kill cause; a spawn failure is isolated; `kill_all` and a mid-flight
poll fault both leave zero surviving process groups through the two-pass
protocol; fd use stays flat at the effective cap; a recycled slot rejects its
stale token; and one slot's capture overflow never reaches a sibling's bytes,
truncation flags, or termination.
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
comptime _BYTE_NEWLINE: UInt8 = 10
comptime _TAGGED_SIZE = 513
"""Bytes each overflowing actor writes per stream: over the 200-byte capture
bound by enough that the head, the marker, and the tail are all distinct."""
comptime _CAPTURE_BOUND = 200
comptime _HEAD_CAP = 100
comptime _TAIL_CAP = 100
comptime _MARKER_LEN = 66
"""Byte length of the spliced marker for 313 omitted bytes at limit 200: the
marker line is 62 characters but 64 bytes because the em dash is three bytes,
and the surrounding newlines bring it to 66."""
comptime _OVERFLOW_TAG = "tag10"
"""Fixture label for the tag-10 overflowing actor. Its length is chosen so the
token `tag10-out-` is ten bytes and the retained tail therefore starts at
`513 - 100 = 413`, which is NOT a multiple of ten: the retained head and tail
begin at different token phases and cannot degenerate into the same bytes."""


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


def _tagged_payload(tag: String, stream: String, size: Int) -> List[UInt8]:
    """The exact bytes `tagged_streams.py` writes for one tagged stream.

    Mirrors the fixture's rule so a test can name every retained byte: the
    token `<tag>-<stream>-` repeated, cut to `size - 1` bytes, then a newline.

    Args:
        tag: The actor label handed to the fixture.
        stream: The stream name, `out` or `err`.
        size: The total byte count the fixture was asked to write.

    Returns:
        The fixture's payload for that stream, in order.
    """
    var token = tag + "-" + stream + "-"
    var token_bytes = token.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while len(out) < size - 1:
        out.append(token_bytes[i % len(token_bytes)])
        i += 1
    out.append(_BYTE_NEWLINE)
    return out^


def _byte_range(b: List[UInt8], start: Int, end: Int) -> List[UInt8]:
    """A fresh copy of the bytes of `b` in `[start, end)`.

    Args:
        b: The captured bytes to read from.
        start: The inclusive first index.
        end: The exclusive last index.

    Returns:
        The requested bytes, in order.
    """
    var out = List[UInt8]()
    for i in range(start, end):
        out.append(b[i])
    return out^


def _pump_one(mut supervisor: Supervisor, mut out: List[Completion]) raises:
    """Pump `wait_any` until exactly one more slot finalizes into `out`.

    Args:
        supervisor: The Supervisor to pump.
        out: The completions collected so far, in arrival order; one is
            appended.

    Raises:
        Error: If no slot finalized within the pump budget.
    """
    var wanted = len(out) + 1
    var guard = 0
    while len(out) < wanted and guard < 200000:
        guard += 1
        var completed = supervisor.wait_any(20)
        if completed:
            out.append(completed.take())
    assert_equal(len(out), wanted, "no slot finalized within the pump budget")


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


def _truncation_marker() -> String:
    """The exact marker spliced into a 513-byte stream at a 200-byte bound."""
    return String(
        "\n[mtest: output truncated — 313 bytes omitted, limit 200 bytes]\n"
    )


def _assert_overflowed_stream(
    captured: List[UInt8], tag: String, stream: String
) raises:
    """Assert one overflowed stream is exactly its own head, marker, and tail.

    Args:
        captured: The bytes the Supervisor retained for that stream.
        tag: The actor label that owns those bytes.
        stream: The stream name, `out` or `err`.

    Raises:
        Error: On any byte, length, or marker mismatch.
    """
    var payload = _tagged_payload(tag, stream, _TAGGED_SIZE)
    var expected_head = bytes_to_str(_byte_range(payload, 0, _HEAD_CAP))
    var expected_tail = bytes_to_str(
        _byte_range(payload, _TAGGED_SIZE - _TAIL_CAP, _TAGGED_SIZE)
    )
    # Guard on the chosen tag and size, not on the capture: were the two
    # retained windows equal, a capture that emitted the head twice would
    # satisfy both range comparisons below and prove nothing about the tail.
    assert_true(
        expected_head != expected_tail,
        "the retained head and tail must be distinguishable byte ranges",
    )
    assert_equal(
        len(captured),
        _HEAD_CAP + _MARKER_LEN + _TAIL_CAP,
        "retained length must be head + marker + tail",
    )
    assert_equal(
        bytes_to_str(_byte_range(captured, 0, _HEAD_CAP)),
        expected_head,
        "the retained head must be this actor's own leading bytes",
    )
    assert_equal(
        bytes_to_str(_byte_range(captured, _HEAD_CAP, _HEAD_CAP + _MARKER_LEN)),
        _truncation_marker(),
    )
    assert_equal(
        bytes_to_str(
            _byte_range(
                captured,
                _HEAD_CAP + _MARKER_LEN,
                _HEAD_CAP + _MARKER_LEN + _TAIL_CAP,
            )
        ),
        expected_tail,
        "the retained tail must be this actor's own trailing bytes",
    )


def test_pool_truncation_is_slot_local_out_of_completion_order() raises:
    # Tag 10 overflows both streams and is then held open on a file barrier, so
    # tag 20 must finalize FIRST, out of spawn order and while the overflowing
    # slot is still live. The neighbor's bytes, flags, and termination must be
    # untouched by the overflow next to it, and the overflow's own retained
    # bytes must be exactly its own head, marker, and tail.
    var runtime = ExecRuntime()
    runtime.open()
    var scratch = temp_root()
    var ready = scratch + "/tagged-" + String(perf_counter_ns()) + ".ready"
    var release = scratch + "/tagged-" + String(perf_counter_ns()) + ".release"
    var supervisor = Supervisor(2, _CAPTURE_BOUND)
    _ = supervisor.spawn(
        py_spec(
            [
                target("tagged_streams.py"),
                _OVERFLOW_TAG,
                String(_TAGGED_SIZE),
                String(_TAGGED_SIZE),
                ready,
                release,
            ],
            0,
        ),
        10,
    )
    # Tag 10 creates its ready marker only after BOTH payloads are written, so
    # draining until the marker exists makes "the overflow is already in the
    # pipes" a precondition of the neighbor's run rather than something observed
    # afterwards. Without it the neighbor could finalize before tag 10 pushed
    # past the bound, and a mutation that copies a sibling's truncation flag
    # would copy a False and escape.
    var guard = 0
    while guard < 200000 and not exists(ready):
        guard += 1
        _ = supervisor.wait_any(20)
    assert_true(exists(ready), "tag 10 never announced its payload")
    assert_equal(
        supervisor.in_flight(), 1, "the overflowing slot is still live"
    )

    _ = supervisor.spawn(
        py_spec([target("tagged_streams.py"), "neighbor", "13", "13"], 0), 20
    )
    var comps = List[Completion]()
    _pump_one(supervisor, comps)
    assert_equal(
        supervisor.in_flight(), 1, "only the barriered slot may remain"
    )
    with open(release, "w") as handle:
        handle.write("release\n")
    _pump_one(supervisor, comps)
    assert_equal(supervisor.in_flight(), 0)
    runtime.close()
    remove(ready)
    remove(release)
    rmdir(scratch)

    assert_equal(comps[0].tag, 20, "the neighbor finalizes first")
    assert_equal(
        comps[1].tag, 10, "the held overflowing actor finalizes second"
    )

    assert_equal(bytes_to_str(comps[0].result.stdout_bytes), "neighbor-out\n")
    assert_equal(bytes_to_str(comps[0].result.stderr_bytes), "neighbor-err\n")
    assert_false(
        comps[0].result.stdout_truncated, "the neighbor never overflowed"
    )
    assert_false(comps[0].result.stderr_truncated)
    assert_true(
        comps[0].result.termination.is_exited(),
        String(comps[0].result.termination),
    )
    assert_equal(comps[0].result.termination.value, 0)

    assert_true(comps[1].result.stdout_truncated, "513 bytes over a 200 bound")
    assert_true(comps[1].result.stderr_truncated)
    _assert_overflowed_stream(
        comps[1].result.stdout_bytes, _OVERFLOW_TAG, "out"
    )
    _assert_overflowed_stream(
        comps[1].result.stderr_bytes, _OVERFLOW_TAG, "err"
    )
    assert_true(
        comps[1].result.termination.is_exited(),
        String(comps[1].result.termination),
    )
    assert_equal(comps[1].result.termination.value, 0)


def test_pool_overflow_and_deadline_kill_finish_without_cross_slot_bytes() raises:
    # An overflowing slot beside a slot the deadline kills: the kill must not
    # borrow the overflow's bytes or flags, and the overflow must not inherit
    # the killed slot's ending. Neither slot's streams may carry the other's tag.
    var runtime = ExecRuntime()
    runtime.open()
    var supervisor = Supervisor(2, _CAPTURE_BOUND)
    _ = supervisor.spawn(
        py_spec(
            [
                target("tagged_streams.py"),
                "spill",
                String(_TAGGED_SIZE),
                String(_TAGGED_SIZE),
            ],
            0,
        ),
        1,
    )
    _ = supervisor.spawn(py_spec([target("sleeper.py")], 100), 2)
    var comps = _collect(supervisor, 2)
    assert_equal(supervisor.in_flight(), 0)
    runtime.close()

    for i in range(len(comps)):
        if comps[i].tag == 1:
            assert_true(
                comps[i].result.termination.is_exited(),
                String(comps[i].result.termination),
            )
            assert_equal(comps[i].result.termination.value, 0)
            assert_true(comps[i].result.stdout_truncated)
            assert_true(comps[i].result.stderr_truncated)
            _assert_overflowed_stream(
                comps[i].result.stdout_bytes, "spill", "out"
            )
            _assert_overflowed_stream(
                comps[i].result.stderr_bytes, "spill", "err"
            )
        else:
            assert_true(
                comps[i].result.termination.is_timed_out(),
                String(comps[i].result.termination),
            )
            assert_true(comps[i].kill_cause.value().is_deadline())
            # The sleeper writes nothing, so exact emptiness is the strongest
            # statement that no byte of the overflowing sibling reached it.
            assert_equal(len(comps[i].result.stdout_bytes), 0)
            assert_equal(len(comps[i].result.stderr_bytes), 0)
            assert_false(comps[i].result.stdout_truncated)
            assert_false(comps[i].result.stderr_truncated)


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
