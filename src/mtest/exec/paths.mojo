"""Canonical (symlink-resolved) absolute paths for `exec`.

`mojo build` bakes the absolute, symlink-resolved source path into every
location line of a child's report (`Running … for <path>`, `At <path>:…`,
`ABORT: …`), so the report parser's identity key is that canonical path.
`canonicalize` computes the same string from a repo-relative or already-absolute
path, so the session can match a report back to the file it built.

Unlike `discover`'s lexical `.`/`..` folding, this resolves symlinks against the
live filesystem. That is why it can raise: a path with no on-disk target has no
canonical form.
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
    """
    try:
        return realpath(path)
    except e:
        raise Error(
            "exec: cannot canonicalize path '" + path + "': " + String(e)
        )
