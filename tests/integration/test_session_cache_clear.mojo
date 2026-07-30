"""`--cache-clear`: what it deletes, and everything it refuses to.

The one place in mtest that removes a directory a USER named rather than one
mtest invented, so the interesting cases are all refusals. Each drives
`clear_cache_root` against a real temp tree and reads back both halves of the
answer: the diagnostic, and what is left on disk. A refusal that deleted
something first would pass a diagnostic-only assertion.

The clear is a session-independent operation, so most cases here write the
`CACHEDIR.TAG` marker by hand rather than paying for a compile to get one. The
two that need a real session say why.
"""
from std.ffi import external_call
from std.os import makedirs, remove
from std.os.path import exists, islink
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import (
    CliOverlay,
    ConfigEnvironment,
    FileConfig,
    ResolvedConfig,
    RunnerConfig,
    resolve_config,
)
from mtest.model import EventKind, WarningPayload
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.platform.cstring import c_string_bytes
from mtest.session import run_session
from mtest.session.store import clear_cache_root

from cache_fixtures import run_recording_session
from session_fixtures import SRC_PASS, base_config, write_file
from tmptree import link_dir, temp_root


comptime _CACHE_ROOT = ".mtest-cache"
"""The whole directory mtest owns, relative to a run root."""


comptime _STORE_DIR = ".mtest-cache/build-v1"
"""The store's generations directory, relative to a run root."""


comptime _MARKER_TEXT = (
    "Signature: 8a477f597d28d172789f06886806bc55\n"
    "# This file is a cache directory tag created by mtest.\n"
    "# For information about cache directory tags, see"
    " https://bford.info/cachedir/\n"
)
"""A hand-written `CACHEDIR.TAG` body, for cases with no session to write one.

Byte-identical to what the store writes, and it has to be: the clear authorizes
deletion by comparing the whole marker, so a fixture that abbreviated it would
be refused. The signature line alone would not do — it is the cachedir
convention's, shared by every tool that marks a cache directory, so a marker
carrying only that says nothing about who created this one.

Only `test_cache_clear_deletes_a_store_a_real_session_wrote` needs the marker a
session actually writes; every other clear case only needs a marker to be there,
so it writes this rather than paying for a compile.
"""


def _chmod(path: String, mode: Int) raises:
    """Set `path`'s permission bits.

    The pinned `std.os` exposes no `chmod`, and the partial-delete refusal
    cannot be reached without one: that path only opens when the removal fails
    on a child the process genuinely may not unlink, which is a permission fact
    and not something a fault injector can stand in for.

    Args:
        path: An existing path whose mode is replaced.
        mode: The POSIX permission bits, for example `0o500`.

    Raises:
        Error: If `chmod` reports a failure.
    """
    var c = c_string_bytes(path)
    # SAFETY: libc `chmod` has the exact ABI `int chmod(const char*, mode_t)` on
    # both Linux and Darwin — a fixed arity of two with no variadic tail, so the
    # NON-variadic call `external_call` emits is the correct one on every target
    # this suite builds for. The pointer names a complete, fully initialized,
    # NUL-terminated byte copy this function uniquely owns: `c_string_bytes`
    # allocates it here, nothing else holds a reference, and `c` stays a live
    # local that is consumed only after the call returns, so the pointer is valid
    # for the whole synchronous call and aliases nothing. It does not escape —
    # `chmod` reads the path and retains nothing past its return — and the callee
    # writes through it not at all. The mode is a plain scalar widened to the
    # `unsigned int` Linux uses; Darwin's narrower `mode_t` reads the same low
    # bits from the same register, and every value passed here fits in nine bits.
    # Nothing is allocated for the callee to free, and the result is a plain
    # status; `errno` is never read, so no ordering constraint against the
    # release of `c` exists.
    var rc = external_call["chmod", Int32](c.unsafe_ptr(), UInt32(mode))
    _ = c^
    assert_equal(rc, Int32(0), "could not chmod " + path)


