"""Test-name list helpers shared across the `session` selection paths.

Layer 4 leaf beneath the orchestration: membership, order-independent set
equality, and the restriction of a probed name universe to the names a
selection actually ran. Pure list arithmetic over `String` names — it imports
nothing, from `mtest` or the stdlib, so both the selection pipeline and the
crash-attribution post-pass can depend on it without either depending on the
other.
"""


def _str_in(items: List[String], needle: String) -> Bool:
    """Whether `needle` equals any element of `items`."""
    for x in items:
        if x == needle:
            return True
    return False


def _select_names(names: List[String], selected: List[String]) -> List[String]:
    """Restrict `names` to `selected`, giving attribution's isolation set.

    Crash attribution reruns a crashed file's tests one at a time to name the
    culprit. Under `-k` or `--only` the file's full test universe was probed,
    but only the selected subset actually ran, and isolating a deselected test
    could name a culprit in code the user never invoked. An empty `selected`
    means no selection is active, so every name is a candidate.

    Args:
        names: The file's probed test names, in source order.
        selected: The names that actually ran, or empty when no selection is
            active.

    Returns:
        The candidate names, in the source order given by `names`.
    """
    if len(selected) == 0:
        return names.copy()
    var kept = List[String]()
    for n in names:
        if _str_in(selected, n):
            kept.append(n)
    return kept^


def _same_set(a: List[String], b: List[String]) -> Bool:
    """Whether `a` and `b` hold the same set of names (order-independent)."""
    if len(a) != len(b):
        return False
    for x in a:
        if not _str_in(b, x):
            return False
    return True
