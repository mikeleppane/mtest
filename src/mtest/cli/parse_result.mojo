"""`ParseResult`: what a successful parse produces.

Parsing either yields a configured run or `config show` request with both its
typed argv overlay and defaults-folded compatibility config, or a non-error
directive to print help or the version. A usage error is not a `ParseResult` —
it is raised. `main` handles each result; this layer never prints or exits.
"""
from mtest.config import CliOverlay, RunnerConfig


@fieldwise_init
struct ParseResult(Copyable, Movable):
    """The outcome of a successful parse.

    A tagged union over `kind`. For `RUN` and `CONFIG_SHOW`, `overlay` holds
    argv presence and values while `config` holds their defaults-folded
    compatibility view. Only help and version carry placeholder fields.
    """

    var kind: Int
    """The `RUN`, `SHOW_HELP`, `SHOW_VERSION`, or `CONFIG_SHOW` outcome."""

    var config: RunnerConfig
    """The parsed run config; meaningful for `RUN` and `CONFIG_SHOW`."""

    var overlay: CliOverlay
    """The argv overlay; meaningful for `RUN` and `CONFIG_SHOW`."""

    var config_path: String
    """The explicit configuration path, or empty when discovery applies."""

    var no_config: Bool
    """Whether configuration-file discovery is explicitly disabled."""

    comptime RUN = 0
    comptime SHOW_HELP = 1
    comptime SHOW_VERSION = 2
    comptime CONFIG_SHOW = 3

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
