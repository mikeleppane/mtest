"""Machine-text escaping primitives shared by every machine reporter.

mtest renders three machine-consumed streams from the same untrusted,
child-process-controlled text: the JSON/NDJSON event stream, the JUnit XML
report, and GitHub Actions annotations. The escaping logic all three would
otherwise duplicate against that hostile input (captured stdout/stderr, test
names, assertion detail, paths) lives here.

These escapers take Mojo `String`s, which are valid UTF-8 by construction, and
never re-decode. Callers are responsible for getting raw captured child bytes
into that form first, by decoding them through `lossy_utf8`; strings that were
never raw bytes (a version label, a JUnit root or suite name) arrive here
directly. They work byte-for-byte: every
delimiter they act on (`"`, `\\`, `&`, `<`, `>`, `%`, `:`, `,`, and the C0
control bytes) is a single ASCII byte, so a plain byte scan that copies every
other byte straight through can never split a multi-byte UTF-8 sequence or
misinterpret a continuation byte.

Also here: the pure core of the collision-proof `::stop-commands::<token>`
fencing GitHub Actions requires to echo untrusted captured output without
letting it forge workflow commands. This module supplies the resume-delimiter
predicate, collision-free token selection over an injected candidate source,
and the fenced-output assembly; the entropy source that mints the real
per-run token wires in elsewhere, after the producing child has exited.
"""

comptime _FFFD: StaticString = "�"
"""The Unicode replacement character, U+FFFD, encoded as UTF-8 (3 bytes)."""


def _push_str(mut out: List[UInt8], text: String):
    """Append every byte of `text` to `out`, in order."""
    for b in text.as_bytes():
        out.append(b)


def _hex_nibble(v: Int) -> UInt8:
    """The lowercase ASCII hex digit byte for a nibble `0 <= v <= 15`."""
    if v < 10:
        return UInt8(48 + v)  # '0'..'9'
    return UInt8(87 + v)  # 'a'..'f' (97 - 10 = 87)


def _bytes_to_string(bytes: List[UInt8]) -> String:
    """Render `bytes` as a `String`; the caller guarantees valid UTF-8."""
    # SAFETY: `unsafe_from_utf8` requires `bytes` to be well-formed UTF-8. Every
    # caller here builds `bytes` by copying whole bytes of already-valid-UTF-8
    # input through unchanged and inserting only single-byte ASCII escape
    # sequences or the fixed 3-byte U+FFFD encoding (EF BF BD) — no multi-byte
    # sequence is ever split and no invalid byte is introduced, so the buffer is
    # valid UTF-8 by construction.
    return String(StringSlice(unsafe_from_utf8=Span(bytes)))


def json_escape_string(s: String) -> String:
    """Escape `s` for use inside a JSON string literal.

    `"` becomes `\\"`, `\\` becomes `\\\\`, LF/CR/Tab take their short forms
    `\\n`/`\\r`/`\\t`, and every remaining byte below 0x20 becomes `\\u00XX`.
    Every other byte — including a valid multi-byte UTF-8 sequence or an
    embedded U+FFFD — passes through unchanged: `s` is already valid UTF-8, so
    a plain byte copy cannot corrupt a sequence, and JSON does not require
    escaping non-ASCII text.

    This covers string content only; number formatting is the caller's policy.

    Args:
        s: The already-UTF-8-valid text to escape.

    Returns:
        `s` with `"`, `\\`, and every C0 control byte escaped.
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
    """A copy of `s`'s UTF-8 bytes as an owned, indexable list."""
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _is_xml_noncharacter(data: List[UInt8], i: Int) -> Bool:
    """Whether an XML-1.0-forbidden noncharacter begins at byte `i`.

    XML 1.0's `Char` production excludes U+FFFE and U+FFFF; its BMP range stops
    at U+FFFD. Both are valid UTF-8 scalars — `EF BF BE` and `EF BF BF` — that
    `lossy_utf8` passes through, so text can be well-formed UTF-8 yet illegal
    XML 1.0. The XML escapers use this to replace them. JSON permits these
    scalars and is unaffected.
    """
    if i + 3 > len(data):
        return False
    if Int(data[i]) != 0xEF or Int(data[i + 1]) != 0xBF:
        return False
    var last = Int(data[i + 2])
    return last == 0xBE or last == 0xBF


def xml_escape_text(s: String) -> String:
    """Escape `s` for XML text content (element body text).

    `&` `<` `>` become entities. Literal Tab/LF/CR pass through unchanged: they
    are valid XML 1.0 `Char`s, and text context does not normalize whitespace.
    Every other byte below 0x20, and the XML-forbidden noncharacters
    U+FFFE/U+FFFF, are replaced with U+FFFD rather than escaped, since XML 1.0
    has no legal representation for them. Every other byte passes through
    unchanged. No CDATA is emitted.

    Args:
        s: The already-UTF-8-valid text to escape.

    Returns:
        `s` escaped for a well-formed XML 1.0 text node.
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
    """Escape `s` for an XML attribute value.

    Adds `"` -> `&quot;` on top of the text-context entity set (`&` `<` `>`).
    Unlike text context, Tab/LF/CR are emitted as the numeric character
    references `&#9;` / `&#10;` / `&#13;` rather than literally: attribute-value
    normalization would otherwise fold them to an ordinary space and corrupt a
    node-id path reconstructed from the attribute. Every other byte below 0x20,
    and the noncharacters U+FFFE/U+FFFF, are replaced with U+FFFD as in text
    context. No CDATA is emitted.

    Args:
        s: The already-UTF-8-valid text to escape.

    Returns:
        `s` escaped for a well-formed, round-trip-safe XML 1.0 attribute value.
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
    """Escape `s` for a GitHub Actions workflow-command message payload.

    `%` becomes `%25`, CR becomes `%0D`, LF becomes `%0A`. A single scan tests
    `%` ahead of CR/LF, so the `%` that a CR/LF escape emits is never itself
    re-escaped. Every other byte, including `:` and `,`, passes through
    unchanged.

    Args:
        s: The already-UTF-8-valid text to escape.

    Returns:
        `s` escaped for a workflow-command message field.
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
    """Escape `s` for a GitHub Actions workflow-command property value.

    Applies the message escape set first (`%` -> `%25`, CR -> `%0D`,
    LF -> `%0A`), then escapes `:` -> `%3A` and `,` -> `%2C`, which the
    workflow-command grammar uses as field and record separators in property
    values. The two-pass composition is safe because no message-set
    replacement text (`%25`, `%0D`, `%0A`) contains a literal `:` or `,`.

    Args:
        s: The already-UTF-8-valid text to escape.

    Returns:
        `s` escaped for a workflow-command property value.
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
        "escape: every stop-commands candidate token collided with the region"
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