def _clear_diagnostic(root: String) -> String:
    """Run `clear_cache_root` against `root` and render its answer as text.

    Args:
        root: The invocation root whose `.mtest-cache` is to be cleared.

    Returns:
        The refusal diagnostic, or the empty string when the clear succeeded.
        Flattening the `Optional` here keeps every case's assertion a plain
        string comparison, so a refusal that appears where none was expected
        prints its own reason instead of `False`.
    """
    var failure = clear_cache_root(root)
    if failure:
        return failure.value()
    return String("")


def _recorder() -> RecordingCoordinator[RecordingReporter]:
    """The recording triple every raw-stream case in this module drives."""
    return RecordingCoordinator(CompositeReporter(Tuple(RecordingReporter())))


def _resolved(config: RunnerConfig) -> ResolvedConfig:
    """Layer `config` with no project file, environment, or CLI overlay.

    Args:
        config: The runner values the session should see.

    Returns:
        The resolved configuration, with `state_cleared` at its default.
    """
    return resolve_config(
        config,
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )


def _saw_warning_kind(rec: RecordingReporter, kind: String) raises -> Bool:
    """Whether the recording holds a `WARNING` event of `kind`.

    Found BY KIND, never by position: this module's cases insert and remove
    warnings, and an index-addressed assertion would break every time one moved.

    Args:
        rec: The recorder to read back.
        kind: The warning kind to look for, as `Event.warning` spells it.

    Returns:
        True if at least one warning carries that kind.

    Raises:
        Error: If the recording cannot be read back.
    """
    for i in range(rec.count()):
        var e = rec.event_at(i)
        if e.kind == EventKind.WARNING:
            if e.data[WarningPayload].warning_kind == kind:
                return True
    return False


def test_cache_clear_removes_marked_store() raises:
    """A marked `.mtest-cache` is deleted whole — store, marker, and lastrun."""
    var root = temp_root()
    write_file(root, ".mtest-cache/CACHEDIR.TAG", _MARKER_TEXT)
    write_file(root, _STORE_DIR + "/tests_stest_uok_h00/bin", "not a binary")
    write_file(root, _STORE_DIR + "/tests_stest_uok_h00/meta", "not a record")
    write_file(root, ".mtest-cache/lastrun", "v1\n")

    var diagnostic = _clear_diagnostic(root)
    assert_equal(diagnostic, "", "clearing an authorized store must not refuse")
    assert_false(
        exists(root + "/" + _CACHE_ROOT),
        "--cache-clear deletes the whole directory, not just the generations",
    )


def test_cache_clear_refuses_symlink() raises:
    """A symlinked `.mtest-cache` is refused before anything is followed.

    The link points at a directory holding a file that has nothing to do with
    mtest. Deleting through the link would take that file with it, so the case
    asserts on the SURVIVING target rather than only on the returned text: a
    refusal that still emptied the target would pass a message-only assertion.
    """
    var root = temp_root()
    write_file(root, "victim/precious.txt", "not mtest's to delete")
    link_dir(root, "victim", _CACHE_ROOT)

    var diagnostic = _clear_diagnostic(root)
    assert_true(diagnostic != "", "a symlinked cache root must be refused")
    assert_true(
        "symlink" in diagnostic,
        "the refusal must say what it refused: " + diagnostic,
    )
    assert_true(
        exists(root + "/victim/precious.txt"),
        "the link target's contents must be untouched",
    )
    assert_true(
        islink(root + "/" + _CACHE_ROOT),
        "the link itself is not mtest's to remove either",
    )


