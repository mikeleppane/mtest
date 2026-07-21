"""Resolution of which `mojo` binary to invoke.

The precedence is fixed: an explicit `--mojo` flag beats the `MTEST_MOJO`
environment variable, which beats the plain `"mojo"` fallback (resolved via
`PATH`). This module does not read the environment itself — the cli layer reads
`MTEST_MOJO` and passes it in — so the precedence is a function of its two
inputs alone.
"""


def resolve_mojo_path(
    flag: Optional[String], env_value: Optional[String]
) -> String:
    """Resolve the mojo binary path: flag, then `MTEST_MOJO`, then `"mojo"`.

    Args:
        flag: The value of an explicit `--mojo` flag, if one was given.
        env_value: The value of the `MTEST_MOJO` environment variable, if set.

    Returns:
        `flag`'s value when present, else `env_value`'s value when present,
        else the literal `"mojo"`.
    """
    if flag:
        return flag.value()
    if env_value:
        return env_value.value()
    return "mojo"
