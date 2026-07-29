"""Pure layered configuration resolution with command-active key metadata.

The resolver replaces whole values in `defaults < mtest.toml < environment <
CLI` order. It carries file overrides as ordered data and never matches paths
or applies per-file policy.
"""
from mtest.config.file_config import FileConfig, OverrideRule
from mtest.config.annotations_mode import AnnotationsMode
from mtest.config.overlay import CliOverlay
from mtest.config.provenance import ConfigProvenance, Provenance
from mtest.config.last_run_state import LastRunState
from mtest.config.runner_config import RunnerConfig


@fieldwise_init
struct ConfigEnvironment(Copyable, Movable):
    """The closed environment inputs understood by config resolution.

    `mtest_mojo` is the only environment value layer; an empty string means
    absent. `no_color` remains a render-time input and never becomes color
    provenance.
    """

    var mtest_mojo: String
    """The non-empty `MTEST_MOJO` value, or empty when absent."""

    var no_color: Bool
    """Whether `NO_COLOR` is set, consulted only when color is `AUTO`."""

    @staticmethod
    def empty() -> ConfigEnvironment:
        """Build an environment with neither supported variable active.

        Returns:
            A newly allocated empty environment input.
        """
        return ConfigEnvironment(mtest_mojo="", no_color=False)


@fieldwise_init
struct ActiveConfigKeys(Copyable, Movable):
    """Whether each resolved key belongs to the current command projection."""

    var paths: Bool
    """Whether paths participate."""

    var excludes: Bool
    """Whether exclusions participate."""

    var gates: Bool
    """Whether gate files participate."""

    var serial_globs: Bool
    """Whether serial pinning participates."""

    var workers: Bool
    """Whether worker sizing participates."""

    var timeout_secs: Bool
    """Whether the run/probe timeout participates."""

    var retries: Bool
    """Whether crash-class retries participate."""

    var maxfail: Bool
    """Whether the failure ceiling participates."""

    var state: Bool
    """Whether persistent last-run state participates."""

    var mojo_path: Bool
    """Whether the Mojo executable participates."""

    var include_paths: Bool
    """Whether include paths participate."""

    var build_args: Bool
    """Whether build arguments participate."""

    var precompiles: Bool
    """Whether precompile entries participate."""

    var compile_timeout_secs: Bool
    """Whether the compile timeout participates."""

    var color: Bool
    """Whether color participates."""

    var show_output: Bool
    """Whether captured-output rendering participates."""

    var verbosity: Bool
    """Whether verbosity participates."""

    var durations: Bool
    """Whether slow-file reporting participates."""

    var junit_dest: Bool
    """Whether the JUnit destination participates."""

    var json_dest: Bool
    """Whether the JSON-stream destination participates."""

    var gh_annotations: Bool
    """Whether GitHub annotations participate."""

    @staticmethod
    def run() -> ActiveConfigKeys:
        """Build the full run/build/report projection.

        Returns:
            A newly allocated key set with every eligible key active.
        """
        return ActiveConfigKeys(
            paths=True,
            excludes=True,
            gates=True,
            serial_globs=True,
            workers=True,
            timeout_secs=True,
            retries=True,
            maxfail=True,
            state=True,
            mojo_path=True,
            include_paths=True,
            build_args=True,
            precompiles=True,
            compile_timeout_secs=True,
            color=True,
            show_output=True,
            verbosity=True,
            durations=True,
            junit_dest=True,
            json_dest=True,
            gh_annotations=True,
        )

    @staticmethod
    def collect() -> ActiveConfigKeys:
        """Build the collect selection/build projection.

        Collection keeps path selection, both deadlines, and all build inputs.
        Scheduling, state, presentation, and report keys are inactive, so
        later behavior and cross-value validation can exclude config-sourced
        values for those keys.

        Returns:
            A newly allocated key set for collect mode.
        """
        return ActiveConfigKeys(
            paths=True,
            excludes=True,
            gates=False,
            serial_globs=False,
            workers=False,
            timeout_secs=True,
            retries=False,
            maxfail=False,
            state=False,
            mojo_path=True,
            include_paths=True,
            build_args=True,
            precompiles=True,
            compile_timeout_secs=True,
            color=False,
            show_output=False,
            verbosity=False,
            durations=False,
            junit_dest=False,
            json_dest=False,
            gh_annotations=False,
        )


