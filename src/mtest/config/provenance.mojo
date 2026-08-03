"""Closed provenance types for resolved configuration values.

Each configuration-eligible key records its source independently, including
values equal to their lower-precedence defaults.
"""


@fieldwise_init
struct Provenance(Equatable, ImplicitlyCopyable, Movable):
    """One source in the configuration precedence order.

    The order runs `DEFAULT`, `MTEST_TOML`, `ENV_MTEST_MOJO`, then `CLI`, each
    replacing the value below it. `ENV_MTEST_MOJO` reaches only `mojo_path`.
    """

    var value: Int
    """The stable integer discriminant identifying the source."""

    comptime DEFAULT = Self(0)
    comptime MTEST_TOML = Self(1)
    comptime ENV_MTEST_MOJO = Self(2)
    comptime CLI = Self(3)

    def __eq__(self, other: Self) -> Bool:
        """Whether both values name the same source."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether the values name different sources."""
        return self.value != other.value


@fieldwise_init
struct ConfigProvenance(Copyable, Movable):
    """The independently resolved source of every eligible config key."""

    var paths: Provenance
    """Source of `[run] paths`."""

    var excludes: Provenance
    """Source of `[run] exclude`."""

    var gates: Provenance
    """Source of `[run] gates`."""

    var serial_globs: Provenance
    """Source of `[run] serial`."""

    var workers: Provenance
    """Source of `[run] workers`."""

    var timeout_secs: Provenance
    """Source of `[run] timeout`."""

    var retries: Provenance
    """Source of `[run] retries`."""

    var maxfail: Provenance
    """Source of `[run] maxfail`."""

    var fail_on_flaky: Provenance
    """Source of `[run] fail-on-flaky`."""

    var state: Provenance
    """Source of `[run] state`."""

    var mojo_path: Provenance
    """Source of `[build] mojo`."""

    var include_paths: Provenance
    """Source of `[build] include`."""

    var build_args: Provenance
    """Source of `[build] build-args`."""

    var precompiles: Provenance
    """Source of `[build] precompile`."""

    var compile_timeout_secs: Provenance
    """Source of `[build] compile-timeout`."""

    var color: Provenance
    """Source of `[report] color`."""

    var show_output: Provenance
    """Source of `[report] show-output`."""

    var verbosity: Provenance
    """Source of `[report] verbosity`."""

    var durations: Provenance
    """Source of `[report] durations`."""

    var junit_dest: Provenance
    """Source of `[report] junit-xml`."""

    var json_dest: Provenance
    """Source of `[report] json`."""

    var gh_annotations: Provenance
    """Source of `[report] gh-annotations`."""

    @staticmethod
    def defaults() -> ConfigProvenance:
        """Build provenance for an untouched built-in-default layer.

        Returns:
            A newly allocated record with every key sourced from defaults.
        """
        return ConfigProvenance(
            paths=Provenance.DEFAULT,
            excludes=Provenance.DEFAULT,
            gates=Provenance.DEFAULT,
            serial_globs=Provenance.DEFAULT,
            workers=Provenance.DEFAULT,
            timeout_secs=Provenance.DEFAULT,
            retries=Provenance.DEFAULT,
            maxfail=Provenance.DEFAULT,
            fail_on_flaky=Provenance.DEFAULT,
            state=Provenance.DEFAULT,
            mojo_path=Provenance.DEFAULT,
            include_paths=Provenance.DEFAULT,
            build_args=Provenance.DEFAULT,
            precompiles=Provenance.DEFAULT,
            compile_timeout_secs=Provenance.DEFAULT,
            color=Provenance.DEFAULT,
            show_output=Provenance.DEFAULT,
            verbosity=Provenance.DEFAULT,
            durations=Provenance.DEFAULT,
            junit_dest=Provenance.DEFAULT,
            json_dest=Provenance.DEFAULT,
            gh_annotations=Provenance.DEFAULT,
        )
