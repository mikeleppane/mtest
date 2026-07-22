"""Portable subprocess supervision over the private native exec adapter.

`run_supervised` is the one blocking entry point. Mojo owns only the typed
process contract and the bounded captures; the C17 adapter owns platform
headers, PATH planning, pipes, fork/exec, polling, process groups, and wait
status. This keeps Linux and macOS ABI details out of Mojo while preserving the
distinctions the runner reports on: exit versus signal, spawn failure versus
exit 127, and an mtest deadline or interrupt kill versus the child's underlying
final status.
"""
from std.ffi import external_call
from std.memory import UnsafePointer, alloc, memset_zero

from mtest.exec.capture import BoundedCapture
from mtest.exec.result import ProcessResult
from mtest.exec.signals import ExecRuntime, interrupt_count
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

The deadline and interrupt escalation reads `spec.grace_ms`, which defaults to
this same value, so a caller can widen the grace for a child that needs longer
to die cleanly. This constant is the grace for the machinery-error abort path,
where there is no spec in hand and nothing mid-flight worth waiting on.
"""
comptime _POST_LEADER_MS = 300
"""Bound for group sweep and nonblocking drain after leader observation."""
comptime _POST_LEADER_SLICE_MS = 10
"""Short poll slice while waiting for swept pipes to reach EOF."""
comptime _BUFSIZE = 65536
"""One native read buffer, reused for both streams."""

comptime _COMPILE_CAP = 64
"""The compile-time supervision ceiling: never more than 64 live children."""
comptime _RESERVED_HEADROOM = 64
"""Fds held back from the 3N+3 spawn peak for the runner's own descriptors."""
comptime _MIN_SOFT_FD = _RESERVED_HEADROOM + 6
"""Smallest RLIMIT_NOFILE soft limit that still fits a single child (N=1)."""
comptime _SWEEP_BYTE_BUDGET = 8 * _BUFSIZE
"""Bytes one `wait_any` sweep may read before yielding to the next sweep."""
comptime _SWEEP_TIME_BUDGET_MS = 50
"""Wall-clock cap on one sweep's drain phase before it yields."""

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
    """Aligned storage for the exact native ABI-v2 records of one run."""

    var owned_strings: List[_BytePtr]
    var argv_records: _U64Ptr
    var env_records: _U64Ptr
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
        `process_open` call. The adapter copies argv, cwd, and environment
        before returning and never retains a Mojo pointer.
        """
        self.owned_strings = List[_BytePtr]()
        # SAFETY: each allocation uses its record's required ABI-v2 alignment
        # (8 for pointer/64-bit records, 4 for 32-bit records). Counts cover the
        # complete fixed layouts asserted by the C header; every allocation has
        # this object as its sole owner and is freed in `__del__`.
        self.argv_records = alloc[UInt64](len(spec.argv) * 2)
        # SAFETY: this object solely owns the env-extra records array, one 16-byte
        # {data,length} record per override entry, freed in `__del__`. A nonzero
        # count writes every slot below before C reads it; a zero count yields an
        # untouched zero-length span the NULL/0 spec never wires in, so this
        # allocation needs no zeroing.
        self.env_records = alloc[UInt64](len(spec.env_extra) * 2)
        self.spec_record = alloc[UInt64](7)
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
        memset_zero(self.spec_record.bitcast[UInt8](), 56)
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

        # SAFETY: the first ABI-v2 spec field is a non-retained pointer to the
        # complete 16-byte argv records above. Remaining scalar slots are exact
        # fixed-width fields; every slot was zeroed first, so reserved=0.
        self.spec_record.bitcast[_U64Ptr]()[0] = self.argv_records
        self.spec_record[1] = UInt64(len(spec.argv))
        # The two ABI-v2 spec tail slots are the env-extra records pointer at u64
        # index 5 (byte 40) and its count at index 6 (byte 48). A zero count keeps
        # both slots NULL/0, reproducing the v1 environment snapshot byte for byte;
        # a nonzero count hands C the raw override records, which it validates and
        # merges replace-not-append before fork.
        if len(spec.env_extra) == 0:
            self.spec_record[5] = UInt64(0)
            self.spec_record[6] = UInt64(0)
        else:
            for i in range(len(spec.env_extra)):
                var copied = _copy_c_string(spec.env_extra[i])
                self.owned_strings.append(copied)
                # SAFETY: `owned_strings` owns this initialized allocation until
                # the native open has copied exactly the recorded number of bytes.
                self.env_records.bitcast[_BytePtr]()[i * 2] = copied
                self.env_records[i * 2 + 1] = UInt64(
                    spec.env_extra[i].byte_length()
                )
            # SAFETY: the env-extra spec field is a non-retained pointer to the
            # complete 16-byte records above, which outlive the synchronous
            # `process_open`; C copies each entry and retains no Mojo pointer.
            self.spec_record.bitcast[_U64Ptr]()[5] = self.env_records
            self.spec_record[6] = UInt64(len(spec.env_extra))
        if spec.cwd:
            var copied = _copy_c_string(spec.cwd.value())
            self.owned_strings.append(copied)
            # SAFETY: `owned_strings` owns the complete initialized cwd copy
            # until the native open copies it and returns without retaining it.
            self.spec_record.bitcast[_BytePtr]()[2] = copied
            self.spec_record[3] = UInt64(spec.cwd.value().byte_length())
            # SAFETY: `spec_record` owns 56 initialized bytes aligned to 8; byte
            # offset 32 is the exact ABI-v2 UInt32 flags field and value 1 is valid.
            self.spec_record.bitcast[UInt32]()[8] = _PROCESS_HAS_CWD

    def __del__(deinit self):
        """Free every ABI record once, after native calls have returned."""
        # SAFETY: C never retains any string, record, or I/O pointer. This object
        # uniquely owns every allocation and deinitialization runs exactly once.
        for i in range(len(self.owned_strings)):
            # SAFETY: `i` is within the owning list; each entry is a distinct
            # C-string allocation that C did not retain and no path freed early.
            self.owned_strings[i].free()
        # SAFETY: C retained none of these aligned ABI-record pointers; this
        # object uniquely owns each allocation and frees each exactly once.
        self.argv_records.free()
        self.env_records.free()
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
    """Render the adapter's error record, keeping any cleanup failure."""
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


