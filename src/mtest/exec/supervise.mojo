"""The supervisor: fork/exec a child and enforce every honesty invariant (L3).

`run_supervised` is the one blocking entry point and the only place any FFI, fd,
pipe, or syscall lives. It builds the argv and all C strings in the PARENT, forks
a child that touches only async-signal-safe calls before exec, and then drains
both streams concurrently on a poll slice while enforcing the deadline and
polling the interrupt flag. The distinctions the product sells are decided here:
a genuine exit code (including 127) versus a spawn failure (an errno through a
close-on-exec pipe), a crash signal versus our own deadline kill (which latches
to timed out), and a group kill that reaches a grandchild versus a single-child
kill that would hang the parent's read forever.
"""
from std.ffi import external_call
from std.memory import UnsafePointer, memset_zero, alloc

from mtest.exec.capture import BoundedCapture
from mtest.exec.result import ProcessResult
from mtest.exec.signals import interrupt_requested
from mtest.exec.spec import ProcessSpec
from mtest.exec.termination import Termination

comptime _CStr = UnsafePointer[UInt8, MutUntrackedOrigin]

comptime _DEFAULT_CAP_BYTES = 8 * 1024 * 1024
"""Default per-stream capture bound: 8 MiB (head + tail)."""
comptime _POLL_SLICE_MS = 50
"""How long each poll slice waits, bounding deadline-check latency."""
comptime _GRACE_MS = 300
"""How long a group SIGTERM is given before escalating to SIGKILL."""
comptime _BUFSIZE = 65536
"""Per-read drain buffer size."""
comptime _MAX_DRAIN_CHUNKS = 16
"""Cap on reads a single `_drain` call performs before yielding back to the
caller. A grandchild flooding the pipe CONTINUOUSLY would otherwise make `_drain`
loop forever (every `read` returns data, never EOF/EAGAIN), starving the
deadline/interrupt/reap checks. Capping per-call reads makes `_drain` return
"not EOF" after a bounded slice so the caller re-polls and re-checks the clock;
`BoundedCapture` still keeps head+tail, so no capture is lost. 16 * 64 KiB drains
a full kernel pipe buffer many times over, so the common single-pass case is
unaffected."""
comptime _MAX_POSTREAP_DRAINS = 4
"""Cap on post-reap drain iterations, so a flooding grandchild cannot spin the
sweep forever. One `_drain` already empties the whole pipe buffer, so the reaped
child's buffered output is fully captured well under this cap."""

comptime _SYS_write = 1
comptime _WNOHANG = 1
comptime _POLLIN: Int16 = 0x1
comptime _O_CLOEXEC = 0x80000
comptime _F_SETFL = 4
comptime _O_NONBLOCK = 0x800
comptime _CLOCK_MONOTONIC = 1
comptime _SIGCHLD = 17
comptime _SIGTERM = 15
comptime _SIGKILL = 9
comptime _SIG_DFL = 0
comptime _EINTR = 4
"""errno for a syscall interrupted by a signal — retry, never terminal."""
comptime _ETXTBSY = 26
"""errno for "text file busy": a freshly built binary can transiently report it
when exec'd right after it was written and closed — a real exec-after-build race,
never a genuine machinery failure. The child retries exec briefly on it."""
comptime _ETXTBSY_MAX_RETRIES = 30
"""How many times the child re-tries a busy exec before giving up."""
comptime _ETXTBSY_SLEEP_NS = 10_000_000
"""Nanoseconds the child sleeps between busy-exec retries (10 ms); with the retry
cap this bounds the total wait to ~300 ms, all inside the rare busy window."""


def _errno() -> Int:
    """The current thread's errno via the same libc location the child uses."""
    return Int(
        external_call[
            "__errno_location", UnsafePointer[Int32, MutUntrackedOrigin]
        ]()[0]
    )


def _reap_reapable():
    """Force our own SIGCHLD disposition to SIG_DFL before spawning children.

    A parent that inherited `SIG_IGN` for SIGCHLD would make our children
    kernel auto-reaped: `waitpid` then fails with ECHILD and can never hand back
    a status word, which would launder every child — real failures and crashes
    included — into a false `Exited(0)`. Resetting to the default makes every
    child spawned here waitable. Idempotent; the default is the normal state, so
    this only ever undoes a hostile inherited disposition."""
    _ = external_call["signal", Int](Int32(_SIGCHLD), Int(_SIG_DFL))


