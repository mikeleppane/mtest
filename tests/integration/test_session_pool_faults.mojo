"""Live pool machinery faults, driven through the isolated native adapter.

Each case injects ONE named fault at ONE dispatch or cleanup boundary of a real
`workers=2` batch over real built-and-executed fixtures, and pins what the
session owes its caller: a non-interrupt machinery fault resolves to exit 3,
stops new scheduling, tears every live process group down, emits at most one
truthful internal error naming the boundary that actually failed, and accounts
the exact remainder NOT-RUN. An already-latched interrupt still outranks a
cleanup fault: exit 2, never 3.

The faults are occurrence-based, so each case is written so the named boundary
is the counted occurrence. In particular the run-dispatch case uses `workers=2`
with exactly ONE run file: the pool dispatches that file's build first, waits
for it, and only then dispatches its run. A second run file would make the next
occurrence another build and fault the wrong boundary.

The build cache moves that arithmetic, because an enabled cache spawns one child
of its own before any file is dispatched — `<compiler> --version`, the key's
toolchain-version frame. Each case below therefore states which count it is
using and why:

- The two dispatch cases count that child. It is exactly one stdout-pipe open,
  always the first, so the boundary they want is simply one occurrence later.
- The `wait_any` case turns the cache OFF instead. Its counted operation is the
  blocking multiplex, and `run_supervised` polls the `--version` child until it
  exits — a count that depends on how fast the compiler answers, not on the
  batch. Faulting an occurrence chosen against that would be a coin flip.
"""
from std.ffi import external_call
from std.os.path import exists
from std.testing import assert_equal, assert_true, TestSuite

from mtest.exec import ExecRuntime
from mtest.exec.signals import _reset_interrupt
from mtest.model import (
    EventKind,
    InternalErrorPayload,
    Outcome,
    SessionFinishedPayload,
)
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_session

from cache_fixtures import dir_listing
from session_fixtures import SRC_PASS, base_config, temp_root, write_file

comptime _READY = "pool_fault_ready"
"""The readiness file the SIGTERM-ignoring sibling drops in the invocation root.
"""

# A sibling that survives the SIGTERM pass: it installs `SIG_IGN` for SIGTERM,
# announces its own readiness, and then holds. A trigger that waits for that
# readiness therefore cannot settle before this group is live, which is what
# forces `kill_all` to have a group to tear down and so to consume the injected
# `GROUP_TERM` occurrence.
comptime _SRC_SIGTERM_IGNORING_HOLD = (
    "from std.ffi import external_call\n"
    "from std.time import sleep\n\n\n"
    "def main() raises:\n"
    "    # SAFETY: `signal(SIGTERM, SIG_IGN)` passes the constant 1 in the\n"
    "    # handler slot, which is exactly SIG_IGN's ABI value; nothing is\n"
    "    # dereferenced and no ownership crosses the boundary.\n"
    '    _ = external_call["signal", Int](Int(15), Int(1))\n'
    '    with open("'
    + _READY
    + '", "w") as f:\n        f.write("1")\n    sleep(30.0)\n'
)

