"""The cli layer of the mtest runner: parsing and command-local diagnosis.

The parser turns an argument vector into a `ParseResult`: a typed argv overlay
plus its defaults-folded `RunnerConfig`, tagged as a run, config-display, or
doctor request, or a directive to print help or the version. A usage error is
raised as a `cli:`-prefixed `Error` for `main` to print to stderr before
exiting 4. The doctor runner owns its fixed, contained Layer-5 diagnostics and
returns lines to `main`; it never enters a session or reporter. The scaffold
runners behind `mtest new` and `mtest init` have the same shape: they write
source — one test file, or the handful of files a project starts from — and
return lines and a code rather than printing or exiting.

The parser is table-driven. `flag_specs()` is the single source of truth for
every accepted spelling: its arity, whether it repeats, and its owned help text,
value placeholder, and group. It parses the full v1 grammar, and the grouped
help output is generated from that same table.

The layer also owns `build_flags_string`, which renders a `RunnerConfig` back
into the shell-ready flag string the console echoes in a run-failure
`reproduce:` line.

The public surface is re-exported here so callers write
`from mtest.cli import parse_args, ParseResult, build_flags_string, ...`.
"""
from mtest.cli.build_flags import build_flags_string
from mtest.cli.flag_spec import (
    FlagGroup,
    FlagId,
    FlagSpec,
    flag_group_name,
    flag_specs,
)
from mtest.cli.parse_result import ParseResult
from mtest.cli.doctor import (
    DoctorReport,
    host_platform_label,
    platform_label,
    run_doctor,
)
from mtest.cli.parser import (
    MTEST_VERSION,
    help_text,
    parse_args,
    version_text,
)
from mtest.cli.scaffold import (
    ScaffoldReport,
    gitignore_update,
    render_github_workflow,
    render_mtest_toml,
    render_test_file,
    run_init,
    run_new,
)
