"""The typed command-line overlay between argv parsing and config resolution.

`CliOverlay` carries only configuration-eligible values plus an explicit
presence bit for each one. Its fold keeps the parser's existing
defaults-resolved `RunnerConfig` surface while preserving the distinction
between an absent value and an explicitly supplied default.
"""
from mtest.config.annotations_mode import AnnotationsMode
from mtest.config.color_when import ColorWhen
from mtest.config.precompile import Precompile
from mtest.config.runner_config import RunnerConfig
from mtest.config.show_output import ShowOutput
from mtest.config.verbosity import Verbosity


@fieldwise_init
struct CliOverlay(Copyable, Movable):
    """Configuration values supplied by argv and their presence bits.

    Deliberately `Copyable, Movable` but not `ImplicitlyCopyable`: the overlay
    owns lists, so copies remain visible at call sites.
    """

    var paths: List[String]
    """Positional path operands supplied by argv."""

    var saw_paths: Bool
    """Whether argv supplied at least one positional path operand."""

    var excludes: List[String]
    """Accumulated `--exclude` values."""

    var saw_excludes: Bool
    """Whether argv supplied at least one `--exclude`."""

    var gates: List[String]
    """Accumulated `--gate` values."""

    var saw_gates: Bool
    """Whether argv supplied at least one `--gate`."""

    var serial_globs: List[String]
    """Accumulated `--serial` values."""

    var saw_serial: Bool
    """Whether argv supplied at least one `--serial`."""

    var workers: Int
    """The parsed worker count, with `0` representing `auto`."""

    var saw_workers: Bool
    """Whether argv supplied `-n` or `--workers`."""

    var timeout_secs: Int
    """The parsed per-file run timeout."""

    var saw_timeout: Bool
    """Whether argv supplied `--timeout`."""

    var retries: Int
    """The parsed crash-class retry ceiling."""

    var saw_retries: Bool
    """Whether argv supplied `--retries`."""

    var maxfail: Int
    """The parsed failing-test scheduling ceiling."""

    var saw_maxfail: Bool
    """Whether argv supplied `--maxfail`."""

    var state: Bool
    """Whether persistent last-run state is enabled."""

    var saw_state: Bool
    """Whether argv supplied state; always False until a CLI spelling exists."""

    var mojo_path: String
    """The `--mojo` value before environment/default resolution."""

    var saw_mojo: Bool
    """Whether argv supplied `--mojo`."""

    var include_paths: List[String]
    """Accumulated `-I` include paths."""

    var saw_include: Bool
    """Whether argv supplied at least one `-I`."""

    var build_args: List[String]
    """Accumulated `--build-arg` and post-`--` values."""

    var saw_build_args: Bool
    """Whether argv supplied at least one build argument."""

    var precompiles: List[Precompile]
    """Accumulated parsed `--precompile` entries."""

    var saw_precompile: Bool
    """Whether argv supplied at least one `--precompile`."""

    var compile_timeout_secs: Int
    """The parsed per-file compile timeout."""

    var saw_compile_timeout: Bool
    """Whether argv supplied `--compile-timeout`."""

    var color: ColorWhen
    """The parsed color mode."""

    var saw_color: Bool
    """Whether argv supplied `--color`."""

    var show_output: ShowOutput
    """The parsed captured-output rendering mode."""

    var saw_show_output: Bool
    """Whether argv supplied `-s` or `--show-output`."""

    var verbosity: Verbosity
    """The parsed quiet, normal, or verbose level."""

    var saw_verbosity: Bool
    """Whether argv supplied `-q` or `-v`."""

    var durations: Int
    """The parsed slow-file listing count."""

    var saw_durations: Bool
    """Whether argv supplied `--durations`."""

    var junit_dest: String
    """The parsed JUnit destination."""

    var saw_junit_xml: Bool
    """Whether argv supplied `--junit-xml`."""

    var json_dest: String
    """The parsed JSON stream destination."""

    var saw_json: Bool
    """Whether argv supplied `--json`."""

    var gh_annotations: AnnotationsMode
    """The parsed GitHub annotations mode."""

    var saw_gh_annotations: Bool
    """Whether argv supplied `--gh-annotations`."""

    @staticmethod
    def default() -> CliOverlay:
        """An absent overlay with typed contract-default value slots.

        Returns:
            A freshly allocated overlay whose presence bits are all False.
        """
        return CliOverlay(
            paths=[],
            saw_paths=False,
            excludes=[],
            saw_excludes=False,
            gates=[],
            saw_gates=False,
            serial_globs=[],
            saw_serial=False,
            workers=1,
            saw_workers=False,
            timeout_secs=300,
            saw_timeout=False,
            retries=0,
            saw_retries=False,
            maxfail=0,
            saw_maxfail=False,
            state=True,
            saw_state=False,
            mojo_path="mojo",
            saw_mojo=False,
            include_paths=[],
            saw_include=False,
            build_args=[],
            saw_build_args=False,
            precompiles=[],
            saw_precompile=False,
            compile_timeout_secs=600,
            saw_compile_timeout=False,
            color=ColorWhen.AUTO,
            saw_color=False,
            show_output=ShowOutput.FAILURES,
            saw_show_output=False,
            verbosity=Verbosity.NORMAL,
            saw_verbosity=False,
            durations=0,
            saw_durations=False,
            junit_dest="",
            saw_junit_xml=False,
            json_dest="",
            saw_json=False,
            gh_annotations=AnnotationsMode.AUTO,
            saw_gh_annotations=False,
        )

    def fold(self, defaults: RunnerConfig) -> RunnerConfig:
        """Fold present argv values over `defaults`.

        Non-config-eligible fields remain byte-for-byte those in `defaults`.
        `state` is retained in the overlay for the complete key model but is
        not yet a `RunnerConfig` field.

        Args:
            defaults: The lower-precedence config. Not mutated.

        Returns:
            A newly allocated defaults-folded config.

        Examples:

        ```mojo
        from mtest.config import CliOverlay, RunnerConfig

        var overlay = CliOverlay.default()
        overlay.timeout_secs = 9
        overlay.saw_timeout = True
        # Only `timeout_secs` moves; every other field stays at its default.
        var config = overlay.fold(RunnerConfig.default())
        ```
        """
        var config = defaults.copy()
        if self.saw_paths:
            config.paths = self.paths.copy()
        if self.saw_excludes:
            config.excludes = self.excludes.copy()
        if self.saw_gates:
            config.gates = self.gates.copy()
        if self.saw_serial:
            config.serial_globs = self.serial_globs.copy()
        if self.saw_workers:
            config.workers = self.workers
        if self.saw_timeout:
            config.timeout_secs = self.timeout_secs
        if self.saw_retries:
            config.retries = self.retries
        if self.saw_maxfail:
            config.maxfail = self.maxfail
        if self.saw_mojo:
            config.mojo_path = self.mojo_path.copy()
        if self.saw_include:
            config.include_paths = self.include_paths.copy()
        if self.saw_build_args:
            config.build_args = self.build_args.copy()
        if self.saw_precompile:
            config.precompiles = self.precompiles.copy()
        if self.saw_compile_timeout:
            config.compile_timeout_secs = self.compile_timeout_secs
        if self.saw_color:
            config.color = self.color
        if self.saw_show_output:
            config.show_output = self.show_output
        if self.saw_verbosity:
            config.verbosity = self.verbosity
        if self.saw_durations:
            config.durations = self.durations
        if self.saw_junit_xml:
            config.junit_dest = self.junit_dest.copy()
        if self.saw_json:
            config.json_dest = self.json_dest.copy()
        if self.saw_gh_annotations:
            config.gh_annotations = self.gh_annotations
        return config^