# A gate that waits for the sibling's readiness, then fails for real. Settling
# only after the sibling is live is what puts a live group under the gate abort's
# `kill_all`.
comptime _SRC_GATE_WAITS_THEN_FAILS = (
    "from std.os.path import exists\n"
    "from std.testing import TestSuite, assert_true\n"
    "from std.time import sleep\n\n\n"
    "def test_gate_fails() raises:\n"
    "    assert_true(False)\n\n\n"
    "def main() raises:\n"
    "    for _ in range(2000):\n"
    '        if exists("'
    + _READY
    + '"):\n'
    "            break\n"
    "        sleep(0.01)\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)

# A trigger that waits for the sibling's readiness, then interrupts the RUNNER
# itself and holds. The interrupt therefore arrives with a live sibling group,
# so the interrupt-driven teardown must consume the injected `GROUP_TERM`
# occurrence — and must still resolve to exit 2, never to the cleanup fault's 3.
comptime _SRC_INTERRUPT_TRIGGER = (
    "from std.ffi import external_call\n"
    "from std.os.path import exists\n"
    "from std.time import sleep\n\n\n"
    "def main() raises:\n"
    "    for _ in range(2000):\n"
    '        if exists("'
    + _READY
    + '"):\n'
    "            break\n"
    "        sleep(0.01)\n"
    "    # SAFETY: `getppid` takes no argument and `kill` takes two scalars;\n"
    "    # the runner that spawned this child is its parent by construction,\n"
    "    # and no pointer or ownership crosses either boundary.\n"
    '    var parent = Int(external_call["getppid", Int32]())\n'
    '    _ = external_call["kill", Int32](Int32(parent), Int32(2))\n'
    "    sleep(30.0)\n"
)

comptime _EIO = 5
"""The errno every injected adapter fault reports."""
comptime _OP_PIPE_STDOUT = 11
"""`MTEST_EXEC_OP_PIPE_STDOUT`: the child's stdout pipe, opened per dispatch."""
comptime _OP_GROUP_TERM = 32
"""`MTEST_EXEC_OP_GROUP_TERM`: the SIGTERM pass over one live process group."""
comptime _OP_POLL_SET = 36
"""`MTEST_EXEC_OP_POLL_SET`: the one blocking multiplex inside `wait_any`."""
comptime _FIRST_BUILD_OPEN = 2
"""Which stdout-pipe open is the pool's FIRST build dispatch.

Occurrence 1 belongs to the cache's `<compiler> --version` child, which every
enabled session spawns before it dispatches anything. The cases using this
constant assert the faulted STEP as well, so a miscount fails loudly instead of
quietly measuring the wrong boundary.
"""
comptime _FIRST_RUN_OPEN = 3
"""Which stdout-pipe open is the RUN dispatch of a ONE-file pooled batch.

`<compiler> --version`, then that file's build, then its run.
"""
comptime _STORE_DIR = ".mtest-cache/build-v1"
"""The store's generations directory, relative to a run root."""


def _reset_faults():
    """Clear the isolated testing adapter's native fault table."""
    # SAFETY: this test-only ABI takes no pointer, retains nothing, and mutates
    # only the testing adapter's single-threaded fault configuration.
    external_call["mtest_exec_test_fault_reset", NoneType]()


def _configure_fault(operation: Int, occurrence: Int, error_number: Int) raises:
    """Fail one occurrence of one native adapter operation.

    Args:
        operation: The `MTEST_EXEC_OP_*` discriminator to fault.
        occurrence: Which visit to that operation fails, counting from 1.
        error_number: The errno the faulted operation reports.

    Raises:
        Error: When the testing adapter rejects the configuration.
    """
    # SAFETY: the test-only ABI takes scalar discriminators only; all three are
    # exact enum/errno/count constants and no pointer or state escapes the call.
    var result = external_call["mtest_exec_test_fault_configure", Int32](
        UInt32(operation), UInt32(occurrence), Int32(error_number), Int64(0)
    )
    assert_equal(result, Int32(0), "could not configure native fault")


def _fault_seen(operation: Int) -> Int:
    """How many visits the adapter counted for one configured operation."""
    # SAFETY: the test-only ABI takes one scalar discriminator, returns a
    # counter by value, and retains nothing.
    return Int(
        external_call["mtest_exec_test_fault_seen", UInt32](UInt32(operation))
    )


def _no_live_children() -> Bool:
    """Whether the runner process has no child left, live or merely reapable.

    The two-pass teardown kills every process group it owns and reaps every
    leader, so after a fault-driven teardown `waitpid` must find nothing at all.

    Returns:
        True when `waitpid` reports no child remains.
    """
    var status = Int32(0)
    # SAFETY: `waitpid(-1, &status, WNOHANG)` is the standard non-blocking
    # existence probe. `status` is a live local for the whole call, the callee
    # writes at most one `int` through the pointer, WNOHANG guarantees the call
    # never blocks, and nothing is retained past the return; the result is -1
    # (ECHILD) exactly when no child remains.
    var reaped = external_call["waitpid", Int32](
        Int32(-1), UnsafePointer(to=status), Int32(1)
    )
    return Int(reaped) == -1


def _recorder() -> RecordingCoordinator[RecordingReporter]:
    """A coordinator whose console slot is a single recorder."""
    return RecordingCoordinator(CompositeReporter(Tuple(RecordingReporter())))


def _kinds(rec: RecordingReporter) -> List[EventKind]:
    """The recorded event kinds in emission order, without ephemeral PROGRESS.

    PROGRESS ticks are throttled on wall-clock and on the in-flight signature,
    so their count is a property of the host rather than of the run. Every other
    kind is deterministic, which is what a complete-sequence assertion pins.

    Args:
        rec: The recorder to read back.

    Returns:
        The retained kinds, in order. Allocates the returned list.
    """
    var out = List[EventKind]()
    for i in range(rec.count()):
        if rec.kind_at(i) != EventKind.PROGRESS:
            out.append(rec.kind_at(i))
    return out^


def _assert_kinds(
    rec: RecordingReporter, expected: List[EventKind], label: String
) raises:
    """Assert the recorded non-PROGRESS kind sequence equals `expected`.

    Args:
        rec: The recorder to read back.
        expected: The complete expected kind sequence.
        label: The case label reported on mismatch.

    Raises:
        Error: When the sequences differ in length or in any position.
    """
    var actual = _kinds(rec)
    assert_equal(len(actual), len(expected), label + ": event count")
    for i in range(len(expected)):
        assert_true(
            actual[i] == expected[i],
            label + ": event " + String(i) + " has the wrong kind",
        )


def _internal_error(rec: RecordingReporter) raises -> InternalErrorPayload:
    """The single recorded `InternalError` payload.

    Args:
        rec: The recorder to read back.

    Returns:
        A copy of the one recorded internal-error payload.

    Raises:
        Error: When the recording holds no internal error or more than one.
    """
    var found = List[InternalErrorPayload]()
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.INTERNAL_ERROR:
            found.append(rec.event_at(i).data[InternalErrorPayload].copy())
    assert_equal(len(found), 1, "exactly one internal error is emitted")
    return found[0].copy()


def _finished(rec: RecordingReporter) raises -> SessionFinishedPayload:
    """The single recorded `SessionFinished` payload.

    Args:
        rec: The recorder to read back.

    Returns:
        A copy of the one recorded terminal payload.

    Raises:
        Error: When the recording does not hold exactly one terminal record.
    """
    var found = List[SessionFinishedPayload]()
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.SESSION_FINISHED:
            found.append(rec.event_at(i).data[SessionFinishedPayload].copy())
    assert_equal(len(found), 1, "exactly one SessionFinished is dispatched")
    return found[0].copy()


def _started_paths(rec: RecordingReporter) -> List[String]:
    """Every path that reached `FileStarted`, in dispatch order."""
    var out = List[String]()
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_STARTED:
            out.append(rec.path_at(i))
    return out^


def test_build_dispatch_open_fault_is_exit_3_with_every_file_not_run() raises:
    # `_FIRST_BUILD_OPEN` is the pool's FIRST build dispatch: only the cache's
    # `--version` child has been spawned before it, and no file has started.
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    write_file(root, "tests/test_c.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2

    var comp = _recorder()
    var code: Int
    _reset_faults()
    _configure_fault(_OP_PIPE_STDOUT, _FIRST_BUILD_OPEN, _EIO)
    # The fault table is process-global, so it is disarmed even if the session
    # raises; a surviving arming would corrupt every later case in this binary.
    try:
        code = run_session(config, root, comp)
    finally:
        _reset_faults()

    assert_equal(code, 3, "a build-dispatch machinery fault resolves to exit 3")
    ref rec = comp.composite.reporters[0]
    var expected = List[EventKind]()
    expected.append(EventKind.SESSION_STARTED)
    expected.append(EventKind.INTERNAL_ERROR)
    expected.append(EventKind.SESSION_FINISHED)
    _assert_kinds(rec, expected, "build dispatch open")

    # No file was ever started: the fault preceded the first FileStarted.
    assert_equal(len(_started_paths(rec)), 0)

    # The staging directory that dispatch had ALREADY claimed is swept. The
    # cache stages into the store before it spawns the compiler, so by the time
    # the stdout pipe fails there is a live `.tmp-<pid>-…` directory under the
    # store — and the fault tears the batch down without that build ever
    # reaching its completion handler, which is the one place a staged directory
    # is otherwise settled. Nothing in the tree sweeps `.tmp-` names afterwards,
    # so the batch's own terminal pass is the last chance to remove it, and this
    # is what proves that pass runs. A binary the run is still using is never at
    # risk: publication clears the batch's claim on all three outcomes,
    # including the failed one whose staged binary stays live.
    assert_equal(
        len(dir_listing(root + "/" + _STORE_DIR)),
        0,
        "a torn-down batch left its staging directory in the store",
    )

    var err = _internal_error(rec)
    assert_equal(err.step, "build", "the failed boundary is the build dispatch")
    assert_equal(err.program, config.mojo_path)
    assert_equal(
        err.errno, 0, "a machinery raise carries errno 0, not a spawn errno"
    )

    var fin = _finished(rec)
    assert_equal(fin.exit_code, 3)
    assert_equal(fin.summary.count_of(Outcome.NOT_RUN), 3)
    assert_equal(fin.summary.count_of(Outcome.PASS), 0)


def test_run_dispatch_open_fault_names_the_run_boundary_and_leaves_it_not_run() raises:
    # `workers=2` with exactly ONE run file: the pool dispatches that file's
    # build, waits for it, and only then dispatches its run, which is
    # `_FIRST_RUN_OPEN`. A second run file would make that occurrence another
    # build and fault the wrong boundary.
    #
    # The cache stays ON here, and this case is what pins where the pool
    # publishes. The build succeeded, so its staging directory was renamed onto
    # a generation BEFORE the run was dispatched — which is the only reason the
    # diagnostic below can name a path that still exists.
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2

    var comp = _recorder()
    var code: Int
    _reset_faults()
    _configure_fault(_OP_PIPE_STDOUT, _FIRST_RUN_OPEN, _EIO)
    try:
        code = run_session(config, root, comp)
    finally:
        _reset_faults()

    assert_equal(code, 3, "a run-dispatch machinery fault resolves to exit 3")
    ref rec = comp.composite.reporters[0]
    var expected = List[EventKind]()
    expected.append(EventKind.SESSION_STARTED)
    expected.append(EventKind.FILE_STARTED)
    expected.append(EventKind.INTERNAL_ERROR)
    expected.append(EventKind.SESSION_FINISHED)
    _assert_kinds(rec, expected, "run dispatch open")

    # Exactly the built file started; it never reached a verdict.
    var started = _started_paths(rec)
    assert_equal(len(started), 1)
    assert_equal(started[0], "tests/test_a.mojo")

    var err = _internal_error(rec)
    assert_equal(err.step, "run", "the failed boundary is the RUN dispatch")
    # A PREFIX match, not an exact path: the generation is named
    # `<mangled>_h<digest32>`, and that digest covers the toolchain, the
    # environment, the invocation root, and every include root's contents, so it
    # differs between machines, checkouts, and toolchain pins. What IS pinnable
    # is that the run dispatch names a published generation's binary — never the
    # compiler, and never the `.tmp-<pid>-...` staging directory, whose name
    # carries this process's pid and would be unassertable even if the seam
    # still used it here.
    assert_true(
        err.program.startswith(_STORE_DIR + "/tests_stest_ua_h")
        and err.program.endswith("/bin"),
        "the internal error must name the published generation's binary,"
        " not the compiler and not a staging path: "
        + err.program,
    )
    var entries = dir_listing(root + "/" + _STORE_DIR)
    assert_equal(
        len(entries),
        1,
        (
            "the store must hold exactly the one published generation, with no"
            " staging directory left beside it"
        ),
    )
    assert_equal(
        err.errno, 0, "a machinery raise carries errno 0, not a spawn errno"
    )

    var fin = _finished(rec)
    assert_equal(fin.exit_code, 3)
    assert_equal(fin.summary.count_of(Outcome.NOT_RUN), 1)
    assert_equal(fin.summary.count_of(Outcome.PASS), 0)


def test_wait_any_poll_fault_is_exit_3_and_leaves_no_live_group() raises:
    # Occurrence 1 of the shared multiplex is the pool's FIRST blocking sweep,
    # taken with both admitted builds in flight. The fault tears the Supervisor
    # down inside `wait_any`; the batch must abandon the rest rather than
    # dispatch the third file into a dead supervisor.
    #
    # `--no-cache` is what keeps "occurrence 1" meaningful. An enabled cache
    # runs `<compiler> --version` first, and `run_supervised` polls that child
    # until it exits — once on a fast answer, repeatedly on a slow one — so the
    # pool's first sweep would sit at an occurrence nobody can name in advance.
    # Nothing in this case is about the cache, so the honest fix is to take the
    # extra child out rather than guess at a count.
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    write_file(root, "tests/test_c.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2
    config.no_cache = True

    var comp = _recorder()
    var code: Int
    _reset_faults()
    _configure_fault(_OP_POLL_SET, 1, _EIO)
    try:
        code = run_session(config, root, comp)
    finally:
        _reset_faults()

    assert_equal(code, 3, "a wait-any machinery fault resolves to exit 3")
    # The teardown ran inside `wait_any`: every group it owned is reaped, so the
    # runner has no child left at all.
    assert_true(
        _no_live_children(),
        "the two-pass teardown must leave no surviving or unreaped child",
    )

    ref rec = comp.composite.reporters[0]
    var expected = List[EventKind]()
    expected.append(EventKind.SESSION_STARTED)
    expected.append(EventKind.FILE_STARTED)
    expected.append(EventKind.FILE_STARTED)
    expected.append(EventKind.SESSION_FINISHED)
    _assert_kinds(rec, expected, "wait-any poll")

    # The two admitted builds started; the third file was never dispatched, so
    # no new work was scheduled after the fault was observed.
    var started = _started_paths(rec)
    assert_equal(len(started), 2)
    assert_equal(started[0], "tests/test_a.mojo")
    assert_equal(started[1], "tests/test_b.mojo")

    var fin = _finished(rec)
    assert_equal(fin.exit_code, 3)
    assert_equal(fin.summary.count_of(Outcome.NOT_RUN), 3)
    assert_equal(fin.summary.count_of(Outcome.PASS), 0)


def test_gate_abort_cleanup_fault_escalates_over_the_gate_exit_1() raises:
    # The failing gate settles only after its SIGTERM-ignoring sibling is live,
    # so the gate abort's `kill_all` has a group to tear down and MUST consume
    # `GROUP_TERM` occurrence 1. A cleanup that cannot honestly tear the groups
    # down is a machinery fault, and exit 3 outranks the gate's own exit 1.
    var root = temp_root()
    write_file(root, "tests/test_gate_fail.mojo", _SRC_GATE_WAITS_THEN_FAILS)
    write_file(root, "tests/test_gate_hold.mojo", _SRC_SIGTERM_IGNORING_HOLD)
    write_file(root, "tests/test_run.mojo", SRC_PASS)

    var config = base_config()
    config.workers = 2
    config.timeout_secs = 60
    config.gates.append("tests/test_gate_fail.mojo")
    config.gates.append("tests/test_gate_hold.mojo")

    var comp = _recorder()
    var code: Int
    var term_visits: Int
    _reset_faults()
    _configure_fault(_OP_GROUP_TERM, 1, _EIO)
    try:
        code = run_session(config, root, comp)
        term_visits = _fault_seen(_OP_GROUP_TERM)
    finally:
        _reset_faults()

    # The readiness barrier in the failing gate has a bounded fallthrough, so
    # assert what it was there to guarantee: the marker exists only because the
    # sibling's RUN wrote it, which is the sole proof that the group `kill_all`
    # tore down was the SIGTERM-ignoring hold rather than a still-building
    # child. Without this the case silently degrades to faulting a build.
    assert_true(
        exists(root + "/" + _READY),
        "the SIGTERM-ignoring sibling must have reached its run",
    )
    # An exact count, not a floor: pass one of the two-pass cleanup issues one
    # TERM per live slot and pass two is GROUP_KILL, a different counted
    # operation, and an injected fault is never retried. The failing gate's slot
    # is finalized before the abort, so exactly ONE group is live here.
    assert_equal(
        term_visits,
        1,
        "the cleanup swept exactly the one live sibling group",
    )
    assert_equal(
        code, 3, "a cleanup machinery fault outranks the gate's own exit 1"
    )

    ref rec = comp.composite.reporters[0]
    var expected = List[EventKind]()
    expected.append(EventKind.SESSION_STARTED)
    expected.append(EventKind.FILE_STARTED)
    expected.append(EventKind.FILE_STARTED)
    expected.append(EventKind.TEST_REPORTED)
    expected.append(EventKind.FILE_FINISHED)
    expected.append(EventKind.SESSION_FINISHED)
    _assert_kinds(rec, expected, "gate-abort cleanup")

    # Both gates started; the run file was never dispatched.
    var started = _started_paths(rec)
    assert_equal(len(started), 2)
    assert_equal(started[0], "tests/test_gate_fail.mojo")
    assert_equal(started[1], "tests/test_gate_hold.mojo")

    var fin = _finished(rec)
    assert_equal(fin.exit_code, 3)
    assert_equal(fin.summary.count_of(Outcome.FAIL), 1)
    # The held gate and the never-dispatched run file are the exact remainder.
    assert_equal(fin.summary.count_of(Outcome.NOT_RUN), 2)
    assert_equal(fin.summary.count_of(Outcome.PASS), 0)


def test_interrupt_cleanup_fault_still_resolves_to_exit_2() raises:
    # The same live-sibling shape, but the teardown is driven by a real
    # interrupt the child delivers to the runner. The injected cleanup fault is
    # consumed exactly as above, yet a latched interrupt outranks it: exit 2,
    # never the cleanup fault's exit 3, with the same exact NOT-RUN accounting.
    #
    # Two teardown entry points can consume occurrence 1, depending on where the
    # signal lands relative to the pool's loop-top interrupt check: the pool's
    # own `kill_all` (the expected path, two live slots), or the Supervisor's
    # in-sweep `_initiate_kill`, which issues TERM before its blocking poll. The
    # second path raises out of `wait_any` with the pool's interrupt flag still
    # unset, so it would resolve to exit 3 and fail HERE — as a scheduling race,
    # not as a refutation of the precedence this case pins.
    var root = temp_root()
    write_file(root, "tests/test_a_hold.mojo", _SRC_SIGTERM_IGNORING_HOLD)
    write_file(root, "tests/test_b_signal.mojo", _SRC_INTERRUPT_TRIGGER)

    var config = base_config()
    config.workers = 2
    config.timeout_secs = 60

    var runtime = ExecRuntime()
    runtime.open()
    _reset_interrupt()
    var comp = _recorder()
    var code: Int
    var term_visits: Int
    _reset_faults()
    _configure_fault(_OP_GROUP_TERM, 1, _EIO)
    try:
        code = run_session(runtime, config, root, comp)
        term_visits = _fault_seen(_OP_GROUP_TERM)
    finally:
        # Process-global state, all of it: an armed fault table, a latched
        # interrupt, or an open runtime leaking out of a raising session would
        # corrupt every later case in this binary.
        _reset_faults()
        _reset_interrupt()
        runtime.close()

    # As in the gate case, the barrier's guarantee is asserted rather than
    # assumed: the trigger signals only after the sibling's RUN wrote this.
    assert_true(
        exists(root + "/" + _READY),
        "the SIGTERM-ignoring sibling must have reached its run",
    )
    # Exactly one TERM per live slot, and BOTH children are provably live when
    # the interrupt is observed: the trigger signals from inside its own run and
    # then holds, and the sibling holds for far longer.
    assert_equal(
        term_visits, 2, "the cleanup swept exactly the two live groups"
    )
    assert_equal(code, 2, "a latched interrupt outranks the cleanup fault")

    ref rec = comp.composite.reporters[0]
    var expected = List[EventKind]()
    expected.append(EventKind.SESSION_STARTED)
    expected.append(EventKind.FILE_STARTED)
    expected.append(EventKind.FILE_STARTED)
    expected.append(EventKind.SESSION_FINISHED)
    _assert_kinds(rec, expected, "interrupt cleanup")

    var started = _started_paths(rec)
    assert_equal(len(started), 2)
    assert_equal(started[0], "tests/test_a_hold.mojo")
    assert_equal(started[1], "tests/test_b_signal.mojo")

    var fin = _finished(rec)
    assert_equal(fin.exit_code, 2)
    assert_equal(fin.summary.count_of(Outcome.NOT_RUN), 2)
    assert_equal(fin.summary.count_of(Outcome.PASS), 0)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
