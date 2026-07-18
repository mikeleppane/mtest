"""Portable subprocess supervision over the private native exec adapter (L3).

`run_supervised` is the one blocking entry point. Mojo owns only the typed
process contract and bounded captures; the C17 adapter owns platform headers,
PATH planning, pipes, fork/exec, polling, process groups, and wait status. This
keeps Linux and macOS ABI details out of Mojo while preserving the distinctions
the product sells: exit versus signal, spawn failure versus exit 127, and an
mtest deadline/interrupt kill versus the child's underlying final status.
"""
from std.ffi import external_call
from std.memory import UnsafePointer, alloc, memset_zero

from mtest.exec.capture import BoundedCapture
from mtest.exec.result import ProcessResult
from mtest.exec.signals import ExecRuntime, interrupt_requested
from mtest.exec.spec import DEFAULT_GRACE_MS, ProcessSpec
from mtest.exec.termination import Termination

comptime _BytePtr = UnsafePointer[UInt8, MutUntrackedOrigin]
comptime _U64Ptr = UnsafePointer[UInt64, MutUntrackedOrigin]

comptime _DEFAULT_CAP_BYTES = 8 * 1024 * 1024
"""Default per-stream capture bound: 8 MiB (head + tail)."""
comptime _POLL_SLICE_MS = 50
"""Maximum normal poll latency for deadline and interrupt checks."""
comptime _GRACE_MS = DEFAULT_GRACE_MS
"""Fallback grace between process-group SIGTERM and SIGKILL.

The deadline/interrupt escalation reads `spec.grace_ms` (which defaults to this
same value), so a caller can widen the grace for a child that needs longer to
die cleanly. This constant remains the grace for the machinery-error abort path,
where there is no spec in hand and nothing is mid-flight worth waiting on.
"""
comptime _POST_LEADER_MS = 300
"""Bound for group sweep and nonblocking drain after leader observation."""
comptime _POST_LEADER_SLICE_MS = 10
"""Short poll slice while waiting for swept pipes to reach EOF."""
comptime _BUFSIZE = 65536
"""One native read buffer, reused for both streams."""
comptime _MAX_DRAIN_CHUNKS = 16
"""Read cap per ready channel before yielding to lifecycle checks."""

comptime _CHANNEL_STDOUT: UInt32 = 1
comptime _CHANNEL_STDERR: UInt32 = 2
comptime _READY_STDOUT: UInt32 = 1
comptime _READY_STDERR: UInt32 = 2
comptime _READ_BYTES: UInt32 = 1
comptime _READ_EOF: UInt32 = 2
comptime _READ_WOULD_BLOCK: UInt32 = 3
comptime _SETUP_WAITING: UInt32 = 0
comptime _SETUP_EXEC_SUCCEEDED: UInt32 = 1
comptime _SETUP_SPAWN_FAILED: UInt32 = 2
comptime _SETUP_CORRUPT: UInt32 = 3
comptime _GROUP_TERM: UInt32 = 1
comptime _GROUP_KILL: UInt32 = 2
comptime _LEADER_WAITABLE: UInt32 = 1
comptime _REAP_EXITED: UInt32 = 1
comptime _REAP_SIGNALED: UInt32 = 2
comptime _PROCESS_HAS_CWD: UInt32 = 1


def _copy_c_string(value: String) -> _BytePtr:
    """Allocate an initialized NUL-terminated byte copy; caller owns it."""
    var length = value.byte_length()
    # SAFETY: the allocation owns `length + 1` UInt8 elements. Zeroing first
    # initializes every pointee and the terminator; each subsequent assignment
    # replaces one initialized byte with a byte read within `value`'s lifetime.
    var copied = alloc[UInt8](length + 1)
    memset_zero(copied, length + 1)
    for i in range(length):
        # SAFETY: `i` is in 0..<length for both the owned destination and the
        # borrowed String bytes; the borrow ends before `value` can move.
        copied[i] = value.unsafe_ptr()[i]
    return copied


