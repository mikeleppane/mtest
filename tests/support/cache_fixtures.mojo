"""Byte-level and recording-session fixtures for the build-artifact cache tests.

Not a test module (no `test_` prefix, so the runner never builds it as a suite);
it is imported via `-I tests/support`. It sits beside `session_fixtures`, which
carries the *text* fixtures — known-outcome Mojo sources and the base config —
and adds the two things the cache suites need that text fixtures cannot express:
a writer for arbitrary bytes (a cache blob is not UTF-8, and a corrupted one is
deliberately not even close) and a directory lister for asserting what a store
actually holds.

`run_recording_session` is the third: one place that composes the recording
triple, drives a real session, and hands back a flat, assertable record. Without
it every cache suite re-spells the same six lines of coordinator wiring and then
re-walks the event stream by hand.
"""
from std.builtin.sort import sort
from std.os import listdir, makedirs
from std.os.path import dirname, exists, isdir

from mtest.config import RunnerConfig
from mtest.exec import ExecRuntime, ProcessResult, ProcessSpec, run_supervised
from mtest.model import EventKind, SessionFinishedPayload, WarningPayload
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_session
from mtest.session.store import CacheContext, collect_env_base


def write_bytes(root: String, rel: String, data: List[UInt8]) raises:
    """Write `data` verbatim to `root/rel`, creating parent directories as
    needed.

    The byte-level counterpart to `session_fixtures.write_file`: nothing here
    interprets, validates, or re-encodes the payload, so a fixture may write an
    invalid UTF-8 sequence, an embedded NUL, or a truncated archive header and
    get exactly those bytes back off the disk. That is the point — the cache
    reads bytes, and its corruption paths only exist because bytes can be
    arbitrary.

    Args:
        root: The directory the relative path is resolved against.
        rel: The path relative to `root`. Its parent directories are created
            when missing, exactly as `write_file` does.
        data: The exact bytes to write. Not interpreted; an empty list writes an
            empty file.

    Raises:
        Error: If a parent directory cannot be created or the file cannot be
            written.

    Examples:

    ```mojo
    from cache_fixtures import write_bytes
    from tmptree import temp_root

    var root = temp_root()
    write_bytes(root, "store/ab/cd.bin", [UInt8(0), UInt8(255)])
    ```
    """
    var full = root + "/" + rel
    var parent = dirname(full)
    if parent != "" and not exists(parent):
        makedirs(parent)
    with open(full, "w") as f:
        f.write_bytes(Span(data))


def chmod_path(mode: String, path: String) raises:
    """Set `path`'s mode through a supervised `chmod` child.

    The platform layer carries no permissions primitive
    (`grep -rn "chmod\\|permissions" src/mtest/platform/` finds nothing) and the
    pinned `std.os` exposes no `chmod` either, so the bit has to come from a
    real process. `mtest.exec` already owns every fork/exec in the tree, which
    makes a supervised spawn the natural fallback — cheaper than a foreign
    declaration written only for the tests.

    The runtime is closed in a `finally`. Without it a raising `run_supervised`
    would leave mtest's process-global signal dispositions owned by a runtime
    nobody can close, and every later test in the same suite that opens one
    would fail on "a runtime is already active".

    Args:
        mode: The mode argument to pass to `chmod`, e.g. `"755"` or `"000"`.
        path: The file or directory to change.

    Raises:
        Error: If the child did not exit, or exited non-zero.

    Examples:

    ```mojo
    from cache_fixtures import chmod_path

    chmod_path("000", "/tmp/unreadable")
    ```
    """
    var argv: List[String] = ["chmod", mode, path]
    var runtime = ExecRuntime()
    runtime.open()
    var result: ProcessResult
    try:
        result = run_supervised(runtime, ProcessSpec.command(argv^, 30000))
    finally:
        runtime.close()
    if not result.termination.is_exited() or result.termination.value != 0:
        raise Error("test setup: chmod " + mode + " failed for '" + path + "'")


def make_executable(path: String) raises:
    """Give `path` the execute bit.

    Args:
        path: The file to make owner/group/other executable.

    Raises:
        Error: If the child did not exit, or exited non-zero.

    Examples:

    ```mojo
    from cache_fixtures import make_executable

    make_executable("/tmp/tc/bin/mojo")
    ```
    """
    chmod_path("755", path)


def executable_stub(root: String, rel: String) raises -> String:
    """Write a trivial executable shell script at `root/rel` and return its path.

    A stand-in toolchain: the tests that key a compiler need a real file with
    the execute bit, not the several-hundred-megabyte one on PATH, and hashing
    a two-line script is what keeps those cases cheap.

    Args:
        root: The scratch directory the relative path is resolved against.
        rel: The path relative to `root`; parent directories are created.

    Returns:
        The absolute (but not canonicalized) path of the stub.

    Raises:
        Error: If the file cannot be written or the execute bit cannot be set.

    Examples:

    ```mojo
    from cache_fixtures import executable_stub
    from tmptree import temp_root

    var root = temp_root()
    var mojo = executable_stub(root, "tc/bin/mojo")
    ```
    """
    var source = String("#!/bin/sh\nexit 0\n")
    var data = List[UInt8]()
    for b in source.as_bytes():
        data.append(b)
    write_bytes(root, rel, data)
    var full = root + "/" + rel
    make_executable(full)
    return full^


