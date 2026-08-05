"""The GitHub Actions stop-commands fencing protocol for the report layer.

GitHub Actions lets a workflow disable command processing with
`::stop-commands::<token>` and re-enable it with `::<token>::`. mtest fences
untrusted captured child output between those markers so the output can never
forge a workflow command. This module supplies the whole protocol: minting the
per-run candidate tokens, the resume-delimiter predicate, collision-free
selection among the candidates, and the fenced-output assembly.

Everything but `mint_fence_tokens` is a pure string operation; that one reads
`/dev/urandom`, and a caller mints only after the producing child has exited so
the token is never exposed to it. The module shares no private helper with the
escapers in `escape.mojo`: escaping and fencing are separate concerns, so they
live in separate modules.
"""

comptime _HEX: StaticString = "0123456789abcdef"
"""Lowercase hex alphabet for rendering a token's random bytes."""

comptime _FENCE_TOKEN_BYTES = 16
"""Random bytes per fence token candidate; 16 bytes is 128 bits of entropy."""

comptime FENCE_TOKEN_POOL = 4
"""How many independent candidate tokens to mint per run. A region that already
contains the primary token's resume delimiter falls through to the next
candidate; four independent 128-bit tokens make an all-collision draw
impossible in practice."""


def mint_fence_tokens(count: Int) raises -> List[String]:
    """Mint `count` independent high-entropy fence tokens from `/dev/urandom`.

    Each token is `_FENCE_TOKEN_BYTES` random bytes rendered as lowercase hex,
    giving 128 bits of entropy apiece, unique per run. The entropy comes from
    ordinary std file I/O; the exec and native layers are never touched.

    Args:
        count: How many tokens to mint.

    Returns:
        `count` hex token strings, in draw order. Allocates.

    Raises:
        Error: When `/dev/urandom` could not be read or returned a short read.
            The caller withholds the region it meant to fence rather than emit
            it unfenced.
    """
    var need = count * _FENCE_TOKEN_BYTES
    var raw: List[UInt8]
    with open("/dev/urandom", "r") as f:
        raw = f.read_bytes(need)
    if len(raw) < need:
        raise Error("fencing: short read from /dev/urandom for fence tokens")
    var out = List[String]()
    for t in range(count):
        var token = String("")
        for b in range(_FENCE_TOKEN_BYTES):
            var v = Int(raw[t * _FENCE_TOKEN_BYTES + b])
            token += String(_HEX[byte=v >> 4])
            token += String(_HEX[byte=v & 0xF])
        out.append(token^)
    return out^


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

    Examples:

    ```mojo
    from mtest.report.fencing import select_collision_free_token

    var candidates: List[String] = ["badtoken", "goodtoken"]
    var token = select_collision_free_token("junk ::badtoken::", candidates)
    ```
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

    Examples:

    ```mojo
    from mtest.report.fencing import fence_region

    var fenced = fence_region("tok1", "captured child output, benign")
    ```
    """
    return (
        stop_commands_opener(token)
        + "\n"
        + region
        + "\n"
        + resume_delimiter(token)
    )
