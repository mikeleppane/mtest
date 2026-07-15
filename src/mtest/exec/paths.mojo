"""Canonical (symlink-resolved) absolute paths for `exec` (Layer 3).

`mojo build` bakes the ABSOLUTE, symlink-resolved source path into every location
line of a child's report (`Running … for <path>`, `At <path>:…`, `ABORT: …`), so
the report parser's identity key is that canonical path. `canonicalize` computes
the same string from a repo-relative or already-absolute path, so the session can
match a report back to the file it built.

Unlike `discover`'s lexical `.`/`..` folding, this RESOLVES symlinks — it is the
filesystem's real answer, not a textual one — which is exactly why it can raise:
a path with no on-disk target has no canonical form.
"""
from std.os.path import realpath


def canonicalize(path: String) raises -> String:
    """Return the absolute, symlink-resolved canonical path of `path`.

    This is the same string `mojo build` bakes into a child's report location
    lines for that source, so it is the identity key the report parser matches on.
    `.`/`..` segments are folded and every symlink component is resolved against
    the live filesystem.

    Args:
        path: A relative or absolute filesystem path that must exist.

    Returns:
        The canonical absolute path, with no `.`/`..` segments and no symlink
        components.

    Raises:
        An `exec:`-prefixed error naming `path` when it cannot be resolved (for
        example a component does not exist).
    """
    try:
        return realpath(path)
    except e:
        raise Error(
            "exec: cannot canonicalize path '" + path + "': " + String(e)
        )
