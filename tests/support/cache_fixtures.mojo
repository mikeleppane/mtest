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
from mtest.model import EventKind, SessionFinishedPayload, WarningPayload
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_session


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
