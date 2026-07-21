"""Lexical, root-relative path normalization for `discover`.

Every path `discover` reports is root-relative and normalized by text only:
`.` and `..` segments are folded lexically and symlinks are never resolved.
Resolving symlinks would make a reported path depend on the filesystem's link
state; folding them textually keeps a file's identity stable and portable. The
cost is that `..` cannot see through a symlink, which is why directory walks
refuse to follow symlinks at all.

`normalize_operand` folds an operand to its root-relative form and raises a
`discover:`-prefixed usage error (the exit-4 class) when the operand escapes
the invocation root.
"""


def _join(segments: List[String], sep: String) -> String:
    """Join `segments` with `sep` (no leading or trailing separator)."""
    var out = String("")
    for i in range(len(segments)):
        if i > 0:
            out += sep
        out += segments[i]
    return out^


def _strip_trailing_slash(s: String) -> String:
    """`s` with any trailing `/` removed (but never reduced below `/`)."""
    var out = s
    while out.byte_length() > 1 and out.endswith("/"):
        out = String(out.removesuffix("/"))
    return out^


def _normalize_abs(path: String) -> String:
    """Fold an absolute `path`'s `.` and `..` segments lexically.

    A leading `..` at the filesystem root is clamped (POSIX behavior), so the
    result is always an absolute path with no `.` or `..` segments and no
    trailing slash, except for the root itself, `/`.
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
        stack.append(s)
    return "/" + _join(stack, "/")


def normalize_root(root: String) -> String:
    """The normalized form of the invocation root.

    An absolute root is folded lexically; a relative root only has trailing
    slashes stripped. Idempotent, so a root may be normalized more than once.
    """
    if root.startswith("/"):
        return _normalize_abs(root)
    return _strip_trailing_slash(root)


def _escape_error(op: String) -> Error:
    """The exit-4 usage error for an operand that escapes the root."""
    return Error("discover: operand '" + op + "' escapes the invocation root")


def normalize_operand(op: String, root: String) raises -> String:
    """Fold operand `op` to its root-relative, normalized form.

    Args:
        op: The operand as written (an absolute or relative path).
        root: The invocation root (normalized internally).

    Returns:
        The root-relative path with `.`/`..` folded away; the empty string means
        the root itself.

    Raises:
        Error: A `discover:`-prefixed usage error when `op` normalizes to a
            path outside the root: a leading `..` that climbs past the root, or
            an absolute path that is not under the root.
    """
    var nroot = normalize_root(root)
    if op.startswith("/"):
        var norm = _normalize_abs(op)
        if norm == nroot:
            return String("")
        if norm.startswith(nroot + "/"):
            return String(norm.removeprefix(nroot + "/"))
        raise _escape_error(op)
    var stack = List[String]()
    for seg in op.split("/"):
        var s = String(seg)
        if s == "" or s == ".":
            continue
        if s == "..":
            if len(stack) == 0:
                raise _escape_error(op)
            _ = stack.pop()
            continue
        stack.append(s)
    return _join(stack, "/")
