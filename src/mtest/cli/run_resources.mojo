"""Everything a configured run owns, and the one ladder that releases it.

Layer 5 owns this because the resources are taken as `main` composes the run —
the exec runtime, the machine-stream descriptor, the JUnit scratch, the
run-report scratch — and every exit path from there on has to release all of
them in one order under one precedence. `main` is the only caller, and it sits
inside this package for the import rules.

Nothing here prints or ends the process. `close_into` releases and then states
the code the caller should end on, together with the one diagnostic a failed
release produces; `main` decides what to do with both.
"""
from std.os import listdir, remove, rmdir

from mtest.exec import ExecRuntime
from mtest.model import EXIT_INTERNAL_ERROR, TerminalFacts, resolve_exit_code
from mtest.report import close_json_fd


@fieldwise_init
struct CloseOutcome(Copyable, Movable):
    """What one release ladder settled on."""

    var code: Int
    """The process exit code the run resolved to."""

    var diagnostic: String
    """The failed release to report, or empty when every release succeeded."""


@fieldwise_init
struct RunResources:
    """Everything a configured run owns, and the one ladder that releases it.

    `main` takes these resources at four different points: the exec runtime
    first, then the machine-stream descriptor, then the JUnit scratch, then the
    run-report scratch. Every exit path from there on has to release all of
    them, in one order, under one precedence. Holding them together is what
    lets `close_into` state that ladder once instead of once per exit path.

    A resource is recorded here at the moment ownership is actually taken, so
    an empty path or a false ownership flag means there is nothing to release.
    """

    var runtime: ExecRuntime
    """The process-global exec and signal state, owned from a successful open."""

    var json_fd: Int
    """The machine-stream descriptor; meaningful only when `json_owns_fd`."""

    var json_owns_fd: Bool
    """Whether `main` opened `json_fd` and so must close it.

    False under `--json -`, where the stream writes to the inherited stdout
    that `main` never opened and must not close.
    """

    var junit_spool: String
    """The JUnit spool directory `main` created, or "" when it owns none."""

    var junit_temp: String
    """The JUnit target temp file `main` created, or "" when it owns none."""

    var report_spool: String
    """The run-report spool directory `main` created, or "" when it owns none.
    """

    var report_md_temp: String
    """The Markdown report's target temp file, or "" when it owns none."""

    var report_md_fd: Int
    """The Markdown report temp's open descriptor, `-1` when the sink is off.

    Recorded for the record's sake, never closed here. The descriptor is LENT
    to `ReportWriter`, whose `finalize_reports` performs the one close; an abort
    path that skips finalize therefore leaks it into process teardown, exactly
    as the JUnit scratch path does today. Closing it here would be the second
    close of a descriptor number the kernel may already have handed to
    something else.
    """

    var report_html_temp: String
    """The HTML report's target temp file, or "" when it owns none."""

    var report_html_fd: Int
    """The HTML report temp's open descriptor, `-1` when the sink is off.

    Borrowed on exactly the terms `report_md_fd` documents.
    """

    def _discard_report_scratch(self):
        """Remove the run-report spool, its fragments, and any leftover temps.

        `main` owns this scratch: it created the spool with `open_report_spool`
        and one temp per active format with `create_unique_temp`, so it frees
        them once the session has finished with them. On success a temp has
        already been renamed onto its report target, so its removal is a no-op
        that never touches the published report; on failure the writer left it
        behind deliberately, and the prior report at the target is what survives.

        The fragments are removed before the directory holding them, because
        `rmdir` refuses a directory that still has entries and the spool would
        outlive the run.

        The descriptors are NOT closed here — see `report_md_fd`.

        Best-effort and non-raising, so it is safe on every error path and with
        empty or missing paths.
        """
        if self.report_md_temp != "":
            try:
                remove(self.report_md_temp)
            except:
                pass
        if self.report_html_temp != "":
            try:
                remove(self.report_html_temp)
            except:
                pass
        if self.report_spool != "":
            try:
                for name in listdir(self.report_spool):
                    try:
                        remove(self.report_spool + "/" + name)
                    except:
                        pass
                rmdir(self.report_spool)
            except:
                pass

    def _discard_junit_scratch(self):
        """Remove the JUnit spool directory, its fragments, and any leftover temp.

        `main` owns this scratch: it created the spool with `open_junit_spool`
        and the temp with `open_junit_artifact`, so it frees them once the
        session has finished with them. On success the temp has already been
        renamed onto the report target, so its removal is a no-op that never
        touches the published report; on failure the reporter discarded it.
        Either way the fragments and the spool directory are what is left.

        The fragments are removed before the directory holding them, for the
        reason `_discard_report_scratch` states.

        Best-effort and non-raising, so it is safe on every error path and with
        empty or missing paths.
        """
        if self.junit_temp != "":
            try:
                remove(self.junit_temp)
            except:
                pass
        if self.junit_spool != "":
            try:
                for name in listdir(self.junit_spool):
                    try:
                        remove(self.junit_spool + "/" + name)
                    except:
                        pass
                rmdir(self.junit_spool)
            except:
                pass

    def close_into(mut self, code: Int, rank_delivery: Bool) -> CloseOutcome:
        """Release every owned resource and state the code to end on.

        The ladder, stated once: discard the JUnit scratch, discard the
        run-report scratch, close the machine-stream descriptor when `main`
        owns it, then restore the exec runtime. Every release runs before the
        code is settled, so no path out of here can leave scratch behind.

        The precedence over `code` follows from what each release can observe.
        A descriptor close can surface a deferred write error (a quota or
        network filesystem that reports ENOSPC/EIO only at close), which is a
        delivery fact this presents to `resolve_exit_code` rather than a code it
        transforms itself. A runtime close failure is the runner's own machinery
        failing, and it yields the internal-error code over anything else, with
        the cause returned for the caller to report.

        Args:
            code: The code the caller reached this exit path carrying.
            rank_delivery: Whether `code` is a run code the model ranks, so a
                deferred write error may escalate it. False for a usage
                refusal, which was decided before any run existed and so has
                no run facts to rank against.

        Returns:
            The process exit code and any failed-release diagnostic. Mutates:
            every owned resource is released, so the result is meaningful once.
            Never raises.
        """
        self._discard_junit_scratch()
        self._discard_report_scratch()
        var resolved = code
        # `flaky_failed` is False here on purpose: the session already applied
        # it, so a flaky-forced failure arrives as `outcome_code=1` and survives
        # this re-resolution. Re-stating the fact could only demote a 0 that the
        # session had already decided was not one.
        if self.json_owns_fd:
            var delivery_failed = close_json_fd(self.json_fd)
            self.json_owns_fd = False
            if rank_delivery:
                resolved = resolve_exit_code(
                    TerminalFacts(
                        interrupted=False,
                        internal_error=False,
                        drift=False,
                        precompile_failed=False,
                        outcome_code=code,
                        delivery_failed=delivery_failed,
                        flaky_failed=False,
                    )
                )
        try:
            self.runtime.close()
        except e:
            return CloseOutcome(
                EXIT_INTERNAL_ERROR, "mtest: internal error: " + String(e)
            )
        return CloseOutcome(resolved, String(""))