struct _NativeBuffers(Movable):
    """Aligned storage for the exact native ABI-v1 records of one run."""

    var owned_strings: List[_BytePtr]
    var argv_records: _U64Ptr
    var spec_record: _U64Ptr
    var error: _U64Ptr
    var process_ref: _U64Ptr
    var milliseconds: UnsafePointer[Int64, MutUntrackedOrigin]
    var poll_result: UnsafePointer[UInt32, MutUntrackedOrigin]
    var read_result: _U64Ptr
    var setup_state: _U64Ptr
    var group_result: UnsafePointer[UInt32, MutUntrackedOrigin]
    var observe_result: UnsafePointer[UInt32, MutUntrackedOrigin]
    var reap_result: UnsafePointer[UInt32, MutUntrackedOrigin]
    var io_buffer: _BytePtr

    def __init__(out self, spec: ProcessSpec):
        """Allocate and initialize all records before the native process opens.

        The process-spec pointer fields borrow `spec` only for the synchronous
        `process_open` call. The adapter copies argv, cwd, and environment before
        returning and never retains a Mojo pointer.
        """
        self.owned_strings = List[_BytePtr]()
        # SAFETY: each allocation uses its record's required ABI-v1 alignment
        # (8 for pointer/64-bit records, 4 for 32-bit records). Counts cover the
        # complete fixed layouts asserted by the C header; every allocation has
        # this object as its sole owner and is freed in `__del__`.
        self.argv_records = alloc[UInt64](len(spec.argv) * 2)
        self.spec_record = alloc[UInt64](5)
        self.error = alloc[UInt64](4)
        self.process_ref = alloc[UInt64](2)
        self.milliseconds = alloc[Int64](1)
        self.poll_result = alloc[UInt32](2)
        self.read_result = alloc[UInt64](2)
        self.setup_state = alloc[UInt64](3)
        # SAFETY: these 4-byte-aligned UInt32 allocations exactly cover their
        # ABI-v1 records (8, 8, and 16 bytes); this object uniquely owns them.
        self.group_result = alloc[UInt32](2)
        self.observe_result = alloc[UInt32](2)
        self.reap_result = alloc[UInt32](4)
        # SAFETY: this object uniquely owns all `_BUFSIZE` UInt8 elements; C
        # writes at most the returned count and retains no pointer after a call.
        self.io_buffer = alloc[UInt8](_BUFSIZE)

        # SAFETY: zeroing covers every byte of every outbound/result record
        # before either Mojo or C reads it. UInt8 has no invalid bit patterns;
        # the I/O buffer is an out-buffer and is read only through returned count.
        memset_zero(self.argv_records.bitcast[UInt8](), len(spec.argv) * 16)
        memset_zero(self.spec_record.bitcast[UInt8](), 40)
        memset_zero(self.error.bitcast[UInt8](), 32)
        memset_zero(self.process_ref.bitcast[UInt8](), 16)
        memset_zero(self.milliseconds.bitcast[UInt8](), 8)
        memset_zero(self.poll_result.bitcast[UInt8](), 8)
        memset_zero(self.read_result.bitcast[UInt8](), 16)
        memset_zero(self.setup_state.bitcast[UInt8](), 24)
        # SAFETY: these aligned records own 8, 8, and 16 bytes respectively;
        # all-zero is valid for every UInt32 field and initializes every byte.
        memset_zero(self.group_result.bitcast[UInt8](), 8)
        memset_zero(self.observe_result.bitcast[UInt8](), 8)
        memset_zero(self.reap_result.bitcast[UInt8](), 16)

        for i in range(len(spec.argv)):
            var copied = _copy_c_string(spec.argv[i])
            self.owned_strings.append(copied)
            # SAFETY: `owned_strings` owns this initialized allocation until the
            # native open has copied exactly the recorded number of bytes.
            self.argv_records.bitcast[_BytePtr]()[i * 2] = copied
            self.argv_records[i * 2 + 1] = UInt64(spec.argv[i].byte_length())

        # SAFETY: the first ABI-v1 spec field is a non-retained pointer to the
        # complete 16-byte argv records above. Remaining scalar slots are exact
        # fixed-width fields; the final 64-bit slot was zeroed, so reserved=0.
        self.spec_record.bitcast[_U64Ptr]()[0] = self.argv_records
        self.spec_record[1] = UInt64(len(spec.argv))
        if spec.cwd:
            var copied = _copy_c_string(spec.cwd.value())
            self.owned_strings.append(copied)
            # SAFETY: `owned_strings` owns the complete initialized cwd copy
            # until the native open copies it and returns without retaining it.
            self.spec_record.bitcast[_BytePtr]()[2] = copied
            self.spec_record[3] = UInt64(spec.cwd.value().byte_length())
            # SAFETY: `spec_record` owns 40 initialized bytes aligned to 8; byte
            # offset 32 is the exact ABI-v1 UInt32 flags field and value 1 is valid.
            self.spec_record.bitcast[UInt32]()[8] = _PROCESS_HAS_CWD

    def __del__(deinit self):
        """Free every ABI record exactly once after native calls have returned.
        """
        # SAFETY: C never retains any string, record, or I/O pointer. This object
        # uniquely owns every allocation and deinitialization runs exactly once.
        for i in range(len(self.owned_strings)):
            # SAFETY: `i` is within the owning list; each entry is a distinct
            # C-string allocation that C did not retain and no path freed early.
            self.owned_strings[i].free()
        # SAFETY: C retained none of these aligned ABI-record pointers; this
        # object uniquely owns each allocation and frees each exactly once.
        self.argv_records.free()
        self.spec_record.free()
        self.error.free()
        self.process_ref.free()
        self.milliseconds.free()
        # SAFETY: C retained none of these record pointers; this object still
        # uniquely owns each allocation and deinitialization runs exactly once.
        self.poll_result.free()
        self.read_result.free()
        self.setup_state.free()
        self.group_result.free()
        self.observe_result.free()
        self.reap_result.free()
        # SAFETY: C retained no I/O pointer and this object uniquely owns the
        # `_BUFSIZE` allocation, which has not been freed on any other path.
        self.io_buffer.free()


