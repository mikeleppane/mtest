"""Machine-text escaping primitives shared by every machine reporter (Layer 2).

mtest renders three machine-consumed streams from the same untrusted,
child-process-controlled text: the JSON/NDJSON event stream, the JUnit XML
report, and GitHub Actions annotations. All three would otherwise duplicate
the same escaping logic against the same hostile input (captured
stdout/stderr, test names, assertion detail, paths), so it lives here ONCE.

Every string reaching these escapers has already passed through
`lossy_utf8` (Layer 1) upstream, so it is guaranteed valid UTF-8 with no lone
surrogates and no raw invalid bytes; these escapers never re-decode. They work
byte-for-byte: every delimiter they act on (`"`, `\\`, `&`, `<`, `>`, `%`,
`:`, `,`, and the C0 control bytes) is a single ASCII byte, so a plain byte
scan that copies every other byte straight through can never split a
multi-byte UTF-8 sequence or misinterpret a continuation byte.

Also here: the pure core of the collision-proof `::stop-commands::<token>`
fencing GitHub Actions requires to safely echo untrusted captured output
without letting it forge workflow commands. The entropy source that mints the
real per-run token is NOT this module's job (it wires in later, after the
producing child has exited); this module only provides the resume-delimiter
predicate, collision-free token selection over an injected candidate source,
and the fenced-output assembly.

Pure throughout: no I/O, no globals, no randomness.
"""

comptime _FFFD: StaticString = "�"
"""The Unicode replacement character, U+FFFD, encoded as UTF-8 (3 bytes)."""


def _push_str(mut out: List[UInt8], text: String):
    """Append every byte of `text` to `out`, in order. Pure; never raises."""
    for b in text.as_bytes():
        out.append(b)


def _hex_nibble(v: Int) -> UInt8:
    """The lowercase ASCII hex digit byte for a nibble `0 <= v <= 15`. Pure."""
    if v < 10:
        return UInt8(48 + v)  # '0'..'9'
    return UInt8(87 + v)  # 'a'..'f' (97 - 10 = 87)


def _bytes_to_string(bytes: List[UInt8]) -> String:
    """Render `bytes` as a `String`. Pure; the caller guarantees valid UTF-8."""
    # SAFETY: `unsafe_from_utf8` requires `bytes` to be well-formed UTF-8. Every
    # caller here builds `bytes` by copying whole bytes of already-valid-UTF-8
    # input through unchanged and inserting only single-byte ASCII escape
    # sequences or the fixed 3-byte U+FFFD encoding (EF BF BD) — no multi-byte
    # sequence is ever split and no invalid byte is introduced, so the buffer is
    # valid UTF-8 by construction.
    return String(StringSlice(unsafe_from_utf8=Span(bytes)))


def json_escape_string(s: String) -> String:
    """Escape `s` for use inside a JSON string literal. Pure.

    `"` becomes `\\"`, `\\` becomes `\\\\`, and every other control byte below
    0x20 becomes `\\n`/`\\r`/`\\t` (the three short forms) or `\\u00XX`
    otherwise. Every other byte — including a valid multi-byte UTF-8 sequence
    or an embedded U+FFFD — passes through unchanged: `s` is already valid
    UTF-8 (decoded upstream via `lossy_utf8`), so a plain byte copy can never
    corrupt a sequence, and JSON strings do not require escaping non-ASCII
    text. Callers own the number policy (integer microseconds, strict
    consumer) separately; this escapes STRING content only.

    Args:
        s: The already-UTF-8-valid text to escape. Not mutated.

    Returns:
        `s` with `"`, `\\`, and every C0 control byte escaped. Does not raise.
    """
    var out = List[UInt8]()
    for b in s.as_bytes():
        var v = Int(b)
        if v == 34:  # '"'
            _push_str(out, '\\"')
        elif v == 92:  # '\'
            _push_str(out, "\\\\")
        elif v == 10:  # '\n'
            _push_str(out, "\\n")
        elif v == 13:  # '\r'
            _push_str(out, "\\r")
        elif v == 9:  # '\t'
            _push_str(out, "\\t")
        elif v < 0x20:
            _push_str(out, "\\u00")
            out.append(_hex_nibble(v >> 4))
            out.append(_hex_nibble(v & 0xF))
        else:
            out.append(b)
    return _bytes_to_string(out)


