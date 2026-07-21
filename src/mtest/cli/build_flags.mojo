"""`build_flags_string`: the shell-ready echo of the build-affecting options.

The console splices this string into a run-failure `reproduce:` line so a
failing file can be re-run under the exact build the session used. It inverts
the parser for the flags that change how a file is built — `--mojo` (only when
it differs from the plain `mojo` default), `-I`, `--build-arg`, and
`--precompile` — and it lives in `cli` because those spellings are the parser's
own. Quoting goes through `mtest.config`'s shared `shell_join`, the same helper
`report` and `session` use, so every reproduce line quotes uniformly.
"""
from mtest.config import RunnerConfig, shell_join


def build_flags_string(config: RunnerConfig) -> String:
    """The shell-ready build-affecting flags in effect, each token quoted.

    Emits, in a fixed order, `--mojo <path>` when the path is not the default
    `mojo`, then `-I <p>` per include path, `--build-arg <a>` per build arg, and
    `--precompile <src[:out]>` per precompile entry. Every token is shell-quoted
    and joined with single spaces.

    Args:
        config: The parsed run configuration to echo the build flags from.

    Returns:
        A copy-paste-safe flag string, or the empty string when no
        build-affecting option is in effect.
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

    return shell_join(tokens)
