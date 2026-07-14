"""An fnmatch-style glob matcher (the stdlib has none).

`discover` needs glob matching in two places: the `test_*.mojo` gate on directory
walks (matched against a file's basename) and `--exclude GLOB` (matched against a
whole root-relative path). Both go through `fnmatch` here.

The supported metacharacters mirror POSIX `fnmatch`:

- `*` matches any run of characters, **including `/`** (documented in the
  command-line contract — an exclude glob is matched against the whole path, not
  segment by segment).
- `?` matches exactly one character.
- `[...]` is a character class: `[abc]`, ranges `[a-z]`, and negation `[!...]`.
  A `]` immediately after `[` or `[!` is a literal member; an unterminated `[`
  is treated as a literal `[`.
- Every other character matches itself. A pattern with no metacharacter therefore
  matches by exact equality, which is the contract's "plain path" rule.

Matching is over Unicode codepoints, so `?` matches one codepoint (not one UTF-8
byte). The matcher is anchored: it succeeds only on a full-string match.
"""

# Codepoint values of the metacharacters, named so the matcher reads clearly.
comptime _STAR = 42  # '*'
comptime _QUESTION = 63  # '?'
comptime _LBRACK = 91  # '['
comptime _RBRACK = 93  # ']'
comptime _BANG = 33  # '!'
comptime _DASH = 45  # '-'


def _codes(s: String) -> List[Int]:
    """The codepoint values of `s`, in order."""
    var out = List[Int]()
    for cp in s.codepoints():
        out.append(Int(cp))
    return out^


@fieldwise_init
struct _ClassMatch(Copyable, Movable):
    """The result of matching one character against a `[...]` class."""

    var matched: Bool
    """Whether the candidate character is a member of the class."""

    var next: Int
    """The pattern index just past the class (past the closing `]`)."""


def _class_at(p: List[Int], open_idx: Int, ch: Int) -> _ClassMatch:
    """Match one character against a `[...]` class starting at `open_idx`.

    Args:
        p: The pattern as codepoints; `p[open_idx]` is `[`.
        open_idx: Index of the opening `[`.
        ch: The candidate character (a codepoint) to test.

    Returns:
        A `_ClassMatch`: whether `ch` is in the class and the pattern index just
        past the closing `]`. An unterminated class is treated as a literal `[`,
        i.e. `matched = (ch == '[')` and `next = open_idx + 1`.
    """
    var j = open_idx + 1
    var negate = False
    if j < len(p) and p[j] == _BANG:
        negate = True
        j += 1
    var matched = False
    var first = True
    while j < len(p):
        if p[j] == _RBRACK and not first:
            return _ClassMatch(matched != negate, j + 1)
        first = False
        if j + 2 < len(p) and p[j + 1] == _DASH and p[j + 2] != _RBRACK:
            if ch >= p[j] and ch <= p[j + 2]:
                matched = True
            j += 3
        else:
            if ch == p[j]:
                matched = True
            j += 1
    # No closing bracket: the '[' was a literal.
    return _ClassMatch(ch == _LBRACK, open_idx + 1)


def _match(p: List[Int], pi_in: Int, n: List[Int], ni_in: Int) -> Bool:
    """Whether pattern `p` from `pi_in` matches name `n` from `ni_in`.

    A backtracking matcher: `*` recurses over every split of the remaining name,
    which is fine for the short paths `discover` handles.
    """
    var pi = pi_in
    var ni = ni_in
    while pi < len(p):
        var c = p[pi]
        if c == _STAR:
            while pi < len(p) and p[pi] == _STAR:
                pi += 1
            if pi == len(p):
                return True
            var k = ni
            while k <= len(n):
                if _match(p, pi, n, k):
                    return True
                k += 1
            return False
        if ni >= len(n):
            return False
        if c == _QUESTION:
            pi += 1
            ni += 1
        elif c == _LBRACK:
            var res = _class_at(p, pi, n[ni])
            if not res.matched:
                return False
            pi = res.next
            ni += 1
        else:
            if c != n[ni]:
                return False
            pi += 1
            ni += 1
    return ni == len(n)


def fnmatch(name: String, pattern: String) -> Bool:
    """Whether `name` matches the glob `pattern` (anchored, whole-string).

    Args:
        name: The string to test (a basename, or a whole root-relative path).
        pattern: The glob: `*` (crosses `/`), `?`, `[...]`, else literal.

    Returns:
        `True` iff the entire `name` is matched by the entire `pattern`. A
        metacharacter-free pattern matches by exact equality.
    """
    return _match(_codes(pattern), 0, _codes(name), 0)
