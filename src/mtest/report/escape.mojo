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

The `::stop-commands::<token>` fencing protocol that echoes this escaped output
into GitHub Actions safely lives beside these escapers in `fencing.mojo`.

One of the three streams is not purely machine-consumed: the annotation tail is
printed to the console's own descriptor, which may be a terminal. The GitHub
escapers therefore finish by running their result through `console_text`, the
runner's single terminal-safety mapping, rather than growing a second copy of
that policy here. The XML and JSON escapers do not: their documents are never
handed to a terminal, and both already have a total answer for every control
code point under their own format's rules.
"""
from mtest.report.console_text import escape_multiline

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

    Two passes, in this order.

    First the workflow-command encoding: `%` becomes `%25`, CR becomes `%0D`,
    LF becomes `%0A`. A single scan tests `%` ahead of CR/LF, so the `%` that a
    CR/LF escape emits is never itself re-escaped. `:` and `,` pass through;
    the property escaper adds those.

    Then the terminal-safety pass, `escape_multiline`. mtest prints its
    annotation tail to the SAME descriptor the console writes to, which may be
    a real terminal, so a workflow command carrying a child's `ESC ] 0 ; … BEL`
    would address that terminal even though GitHub's own UI renders the payload
    as inert text. Running this pass second is what keeps the two concerns from
    fighting: by the time it runs, no raw CR or LF is left for it to see, so
    `%0D` and `%0A` survive exactly as GitHub's line-folding needs, and the
    `%25`/`%0D`/`%0A` text it does see is plain ASCII it copies through. Tab
    rides through literally: it is legal inside a workflow command and cannot
    address a terminal.

    A C1 control is two UTF-8 bytes, so this pass — unlike the first — replaces
    whole code points rather than single bytes. It never splits a sequence, so
    the result is still valid UTF-8 and still safe to bound by code point.

    Args:
        s: The already-UTF-8-valid text to escape.

    Returns:
        `s` escaped for a workflow-command message field, carrying no control
        character a terminal would execute.
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
    return escape_multiline(_bytes_to_string(out))


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
