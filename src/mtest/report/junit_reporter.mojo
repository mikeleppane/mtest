"""The stateful JUnit reporter and its per-suite fragment spool (Layer 2).

Where `junit` is the PURE renderer (typed suite state -> XML), this is the
stateful shell around it: a `Reporter` that accumulates the typed state each
event carries, renders one `<testsuite>` fragment as each file finishes, and
SPOOLS that fragment to a session temp directory (one file per suite) so the
runner's memory never holds every rendered suite at once. The final document is
built by `assemble`, which reads the spooled fragments back in node-id order and
wraps them in the `<testsuites>` root — a clean entry point the serving task
(the `--junit-xml` destination/finalize/atomic-rename protocol) will call, and
which tests drive end to end.

Every fact the reporter renders comes from the typed event payloads — never a
parse of the human console text and never a session side channel. The sentinel
matrix is decided from `attempts_used`, the file outcome, and whether any
per-test row carries a failing outcome:

- `[attempts]` exists iff `attempts_used > 1` — it carries the whole attempt
  story (a flaky pass's `flakyFailure`s, a rerun-exhausted failure's Surefire
  chronology with the FIRST failed attempt as the primary and every later
  attempt as a rerun, or a retried per-test failure's prior attempts as reruns).
- `[build]` exists iff `attempts_used <= 1` AND the failing outcome is
  file-level (no per-test row carries it).
- The two are mutually exclusive by construction — exactly one outcome sentinel
  per suite, or none when per-test rows carry the verdict.

A precompile failure emits its own `mtest::precompile` suite plus one `[not-run]`
suite per NAMED casualty; a bare casualty COUNT with no names invents no rows.

`handle` is TOTAL and NON-RAISING per the `Reporter` seam: the only fallible
step is the fragment file write, which is wrapped and latched (like the JSON
stream reporter), after which the reporter goes silent. An INERT reporter (the
no-`--junit-xml` shape) owns no spool directory and does nothing.
"""
from std.ffi import external_call
from std.os import remove
from std.os.path import basename, dirname

from mtest.model.events import Event, EventKind
from mtest.model.outcome import Outcome
from mtest.model.test_result import TestResult
from mtest.report.junit import (
    JunitCase,
    JunitPrimary,
    JunitRerun,
    JunitSuite,
    RenderedSuite,
    assemble,
    bounded_text_from_bytes,
    dotted_classname,
    render_suite,
)
from mtest.report.reporter import Reporter

# Decomposed exec-layer termination kinds (as carried on the events).
comptime _TERM_EXITED = 0
comptime _TERM_SIGNALED = 1
comptime _TERM_TIMED_OUT = 2
comptime _TERM_SPAWN_FAILED = 3


def _junit_nonce() -> String:
    """A per-process token isolating this run's JUnit spool and temp paths.

    Two mtest PROCESSES writing the same `--junit-xml PATH` (plausible under
    `--shard`) must never collide on a temp path one's finalize is renaming or a
    spool dir one's cleanup would delete. The process id is stable within a run
    and distinct across concurrent runs, so it keys each invocation's disposable
    paths apart. Never raises.
    """
    # SAFETY: `getpid` takes no arguments and returns this process's id as an
    # Int32; there is nothing to misuse and the call cannot fail.
    var pid = external_call["getpid", Int32]()
    return String(Int(pid))


def _cstring(value: String) -> List[UInt8]:
    """An owned NUL-terminated byte copy of `value`, for one libc call."""
    var out = List[UInt8]()
    for b in value.as_bytes():
        out.append(b)
    out.append(0)
    return out^


def _rename(src: String, dst: String) raises:
    """Atomically rename `src` onto `dst`, replacing `dst` if it exists.

    The report layer performs its own libc calls (as `json_stream_reporter` does
    for `write`/`open`/`close`) rather than reaching up into `exec`, so the
    reporter stays self-contained. Both paths share a filesystem (the caller
    derives `src` from `dst`'s directory), so `rename(2)` is indivisible: on
    success `dst` names what `src` named; on failure NEITHER path is modified —
    the whole reason the JUnit artifact is renamed and not written in place.

    Raises:
        Error: if `rename(2)` failed (the target is a directory, straddles
            filesystems, or its directory became unwritable).
    """
    var s = _cstring(src)
    var d = _cstring(dst)
    # SAFETY: libc rename has the exact `int rename(const char*, const char*)`
    # ABI. Both arguments are complete NUL-terminated byte copies this function
    # uniquely owns; the borrowed pointers stay valid for the whole synchronous
    # call (both lists are used again below), and rename retains neither pointer
    # and writes through neither. The result is a plain scalar status.
    var rc = external_call["rename", Int32](s.unsafe_ptr(), d.unsafe_ptr())
    _ = s^
    _ = d^
    if rc != 0:
        raise Error(
            "report: junit rename failed: '" + src + "' -> '" + dst + "'"
        )


