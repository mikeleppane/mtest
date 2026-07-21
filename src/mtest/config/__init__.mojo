"""The config layer of the mtest runner.

Centered on `RunnerConfig`, the typed home for every knob the cli parser fills
and the session reads. Alongside it live the closed vocabularies that name a
config choice (`ShowOutput`, `Verbosity`, `ColorWhen`, `ShardMode`,
`AnnotationsMode`), the mojo-path resolution helper, the shell-quoting helpers
(`shell_quote`, `shell_join`) that every reproduce line is rendered through,
and the byte-to-text codec (`lossy_utf8`) that every captured stream is decoded
with.

This layer is data plus pure helpers: no parsing, no environment or file reads,
no printing. It may import from `model`, but currently needs nothing there.

The public surface is re-exported here so callers write
`from mtest.config import RunnerConfig, resolve_mojo_path, shell_quote, ...`.
"""
from mtest.config.annotations_mode import (
    AnnotationsMode,
    annotations_resolved_on,
)
from mtest.config.color_when import ColorWhen
from mtest.config.lossy_utf8 import lossy_utf8
from mtest.config.mojo_path import resolve_mojo_path
from mtest.config.precompile import Precompile
from mtest.config.runner_config import RunnerConfig
from mtest.config.shell_quote import shell_join, shell_quote
from mtest.config.shard_mode import ShardMode
from mtest.config.show_output import ShowOutput
from mtest.config.verbosity import Verbosity