def _native_poll_set(
    handles: _U64Ptr,
    count: UInt64,
    timeout_ms: Int32,
    results: _BytePtr,
    error: _BytePtr,
) -> Int32:
    """Thin ABI-v2 binding: poll readiness across a set of handles at once.

    The Supervisor's readiness-set driver is wired in a later commit; this is
    the reachable declaration so it can call the primitive. `handles` names
    `count` live tokens; `results` addresses `count` 8-byte poll-result records
    that the native two-phase validation zeroes; C retains neither pointer.
    """
    # SAFETY: `handles` and `results` are caller-owned records spanning exactly
    # `count` entries each, and `error` a complete aligned error record; the ABI
    # validates the count, writes only within those spans, and retains no
    # pointer. All four outlive this synchronous call.
    return external_call["mtest_exec_poll_set", Int32](
        handles, count, timeout_ms, results, error
    )


def _native_fd_limit(soft_limit: _BytePtr, error: _BytePtr) -> Int32:
    """Thin ABI-v2 binding: report the RLIMIT_NOFILE soft limit.

    Wired into the Supervisor's effective-cap derivation in a later commit;
    RLIM_INFINITY arrives as the UINT64_MAX sentinel. C retains no pointer.
    """
    # SAFETY: `soft_limit` addresses a caller-owned 8-byte cell and `error` a
    # complete aligned error record; the ABI writes only those and retains no
    # pointer. Both outlive this synchronous call.
    return external_call["mtest_exec_fd_limit", Int32](soft_limit, error)


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


def _read_quantum(
    handle: UInt64,
    channel: UInt32,
    mut capture: BoundedCapture,
    mut native: _NativeBuffers,
) raises -> UInt32:
    """Read at most one `_BUFSIZE` chunk without blocking.

    Returns the native read state (`_READ_BYTES`, `_READ_EOF`, or
    `_READ_WOULD_BLOCK`). On `_READ_BYTES` the chunk's bytes are pushed into
    `capture` and its length is left in `native.read_result[1]` for the caller's
    sweep budget. This one-chunk quantum is the fair unit the Supervisor charges
    against its per-sweep byte budget so no single fd monopolizes a sweep.
    """
    # SAFETY: the live token names an owned process; `io_buffer` owns `_BUFSIZE`
    # writable bytes and read-result/error are complete aligned non-retained
    # records. C rejects counts beyond the supplied capacity.
    var status = external_call["mtest_exec_process_read", Int32](
        handle,
        channel,
        native.io_buffer,
        UInt64(_BUFSIZE),
        native.read_result.bitcast[UInt8](),
        native.error.bitcast[UInt8](),
    )
    if status != 0:
        raise Error(_native_error("exec: channel read failed", native.error))
    # SAFETY: success initialized the 16-byte result. State is bytes 0..3;
    # count is bytes 8..15 and is read only for READ_BYTES.
    var state = native.read_result.bitcast[UInt32]()[0]
    if state == _READ_EOF or state == _READ_WOULD_BLOCK:
        return state
    if state != _READ_BYTES:
        raise Error("exec: native channel returned an invalid read state")
    var count = Int(native.read_result[1])
    if count < 0 or count > _BUFSIZE:
        raise Error("exec: native channel returned an invalid byte count")
    # SAFETY: C reported `count <= _BUFSIZE` bytes and initialized exactly that
    # prefix before returning; the buffer remains alive and unaliased.
    for i in range(count):
        capture.push_byte(native.io_buffer[i])
    return state


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


def run_supervised(
    mut runtime: ExecRuntime,
    spec: ProcessSpec,
    capture_bound_bytes: Int = _DEFAULT_CAP_BYTES,
) raises -> ProcessResult:
    """Run one child under exclusive runtime ownership and capture both streams.

    This is the capacity-1 view of the Supervisor: it spawns the one child,
    drives `wait_any` until that child's `Completion`, and projects the
    completion's `ProcessResult`. There is a single supervision implementation;
    the one-process path takes no special case.

    Args:
        runtime: The active, exclusively borrowed process-global exec runtime.
        spec: The command, optional cwd, and deadline.
        capture_bound_bytes: Positive per-stream head+tail capture limit.

    Returns:
        Separate bounded streams, exact truncation flags, truthful structured
        termination, and monotonic duration.

    Raises:
        Error: An input or runner-machinery failure. Child exit, signal,
            timeout, and spawn failure stay structured data, not exceptions.
    """
    if len(spec.argv) == 0:
        raise Error("exec: run_supervised got an empty argv")
    if capture_bound_bytes <= 0:
        raise Error("exec: capture bound must be positive")
    if not runtime.active:
        raise Error("exec: run_supervised requires an active ExecRuntime")

    var supervisor = Supervisor(1, capture_bound_bytes)
    _ = supervisor.spawn(spec.copy(), 0)
    while True:
        var completed = supervisor.wait_any(_POLL_SLICE_MS)
        if completed:
            return completed.take().into_result()


