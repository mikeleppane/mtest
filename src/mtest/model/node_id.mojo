"""Node identifiers: `NodeId`, the raw selection-token splitter, and `render`'s
inverse.

A `NodeId` is a test's lexical identity: the file's root-relative path as
discovered or as the user typed it, plus the test function name. It is
deliberately lexical, not canonical. Canonical path identity (realpath, symlink
resolution) is a separate concern that lives elsewhere. `render()` produces the
single canonical string form, `path::name`, used for display, selection, and
repro lines.

`split_node_token` is the policy-free half of turning a raw CLI operand into a
`NodeId`: it counts `::` occurrences and splits at the first one, deciding
nothing further. The caller turns a `sep_count` of 0, 1, or 2-or-more into
"plain file operand", "node id", or "malformed", because that policy differs by
call site.

`split_rendered_node_id` is the other direction and splits at the LAST `::`,
because it undoes `render()` on an id the runner itself produced rather than
parsing something a user typed.
"""


@fieldwise_init
struct NodeId(Copyable, Equatable, Movable):
    """A test's lexical identity: a root-relative path and a test name.

    Owns its two String fields, so copies are explicit via `.copy()`.

    Examples:

    ```mojo
    from mtest.model import NodeId

    var node = NodeId("tests/test_a.mojo", "test_foo")
    var rendered = node.render()  # "tests/test_a.mojo::test_foo"
    ```
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

    Examples:

    ```mojo
    from mtest.model import split_node_token

    var split = split_node_token("tests/test_a.mojo::test_foo")
    var is_node_id = split.sep_count == 1  # True
    var path = split.file_part  # "tests/test_a.mojo"
    var name = split.name_part  # "test_foo"
    ```
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


def split_rendered_node_id(node_id: String) -> NodeId:
    """Recover the `NodeId` behind a string `render()` produced.

    Splits at the LAST `::`, which is what makes this the exact inverse of
    `render()`: a test name is a Mojo identifier and can never contain `::`,
    while a file path can, so only the final separator reconstructs the pair.
    `split_node_token` splits at the FIRST one on purpose — its callers parse
    raw user operands, where a second separator means a malformed node id they
    refuse rather than a path to keep whole.

    Args:
        node_id: A rendered `path::name` string produced by this runner.

    Returns:
        The recovered identity, freshly allocated. A string carrying no `::`
        at all is not a rendered node id; it comes back whole as `path` with an
        empty `name`, mirroring `split_node_token`'s degenerate case rather
        than trapping.

    Examples:

    ```mojo
    from mtest.model import split_rendered_node_id

    var node = split_rendered_node_id("we::ird/test_a.mojo::test_foo")
    var path = node.path  # "we::ird/test_a.mojo"
    var name = node.name  # "test_foo"
    ```
    """
    var last = node_id.rfind("::")
    if last == -1:
        return NodeId(node_id, "")
    return NodeId(
        String(node_id[byte=:last]), String(node_id[byte = last + 2 :])
    )
