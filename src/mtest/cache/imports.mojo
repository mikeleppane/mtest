"""Which modules a Mojo source imports, or the admission that it cannot tell.

Layer 2 (`cache`): pure, no I/O. Source bytes go in, module names come out.

The build cache asks one question of a source file before keying it: does this
file import a module the key's directory walk deliberately left out? The answer
chooses between a precise key and a conservative one, so the scanner carries a
third answer beside yes and no — "I cannot tell" — and every shape it does not
recognize takes that branch. A scanner that guessed would be trading a rebuild
for a wrong verdict, which is the one trade this cache may never make.

What it recognizes, at any indentation, on any line whose text is code:

- `import a`, `import a.b`, `import a as b`, `import a, b.c as d`
- `from a import ...`, `from a.b import ...`

It reports the FIRST dotted component of each, because that is the name the
compiler resolves against a search path; the rest of a `from` line names symbols
inside the module and can never name another one.

What makes it refuse to answer — every case erring toward the conservative key:

- bytes that are not well-formed UTF-8, which the compiler could not read as
  source either
- bytes that do not lex as source: an embedded `0x00`, a string literal still
  open at end of file, or a newline inside a single-quoted literal
- a leading `.` on the module path, a relative form this scanner does not model
- an `import` or `from` line whose remainder does not fit the grammar above,
  including a statement continued onto the next line
- the token `import` on a line that does not START with `import` or `from` —
  the `x = 1; import y` shape, and anything else hiding an import mid-line

Comments and string literals are erased before any of that, so an `import`
inside a docstring or after a `#` is neither an import nor a reason to refuse.
That erasure is what keeps the refusal rare enough to be worth having: prose
about importing is ordinary, and treating it as source would push every file
that contains it onto the conservative path.

The public surface is re-exported from `mtest.cache`.
"""

comptime _ST_CODE = 0
"""Lexer state: outside every literal."""

comptime _ST_SINGLE = 1
"""Lexer state: inside a `'...'` literal."""

comptime _ST_DOUBLE = 2
"""Lexer state: inside a `"..."` literal."""

comptime _ST_TRIPLE_SINGLE = 3
"""Lexer state: inside a `'''...'''` literal."""

comptime _ST_TRIPLE_DOUBLE = 4
"""Lexer state: inside a `\"\"\"...\"\"\"` literal."""


def _byte(text: StaticString) -> UInt8:
    """The single byte of a one-character literal.

    Spelling the punctuation this way keeps the lexer readable without pinning
    ASCII code points into it as bare numbers.

    Args:
        text: A one-byte string.

    Returns:
        Its only byte.
    """
    return text.as_bytes()[0]


def _is_ident_byte(b: UInt8) -> Bool:
    """Whether `b` can appear inside an identifier.

    Every byte above ASCII counts, so a non-ASCII module name is read as one
    token rather than split into pieces that could accidentally match a keyword.

    Args:
        b: The byte to classify.

    Returns:
        True for ASCII letters, digits, `_`, and any byte `>= 0x80`.
    """
    if b >= _byte("A") and b <= _byte("Z"):
        return True
    if b >= _byte("a") and b <= _byte("z"):
        return True
    if b >= _byte("0") and b <= _byte("9"):
        return True
    if b == _byte("_"):
        return True
    return b >= 0x80


def _is_blank_byte(b: UInt8) -> Bool:
    """Whether `b` separates tokens without ending the line.

    A carriage return counts, so a file with CRLF endings parses exactly like
    one with LF endings instead of failing on a trailing byte.

    Args:
        b: The byte to classify.

    Returns:
        True for space, tab, carriage return, and form feed.
    """
    return b == _byte(" ") or b == _byte("\t") or b == _byte("\r") or b == 0x0C


def _skip_blanks(line: List[UInt8], var i: Int) -> Int:
    """The first index at or after `i` that is not a blank.

    Args:
        line: One line of code text.
        i: Where to start.

    Returns:
        The index of the first non-blank byte, or `len(line)`.
    """
    while i < len(line) and _is_blank_byte(line[i]):
        i += 1
    return i