def _mono_ms() -> Int:
    """The monotonic clock in milliseconds. Does not raise."""
    var ts = alloc[Int64](2)
    _ = external_call["clock_gettime", Int32](
        Int32(_CLOCK_MONOTONIC), ts.bitcast[UInt8]()
    )
    var ms = Int(ts[0]) * 1000 + Int(ts[1]) // 1_000_000
    ts.free()
    return ms


def _cstr(s: String) -> _CStr:
    """A fresh NUL-terminated heap copy of `s`. Allocates; caller frees. Pure.
    """
    var n = s.byte_length()
    var p = alloc[UInt8](n + 1)
    for i in range(n):
        p[i] = s.unsafe_ptr()[i]
    p[n] = 0
    return p


def _decode(raw: Int) -> Termination:
    """Decode a raw `waitpid` status structurally (never 128+N). Pure."""
    if (raw & 0x7F) == 0:
        return Termination.exited((raw >> 8) & 0xFF)
    return Termination.signaled(raw & 0x7F)


def _child_fail_errno(write_fd: Int32):
    """Async-safe: write the current errno to the errno pipe. Child-only."""
    var eloc = external_call[
        "__errno_location", UnsafePointer[Int32, MutUntrackedOrigin]
    ]()
    _ = external_call["syscall", Int](
        Int(_SYS_write), Int(write_fd), eloc.bitcast[UInt8](), Int(4)
    )