def _native_error(prefix: String, error: _U64Ptr) -> String:
    """Render the adapter's fixed error record without discarding cleanup data.
    """
    # SAFETY: every failing ABI function initializes the complete aligned error
    # record. ABI-v1 fixes operation/errno at 0/4 and cleanup values at 8/12.
    var operation = Int(error.bitcast[UInt32]()[0])
    var error_number = Int(error.bitcast[Int32]()[1])
    var cleanup_operation = Int(error.bitcast[UInt32]()[2])
    var cleanup_error = Int(error.bitcast[Int32]()[3])
    var message = (
        prefix
        + " (operation "
        + String(operation)
        + ", errno "
        + String(error_number)
        + ")"
    )
    if cleanup_operation != 0:
        message += (
            "; cleanup operation "
            + String(cleanup_operation)
            + " failed with errno "
            + String(cleanup_error)
        )
    return message^


def _monotonic_ms(mut native: _NativeBuffers) raises -> Int:
    """Read the adapter's checked monotonic millisecond clock."""
    # SAFETY: both pointers address complete aligned ABI-v1 out records owned by
    # `native`; the call initializes them and retains neither pointer.
    var status = external_call["mtest_exec_monotonic_ms", Int32](
        native.milliseconds, native.error.bitcast[UInt8]()
    )
    if status != 0:
        raise Error(_native_error("exec: monotonic clock failed", native.error))
    # SAFETY: the successful call initialized the complete Int64 out-pointee.
    return Int(native.milliseconds[0])


def _process_open(mut native: _NativeBuffers) raises -> UInt64:
    """Open one native child and return its opaque generation-token handle."""
    # SAFETY: spec/process/error point to complete, aligned ABI-v1 records. All
    # borrowed spec strings remain alive for this synchronous call; C copies
    # them before fork/return and retains no Mojo pointer.
    var status = external_call["mtest_exec_process_open", Int32](
        native.spec_record.bitcast[UInt8](),
        native.process_ref.bitcast[UInt8](),
        native.error.bitcast[UInt8](),
    )
    if status != 0:
        raise Error(_native_error("exec: process open failed", native.error))
    # SAFETY: success initialized the complete 16-byte process-ref record; its
    # first eight bytes are the nonzero opaque handle, never a pointer address.
    return native.process_ref[0]


def _poll(
    handle: UInt64, timeout_ms: Int, mut native: _NativeBuffers
) raises -> UInt32:
    """Poll all still-owned native channels and return readiness bits."""
    # SAFETY: handle is the live opaque token; result/error are complete aligned
    # records owned by `native`, initialized by C and never retained.
    var status = external_call["mtest_exec_process_poll", Int32](
        handle,
        Int32(timeout_ms),
        native.poll_result,
        native.error.bitcast[UInt8](),
    )
    if status != 0:
        raise Error(_native_error("exec: poll failed", native.error))
    # SAFETY: successful poll initialized the full result; readiness is slot 0.
    return native.poll_result[0]


