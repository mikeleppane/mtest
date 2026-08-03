"""`ParseResult`: what a successful parse produces.

Parsing either yields a configured run, `config show`, `doctor`, or `debug`
request with both its typed argv overlay and defaults-folded compatibility
config, a `new` scaffolding request, or a non-error directive to print help or
the version. A usage error is not a `ParseResult`: it is raised. `main` handles
each result; this layer never prints or exits.
"""
from mtest.config import CliOverlay, RunnerConfig


@fieldwise_init
struct ParseResult(Copyable, Movable):
    """The outcome of a successful parse.

    A tagged union over `kind`. For `RUN`, `CONFIG_SHOW`, `DOCTOR`, and
    `DEBUG`, `overlay` holds argv presence and values while `config` holds
    their defaults-folded compatibility view. `DEBUG` additionally carries the
    one node id it was given in `operand`, and `NEW` carries the one path it
    was given there. Help, version, and `NEW` carry placeholder fields.

    Examples:

    ```mojo
    from mtest.cli import parse_args

    var argv: List[String] = ["tests/", "-k", "test_add"]
    var result = parse_args(argv)
    if result.is_run():
        print(result.config.keyword)
    ```
    """

    var kind: Int
    """The successful parse outcome discriminant."""

    var config: RunnerConfig
    """The parsed config; meaningful for `RUN`, `CONFIG_SHOW`, and `DOCTOR`."""

    var overlay: CliOverlay
    """The argv overlay; meaningful for `RUN`, `CONFIG_SHOW`, and `DOCTOR`."""

    var config_path: String
    """The explicit configuration path, or empty when discovery applies."""

    var no_config: Bool
    """Whether configuration-file discovery is explicitly disabled."""

    var operand: String
    """The one path-shaped operand `DEBUG` and `NEW` name; empty otherwise.

    It is kept out of `config.paths` on purpose: both commands own their
    operand and resolve it against a projection in which a project file's own
    path list never participates — under `NEW` there is no configuration at
    all, since the file is scaffolded before any is loaded."""

    comptime RUN = 0
    comptime SHOW_HELP = 1
    comptime SHOW_VERSION = 2
    comptime CONFIG_SHOW = 3
    comptime DOCTOR = 4
    comptime DEBUG = 5
    comptime NEW = 6

    @staticmethod
    def run(
        var config: RunnerConfig,
        var overlay: CliOverlay,
        config_path: String = "",
        no_config: Bool = False,
    ) -> ParseResult:
        """A result that runs the defaults-folded `config`.

        Args:
            config: The parsed configuration. Consumed; the returned result
                owns it.
            overlay: The typed argv overlay. Consumed; the returned result owns
                it.
            config_path: The explicit configuration path, or empty to discover.
            no_config: Whether to skip configuration discovery.

        Returns:
            A result whose `kind` is `RUN`.
        """
        return ParseResult(
            kind=Self.RUN,
            config=config^,
            overlay=overlay^,
            config_path=config_path,
            no_config=no_config,
            operand=String(""),
        )

    @staticmethod
    def show_help() -> ParseResult:
        """A result asking `main` to print help; its config is a placeholder."""
        return ParseResult(
            kind=Self.SHOW_HELP,
            config=RunnerConfig.default(),
            overlay=CliOverlay.default(),
            config_path="",
            no_config=False,
            operand=String(""),
        )

    @staticmethod
    def show_version() -> ParseResult:
        """A result asking `main` to print the version string."""
        return ParseResult(
            kind=Self.SHOW_VERSION,
            config=RunnerConfig.default(),
            overlay=CliOverlay.default(),
            config_path="",
            no_config=False,
            operand=String(""),
        )

    @staticmethod
    def config_show(
        var config: RunnerConfig,
        var overlay: CliOverlay,
        config_path: String = "",
        no_config: Bool = False,
    ) -> ParseResult:
        """A result asking `main` to render the resolved run configuration.

        Args:
            config: The parsed run configuration. Consumed.
            overlay: The typed argv overlay. Consumed.
            config_path: The explicit configuration path, or empty to discover.
            no_config: Whether to skip configuration discovery.

        Returns:
            A result whose `kind` is `CONFIG_SHOW`.
        """
        return ParseResult(
            kind=Self.CONFIG_SHOW,
            config=config^,
            overlay=overlay^,
            config_path=config_path,
            no_config=no_config,
            operand=String(""),
        )

    @staticmethod
    def doctor(
        var config: RunnerConfig,
        var overlay: CliOverlay,
        config_path: String = "",
        no_config: Bool = False,
    ) -> ParseResult:
        """A result asking `main` to run environment diagnostics.

        Args:
            config: The parsed doctor configuration. Consumed.
            overlay: The typed argv overlay. Consumed.
            config_path: The explicit configuration path, or empty to discover.
            no_config: Whether to skip configuration discovery.

        Returns:
            A result whose `kind` is `DOCTOR`.
        """
        return ParseResult(
            kind=Self.DOCTOR,
            config=config^,
            overlay=overlay^,
            config_path=config_path,
            no_config=no_config,
            operand=String(""),
        )

    @staticmethod
    def debug(
        var config: RunnerConfig,
        var overlay: CliOverlay,
        var operand: String,
        config_path: String = "",
        no_config: Bool = False,
    ) -> ParseResult:
        """A result asking `main` to prepare one test and hand over the terminal.

        Args:
            config: The parsed build configuration. Consumed.
            overlay: The typed argv overlay. Consumed.
            operand: The `PATH::TEST` node id to debug. Consumed.
            config_path: The explicit configuration path, or empty to discover.
            no_config: Whether to skip configuration discovery.

        Returns:
            A result whose `kind` is `DEBUG`.
        """
        return ParseResult(
            kind=Self.DEBUG,
            config=config^,
            overlay=overlay^,
            config_path=config_path,
            no_config=no_config,
            operand=operand^,
        )

    @staticmethod
    def scaffold(var operand: String) -> ParseResult:
        """A result asking `main` to scaffold one test file.

        Its config and overlay are placeholders: the file is created before any
        project configuration is discovered, so none of it applies.

        Args:
            operand: The path to create. Consumed.

        Returns:
            A result whose `kind` is `NEW`.
        """
        return ParseResult(
            kind=Self.NEW,
            config=RunnerConfig.default(),
            overlay=CliOverlay.default(),
            config_path="",
            no_config=False,
            operand=operand^,
        )

    def is_run(self) -> Bool:
        """Whether this result is a configured run."""
        return self.kind == Self.RUN

    def is_help(self) -> Bool:
        """Whether this result asks for the help directive."""
        return self.kind == Self.SHOW_HELP

    def is_version(self) -> Bool:
        """Whether this result asks for the version directive."""
        return self.kind == Self.SHOW_VERSION

    def is_config_show(self) -> Bool:
        """Whether this result asks to render the resolved configuration."""
        return self.kind == Self.CONFIG_SHOW

    def is_doctor(self) -> Bool:
        """Whether this result asks to diagnose the local mtest environment."""
        return self.kind == Self.DOCTOR

    def is_debug(self) -> Bool:
        """Whether this result asks to hand the terminal to one test."""
        return self.kind == Self.DEBUG

    def is_new(self) -> Bool:
        """Whether this result asks to scaffold one test file."""
        return self.kind == Self.NEW
