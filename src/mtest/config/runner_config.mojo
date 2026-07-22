"""`RunnerConfig`: the typed home for every runner knob.

`RunnerConfig` is data plus its contract defaults — no parsing, no environment
or file reads, no printing. The cli layer constructs and fills one from argv;
the session layer only reads it. An empty `paths` list means "use discovery's
own default root", not "nothing to do"; applying that rule is discover's job.
"""
from mtest.config.annotations_mode import AnnotationsMode
from mtest.config.color_when import ColorWhen
from mtest.config.precompile import Precompile
from mtest.config.shard_mode import ShardMode
from mtest.config.show_output import ShowOutput
from mtest.config.verbosity import Verbosity


@fieldwise_init
struct RunnerConfig(Copyable, Movable):
    """Every knob the parser fills and the session reads.

    Deliberately `Copyable, Movable` but not `ImplicitlyCopyable`: it owns
    several `List`s, so every copy of a config is a visible `.copy()` at the
    call site rather than a silent implicit one.
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
    """The already-resolved mojo binary path (see `resolve_mojo_path`)."""

    var timeout_secs: Int
    """Per-file run timeout in seconds; `0` disables it."""

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
    """`--maxfail N`: stop scheduling once N failing tests have accumulated;
    `0` disables the limit."""

    var durations: Int
    """`--durations N`: how many of the slowest files the console reporter
    lists after the summary band; `0` suppresses the listing."""

    var collect: Bool
    """Collect mode (`collect` subcommand or `--collect-only`): probe every
    discovered file for its node ids and print the sorted listing, running no
    test body. When True the session takes the collect path, not a run."""

    var shard_mode: ShardMode
    """`--shard` partitioning mode: hash (default) or slice. Consulted only
    when `shard_n > 0`."""

    var shard_m: Int
    """`--shard M/N`: this shard's 1-based index. `0` when unsharded."""

    var shard_n: Int
    """`--shard M/N`: the total shard count. `0` (the default) means unsharded,
    so the whole discovered run set runs. When `> 0` the session keeps only the
    run files this shard owns; gate files are never sharded."""

    var retries: Int
    """`--retries N`: how many times to re-run a crash-class failure (a real
    crash or a deadline kill) before accepting it; `0` (the default) disables
    retries. A file runs up to `retries + 1` attempts, and a late pass after a
    crash-class attempt is flaky. Deterministic failures are never retried."""

    var workers: Int
    """`-n N`: how many run files to build and execute concurrently. `1` (the
    default) is the sequential path — one child at a time, argv byte-identical
    to a single-worker run. A value above one drives the parallel pool. `0`
    means `auto`, resolved from the machine's core count; the CLI does not yet
    surface the flag, so every parsed config carries `1` until the flip lands."""

    var compile_timeout_secs: Int
    """`--compile-timeout SECS`: per-file build timeout in seconds; `0`
    disables it. A build that exceeds it is killed under the supervised
    protocol (with a compile-specific grace) and reported COMPILE_TIMEOUT, a
    crash-class failure `--retries` retries against a quarantined module
    cache."""

    var json_dest: String
    """`--json PATH|-`: the machine event-stream destination. Empty means the
    flag was absent, so no stream. `"-"` streams to stdout byte-pure, which
    relocates the console to stderr. Any other value is a filesystem path the
    stream is written to live, overwriting a pre-existing file at session
    start. The parser validates it syntactically (non-empty, with an existing
    parent directory); a runtime open failure is the session's to resolve."""

    var gh_annotations: AnnotationsMode
    """`--gh-annotations off|on|auto`: whether to emit GitHub Actions
    annotation workflow-command lines in the deterministic stdout tail. `auto`
    (the default) renders only when `GITHUB_ACTIONS=true`, `on` always renders,
    `off` never does. Fencing echoed child output with stop-commands is a
    separate console concern keyed on `GITHUB_ACTIONS`, active regardless of
    this mode."""

    var junit_dest: String
    """`--junit-xml PATH`: the JUnit XML report destination. Empty means the
    flag was absent, so no report. Any other value is a filesystem path the
    assembled `<testsuites>` document is written to. Unlike `--json`, the
    destination is never truncated live: the report is assembled at
    finalization, written to a unique temp beside the target, and renamed
    atomically onto the path only after a verified complete write, so a prior
    report survives every failure. The parser validates it syntactically
    (non-empty, with an existing parent directory); a runtime creation failure
    is the session's to resolve."""

    @staticmethod
    def default() -> RunnerConfig:
        """A config with every field at its contract default.

        The two deadlines are the only nonzero counts: `timeout_secs=300` and
        `compile_timeout_secs=600`. Every other numeric field is `0` —
        `maxfail`, `durations`, `retries`, `shard_m`, `shard_n` — which
        disables that limit and leaves the run unsharded. Every list is empty,
        `exitfirst` and `collect` are False, and `keyword`, `json_dest`, and
        `junit_dest` are `""`, so no keyword filter, event stream, or JUnit
        report is configured. The rest are `mojo_path="mojo"`,
        `show_output=FAILURES`, `verbosity=NORMAL`, `color=AUTO`,
        `shard_mode=HASH`, and `gh_annotations=AUTO`.

        Returns:
            A freshly allocated config. `parse_args` does not build on this —
            it constructs its own `RunnerConfig` from the parsed tokens — so
            the only use is the placeholder config a help or version
            `ParseResult` carries and callers ignore.
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
            retries=0,
            workers=1,
            compile_timeout_secs=600,
            json_dest="",
            gh_annotations=AnnotationsMode.AUTO,
            junit_dest="",
        )
