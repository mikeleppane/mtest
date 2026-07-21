"""The cli layer of the mtest runner: the argument parser.

This is the parser only, not `main`. It turns an argument vector into a
`ParseResult` — a filled `RunnerConfig` to run, or a directive to print help or
the version. A usage error is raised as a `cli:`-prefixed `Error` for `main` to
print to stderr before exiting 4.

The parser is table-driven. `flag_specs()` is the single source of truth for
every accepted spelling: its arity, whether it repeats, whether this build
serves it, and, for a not-yet-served flag, the milestone that brings it. The
full v1 grammar is parsed today and the unserved flags are refused loudly, so
later work flips an availability bit instead of teaching the parser a new token.

The layer also owns `build_flags_string`, which renders a `RunnerConfig` back
into the shell-ready flag string the console echoes in a run-failure
`reproduce:` line.

The public surface is re-exported here so callers write
`from mtest.cli import parse_args, ParseResult, build_flags_string, ...`.
"""
from mtest.cli.build_flags import build_flags_string
from mtest.cli.flag_spec import FlagId, FlagSpec, flag_specs
from mtest.cli.parse_result import ParseResult
from mtest.cli.parser import (
    MTEST_VERSION,
    help_text,
    parse_args,
    version_text,
)
