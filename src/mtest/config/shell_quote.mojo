"""The shared shell-quoting helpers behind every reproduce line (Layer 1).

`shell_quote` and `shell_join` are the SINGLE quoting implementation the
runner uses to build copy-paste-safe shell commands: `report` (Layer 2) quotes
a bare path in a run-failure reproduce line, `session` (Layer 4) quotes the
build argv it stores as `build_command` (the COMPILE-ERROR reproduce line and
`-v` verbose output), and `cli` (Layer 5) quotes the build-affecting flags it
echoes. Every caller shares this ONE safe-character set and escaping rule, so
a reproduce line quotes uniformly end to end regardless of which layer built
it. Pure: no I/O, no environment reads.
"""

# Characters that need no shell quoting in a reproduce token.
comptime _SHELL_SAFE: StaticString = (
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:,+@%"
)


def shell_quote(s: String) -> String:
    """Single-quote `s` for a shell if it holds any unsafe character. Pure.

    An already-safe token passes through unchanged; otherwise it is wrapped in
    single quotes with embedded quotes escaped, so the result is copy-paste
    safe. An empty token becomes `''`.

    Args:
        s: The token to quote.

    Returns:
        A shell-safe token. Does not mutate or raise.
    """
    if s.byte_length() == 0:
        return "''"
    var safe = True
    for cp in s.codepoint_slices():
        if String(cp) not in _SHELL_SAFE:
            safe = False
            break
    if safe:
        return s.copy()
    var out = String("'")
    for cp in s.codepoint_slices():
        var c = String(cp)
        if c == "'":
            out += "'\\''"
        else:
            out += c
    out += "'"
    return out


def shell_join(tokens: List[String]) -> String:
    """Shell-quote every token in `tokens` and space-join them. Pure.

    Each token is quoted independently via `shell_quote`, then joined with
    single spaces, so the result is a single copy-paste-safe command line. An
    empty list yields the empty string.

    Args:
        tokens: The argv or flag tokens to join, in order.

    Returns:
        The shell-quoted, space-joined command line. Does not mutate or raise.
    """
    var out = String("")
    for i in range(len(tokens)):
        if i > 0:
            out += " "
        out += shell_quote(tokens[i])
    return out
