"""Node identifiers: `NodeId` and the raw selection-token splitter.

A `NodeId` is a test's lexical identity: the file's root-relative path as
discovered or as the user typed it, plus the test function name. It is
deliberately lexical, not canonical -- canonical path identity (realpath,
symlink resolution) is a separate concern that lives elsewhere. `render()`
produces the single canonical string form, `path::name`, used for display,
selection, and repro lines.

`split_node_token` is the policy-free half of turning a raw CLI operand into a
`NodeId`: it counts `::` occurrences and splits at the first one, deciding
nothing further. The caller turns a `sep_count` of 0, 1, or 2-or-more into
"plain file operand", "node id", or "malformed", because that policy differs by
call site.
"""


@fieldwise_init
struct NodeId(Copyable, Equatable, Movable):
    """A test's lexical identity: a root-relative path and a test name.

    Owns its two String fields, so copies are explicit via `.copy()`.
    """

    var path: String
    """The file's root-relative, lexical path, not a realpath."""
    var name: String
    """The test function name; nonempty and `::`-free for a real node."""

    def render(self) -> String:
        """The canonical node-id string, `path::name`."""
        return self.path + "::" + self.name

    def __eq__(self, other: Self) -> Bool:
        """Equal iff both `path` and `name` match."""
        return self.path == other.path and self.name == other.name

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`."""
        return not (self == other)


@fieldwise_init
struct NodeIdSplit(ImplicitlyCopyable, Movable):
    """The result of splitting a raw selection token at its first `::`.

    Carries no policy: it records how many separators the token held and where
    the first one fell, leaving the caller to decide what a given `sep_count`
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

    Counts every non-overlapping `::` occurrence but splits only at the first;
    the caller decides what a given `sep_count` means.

    Args:
        token: The raw operand text, unvalidated.

    Returns:
        The split. A `sep_count` of 0 means `file_part` is the whole token and
        `name_part` is empty.
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