def _drain_channel(
    handle: UInt64,
    channel: UInt32,
    mut capture: BoundedCapture,
    mut native: _NativeBuffers,
) raises -> Bool:
    """Drain a ready channel without blocking; return True only at EOF."""
    for _ in range(_MAX_DRAIN_CHUNKS):
        # SAFETY: the live token names the sole active process; `io_buffer` owns
        # `_BUFSIZE` writable bytes and read-result/error are complete aligned
        # non-retained records. C rejects counts beyond the supplied capacity.
        var status = external_call["mtest_exec_process_read", Int32](
            handle,
            channel,
            native.io_buffer,
            UInt64(_BUFSIZE),
            native.read_result.bitcast[UInt8](),
            native.error.bitcast[UInt8](),
        )
        if status != 0:
            raise Error(
                _native_error("exec: channel read failed", native.error)
            )
        # SAFETY: success initialized the 16-byte result. State is bytes 0..3;
        # count is bytes 8..15 and is read only for READ_BYTES.
        var state = native.read_result.bitcast[UInt32]()[0]
        if state == _READ_EOF:
            return True
        if state == _READ_WOULD_BLOCK:
            return False
        if state != _READ_BYTES:
            raise Error("exec: native channel returned an invalid read state")
        var count = Int(native.read_result[1])
        if count < 0 or count > _BUFSIZE:
            raise Error("exec: native channel returned an invalid byte count")
        # SAFETY: C reported `count <= _BUFSIZE` bytes and initialized exactly
        # that prefix before returning; the buffer remains alive and unaliased.
        for i in range(count):
            capture.push_byte(native.io_buffer[i])
    return False


def _setup_drain(handle: UInt64, mut native: _NativeBuffers) raises -> UInt32:
    """Advance the persistent framed child-setup state without blocking."""
    # SAFETY: setup_state is the same initialized 24-byte record across calls so
    # partial frames persist. C validates its fields, retains no pointer, and
    # writes only within the ABI-v1 record; error is complete and aligned.
    var status = external_call["mtest_exec_process_setup_drain", Int32](
        handle,
        native.setup_state.bitcast[UInt8](),
        native.error.bitcast[UInt8](),
    )
    if status != 0:
        raise Error(_native_error("exec: setup channel failed", native.error))
    # SAFETY: outcome is the UInt32 at byte offset 12 in the validated record.
    return native.setup_state.bitcast[UInt32]()[3]


def _group(
    handle: UInt64, action: UInt32, mut native: _NativeBuffers
) raises -> UInt32:
    """Probe or signal the owned process group through the adapter."""
    # SAFETY: action is one of ABI-v1's three group discriminants; result/error
    # are full aligned non-retained records and handle is the live token.
    var status = external_call["mtest_exec_process_group", Int32](
        handle,
        action,
        native.group_result,
        native.error.bitcast[UInt8](),
    )
    if status != 0:
        raise Error(
            _native_error("exec: process-group action failed", native.error)
        )
    # SAFETY: C initialized the full result; state is its first UInt32.
    return native.group_result[0]


def _observe(handle: UInt64, mut native: _NativeBuffers) raises -> UInt32:
    """Observe leader waitability with waitid(WNOWAIT), without reaping."""
    # SAFETY: result/error are complete aligned non-retained records and handle
    # is the sole active process's opaque token.
    var status = external_call["mtest_exec_process_observe", Int32](
        handle,
        native.observe_result,
        native.error.bitcast[UInt8](),
    )
    if status != 0:
        raise Error(
            _native_error("exec: leader observation failed", native.error)
        )
    # SAFETY: C initialized the full result; state is its first UInt32.
    return native.observe_result[0]


def _close_channel(
    handle: UInt64, channel: UInt32, mut native: _NativeBuffers
) raises:
    """Explicitly close one retained native read channel."""
    # SAFETY: the action retains no pointer; error is a complete aligned record
    # and the live token/channel identify one adapter-owned descriptor.
    var status = external_call["mtest_exec_process_channel_close", Int32](
        handle, channel, native.error.bitcast[UInt8]()
    )
    if status != 0:
        raise Error(_native_error("exec: channel close failed", native.error))