def run_supervised(
    spec: ProcessSpec, capture_bound_bytes: Int = _DEFAULT_CAP_BYTES
) raises -> ProcessResult:
    """Run one child under full supervision, capturing both streams.

    Forks and execs `spec.argv` in its own process group, drains stdout and
    stderr concurrently on a poll slice, enforces `spec.timeout_ms` with a group
    SIGTERM->grace->SIGKILL escalation, polls the interrupt flag for a prompt
    bail-out, then reaps the child and decodes its status.

    Args:
        spec: The command to run: argv, optional cwd, timeout. Not mutated.
        capture_bound_bytes: The per-stream capture bound (head + tail); the
            default is 8 MiB. Tests lower it to exercise truncation.

    Returns:
        The captured raw streams (separate, byte-exact under the bound), a
        structured `Termination` (Exited / Signaled / TimedOut / SpawnFailed),
        and the wall duration. Allocates the capture buffers.

    Raises:
        Error: `exec: ...` if the runner's OWN machinery fails (an empty argv, a
            `pipe`/`fork` syscall). A child that exits nonzero or crashes is
            DATA, never a raise.
    """
    if len(spec.argv) == 0:
        raise Error("exec: run_supervised got an empty argv")

    # Guarantee our children are reapable regardless of the inherited SIGCHLD
    # disposition, so `waitpid` below always yields a real status.
    _reap_reapable()

    var head_cap = capture_bound_bytes // 2
    var tail_cap = capture_bound_bytes - head_cap

    # Build argv and all C strings in the PARENT, before the fork.
    var owned = List[_CStr]()
    var argv = alloc[_CStr](len(spec.argv) + 1)
    memset_zero(argv.bitcast[UInt8](), (len(spec.argv) + 1) * 8)
    for i in range(len(spec.argv)):
        var c = _cstr(spec.argv[i])
        owned.append(c)
        argv[i] = c
    var arg0 = argv[0]

    var has_cwd = spec.cwd.__bool__()
    var cwd_cstr = arg0
    if has_cwd:
        cwd_cstr = _cstr(spec.cwd.value())
        owned.append(cwd_cstr)

    # Three pipes: stdout, stderr, and a close-on-exec errno pipe.
    var opipe = alloc[Int32](2)
    var epipe = alloc[Int32](2)
    var xpipe = alloc[Int32](2)
    if external_call["pipe", Int32](opipe) != 0:
        # Nothing opened yet; free the build allocations before raising.
        _free_build(owned^, argv, opipe, epipe, xpipe)
        raise Error("exec: pipe() for stdout failed")
    if external_call["pipe", Int32](epipe) != 0:
        # The stdout pipe is open: close both ends, then free, before raising.
        _ = external_call["close", Int32](opipe[0])
        _ = external_call["close", Int32](opipe[1])
        _free_build(owned^, argv, opipe, epipe, xpipe)
        raise Error("exec: pipe() for stderr failed")
    if external_call["pipe2", Int32](xpipe, Int32(_O_CLOEXEC)) != 0:
        # Both data pipes are open: close all four ends, then free, before raise.
        _ = external_call["close", Int32](opipe[0])
        _ = external_call["close", Int32](opipe[1])
        _ = external_call["close", Int32](epipe[0])
        _ = external_call["close", Int32](epipe[1])
        _free_build(owned^, argv, opipe, epipe, xpipe)
        raise Error("exec: pipe2() for errno channel failed")
    var o_r = opipe[0]
    var o_w = opipe[1]
    var e_r = epipe[0]
    var e_w = epipe[1]
    var x_r = xpipe[0]
    var x_w = xpipe[1]

    # The busy-exec retry timespec, built in the PARENT so the child touches no
    # allocator: [0..1] is the req (tv_sec, tv_nsec), [2..3] is scratch for the
    # nanosleep `rem` out-parameter. The child reads its own copy-on-write copy;
    # the parent frees its copy right after the fork (separate address spaces).
    var nap = alloc[Int64](4)
    nap[0] = 0
    nap[1] = _ETXTBSY_SLEEP_NS
    nap[2] = 0
    nap[3] = 0

    var start = _mono_ms()
    var pid = external_call["fork", Int32]()
    if pid < 0:
        # All six pipe ends are open: close every one, then free, before raising.
        _ = external_call["close", Int32](o_r)
        _ = external_call["close", Int32](o_w)
        _ = external_call["close", Int32](e_r)
        _ = external_call["close", Int32](e_w)
        _ = external_call["close", Int32](x_r)
        _ = external_call["close", Int32](x_w)
        nap.free()
        _free_build(owned^, argv, opipe, epipe, xpipe)
        raise Error("exec: fork() failed")

    if pid == 0:
        # CHILD: async-signal-safe calls only, on pre-built pointers.
        _ = external_call["setpgid", Int32](Int32(0), Int32(0))
        if has_cwd:
            if external_call["chdir", Int32](cwd_cstr) != 0:
                _child_fail_errno(x_w)
                external_call["_exit", NoneType](Int32(127))
        _ = external_call["dup2", Int32](o_w, Int32(1))
        _ = external_call["dup2", Int32](e_w, Int32(2))
        _ = external_call["close", Int32](o_r)
        _ = external_call["close", Int32](o_w)
        _ = external_call["close", Int32](e_r)
        _ = external_call["close", Int32](e_w)
        _ = external_call["close", Int32](x_r)
        _ = external_call["execvp", Int32](arg0, argv)
        # Exec failed. A freshly built binary can transiently be ETXTBSY (text
        # file busy) when exec'd right after it was written and closed. Sleep
        # briefly and retry exec within a bounded window before reporting the
        # failure. Async-signal-safe: only nanosleep/execvp here, and the sleep
        # timespec was built by the parent (no allocation in the child). A
        # successful retried execvp never returns, so this costs time only in the
        # rare busy window — the common first-exec-succeeds path is untouched.
        var eloc = external_call[
            "__errno_location", UnsafePointer[Int32, MutUntrackedOrigin]
        ]()
        var tries = 0
        while Int(eloc[0]) == _ETXTBSY and tries < _ETXTBSY_MAX_RETRIES:
            _ = external_call["nanosleep", Int32](
                nap.bitcast[UInt8](), (nap + 2).bitcast[UInt8]()
            )
            _ = external_call["execvp", Int32](arg0, argv)
            tries += 1
        # Still failing: report the final errno through the errno pipe.
        _child_fail_errno(x_w)
        external_call["_exit", NoneType](Int32(127))

    # PARENT.
    # Also set the child's process group from the parent to close the group-kill
    # startup race: if the deadline fires in the microseconds before the child
    # runs its own setpgid(0,0), kill(-pid, SIGTERM) would hit a group that does
    # not exist yet. Doing it here makes the group exist from the parent's view
    # immediately. Ignore the return — a post-exec race yields EACCES/ESRCH
    # harmlessly, and the child's setpgid(0,0) remains authoritative (the
    # belt-and-suspenders POSIX idiom).
    _ = external_call["setpgid", Int32](pid, Int32(0))
    _ = external_call["close", Int32](o_w)
    _ = external_call["close", Int32](e_w)
    _ = external_call["close", Int32](x_w)
    # The child holds its own copy-on-write copy of the retry timespec; the parent
    # never reads it again, so free the parent's copy now.
    nap.free()

    var ebuf = alloc[Int32](1)
    ebuf[0] = 0
    var status = alloc[Int32](1)
    status[0] = 0

    # Shared deadline/interrupt state, carried from the pre-exec resolution below
    # into the supervision loop: a stall in EITHER phase is governed by the same
    # deadline, and a timed-out latch set here survives into the final verdict.
    var killing = False
    var escalated = False
    var timed_out = False
    var kill_time = 0

    # Resolve spawn-failed vs exec-ran WITHOUT blocking. The errno pipe delivers
    # 4 bytes on failure or a close-on-exec EOF when exec runs; a BLOCKING read
    # here would hang forever if the child stalls between fork and exec, and with
    # SA_RESTART on the handlers neither the deadline nor Ctrl-C could break it.
    # So make it non-blocking and fold it into the deadline/interrupt loop:
    # accumulate up to 4 errno bytes, or observe EOF, re-checking the deadline
    # and the interrupt latch every slice. A stuck pre-exec child is group-killed
    # on timeout/interrupt just like a stuck running one.
    _ = external_call["fcntl", Int32](x_r, Int32(_F_SETFL), Int32(_O_NONBLOCK))
    var xpfd = alloc[UInt8](8)
    memset_zero(xpfd, 8)
    _pfd_set(xpfd, 0, x_r)
    var egot = 0
    var spawn_failed = False
    while True:
        var now = _mono_ms()
        if not killing:
            if interrupt_requested() or (
                spec.timeout_ms > 0 and (now - start) >= spec.timeout_ms
            ):
                _ = external_call["kill", Int32](
                    Int32(-Int(pid)), Int32(_SIGTERM)
                )
                killing = True
                timed_out = True
                kill_time = now
        else:
            if not escalated and (now - kill_time) >= _GRACE_MS:
                _ = external_call["kill", Int32](
                    Int32(-Int(pid)), Int32(_SIGKILL)
                )
                escalated = True

        var n = external_call["read", Int](
            x_r, ebuf.bitcast[UInt8]() + egot, Int(4 - egot)
        )
        if n > 0:
            # A 4-byte errno write is atomic (<= PIPE_BUF), so this normally
            # completes in one read; accumulate defensively regardless.
            egot += Int(n)
            if egot >= 4:
                spawn_failed = True
                break
            continue
        if n == 0:
            # Close-on-exec EOF: exec ran (or the child is already gone).
            break
        # EAGAIN: nothing resolved yet — wait a slice, bounding deadline lag.
        _ = external_call["poll", Int32](xpfd, UInt64(1), Int32(_POLL_SLICE_MS))
    xpfd.free()
    _ = external_call["close", Int32](x_r)

    if spawn_failed:
        # The child already _exit(127)'d, so a blocking reap returns at once.
        _ = external_call["waitpid", Int32](pid, status, Int32(0))
        _ = external_call["close", Int32](o_r)
        _ = external_call["close", Int32](e_r)
        var dur = _mono_ms() - start
        if timed_out:
            # A deadline or an interrupt fired DURING the busy-exec retry window
            # and group-killed us, yet the child then exhausted its retries and
            # reported the exec errno. Our own kill won the race, so the run
            # LATCHES to TimedOut regardless of that errno — exactly as the
            # running-child latch site below does; final_* retains the reaped
            # death. The session disambiguates a real timeout from an interrupt
            # via the interrupt flag, so this one check restores BOTH precedences
            # (the interrupt one is the load-bearing exit-2 guarantee).
            var final = _decode(Int(status[0]))
            var term = Termination.timed_out(final.kind, final.value, escalated)
            _free_all(owned^, argv, opipe, epipe, xpipe, ebuf, status)
            return ProcessResult(
                List[UInt8](), List[UInt8](), False, False, term, dur
            )
        # No latch fired: a genuine spawn failure — report the child's errno.
        var errno = Int(ebuf[0])
        _free_all(owned^, argv, opipe, epipe, xpipe, ebuf, status)
        return ProcessResult(
            List[UInt8](),
            List[UInt8](),
            False,
            False,
            Termination.spawn_failed(errno),
            dur,
        )

    # Exec succeeded: supervise the running child.
    _ = external_call["fcntl", Int32](o_r, Int32(_F_SETFL), Int32(_O_NONBLOCK))
    _ = external_call["fcntl", Int32](e_r, Int32(_F_SETFL), Int32(_O_NONBLOCK))

    var out_cap = BoundedCapture(head_cap, tail_cap)
    var err_cap = BoundedCapture(head_cap, tail_cap)
    var buf = alloc[UInt8](_BUFSIZE)

    var pfd = alloc[UInt8](16)
    memset_zero(pfd, 16)
    _pfd_set(pfd, 0, o_r)
    _pfd_set(pfd, 1, e_r)

    var o_open = True
    var e_open = True

    while True:
        var r = external_call["waitpid", Int32](pid, status, Int32(_WNOHANG))
        if Int(r) == Int(pid):
            # `status` now holds the reaped child's real status word.
            break
        if Int(r) < 0:
            # With SIGCHLD forced to SIG_DFL our child IS reapable, so this is
            # not "already gone" — it is machinery failure. EINTR is retryable.
            # Anything else (ECHILD or otherwise) means we can never learn the
            # child's real fate, and decoding the still-zero status word would be
            # a false Exited(0) PASS. Group-clean and report a spawn-failure
            # sentinel instead: the session routes it to the internal-error exit
            # (exit 3), which covers reap-side machinery failure too. A non-status
            # must never become an Exited/Signaled outcome.
            var errno = _errno()
            if errno == _EINTR:
                continue
            _ = external_call["kill", Int32](Int32(-Int(pid)), Int32(_SIGKILL))
            _ = external_call["close", Int32](o_r)
            _ = external_call["close", Int32](e_r)
            var dur = _mono_ms() - start
            var oz = out_cap.finish()
            var ez = err_cap.finish()
            buf.free()
            pfd.free()
            _free_all(owned^, argv, opipe, epipe, xpipe, ebuf, status)
            return ProcessResult(
                oz^,
                ez^,
                out_cap.was_truncated(),
                err_cap.was_truncated(),
                Termination.spawn_failed(errno),
                dur,
            )

        var now = _mono_ms()
        if not killing:
            if interrupt_requested() or (
                spec.timeout_ms > 0 and (now - start) >= spec.timeout_ms
            ):
                _ = external_call["kill", Int32](
                    Int32(-Int(pid)), Int32(_SIGTERM)
                )
                killing = True
                timed_out = True
                kill_time = now
        else:
            if not escalated and (now - kill_time) >= _GRACE_MS:
                _ = external_call["kill", Int32](
                    Int32(-Int(pid)), Int32(_SIGKILL)
                )
                escalated = True

        # Wait for I/O, or sleep the slice if both streams are already at EOF.
        _ = external_call["poll", Int32](pfd, UInt64(2), Int32(_POLL_SLICE_MS))
        if o_open and _pfd_revents(pfd, 0) != 0:
            if _drain(o_r, buf, out_cap):
                o_open = False
                _pfd_disable(pfd, 0)
        if e_open and _pfd_revents(pfd, 1) != 0:
            if _drain(e_r, buf, err_cap):
                e_open = False
                _pfd_disable(pfd, 1)

    # Child reaped. Sweep the rest of its process group FIRST, before draining. A
    # grandchild the child forked outlives the reaped leader and is a leaked
    # resource we own via the group; the timeout/interrupt path already
    # group-kills, but a NORMAL exit would otherwise leave it running — and a
    # grandchild flooding the inherited stdout pipe would keep `read` returning
    # data forever, so a drain-to-EOF BEFORE the kill would never terminate.
    # Killing the group closes the grandchild's write ends, so the drain that
    # follows is guaranteed to reach EOF. The leader's own output is already in
    # the kernel pipe buffer (it wrote it before exiting) and SIGKILL does not
    # discard buffered pipe bytes, so the post-kill drain still captures it. This
    # is cleanup ONLY: the reported status stays the leader's real fate — the
    # sweep never turns a normal exit into TimedOut. Done promptly, before any
    # later fork, so the pgid cannot have been reused.
    _ = external_call["kill", Int32](Int32(-Int(pid)), Int32(_SIGKILL))

    # Now drain whatever remains without blocking. With the group killed every
    # write end is closed, so each `_drain` reaches EOF in a bounded number of
    # reads; the quiet-grandchild and no-grandchild cases finish in the first
    # iteration. The iteration cap is defensive belt-and-suspenders: draining
    # after the sweep always converges to EOF.
    var drains = 0
    while (o_open or e_open) and drains < _MAX_POSTREAP_DRAINS:
        var rc = external_call["poll", Int32](pfd, UInt64(2), Int32(0))
        if Int(rc) <= 0:
            break
        var progressed = False
        if o_open and _pfd_revents(pfd, 0) != 0:
            if _drain(o_r, buf, out_cap):
                o_open = False
                _pfd_disable(pfd, 0)
            progressed = True
        if e_open and _pfd_revents(pfd, 1) != 0:
            if _drain(e_r, buf, err_cap):
                e_open = False
                _pfd_disable(pfd, 1)
            progressed = True
        if not progressed:
            break
        drains += 1

    _ = external_call["close", Int32](o_r)
    _ = external_call["close", Int32](e_r)

    var dur = _mono_ms() - start
    var raw = Int(status[0])
    var term: Termination
    if timed_out:
        # The deadline/interrupt kill LATCHES: TimedOut regardless of how the
        # child then died. final_* retains the actual death.
        var final = _decode(raw)
        term = Termination.timed_out(final.kind, final.value, escalated)
    else:
        term = _decode(raw)

    var out_bytes = out_cap.finish()
    var err_bytes = err_cap.finish()
    buf.free()
    pfd.free()
    _free_all(owned^, argv, opipe, epipe, xpipe, ebuf, status)
    return ProcessResult(
        out_bytes^,
        err_bytes^,
        out_cap.was_truncated(),
        err_cap.was_truncated(),
        term,
        dur,
    )


