"""The GitHub Actions stop-commands fencing protocol for the report layer.

GitHub Actions lets a workflow disable command processing with
`::stop-commands::<token>` and re-enable it with `::<token>::`. mtest fences
untrusted captured child output between those markers so the output can never
forge a workflow command. This module supplies the resume-delimiter predicate,
collision-free token selection over an injected candidate source, and the
fenced-output assembly; the entropy source that mints the real per-run token
wires in elsewhere, after the producing child has exited.

These are pure string operations with no I/O and no private helper shared with
the escapers in `escape.mojo`. They live apart so the escaping primitives and
the fencing protocol read as the two separate concerns they are.
"""


def resume_delimiter(token: String) -> String:
    """The GitHub Actions stop-commands resume delimiter for `token`.

    The string `::<token>::` is the only text sequence that re-enables
    workflow-command processing once `::stop-commands::<token>` has disabled
    it.

    Args:
        token: The fencing token.

    Returns:
        `"::" + token + "::"`.
    """
    return "::" + token + "::"


def contains_resume_delimiter(region: String, token: String) -> Bool:
    """Whether `region` contains the resume delimiter for `token`.

    The collision check: if a captured region already contains `::<token>::`
    for a candidate token, fencing that region with that token would let the
    region's own content prematurely re-enable commands.

    Args:
        region: The text to search.
        token: The candidate fencing token.

    Returns:
        True if `resume_delimiter(token)` occurs anywhere in `region`.
    """
    return resume_delimiter(token) in region


def select_collision_free_token(
    region: String, candidates: List[String]
) raises -> String:
    """Pick the first candidate token that does not collide with `region`.

    Draws `candidates` in order, so the eventual fence is collision-proof by
    construction rather than by probability. This function generates no
    randomness: the caller injects the high-entropy, per-run-unique candidate
    source as `candidates`, minted after the producing child has exited and
    never exposed to it.

    Args:
        region: The captured text the chosen token must not collide with.
        candidates: Candidate tokens to try, in order.

    Returns:
        The first candidate whose resume delimiter is absent from `region`,
        copied.

    Raises:
        Error: When every candidate collided with `region`.
    """
    for i in range(len(candidates)):
        if not contains_resume_delimiter(region, candidates[i]):
            return candidates[i].copy()
    raise Error(
        "fencing: every stop-commands candidate token collided with the region"
    )


def stop_commands_opener(token: String) -> String:
    """The GitHub Actions stop-commands opener line for `token`.

    Args:
        token: The fencing token.

    Returns:
        `"::stop-commands::" + token`.
    """
    return "::stop-commands::" + token


def fence_region(token: String, region: String) -> String:
    """Assemble `region` wrapped in stop-commands fencing for `token`.

    Joins the opener, the region, and the resume delimiter with newlines, since
    each workflow command must start its own line. Building the whole fence in
    one expression means the resume delimiter cannot be left out.

    A caller that must interleave writes around a fallible I/O step should use
    `stop_commands_opener` and `resume_delimiter` directly instead, so its own
    always-runs guarantee also covers writing the resume delimiter.

    Args:
        token: The fencing token, already proven collision-free against
            `region`, typically via `select_collision_free_token`.
        region: The captured text to fence.

    Returns:
        `stop_commands_opener(token)`, `region`, and `resume_delimiter(token)`
        joined by newlines.
    """
    return (
        stop_commands_opener(token)
        + "\n"
        + region
        + "\n"
        + resume_delimiter(token)
    )
