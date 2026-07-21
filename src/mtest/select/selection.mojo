"""Pure selection logic: operand parsing and universe->selected/deselected.

This module is the pure, filesystem-free heart of the selection pipeline. It
turns raw CLI operands into a per-file selection intent (operand parsing) and
folds a file's collected test universe together with that intent and the `-k`
keyword into the selected and deselected name sets (selection). It imports only
`model`, for the raw node-token splitter, and performs no I/O.

Two policies live here and are not the session's to re-derive:

- Operand parsing. A raw operand is split at its first `::`. Zero `::` is a
  plain file or directory operand, whose files are selected whole; exactly one
  `::` is a node id, whose `file_part` is a file operand and `name_part` a
  selected name; more than one `::` is a malformed node id and raises the
  exit-4 usage error.
- Selection. The base is the whole universe, or the intent's validated
  name-set. `-k` then intersects that base, keeping names whose `rel::name`
  contains the keyword as a case-insensitive substring. An explicit name absent
  from the universe raises the exit-4 unknown-test error, never a malformed
  node id error.
"""
from mtest.model import NodeIdSplit, split_node_token


@fieldwise_init
struct NamedTarget(Copyable, Movable):
    """One node-id operand: the file it named and the test name it selected."""

    var file_part: String
    """The operand text before the `::` — the file the node id implies."""
    var name: String
    """The operand text after the `::` — a selected test name for that file."""


@fieldwise_init
struct OperandParse(Copyable, Movable):
    """The result of parsing the raw operands. Owns its lists."""

    var has_node_id: Bool
    """Whether any operand carried a `::` node id, activating name selection."""
    var plain_operands: List[String]
    """The operands with no `::` — file or directory operands, taken whole."""
    var named_targets: List[NamedTarget]
    """Every node-id operand as a (file_part, name) pair."""


@fieldwise_init
struct FileIntent(Copyable, Movable):
    """One file's selection intent: whole, or an explicit set of test names."""

    var whole: Bool
    """Whether a plain operand covered this file, making every test the base."""
    var names: List[String]
    """The explicitly named tests when not whole (empty when whole)."""

    @staticmethod
    def whole_file() -> FileIntent:
        """A file selected whole.

        Returns:
            An intent whose base is every collected test in the file.
        """
        return FileIntent(True, List[String]())

    @staticmethod
    def named(var names: List[String]) -> FileIntent:
        """A file selected by an explicit set of test names.

        Args:
            names: The explicitly named tests. Consumed; the returned intent
                owns it.

        Returns:
            A non-whole intent carrying `names`.
        """
        return FileIntent(False, names^)


@fieldwise_init
struct SelectionResult(Copyable, Movable):
    """The outcome of selecting from a file's universe. Owns its lists."""

    var selected: List[String]
    """The surviving test names, in universe order."""
    var deselected: List[String]
    """The universe minus the selected names, in universe order."""


def selection_active(paths: List[String], keyword: String) -> Bool:
    """Whether the selection pipeline is active for this invocation.

    Selection is active iff any operand is a node id (`::`) or a `-k` keyword
    is present; otherwise the runner keeps its default whole-file path.

    Args:
        paths: The raw positional operands.
        keyword: The `-k` keyword, empty when the flag was not given.

    Returns:
        True when the selection pipeline must run for this invocation.
    """
    if keyword != "":
        return True
    for p in paths:
        if "::" in p:
            return True
    return False


def parse_operands(paths: List[String]) raises -> OperandParse:
    """Parse raw operands into the per-invocation selection intent.

    Args:
        paths: The raw positional operands, unvalidated.

    Returns:
        The parse: whether any node id was present, the plain operands, and the
        node-id targets.

    Raises:
        Error: A `select:`-prefixed usage error (exit-4 class) for an operand
            with more than one `::` — a malformed node id, never an unknown
            test.
    """
    var plain = List[String]()
    var named = List[NamedTarget]()
    var has_node_id = False
    for op in paths:
        var split = split_node_token(op)
        if split.sep_count > 1:
            raise Error(
                "select: malformed node id '"
                + op
                + "': a node id is PATH::TEST with a single '::' (see mtest"
                + " --help)"
            )
        if split.sep_count == 0:
            plain.append(String(op))
        else:
            has_node_id = True
            named.append(NamedTarget(split.file_part, split.name_part))
    return OperandParse(has_node_id, plain^, named^)


def _lower_ascii(s: String) -> String:
    """`s` with every ASCII A-Z lowercased; other bytes unchanged.

    Byte-wise and UTF-8 safe: an ASCII `A`-`Z` byte (0x41-0x5A) can never appear
    inside a multibyte UTF-8 sequence (whose bytes are all >= 0x80), so folding
    those bytes alone never corrupts a codepoint.
    """
    var src = s.as_bytes()
    var out = List[UInt8](capacity=len(src))
    for b in src:
        var v = Int(b)
        if v >= 65 and v <= 90:
            out.append(UInt8(v + 32))
        else:
            out.append(b)
    # SAFETY: `s` began as valid UTF-8 and only standalone ASCII A-Z bytes were
    # replaced by same-width ASCII a-z; continuation/leading bytes are unchanged.
    # `out` owns the complete initialized bytes until String copies the Span.
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def contains_ci(haystack: String, needle: String) -> Bool:
    """Whether `needle` is a case-insensitive substring of `haystack`.

    Case folding is ASCII-only, which is sufficient for test-name keywords. An
    empty `needle` matches everything.
    """
    if needle == "":
        return True
    return _lower_ascii(needle) in _lower_ascii(haystack)


def _contains(items: List[String], needle: String) -> Bool:
    """Whether `needle` equals any element of `items`."""
    for x in items:
        if x == needle:
            return True
    return False


def select_from(
    universe: List[String], rel: String, intent: FileIntent, keyword: String
) raises -> SelectionResult:
    """Fold a file's universe, intent, and keyword into selected/deselected.

    The base is the universe (a whole file) or the intent's explicit name-set;
    `-k` then intersects the base, keeping a name only when `rel::name` contains
    the keyword as a case-insensitive substring. `selected` and `deselected`
    partition the universe and preserve universe order.

    Args:
        universe: The file's collected test names, in discovery order.
        rel: The file's root-relative path (the `rel::name` keyword scope).
        intent: The file's selection intent (whole, or an explicit name-set).
        keyword: The `-k` expression (empty disables the keyword filter).

    Returns:
        The selected and deselected name partitions.

    Raises:
        Error: A `select:`-prefixed usage error (exit-4 class) naming
            `rel::name` when an explicitly named test is not in the universe —
            an unknown test.
    """
    # Validate every explicitly named test against the universe first, so an
    # unknown name is a usage error rather than a silent empty selection.
    if not intent.whole:
        for nm in intent.names:
            if not _contains(universe, nm):
                raise Error(
                    "select: unknown test '"
                    + rel
                    + "::"
                    + nm
                    + "' — not among the file's collected tests (see mtest"
                    + " --help)"
                )

    var selected = List[String]()
    var deselected = List[String]()
    for u in universe:
        var in_base = intent.whole or _contains(intent.names, u)
        var kw_ok = keyword == "" or contains_ci(rel + "::" + u, keyword)
        if in_base and kw_ok:
            selected.append(String(u))
        else:
            deselected.append(String(u))
    return SelectionResult(selected^, deselected^)