def _reap(handle: UInt64, mut native: _NativeBuffers) raises -> Termination:
    """Reap the already-observed leader exactly once and decode C's result."""
    # SAFETY: waitid observation established waitability without consumption;
    # result/error are complete aligned non-retained ABI-v1 records.
    var status = external_call["mtest_exec_process_reap", Int32](
        handle,
        native.reap_result,
        native.error.bitcast[UInt8](),
    )
    if status != 0:
        raise Error(_native_error("exec: leader reap failed", native.error))
    # SAFETY: successful reap initialized the full 16-byte record. Kind is the
    # UInt32 at offset 4 and value the Int32 at offset 8.
    var kind = native.reap_result[1]
    # SAFETY: the 16-byte record is 4-byte aligned and C initialized its Int32
    # value field at byte offset 8 before returning success; the cast does not escape.
    var value = Int(native.reap_result.bitcast[Int32]()[2])
    if kind == _REAP_EXITED:
        return Termination.exited(value)
    if kind == _REAP_SIGNALED:
        return Termination.signaled(value)
    raise Error("exec: waitpid returned a non-terminal child status")


def _process_close(handle: UInt64, mut native: _NativeBuffers) raises:
    """Release a fully reaped, swept, channel-closed native process record."""
    # SAFETY: handle is the live token and error is a complete aligned record;
    # success consumes adapter ownership and retains no Mojo pointer.
    var status = external_call["mtest_exec_process_close", Int32](
        handle, native.error.bitcast[UInt8]()
    )
    if status != 0:
        raise Error(_native_error("exec: process close failed", native.error))


def _abort_process(handle: UInt64, mut native: _NativeBuffers) -> String:
    """Best-effort explicit cleanup after a machinery error; never raises."""
    # SAFETY: the live token identifies the sole active process. The adapter
    # consumes it whenever channel close, group sweep, and leader reap complete,
    # including a return that preserves an earlier cleanup diagnostic; otherwise
    # it retains the unreaped leader (live or waitable) and native-static handle.
    # The still-active ExecRuntime token remains its sole cross-ABI owner, and
    # runtime.close() retries that exact handle before restoring signal state.
    # Error is complete, aligned, and non-retained.
    var status = external_call["mtest_exec_process_abort", Int32](
        handle, UInt32(_GRACE_MS), native.error.bitcast[UInt8]()
    )
    if status == 0:
        return String("")
    return String("; ") + _native_error("exec: cleanup failed", native.error)


