"""The config layer of the mtest runner (Layer 1).

This is `RunnerConfig`, the typed home for every knob the cli parser (a later
layer) fills and the session (a later layer) reads, plus the config-specific
closed vocabularies (`ShowOutput`, `Verbosity`, `ColorWhen`) and the pure
mojo-path resolution helper. It imports only from `model` — and does not
today, because none of this data needs model's vocabulary. It is DATA plus
pure helpers: no parsing, no environment or file reads, no printing.

The public surface is re-exported here so callers write
`from mtest.config import RunnerConfig, resolve_mojo_path, ShowOutput, ...`.
"""
from mtest.config.color_when import ColorWhen
from mtest.config.mojo_path import resolve_mojo_path
from mtest.config.precompile import Precompile
from mtest.config.runner_config import RunnerConfig
from mtest.config.show_output import ShowOutput
from mtest.config.verbosity import Verbosity
