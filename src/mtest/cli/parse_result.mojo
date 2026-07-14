"""`ParseResult`: what a successful parse produces.

Parsing either yields a configured run or a non-error directive to print help or
the version. A usage error is not a `ParseResult` — it is raised. `main` (a later
layer) renders help/version to stdout with exit 0 and executes the run config;
this layer never prints or exits.
"""
from mtest.config import RunnerConfig


@fieldwise_init
struct ParseResult(Copyable, Movable):
    """The outcome of a successful parse: a run config, or a help/version ask.

    A tagged union over `kind`. When `kind == RUN` the `config` field is the
    parsed configuration; for the two directives `config` carries a default and
    is unused. Owns a `RunnerConfig`, so copies are explicit; never raises.
    """

    var kind: Int
    """Which outcome this is: `RUN`, `SHOW_HELP`, or `SHOW_VERSION`."""

    var config: RunnerConfig
    """The parsed run configuration; meaningful only when `kind == RUN`."""

    comptime RUN = 0
    comptime SHOW_HELP = 1
    comptime SHOW_VERSION = 2

    @staticmethod
    def run(var config: RunnerConfig) -> ParseResult:
        """A result that runs `config`. Takes ownership of the config."""
        return ParseResult(kind=Self.RUN, config=config^)

    @staticmethod
    def show_help() -> ParseResult:
        """A result asking `main` to print help (a default config rides along).
        """
        return ParseResult(kind=Self.SHOW_HELP, config=RunnerConfig.default())

    @staticmethod
    def show_version() -> ParseResult:
        """A result asking `main` to print the version string."""
        return ParseResult(
            kind=Self.SHOW_VERSION, config=RunnerConfig.default()
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
