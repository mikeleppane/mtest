"""`build_flags_string`: the shell-ready echo of the build-affecting options.

The console splices this string into a run-failure `reproduce:` line so a failing
file can be re-run under the exact build the session used. It is the inverse of
the parser for the flags that change how a file is built — `--mojo` (only when it
differs from the plain `mojo` default), `-I`, `--build-arg`, and `--precompile` —
and it lives in `cli` because those spellings are the parser's own. Pure: it reads
a `RunnerConfig` and returns a `String`, touching no environment and no I/O.
"""
from mtest.config import RunnerConfig

# Characters that need no shell quoting in a reproduce token. Kept in step with
# the console's own quoting set so the whole reproduce line quotes uniformly.
comptime _SHELL_SAFE: StaticString = (
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:,+@%"
)


def _shell_quote(s: String) -> String:
    """Single-quote `s` for a shell if it holds any unsafe character. Pure.

    An already-safe token passes through unchanged; otherwise it is wrapped in
    single quotes with embedded quotes escaped, so the reproduce line is
    copy-paste safe. An empty token becomes `''`.
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


def build_flags_string(config: RunnerConfig) -> String:
    """The shell-ready build-affecting flags in effect, each token quoted. Pure.

    Emits, in a fixed order, `--mojo <path>` only when the path is non-default,
    then `-I <p>` per include path, `--build-arg <a>` per build arg, and
    `--precompile <src[:out]>` per precompile entry. Every token is shell-quoted
    and joined with single spaces. Empty when nothing applies.

    Args:
        config: The parsed run configuration to echo the build flags from.

    Returns:
        A copy-paste-safe flag string, or the empty string when no
        build-affecting option is in effect. Does not mutate or raise.
    """
    var tokens = List[String]()
    if config.mojo_path != "mojo":
        tokens.append("--mojo")
        tokens.append(config.mojo_path)
    for p in config.include_paths:
        tokens.append("-I")
        tokens.append(p)
    for a in config.build_args:
        tokens.append("--build-arg")
        tokens.append(a)
    for pc in config.precompiles:
        tokens.append("--precompile")
        if pc.out:
            tokens.append(pc.src + ":" + pc.out.value())
        else:
            tokens.append(pc.src.copy())

    var out = String("")
    for i in range(len(tokens)):
        if i > 0:
            out += " "
        out += _shell_quote(tokens[i])
    return out
