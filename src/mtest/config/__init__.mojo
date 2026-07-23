"""The config layer of the mtest runner.

Centered on `RunnerConfig`, the typed home for every knob the session reads,
`CliOverlay`, the presence-aware values supplied by argv, and `FileConfig`, the
typed presence-aware `mtest.toml` layer. Alongside them live the closed
vocabularies that name a config choice (`ShowOutput`, `Verbosity`, `ColorWhen`,
`ShardMode`, `AnnotationsMode`), source-neutral single-value validators, the
mojo-path resolution helper, the shell-quoting helpers (`shell_quote`,
`shell_join`) that every reproduce line is rendered through, and the
byte-to-text codec (`lossy_utf8`) that every captured stream is decoded with.

This layer is data plus pure helpers: no argv parsing, environment or file
reads, spawning, or printing. `toml_bridge` is the single exception to
otherwise-pure product Mojo: it initializes Python lazily inside the
parse-from-string call and uses only stdlib `tomllib`, immediately converting
the result into typed Mojo data. It may import from `model`, but currently needs
nothing there.

The public surface is re-exported here so callers write
`from mtest.config import FileConfig, RunnerConfig, parse_toml, ...`.
"""
from mtest.config.annotations_mode import (
    AnnotationsMode,
    annotations_resolved_on,
)
from mtest.config.color_when import ColorWhen
from mtest.config.file_config import FileConfig, OverrideRule
from mtest.config.lossy_utf8 import lossy_utf8
from mtest.config.mojo_path import resolve_mojo_path
from mtest.config.overlay import CliOverlay
from mtest.config.precompile import Precompile
from mtest.config.runner_config import RunnerConfig
from mtest.config.shell_quote import shell_join, shell_quote
from mtest.config.shard_mode import ShardMode
from mtest.config.show_output import ShowOutput
from mtest.config.toml_bridge import (
    ConfigDiagnostic,
    ConfigFailureKind,
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
)