@fieldwise_init
struct ResolvedConfig(Copyable, Movable):
    """Effective values, per-key provenance, and command projection metadata.

    `config` retains `RunnerConfig`'s noneligible per-invocation fields exactly
    as received in the defaults input. `state` and ordered overrides live
    beside it because the compatibility config does not yet carry them.
    """

    var config: RunnerConfig
    """The fully layered runner-compatible values."""

    var state: Bool
    """Whether last-run state is enabled."""

    var overrides: List[OverrideRule]
    """The file override tables in document order, not yet applied."""

    var provenance: ConfigProvenance
    """The independently resolved source of every eligible key."""

    var active_keys: ActiveConfigKeys
    """The keys consumed and cross-validated by the current command."""

    var no_color: Bool
    """The separate `NO_COLOR` render-time input."""

    var config_file: String
    """The normalized selected project-config path, or empty when absent."""

    var state_warnings: List[String]
    """Contained nonfatal state diagnostics emitted after session start."""

    var last_run_state: LastRunState
    """The parsed prior failures supplied by main, empty before state loading."""

    var state_cleared: Bool
    """Whether `--cache-clear` just deleted the last-run state this run would
    otherwise have read.

    Supplied by main alongside `last_run_state`, because only main knows whether
    the state file was there when it removed the cache directory. The session
    turns it into one warning under `--lf`/`--ff`; every other caller leaves it
    False and sees the event stream it always saw."""


def validate_resolved_config(config: ResolvedConfig) -> Optional[String]:
    """Validate cross-key constraints over command-active resolved values.

    The returned diagnostic is fully framed, naming each offending value the
    way its own layer spells it: `cli:` and flag names for command-line
    values, `config:` and table/key names for project-file ones, so the
    remedy it suggests is one the reader can actually apply. Inactive keys are
    deliberately ignored, so a run-only reporting value in a project file
    cannot make collect mode fail.

    Args:
        config: The layered values and active-key projection to validate.

    Returns:
        A complete usage diagnostic when a constraint fails, otherwise none.
    """
    if (
        config.active_keys.json_dest
        and config.active_keys.gh_annotations
        and config.config.json_dest == "-"
        and config.config.gh_annotations != AnnotationsMode.OFF
    ):
        # Name each half where its own layer set it: a reader told to "drop
        # '--json -'" cannot act on that when the value lives in the project
        # file, and vice versa.
        var json_from_file = config.provenance.json_dest == (
            Provenance.MTEST_TOML
        )
        var annotations_from_file = config.provenance.gh_annotations == (
            Provenance.MTEST_TOML
        )
        var origin = config.config_file
        if origin == "":
            origin = String("mtest.toml")
        var prefix = String("cli: ")
        if json_from_file:
            prefix = "config: " + origin + ": "
        var json_name = String("'--json -'")
        if json_from_file:
            json_name = '[report] json = "-"'
        var json_fix = String("use '--json PATH'")
        if json_from_file:
            json_fix = "set [report] json to a path"
        var annotations_fix = String("set '--gh-annotations off'")
        if annotations_from_file:
            annotations_fix = 'set [report] gh-annotations = "off"'
        return Optional[String](
            prefix
            + json_name
            + " streams machine output to stdout, which the"
            " '--gh-annotations' tail cannot share; drop it ("
            + json_fix
            + "), or "
            + annotations_fix
            + " (see mtest --help)"
        )
    return Optional[String](None)


