"""`RunnerConfig`: the typed home for every runner knob (Layer 1).

`RunnerConfig` is data plus its contract defaults — no parsing, no environment
or file reads, no printing. The cli layer (a later module) constructs and fills
one from argv; the session layer (a later module) only reads it. An empty
`paths` list means "use discovery's own default root", not "nothing to do" —
that rule is discover's, not config's, to apply.
"""
from mtest.config.color_when import ColorWhen
from mtest.config.precompile import Precompile
from mtest.config.shard_mode import ShardMode
from mtest.config.show_output import ShowOutput
from mtest.config.verbosity import Verbosity


@fieldwise_init
struct RunnerConfig(Copyable, Movable):
    """Every knob the parser fills and the session reads.

    Deliberately `Copyable, Movable` but not `ImplicitlyCopyable`: it owns
    several `List`s, so every copy of a config is a visible `.copy()` in
    review, not a silent implicit one. Reads do not mutate or raise.
    """

    var paths: List[String]
    """Positional path operands; empty means "use the default root"."""

    var excludes: List[String]
    """Repeatable `--exclude` glob patterns."""

    var gates: List[String]
    """Repeatable `--gate` file paths."""

    var precompiles: List[Precompile]
    """Repeatable `--precompile SRC[:OUT]` entries."""

    var build_args: List[String]
    """`--build-arg` values plus any args passed after a bare `--`."""

    var include_paths: List[String]
    """Repeatable `-I` include-path entries."""

    var mojo_path: String
    """The RESOLVED mojo binary path (see `resolve_mojo_path`)."""

    var timeout_secs: Int
    """Per-file RUN timeout in seconds; `0` disables it."""

    var show_output: ShowOutput
    """Which files' captured output the console reporter renders."""

    var verbosity: Verbosity
    """How much the console reporter prints per file."""

    var color: ColorWhen
    """Whether the console reporter colorizes output."""

    var exitfirst: Bool
    """Whether to stop the run after the first failing file (`-x`)."""

    var keyword: String
    """The `-k` keyword expression; empty means no keyword filter."""

    var maxfail: Int
    """`--maxfail N`: stop scheduling once N failing TESTS have accumulated;
    `0` disables the limit (no cap)."""

    var durations: Int
    """`--durations N`: the number of slowest files to report; `0` disables
    the report (no listing). The console reporter renders the file-level
    slowest-files list after the summary band, from this field threaded at
    construction."""

    var collect: Bool
    """Collect mode (`collect` subcommand / `--collect-only`): probe every
    discovered file for its node ids and print the sorted listing, running no
    test body. When True the session takes the collect path, not a run."""

    var shard_mode: ShardMode
    """`--shard` partitioning mode: hash (default) or slice. Only consulted when
    `shard_n > 0`."""

    var shard_m: Int
    """`--shard M/N`: this shard's 1-based index. `0` when unsharded."""

    var shard_n: Int
    """`--shard M/N`: the total shard count. `0` (the default) means UNSHARDED —
    the whole discovered run set runs. When `> 0` the session keeps only the run
    files this shard owns; gate files are never sharded."""

    @staticmethod
    def default() -> RunnerConfig:
        """A config with every field at its contract default. Allocates.

        The defaults: every list empty, `mojo_path="mojo"`,
        `timeout_secs=300`, `show_output=FAILURES`, `verbosity=NORMAL`,
        `color=AUTO`, `exitfirst=False`, `maxfail=0` (no limit),
        `durations=0` (no report), `collect=False`, and UNSHARDED
        (`shard_mode=HASH`, `shard_m=0`, `shard_n=0`).
        """
        return RunnerConfig(
            paths=[],
            excludes=[],
            gates=[],
            precompiles=[],
            build_args=[],
            include_paths=[],
            mojo_path="mojo",
            timeout_secs=300,
            show_output=ShowOutput.FAILURES,
            verbosity=Verbosity.NORMAL,
            color=ColorWhen.AUTO,
            exitfirst=False,
            keyword="",
            maxfail=0,
            durations=0,
            collect=False,
            shard_mode=ShardMode.HASH,
            shard_m=0,
            shard_n=0,
        )
