"""The stateful JUnit reporter and its per-suite fragment spool.

Where `junit` is the pure renderer (typed suite state to XML), this is the
stateful shell around it: a `Reporter` that accumulates the typed state each
event carries, renders one `<testsuite>` fragment as each file finishes, and
spools that fragment to a session temp directory, one file per suite, so the
runner's memory never holds every rendered suite at once. The final document is
built by `assemble`, which reads the spooled fragments back in suite-key order
and wraps them in the `<testsuites>` root.

Every fact the reporter renders comes from the typed event payloads, never a
parse of the human console text and never a session side channel. The sentinel
matrix is decided from `attempts_used`, the file outcome, and whether any
per-test row carries a failing outcome:

- `[attempts]` exists exactly when `attempts_used > 1`. It carries the whole
  attempt story: a flaky pass's `flakyFailure`s, a rerun-exhausted failure's
  Surefire chronology with the first failed attempt as the primary and every
  later attempt as a rerun, or a retried per-test failure's prior attempts as
  reruns.
- `[build]` exists exactly when `attempts_used <= 1` and the failing outcome is
  file-level, meaning no per-test row carries it.
- The two are mutually exclusive by construction: exactly one outcome sentinel
  per suite, or none when per-test rows carry the verdict.

A precompile failure emits its own `mtest::precompile` suite plus one
`[not-run]` suite per named casualty; a bare casualty count with no names
invents no rows.

`handle` is total and non-raising per the `Reporter` seam. The only fallible
step is the fragment file write, which is wrapped and latched as in the JSON
stream reporter, after which the reporter goes silent. An inert reporter, the
no-`--junit-xml` shape, owns no spool directory and does nothing.
"""
from std.ffi import external_call
from std.os import getenv, mkdir, remove
from std.os.path import basename, dirname
from std.time import perf_counter_ns

from mtest.model.events import Event, EventKind
from mtest.model.outcome import Outcome
from mtest.model.test_result import TestResult
from mtest.platform import process_id
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

# How many distinct spool-directory names one call may try before giving up.
# Every candidate re-reads the nanosecond clock, so a repeat needs two readings
# to land on the same nanosecond; the budget therefore guards against an
# unusable temp base rather than a collision rate.
comptime _SPOOL_ATTEMPTS = 64


def _junit_nonce() -> String:
    """A per-process token isolating this run's JUnit spool and temp paths.

    Two mtest processes writing the same `--junit-xml PATH`, which `--shard`
    makes plausible, must never collide on a temp path one's finalize is
    renaming or a spool dir one's cleanup would delete. The process id is stable
    within a run and distinct across concurrent runs, so it keys each
    invocation's disposable paths apart.

    Returns:
        The process id, rendered in decimal.
    """
    return String(process_id())


def open_junit_spool() raises -> String:
    """Create and return this run's private temp directory for suite fragments.

    Deliberately avoids `std.tempfile.mkdtemp`: at the pinned toolchain its
    candidate-name generator is unseeded, so every process walks the same name
    sequence. In a shared `/tmp` those exact names already exist from earlier
    runs, mkdtemp exhausts its internal attempts, and `--junit-xml` dies before
    a single test is built.

    The key here is instead a monotonic nanosecond reading taken fresh on every
    attempt, with `mkdir`'s own atomic exclusive create as the arbiter, under a
    `mtest-junit-<pid>-` prefix that ties a stray directory back to the run that
    left it. The pid alone cannot be the key: pids recur across pid namespaces
    and after wraparound, so a fixed per-pid stem walked in index order would
    have to step over every leftover a previous same-pid run abandoned, which
    against a persisted `/tmp` reproduces the budget exhaustion this function
    exists to remove. A re-read clock cannot be walked into again.

    Honors `TMPDIR`, then `TEMP`, then `TMP`, falling back to `/tmp` — the same
    precedence `gettempdir()` applies behind the `mkdtemp()` this replaces, so
    confining a run's scratch keeps working exactly as it did before.

    Returns:
        The path of the freshly created, empty directory, mode 0o700. The
        caller owns it and is responsible for removing it.

    Raises:
        Error: When no candidate could be created within the attempt budget,
            because the temp base is missing, is not a directory, or is
            unwritable. The message carries the last underlying failure
            verbatim, since every one of those causes burns the whole budget
            identically and only the errno text tells them apart. The caller
            resolves this to the pre-run internal-error exit code.
    """
    var base = getenv("TMPDIR", "")
    if base == "":
        base = getenv("TEMP", "")
    if base == "":
        base = getenv("TMP", "")
    if base == "":
        base = String("/tmp")
    if base.byte_length() > 1 and base.endswith("/"):
        base = String(base.removesuffix("/"))
    var stem = base + "/mtest-junit-" + _junit_nonce() + "-"
    # Seeded so the raise below is always well-formed; the budget is positive,
    # so a real failure always overwrites this.
    var last = String("no attempt was made")
    for attempt in range(_SPOOL_ATTEMPTS):
        var candidate = stem + String(perf_counter_ns()) + "-" + String(attempt)
        try:
            mkdir(candidate, 0o700)
        except e:
            last = String(e)
            continue
        return candidate^
    raise Error(
        "report: could not create a junit spool directory under '"
        + base
        + "' ("
        + String(_SPOOL_ATTEMPTS)
        + " attempts; last: "
        + last
        + ")"
    )