def _string_bytes(s: String) -> List[UInt8]:
    """A copy of `s`'s UTF-8 bytes as an owned, indexable list. Pure."""
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _is_xml_noncharacter(data: List[UInt8], i: Int) -> Bool:
    """Whether an XML-1.0-forbidden noncharacter begins at byte `i`. Pure.

    XML 1.0's `Char` production excludes U+FFFE and U+FFFF (its BMP range stops
    at U+FFFD): they are valid UTF-8 scalars — `EF BF BE` and `EF BF BF` — that
    `lossy_utf8` correctly passes through, but a document containing them is
    well-formed UTF-8 yet illegal XML 1.0 (`xmllint` rejects it). Detected here
    (input is already valid UTF-8) so the XML escapers can replace them; JSON,
    which permits these scalars, is unaffected.
    """
    if i + 3 > len(data):
        return False
    if Int(data[i]) != 0xEF or Int(data[i + 1]) != 0xBF:
        return False
    var last = Int(data[i + 2])
    return last == 0xBE or last == 0xBF


def xml_escape_text(s: String) -> String:
    """Escape `s` for XML TEXT content (element body text). Pure.

    `&` `<` `>` become entities. Literal Tab/LF/CR pass through unchanged
    (they are valid XML 1.0 `Char`s and TEXT context does not normalize
    whitespace). Every other control byte below 0x20 — and the XML-forbidden
    noncharacters U+FFFE/U+FFFF — an invalid XML 1.0 code point, is REPLACED
    with U+FFFD, not escaped, per the settled design. No CDATA is ever emitted.
    Every other byte passes through unchanged.

    Args:
        s: The already-UTF-8-valid text to escape. Not mutated.

    Returns:
        `s` escaped for a well-formed XML 1.0 text node. Does not raise.
    """
    var data = _string_bytes(s)
    var n = len(data)
    var out = List[UInt8]()
    var i = 0
    while i < n:
        if _is_xml_noncharacter(data, i):  # U+FFFE/U+FFFF: illegal XML 1.0.
            _push_str(out, _FFFD)
            i += 3
            continue
        var v = Int(data[i])
        if v == 38:  # '&'
            _push_str(out, "&amp;")
        elif v == 60:  # '<'
            _push_str(out, "&lt;")
        elif v == 62:  # '>'
            _push_str(out, "&gt;")
        elif v == 9 or v == 10 or v == 13:  # Tab, LF, CR: valid, pass through.
            out.append(data[i])
        elif v < 0x20:  # Invalid XML 1.0 control code point.
            _push_str(out, _FFFD)
        else:
            out.append(data[i])
        i += 1
    return _bytes_to_string(out)


def xml_escape_attribute(s: String) -> String:
    """Escape `s` for an XML ATTRIBUTE value. Pure.

    Adds `"` -> `&quot;` on top of the TEXT-context entity set (`&` `<` `>`).
    Unlike TEXT context, literal Tab/LF/CR are emitted as numeric character
    references — `&#9;` / `&#10;` / `&#13;` — rather than passed through
    literally: attribute-value normalization would otherwise fold them to an
    ordinary space and silently corrupt a hostile node-id path reconstructed
    from the attribute. Every other control byte below 0x20 — and the
    XML-forbidden noncharacters U+FFFE/U+FFFF — is REPLACED with U+FFFD,
    identically to TEXT context. No CDATA is ever emitted.

    Args:
        s: The already-UTF-8-valid text to escape. Not mutated.

    Returns:
        `s` escaped for a well-formed, round-trip-safe XML 1.0 attribute
        value. Does not raise.
    """
    var data = _string_bytes(s)
    var n = len(data)
    var out = List[UInt8]()
    var i = 0
    while i < n:
        if _is_xml_noncharacter(data, i):  # U+FFFE/U+FFFF: illegal XML 1.0.
            _push_str(out, _FFFD)
            i += 3
            continue
        var v = Int(data[i])
        if v == 38:  # '&'
            _push_str(out, "&amp;")
        elif v == 60:  # '<'
            _push_str(out, "&lt;")
        elif v == 62:  # '>'
            _push_str(out, "&gt;")
        elif v == 34:  # '"'
            _push_str(out, "&quot;")
        elif v == 9:  # '\t'
            _push_str(out, "&#9;")
        elif v == 10:  # '\n'
            _push_str(out, "&#10;")
        elif v == 13:  # '\r'
            _push_str(out, "&#13;")
        elif v < 0x20:  # Invalid XML 1.0 control code point.
            _push_str(out, _FFFD)
        else:
            out.append(data[i])
        i += 1
    return _bytes_to_string(out)


def gh_escape_message(s: String) -> String:
    """Escape `s` for a GitHub Actions workflow-command MESSAGE payload. Pure.

    `%` becomes `%25`, CR becomes `%0D`, LF becomes `%0A` — `%` is escaped
    first (in scan order, ahead of CR/LF) so the `%` a CR/LF escape itself
    emits is never re-escaped. Every other byte, including `:` and `,`,
    passes through unchanged.

    Args:
        s: The already-UTF-8-valid text to escape. Not mutated.

    Returns:
        `s` escaped for a workflow-command message field. Does not raise.
    """
    var out = List[UInt8]()
    for b in s.as_bytes():
        var v = Int(b)
        if v == 37:  # '%'
            _push_str(out, "%25")
        elif v == 13:  # '\r'
            _push_str(out, "%0D")
        elif v == 10:  # '\n'
            _push_str(out, "%0A")
        else:
            out.append(b)
    return _bytes_to_string(out)


