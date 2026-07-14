"""The cli layer of the mtest runner (Layer 5): the argument parser.

This is the parser only — not `main`. It imports `config` (and `model` through
it) and turns an argument vector into a `ParseResult`: a filled `RunnerConfig`
to run, or a directive to print help or the version. A usage error is raised as
a `cli:`-prefixed `Error` for `main` to print to stderr and exit 4.

The parser is table-driven. `flag_specs()` is the single source of truth for
every accepted spelling — its arity, whether it repeats, whether this build
serves it, and, for a not-yet-served flag, the milestone that brings it. The
full v1 grammar is parsed now and the unserved flags are refused loudly, so
later work flips an availability bit instead of teaching a new token.

The public surface is re-exported here so callers write
`from mtest.cli import parse_args, ParseResult, ...`.
"""
from mtest.cli.flag_spec import FlagId, FlagSpec, flag_specs
from mtest.cli.parse_result import ParseResult
from mtest.cli.parser import (
    MTEST_VERSION,
    help_text,
    parse_args,
    version_text,
)