@fieldwise_init
struct JunitArtifact(Copyable, Movable):
    """The resolved `--junit-xml` destination handles, proven writable at start.

    `spool_dir` is a fresh session temp directory for the per-suite fragments;
    `temp_path` is the unique temp FILE created in the TARGET directory (its
    creation PROVES that directory writable now), the assembled document is
    written to it at finalization, and it is renamed atomically onto
    `target_path`. Owns its Strings; never raises.
    """

    var spool_dir: String
    """The session temp directory the per-suite fragments are spooled into."""
    var temp_path: String
    """The unique temp file in the target dir; the final document lands here."""
    var target_path: String
    """The `--junit-xml` PATH the temp is atomically renamed onto."""


def open_junit_artifact(
    spool_dir: String, path: String
) raises -> JunitArtifact:
    """Resolve the JUnit destination and PROVE the target directory writable.

    Creates a unique temp FILE in the TARGET directory (dirname(`path`)) at
    session start — its creation proves the directory writable NOW, before any
    build or run, so a doomed report destination fails fast rather than after a
    whole run. The prior report at `path` is NEVER touched here (or anywhere
    before the final atomic rename). Raises on a creation failure — the caller
    resolves that to the pre-run internal-error exit code.

    Args:
        spool_dir: The already-created session temp directory for fragments.
        path: The `--junit-xml` destination PATH.

    Raises:
        Error: if the unique temp file cannot be created (the target directory
            is unwritable or missing).
    """
    var target_dir = String(dirname(path))
    var temp_name = (
        "." + String(basename(path)) + ".mtest-" + _junit_nonce() + ".tmp"
    )
    var temp_path: String
    if target_dir != "":
        temp_path = target_dir + "/" + temp_name
    else:
        temp_path = temp_name
    # Prove writability by creating (truncating) the unique temp file now.
    with open(temp_path, "w") as f:
        f.write("")
    return JunitArtifact(spool_dir, temp_path, path)


@fieldwise_init
struct JunitFinalizeResult(Copyable, Movable):
    """The outcome of finalizing the JUnit artifact: a failure flag + diagnostic.

    `failed` is True when the report could not be published (a latched spool, a
    failed assemble, temp write, or atomic rename); `detail` is the loud
    diagnostic the session surfaces. An inert or clean finalize is `failed=False`
    with an empty `detail`.
    """

    var failed: Bool
    """Whether finalization could not publish the report."""
    var detail: String
    """The loud diagnostic when `failed`; empty when clean."""


@fieldwise_init
struct _Diag(Copyable, Movable):
    """A derived outcome descriptor: element class, `type`, message, and body.
    """

    var is_error: Bool
    """Whether this counts as an `<error>` (else a `<failure>`)."""
    var type_label: String
    """The `type` attribute value."""
    var message: String
    """The `message` attribute value."""
    var stack: String
    """The primary body / rerun `stackTrace` text."""


@fieldwise_init
struct _AttemptRec(Copyable, Movable):
    """One non-final retry attempt's typed record, kept until the file finishes.
    """

    var term_kind: Int
    var term_value: Int
    var escalated: Bool
    var stdout_text: String
    var stderr_text: String


@fieldwise_init
struct _FileAccum(Copyable, Movable):
    """The per-file state accumulated between FileStarted and FileFinished."""

    var path: String
    var tests: List[TestResult]
    var attempts: List[_AttemptRec]


@fieldwise_init
struct _SpoolEntry(Copyable, Movable):
    """One spooled suite's order key, on-disk fragment path, and counts."""

    var suite_key: String
    var file_path: String
    var tests: Int
    var failures: Int
    var errors: Int
    var skipped: Int


