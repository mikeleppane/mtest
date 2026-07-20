"""Temp-directory tree helpers for the `discover` tests.

Not a test module (no `test_` prefix, so the runner never builds it as a suite);
it is imported via `-I tests/support`. Each helper builds or tears down a real on-disk
tree so the walk can be exercised against actual directories, files, and
symlinks, then cleaned up.
"""
from std.os import (
    getenv,
    listdir,
    makedirs,
    mkdir,
    remove,
    rmdir,
    symlink,
    unlink,
)
from std.os.path import dirname, exists, isdir, islink
from std.testing import assert_equal
from std.time import perf_counter_ns

# How many distinct names one `temp_root` call may try before giving up. The
# nanosecond key already makes a repeat vanishingly unlikely, so the budget
# guards against an unwritable temp base rather than a collision rate.
comptime _TEMP_ATTEMPTS = 64


def _fmt(xs: List[String]) -> String:
    """Render a path list as `[a, b, c]` for assertion messages."""
    var out = String("[")
    for i in range(len(xs)):
        if i > 0:
            out += ", "
        out += xs[i]
    out += "]"
    return out^


def assert_paths(got: List[String], expected: List[String]) raises:
    """Assert `got` equals `expected` element-for-element, with a clear diff."""
    var msg = "paths mismatch: got " + _fmt(got) + " expected " + _fmt(expected)
    assert_equal(len(got), len(expected), msg)
    for i in range(len(expected)):
        assert_equal(got[i], expected[i], msg)


def temp_root() raises -> String:
    """Create and return a fresh, empty temp directory under `TMPDIR` (else
    `/tmp`).

    The shared scratch-root primitive for every suite: `discover` trees, `exec`
    scratch, session fixture roots, and JUnit report targets all come from here.

    Deliberately does NOT use `std.tempfile.mkdtemp`. At the pinned toolchain
    its candidate-name generator is unseeded, so every process walks the SAME
    name sequence; in a shared `/tmp` those names already exist from earlier
    runs, and it exhausts its internal attempts and raises. The key here is a
    monotonic nanosecond reading — distinct across the hundreds of roots one
    aggregate test binary creates and across concurrent processes — with a
    retry counter as the tiebreaker and `mkdir`'s atomic exclusive create as
    the arbiter.

    Raises:
        Error: if no candidate could be created within the attempt budget (the
            temp base is missing, is not a directory, or is unwritable). The
            message carries the LAST underlying failure verbatim — those causes
            burn the budget identically and only the errno text separates them.
    """
    var base = getenv("TMPDIR", "")
    if base == "":
        base = String("/tmp")
    elif base.byte_length() > 1 and base.endswith("/"):
        base = String(base.removesuffix("/"))
    # Seeded so the raise below is always well-formed; the budget is positive,
    # so a real failure always overwrites this.
    var last = String("no attempt was made")
    for attempt in range(_TEMP_ATTEMPTS):
        var candidate = (
            base
            + "/mtest-test-"
            + String(perf_counter_ns())
            + "-"
            + String(attempt)
        )
        try:
            mkdir(candidate, 0o700)
        except e:
            last = String(e)
            continue
        return candidate^
    raise Error(
        "tmptree: could not create a temp root under '"
        + base
        + "' ("
        + String(_TEMP_ATTEMPTS)
        + " attempts; last: "
        + last
        + ")"
    )


def mkdirs(path: String) raises:
    """Create `path` and any missing parents (a no-op if it already exists)."""
    if not exists(path):
        makedirs(path)


def touch(root: String, rel: String) raises:
    """Create an empty file at `root/rel`, making parent directories as needed.
    """
    var full = root + "/" + rel
    var parent = dirname(full)
    if parent != "" and not exists(parent):
        makedirs(parent)
    with open(full, "w") as f:
        f.write("")


def link_dir(root: String, target_rel: String, link_rel: String) raises:
    """Create a symlink at `root/link_rel` pointing at `root/target_rel`."""
    symlink(root + "/" + target_rel, root + "/" + link_rel)


def remove_tree(path: String) raises:
    """Recursively delete `path`; a symlink is unlinked, never followed."""
    if islink(path):
        unlink(path)
        return
    if isdir(path):
        for entry in listdir(path):
            remove_tree(path + "/" + String(entry))
        rmdir(path)
    elif exists(path):
        remove(path)