def resolve_config(
    defaults: RunnerConfig,
    file: FileConfig,
    environment: ConfigEnvironment,
    overlay: CliOverlay,
) -> ResolvedConfig:
    """Resolve defaults, file, environment, and argv layers.

    Each present layer replaces the whole lower-layer value, including lists.
    An explicit value equal to a default still receives the supplying layer's
    provenance. Only non-empty `MTEST_MOJO` participates as an environment
    value; `NO_COLOR` is carried separately and never rewrites color or its
    provenance. The function performs no I/O, override matching, or cross-key
    validation.

    Args:
        defaults: Built-in values plus noneligible per-invocation fields. Not
            mutated.
        file: Presence-aware values and ordered overrides from `mtest.toml`.
            Not mutated.
        environment: The closed `MTEST_MOJO`/`NO_COLOR` input. Not mutated.
        overlay: Presence-aware values supplied by argv. Not mutated.

    Returns:
        Newly allocated effective values, provenance, ordered overrides, and
        the run or collect active-key projection.

    Examples:

    ```mojo
    from mtest.config import CliOverlay, ConfigEnvironment, FileConfig
    from mtest.config import RunnerConfig, resolve_config

    var resolved = resolve_config(
        RunnerConfig.default(),
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    ```
    """
    var config = defaults.copy()
    var state = True
    var sources = ConfigProvenance.defaults()

    if file.saw_paths:
        config.paths = file.paths.copy()
        config.paths_supplied = True
        sources.paths = Provenance.MTEST_TOML
    if file.saw_excludes:
        config.excludes = file.excludes.copy()
        sources.excludes = Provenance.MTEST_TOML
    if file.saw_gates:
        config.gates = file.gates.copy()
        sources.gates = Provenance.MTEST_TOML
    if file.saw_serial:
        config.serial_globs = file.serial_globs.copy()
        sources.serial_globs = Provenance.MTEST_TOML
    if file.saw_workers:
        config.workers = file.workers
        sources.workers = Provenance.MTEST_TOML
    if file.saw_timeout:
        config.timeout_secs = file.timeout_secs
        sources.timeout_secs = Provenance.MTEST_TOML
    if file.saw_retries:
        config.retries = file.retries
        sources.retries = Provenance.MTEST_TOML
    if file.saw_maxfail:
        config.maxfail = file.maxfail
        sources.maxfail = Provenance.MTEST_TOML
    if file.saw_state:
        state = file.state
        sources.state = Provenance.MTEST_TOML
    if file.saw_mojo:
        config.mojo_path = file.mojo_path.copy()
        sources.mojo_path = Provenance.MTEST_TOML
    if file.saw_include:
        config.include_paths = file.include_paths.copy()
        sources.include_paths = Provenance.MTEST_TOML
    if file.saw_build_args:
        config.build_args = file.build_args.copy()
        sources.build_args = Provenance.MTEST_TOML
    if file.saw_precompile:
        config.precompiles = file.precompiles.copy()
        sources.precompiles = Provenance.MTEST_TOML
    if file.saw_compile_timeout:
        config.compile_timeout_secs = file.compile_timeout_secs
        sources.compile_timeout_secs = Provenance.MTEST_TOML
    if file.saw_color:
        config.color = file.color
        sources.color = Provenance.MTEST_TOML
    if file.saw_show_output:
        config.show_output = file.show_output
        sources.show_output = Provenance.MTEST_TOML
    if file.saw_verbosity:
        config.verbosity = file.verbosity
        sources.verbosity = Provenance.MTEST_TOML
    if file.saw_durations:
        config.durations = file.durations
        sources.durations = Provenance.MTEST_TOML
    if file.saw_junit_xml:
        config.junit_dest = file.junit_dest.copy()
        sources.junit_dest = Provenance.MTEST_TOML
    if file.saw_json:
        config.json_dest = file.json_dest.copy()
        sources.json_dest = Provenance.MTEST_TOML
    if file.saw_gh_annotations:
        config.gh_annotations = file.gh_annotations
        sources.gh_annotations = Provenance.MTEST_TOML

    if environment.mtest_mojo.byte_length() > 0:
        config.mojo_path = environment.mtest_mojo.copy()
        sources.mojo_path = Provenance.ENV_MTEST_MOJO

    if overlay.saw_paths:
        config.paths = overlay.paths.copy()
        config.paths_supplied = True
        sources.paths = Provenance.CLI
    if overlay.saw_excludes:
        config.excludes = overlay.excludes.copy()
        sources.excludes = Provenance.CLI
    if overlay.saw_gates:
        config.gates = overlay.gates.copy()
        sources.gates = Provenance.CLI
    if overlay.saw_serial:
        config.serial_globs = overlay.serial_globs.copy()
        sources.serial_globs = Provenance.CLI
    if overlay.saw_workers:
        config.workers = overlay.workers
        sources.workers = Provenance.CLI
    if overlay.saw_timeout:
        config.timeout_secs = overlay.timeout_secs
        sources.timeout_secs = Provenance.CLI
    if overlay.saw_retries:
        config.retries = overlay.retries
        sources.retries = Provenance.CLI
    if overlay.saw_maxfail:
        config.maxfail = overlay.maxfail
        sources.maxfail = Provenance.CLI
    if overlay.saw_state:
        state = overlay.state
        sources.state = Provenance.CLI
    if overlay.saw_mojo:
        config.mojo_path = overlay.mojo_path.copy()
        sources.mojo_path = Provenance.CLI
    if overlay.saw_include:
        config.include_paths = overlay.include_paths.copy()
        sources.include_paths = Provenance.CLI
    if overlay.saw_build_args:
        config.build_args = overlay.build_args.copy()
        sources.build_args = Provenance.CLI
    if overlay.saw_precompile:
        config.precompiles = overlay.precompiles.copy()
        sources.precompiles = Provenance.CLI
    if overlay.saw_compile_timeout:
        config.compile_timeout_secs = overlay.compile_timeout_secs
        sources.compile_timeout_secs = Provenance.CLI
    if overlay.saw_color:
        config.color = overlay.color
        sources.color = Provenance.CLI
    if overlay.saw_show_output:
        config.show_output = overlay.show_output
        sources.show_output = Provenance.CLI
    if overlay.saw_verbosity:
        config.verbosity = overlay.verbosity
        sources.verbosity = Provenance.CLI
    if overlay.saw_durations:
        config.durations = overlay.durations
        sources.durations = Provenance.CLI
    if overlay.saw_junit_xml:
        config.junit_dest = overlay.junit_dest.copy()
        sources.junit_dest = Provenance.CLI
    if overlay.saw_json:
        config.json_dest = overlay.json_dest.copy()
        sources.json_dest = Provenance.CLI
    if overlay.saw_gh_annotations:
        config.gh_annotations = overlay.gh_annotations
        sources.gh_annotations = Provenance.CLI

    var active_keys = ActiveConfigKeys.run()
    if config.collect:
        active_keys = ActiveConfigKeys.collect()
    return ResolvedConfig(
        config=config^,
        state=state,
        overrides=file.overrides.copy(),
        provenance=sources^,
        active_keys=active_keys^,
        no_color=environment.no_color,
        config_file="",
        state_warnings=[],
        last_run_state=LastRunState.empty(),
        state_cleared=False,
    )