@fieldwise_init
struct JunitStatus(Copyable, Movable):
    """The pollable health of a `JunitReporter`'s spool.

    `failed` latches on the first fragment-write failure; `context` names what
    was being spooled when it tripped. An owner treats a latched spool as a
    fatal artifact condition, exactly as it does the JSON stream's latch.
    """

    var failed: Bool
    """Whether a fragment write has failed and the reporter gone silent."""
    var context: String
    """What was being spooled when the latch tripped ("" when clean)."""


def _blank_primary() -> JunitPrimary:
    """A primary placeholder for a row that carries no primary outcome child."""
    return JunitPrimary("", "", "", "")


def _bound_str(s: String) -> String:
    """Bound a runner/child-authored string the same way captured bytes are."""
    var b = List[UInt8]()
    for x in s.as_bytes():
        b.append(x)
    return bounded_text_from_bytes(b)


def _attempt_diag(a: _AttemptRec) -> _Diag:
    """The derived descriptor for one non-final attempt's termination. Pure."""
    if a.term_kind == _TERM_SIGNALED:
        var m = "killed by signal " + String(a.term_value)
        if a.escalated:
            m += " (escalated to SIGKILL)"
        return _Diag(True, "Signal", m, "signal " + String(a.term_value))
    if a.term_kind == _TERM_TIMED_OUT:
        return _Diag(True, "Timeout", "timed out", "timed out")
    if a.term_kind == _TERM_SPAWN_FAILED:
        return _Diag(
            True,
            "SpawnError",
            "spawn failed",
            "spawn failed (errno " + String(a.term_value) + ")",
        )
    return _Diag(
        False,
        "ExitFailure",
        "exited with status " + String(a.term_value),
        "exit status " + String(a.term_value),
    )


def _outcome_diag(e: Event, stderr_text: String) -> _Diag:
    """The derived descriptor for a file's FINAL failing outcome. Pure."""
    var o = e.outcome
    if o == Outcome.FAIL:
        var body = stderr_text if stderr_text != "" else String(
            "exited with status " + String(e.exit_status)
        )
        return _Diag(
            False,
            "Failure",
            "exited with status " + String(e.exit_status),
            body,
        )
    if o == Outcome.CRASH:
        var m = "killed by signal " + String(e.signal_number)
        if e.escalated:
            m += " (escalated to SIGKILL)"
        return _Diag(True, "Crash", m, "signal " + String(e.signal_number))
    if o == Outcome.TIMEOUT:
        return _Diag(
            True,
            "Timeout",
            "timed out after " + String(e.timeout_seconds) + "s",
            "timed out",
        )
    if o == Outcome.COMPILE_ERROR:
        return _Diag(True, "CompileError", "build failed", stderr_text)
    if o == Outcome.COMPILE_TIMEOUT:
        return _Diag(
            True, "CompileTimeout", "build timed out", "build timed out"
        )
    if o == Outcome.MALFORMED_SUITE:
        return _Diag(
            True, "MalformedSuite", "malformed test report", stderr_text
        )
    return _Diag(True, "Error", "run error", stderr_text)


def _primary_from(d: _Diag) -> JunitPrimary:
    """A primary `<error>`/`<failure>` from a descriptor. Pure."""
    var el = String("error") if d.is_error else String("failure")
    return JunitPrimary(el, d.message, d.type_label, d.stack)


def _rerun_from(
    d: _Diag, flaky: Bool, sout: String, serr: String
) -> JunitRerun:
    """A rerun/flaky child from a descriptor. Pure; `type` always rides."""
    var el: String
    if flaky:
        el = String("flakyError") if d.is_error else String("flakyFailure")
    else:
        el = String("rerunError") if d.is_error else String("rerunFailure")
    return JunitRerun(el, d.message, d.type_label, d.stack, sout, serr)


