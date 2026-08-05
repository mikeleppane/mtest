"""The leaf helpers every other part of the store shares.

Layer 4 (`session`), the bottom of `store`: it imports no sibling, so every
sibling may import it. What lands here is what more than one of them needs and
none of them owns — path composition, directory listing, the environment read
that tells unset from empty, and the two read bounds.

The byte ordering is the exception worth naming. `_bytewise_less` and
`_sort_bytewise` are not a general-purpose sort: an include walk feeds its
entries in exactly this order, so the ordering is part of the key's wire
contract and changing it invalidates every stored key. That is why it is
defined against `String`'s bytes here rather than borrowed from anywhere that
could reasonably change its mind.
"""
from std.os import getenv, listdir


comptime _WALK_FILE_CAP = 64 * 1024 * 1024
"""Largest source or package file an include walk will digest, in bytes."""

comptime _BIN_CAP = 512 * 1024 * 1024
"""Largest binary the cache will digest, in bytes — compiler, library, or
artifact."""

comptime _UNSET_PROBE_A = "\x01mtest-cache-env-probe-a"
"""One of two sentinels that tell an unset variable from an empty one."""

comptime _UNSET_PROBE_B = "\x01mtest-cache-env-probe-b"
"""The second sentinel; see `_env_value`."""


def _env_value(name: String) -> Optional[String]:
    """The environment variable `name`, or nothing when it is not set at all.

    `getenv` folds "unset" into its default, so one call cannot tell an absent
    variable from one set to the empty string — and for a cache key those are
    different facts about the environment the compiler ran in. Two probes with
    different defaults settle it without a foreign call: if the variable is set
    both probes return its value, and at most one of them can equal its own
    sentinel, so even a variable literally spelling one sentinel is reported
    correctly. Only a genuinely unset variable returns each default in turn.

    Args:
        name: The variable to read.

    Returns:
        Its value, the empty string included, or `None` when it is unset.
    """
    var first = getenv(name, _UNSET_PROBE_A)
    if first != _UNSET_PROBE_A:
        return Optional(first^)
    var second = getenv(name, _UNSET_PROBE_B)
    if second != _UNSET_PROBE_B:
        return Optional(second^)
    return None


def _absolute(root: String, path: String) -> String:
    """Resolve `path` against `root` unless it is already absolute.

    Args:
        root: The invocation root, itself absolute.
        path: An absolute path, or one relative to `root`.

    Returns:
        An absolute path. Not canonicalized: the spelling is what the compiler
        is given, and `realpath` is applied only where the key wants identity
        rather than spelling.
    """
    if path.startswith("/"):
        return String(path)
    return root + "/" + path


def _bytewise_less(a: String, b: String) -> Bool:
    """Whether `a` sorts before `b` by raw byte order.

    Paths are UTF-8 and byte order equals codepoint order there, so this is a
    correct, locale-free, dependency-free total order — and the order is part
    of the wire contract, which is why it is pinned here rather than delegated
    to a comparison whose semantics could change under the runner.

    Args:
        a: The left name.
        b: The right name.

    Returns:
        True iff `a` precedes `b`.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var an = len(ab)
    var bn = len(bb)
    var n = an if an < bn else bn
    for i in range(n):
        if ab[i] != bb[i]:
            return ab[i] < bb[i]
    return an < bn


def _sort_bytewise(mut names: List[String]):
    """Sort `names` in place into byte order (insertion sort).

    One directory's entries at a time, so an O(n^2) insertion sort is free and
    trivially deterministic. `listdir` returns filesystem order, which differs
    between machines and even between runs; without this the key would too.

    Args:
        names: The entry names, reordered in place.
    """
    for i in range(1, len(names)):
        var j = i
        while j > 0 and _bytewise_less(names[j], names[j - 1]):
            names.swap_elements(j, j - 1)
            j -= 1


def _list_sorted(abs_dir: String) -> Optional[List[String]]:
    """The entries of `abs_dir` in byte order, or nothing if it cannot be read.

    `listdir` raises on failure — unlike `isdir` / `isfile`, which fold every
    error into `False` — so this is the one directory query in the module that
    can tell "empty" from "unreadable". Every place the walk needs to
    characterize a directory goes through it for exactly that reason.

    Args:
        abs_dir: The directory to read, absolute.

    Returns:
        The sorted entry names, or `None` when the directory could not be
        listed at all.
    """
    var names = List[String]()
    try:
        for entry in listdir(abs_dir):
            names.append(String(entry))
    except:
        return None
    _sort_bytewise(names)
    return Optional(names^)
