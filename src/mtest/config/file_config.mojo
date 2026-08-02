"""Typed, presence-aware data parsed from one `mtest.toml` document.

`FileConfig` records whether each key was supplied separately from its typed
value, so later precedence resolution can replace whole values including empty
lists. `OverrideRule` preserves one override table without matching paths in
this layer.
"""
from mtest.config.annotations_mode import AnnotationsMode
from mtest.config.color_when import ColorWhen
from mtest.config.precompile import Precompile
from mtest.config.show_output import ShowOutput
from mtest.config.verbosity import Verbosity


@fieldwise_init
struct OverrideRule(Copyable, Movable):
    """One ordered per-file override table with presence-aware values."""

    var files: List[String]
    """The non-empty file globs named by this table."""

    var timeout_secs: Int
    """The per-file run timeout when `saw_timeout` is True."""

    var saw_timeout: Bool
    """Whether this table supplied `timeout`."""

    var compile_timeout_secs: Int
    """The per-file build timeout when `saw_compile_timeout` is True."""

    var saw_compile_timeout: Bool
    """Whether this table supplied `compile-timeout`."""

    var retries: Int
    """The crash-class retry ceiling when `saw_retries` is True."""

    var saw_retries: Bool
    """Whether this table supplied `retries`."""

    var serial: Bool
    """Whether matching files are pinned to serial execution."""

    var saw_serial: Bool
    """Whether this table supplied `serial`."""

    @staticmethod
    def empty() -> OverrideRule:
        """Build the unpopulated starting value for one override table.

        Returns:
            A freshly allocated rule with no files or supplied override keys.
        """
        return OverrideRule(
            files=[],
            timeout_secs=0,
            saw_timeout=False,
            compile_timeout_secs=0,
            saw_compile_timeout=False,
            retries=0,
            saw_retries=False,
            serial=False,
            saw_serial=False,
        )


@fieldwise_init
struct FileConfig(Copyable, Movable):
    """Every accepted file value plus an explicit presence bit.

    Deliberately `Copyable, Movable` but not `ImplicitlyCopyable`: the model
    owns lists and strings, so every copy remains visible at call sites.

    A value slot alone changes nothing. Resolution reads the presence bit, so a
    supplied key means setting both.

    Examples:

    ```mojo
    from mtest.config import FileConfig

    var file = FileConfig.empty()
    file.timeout_secs = 41
    file.saw_timeout = True
    ```
    """

    var paths: List[String]
    """The `[run] paths` replacement list."""

    var saw_paths: Bool
    """Whether `[run] paths` was supplied."""

    var excludes: List[String]
    """The `[run] exclude` replacement list."""

    var saw_excludes: Bool
    """Whether `[run] exclude` was supplied."""

    var gates: List[String]
    """The `[run] gates` replacement list."""

    var saw_gates: Bool
    """Whether `[run] gates` was supplied."""

    var serial_globs: List[String]
    """The `[run] serial` replacement list."""

    var saw_serial: Bool
    """Whether `[run] serial` was supplied."""

    var workers: Int
    """The worker count, with `0` representing `auto`."""

    var saw_workers: Bool
    """Whether `[run] workers` was supplied."""

    var timeout_secs: Int
    """The global per-file run timeout."""

    var saw_timeout: Bool
    """Whether `[run] timeout` was supplied."""

    var retries: Int
    """The global crash-class retry ceiling."""

    var saw_retries: Bool
    """Whether `[run] retries` was supplied."""

    var maxfail: Int
    """The global failing-test scheduling ceiling."""

    var saw_maxfail: Bool
    """Whether `[run] maxfail` was supplied."""

    var fail_on_flaky: Bool
    """Whether a FLAKY file must turn a would-be 0 into exit 1."""

    var saw_fail_on_flaky: Bool
    """Whether `[run] fail-on-flaky` was supplied."""

    var state: Bool
    """Whether last-run state is enabled."""

    var saw_state: Bool
    """Whether `[run] state` was supplied."""

    var mojo_path: String
    """The `[build] mojo` executable path."""

    var saw_mojo: Bool
    """Whether `[build] mojo` was supplied."""

    var include_paths: List[String]
    """The `[build] include` replacement list."""

    var saw_include: Bool
    """Whether `[build] include` was supplied."""

    var build_args: List[String]
    """The `[build] build-args` replacement list."""

    var saw_build_args: Bool
    """Whether `[build] build-args` was supplied."""

    var precompiles: List[Precompile]
    """The typed `[build] precompile` replacement list."""

    var saw_precompile: Bool
    """Whether `[build] precompile` was supplied."""

    var compile_timeout_secs: Int
    """The global per-file build timeout."""

    var saw_compile_timeout: Bool
    """Whether `[build] compile-timeout` was supplied."""

    var color: ColorWhen
    """The `[report] color` choice."""

    var saw_color: Bool
    """Whether `[report] color` was supplied."""

    var show_output: ShowOutput
    """The `[report] show-output` choice."""

    var saw_show_output: Bool
    """Whether `[report] show-output` was supplied."""

    var verbosity: Verbosity
    """The `[report] verbosity` level."""

    var saw_verbosity: Bool
    """Whether `[report] verbosity` was supplied."""

    var durations: Int
    """The `[report] durations` count."""

    var saw_durations: Bool
    """Whether `[report] durations` was supplied."""

    var junit_dest: String
    """The `[report] junit-xml` destination."""

    var saw_junit_xml: Bool
    """Whether `[report] junit-xml` was supplied."""

    var json_dest: String
    """The `[report] json` destination."""

    var saw_json: Bool
    """Whether `[report] json` was supplied."""

    var gh_annotations: AnnotationsMode
    """The `[report] gh-annotations` choice."""

    var saw_gh_annotations: Bool
    """Whether `[report] gh-annotations` was supplied."""

    var overrides: List[OverrideRule]
    """The override tables in document order."""

    @staticmethod
    def empty() -> FileConfig:
        """Build a file model with every presence bit unset.

        Value slots use the runner's contract defaults, but they have no effect
        until their corresponding presence bit is True.

        Returns:
            A freshly allocated absent file layer with no overrides.
        """
        return FileConfig(
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
            fail_on_flaky=False,
            saw_fail_on_flaky=False,
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
            overrides=[],
        )