def _drain(
    fd: Int32,
    buf: UnsafePointer[UInt8, MutUntrackedOrigin],
    mut cap: BoundedCapture,
) -> Bool:
    """Read available bytes from `fd` into `cap` (non-blocking), bounded per call.

    Returns True iff EOF was reached (read returned 0). Returns False when either
    no more data is available right now (EAGAIN, read < 0) OR the per-call read
    cap is hit with data still flowing — both mean "not EOF, re-poll". Bounding
    the reads keeps a continuously flooding fd from spinning this call forever, so
    the caller always regains control to re-check the deadline and interrupt.
    Mutates `cap`; does not raise.
    """
    var chunks = 0
    while chunks < _MAX_DRAIN_CHUNKS:
        var n = external_call["read", Int](fd, buf, Int(_BUFSIZE))
        if n == 0:
            return True
        if n < 0:
            return False
        for i in range(n):
            cap.push_byte(buf[i])
        chunks += 1
    # Cap reached with data still available: not EOF — let the caller re-poll.
    return False


def _pfd_set(pfd: UnsafePointer[UInt8, MutUntrackedOrigin], i: Int, fd: Int32):
    """Set pollfd entry `i` to watch `fd` for POLLIN. Pure."""
    pfd.bitcast[Int32]()[i * 2] = fd
    pfd.bitcast[Int16]()[i * 4 + 2] = _POLLIN


