"""Recursive directory walking for `discover`.

`walk_dir` collects the files under a directory, recursively, whose basename
matches the `test_*.mojo` pattern. `listdir` returns entries unsorted, so each
directory's entries are sorted before use and the walk stays deterministic. The
pattern gates directory walks only; an explicitly named operand bypasses it,
which the caller handles rather than the walk.

Symlinks, by kind. A symlinked **directory** is never descended: lexical
normalization cannot detect a cycle, so following one could loop forever or
reach outside the root. A symlinked **file** carries no such risk — it is one
entry, it cannot close a cycle, and skipping it silently dropped tests the user
had selected, producing a green run over the wrong set. So a link to a regular
file is walked exactly like a regular file, keeping its own lexical path (§2
does not resolve symlinks). A link that resolves to neither — a dangling
target — is unusable and reported.

Nothing here prints: the skipped links ride out in `WalkResult` so the session
can emit one loud warning apiece, the way it already does for a stale exclude.
"""
from std.builtin.sort import sort
from std.os import listdir
from std.os.path import isdir, isfile, islink

from mtest.discover.fnmatch import fnmatch

comptime _TEST_GLOB = "test_*.mojo"
"""The directory-walk pattern, matched against each file's basename."""


@fieldwise_init
struct WalkResult(Copyable, Movable):
    """The files a walk found, plus the links it could not use.

    Owns its lists, so copies are explicit.
    """

    var files: List[String]
    """Root-relative `test_*.mojo` files, in per-directory sorted order."""

    var skipped_links: List[String]
    """Root-relative symlinks the walk refused: a symlinked directory (cycle
    safety) or a dangling `test_*.mojo` link (unusable). Never silent."""


def walk_dir(abs_dir: String, rel_prefix: String) raises -> WalkResult:
    """Root-relative `test_*.mojo` files under `abs_dir`, recursively, sorted.

    Args:
        abs_dir: The absolute filesystem path of the directory to walk.
        rel_prefix: The root-relative path of `abs_dir` (empty for the root),
            used to build each result's root-relative path.

    Returns:
        The matching files as root-relative paths — symlinked files included,
        keeping the link's own path — together with every symlink the walk
        refused to use. Each directory's entries are visited in sorted order.

    Raises:
        Error: If a directory cannot be listed during the walk.
    """
    var names = List[String]()
    for entry in listdir(abs_dir):
        names.append(String(entry))
    sort(names)

    var out = List[String]()
    var skipped = List[String]()
    for name in names:
        var full = abs_dir + "/" + name
        var rel: String
        if rel_prefix == "":
            rel = name
        else:
            rel = rel_prefix + "/" + name
        # `isdir`/`isfile` both follow links, so the kind is decided here.
        if islink(full):
            if isdir(full):
                # A symlinked subtree could close a cycle: refuse, but loudly.
                skipped.append(rel^)
            elif isfile(full):
                # One entry, no cycle possible: an ordinary test file.
                if fnmatch(name, _TEST_GLOB):
                    out.append(rel^)
            elif fnmatch(name, _TEST_GLOB):
                # Dangling, and named like a test the user expects to run.
                skipped.append(rel^)
            continue
        if isdir(full):
            var sub = walk_dir(full, rel)
            for f in sub.files:
                out.append(f)
            for s in sub.skipped_links:
                skipped.append(s)
        elif isfile(full):
            if fnmatch(name, _TEST_GLOB):
                out.append(rel^)
    return WalkResult(out^, skipped^)