comptime _KILL_DEADLINE = 1
"""Kill-cause code: an mtest per-child deadline fired first."""
comptime _KILL_INTERRUPT = 2
"""Kill-cause code: an interrupt activation drove the kill."""


@fieldwise_init
struct SlotId(Copyable, Movable):
    """An opaque in-flight handle: a slot index paired with its generation.

    Slot storage is recycled, so the raw index alone is ambiguous. The
    generation disambiguates: a `SlotId` from a completed run never matches the
    next tenant of the same slot, so a stale token is always rejected.
    """

    var index: Int
    """The recycled storage index this run occupied."""
    var generation: Int
    """The monotonically increasing tenancy stamp that made the index unique."""


@fieldwise_init
struct KillCause(Copyable, Equatable, Movable, Writable):
    """Why the Supervisor initiated a kill: a per-child deadline or an interrupt.

    The cause latches once, at the first kill initiation for a slot, and is
    carried out unchanged in the slot's `Completion`.
    """

    var value: Int
    """The latched cause code: `DEADLINE` or `INTERRUPT`."""

    comptime DEADLINE = _KILL_DEADLINE
    comptime INTERRUPT = _KILL_INTERRUPT

    @staticmethod
    def deadline() -> Self:
        """The cause for a per-child deadline expiry."""
        return Self(Self.DEADLINE)

    @staticmethod
    def interrupt() -> Self:
        """The cause for an observed interrupt activation."""
        return Self(Self.INTERRUPT)

    def is_deadline(self) -> Bool:
        """Whether a deadline drove the kill."""
        return self.value == Self.DEADLINE

    def is_interrupt(self) -> Bool:
        """Whether an interrupt drove the kill."""
        return self.value == Self.INTERRUPT

    def __eq__(self, other: Self) -> Bool:
        """Structural equality on the latched cause code."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return self.value != other.value

    def write_to(self, mut writer: Some[Writer]):
        """Render a short debug form for assertion messages."""
        if self.value == Self.DEADLINE:
            writer.write("KillCause.DEADLINE")
        elif self.value == Self.INTERRUPT:
            writer.write("KillCause.INTERRUPT")
        else:
            writer.write("KillCause(", self.value, ")")


struct Completion(Movable):
    """One finalized slot's outcome, extracted before the slot is recycled.

    `tag` is the opaque, caller-assigned identity from `spawn`; the Supervisor
    returns it so a caller never has to correlate through a recycled slot index.
    `kill_cause` is set only when the Supervisor initiated a kill.
    """

    var tag: Int
    """The opaque identity the caller passed to `spawn` for this run."""
    var result: ProcessResult
    """The captured streams, structured termination, and duration."""
    var kill_cause: Optional[KillCause]
    """The latched kill cause, or `None` when the child ended on its own."""

    def __init__(
        out self,
        tag: Int,
        var result: ProcessResult,
        var kill_cause: Optional[KillCause],
    ):
        """Take ownership of a finalized slot's projected outcome."""
        self.tag = tag
        self.result = result^
        self.kill_cause = kill_cause^

    def into_result(deinit self) -> ProcessResult:
        """Consume this completion and hand back just its `ProcessResult`."""
        return self.result^


def effective_cap(soft_fd_limit: UInt64) raises -> Int:
    """The live-child ceiling that a soft fd limit can honor at the 3N+3 peak.

    Each child costs three descriptors (stdout, stderr, setup) at its spawn
    peak, atop a reserved headroom for the runner's own fds. The formula is
    `min(64, (soft - 64 - 3) // 3)` with a reserved headroom of 64. The
    `UINT64_MAX` sentinel (RLIM_INFINITY) and any limit large enough to reach
    the compile-time ceiling both yield 64. A limit too small to fit even one
    child is a hard environment error, never a silent clamp to a capacity the
    spawn peak cannot honor.

    Args:
        soft_fd_limit: The RLIMIT_NOFILE soft limit, or the `UINT64_MAX`
            RLIM_INFINITY sentinel.

    Returns:
        The effective live-child capacity in `1 ..= 64`.

    Raises:
        Error: When the soft limit cannot fit even a single child. The message
            names the offending limit and the required minimum; a caller maps
            this hard environment fault to exit 3.
    """
    if soft_fd_limit == UInt64.MAX:
        return _COMPILE_CAP
    if soft_fd_limit >= UInt64(_RESERVED_HEADROOM + 3 * _COMPILE_CAP + 3):
        return _COMPILE_CAP
    var soft = Int(soft_fd_limit)
    if soft < _MIN_SOFT_FD:
        raise Error(
            "exec: RLIMIT_NOFILE soft limit "
            + String(soft)
            + " is below the minimum "
            + String(_MIN_SOFT_FD)
            + " required to supervise a single child"
        )
    return (soft - _RESERVED_HEADROOM - 3) // 3


