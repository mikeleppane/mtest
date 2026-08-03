"""Recursive directory walking for `discover`.

`walk_dir` collects the files under a directory, recursively, whose basename
matches the `test_*.mojo` pattern. `listdir` returns entries unsorted, so each
directory's entries are sorted before use and the walk stays deterministic. The
pattern gates directory walks only; an explicitly named operand bypasses it,
which the caller handles rather than the walk.

Every listed entry is characterized exactly once, by a raising `lstat` on the
entry itself. The `isdir`/`isfile`/`islink` predicates fold every inspection
error into `False`, and a folded error here is a silently smaller run: in a
directory this process may read but not search, every child stat fails and the
whole subtree would look empty. A name that came out of a listing existed a
moment ago, so an entry that cannot be characterized refuses the walk instead.

Symlinks, by kind. A symlinked **directory** is never descended: lexical
normalization cannot detect a cycle, so following one could loop forever or
reach outside the root. A symlinked **file** carries no such risk — it is one
entry, it cannot close a cycle, and skipping it silently dropped tests the user
had selected, producing a green run over the wrong set. So a link to a regular
file is walked exactly like a regular file, keeping its own lexical path (§2
does not resolve symlinks). A link that resolves to neither — a dangling
target — is unusable and reported.

Other kinds, by name. A directory, FIFO, socket, or device wearing a
`test_*.mojo` name is a tree accident: it names a test the run cannot contain.
It is never descended and never collected, but it is always reported. A
non-test-named entry of those kinds cannot hide a test, so it stays silent.

Paths carrying `::`. The node-id grammar reserves `::` to separate a file from
a test name, so a `test_*.mojo` file whose root-relative path contains one has
no identity the runner can express: it cannot be typed as an operand, cannot be
rendered as a node id, and cannot be recalled from last-run state. Collecting
it would put a test in the run that nothing could then name, so it is refused —
and reported, because a refusal that runs one test fewer is exactly the kind of
silence §5's walk-totality rule exists to prevent.

Nothing here prints: all three loud channels — the refused links, the
test-named non-regular entries, and the unaddressable paths — ride out in
`WalkResult` so the session can emit one loud warning apiece, the way it
already does for a stale exclude.
"""
from std.builtin.sort import sort
from std.os import listdir, lstat
from std.os.path import isdir, isfile

from mtest.discover.fnmatch import fnmatch
from mtest.model import escape_one_line

comptime _TEST_GLOB = "test_*.mojo"
"""The directory-walk pattern, matched against each file's basename."""

comptime _S_IFMT = 0xF000
"""File-type mask over `st_mode`; POSIX fixes it on Linux and Darwin alike."""

comptime _S_IFDIR = 0x4000
"""`S_IFDIR`: the `st_mode` file-type value for a directory."""

comptime _S_IFLNK = 0xA000
"""`S_IFLNK`: the `st_mode` file-type value for a symbolic link."""

comptime _S_IFREG = 0x8000
"""`S_IFREG`: the `st_mode` file-type value for a regular file."""

comptime NODE_ID_SEPARATOR = "::"
"""What separates a file from a test name in a node id, and so what a path may
not contain (§5 of the CLI contract)."""


def path_is_addressable(rel: String) -> Bool:
    """Whether a root-relative path can be named as an operand or a node id.

    The one place the `::` rule is applied to a path, so the walk that drops
    such a file and the operand refusal that explains it cannot drift apart.

    Args:
        rel: A root-relative path, exactly as discovery spells it.

    Returns:
        False iff `rel` contains the node-id separator. Allocates nothing.

    Examples:

    ```mojo
    from mtest.discover import path_is_addressable

    print(path_is_addressable("tests/test_a.mojo"))  # True
    print(path_is_addressable("tests/co::l/test_a.mojo"))  # False
    ```
    """
    return rel.find(NODE_ID_SEPARATOR) == -1


def is_discovered_test_name(name: String) -> Bool:
    """Whether a directory walk would collect a file with this basename.

    The one place the pattern is applied, so every caller means the same thing
    by "a test file". `walk_dir` asks it of each entry it meets; the build cache
    asks it of a test file's siblings to tell an independent entry point — one
    that already carries its own key — from a shared helper that belongs in its
    neighbours' keys. Those two answers must never drift apart, which is why the
    pattern is not spelled a second time anywhere.

    Args:
        name: One directory entry's bare name, with no directory part.

    Returns:
        True iff a directory walk would collect a file of that name.

    Examples:

    ```mojo
    from mtest.discover import is_discovered_test_name

    print(is_discovered_test_name("test_addition.mojo"))  # True
    print(is_discovered_test_name("helpers.mojo"))  # False
    ```
    """
    return fnmatch(name, _TEST_GLOB)


