"""Absolute source paths for `exec`, in the two flavors the runner needs.

`mojo build` bakes the absolute source path into every location line of a
child's report (`Running … for <path>`, `At <path>:…`, `ABORT: …`), so the
report parser's identity key is that path. Crucially, it bakes the path it was
HANDED: a relative argument is made absolute against the compiler's cwd, but a
symlink component is never resolved. The identity key is therefore the
**lexical** absolute path — `lexical_source_path` — not the canonical one.

`canonicalize` answers the different question "which file is this, really", by
resolving symlinks against the live filesystem. The two agree for any path with
no symlink component, which is why using the wrong one stayed invisible until a
test file was reached through a link: the resolved path named the link's target,
the child's report named the link, the identity match failed, and a conforming
module was reported MALFORMED-SUITE. §2 is explicit that mtest does not resolve
symlinks; the identity key now matches that rule.
"""
from std.os.path import realpath


def canonicalize(path: String) raises -> String:
    """Return the absolute, symlink-resolved canonical path of `path`.

    This is the same string `mojo build` bakes into a child's report location
    lines for that source, so it is the identity key the report parser matches
    on. `.`/`..` segments are folded and every symlink component is resolved
    against the live filesystem.

    Args:
        path: A relative or absolute filesystem path that must exist.

    Returns:
        The canonical absolute path, with no `.`/`..` segments and no symlink
        components.

    Raises:
        Error: If `path` cannot be resolved, for example because a component
            does not exist. The message is `exec:`-prefixed and names `path`.

    Examples:

    ```mojo
    from mtest.exec import canonicalize

    var source = canonicalize("tests/fixtures/protocol/passing.mojo")
    ```
    """
    try:
        return realpath(path)
    except e:
        raise Error(
            "exec: cannot canonicalize path '" + path + "': " + String(e)
        )


def lexical_source_path(path: String) -> String:
    """Return `path` folded lexically, with every symlink component intact.

    This is the identity key a child's report is matched on: the string
    `mojo build` bakes into its location lines. `.` and empty segments are
    dropped and `..` pops the previous segment, exactly as the compiler's own
    absolute-path construction does — but no symlink is resolved, so a test
    file reached through a link keeps the link's name.

    Deliberately non-raising and filesystem-free: unlike `canonicalize` it
    asserts nothing about existence, because the caller has already built the
    file it is naming.

    Args:
        path: An absolute path, ordinarily `root + "/" + rel`.

    Returns:
        The lexically folded absolute path, with no `.`, `..`, empty, or
        duplicated separator segments, and no trailing slash.

    Examples:

    ```mojo
    from mtest.exec import lexical_source_path

    # A symlinked test file keeps its own name, unlike `canonicalize`.
    var key = lexical_source_path("/project/tests/test_linked.mojo")
    ```
    """
    var stack = List[String]()
    for seg in path.split("/"):
        var s = String(seg)
        if s == "" or s == ".":
            continue
        if s == "..":
            if len(stack) > 0:
                _ = stack.pop()
            continue
        stack.append(s^)
    var out = String("")
    for s in stack:
        out += "/" + s
    return out^ if out != "" else String("/")
