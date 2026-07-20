"""The `mtest` binary entry point (Layer 5, the top).

`main` is the only place that reads the process argv and environment, talks to
the terminal, and calls `exit`. It parses argv, prints help or the version to
stdout and exits 0, prints a usage error to stderr and exits 4 (the one stated
exception to the event seam — a pre-session usage error has no reporter to route
through), resolves the console's color inputs, constructs the exec runtime, resolves the
machine-stream destination (`--json`) and, with it, the console's own
destination, composes a `ConsoleReporter` and a `JsonStreamReporter` into a
fixed-order `CompositeReporter` (the type the session drives), runs the session,
flushes the console's rendered buffer to its resolved descriptor (stdout, or
stderr under `--json -` so stdout carries only the byte-pure stream), and exits
with the session's resolved code.

It stays THIN: every decision it makes is delegated. The parser resolves the
config (including the mojo path); the console resolves color from the inputs main
supplies; the session resolves the exit code. `main` only wires and moves bytes.
All FFI stays below in `exec` — `stdout_isatty()` is the terminal probe; argv,
cwd, getenv, and exit are ordinary program-level operations via `std`.
"""
from std.io import FileDescriptor
from std.os import getenv, listdir, remove, rmdir
from std.pathlib import cwd
from std.sys import argv, exit
from std.tempfile import mkdtemp

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
from mtest.report import (
    AnnotationsReporter,
    CompositeReporter,
    ConsoleReporter,
    JsonStreamReporter,
    JunitReporter,
    close_json_fd,
    escalate_on_close_failure,
    open_json_fd,
    open_junit_artifact,
    resume_delimiter,
)
from mtest.session import (
    CollectResult,
    annotation_lines,
    run_collect,
    run_session,
)


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
    or empty variable does not. The console's `AUTO` mode reads this.
    """
    return getenv("NO_COLOR", "").byte_length() > 0


def _eprintln(text: String):
    """Write `text` and a newline to standard error (fd 2), flushed."""
    print(text, file=FileDescriptor(2), flush=True)


def _close_runtime(mut runtime: ExecRuntime) -> Bool:
    """Explicitly restore exec state; report and return False on failure."""
    try:
        runtime.close()
        return True
    except e:
        _eprintln("mtest: internal error: " + String(e))
        return False


def _discard_junit_scratch(spool_dir: String, temp_path: String):
    """Best-effort removal of the JUnit spool directory (with every spooled
    fragment) and any leftover temp file. Non-raising; safe on empty/missing.

    `main` OWNS this scratch — it created the spool with `mkdtemp` and the temp
    with `open_junit_artifact` — so it frees them on every exit path once the
    session has finished with them. On success the temp has already been renamed
    onto the report target (so removing `temp_path` is a no-op that never touches
    the published report); on failure the reporter already discarded the temp;
    either way the fragments and the spool directory are the leftovers to clear.
    Called after the session returns and on the pre-run/raise error paths, so a
    run never leaks a `mkdtemp` directory per invocation.
    """
    if temp_path != "":
        try:
            remove(temp_path)
        except:
            pass
    if spool_dir != "":
        try:
            for name in listdir(spool_dir):
                try:
                    remove(spool_dir + "/" + name)
                except:
                    pass
            rmdir(spool_dir)
        except:
            pass


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
        exit(4)

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
        exit(3)
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
            exit(3)
            return
        _eprintln("mtest: internal error: " + primary)
        exit(3)
        return

    # Collect mode: probe every discovered file for its node ids and print the
    # SORTED listing to STDOUT, byte-clean, running no test body. This print is
    # the SECOND sanctioned exception to the event seam (usage errors are the
    # first): the listing is a frozen machine-readable contract, so it is written
    # OUTSIDE any reporter, STDOUT carries ONLY the listing, and every diagnostic
    # goes to STDERR. A discover: usage error still routes to exit 4.
    if config.collect:
        var collected = CollectResult(List[String](), List[String](), 0)
        try:
            collected = run_collect(runtime, config, root)
        except e:
            _eprintln(String(e))
            if not _close_runtime(runtime):
                exit(3)
            exit(4)
        for line in collected.diagnostics:
            _eprintln(line)
        var listing = String("")
        for nid in collected.listing:
            listing += nid + "\n"
        print(listing, end="", flush=True)
        if not _close_runtime(runtime):
            exit(3)
        exit(collected.code)

    # Resolve the machine-stream destination and, with it, the console's own
    # destination. Under `--json -` the stream OWNS stdout (byte-pure), so the
    # whole console relocates to stderr; `--json PATH` streams to the file and
    # leaves the console on stdout. `--color auto` then decides against the
    # console's RESOLVED descriptor — stderr's TTY-ness when relocated, stdout's
    # otherwise — because color is a property of where the human text lands.
    var console_fd = 1
    var json_fd = -1
    var json_active = False
    var json_owns_fd = False
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
            if not _close_runtime(runtime):
                exit(3)
            exit(3)
        json_active = True
        json_owns_fd = True

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
            # Assign the spool to the outer name FIRST, so a later failure to
            # open the target temp still leaves the mkdtemp directory tracked for
            # cleanup rather than leaking it.
            junit_spool = mkdtemp()
            var artifact = open_junit_artifact(junit_spool, config.junit_dest)
            junit_temp = artifact.temp_path
            junit_target = artifact.target_path
        except junit_error:
            _discard_junit_scratch(junit_spool, junit_temp)
            if json_owns_fd:
                # Already exiting 3 (an internal error outranks a close failure);
                # the close status cannot escalate further, so discard it.
                _ = close_json_fd(json_fd)
            _eprintln("mtest: internal error: " + String(junit_error))
            if not _close_runtime(runtime):
                exit(3)
            exit(3)

    # A fixed composition ORDER: index 0 the console, index 1 the machine stream
    # (inert when `--json` is absent), index 2 the JUnit report (inert when
    # `--junit-xml` is absent), index 3 the annotations reporter (inert when
    # resolved off). The session polls index 1's stream latch, finalizes index 2's
    # report, and reaches index 3 for its tail by those fixed positions —
    # `run_session[1, 2, 3]` below names them.
    var stream = JsonStreamReporter(json_fd, MTEST_VERSION, json_active)
    var junit = JunitReporter(
        junit_spool, junit_active, junit_target, junit_temp
    )
    var annotations = AnnotationsReporter(annotations_on)
    var comp = CompositeReporter(Tuple(console^, stream^, junit^, annotations^))

    var code = 0
    try:
        code = run_session[1, 2, 3](runtime, config, root, comp)
    except e:
        # The only raise the session propagates is a discover: usage error;
        # like a cli usage error it exits 4 to stderr. The session raised before
        # finalizing, so clear the junit scratch it never got to publish.
        if junit_active:
            _discard_junit_scratch(junit_spool, junit_temp)
        if json_owns_fd:
            # A usage error already routes to exit 4, which dominates any
            # close-failure escalation, so discard the close status here.
            _ = close_json_fd(json_fd)
        _eprintln(String(e))
        if not _close_runtime(runtime):
            exit(3)
        exit(4)

    # Flush the console's fully rendered buffer verbatim (it already ends in a
    # newline) to its RESOLVED destination — stdout normally, stderr under
    # `--json -` so stdout carries only the byte-pure stream. Even on an
    # interrupt or partial-summary path.
    print(
        comp.reporters[0].output(),
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
    # resolved on (never beside `--json -`, refused at parse time). `annotation_lines`
    # reaches the concrete reporter at the fixed composite index 3.
    var fence_token = comp.reporters[0].fence_token()
    if gh_actions and fence_token != "":
        print(
            resume_delimiter(fence_token),
            file=FileDescriptor(console_fd),
            flush=True,
        )
    if annotations_on:
        var tail = annotation_lines[3](comp)
        var rendered = String("")
        for line in tail:
            rendered += line + "\n"
        print(rendered, end="", file=FileDescriptor(console_fd), flush=True)

    if json_owns_fd:
        # The close of the destination main OWNS can surface a deferred write
        # error (a quota/network filesystem that reports ENOSPC/EIO only at
        # close), which the session could not have seen. Escalate the resolved
        # code under the terminal-write-failure precedence (2 stands, 3 stays,
        # 0/1/5 -> 3): an undelivered machine report must not exit success.
        code = escalate_on_close_failure(code, close_json_fd(json_fd))
    if junit_active:
        # The session has finalized (the report was renamed onto its target, or
        # left intact on failure); free the spool directory and fragments main
        # created for it so no run leaks a mkdtemp directory. Covers the success,
        # interrupt, finalize-failure, and spool-failure paths alike.
        _discard_junit_scratch(junit_spool, junit_temp)
    if not _close_runtime(runtime):
        exit(3)
    exit(code)