def _pfd_disable(pfd: UnsafePointer[UInt8, MutUntrackedOrigin], i: Int):
    """Disable pollfd entry `i` (fd = -1 is ignored by poll). Pure."""
    pfd.bitcast[Int32]()[i * 2] = Int32(-1)


def _pfd_revents(
    pfd: UnsafePointer[UInt8, MutUntrackedOrigin], i: Int
) -> Int16:
    """The revents of pollfd entry `i`. Pure."""
    return pfd.bitcast[Int16]()[i * 4 + 3]


def _free_build(
    var owned: List[_CStr],
    argv: UnsafePointer[_CStr, MutUntrackedOrigin],
    opipe: UnsafePointer[Int32, MutUntrackedOrigin],
    epipe: UnsafePointer[Int32, MutUntrackedOrigin],
    xpipe: UnsafePointer[Int32, MutUntrackedOrigin],
):
    """Free the pre-fork build allocations: the argv/cstr copies and the three
    pipe fd arrays. Used both on the machinery-failure raise paths (before ebuf/
    status exist) and, via `_free_all`, on the success paths. Pure."""
    for i in range(len(owned)):
        owned[i].free()
    argv.free()
    opipe.free()
    epipe.free()
    xpipe.free()


def _free_all(
    var owned: List[_CStr],
    argv: UnsafePointer[_CStr, MutUntrackedOrigin],
    opipe: UnsafePointer[Int32, MutUntrackedOrigin],
    epipe: UnsafePointer[Int32, MutUntrackedOrigin],
    xpipe: UnsafePointer[Int32, MutUntrackedOrigin],
    ebuf: UnsafePointer[Int32, MutUntrackedOrigin],
    status: UnsafePointer[Int32, MutUntrackedOrigin],
):
    """Free every heap allocation made for one supervised run. Pure."""
    _free_build(owned^, argv, opipe, epipe, xpipe)
    ebuf.free()
    status.free()