def test_cache_clear_refuses_unmarked() raises:
    """An unmarked `.mtest-cache` is refused, and the refusal is actionable.

    No "but everything in it looks like ours" exception exists on purpose: that
    heuristic is exactly how a directory somebody else created gets deleted, and
    neither does a run write the marker into a directory it merely found — that
    would manufacture the proof one invocation later. So the refusal is
    permanent until the user acts, and the text has to say so and hand over the
    manual removal rather than name a run that would fix it.
    """
    var root = temp_root()
    write_file(root, ".mtest-cache/build-v1/somebody_elses", "stray")

    var diagnostic = _clear_diagnostic(root)
    assert_true(diagnostic != "", "an unmarked cache root must be refused")
    assert_true(
        "CACHEDIR.TAG" in diagnostic,
        "the refusal must name the marker it looked for: " + diagnostic,
    )
    assert_true(
        "deletion-authorization marker" in diagnostic,
        "the refusal must name the marker's deletion authority: " + diagnostic,
    )
    assert_true(
        "never into one it finds" in diagnostic,
        ("the refusal must say why no later run can fix it: " + diagnostic),
    )
    assert_false(
        "run mtest once" in diagnostic,
        (
            "the refusal must not name a run as the way out; a run that marked"
            " this directory would manufacture the proof: "
            + diagnostic
        ),
    )
    assert_true(
        "rm -rf .mtest-cache" in diagnostic,
        "the refusal must hand over the manual fix: " + diagnostic,
    )
    assert_true(
        exists(root + "/.mtest-cache/build-v1/somebody_elses"),
        "a refused clear must leave every byte where it was",
    )


def test_cache_clear_refuses_a_marker_it_did_not_write() raises:
    """A `CACHEDIR.TAG` holding somebody else's text proves nothing.

    `CACHEDIR.TAG` is a CONVENTION, not mtest's private name: the signature line
    is a fixed byte string every cache-marking tool writes, and users and backup
    scripts are actively encouraged to drop one into any directory they want
    backups to skip. So a marker's mere presence — even a marker leading with
    the standard signature — says only that somebody marked this as a cache, not
    that mtest created it. The whole text mtest writes authorizes deletion, or
    the deletion does not happen.
    """
    var root = temp_root()
    write_file(root, ".mtest-cache/CACHEDIR.TAG", "Signature: deadbeef\n")
    write_file(root, ".mtest-cache/theirs.txt", "somebody else's cache")

    var diagnostic = _clear_diagnostic(root)
    assert_true(
        diagnostic != "", "a marker mtest did not write must be refused"
    )
    assert_true(
        "CACHEDIR.TAG" in diagnostic,
        "the refusal must name the marker it checked: " + diagnostic,
    )
    assert_true(
        "rm -rf .mtest-cache" in diagnostic,
        "the refusal must hand over the manual fix: " + diagnostic,
    )
    assert_true(
        exists(root + "/.mtest-cache/theirs.txt"),
        "a refused clear must leave every byte where it was",
    )


def test_cache_clear_refuses_a_marker_that_is_not_a_regular_file() raises:
    """A directory named `CACHEDIR.TAG` is not the marker mtest writes.

    The cheapest way to defeat a deletion check is to satisfy it with the
    wrong kind of object: a bare existence test accepts a directory, a symlink,
    a socket, or a device node at the marker's path, and each of those
    authorizes deleting a tree mtest never created.
    """
    var root = temp_root()
    makedirs(root + "/.mtest-cache/CACHEDIR.TAG")
    write_file(root, ".mtest-cache/theirs.txt", "somebody else's cache")

    var diagnostic = _clear_diagnostic(root)
    assert_true(
        diagnostic != "", "a marker that is not a regular file must be refused"
    )
    assert_true(
        "regular file" in diagnostic,
        "the refusal must say what the marker is not: " + diagnostic,
    )
    assert_true(
        exists(root + "/.mtest-cache/theirs.txt"),
        "a refused clear must leave every byte where it was",
    )