def _cstring(value: String) -> List[UInt8]:
    """An owned NUL-terminated byte copy of `value`, for one libc call."""
    var out = List[UInt8]()
    for b in value.as_bytes():
        out.append(b)
    out.append(0)
    return out^


def _rename(src: String, dst: String) raises:
    """Atomically rename `src` onto `dst`, replacing `dst` if it exists.

    The report layer performs its own libc calls, as `json_stream_reporter` does
    for `write`/`open`/`close`, rather than reaching up into `exec`, so the
    reporter stays self-contained. Both paths share a filesystem because the
    caller derives `src` from `dst`'s directory, so `rename(2)` is indivisible:
    on success `dst` names what `src` named, and on failure neither path is
    modified. That is why the JUnit artifact is renamed rather than written in
    place.

    Args:
        src: The existing temp file to rename.
        dst: The path to replace.

    Raises:
        Error: When `rename(2)` failed, because the target is a directory,
            straddles filesystems, or its directory became unwritable.
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

    `spool_dir` is a fresh session temp directory for the per-suite fragments.
    `temp_path` is the unique temp file created in the target directory, and
    creating it is what proves that directory writable. The assembled document
    is written to `temp_path` at finalization, then renamed atomically onto
    `target_path`.
    """

    var spool_dir: String
    """The session temp directory the per-suite fragments are spooled into."""
    var temp_path: String
    """The unique temp file in the target dir; the final document lands here."""
    var target_path: String
    """The `--junit-xml` path the temp is atomically renamed onto."""


def open_junit_artifact(
    spool_dir: String, path: String
) raises -> JunitArtifact:
    """Resolve the JUnit destination and prove the target directory writable.

    Creates a unique temp file in `dirname(path)` at session start. Creating it
    proves the directory writable before any build or run, so a doomed report
    destination fails fast rather than after a whole run. The prior report at
    `path` is not touched here, nor anywhere before the final atomic rename.

    Args:
        spool_dir: The already-created session temp directory for fragments.
        path: The `--junit-xml` destination path.

    Returns:
        The resolved destination handles.

    Raises:
        Error: When the unique temp file cannot be created, because the target
            directory is unwritable or missing. The caller resolves this to the
            pre-run internal-error exit code.
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
    """The outcome of finalizing the JUnit artifact: a failure flag plus detail.

    `failed` is True when the report could not be published, whether from a
    latched spool, a failed assemble, a failed temp write, or a failed atomic
    rename; `detail` is the diagnostic the session surfaces. An inert or clean
    finalize is `failed=False` with an empty `detail`.
    """

    var failed: Bool
    """Whether finalization could not publish the report."""
    var detail: String
    """The diagnostic when `failed`; empty when clean."""


@fieldwise_init
struct _Diag(Copyable, Movable):
    """A derived outcome descriptor: element class, `type`, message, and body.
    """

    var is_error: Bool
    """Whether this counts as an `<error>` rather than a `<failure>`."""
    var type_label: String
    """The `type` attribute value."""
    var message: String
    """The `message` attribute value."""
    var stack: String
    """The primary body, or the rerun `stackTrace` text."""


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

    `failed` latches on the first fragment-write failure, and `context` names
    what was being spooled when it tripped. An owner treats a latched spool as
    a fatal artifact condition, as it does the JSON stream's latch.
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
    """The derived descriptor for one non-final attempt's termination."""
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
    """The derived descriptor for a file's final failing outcome."""
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
    """A primary `<error>`/`<failure>` from a descriptor."""
    var el = String("error") if d.is_error else String("failure")
    return JunitPrimary(el, d.message, d.type_label, d.stack)


def _rerun_from(
    d: _Diag, flaky: Bool, sout: String, serr: String
) -> JunitRerun:
    """A rerun/flaky child from a descriptor; `type` always rides along."""
    var el: String
    if flaky:
        el = String("flakyError") if d.is_error else String("flakyFailure")
    else:
        el = String("rerunError") if d.is_error else String("rerunFailure")
    return JunitRerun(el, d.message, d.type_label, d.stack, sout, serr)