def _supervise_open_process(
    handle: UInt64,
    spec: ProcessSpec,
    head_cap: Int,
    tail_cap: Int,
    start_ms: Int,
    mut native: _NativeBuffers,
) raises -> ProcessResult:
    """Drive one already-open native process through observe/sweep/reap/close.
    """
    var out_capture = BoundedCapture(head_cap, tail_cap)
    var err_capture = BoundedCapture(head_cap, tail_cap)
    var stdout_open = True
    var stderr_open = True
    var setup_outcome = _SETUP_WAITING
    var leader_waitable = False
    var killing = False
    var escalated = False
    var timed_out = False
    var kill_time = 0

    while not leader_waitable or setup_outcome == _SETUP_WAITING:
        var now = _monotonic_ms(native)
        if not leader_waitable:
            if not killing:
                if interrupt_requested() or (
                    spec.timeout_ms > 0 and now - start_ms >= spec.timeout_ms
                ):
                    _ = _group(handle, _GROUP_TERM, native)
                    killing = True
                    timed_out = True
                    kill_time = now
            elif not escalated and now - kill_time >= spec.grace_ms:
                _ = _group(handle, _GROUP_KILL, native)
                escalated = True

        if _observe(handle, native) == _LEADER_WAITABLE:
            leader_waitable = True

        setup_outcome = _setup_drain(handle, native)
        if leader_waitable and setup_outcome != _SETUP_WAITING:
            break

        var poll_timeout_ms = _POLL_SLICE_MS
        if not killing and spec.timeout_ms > 0:
            var remaining_ms = spec.timeout_ms - (now - start_ms)
            if remaining_ms < poll_timeout_ms:
                poll_timeout_ms = remaining_ms
        var readiness = _poll(handle, poll_timeout_ms, native)
        if stdout_open and (readiness & _READY_STDOUT) != 0:
            if _drain_channel(handle, _CHANNEL_STDOUT, out_capture, native):
                stdout_open = False
        if stderr_open and (readiness & _READY_STDERR) != 0:
            if _drain_channel(handle, _CHANNEL_STDERR, err_capture, native):
                stderr_open = False

    var abnormal = String("")
    if setup_outcome == _SETUP_CORRUPT:
        abnormal = "exec: corrupt child setup record"
    elif (
        setup_outcome != _SETUP_EXEC_SUCCEEDED
        and setup_outcome != _SETUP_SPAWN_FAILED
    ):
        abnormal = "exec: invalid child setup outcome"

    # Keep the observed leader waitable so its pid/pgid cannot be reused while
    # residual group members are killed and inherited pipe writers are drained.
    _ = _group(handle, _GROUP_KILL, native)
    var drain_deadline = _monotonic_ms(native) + _POST_LEADER_MS
    while True:
        if not stdout_open and not stderr_open:
            break
        var now = _monotonic_ms(native)
        if now >= drain_deadline:
            break
        var readiness = _poll(handle, _POST_LEADER_SLICE_MS, native)
        if stdout_open and (readiness & _READY_STDOUT) != 0:
            if _drain_channel(handle, _CHANNEL_STDOUT, out_capture, native):
                stdout_open = False
        if stderr_open and (readiness & _READY_STDERR) != 0:
            if _drain_channel(handle, _CHANNEL_STDERR, err_capture, native):
                stderr_open = False

    if stdout_open:
        _close_channel(handle, _CHANNEL_STDOUT, native)
    if stderr_open:
        _close_channel(handle, _CHANNEL_STDERR, native)
    if (stdout_open or stderr_open) and abnormal == "":
        abnormal = (
            "exec: descendant retained a capture pipe past the cleanup deadline"
        )

    var final = _reap(handle, native)
    var duration_ms = _monotonic_ms(native) - start_ms

    if abnormal != "":
        raise Error(abnormal)

    var termination: Termination
    if timed_out:
        termination = Termination.timed_out(final.kind, final.value, escalated)
    elif setup_outcome == _SETUP_SPAWN_FAILED:
        # SAFETY: a validated setup frame fixes stage at byte 16 and errno at
        # byte 20. SpawnFailed carries the child-side setup/exec errno as data.
        var error_number = Int(native.setup_state.bitcast[Int32]()[5])
        termination = Termination.spawn_failed(error_number)
    else:
        termination = final

    var stdout_truncated = out_capture.was_truncated()
    var stderr_truncated = err_capture.was_truncated()
    var stdout_bytes = out_capture.finish()
    var stderr_bytes = err_capture.finish()
    if setup_outcome == _SETUP_SPAWN_FAILED:
        stdout_bytes = List[UInt8]()
        stderr_bytes = List[UInt8]()
        stdout_truncated = False
        stderr_truncated = False

    _process_close(handle, native)
    return ProcessResult(
        stdout_bytes^,
        stderr_bytes^,
        stdout_truncated,
        stderr_truncated,
        termination,
        duration_ms,
    )


def run_supervised(
    mut runtime: ExecRuntime,
    spec: ProcessSpec,
    capture_bound_bytes: Int = _DEFAULT_CAP_BYTES,
) raises -> ProcessResult:
    """Run one child under exclusive runtime ownership and capture both streams.

    Args:
        runtime: The active, exclusively borrowed process-global exec runtime.
        spec: The command, optional cwd, and deadline. Not mutated.
        capture_bound_bytes: Positive per-stream head+tail capture limit.

    Returns:
        Separate bounded streams, exact truncation flags, truthful structured
        termination, and monotonic duration.

    Raises:
        Error: An input or runner-machinery failure. Child exit, signal, timeout,
            and spawn failure remain structured data rather than exceptions.
    """
    if len(spec.argv) == 0:
        raise Error("exec: run_supervised got an empty argv")
    if capture_bound_bytes <= 0:
        raise Error("exec: capture bound must be positive")
    if not runtime.active:
        raise Error("exec: run_supervised requires an active ExecRuntime")

    var head_cap = capture_bound_bytes // 2
    var tail_cap = capture_bound_bytes - head_cap
    var native = _NativeBuffers(spec)
    var start_ms = _monotonic_ms(native)
    var handle = _process_open(native)

    try:
        return _supervise_open_process(
            handle, spec, head_cap, tail_cap, start_ms, native
        )
    except error:
        var primary = String(error)
        var cleanup = _abort_process(handle, native)
        raise Error(primary + cleanup)
