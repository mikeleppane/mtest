"""The `mtest` binary entry point (Layer 5, the top).

`main` is the only place that reads the process argv and environment, talks to
the terminal, and calls `exit`. It parses argv, prints help or the version to
stdout and exits 0, prints a usage error to stderr and exits 4 (the one stated
exception to the event seam — a pre-session usage error has no reporter to route
through), resolves the console's color inputs, installs the interrupt handlers,
wraps a `ConsoleReporter` in a one-element `CompositeReporter` (the type the
session drives), runs the session, flushes the console's rendered buffer to
stdout, and exits with the session's resolved code.

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
from mtest.exec import install_signal_handlers, stdout_isatty
from mtest.report import CompositeReporter, ConsoleReporter
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

    # Install the interrupt handlers and resolve the invocation root. A failure
    # of either is a pre-session internal error (mapping the flag page or reading
    # the cwd) — the honest code is 3, the same the session gives its own.
    var root = String("")
    try:
        install_signal_handlers()
        root = String(cwd())
    except e:
        _eprintln("mtest: internal error: " + String(e))
        exit(3)

    # Collect mode: probe every discovered file for its node ids and print the
    # SORTED listing to STDOUT, byte-clean, running no test body. This print is
    # the SECOND sanctioned exception to the event seam (usage errors are the
    # first): the listing is a frozen machine-readable contract, so it is written
    # OUTSIDE any reporter, STDOUT carries ONLY the listing, and every diagnostic
    # goes to STDERR. A discover: usage error still routes to exit 4.
    if config.collect:
        var collected = CollectResult(List[String](), List[String](), 0)
        try:
            collected = run_collect(config, root)
        except e:
            _eprintln(String(e))
            exit(4)
        for line in collected.diagnostics:
            _eprintln(line)
        var listing = String("")
        for nid in collected.listing:
            listing += nid + "\n"
        print(listing, end="", flush=True)
        exit(collected.code)

    var build_flags = build_flags_string(config)
    var console = ConsoleReporter(
        MTEST_VERSION,
        config.color,
        stdout_isatty(),
        _no_color_set(),
        config.verbosity,
        config.show_output,
        build_flags^,
    )
    var comp = CompositeReporter(Tuple(console^))

    var code = 0
    try:
        code = run_session(config, root, comp)
    except e:
        # The only raise the session propagates is a discover: usage error;
        # like a cli usage error it exits 4 to stderr.
        _eprintln(String(e))
        exit(4)

    # Flush the console's fully rendered buffer verbatim (it already ends in a
    # newline), even on an interrupt or partial-summary path.
    print(comp.reporters[0].output(), end="", flush=True)
    exit(code)