def _ident_end(line: List[UInt8], i: Int) -> Int:
    """The index just past the identifier starting at `i`.

    Args:
        line: One line of code text.
        i: Where the candidate identifier starts.

    Returns:
        The end index, equal to `i` when no identifier starts there.
    """
    var j = i
    while j < len(line) and _is_ident_byte(line[j]):
        j += 1
    return j


def _text_of(line: List[UInt8], start: Int, end: Int) -> String:
    """The bytes of `line` in `[start, end)` as text.

    Args:
        line: One line of code text, from a buffer `scan_imports` has already
            established is well-formed UTF-8.
        start: First index, inclusive. Both ends must sit on an identifier-run
            boundary, which every caller obtains from `_ident_end`.
        end: Last index, exclusive.

    Returns:
        The token's text.
    """
    var out = List[UInt8]()
    for k in range(start, end):
        out.append(line[k])
    # SAFETY: `unsafe_from_utf8` requires `out` to be well-formed UTF-8, and
    # three facts together give that. (1) `scan_imports` refuses any buffer that
    # is not well-formed UTF-8 before a line is ever built, so the source bytes
    # are. (2) `_code_lines` drops bytes only at `#`, `\n`, `"`, and `'`, all
    # ASCII, and an ASCII byte never occurs inside a multi-byte sequence, so no
    # erasure can cut one in half and each line's text is well-formed too.
    # (3) `[start, end)` is bounded at both ends by a byte that is not an
    # identifier byte (or by the line's own edge), while every byte of a
    # multi-byte sequence is `>= 0x80` and therefore IS an identifier byte — so
    # a boundary can never fall inside a sequence.
    return String(StringSlice(unsafe_from_utf8=Span(out)))


@fieldwise_init
struct ImportScan(Copyable, Movable):
    """The modules a source names, or the fact that it could not be read.

    `parsed` is the field to branch on. It is not a failure flag: a source the
    scanner will not draw conclusions from is a perfectly ordinary outcome, and
    the caller's response is to fall back to whatever it would do if the source
    imported everything.

    Examples:

    ```mojo
    from mtest.cache import scan_imports

    var src = List[UInt8]()
    for b in "from helper import value".as_bytes():
        src.append(b)
    var found = scan_imports(src)
    if found.parsed:
        pass  # found.modules == ["helper"]
    ```
    """

    var parsed: Bool
    """True iff every import-bearing construct in the source was recognized."""

    var modules: List[String]
    """The first dotted component of each import found, in source order. Empty
    when `parsed` is False, where it means nothing rather than nothing found."""

    @staticmethod
    def unreadable() -> ImportScan:
        """A source the scanner refuses to draw conclusions from.

        Returns:
            A scan with `parsed` clear and no modules.
        """
        return ImportScan(False, List[String]())


def _is_well_formed_utf8(data: List[UInt8]) -> Bool:
    """Whether `data` decodes as UTF-8.

    The checked `from_utf8` constructor is the decision, so overlong forms,
    surrogates, and truncated sequences are rejected by the same rules the rest
    of the toolchain applies rather than by a second implementation of them.
    Nothing is kept: only the verdict matters, and the slice borrows `data`
    rather than copying it.

    Args:
        data: The whole source file's bytes.

    Returns:
        True iff every byte belongs to a well-formed sequence.
    """
    try:
        _ = StringSlice(from_utf8=Span(data))
    except:
        return False
    return True