def query_effective_cap() raises -> Int:
    """Resolve the effective capacity from the live RLIMIT_NOFILE soft limit.

    Reads the soft limit through the native adapter and applies `effective_cap`.

    Raises:
        Error: A native fd-limit query failure, or the hard environment error
            from `effective_cap` when even one child does not fit.
    """
    # SAFETY: `soft_limit` owns one 8-byte cell and `error` a complete 32-byte
    # aligned ABI-v1 error record; both are zeroed before the non-retaining query
    # and freed on every path below. C writes only the soft limit and the error.
    var soft_limit = alloc[UInt64](1)
    var error = alloc[UInt64](4)
    memset_zero(soft_limit.bitcast[UInt8](), 8)
    memset_zero(error.bitcast[UInt8](), 32)
    var status = _native_fd_limit(
        soft_limit.bitcast[UInt8](), error.bitcast[UInt8]()
    )
    if status != 0:
        var message = _native_error("exec: fd limit query failed", error)
        # SAFETY: both cells are uniquely owned here and C retained neither; free
        # each exactly once before raising, on this early-return path.
        soft_limit.free()
        error.free()
        raise Error(message)
    var value = soft_limit[0]
    # SAFETY: the query succeeded and read `value` out; both uniquely-owned,
    # non-retained cells are now dead and freed exactly once each.
    soft_limit.free()
    error.free()
    return effective_cap(value)


def decide_kill(
    deadline_expired: Bool, interrupt_activations: Int
) -> Optional[KillCause]:
    """The observation-order decision for one unlatched slot in one sweep.

    This is an observation-order rule, not a chronology claim: within a sweep a
    deadline is evaluated FIRST, so an already-expired deadline latches TIMEOUT
    even when an interrupt was also observed; only an unlatched slot with no
    expired deadline and at least one interrupt activation latches on the
    interrupt. Escalation (a second activation) is a separate axis; see
    `escalate_on_interrupt`.

    Args:
        deadline_expired: Whether this slot's deadline has already expired.
        interrupt_activations: The `interrupt_count()` value observed this sweep.

    Returns:
        The cause to latch, or `None` when no kill is initiated this sweep.
    """
    if deadline_expired:
        return Optional(KillCause.deadline())
    if interrupt_activations >= 1:
        return Optional(KillCause.interrupt())
    return None


def escalate_on_interrupt(interrupt_activations: Int) -> Bool:
    """Whether a second observed interrupt activation forces immediate SIGKILL.

    Args:
        interrupt_activations: The `interrupt_count()` value observed this sweep.

    Returns:
        True once two activations have been observed (escalate-to-kill).
    """
    return interrupt_activations >= 2


struct _Slot(Movable):
    """One in-flight child's full driving state within the Supervisor."""

    var active: Bool
    var generation: Int
    var handle: UInt64
    var tag: Int
    var timeout_ms: Int
    var grace_ms: Int
    var start_ms: Int
    var native: _NativeBuffers
    var out_capture: BoundedCapture
    var err_capture: BoundedCapture
    var stdout_open: Bool
    var stderr_open: Bool
    var setup_outcome: UInt32
    var leader_waitable: Bool
    var draining: Bool
    var drain_deadline: Int
    var group_swept: Bool
    var killing: Bool
    var escalated: Bool
    var timed_out: Bool
    var kill_time: Int
    var has_kill_cause: Bool
    var kill_cause_value: Int

    def __init__(
        out self,
        var spec: ProcessSpec,
        tag: Int,
        generation: Int,
        head_cap: Int,
        tail_cap: Int,
    ) raises:
        """Open one native child and initialize its lifecycle state.

        The open is non-blocking: it forks and returns immediately with the
        child RESOLVING through its setup fd. A failure to open raises before
        the slot is published, so no half-opened slot is ever admitted.
        """
        self.native = _NativeBuffers(spec)
        self.start_ms = _monotonic_ms(self.native)
        self.handle = _process_open(self.native)
        self.out_capture = BoundedCapture(head_cap, tail_cap)
        self.err_capture = BoundedCapture(head_cap, tail_cap)
        self.active = True
        self.generation = generation
        self.tag = tag
        self.timeout_ms = spec.timeout_ms
        self.grace_ms = spec.grace_ms
        self.stdout_open = True
        self.stderr_open = True
        self.setup_outcome = _SETUP_WAITING
        self.leader_waitable = False
        self.draining = False
        self.drain_deadline = 0
        self.group_swept = False
        self.killing = False
        self.escalated = False
        self.timed_out = False
        self.kill_time = 0
        self.has_kill_cause = False
        self.kill_cause_value = 0


