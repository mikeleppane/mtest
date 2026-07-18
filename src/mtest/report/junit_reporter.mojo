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

    def __init__(out self, spool_dir: String, active: Bool):
        """Construct a reporter that spools fragments into `spool_dir`.

        Args:
            spool_dir: An existing, writable session temp directory the
                per-suite fragments are written to.
            active: Whether to spool; `False` yields an inert reporter that owns
                no directory and does nothing.
        """
        self._active = active
        self._spool_dir = spool_dir
        self._counter = 0
        self._index = List[_SpoolEntry]()
        self._accums = List[_FileAccum]()
        self._failed = False
        self._context = String("")

    @staticmethod
    def inert() -> Self:
        """The no-`--junit-xml` reporter: owns no directory, does nothing."""
        return Self("", False)

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