def _code_lines(data: List[UInt8]) -> Optional[List[List[UInt8]]]:
    """Split `data` into per-line code text, erasing comments and literals.

    A literal's contents and a comment's contents are dropped rather than
    blanked out, because nothing downstream cares about column positions — only
    about which tokens are code. Newlines inside a triple-quoted literal still
    break lines, so a line number never drifts.

    Args:
        data: The whole source file's bytes.

    Returns:
        One byte list per physical line, or `None` when the bytes do not lex:
        an embedded `0x00`, a literal open at end of file, or a newline inside a
        single-quoted literal. Never raises.
    """
    # Checked over the whole buffer before lexing, not as the lexer passes each
    # byte: a `0x00` inside a comment or a literal would otherwise be skipped
    # along with the rest of it, and the files that carry one — an object file,
    # a UTF-16 source, a truncated write — are exactly the ones whose comment
    # and literal boundaries mean nothing.
    for b in data:
        if b == 0:
            return None
    var lines = List[List[UInt8]]()
    var cur = List[UInt8]()
    var state = _ST_CODE
    var i = 0
    var n = len(data)
    while i < n:
        var b = data[i]
        if state == _ST_CODE:
            if b == _byte("#"):
                while i < n and data[i] != _byte("\n"):
                    i += 1
                continue
            if b == _byte("\n"):
                lines.append(cur^)
                cur = List[UInt8]()
                i += 1
                continue
            if b == _byte('"') or b == _byte("'"):
                if i + 2 < n and data[i + 1] == b and data[i + 2] == b:
                    state = (
                        _ST_TRIPLE_DOUBLE if b
                        == _byte('"') else _ST_TRIPLE_SINGLE
                    )
                    i += 3
                else:
                    state = _ST_DOUBLE if b == _byte('"') else _ST_SINGLE
                    i += 1
                continue
            cur.append(b)
            i += 1
            continue
        if state == _ST_SINGLE or state == _ST_DOUBLE:
            if b == _byte("\n"):
                # A one-line literal cannot span a line, so this file does not
                # lex and no statement in it can be trusted.
                return None
            if b == _byte("\\"):
                if i + 1 < n and data[i + 1] == _byte("\n"):
                    lines.append(cur^)
                    cur = List[UInt8]()
                i += 2
                continue
            var closer = _byte('"') if state == _ST_DOUBLE else _byte("'")
            if b == closer:
                state = _ST_CODE
            i += 1
            continue
        if b == _byte("\n"):
            lines.append(cur^)
            cur = List[UInt8]()
            i += 1
            continue
        if b == _byte("\\"):
            if i + 1 < n and data[i + 1] == _byte("\n"):
                lines.append(cur^)
                cur = List[UInt8]()
            i += 2
            continue
        var quote = _byte('"') if state == _ST_TRIPLE_DOUBLE else _byte("'")
        if (
            b == quote
            and i + 2 < n
            and data[i + 1] == quote
            and data[i + 2] == quote
        ):
            state = _ST_CODE
            i += 3
            continue
        i += 1
    if state != _ST_CODE:
        return None
    lines.append(cur^)
    return Optional(lines^)


def _has_import_token(line: List[UInt8]) -> Bool:
    """Whether the whole token `import` appears anywhere in `line`.

    Whole tokens only: `important` and `reimport` are not it. This is the guard
    that keeps `x = 1; import y` from reading as an ordinary assignment.

    Args:
        line: One line of code text.

    Returns:
        True iff some token on the line is exactly `import`.
    """
    var i = 0
    while i < len(line):
        if _is_ident_byte(line[i]):
            var e = _ident_end(line, i)
            if _text_of(line, i, e) == "import":
                return True
            i = e
        else:
            i += 1
    return False


def _skip_dotted_tail(line: List[UInt8], var i: Int) -> Int:
    """Consume `.name` components after a module path's first component.

    Args:
        line: One line of code text.
        i: The index just past the first component.

    Returns:
        The index just past the last component, or `-1` when a `.` is not
        followed by an identifier.
    """
    while i < len(line) and line[i] == _byte("."):
        i += 1
        var e = _ident_end(line, i)
        if e == i:
            return -1
        i = e
    return i


