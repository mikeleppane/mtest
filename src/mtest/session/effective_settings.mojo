"""Pure per-file settings lookup for session-owned execution policy.

Override globs match the same root-relative paths and use the same matcher as
discovery exclusions. Scalar keys use the first matching table that supplies
that key, unless the global scalar came from CLI. Serial pinning is monotonic:
global serial globs and every matching `serial = true` table form a union.

Gate files use this same scalar lookup because they are ordinary discovered,
root-relative test files. Their `serial` value is still resolved
deterministically but does not move them out of the fixed gate band: serial-last
is a run-file scheduling policy, while all gates must remain before run files.
"""
from mtest.config import (
    ActiveConfigKeys,
    ConfigProvenance,
    LastRunState,
    OverrideRule,
    Provenance,
    ResolvedConfig,
    RunnerConfig,
)
from mtest.discover import fnmatch


@fieldwise_init
struct EffectiveFileSettings(Equatable, ImplicitlyCopyable, Movable):
    """The execution-policy values effective for one root-relative file."""

    var timeout_secs: Int
    """The run, probe, and attribution-isolation timeout in seconds."""

    var compile_timeout_secs: Int
    """The build and recovery-build timeout in seconds."""

    var retries: Int
    """The crash-class retry ceiling."""

    var serial: Bool
    """Whether the file belongs to the final capacity-one serial batch."""


def _compat_resolved_config(config: RunnerConfig) -> ResolvedConfig:
    """Wrap the legacy runner config with no per-file override tables."""
    var active = ActiveConfigKeys.run()
    if config.collect:
        active = ActiveConfigKeys.collect()
    return ResolvedConfig(
        config.copy(),
        True,
        List[OverrideRule](),
        ConfigProvenance.defaults(),
        active^,
        False,
        "",
        List[String](),
        LastRunState.empty(),
        False,
    )


def _rule_matches(rule: OverrideRule, path: String) -> Bool:
    """Whether any file glob in `rule` matches `path`."""
    for pattern in rule.files:
        if fnmatch(path, pattern):
            return True
    return False


def effective_file_settings(
    resolved: ResolvedConfig, path: String
) -> EffectiveFileSettings:
    """Resolve execution-policy values for one root-relative file.

    Matching tables are visited in document order. Each scalar has its own
    first-supplier latch, so an earlier table that omits a scalar does not hide
    a value supplied later. CLI provenance starts only that scalar's latch in
    the closed state. Serial is intentionally different: false never unpins,
    and every matching true table participates in the union.

    Args:
        resolved: Layered global values, provenance, and ordered override
            tables. Not mutated.
        path: A discovered root-relative file path, including a gate path when
            the caller is scheduling a gate.

    Returns:
        A small typed value suitable for storing directly on scheduler state.
    """
    var timeout_secs = resolved.config.timeout_secs
    var compile_timeout_secs = resolved.config.compile_timeout_secs
    var retries = resolved.config.retries
    var saw_timeout = resolved.provenance.timeout_secs == Provenance.CLI
    var saw_compile_timeout = (
        resolved.provenance.compile_timeout_secs == Provenance.CLI
    )
    var saw_retries = resolved.provenance.retries == Provenance.CLI
    var serial = False

    for pattern in resolved.config.serial_globs:
        if fnmatch(path, pattern):
            serial = True

    for rule in resolved.overrides:
        if not _rule_matches(rule, path):
            continue
        if not saw_timeout and rule.saw_timeout:
            timeout_secs = rule.timeout_secs
            saw_timeout = True
        if not saw_compile_timeout and rule.saw_compile_timeout:
            compile_timeout_secs = rule.compile_timeout_secs
            saw_compile_timeout = True
        if not saw_retries and rule.saw_retries:
            retries = rule.retries
            saw_retries = True
        if rule.saw_serial and rule.serial:
            serial = True

    return EffectiveFileSettings(
        timeout_secs,
        compile_timeout_secs,
        retries,
        serial,
    )