def gh_escape_property(s: String) -> String:
    """Escape `s` for a GitHub Actions workflow-command PROPERTY value. Pure.

    Applies the message escape set first (`%` -> `%25`, CR -> `%0D`,
    LF -> `%0A`), then additionally escapes `:` -> `%3A` and `,` -> `%2C` —
    property values use both as field/record separators in the workflow
    command grammar. The two-pass composition is safe because none of the
    message-set replacement text (`%25`, `%0D`, `%0A`) ever contains a
    literal `:` or `,`.

    Args:
        s: The already-UTF-8-valid text to escape. Not mutated.

    Returns:
        `s` escaped for a workflow-command property value. Does not raise.
    """
    var msg_escaped = gh_escape_message(s)
    var out = List[UInt8]()
    for b in msg_escaped.as_bytes():
        var v = Int(b)
        if v == 58:  # ':'
            _push_str(out, "%3A")
        elif v == 44:  # ','
            _push_str(out, "%2C")
        else:
            out.append(b)
    return _bytes_to_string(out)


def resume_delimiter(token: String) -> String:
    """The complete GitHub Actions stop-commands resume delimiter. Pure.

    The exact string `::<token>::` — the only text sequence that re-enables
    workflow-command processing once `::stop-commands::<token>` has disabled
    it.

    Args:
        token: The fencing token. Not mutated.

    Returns:
        `"::" + token + "::"`. Does not raise.
    """
    return "::" + token + "::"


def contains_resume_delimiter(region: String, token: String) -> Bool:
    """Whether `region` contains the complete resume delimiter for `token`.

    Pure. This is the collision check: if a captured region already contains
    `::<token>::` for a candidate token, fencing that region with that token
    would let the region's own content prematurely re-enable commands.

    Args:
        region: The text to search. Not mutated.
        token: The candidate fencing token. Not mutated.

    Returns:
        True iff `resume_delimiter(token)` occurs anywhere in `region`. Does
        not raise.
    """
    return resume_delimiter(token) in region


def select_collision_free_token(
    region: String, candidates: List[String]
) raises -> String:
    """The first candidate token whose resume delimiter is absent from
    `region`. Pure.

    Draws `candidates` in order and returns the first one that does not
    collide, so the eventual fence is collision-proof by construction rather
    than by probability. This function generates no randomness itself — the
    real, high-entropy, per-run-unique candidate source (minted after the
    producing child has exited, never exposed to it) is injected by the
    caller as `candidates`; keeping the selection logic pure here is what
    makes the collision path table-testable.

    Args:
        region: The captured text the chosen token must not collide with.
            Not mutated.
        candidates: Candidate tokens to try, in order. Not mutated.

    Returns:
        The first collision-free candidate, copied.

    Raises:
        Error: every candidate in `candidates` collided with `region`.
    """
    for i in range(len(candidates)):
        if not contains_resume_delimiter(region, candidates[i]):
            return candidates[i].copy()
    raise Error(
        "escape: every stop-commands candidate token collided with the region"
    )


def stop_commands_opener(token: String) -> String:
    """The GitHub Actions stop-commands opener line for `token`. Pure.

    Args:
        token: The fencing token. Not mutated.

    Returns:
        `"::stop-commands::" + token`. Does not raise.
    """
    return "::stop-commands::" + token


def fence_region(token: String, region: String) -> String:
    """Assemble a `region` wrapped in stop-commands fencing for `token`. Pure.

    Joins the opener, the region, and the resume delimiter with newlines (each
    workflow command must start its own line). The resume delimiter is
    unconditionally appended — there is no branch in this function that can
    omit it — so a caller that always calls this (or, equivalently, always
    writes `stop_commands_opener` and `resume_delimiter` around a region even
    on an error path) can never leave the fence unterminated. Callers needing
    to interleave writes around a genuinely fallible I/O step should use
    `stop_commands_opener` and `resume_delimiter` directly instead of this
    convenience wrapper, so their own always-runs guarantee covers the write
    of the resume delimiter too.

    Args:
        token: The fencing token, already proven collision-free against
            `region` (typically via `select_collision_free_token`). Not
            mutated.
        region: The captured text to fence. Not mutated.

    Returns:
        `stop_commands_opener(token)`, `region`, and `resume_delimiter(token)`
        joined by newlines. Does not raise.
    """
    return (
        stop_commands_opener(token)
        + "\n"
        + region
        + "\n"
        + resume_delimiter(token)
    )
