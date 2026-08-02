"""The config layer of the mtest runner.

`RunnerConfig` is the typed home for every knob the session reads. `CliOverlay`
carries the presence-aware values supplied by argv, and `FileConfig` is the
typed presence-aware `mtest.toml` layer. `ResolvedConfig` carries layered
values, per-key provenance, ordered overrides, and command-active key metadata.

Alongside them live the closed vocabularies that name a config choice
(`ShowOutput`, `Verbosity`, `ColorWhen`, `ShardMode`, `AnnotationsMode`) and
the source-neutral single-value validators. The cross-cutting helpers sit here
too: `resolve_mojo_path`, the shell-quoting pair `shell_quote` and `shell_join`
that every reproduce line is rendered through, and the byte-to-text codec
`lossy_utf8` that every captured stream is decoded with.

This layer is data plus pure helpers: no argv parsing, environment or file
reads, spawning, or printing. `toml_bridge` parses with the pinned vendored
native TOML package and applies every mtest schema and value rule. `show`
renders a resolved value as human-facing, copy-pasteable TOML.

The public surface is re-exported here so callers write
`from mtest.config import FileConfig, RunnerConfig, parse_toml, ...`.
"""
from mtest.config.annotations_mode import (
    AnnotationsMode,
    annotations_resolved_on,
)
from mtest.config.color_when import ColorWhen
from mtest.config.file_config import FileConfig, OverrideRule
from mtest.config.last_run_state import (
    LastRunRecordKind,
    LastRunRecord,
    LastRunState,
    LastRunDiagnosticKind,
    LastRunDiagnostic,
    LastRunEncodeResult,
    LastRunParseResult,
    StateDelta,
    encode_last_run_state,
    parse_last_run_state,
    merge_last_run_state,
)
from mtest.config.lossy_utf8 import lossy_utf8
from mtest.config.mojo_path import resolve_mojo_path
from mtest.config.overlay import CliOverlay
from mtest.config.precompile import Precompile
from mtest.config.provenance import ConfigProvenance, Provenance
from mtest.config.resolve import (
    ActiveConfigKeys,
    ConfigEnvironment,
    ResolvedConfig,
    resolve_config,
    validate_resolved_config,
)
from mtest.config.runner_config import (
    RunnerConfig,
    cli_only_resolution_defaults,
)
from mtest.config.show import render_config_show
from mtest.config.shell_quote import shell_join, shell_quote
from mtest.config.shard_mode import ShardMode
from mtest.config.show_output import ShowOutput
from mtest.config.toml_bridge import (
    ConfigDiagnostic,
    ConfigFailureKind,
    TOML_SOURCE_MAX_BYTES,
    TomlParseResult,
    parse_toml,
)
from mtest.config.verbosity import Verbosity
from mtest.config.value_validation import (
    build_arg_rejection,
    parse_annotations_value,
    parse_color_value,
    parse_nonnegative_decimal,
    parse_precompile_value,
    parse_show_output_value,
    parse_verbosity_value,
    parse_worker_count,
    safe_path_label,
)