def env_base(config: RunnerConfig, root: String) raises -> CacheContext:
    """Collect an env base over a runtime this helper opens and closes.

    No `try`/`finally` is needed and none is written: `collect_env_base` is
    non-raising by contract — every failure it can meet becomes a disabled
    context — so there is no path on which `runtime.close()` is skipped. That
    contract is what keeps this helper from repeating `chmod_path`'s shape
    above, where a raising `run_supervised` would leak an open runtime into
    every later test in the suite.

    Args:
        config: The config to key.
        root: The invocation root.

    Returns:
        The collected context.

    Raises:
        Error: If the exec runtime cannot be opened or closed.

    Examples:

    ```mojo
    from cache_fixtures import env_base
    from session_fixtures import base_config
    from tmptree import temp_root

    var ctx = env_base(base_config(), temp_root())
    ```
    """
    var runtime = ExecRuntime()
    runtime.open()
    var ctx = collect_env_base(runtime, config, root)
    runtime.close()
    return ctx^


def base_digest(ctx: CacheContext) raises -> String:
    """The full key of `ctx.base`, taken from a fork so `ctx` stays usable.

    Args:
        ctx: The collected context whose base key is wanted.

    Returns:
        The base key's full hex digest.

    Raises:
        Error: If the digest cannot be finalized.

    Examples:

    ```mojo
    from cache_fixtures import base_digest, env_base
    from session_fixtures import base_config
    from tmptree import temp_root

    var key = base_digest(env_base(base_config(), temp_root()))
    ```
    """
    var forked = ctx.base.copy()
    return forked^.digest_full()


def dir_listing(path: String) raises -> List[String]:
    """List `path`'s immediate entry names, sorted, or nothing if it is no
    directory.

    `listdir` returns entries in filesystem order, which is arbitrary and
    differs between runs and machines; every assertion about a store's contents
    would be flaky without the sort. A missing directory reads as an empty
    listing rather than an error, so "the store was never created" and "the
    store is empty" are asserted the same way — the distinction that matters to
    a cache test is what is IN the store, and `isdir` is right there when a test
    genuinely means existence.

    Args:
        path: The directory to list. It may be absent or not a directory.

    Returns:
        The immediate entry names — bare names, not joined paths — in ascending
        byte order. Empty when `path` is missing or is not a directory.

    Raises:
        Error: If `path` is a directory that exists but cannot be listed, for
            example because it is unreadable.

    Examples:

    ```mojo
    from cache_fixtures import dir_listing

    var names = dir_listing("/no/such/dir")  # []
    ```
    """
    var names = List[String]()
    if not isdir(path):
        return names^
    for entry in listdir(path):
        names.append(String(entry))
    sort(names)
    return names^


@fieldwise_init
struct RecordedRun(Copyable, Movable):
    """One session's outcome, flattened to just what a cache test asserts on.

    A cache test cares about four things: the exit code, how many files the run
    genuinely compiled, how many it served from the store, and which warnings it
    raised. Everything else in the event stream is another suite's subject, so
    this carries no events — a test that needs the raw stream should compose the
    recording triple itself.
    """

    var code: Int
    """The exit code the session resolved."""
    var built_files: Int
    """How many files were admitted at a first-attempt compile, compile failures
    included. Retries, probes, and precompile steps never count."""
    var cached_files: Int
    """How many files were admitted from a cache hit."""
    var warnings: List[String]
    """Every `WARNING` event, in emission order, each rendered as
    `kind + ":" + detail`."""


def run_recording_session(
    config: RunnerConfig, root: String
) raises -> RecordedRun:
    """Run one real session under the recording triple and flatten the result.

    Composes `RecordingCoordinator(CompositeReporter(Tuple(RecordingReporter())))`
    — the same wiring the session suites use — drives `run_session` against
    `root`, then reads the counters and the warnings back off the recording.

    Args:
        config: Every knob the run reads. Use `session_fixtures.base_config()`
            unless the test is about a specific knob.
        root: The invocation root; built binaries and paths are relative to it.

    Returns:
        The exit code, the build/cache admission counters, and every warning the
        run emitted.

    Raises:
        Error: If the exec runtime cannot be opened or closed, or if the session
            raises a pre-session usage error.

    Examples:

    ```mojo
    from cache_fixtures import run_recording_session
    from session_fixtures import base_config, write_file, SRC_PASS
    from tmptree import temp_root

    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var run = run_recording_session(base_config(), root)
    ```
    """
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    ref rec = comp.composite.reporters[0]
    var warnings = List[String]()
    # The counters are read off the ONE terminal event the session dispatches;
    # a torn run that never reached it leaves them at zero, which is the honest
    # answer for a session that admitted nothing.
    var built_files = 0
    var cached_files = 0
    for i in range(rec.count()):
        var e = rec.event_at(i)
        if e.kind == EventKind.WARNING:
            warnings.append(
                e.data[WarningPayload].warning_kind
                + ":"
                + e.data[WarningPayload].warning_pattern
            )
        elif e.kind == EventKind.SESSION_FINISHED:
            built_files = e.data[SessionFinishedPayload].built_files
            cached_files = e.data[SessionFinishedPayload].cached_files

    return RecordedRun(code, built_files, cached_files, warnings^)
