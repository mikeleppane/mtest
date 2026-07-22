"""The `mtest` binary entry point.

`main` is the only place that reads the process argv and environment, talks to
the terminal, and calls `exit`. It parses argv, prints help or the version and
exits 0, constructs the exec runtime, resolves the machine-stream (`--json`)
destination and with it the console's own descriptor, then resolves the JUnit
report destination, composes the console, stream, JUnit, and annotation
reporters into a `StandardReportCoordinator` (the report-layer interface the
session drives), runs the session, flushes the console's rendered buffer to its
resolved descriptor (stdout, or stderr under `--json -` so stdout carries only
the byte-pure stream), and exits with the session's resolved code.

Two writes bypass the event seam, both by design: a pre-session usage error
goes straight to stderr with exit 4, having no reporter to route through, and
`--collect-only` writes its node-id listing straight to stdout, where it is a
frozen machine-readable contract.

Every decision `main` makes is delegated. The parser resolves the config
(including the mojo path); the console resolves color from the inputs main
supplies; the session states the run's facts and `resolve_exit_code` in the
model layer ranks them. `main` names no exit code of its own except
`EXIT_USAGE_ERROR`, which is refused before any run exists and so has no facts
to rank. Otherwise it only wires and moves bytes. All FFI stays below in `exec`
— `stdout_isatty()` and `stderr_isatty()` are the terminal probes, while argv,
cwd, getenv, and exit are ordinary program-level operations via `std`.
"""
from std.io import FileDescriptor
from std.os import getenv, listdir, remove, rmdir
from std.pathlib import cwd
from std.sys import argv, exit

from mtest.cli import (
    MTEST_VERSION,
    ParseResult,
    build_flags_string,
    help_text,
    parse_args,
    version_text,
)
from mtest.exec import ExecRuntime, stderr_isatty, stdout_isatty
from mtest.config import annotations_resolved_on
from mtest.model import (
    EXIT_INTERNAL_ERROR,
    TerminalFacts,
    resolve_exit_code,
)
from mtest.report import (
    AnnotationsReporter,
    ConsoleReporter,
    JsonStreamReporter,
    JunitReporter,
    StandardReportCoordinator,
    close_json_fd,
    open_json_fd,
    open_junit_artifact,
    open_junit_spool,
    resume_delimiter,
)
from mtest.session import CollectResult, run_collect, run_session


comptime EXIT_USAGE_ERROR = 4
"""The invocation was refused before any run existed: a usage error.

The one exit code that is not the model's to resolve, and so the one that lives
here. It is decided before there are any run outcomes or run facts to rank, and
it dominates every code a run could have produced because no run happened.
"""


def _argv_tail() -> List[String]:
    """The process argument tokens, excluding the program name (argv[0])."""
    var raw = argv()
    var tail = List[String]()
    for i in range(1, len(raw)):
        tail.append(String(raw[i]))
    return tail^


def _no_color_set() -> Bool:
    """Whether `NO_COLOR` is set to a non-empty value in the environment.

    Per the `NO_COLOR` convention any non-empty value disables color; an unset
    or empty variable does not. The console's auto color mode reads this.
    """
    return getenv("NO_COLOR", "").byte_length() > 0


def _eprintln(text: String):
    """Write `text` and a newline to standard error (fd 2), flushed."""
    print(text, file=FileDescriptor(2), flush=True)


@fieldwise_init
struct RunResources:
    """Everything a configured run owns, and the one ladder that releases it.

    `main` takes these resources at three different points — the exec runtime
    first, then the machine-stream descriptor, then the JUnit scratch — and
    every exit path from there on has to release all of them, in one order,
    under one precedence. Holding them together is what lets `close_into` state
    that ladder once instead of once per exit path.

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

    def _discard_junit_scratch(self):
        """Remove the JUnit spool directory, its fragments, and any leftover temp.

        `main` owns this scratch — it created the spool with `open_junit_spool`
        and the temp with `open_junit_artifact` — so it frees them once the
        session has finished with them. On success the temp has already been
        renamed onto the report target, making its removal a no-op that never
        touches the published report; on failure the reporter discarded it.
        Either way the fragments and the spool directory are what is left.

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

    def close_into(mut self, code: Int, rank_delivery: Bool) -> Int:
        """Release every owned resource and return the code to exit with.

        The ladder, stated once: discard the JUnit scratch, close the
        machine-stream descriptor when `main` owns it, then restore the exec
        runtime. The precedence over `code` follows from what each release can
        observe. A descriptor close can surface a deferred write error (a quota
        or network filesystem that reports ENOSPC/EIO only at close), which is
        a delivery fact this presents to `resolve_exit_code` rather than a code
        it transforms itself. A runtime close failure is the runner's own
        machinery failing, reported to stderr, and it yields the internal-error
        code over anything else.

        Args:
            code: The code the caller reached this exit path carrying.
            rank_delivery: Whether `code` is a run code the model ranks, so a
                deferred write error may escalate it. False for a usage
                refusal, which was decided before any run existed and so has
                no run facts to rank against.

        Returns:
            The process exit code. Mutates: every owned resource is released,
            so the result is meaningful once. Never raises.
        """
        self._discard_junit_scratch()
        var resolved = code
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
                    )
                )
        try:
            self.runtime.close()
        except e:
            _eprintln("mtest: internal error: " + String(e))
            return EXIT_INTERNAL_ERROR
        return resolved