struct Supervisor(Movable):
    """Capacity-N supervision over the native exec adapter.

    A Supervisor drives up to `capacity` live children at once, each through the
    same per-slot lifecycle the capacity-1 run uses: RESOLVING (setup fd in the
    poll set) -> RUNNING -> a per-slot bounded post-death DRAINING window ->
    finalized only when its leader is reaped, its group is swept, and every
    channel (the setup channel included) is closed. EOF alone never finalizes a
    slot and a missing EOF never wedges one.

    `spawn` is non-blocking and returns an opaque `SlotId`; `wait_any` runs one
    globally budgeted, fair sweep across every live slot and returns the next
    finalized slot's `Completion` (its fields extracted before the slot is
    recycled); `kill_all` tears every live group down through the two-pass
    protocol; `in_flight` reports how many slots are live.
    """

    var capacity: Int
    var head_cap: Int
    var tail_cap: Int
    var slots: List[_Slot]
    var cursor: Int
    var next_generation: Int
    var scratch: _NativeBuffers
    var poll_handles: _U64Ptr
    var poll_results: _BytePtr

    def __init__(
        out self, capacity: Int, capture_bound_bytes: Int = _DEFAULT_CAP_BYTES
    ) raises:
        """Allocate the shared poll-set buffers for up to `capacity` children.

        Args:
            capacity: The maximum number of simultaneously live children, in
                `1 ..= 64`.
            capture_bound_bytes: The positive per-stream head+tail capture bound
                each child's captures honor.

        Raises:
            Error: When `capacity` or the capture bound is out of range.
        """
        if capacity < 1 or capacity > _COMPILE_CAP:
            raise Error(
                "exec: supervisor capacity must be in 1..="
                + String(_COMPILE_CAP)
                + ", got "
                + String(capacity)
            )
        if capture_bound_bytes <= 0:
            raise Error("exec: capture bound must be positive")
        self.capacity = capacity
        self.head_cap = capture_bound_bytes // 2
        self.tail_cap = capture_bound_bytes - self.head_cap
        self.slots = List[_Slot]()
        self.cursor = 0
        self.next_generation = 1
        var dummy = ProcessSpec.command(["mtest-supervisor-scratch"], 0)
        self.scratch = _NativeBuffers(dummy)
        # SAFETY: these two records are sized to the fixed capacity and owned
        # solely by this Supervisor; `poll_handles` holds `capacity` tokens and
        # `poll_results` `capacity` 8-byte poll-result records. Both are freed in
        # `__del__` and C retains neither across a `poll_set` call.
        self.poll_handles = alloc[UInt64](capacity)
        self.poll_results = alloc[UInt8](capacity * 8)
        memset_zero(self.poll_handles.bitcast[UInt8](), capacity * 8)
        memset_zero(self.poll_results, capacity * 8)

    def __del__(deinit self):
        """Best-effort teardown of any slot left in flight, then free buffers.
        """
        # SAFETY: an abandoned live slot is torn down through the native abort,
        # which consumes its handle; failures cannot be raised from a destructor,
        # so callers use `kill_all`/`wait_any` for a reported teardown.
        for i in range(len(self.slots)):
            if self.slots[i].active:
                _ = _abort_process(self.slots[i].handle, self.slots[i].native)
                self.slots[i].active = False
        # SAFETY: this Supervisor uniquely owns both poll-set records and frees
        # each exactly once; C retained neither.
        self.poll_handles.free()
        self.poll_results.free()

    def in_flight(self) -> Int:
        """How many slots currently hold a live, unfinalized child."""
        var n = 0
        for i in range(len(self.slots)):
            if self.slots[i].active:
                n += 1
        return n

    def slot_is_live(self, slot: SlotId) -> Bool:
        """Whether `slot` still names a live child (rejects a recycled token).

        Args:
            slot: A `SlotId` returned by `spawn`.

        Returns:
            True only when the slot is still active and its generation matches;
            a token whose slot has been recycled is rejected.
        """
        if slot.index < 0 or slot.index >= len(self.slots):
            return False
        return (
            self.slots[slot.index].active
            and self.slots[slot.index].generation == slot.generation
        )

    def spawn(mut self, var spec: ProcessSpec, tag: Int) raises -> SlotId:
        """Open one child non-blocking and admit it to a slot.

        Args:
            spec: The command, optional cwd, and deadline. Consumed.
            tag: The caller's opaque identity, returned in this run's
                `Completion` so correlation never goes through a recycled index.

        Returns:
            An opaque `SlotId` naming the admitted slot and its generation.

        Raises:
            Error: An empty argv, a full Supervisor, or a native open failure.
                A per-child spawn failure is not this error: it resolves through
                the slot's eventual `Completion` as a `SpawnFailed` termination.
        """
        if len(spec.argv) == 0:
            raise Error("exec: spawn got an empty argv")
        var idx = -1
        for i in range(len(self.slots)):
            if not self.slots[i].active:
                idx = i
                break
        if idx == -1 and len(self.slots) >= self.capacity:
            raise Error("exec: supervisor is at capacity")
        var generation = self.next_generation
        self.next_generation += 1
        if idx == -1:
            self.slots.append(
                _Slot(spec^, tag, generation, self.head_cap, self.tail_cap)
            )
            idx = len(self.slots) - 1
        else:
            self.slots[idx] = _Slot(
                spec^, tag, generation, self.head_cap, self.tail_cap
            )
        return SlotId(idx, generation)

    def wait_any(mut self, slice_ms: Int) raises -> Optional[Completion]:
        """Run one fair sweep and return the next finalized slot's `Completion`.

        The sweep, in fixed order: evaluate every live slot's deadline against
        one monotonic timestamp FIRST; THEN read `interrupt_count()` once and
        apply interrupt kills (and a second-activation SIGKILL escalation) to the
        still-unlatched slots; escalate per-slot graces; observe leaders and
        drain the setup channel; block once in `poll_set` across every live
        channel; drain ready channels under a global byte and time budget with a
        rotating cursor; then finalize the first slot whose terminal predicate
        holds. A machinery fault tears the Supervisor down (single live slot via
        the native abort; multiple via the two-pass protocol) and re-raises the
        primary error with any cleanup failure appended.

        Args:
            slice_ms: The maximum time the one blocking `poll_set` may wait.

        Returns:
            The next finalized slot's `Completion`, or `None` when no slot
            finalized this sweep.

        Raises:
            Error: A runner-machinery failure, or the descendant-retained-pipe
                honesty error for a slot whose pipe outlived the drain window.
        """
        if self.in_flight() == 0:
            return None
        try:
            return self._sweep(slice_ms)
        except err:
            raise self._cleanup_after_fault(String(err))

    def kill_all(mut self) raises:
        """Tear every live group down through the two-pass protocol.

        Pass one SIGTERMs every live group; a single shared grace window then
        lets streams drain opportunistically; pass two SIGKILLs every survivor
        and reaps and closes every slot regardless of individual failures.

        Raises:
            Error: When cleanup could not complete for some slot; the message
                aggregates each slot's failure.
        """
        var live = List[Int]()
        for i in range(len(self.slots)):
            if self.slots[i].active:
                live.append(i)
        if len(live) == 0:
            return
        var notes = self._two_pass_cleanup(live)
        if notes != "":
            raise Error("exec: supervisor kill_all cleanup incomplete" + notes)

    def _now(mut self) raises -> Int:
        """Read the shared monotonic clock through the scratch record."""
        return _monotonic_ms(self.scratch)

    def _initiate_kill(mut self, i: Int, cause_value: Int, now: Int) raises:
        """SIGTERM one slot's group and latch its kill cause (once)."""
        _ = _group(self.slots[i].handle, _GROUP_TERM, self.slots[i].native)
        self.slots[i].killing = True
        self.slots[i].timed_out = True
        self.slots[i].kill_time = now
        if not self.slots[i].has_kill_cause:
            self.slots[i].has_kill_cause = True
            self.slots[i].kill_cause_value = cause_value

    def _clamp_timeout(self, slice_ms: Int, now: Int) -> Int:
        """Clamp the blocking wait to the nearest deadline or drain window."""
        var timeout = slice_ms
        for i in range(len(self.slots)):
            if not self.slots[i].active:
                continue
            if self.slots[i].draining:
                if (
                    not self.slots[i].stdout_open
                    and not self.slots[i].stderr_open
                ):
                    return 0
                var remaining = self.slots[i].drain_deadline - now
                if remaining < timeout:
                    timeout = remaining
            elif (
                self.slots[i].timeout_ms > 0
                and not self.slots[i].killing
                and not self.slots[i].leader_waitable
            ):
                var remaining = self.slots[i].timeout_ms - (
                    now - self.slots[i].start_ms
                )
                if remaining < timeout:
                    timeout = remaining
        if timeout < 0:
            timeout = 0
        return timeout

    def _poll_set(mut self, timeout_ms: Int) raises:
        """Block once across every live slot's channels (the shared multiplex).

        This is the one place a sweep sleeps, so a draining slot never blocks a
        live sibling; per-slot readiness is re-read non-blocking during the
        drain phase.
        """
        var count = 0
        for i in range(len(self.slots)):
            if self.slots[i].active:
                # SAFETY: `poll_handles` owns `capacity` slots and `count` never
                # exceeds the number of active slots, itself bounded by capacity.
                self.poll_handles[count] = self.slots[i].handle
                count += 1
        if count == 0:
            return
        # SAFETY: `poll_handles`/`poll_results` are the capacity-sized owned
        # records, `count` is bounded by capacity, and the scratch error record
        # is complete and aligned; C validates the count and retains no pointer.
        var status = _native_poll_set(
            self.poll_handles,
            UInt64(count),
            Int32(timeout_ms),
            self.poll_results,
            self.scratch.error.bitcast[UInt8](),
        )
        if status != 0:
            raise Error(
                _native_error("exec: poll set failed", self.scratch.error)
            )

    def _drain_sweep(mut self) raises:
        """Fair, globally budgeted drain with a cursor persisted across sweeps.

        Visits live slots round-robin from the persisted cursor, reading one
        `_BUFSIZE` quantum per ready channel per visit and charging it against a
        shared byte budget; a monotonic-time budget also ends the sweep early.
        Work not reached this sweep resumes at the cursor next sweep.
        """
        var n = len(self.slots)
        if n == 0:
            return
        var bytes_left = _SWEEP_BYTE_BUDGET
        var start_ms = self._now()
        var stopped_at = self.cursor % n
        var resumed = False
        for step in range(n):
            var i = (self.cursor + step) % n
            if not self.slots[i].active:
                continue
            if (
                bytes_left <= 0
                or self._now() - start_ms >= _SWEEP_TIME_BUDGET_MS
            ):
                stopped_at = i
                resumed = True
                break
            var readiness = _poll(self.slots[i].handle, 0, self.slots[i].native)
            if self.slots[i].stdout_open and (readiness & _READY_STDOUT) != 0:
                var state = _read_quantum(
                    self.slots[i].handle,
                    _CHANNEL_STDOUT,
                    self.slots[i].out_capture,
                    self.slots[i].native,
                )
                if state == _READ_EOF:
                    self.slots[i].stdout_open = False
                elif state == _READ_BYTES:
                    bytes_left -= Int(self.slots[i].native.read_result[1])
            if self.slots[i].stderr_open and (readiness & _READY_STDERR) != 0:
                var state = _read_quantum(
                    self.slots[i].handle,
                    _CHANNEL_STDERR,
                    self.slots[i].err_capture,
                    self.slots[i].native,
                )
                if state == _READ_EOF:
                    self.slots[i].stderr_open = False
                elif state == _READ_BYTES:
                    bytes_left -= Int(self.slots[i].native.read_result[1])
        if resumed:
            self.cursor = stopped_at
        else:
            self.cursor = (self.cursor + 1) % n

    def _sweep(mut self, slice_ms: Int) raises -> Optional[Completion]:
        """One fair sweep; see `wait_any` for the fixed observation order."""
        var now = self._now()
        var n = len(self.slots)

        # (1) Deadlines observed FIRST against one sweep timestamp.
        for i in range(n):
            if not self.slots[i].active:
                continue
            if self.slots[i].leader_waitable or self.slots[i].killing:
                continue
            if (
                self.slots[i].timeout_ms > 0
                and now - self.slots[i].start_ms >= self.slots[i].timeout_ms
            ):
                self._initiate_kill(i, _KILL_DEADLINE, now)

        # (2) THEN the interrupt state, read once and applied to the rest.
        var activations = interrupt_count()
        if activations >= 1:
            for i in range(n):
                if not self.slots[i].active:
                    continue
                if self.slots[i].leader_waitable or self.slots[i].killing:
                    continue
                self._initiate_kill(i, _KILL_INTERRUPT, now)
        if activations >= 2:
            for i in range(n):
                if not self.slots[i].active or self.slots[i].leader_waitable:
                    continue
                _ = _group(
                    self.slots[i].handle, _GROUP_KILL, self.slots[i].native
                )
                self.slots[i].escalated = True

        # (3) Per-slot SIGTERM->SIGKILL grace escalation.
        for i in range(n):
            if not self.slots[i].active or self.slots[i].leader_waitable:
                continue
            if self.slots[i].killing and not self.slots[i].escalated:
                if now - self.slots[i].kill_time >= self.slots[i].grace_ms:
                    _ = _group(
                        self.slots[i].handle, _GROUP_KILL, self.slots[i].native
                    )
                    self.slots[i].escalated = True

        # (4) Observe leaders, drain setup, and transition finished leaders.
        for i in range(n):
            if not self.slots[i].active or self.slots[i].draining:
                continue
            if not self.slots[i].leader_waitable:
                if (
                    _observe(self.slots[i].handle, self.slots[i].native)
                    == _LEADER_WAITABLE
                ):
                    self.slots[i].leader_waitable = True
            if self.slots[i].setup_outcome == _SETUP_WAITING:
                self.slots[i].setup_outcome = _setup_drain(
                    self.slots[i].handle, self.slots[i].native
                )
            if (
                self.slots[i].leader_waitable
                and self.slots[i].setup_outcome != _SETUP_WAITING
            ):
                # Keep the observed leader waitable while residual group members
                # are killed and inherited pipe writers are drained.
                _ = _group(
                    self.slots[i].handle, _GROUP_KILL, self.slots[i].native
                )
                self.slots[i].group_swept = True
                self.slots[i].draining = True
                self.slots[i].drain_deadline = now + _POST_LEADER_MS

        # (5) The one blocking multiplex across every live channel.
        self._poll_set(self._clamp_timeout(slice_ms, now))

        # (6) Fair, globally budgeted drain.
        self._drain_sweep()

        # (7) Finalize the first slot whose terminal predicate holds.
        var final_now = self._now()
        for i in range(n):
            if not self.slots[i].active or not self.slots[i].draining:
                continue
            var both_closed = (
                not self.slots[i].stdout_open and not self.slots[i].stderr_open
            )
            if both_closed or final_now >= self.slots[i].drain_deadline:
                return Optional(self._finalize(i))
        return None

    def _finalize(mut self, i: Int) raises -> Completion:
        """Force-close, reap, classify, and recycle one terminal slot.

        The terminal predicate is `reaped && group_swept && all channels
        closed`. Any channel still open at window expiry is force-closed and
        surfaces the descendant-retained-pipe honesty error rather than
        laundering the leader's exit into a clean pass.
        """
        var abnormal = String("")
        if self.slots[i].setup_outcome == _SETUP_CORRUPT:
            abnormal = "exec: corrupt child setup record"
        elif (
            self.slots[i].setup_outcome != _SETUP_EXEC_SUCCEEDED
            and self.slots[i].setup_outcome != _SETUP_SPAWN_FAILED
        ):
            abnormal = "exec: invalid child setup outcome"

        if self.slots[i].stdout_open:
            _close_channel(
                self.slots[i].handle, _CHANNEL_STDOUT, self.slots[i].native
            )
        if self.slots[i].stderr_open:
            _close_channel(
                self.slots[i].handle, _CHANNEL_STDERR, self.slots[i].native
            )
        if (
            self.slots[i].stdout_open or self.slots[i].stderr_open
        ) and abnormal == "":
            abnormal = (
                "exec: descendant retained a capture pipe past the cleanup"
                " deadline"
            )

        var final = _reap(self.slots[i].handle, self.slots[i].native)
        var duration_ms = self._now() - self.slots[i].start_ms

        if abnormal != "":
            raise Error(abnormal)

        var termination: Termination
        if self.slots[i].timed_out:
            termination = Termination.timed_out(
                final.kind, final.value, self.slots[i].escalated
            )
        elif self.slots[i].setup_outcome == _SETUP_SPAWN_FAILED:
            # SAFETY: a validated setup frame fixes stage at byte 16 and errno at
            # byte 20. SpawnFailed carries the child-side setup/exec errno.
            var error_number = Int(
                self.slots[i].native.setup_state.bitcast[Int32]()[5]
            )
            termination = Termination.spawn_failed(error_number)
        else:
            termination = final

        var stdout_truncated = self.slots[i].out_capture.was_truncated()
        var stderr_truncated = self.slots[i].err_capture.was_truncated()
        var stdout_bytes = self.slots[i].out_capture.finish()
        var stderr_bytes = self.slots[i].err_capture.finish()
        if self.slots[i].setup_outcome == _SETUP_SPAWN_FAILED:
            stdout_bytes = List[UInt8]()
            stderr_bytes = List[UInt8]()
            stdout_truncated = False
            stderr_truncated = False

        _process_close(self.slots[i].handle, self.slots[i].native)

        var kill_cause = Optional[KillCause](None)
        if self.slots[i].has_kill_cause:
            kill_cause = Optional(KillCause(self.slots[i].kill_cause_value))
        var tag = self.slots[i].tag
        self.slots[i].active = False
        return Completion(
            tag,
            ProcessResult(
                stdout_bytes^,
                stderr_bytes^,
                stdout_truncated,
                stderr_truncated,
                termination,
                duration_ms,
            ),
            kill_cause^,
        )

    def _cleanup_after_fault(mut self, primary: String) -> Error:
        """Tear the Supervisor down after a machinery fault; preserve `primary`.

        A single live slot is aborted through the native abort (the capacity-1
        cleanup contract, message-compatible with the direct-supervision path);
        multiple live slots go through the shared-grace two-pass protocol.
        """
        var live = List[Int]()
        for i in range(len(self.slots)):
            if self.slots[i].active:
                live.append(i)
        var suffix = String("")
        if len(live) == 1:
            var i = live[0]
            suffix = _abort_process(self.slots[i].handle, self.slots[i].native)
            self.slots[i].active = False
        elif len(live) > 1:
            suffix = self._two_pass_cleanup(live)
        return Error(primary + suffix)

    def _two_pass_cleanup(mut self, live: List[Int]) -> String:
        """SIGTERM all -> one shared grace -> SIGKILL all -> reap/close all.

        Never a per-slot TERM->grace->KILL, which would stack grace windows.
        Individual failures are aggregated and the groups are torn down
        regardless, so no process group survives.
        """
        var notes = String("")
        # Pass one: SIGTERM every live group.
        for k in range(len(live)):
            var i = live[k]
            try:
                _ = _group(
                    self.slots[i].handle, _GROUP_TERM, self.slots[i].native
                )
            except term_error:
                notes += "; " + String(term_error)

        # One shared grace window (never a per-slot grace): a bounded run of
        # short opportunistic waits in poll_set, draining survivors' streams.
        for _ in range(_GRACE_MS // _POST_LEADER_SLICE_MS):
            try:
                self._poll_set(_POST_LEADER_SLICE_MS)
            except:
                pass

        # Pass two: SIGKILL every survivor, then reap and close every slot.
        for k in range(len(live)):
            var i = live[k]
            try:
                _ = _group(
                    self.slots[i].handle, _GROUP_KILL, self.slots[i].native
                )
            except kill_error:
                notes += "; " + String(kill_error)
        for k in range(len(live)):
            var i = live[k]
            # Observe the now-killed leader waitable before reaping it; a fresh
            # slot may not have been observed on the sweep the fault interrupted.
            var observed = self.slots[i].leader_waitable
            for _ in range(200):
                if observed:
                    break
                try:
                    observed = (
                        _observe(self.slots[i].handle, self.slots[i].native)
                        == _LEADER_WAITABLE
                    )
                except observe_error:
                    notes += "; " + String(observe_error)
                    break
                if not observed:
                    try:
                        self._poll_set(_POST_LEADER_SLICE_MS)
                    except:
                        pass
            try:
                _close_channel(
                    self.slots[i].handle, _CHANNEL_STDOUT, self.slots[i].native
                )
            except:
                pass
            try:
                _close_channel(
                    self.slots[i].handle, _CHANNEL_STDERR, self.slots[i].native
                )
            except:
                pass
            if observed:
                try:
                    _ = _reap(self.slots[i].handle, self.slots[i].native)
                except reap_error:
                    notes += "; " + String(reap_error)
            try:
                _process_close(self.slots[i].handle, self.slots[i].native)
            except close_error:
                notes += "; " + String(close_error)
            self.slots[i].active = False
        return notes^