def _parse_import_list(
    line: List[UInt8], var i: Int, mut modules: List[String]
) -> Bool:
    """Parse `a.b as c, d` — everything after an `import` keyword.

    Args:
        line: One line of code text.
        i: The index just past the `import` keyword.
        modules: Each module path's first component is appended here.

    Returns:
        True iff the whole remainder of the line fits the grammar.
    """
    while True:
        i = _skip_blanks(line, i)
        var e = _ident_end(line, i)
        if e == i:
            return False
        modules.append(_text_of(line, i, e))
        i = _skip_dotted_tail(line, e)
        if i < 0:
            return False
        i = _skip_blanks(line, i)
        var kw_end = _ident_end(line, i)
        if kw_end > i and _text_of(line, i, kw_end) == "as":
            i = _skip_blanks(line, kw_end)
            var alias_end = _ident_end(line, i)
            if alias_end == i:
                return False
            i = _skip_blanks(line, alias_end)
        if i < len(line) and line[i] == _byte(","):
            i += 1
            continue
        break
    # Anything left over is a form this scanner does not model — a line
    # continuation, a parenthesis, a second statement — and each of those could
    # carry an import the caller must not be told is absent.
    return i >= len(line)


def _parse_from(
    line: List[UInt8], var i: Int, mut modules: List[String]
) -> Bool:
    """Parse `a.b import ...` — everything after a `from` keyword.

    Args:
        line: One line of code text.
        i: The index just past the `from` keyword.
        modules: The module path's first component is appended here, and only
            once the `import` keyword has been seen, so a refused line
            contributes nothing.

    Returns:
        True iff a module path followed by `import` was found. What comes after
        `import` names symbols inside that module, so it is not examined.
    """
    i = _skip_blanks(line, i)
    if i < len(line) and line[i] == _byte("."):
        return False
    var e = _ident_end(line, i)
    if e == i:
        return False
    var first = _text_of(line, i, e)
    i = _skip_dotted_tail(line, e)
    if i < 0:
        return False
    i = _skip_blanks(line, i)
    var kw_end = _ident_end(line, i)
    if kw_end == i or _text_of(line, i, kw_end) != "import":
        return False
    modules.append(first^)
    return True


def _scan_line(line: List[UInt8], mut modules: List[String]) -> Bool:
    """Read one line of code text for imports.

    Args:
        line: The line's code text, comments and literals already erased.
        modules: Every module name found is appended here.

    Returns:
        True when the line was understood — which includes the ordinary case of
        a line that imports nothing.
    """
    var i = _skip_blanks(line, 0)
    var e = _ident_end(line, i)
    if e > i:
        var head = _text_of(line, i, e)
        if head == "import":
            return _parse_import_list(line, e, modules)
        if head == "from":
            return _parse_from(line, e, modules)
    return not _has_import_token(line)


def scan_imports(data: List[UInt8]) -> ImportScan:
    """The modules a Mojo source imports, or a refusal to say.

    Args:
        data: The whole source file's bytes.

    Returns:
        A scan whose `parsed` says whether the answer may be relied on, and
        whose `modules` holds the first dotted component of every import found,
        in source order and with duplicates kept. Never raises: this is asked
        about files that arrived from a filesystem, where any byte sequence is
        possible, and bytes that are not UTF-8 are one more refusal rather than
        an error.

    Examples:

    ```mojo
    from mtest.cache import scan_imports

    var src = List[UInt8]()
    for b in "import a.b as c, d".as_bytes():
        src.append(b)
    var found = scan_imports(src)
    print(found.parsed, len(found.modules))  # True 2
    ```
    """
    # Checked before anything is tokenized, because an identifier byte is any
    # byte at or above 0x80: a Latin-1 module name, a truncated multi-byte
    # sequence, or a binary blob renamed `.mojo` would otherwise lex into a
    # token whose bytes are not text. The compiler reads source as UTF-8, so a
    # file that is not UTF-8 is one this scanner has no business drawing
    # conclusions about, and refusing widens the key — the right answer for a
    # file nothing here can read.
    if not _is_well_formed_utf8(data):
        return ImportScan.unreadable()
    var lines = _code_lines(data)
    if not lines:
        return ImportScan.unreadable()
    var text = lines.value().copy()
    var modules = List[String]()
    for idx in range(len(text)):
        if not _scan_line(text[idx], modules):
            return ImportScan.unreadable()
    return ImportScan(True, modules^)
