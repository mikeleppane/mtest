"""Recursive directory walking for `discover`.

`walk_dir` collects the files under a directory whose basename matches the
`test_*.mojo` pattern, recursively, with each directory's entries visited in
sorted order for determinism. The pattern gates directory walks only — an
explicitly named operand bypasses it (that is handled by the caller, not here).

**Symlink no-follow.** The walk never follows a symlink, neither a symlinked
subdirectory nor a symlinked file. Lexical normalization cannot detect a cycle,
so a walk that followed links could loop forever or reach outside the root; the
only safe policy is to not follow any link during a walk. An explicitly named
symlink operand is the caller's concern, not the walk's.
"""
from std.builtin.sort import sort
from std.os import listdir
from std.os.path import isdir, isfile, islink

from mtest.discover.fnmatch import fnmatch

comptime _TEST_GLOB = "test_*.mojo"
"""The directory-walk pattern, matched against each file's basename."""


def walk_dir(abs_dir: String, rel_prefix: String) raises -> List[String]:
    """Root-relative `test_*.mojo` files under `abs_dir`, recursively, sorted.

    Args:
        abs_dir: The absolute filesystem path of the directory to walk.
        rel_prefix: The root-relative path of `abs_dir` (empty for the root),
            used to build each result's root-relative path.

    Returns:
        The matching files as root-relative paths. Each directory's entries are
        visited in sorted order; symlinks are skipped (never followed).
    """
    var names = List[String]()
    for entry in listdir(abs_dir):
        names.append(String(entry))
    sort(names)

    var out = List[String]()
    for name in names:
        var full = abs_dir + "/" + name
        var rel: String
        if rel_prefix == "":
            rel = name
        else:
            rel = rel_prefix + "/" + name
        # Never follow a symlink: lexical normalization cannot detect cycles.
        if islink(full):
            continue
        if isdir(full):
            for f in walk_dir(full, rel):
                out.append(f)
        elif isfile(full):
            if fnmatch(name, _TEST_GLOB):
                out.append(rel)
    return out^