def _case_for_test(t: TestResult, cn: String) -> JunitCase:
    """One per-test `<testcase>` row from a typed result. Pure.

    A FAIL carries its verbatim assertion detail as a `<failure>`; a CRASH an
    `<error>`; a SKIP a bare `<skipped/>`; every other outcome is a passing row.
    """
    var name = t.node.render()
    if t.outcome == Outcome.FAIL:
        return JunitCase(
            name,
            cn,
            True,
            JunitPrimary("failure", "", "AssertionError", _bound_str(t.detail)),
            List[JunitRerun](),
        )
    if t.outcome == Outcome.CRASH:
        return JunitCase(
            name,
            cn,
            True,
            JunitPrimary("error", "", "CrashError", _bound_str(t.detail)),
            List[JunitRerun](),
        )
    if t.outcome == Outcome.SKIP:
        return JunitCase(
            name,
            cn,
            True,
            JunitPrimary("skipped", "", "", ""),
            List[JunitRerun](),
        )
    return JunitCase(name, cn, False, _blank_primary(), List[JunitRerun]())


def _is_failing_test(t: TestResult) -> Bool:
    """Whether a per-test row carries a failing verdict the suite need not
    re-carry via a sentinel."""
    return t.outcome == Outcome.FAIL or t.outcome == Outcome.CRASH


