"""`ParseResult`: what a successful parse produces.

Parsing either yields a configured run with both its typed argv overlay and
defaults-folded compatibility config, or a non-error directive to print help
or the version. A usage error is not a `ParseResult` — it is raised. `main`
renders help and version to stdout with exit 0 and executes the run config;
this layer never prints or exits.
"""
from mtest.config import CliOverlay, RunnerConfig


@fieldwise_init
struct ParseResult(Copyable, Movable):
    """The outcome of a successful parse: a run, or a help/version ask.

    A tagged union over `kind`. When `kind == RUN`, `overlay` holds argv
    presence and values while `config` holds their defaults-folded
    compatibility view. For directives both fields are placeholders.
    """

    var kind: Int
    """Which outcome this is: `RUN`, `SHOW_HELP`, or `SHOW_VERSION`."""

    var config: RunnerConfig
    """The parsed run configuration; meaningful only when `kind == RUN`."""

    var overlay: CliOverlay
    """The typed argv overlay; meaningful only when `kind == RUN`."""

    var config_path: String
    """The explicit configuration path, or empty when discovery applies."""

    var no_config: Bool
    """Whether configuration-file discovery is explicitly disabled."""

    comptime RUN = 0
    comptime SHOW_HELP = 1
    comptime SHOW_VERSION = 2

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

    def is_run(self) -> Bool:
        """Whether this result is a configured run."""
        return self.kind == Self.RUN

    def is_help(self) -> Bool:
        """Whether this result asks for the help directive."""
        return self.kind == Self.SHOW_HELP

    def is_version(self) -> Bool:
        """Whether this result asks for the version directive."""
        return self.kind == Self.SHOW_VERSION
