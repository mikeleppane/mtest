"""The shared shell-quoting helpers behind every reproduce line.

`shell_quote` and `shell_join` are the runner's only quoting implementation for
building copy-paste-safe shell commands. `report` quotes the bare path in a
run-failure reproduce line and shell-joins the event's `build_argv` for the
compile-error reproduce line and `-v` output, and `cli` quotes the
build-affecting flags it echoes into the same lines. Sharing one safe-character
set and escaping rule is what makes a reproduce line quote uniformly end to end
no matter which layer built it. No I/O, no environment reads.
"""

# Characters that need no shell quoting in a reproduce token.
comptime _SHELL_SAFE: StaticString = (
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:,+@%"
)


def shell_quote(s: String) -> String:
    """Single-quote `s` for a shell if it holds any unsafe character.

    A token built entirely from safe characters passes through unchanged;
    otherwise it is wrapped in single quotes with embedded single quotes
    escaped. An empty token becomes `''`.

    Args:
        s: The token to quote.

    Returns:
        A shell-safe token.
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
    """Shell-quote every token in `tokens` and space-join them.

    Each token is quoted independently via `shell_quote`, then joined with
    single spaces, giving one copy-paste-safe command line. An empty list
    yields the empty string.

    Args:
        tokens: The argv or flag tokens to join, in order.

    Returns:
        The shell-quoted, space-joined command line.
    """
    var out = String("")
    for i in range(len(tokens)):
        if i > 0:
            out += " "
        out += shell_quote(tokens[i])
    return out
