"""Node identifiers: `NodeId` (lexical) and the raw-token splitter (Layer 0).

A `NodeId` is a test's lexical identity: the file's root-relative path as
discovered or as the user typed it, plus the test function name. It is
deliberately LEXICAL, not canonical -- canonical path identity (realpath,
symlink resolution) is a separate concern that lives elsewhere. `render()`
produces the single canonical string form (`path::name`) used for display,
selection, and repro lines.

`split_node_token` is the pure, policy-free half of turning a raw CLI operand
into a `NodeId`: it counts `::` occurrences and splits at the first one. It
raises nothing and decides nothing -- the caller (the session) is the one that
turns a `sep_count` of 0/1/(>=2) into "plain file operand" / "node id" /
"malformed", because that policy differs by call site.
"""


@fieldwise_init
struct NodeId(Copyable, Equatable, Movable):
    """A test's lexical identity: a root-relative path and a test name.

    Owns its two String fields, so copies are explicit via `.copy()`; equality
    and rendering never mutate or raise.
    """

    var path: String
    """The file's root-relative, LEXICAL path (not a realpath)."""
    var name: String
    """The test function name; nonempty and `::`-free for a real node."""

    def render(self) -> String:
        """The canonical node-id string: `path::name`. Never raises."""
        return self.path + "::" + self.name

    def __eq__(self, other: Self) -> Bool:
        """Equal iff BOTH `path` and `name` match. Never raises."""
        return self.path == other.path and self.name == other.name

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Never raises."""
        return not (self == other)


@fieldwise_init
struct NodeIdSplit(ImplicitlyCopyable, Movable):
    """The pure result of splitting a raw selection token at its first `::`.

    A trivial value carrying no policy: it counts `::` occurrences and splits
    at the first one, leaving the caller to decide what a given `sep_count`
    means.
    """

    var sep_count: Int
    """How many non-overlapping `::` occurrences the token contains."""
    var file_part: String
    """Text before the first `::` (the whole token when `sep_count == 0`)."""
    var name_part: String
    """Text after the first `::` (empty when `sep_count == 0`)."""


def split_node_token(token: String) -> NodeIdSplit:
    """Split a raw selection token at its first `::`, with no policy.

    Counts every non-overlapping `::` occurrence and splits only at the first;
    the caller decides what a `sep_count` of 0/1/(>=2) means. Pure; never
    raises.

    Args:
        token: The raw operand text, unvalidated.

    Returns:
        The split, with `sep_count` = 0 meaning `file_part` is the whole
        token and `name_part` is empty. Allocates the two owned Strings.
    """
    var all_parts = token.split("::")
    var sep_count = len(all_parts) - 1
    if sep_count == 0:
        return NodeIdSplit(sep_count=0, file_part=token, name_part="")
    var first = token.split("::", 1)
    return NodeIdSplit(
        sep_count=sep_count,
        file_part=String(first[0]),
        name_part=String(first[1]),
    )