struct JunitReporter(Reporter):
    """A `Reporter` that spools one `<testsuite>` fragment per finished file.

    Accumulates per-file typed state, renders and spools each suite as its file
    finishes, and assembles the node-id-sorted document on demand. `handle` is
    total and non-raising; a fragment-write failure latches the reporter silent.
    An inert reporter owns no spool directory and does nothing. `Copyable,
    Movable` (owns Strings and Lists) so it slots into the reporter composition.
    """

    var _active: Bool
    """Whether this reporter spools at all; `False` is the no-`--junit-xml` shape.
    """
    var _spool_dir: String
    """The session temp directory the per-suite fragments are written to."""
    var _counter: Int
    """A monotonic counter minting a unique fragment filename per suite."""
    var _index: List[_SpoolEntry]
    """One entry per spooled suite: order key, fragment path, and counts."""
    var _accums: List[_FileAccum]
    """The in-flight per-file accumulators, keyed by path."""
    var _failed: Bool
    """The latch: set on the first fragment-write failure, then `handle` no-ops.
    """
    var _context: String
    """What was being spooled when the latch tripped ("" while clean)."""
    var _target_path: String
    """The `--junit-xml` PATH the assembled document is renamed onto ("" when
    inert or under a test driver that never finalizes)."""
    var _temp_path: String
    """The unique temp file the assembled document is written to before the
    atomic rename onto `_target_path` ("" when inert)."""

    def __init__(
        out self,
        spool_dir: String,
        active: Bool,
        target_path: String = "",
        temp_path: String = "",
    ):
        """Construct a reporter that spools fragments into `spool_dir`.

        Args:
            spool_dir: An existing, writable session temp directory the
                per-suite fragments are written to.
            active: Whether to spool; `False` yields an inert reporter that owns
                no directory and does nothing.
            target_path: The `--junit-xml` PATH the finalized document is
                atomically renamed onto; empty leaves `finalize` a no-op (a test
                driver that only drives `assemble` never sets it).
            temp_path: The unique temp file the document is written to before the
                rename; empty leaves `finalize` a no-op.
        """
        self._active = active
        self._spool_dir = spool_dir
        self._counter = 0
        self._index = List[_SpoolEntry]()
        self._accums = List[_FileAccum]()
        self._failed = False
        self._context = String("")
        self._target_path = target_path
        self._temp_path = temp_path

    @staticmethod
    def inert() -> Self:
        """The no-`--junit-xml` reporter: owns no directory, does nothing."""
        return Self("", False)

    def note_not_run(mut self, selected_paths: List[String]):
        """Synthesize a `[not-run]` suite for each selected file never spooled.

        Called by the session at the terminal protocol's Phase 1 (outside the
        `Reporter` trait) so an interrupted, gate-aborted, or `--maxfail`-capped
        run STILL carries a `[not-run]` skipped row for every selected file that
        never produced a verdict. A file whose real verdict already spooled a
        suite — a ran file, a deselected file, or a precompile casualty — is
        already in the index and is skipped here, so no suite is ever doubled.
        Total; never raises (the spool write is caught and latched like `handle`).
        """
        if not self._active or self._failed:
            return
        for i in range(len(selected_paths)):
            if self._failed:
                return
            var path = selected_paths[i]
            if self._has_suite(path):
                continue
            var cases = List[JunitCase]()
            cases.append(
                JunitCase(
                    "[not-run]",
                    dotted_classname(path),
                    True,
                    JunitPrimary("skipped", "not run", "", ""),
                    List[JunitRerun](),
                )
            )
            var suite = JunitSuite(path, 0.0, cases^, "", "")
            self._spool(render_suite(suite), "not-run suite " + path)

    def _has_suite(self, suite_key: String) -> Bool:
        """Whether a suite with `suite_key` has already been spooled."""
        for i in range(len(self._index)):
            if self._index[i].suite_key == suite_key:
                return True
        return False

    def finalize(mut self) -> JunitFinalizeResult:
        """Publish the JUnit artifact: assemble -> temp write -> atomic rename.

        Called by the SESSION on the concrete reporter (outside the `Reporter`
        trait) at the terminal protocol's Phase 1. NON-RAISING: every failure is
        caught and returned as a loud diagnostic the session collects.

        The deliberate asymmetry vs the JSON stream: a spool-write failure does
        NOT abort the run mid-flight (unlike a latched stream, a fatal abort) —
        it rode silently to here and surfaces NOW as a finalization failure. On a
        clean spool the fragments are assembled in node-id order, written to the
        unique temp (a verified complete write), and renamed atomically onto the
        target. The prior report at the target is never truncated: on ANY failure
        the target is left exactly as it was and the temp is cleaned up.
        """
        if not self._active or self._target_path == "":
            return JunitFinalizeResult(False, "")
        if self._failed:
            return JunitFinalizeResult(
                True,
                "junit spool failed while writing " + self._context,
            )
        try:
            var doc = self.assemble("mtest")
            with open(self._temp_path, "w") as f:
                f.write(doc)
            _rename(self._temp_path, self._target_path)
        except e:
            self._discard_temp()
            return JunitFinalizeResult(
                True, "junit report could not be written: " + String(e)
            )
        return JunitFinalizeResult(False, "")

    def _discard_temp(mut self):
        """Best-effort remove of the leftover temp file after a failed publish.
        """
        try:
            remove(self._temp_path)
        except:
            pass

    def handle(mut self, e: Event):
        """Consume one event, spooling a suite as each file/precompile finishes.

        Total over the event set; never raises. Accumulation is in-memory list
        work; only the fragment write is fallible, and it is caught and latched
        so a dead spool never propagates out of the seam.
        """
        if not self._active or self._failed:
            return
        if e.kind == EventKind.FILE_STARTED:
            self._reset_accum(e.path)
            return
        if e.kind == EventKind.TEST_REPORTED:
            var idx = self._ensure_accum(e.path)
            self._accums[idx].tests.append(e.test.copy())
            return
        if e.kind == EventKind.ATTEMPT_FINISHED:
            var idx = self._ensure_accum(e.path)
            self._accums[idx].attempts.append(
                _AttemptRec(
                    e.term_kind,
                    e.term_value,
                    e.escalated,
                    bounded_text_from_bytes(e.captured_stdout),
                    bounded_text_from_bytes(e.captured_stderr),
                )
            )
            return
        if e.kind == EventKind.FILE_FINISHED:
            self._finish_file(e)
            return
        if e.kind == EventKind.PRECOMPILE_FAILED:
            self._finish_precompile(e)
            return

    def status(self) -> JunitStatus:
        """The pollable latch state — callable OUTSIDE the `Reporter` trait."""
        return JunitStatus(self._failed, self._context)

    def suite_count(self) -> Int:
        """How many suite fragments have been spooled so far."""
        return len(self._index)

    def spool_dir(self) -> String:
        """The session temp directory the per-suite fragments are written to."""
        return self._spool_dir.copy()

    def assemble(self, root_name: String) raises -> String:
        """Read the spooled fragments back and build the full document.

        The clean assembly entry point: reads each per-suite fragment from the
        spool, orders them by node id, and wraps them in the `<testsuites>` root
        (root totals summed, no root `skipped`). The serving task calls this to
        produce the artifact; tests call it to validate end to end.

        Args:
            root_name: The `<testsuites>` `name` (e.g. `"mtest"`).

        Returns:
            The complete `<testsuites>` document.

        Raises:
            Error: if a spooled fragment cannot be read back.
        """
        var frags = List[RenderedSuite]()
        for i in range(len(self._index)):
            var entry = self._index[i].copy()
            var body: String
            with open(entry.file_path, "r") as f:
                body = f.read()
            frags.append(
                RenderedSuite(
                    entry.suite_key.copy(),
                    body^,
                    entry.tests,
                    entry.failures,
                    entry.errors,
                    entry.skipped,
                )
            )
        return assemble(root_name, frags)

    def _accum_index(self, path: String) -> Int:
        """The index of `path`'s accumulator, or -1 if none exists yet."""
        for i in range(len(self._accums)):
            if self._accums[i].path == path:
                return i
        return -1

    def _ensure_accum(mut self, path: String) -> Int:
        """The index of `path`'s accumulator, creating an empty one if absent.
        """
        var idx = self._accum_index(path)
        if idx >= 0:
            return idx
        self._accums.append(
            _FileAccum(path.copy(), List[TestResult](), List[_AttemptRec]())
        )
        return len(self._accums) - 1

    def _reset_accum(mut self, path: String):
        """Begin a fresh accumulator for `path`, discarding any stale one."""
        var idx = self._accum_index(path)
        if idx >= 0:
            self._accums[idx].tests = List[TestResult]()
            self._accums[idx].attempts = List[_AttemptRec]()
            return
        self._accums.append(
            _FileAccum(path.copy(), List[TestResult](), List[_AttemptRec]())
        )

    def _drop_accum(mut self, path: String):
        """Remove `path`'s accumulator once its suite has been rendered."""
        var idx = self._accum_index(path)
        if idx >= 0:
            _ = self._accums.pop(idx)

    def _finish_file(mut self, e: Event):
        """Render and spool the suite for one finished file (or drop it)."""
        # Selection-induced absences carry no suite at all.
        if e.outcome == Outcome.EXCLUDED or e.outcome == Outcome.DESELECTED:
            self._drop_accum(e.path)
            return
        var idx = self._ensure_accum(e.path)
        var suite = self._suite_for_file(e, idx)
        self._drop_accum(e.path)
        self._spool(render_suite(suite), "suite " + e.path)

    def _suite_for_file(self, e: Event, accum_idx: Int) -> JunitSuite:
        """Build the typed suite for a finished file from its accumulator."""
        var cn = dotted_classname(e.path)
        var cases = List[JunitCase]()

        if e.outcome == Outcome.NOT_RUN:
            cases.append(
                JunitCase(
                    "[not-run]",
                    cn,
                    True,
                    JunitPrimary("skipped", "not run", "", ""),
                    List[JunitRerun](),
                )
            )
            return JunitSuite(e.path, e.duration_seconds, cases^, "", "")

        var failing_test_rows = 0
        for i in range(len(self._accums[accum_idx].tests)):
            var t = self._accums[accum_idx].tests[i].copy()
            if _is_failing_test(t):
                failing_test_rows += 1
            cases.append(_case_for_test(t, cn))

        if e.attempts_used > 1:
            if not e.outcome.is_failing():
                cases.append(self._attempts_flaky(cn, accum_idx))
            elif failing_test_rows > 0:
                cases.append(self._attempts_pertest(cn, accum_idx))
            else:
                cases.append(self._attempts_filelevel(cn, accum_idx, e))
        elif e.outcome.is_failing() and failing_test_rows == 0:
            var d = _outcome_diag(e, bounded_text_from_bytes(e.captured_stderr))
            cases.append(
                JunitCase(
                    "[build]", cn, True, _primary_from(d), List[JunitRerun]()
                )
            )

        var sout = bounded_text_from_bytes(e.captured_stdout)
        var serr = bounded_text_from_bytes(e.captured_stderr)
        return JunitSuite(e.path, e.duration_seconds, cases^, sout, serr)

    def _attempts_flaky(self, cn: String, accum_idx: Int) -> JunitCase:
        """The `[attempts]` row for a flaky pass: one `<flakyFailure>` per failed
        attempt, in attempt order, each with its own bounded diagnostics.

        Flaky children are `flakyFailure` (not `flakyError`): the file's final
        verdict is a PASS, so the earlier attempts are reported as flaky
        annotations, each carrying the REQUIRED `type` from that attempt's
        termination — they never count against the suite's failures/errors."""
        var reruns = List[JunitRerun]()
        for i in range(len(self._accums[accum_idx].attempts)):
            var a = self._accums[accum_idx].attempts[i].copy()
            var d = _attempt_diag(a)
            reruns.append(
                JunitRerun(
                    "flakyFailure",
                    d.message,
                    d.type_label,
                    d.stack,
                    a.stdout_text,
                    a.stderr_text,
                )
            )
        return JunitCase("[attempts]", cn, False, _blank_primary(), reruns^)

    def _attempts_pertest(self, cn: String, accum_idx: Int) -> JunitCase:
        """The `[attempts]` row for retried per-test failures: prior attempts as
        reruns, no primary of its own (the per-test rows carry the verdict)."""
        var reruns = List[JunitRerun]()
        for i in range(len(self._accums[accum_idx].attempts)):
            var a = self._accums[accum_idx].attempts[i].copy()
            var d = _attempt_diag(a)
            reruns.append(_rerun_from(d, False, a.stdout_text, a.stderr_text))
        return JunitCase("[attempts]", cn, False, _blank_primary(), reruns^)

    def _attempts_filelevel(
        self, cn: String, accum_idx: Int, e: Event
    ) -> JunitCase:
        """The `[attempts]` row for a rerun-exhausted file-level failure.

        Surefire chronology: the FIRST failed attempt is the primary; every
        subsequent failed attempt, the final one included, is a rerun in attempt
        order. When no non-final attempts were captured, the final outcome is the
        primary and there are no reruns.
        """
        var n = len(self._accums[accum_idx].attempts)
        var final_d = _outcome_diag(
            e, bounded_text_from_bytes(e.captured_stderr)
        )
        if n == 0:
            return JunitCase(
                "[attempts]",
                cn,
                True,
                _primary_from(final_d),
                List[JunitRerun](),
            )
        var reruns = List[JunitRerun]()
        for i in range(1, n):
            var a = self._accums[accum_idx].attempts[i].copy()
            var d = _attempt_diag(a)
            reruns.append(_rerun_from(d, False, a.stdout_text, a.stderr_text))
        reruns.append(_rerun_from(final_d, False, "", ""))
        var first_d = _attempt_diag(self._accums[accum_idx].attempts[0])
        return JunitCase(
            "[attempts]", cn, True, _primary_from(first_d), reruns^
        )

    def _finish_precompile(mut self, e: Event):
        """Emit the precompile suite plus one not-run suite per named casualty.

        The `mtest::precompile` suite carries a `[precompile]` error; each named
        casualty gets its own `[not-run]` suite. A bare casualty COUNT with no
        names invents no casualty rows — the degenerate case renders only the
        precompile suite.
        """
        var cn = dotted_classname("mtest::precompile")
        var msg = String("precompile failed (" + e.step + ")")
        var pcases = List[JunitCase]()
        pcases.append(
            JunitCase(
                "[precompile]",
                cn,
                True,
                JunitPrimary(
                    "error",
                    msg,
                    "PrecompileError",
                    _bound_str(e.compiler_output),
                ),
                List[JunitRerun](),
            )
        )
        var psuite = JunitSuite("mtest::precompile", 0.0, pcases^, "", "")
        self._spool(render_suite(psuite), "suite mtest::precompile")

        var not_run_msg = String("not run: precompile failed (" + e.step + ")")
        for i in range(len(e.casualties)):
            if self._failed:
                return
            var path = e.casualties[i]
            var ccases = List[JunitCase]()
            ccases.append(
                JunitCase(
                    "[not-run]",
                    dotted_classname(path),
                    True,
                    JunitPrimary("skipped", not_run_msg, "", ""),
                    List[JunitRerun](),
                )
            )
            var csuite = JunitSuite(path, 0.0, ccases^, "", "")
            self._spool(render_suite(csuite), "suite " + path)

    def _spool(mut self, r: RenderedSuite, context: String):
        """Write one rendered fragment to the spool, latching on any failure."""
        var path = self._spool_dir + "/suite-" + String(self._counter) + ".xml"
        self._counter += 1
        try:
            with open(path, "w") as f:
                f.write(r.body)
        except:
            self._latch(context)
            return
        self._index.append(
            _SpoolEntry(
                r.suite_key.copy(),
                path,
                r.tests,
                r.failures,
                r.errors,
                r.skipped,
            )
        )

    def _latch(mut self, context: String):
        """Record the first fragment-write failure and go silent."""
        if not self._failed:
            self._failed = True
            self._context = context.copy()
