"""`RunnerConfig`: the typed home for every runner knob.

`RunnerConfig` is data plus its contract defaults: no parsing, no environment
or file reads, no printing. The cli layer folds its typed argv overlay over a
default config; the session layer only reads the result. An empty `paths` list
means "use discovery's own default root", not "nothing to do"; applying that
rule is discover's job.
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
    """The selected path operands; see `paths_supplied` for an empty list."""

    var paths_supplied: Bool
    """Whether any layer actually supplied `paths`, empty list included.

    Discovery falls back to `tests/` (else `.`) only when NO layer supplied a
    path list. A layer that supplied an explicitly empty list replaces the
    lower value like every other list key, so it selects nothing rather than
    silently reopening the default tree.
    """

    var excludes: List[String]
    """Repeatable `--exclude` glob patterns."""

    var serial_globs: List[String]
    """Repeatable `--serial` glob patterns pinning files to one-at-a-time
    execution."""

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

    var fail_on_flaky: Bool
    """`--fail-on-flaky`: exit 1 when the run would otherwise exit 0 and at
    least one file passed only after a crash-class retry (FLAKY). A terminal
    verdict only: it changes no retry, `--maxfail`, or last-run-state behavior.
    `False` (the default) keeps a FLAKY-only session at exit 0."""

    var durations: Int
    """`--durations N`: how many of the slowest files the console reporter
    lists after the summary band; `0` suppresses the listing."""

    var collect: Bool
    """Collect mode (`collect` subcommand or `--collect-only`): probe every
    discovered file for its node ids and print the sorted listing, running no
    test body. When True the session takes the collect path, not a run."""

    var collect_json: Bool
    """`--format json`: render the collect listing as an NDJSON stream.

    Read only when `collect` is True, which the parser enforces by refusing
    `--format` outside collect mode. `False` (the default, and `--format
    lines`) keeps the plain one-node-id-per-line listing byte-for-byte.
    CLI-only by design: this is deliberately exempt from `mtest.toml`, so it
    is never a layered value and carries no file or environment source."""

    var last_failed: Bool
    """Whether `--lf`/`--last-failed` narrows to remembered failures."""

    var failed_first: Bool
    """Whether `--ff`/`--failed-first` orders remembered failures first."""

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
    default) is the sequential path: one child at a time, argv byte-identical
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

    var shuffle: Bool
    """`--shuffle`: randomize the order the run files execute in.

    Applied after the shard partition and only to run files; gate files keep
    their listed order, and every reported surface stays node-id sorted.
    CLI-only by design: this is deliberately exempt from `mtest.toml`, so it
    is never a layered value and carries no file or environment source.
    Defaults to `False`."""

    var shuffle_seed: Int
    """`--seed N`: the seed that fixes the `--shuffle` order.

    `-1` (the default) means no seed was given, so the session derives one at
    start and reports it; any value `>= 0` is used verbatim. Read only when
    `shuffle` is True. CLI-only by design, like `shuffle` itself."""

    var no_cache: Bool
    """`--no-cache`: build without reading or writing the build cache.

    CLI-only by design: this is deliberately exempt from `mtest.toml`, so it
    is never a layered value and carries no file or environment source.
    Defaults to `False`."""

    var cache_clear: Bool
    """`--cache-clear`: delete `.mtest-cache` (build cache and last-run
    state), then run.

    CLI-only by design: this is deliberately exempt from `mtest.toml`, so it
    is never a layered value and carries no file or environment source.
    Defaults to `False`."""

    @staticmethod
    def default() -> RunnerConfig:
        """A config with every field at its contract default.

        The nonzero numeric defaults are the two deadlines, `timeout_secs=300`
        and `compile_timeout_secs=600`, plus `workers=1` for the sequential
        path. `maxfail`, `durations`, `retries`, `shard_m`, and `shard_n` are
        all `0`, which disables each limit and leaves the run unsharded.
        `shuffle_seed` is `-1`, the sentinel for "derive one at session start".
        Every
        list is empty; `paths_supplied`, `exitfirst`, `collect`,
        `collect_json`, `last_failed`,
        `failed_first`, `fail_on_flaky`, `shuffle`, `no_cache`, and
        `cache_clear` are False; and
        `keyword`, `json_dest`, and `junit_dest` are `""`, so no keyword
        filter, event stream, or JUnit report is configured. The rest are
        `mojo_path="mojo"`,
        `show_output=FAILURES`, `verbosity=NORMAL`, `color=AUTO`,
        `shard_mode=HASH`, and `gh_annotations=AUTO`.

        Returns:
            A freshly allocated config used as the lower-precedence input to
            `parse_args`'s overlay fold and as the placeholder a help or
            version `ParseResult` carries.

        Examples:

        ```mojo
        from mtest.config import RunnerConfig, Verbosity

        var config = RunnerConfig.default()
        config.timeout_secs = 30
        config.verbosity = Verbosity.VERBOSE
        ```
        """
        return RunnerConfig(
            paths=[],
            paths_supplied=False,
            excludes=[],
            serial_globs=[],
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
            fail_on_flaky=False,
            durations=0,
            collect=False,
            collect_json=False,
            last_failed=False,
            failed_first=False,
            shard_mode=ShardMode.HASH,
            shard_m=0,
            shard_n=0,
            retries=0,
            workers=1,
            compile_timeout_secs=600,
            json_dest="",
            gh_annotations=AnnotationsMode.AUTO,
            junit_dest="",
            shuffle=False,
            shuffle_seed=-1,
            no_cache=False,
            cache_clear=False,
        )


def cli_only_resolution_defaults(parsed: RunnerConfig) -> RunnerConfig:
    """Seed a resolution base with the fields no config layer may supply.

    Layered resolution starts from contract defaults and folds the project
    file, the environment, and the CLI overlay over them. The fields below are
    outside that model entirely: they are decided by argv alone and have no
    `mtest.toml` key, so nothing downstream would ever restore them. This
    carries them across, and everything else stays at its contract default for
    the resolver to fill.

    A field missing from this projection is the quietest defect in the runner:
    the flag parses, the config carries it, and it is silently discarded on the
    way to the session, so the feature is simply inert. `main` is a program
    rather than a package and cannot be imported by a test, which is why this
    lives here — `tests/unit/test_config.mojo` holds it to carrying every
    CLI-only field.

    Args:
        parsed: The config `parse_args` produced. Not mutated.

    Returns:
        A freshly allocated config: contract defaults everywhere except the
        CLI-only fields, which are copied from `parsed`.
    """
    var defaults = RunnerConfig.default()
    defaults.exitfirst = parsed.exitfirst
    defaults.keyword = parsed.keyword.copy()
    defaults.collect = parsed.collect
    defaults.collect_json = parsed.collect_json
    defaults.last_failed = parsed.last_failed
    defaults.failed_first = parsed.failed_first
    defaults.shard_mode = parsed.shard_mode
    defaults.shard_m = parsed.shard_m
    defaults.shard_n = parsed.shard_n
    defaults.shuffle = parsed.shuffle
    defaults.shuffle_seed = parsed.shuffle_seed
    defaults.no_cache = parsed.no_cache
    defaults.cache_clear = parsed.cache_clear
    return defaults^