def _case_for_test(t: TestResult, cn: String) -> JunitCase:
    """One per-test `<testcase>` row from a typed result.

    A FAIL carries its verbatim assertion detail as a `<failure>`, a CRASH as an
    `<error>`, and a SKIP as a bare `<skipped/>`. Every other outcome yields a
    passing row.
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
    """Whether a per-test row already carries the failing verdict, so the suite
    needs no outcome sentinel for it."""
    return t.outcome == Outcome.FAIL or t.outcome == Outcome.CRASH


struct JunitReporter(Reporter):
    """A `Reporter` that spools one `<testsuite>` fragment per finished file.

    Accumulates per-file typed state, renders and spools each suite as its file
    finishes, and assembles the suite-key-sorted document on demand. A
    fragment-write failure latches the reporter silent. An inert reporter owns
    no spool directory and does nothing.
    """

    var _active: Bool
    """Whether this reporter spools at all; `False` is the inert shape."""
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
    """The `--junit-xml` path the assembled document is renamed onto; empty when
    inert, or under a test driver that never finalizes."""
    var _temp_path: String
    """The unique temp file the assembled document is written to before the
    atomic rename onto `_target_path`; empty when inert."""

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
            target_path: The `--junit-xml` path the finalized document is
                atomically renamed onto. Empty leaves `finalize` a no-op, which
                is what a test driver that only drives `assemble` wants.
            temp_path: The unique temp file the document is written to before
                the rename. Empty leaves `finalize` a no-op.
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

        Called by the session during terminal finalization, outside the
        `Reporter` trait, so an interrupted, gate-aborted, or `--maxfail`-capped
        run still carries a `[not-run]` skipped row for every selected file that
        never produced a verdict. A file that already spooled a suite — because
        it ran, or was a precompile casualty — is in the index and is skipped
        here, so no suite is ever doubled. Deselected and excluded files never
        spool a suite at all and so are never in the index; keeping them out of
        the report is the caller's job, and the session passes only the files
        that reached no verdict.

        The spool write is caught and latched as in `handle`.

        Args:
            selected_paths: The selected files that must appear in the report.
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
        """Publish the JUnit artifact: assemble, write the temp, rename it.

        Called by the session on the concrete reporter, outside the `Reporter`
        trait, during terminal finalization. Every failure is caught and
        returned as a diagnostic the session collects.

        This is deliberately asymmetric with the JSON stream. A latched stream
        aborts the run mid-flight; a spool-write failure does not, and instead
        rides silently to here and surfaces as a finalization failure. On a
        clean spool the fragments are assembled in suite-key order, written to
        the unique temp, and renamed atomically onto the target.

        The prior report at the target is never truncated: on any failure the
        target is left exactly as it was. Temp cleanup is narrower — a failure
        assembling or writing the temp removes it, but a run that arrives here
        with an already-latched spool failure returns without touching the temp
        the session created, so that empty temp outlives the run.

        Returns:
            A clean result when inert or published, otherwise the failure flag
            and its diagnostic.
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
        """Remove the leftover temp file after a failed publish, best-effort."""
        try:
            remove(self._temp_path)
        except:
            pass

    def handle(mut self, e: Event):
        """Consume one event, spooling a suite as each file/precompile finishes.

        Accumulation is in-memory list work; only the fragment write is
        fallible, and it is caught and latched so a dead spool never propagates
        out of the seam.

        Args:
            e: The event to consume.
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
        """The pollable latch state; callable outside the `Reporter` trait."""
        return JunitStatus(self._failed, self._context)

    def suite_count(self) -> Int:
        """How many suite fragments have been spooled so far."""
        return len(self._index)

    def spool_dir(self) -> String:
        """The session temp directory the per-suite fragments are written to."""
        return self._spool_dir.copy()

    def assemble(self, root_name: String) raises -> String:
        """Read the spooled fragments back and build the full document.

        Reads each per-suite fragment from the spool, orders them by suite key,
        and wraps them in the `<testsuites>` root, with the root totals summed
        and no root `skipped`.

        Args:
            root_name: The `<testsuites>` `name`, for example `"mtest"`.

        Returns:
            The complete `<testsuites>` document.

        Raises:
            Error: When a spooled fragment cannot be read back.
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
        """The index of `path`'s accumulator, creating one if absent."""
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
        """The `[attempts]` row for a flaky pass.

        Carries one `<flakyFailure>` per failed attempt, in attempt order, each
        with its own bounded diagnostics.

        Flaky children are always `flakyFailure`, never `flakyError`. The file's
        final verdict is a pass, so earlier attempts are reported as flaky
        annotations that never count against the suite's failures or errors,
        each carrying the schema-required `type` from that attempt's
        termination."""
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
        reruns, with no primary of its own, since the per-test rows carry the
        verdict."""
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

        Surefire chronology: the first failed attempt is the primary, and every
        subsequent failed attempt, the final one included, is a rerun in attempt
        order. When no non-final attempts were captured, the final outcome is
        the primary and there are no reruns.
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

        The `mtest::precompile` suite carries a `[precompile]` error, and each
        named casualty gets its own `[not-run]` suite. A bare casualty count
        with no names invents no casualty rows, so that degenerate case renders
        only the precompile suite.
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
