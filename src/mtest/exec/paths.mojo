"""Absolute source paths for `exec`, in the flavors the runner needs.

`mojo build` bakes the absolute source path into every location line of a
child's report (`Running … for <path>`, `At <path>:…`, `ABORT: …`), so the
report parser's identity key is that path. mtest hands the compiler a
ROOT-RELATIVE argument, so reproducing that key means reproducing exactly what
the compiler does with it — and the two halves behave differently:

- The **root** half is resolved by `getcwd(3)`, which always reports the
  PHYSICAL directory, every symlink already resolved. So the key's prefix must
  be canonical, whatever string the caller happened to pass as the root.
- The **relative** half is only made absolute, never resolved. A symlink
  component in it survives into the report verbatim.

`source_identity_key` composes those two halves and is what call sites should
use. Getting either half wrong reports a conforming module as MALFORMED-SUITE,
and each half hides on a different platform: an all-canonical key breaks only
when a test file is reached through a link, and an all-lexical key breaks only
when the ROOT is reached through one — which on macOS is the default, because
the temp root lives under `/var`, itself a link to `/private/var`. §2 is
explicit that mtest does not resolve symlinks *it was pointed at*; resolving
the root it is standing in is a different act, and the one the compiler
performs.
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


def source_identity_key(root: String, rel: String) raises -> String:
    """Return the key a child's report location lines carry for `rel`.

    Reproduces what `mojo build` does with the root-relative path it is handed,
    which treats the two halves differently: `root` is canonicalized, because
    the compiler resolves a relative argument against `getcwd(3)` and that
    always reports the physical directory; `rel` is folded lexically only, so a
    test file reached through a symlink keeps the link's own name.

    Callers must not hand-roll this as `lexical_source_path(root + "/" + rel)`.
    That form is correct only when `root` is ALREADY physical, which is true of
    the CLI (its root is `cwd()`) and need not be true of any other caller —
    `run_session` takes the root as an argument. On macOS it is routinely false,
    since the temp root sits under `/var`, a link to `/private/var`.

    Args:
        root: The invocation root; must exist, but need not be canonical.
        rel: The root-relative source path, kept lexically.

    Returns:
        The absolute identity key: canonical root, lexical remainder.

    Raises:
        Error: If `root` cannot be canonicalized. The message is `exec:`-
            prefixed and names the path.

    Examples:

    ```mojo
    from mtest.exec import source_identity_key

    # Resolves a symlinked root, keeps a symlinked file.
    var key = source_identity_key("/var/tmp/proj", "tests/test_linked.mojo")
    ```
    """
    return lexical_source_path(canonicalize(root) + "/" + rel)
