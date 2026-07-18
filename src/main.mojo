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
from std.os import getenv
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
from mtest.report import (
    CompositeReporter,
    ConsoleReporter,
    JsonStreamReporter,
    close_json_fd,
    open_json_fd,
)
from mtest.session import CollectResult, run_collect, run_session


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
            if not _close_runtime(runtime):
                exit(3)
            _eprintln(String(e))
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
            if not _close_runtime(runtime):
                exit(3)
            _eprintln("mtest: internal error: " + String(open_error))
            exit(3)
            return
        json_active = True
        json_owns_fd = True

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
    )
    # A fixed composition ORDER: index 0 is the console, index 1 the machine
    # stream (inert when `--json` is absent). The session polls index 1's latch
    # by that fixed position — `run_session[1]` below names it.
    var stream = JsonStreamReporter(json_fd, MTEST_VERSION, json_active)
    var comp = CompositeReporter(Tuple(console^, stream^))

    var code = 0
    try:
        code = run_session[1](runtime, config, root, comp)
    except e:
        # The only raise the session propagates is a discover: usage error;
        # like a cli usage error it exits 4 to stderr.
        if json_owns_fd:
            close_json_fd(json_fd)
        if not _close_runtime(runtime):
            exit(3)
        _eprintln(String(e))
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
    if json_owns_fd:
        close_json_fd(json_fd)
    if not _close_runtime(runtime):
        exit(3)
    exit(code)