def main():
    """Parse argv, run the session, and exit with the resolved code."""
    # The sentinel is never read: every except path below exits the process,
    # but the compiler does not treat `exit` as noreturn, so the value must be
    # initialized on the fall-through path it thinks exists.
    var result = ParseResult.show_help()
    try:
        result = parse_args(_argv_tail())
    except e:
        # A pre-session cli: usage error: the one seam exception — straight to
        # stderr with the dedicated usage exit code 4.
        _eprintln(String(e))
        exit(EXIT_USAGE_ERROR)

    if result.is_help():
        print(help_text(), end="", flush=True)
        exit(0)
    if result.is_version():
        print(version_text(), flush=True)
        exit(0)

    # A configured run.
    var config = result.config.copy()

    # Resolve the invocation root, then transactionally take exclusive ownership
    # of process-global signal/exec state. Either failure is a pre-session
    # internal error; the honest code is 3.
    var root: String
    try:
        root = String(cwd())
    except e:
        _eprintln("mtest: internal error: " + String(e))
        exit(EXIT_INTERNAL_ERROR)
        return

    var runtime = ExecRuntime()
    try:
        runtime.open()
    except e:
        var primary = String(e)
        try:
            runtime.close()
        except cleanup_error:
            _eprintln(
                "mtest: internal error: "
                + primary
                + "; "
                + String(cleanup_error)
            )
            exit(EXIT_INTERNAL_ERROR)
            return
        _eprintln("mtest: internal error: " + primary)
        exit(EXIT_INTERNAL_ERROR)
        return

    # From here on the runtime is owned, and every exit path has to release it.
    # The machine-stream descriptor and the JUnit scratch join it below, each
    # recorded the moment it is actually opened.
    var resources = RunResources(runtime^, -1, False, String(""), String(""))

    # Collect mode: probe every discovered file for its node ids and print the
    # SORTED listing to STDOUT, byte-clean, running no test body. This print is
    # the SECOND sanctioned exception to the event seam (usage errors are the
    # first): the listing is a frozen machine-readable contract, so it is written
    # OUTSIDE any reporter, STDOUT carries ONLY the listing, and every diagnostic
    # goes to STDERR. A discover: usage error still routes to exit 4.
    if config.collect:
        var collected = CollectResult(List[String](), List[String](), 0)
        try:
            collected = run_collect(resources.runtime, config, root)
        except e:
            _eprintln(String(e))
            exit(resources.close_into(EXIT_USAGE_ERROR, rank_delivery=False))
        for line in collected.diagnostics:
            _eprintln(line)
        var listing = String("")
        for nid in collected.listing:
            listing += nid + "\n"
        print(listing, end="", flush=True)
        exit(resources.close_into(collected.code, rank_delivery=True))

    # Resolve the machine-stream destination and, with it, the console's own
    # destination. Under `--json -` the stream OWNS stdout (byte-pure), so the
    # whole console relocates to stderr; `--json PATH` streams to the file and
    # leaves the console on stdout. `--color auto` then decides against the
    # console's RESOLVED descriptor — stderr's TTY-ness when relocated, stdout's
    # otherwise — because color is a property of where the human text lands.
    var console_fd = 1
    var json_fd = -1
    var json_active = False
    if config.json_dest == "-":
        json_fd = 1
        json_active = True
        console_fd = 2
    elif config.json_dest != "":
        # Open the destination at session start. A runtime open failure
        # (permissions, a missing parent that slipped past parse-time
        # validation, descriptor exhaustion) is a pre-run internal error: exit 3.
        try:
            json_fd = open_json_fd(config.json_dest)
        except open_error:
            _eprintln("mtest: internal error: " + String(open_error))
            exit(resources.close_into(EXIT_INTERNAL_ERROR, rank_delivery=True))
        json_active = True
        resources.json_fd = json_fd
        resources.json_owns_fd = True

    # The GitHub Actions probe drives BOTH the `auto` annotation resolution and
    # the console's stop-commands FENCING of echoed child output. Fencing is
    # active whenever `GITHUB_ACTIONS=true`, independent of the annotation mode
    # (even `off`): any child-produced `::error` in echoed output would otherwise
    # forge a workflow command. The annotation TAIL renders only when resolved-on.
    var gh_actions = getenv("GITHUB_ACTIONS", "") == "true"
    var annotations_on = annotations_resolved_on(
        config.gh_annotations, gh_actions
    )

    var console_is_tty = stderr_isatty() if console_fd == 2 else stdout_isatty()
    var build_flags = build_flags_string(config)
    var console = ConsoleReporter(
        MTEST_VERSION,
        config.color,
        console_is_tty,
        _no_color_set(),
        config.verbosity,
        config.show_output,
        build_flags^,
        config.durations,
        gh_actions,
    )
    # Resolve the JUnit report destination. Unlike `--json`, the destination is
    # NEVER opened for live truncation: a unique temp file is created in the
    # TARGET directory now — proving it writable BEFORE any build or run — and the
    # assembled document is atomically renamed onto PATH at session finalization,
    # so a prior report survives every failure. A runtime creation failure here
    # (an unwritable or vanished target directory) is a pre-run internal error:
    # exit 3, mirroring `--json`'s runtime open failure. Report destinations are
    # not root-constrained.
    var junit_active = config.junit_dest != ""
    var junit_spool = String("")
    var junit_temp = String("")
    var junit_target = String("")
    if junit_active:
        try:
            # Record the spool as owned FIRST, so a later failure to open the
            # target temp still leaves the spool directory tracked for cleanup
            # rather than leaking it.
            junit_spool = open_junit_spool()
            resources.junit_spool = junit_spool
            var artifact = open_junit_artifact(junit_spool, config.junit_dest)
            junit_temp = artifact.temp_path
            resources.junit_temp = junit_temp
            junit_target = artifact.target_path
        except junit_error:
            _eprintln("mtest: internal error: " + String(junit_error))
            exit(resources.close_into(EXIT_INTERNAL_ERROR, rank_delivery=True))

    # Each reporter is independently inert when its feature is off: no `--json`,
    # no `--junit-xml`, annotations resolved off. The coordinator exposes the
    # stream latch, the JUnit finalize, and the annotation tail by name, so no
    # caller depends on the order they are constructed in.
    var stream = JsonStreamReporter(json_fd, MTEST_VERSION, json_active)
    var junit = JunitReporter(
        junit_spool, junit_active, junit_target, junit_temp
    )
    var annotations = AnnotationsReporter(annotations_on)
    var comp = StandardReportCoordinator(
        console^, stream^, junit^, annotations^
    )

    var code = 0
    try:
        code = run_session(resources.runtime, config, root, comp)
    except e:
        # The only raise the session propagates is a discover: usage error;
        # like a cli usage error it exits 4 to stderr. The session raised before
        # finalizing, so the epilogue clears the junit scratch it never got to
        # publish. A usage error dominates any close-failure escalation, so the
        # descriptor's close status is not ranked against it.
        _eprintln(String(e))
        exit(resources.close_into(EXIT_USAGE_ERROR, rank_delivery=False))

    # Flush the console's fully rendered buffer verbatim (it already ends in a
    # newline) to its RESOLVED destination — stdout normally, stderr under
    # `--json -` so stdout carries only the byte-pure stream. Even on an
    # interrupt or partial-summary path.
    print(
        comp.console_output(),
        end="",
        file=FileDescriptor(console_fd),
        flush=True,
    )

    # The ALWAYS-RUNS restoration epilogue, then the annotation tail — both to the
    # console's resolved descriptor, right after the summary band. When the
    # console fenced any captured-output region under Actions, emit one final
    # resume delimiter FIRST so workflow commands are guaranteed re-enabled before
    # mtest's OWN `::error`/`::warning`/`::notice` lines — no error or partial path
    # can leave commands disabled. The tail itself renders only when annotations
    # resolved on (never beside `--json -`, refused at parse time).
    var fence_token = comp.fence_token()
    if gh_actions and fence_token != "":
        print(
            resume_delimiter(fence_token),
            file=FileDescriptor(console_fd),
            flush=True,
        )
    if annotations_on:
        var tail = comp.annotation_tail()
        var rendered = String("")
        for line in tail:
            rendered += line + "\n"
        print(rendered, end="", file=FileDescriptor(console_fd), flush=True)

    # The session has finalized (the JUnit report was renamed onto its target,
    # or left intact on failure), so the epilogue frees the spool directory and
    # fragments main created for it, closes the machine-stream descriptor main
    # owns — whose deferred write error, if any, the session could not have
    # seen and the resolver re-ranks — and restores the exec runtime. Covers
    # the success, interrupt, finalize-failure, and spool-failure paths alike.
    exit(resources.close_into(code, rank_delivery=True))