@fieldwise_init
struct WalkResult(Copyable, Movable):
    """The files a walk found, plus the entries it could not use.

    Owns its lists, so copies are explicit.
    """

    var files: List[String]
    """Root-relative `test_*.mojo` files, in per-directory sorted order."""

    var skipped_links: List[String]
    """Root-relative symlinks the walk refused: a symlinked directory (cycle
    safety), or a `test_*.mojo` link resolving to no usable file — a deleted
    target, a target the process cannot reach, or one that is neither a
    directory nor a regular file. Never silent."""

    var skipped_nonregular: List[String]
    """Root-relative test-named entries that are neither regular files nor
    symlinks nor descendable directories — a directory wearing a test
    file's name, or a FIFO, socket, or device sitting exactly where a test
    file is expected. Never silent: each one is a test the tree suggests
    exists and the run will not contain."""

    var skipped_unaddressable: List[String]
    """Root-relative test-named entries whose path carries `::`, which the
    node-id grammar reserves (§5). The file may be perfectly runnable; it is
    refused because nothing could name it afterwards. Never silent, for the
    same reason the two channels above are not."""


def walk_dir(abs_dir: String, rel_prefix: String) raises -> WalkResult:
    """Root-relative `test_*.mojo` files under `abs_dir`, recursively, sorted.

    Args:
        abs_dir: The absolute filesystem path of the directory to walk.
        rel_prefix: The root-relative path of `abs_dir` (empty for the root),
            used to build each result's root-relative path.

    Returns:
        The matching files as root-relative paths — symlinked files included,
        keeping the link's own path — together with every symlink the walk
        refused to use, every test-named entry that is not a runnable file,
        and every test-named entry no node id could address. Each directory's
        entries are visited in sorted order.

    Raises:
        Error: If a directory cannot be listed, or an entry cannot be
            characterized, during the walk.
    """
    var names = List[String]()
    for entry in listdir(abs_dir):
        names.append(String(entry))
    sort(names)

    var out = List[String]()
    var skipped = List[String]()
    var nonregular = List[String]()
    var unaddressable = List[String]()
    for name in names:
        var full = abs_dir + "/" + name
        var rel: String
        if rel_prefix == "":
            rel = name
        else:
            rel = rel_prefix + "/" + name
        # Before the entry is characterized at all: what makes this file
        # unusable is its NAME, not its kind, and a `::` in the path defeats
        # every way the runner has of pointing at the result. A directory
        # carrying one is still descended, so each unaddressable test under it
        # is announced on its own rather than as a whole subtree the reader
        # would have to expand.
        if not path_is_addressable(rel) and is_discovered_test_name(name):
            unaddressable.append(rel^)
            continue
        # One raising characterization per entry: `isdir`/`isfile`/`islink`
        # fold every inspection error into False, and a folded error here is a
        # silently smaller run. This name came out of the listing, so it
        # existed a moment ago; a tree the walk cannot characterize must be
        # refused, not framed as empty.
        var kind: Int
        try:
            kind = Int(lstat(full).st_mode) & _S_IFMT
        except:
            raise Error(
                "discover: cannot inspect '" + escape_one_line(rel) + "'"
            )
        if kind == _S_IFLNK:
            # The target's type decides; `isdir`/`isfile` follow the link.
            if isdir(full):
                # A symlinked subtree could close a cycle: refuse, but loudly.
                skipped.append(rel^)
            elif isfile(full):
                # One entry, no cycle possible: an ordinary test file.
                if is_discovered_test_name(name):
                    out.append(rel^)
            elif is_discovered_test_name(name):
                # Dangling, and named like a test the user expects to run.
                skipped.append(rel^)
            continue
        if kind == _S_IFDIR:
            if is_discovered_test_name(name):
                # A directory NAMED like a test file: descending it would run
                # tests under a name nothing treats as a container, or
                # silently shrink the run. The check sits ABOVE the recursion —
                # a terminal else can never see this case.
                nonregular.append(rel^)
            else:
                var sub = walk_dir(full, rel)
                for f in sub.files:
                    out.append(f)
                for s in sub.skipped_links:
                    skipped.append(s)
                for s in sub.skipped_nonregular:
                    nonregular.append(s)
                for s in sub.skipped_unaddressable:
                    unaddressable.append(s)
        elif kind == _S_IFREG:
            if is_discovered_test_name(name):
                out.append(rel^)
        elif is_discovered_test_name(name):
            # Characterized, and neither regular file nor directory nor
            # symlink: a FIFO, socket, or device wearing a test file's name.
            nonregular.append(rel^)
    return WalkResult(out^, skipped^, nonregular^, unaddressable^)