def test_cache_clear_reports_a_partial_delete() raises:
    """The one refusal that changes the disk says so, and how to finish the job.

    `_remove_dir_contents_no_follow` raises on the FIRST entry it cannot remove,
    so an unwritable generation — or an `ENOTEMPTY` from a concurrent mtest
    writing into the store — stops the walk with part of the cache already gone.
    The other two refusals leave every byte where it was and can simply name a
    fix; this one has to admit the partial state first, or a user reading it has
    no way to know what is still there.

    The failure is induced with the permission bit rather than an injector,
    because that is the shape the real one takes: a directory whose contents the
    process may read but may not unlink from.
    """
    var root = temp_root()
    write_file(root, ".mtest-cache/CACHEDIR.TAG", _MARKER_TEXT)
    write_file(root, _STORE_DIR + "/tests_stest_uok_h00/bin", "not a binary")
    var locked = root + "/" + _STORE_DIR + "/tests_stest_uok_h00"
    # `r-x`: the walk can still list and characterize the generation, so it
    # reaches the `unlink` that the missing write bit denies.
    _chmod(locked, 0o500)

    var diagnostic = _clear_diagnostic(root)
    # Restored BEFORE the first assertion, so a failing case still leaves a
    # removable temp tree behind rather than an undeletable one.
    _chmod(locked, 0o700)

    assert_true(
        diagnostic != "",
        (
            "an entry the process may not unlink must refuse; a run as root"
            " would defeat this setup and is not a supported test environment"
        ),
    )
    assert_true(
        "could not delete the cache directory" in diagnostic,
        "the refusal must still name what failed: " + diagnostic,
    )
    assert_true(
        "may already have been removed" in diagnostic,
        "the one refusal that changes the disk must admit it: " + diagnostic,
    )
    assert_true(
        "rm -rf .mtest-cache" in diagnostic,
        "a partial delete must hand over the command that finishes it: "
        + diagnostic,
    )


def test_cache_clear_on_an_absent_store_succeeds() raises:
    """Nothing to delete is success, not a diagnostic."""
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)

    assert_equal(
        _clear_diagnostic(root),
        "",
        "an absent cache root is the ordinary first-run shape",
    )


def test_cache_clear_deletes_a_store_a_real_session_wrote() raises:
    """The marker a real session writes is the one the clear accepts.

    The two halves of this feature are written by different code: the store writes
    `CACHEDIR.TAG` at store creation and the clear reads it. A test that builds
    the marker by hand would pass even if the two spelled the path differently,
    so this one lets a session create the store and then clears it for real.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()

    var first = run_recording_session(config.copy(), root)
    assert_equal(first.code, 0, "the cold run must pass")
    assert_equal(first.built_files, 1, "the cold run compiles the one file")
    assert_true(
        exists(root + "/.mtest-cache/CACHEDIR.TAG"),
        (
            "a cache-enabled session must have written the"
            " deletion-authorization marker"
        ),
    )

    assert_equal(
        _clear_diagnostic(root),
        "",
        "a store with the marker authorizes deletion",
    )
    assert_false(
        exists(root + "/" + _CACHE_ROOT), "the cleared store must be gone"
    )

    var second = run_recording_session(config^, root)
    assert_equal(second.code, 0, "the cold-again run must pass")
    assert_equal(second.cached_files, 0, "a cleared store can serve no hit")
    assert_equal(second.built_files, 1, "the file is compiled from scratch")


def test_cache_clear_warns_when_lf_lost_its_state() raises:
    """`--cache-clear` with `--lf` says the state it would have read is gone.

    Emitted at session start rather than from main because that is where a
    reporter exists, and gated on the plumbed flag rather than on the config so
    an ordinary `--lf` run's event stream is byte-for-byte what it was.
    """
    var root = temp_root()
    write_file(root, "tests/test_ok.mojo", SRC_PASS)
    var config = base_config()
    config.last_failed = True

    var cleared = _resolved(config.copy())
    cleared.state_cleared = True
    var comp = _recorder()
    var code = run_session(cleared, root, comp)
    assert_equal(code, 0, "the full-selection fallback still runs the file")
    assert_true(
        _saw_warning_kind(comp.composite.reporters[0], "cache-clear"),
        "a cleared state under --lf must be reported, not silently ignored",
    )

    var untouched = _resolved(config^)
    assert_false(
        untouched.state_cleared,
        "the plumbed flag must default to False everywhere",
    )
    var quiet = _recorder()
    _ = run_session(untouched, root, quiet)
    assert_false(
        _saw_warning_kind(quiet.composite.reporters[0], "cache-clear"),
        "a plain --lf run must not gain a warning it never had",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
