"""The pure mojo-path resolution helper (Layer 1).

Resolving which `mojo` binary to invoke follows a fixed precedence: an explicit
`--mojo-path` flag beats the `MTEST_MOJO` environment variable, which beats the
plain `"mojo"` fallback (resolved via `PATH`). This module does not read the
environment itself — the cli layer reads `MTEST_MOJO` and passes it in — so the
precedence is a pure, exhaustively testable function of its two inputs.
"""


def resolve_mojo_path(
    flag: Optional[String], env_value: Optional[String]
) -> String:
    """Resolve the mojo binary path: flag > `MTEST_MOJO` env > `"mojo"`.

    Pure: performs no I/O and never reads the environment itself. The caller
    (cli) is responsible for reading `--mojo-path` and `MTEST_MOJO` and passing
    their values in.

    Args:
        flag: The value of an explicit `--mojo-path` flag, if given.
        env_value: The value of the `MTEST_MOJO` environment variable, if set.

    Returns:
        `flag`'s value if present; else `env_value`'s value if present; else
        the literal `"mojo"`. Does not mutate or raise.
    """
    if flag:
        return flag.value()
    if env_value:
        return env_value.value()
    return "mojo"
