# CLI reference

The listing below is generated against `build/mtest --help` and is not allowed
to drift from that output:

```text
mtest — a pytest-like test runner for Mojo

usage: mtest [run] [PATHS...] [flags] [-- BUILD-ARGS...]
       mtest collect [PATHS...] [--format lines|json] [flags]
       mtest config show [PATHS...] [flags] [-- BUILD-ARGS...]
       mtest doctor [--config PATH | --no-config] [--color WHEN] [-q | -v]
       mtest debug PATH::TEST [build flags] [-- BUILD-ARGS...]
       mtest new PATH
       mtest init [--ci github]
       mtest completions bash|zsh|fish

Subcommands:
  run [PATHS...] [flags]      Run tests (the default subcommand).
  collect [PATHS...] [flags]  List node ids without running tests.
  config show [PATHS...]      Show resolved configuration.
  doctor [flags]              Diagnose the environment without running tests.
  debug PATH::TEST            Run one test with the terminal handed over.
  new PATH                    Create one runnable test file.
  init [--ci github]          Bootstrap a project in this directory.
  completions SHELL           Print a bash, zsh, or fish completion script.
  help                        Show this help and exit.
  version                     Show the version and exit.

Selection:
  --exclude GLOB              Exclude matching files (repeatable).
  -k STR                      Select node ids containing STR.
  --gate PATH                 Run PATH before ordinary files (repeatable).
  --shard [hash:|slice:]M/N   Run only the selected shard.

Execution:
  -x, --exitfirst             Stop after the first failing file.
  --maxfail N                 Stop after N failed tests (0 disables).
  --timeout SECS              Set per-file run timeout (0 disables).
  --retries N                 Retry crash-class outcomes N times.
  --fail-on-flaky             Exit 1 when any file passed only after retries.
  -n, --workers N|auto        Set worker count (default: 1).
  --serial GLOB               Run matching files serially (repeatable).
  --shuffle                   Randomize run-file order (gates keep theirs).
  --seed N                    Fix the --shuffle order to a reproducible seed.
  --no-cache                  Build without reading/writing the build cache.
  --cache-clear               Delete .mtest-cache (cache/last-run state), run.

Building:
  -I PATH                     Add a Mojo include path (repeatable).
  --build-arg ARG             Forward one argument to mojo build (repeatable).
  --precompile SRC[:OUT]      Precompile package before builds (repeatable).
  --mojo PATH                 Use this Mojo executable.
  --compile-timeout SECS      Set per-file build timeout (0 disables).

Reporting:
  -s                          Show captured output for all files.
  --show-output MODE          Choose failures|all|none captured output.
  --durations N               Show N slowest file durations (0 disables).
  -q                          Suppress passing file rows.
  -v                          Show build commands and step timings.
  --color WHEN                Choose auto|always|never color output.
  --format FORMAT             Collect output format: lines (default) or json.
  --json PATH|-               Write NDJSON events to PATH or stdout.
  --junit-xml PATH            Write a JUnit XML report.
  --report FORMAT:PATH        Write an md or html run report (once each).
  --report-style STYLE        Choose concise|full report detail.
  --gh-annotations MODE       Choose off|on|auto GitHub annotations.

Session state:
  --config PATH               Use this project configuration file.
  --no-config                 Disable project configuration discovery.
  --lf, --last-failed         Run only entries from the last-failed state.
  --ff, --failed-first        Run last-failed entries before the rest.

General:
  --collect-only              List node ids without running tests.
  -h, --help                  Show this help and exit.
  --version                   Show the version and exit.
```

| Flag | Meaning |
|------|---------|
| `PATHS...` | files, directories (walked recursively for `test_*.mojo`), or a node id (`path::test`, selects one test) |
| `-k STR` | case-insensitive substring filter over node ids; a repeated `-k` takes the last occurrence; ignored under `collect`; a `-k` that empties the session exits `5` |
| `--exclude GLOB` | (repeatable) drop matching files from the run, each reported with an `EXCLUDED` line |
| `-I PATH` | (repeatable) an include path forwarded to every `mojo build` |
| `--build-arg ARG` / `-- ARGS...` | forward arguments to `mojo build`; `-o`, `--emit`, and extra source operands are refused (exit `4`) |
| `--gate PATH` | (repeatable) files that must pass first; a gate failure aborts the whole session |
| `--precompile SRC[:OUT]` | (repeatable) `mojo precompile` a package before any test build; its output directory is auto-added to `-I` |
| `--mojo PATH` | override the `mojo` toolchain resolved from `PATH` (or `MTEST_MOJO`) |
| `--config PATH`, `--no-config` | select one project config or disable config discovery |
| `config show [PATHS...] [flags]` | render the fully resolved configuration without running tests |
| `doctor [flags]` | run ten contained environment checks without starting a test session |
| `debug PATH::TEST` | build and probe one test, print the `build:`/`run:` commands, then replace mtest with the binary; no summary and no mtest verdict |
| `new PATH` | scaffold one runnable test file at `PATH`, creating parent directories; never overwrites (exit `4`) |
| `init [--ci github]` | bootstrap a project in the current directory: a first test, an `mtest.toml`, a `.gitignore` entry, and with `--ci github` a workflow; nothing existing is replaced |
| `--lf`, `--last-failed` | run only tests recorded as failed in the last completed state |
| `--ff`, `--failed-first` | run last-failed tests first, then the remaining selection |
| `-x`, `--exitfirst` | stop scheduling new files after the first failing file |
| `--maxfail N` | stop scheduling once `N` tests have failed (`0`, the default, means no limit); checked between files, not mid-file |
| `--timeout SECS` | bound a single file's run (default `300`, `0` disables); exceeding it yields TIMEOUT |
| `--compile-timeout SECS` | bound a single file's build (default `600`, `0` disables); exceeding it yields COMPILE-TIMEOUT |
| `--retries N` | crash-class-only retries, `N` extra attempts (default `0`); a late pass is reported FLAKY |
| `--fail-on-flaky` | exit `1` when the run would otherwise exit `0` and at least one file is FLAKY |
| `-s`, `--show-output MODE` | `failures` (default), `all`, or `none`: which outcomes show captured output |
| `--durations N` | print the `N` slowest files by run-only wall-clock after the summary (`0`, the default, disables); survives `-q` |
| `-q` | quiet: omit PASS lines |
| `-v` | verbose: add the build command, per-step timing, and the `SLOW`-step label |
| `--color WHEN` | `auto` (default), `always`, or `never`; `NO_COLOR` disables `auto`, while an explicit `always` or `never` wins |
| `--shard [hash:\|slice:]M/N` | run (or collect) only shard `M` of `N`; `hash:` (default, stable over the path) or `slice:` (sorted round-robin) |
| `-n`, `--workers N\|auto` | run files across a pool of `N` worker processes; `auto` is half the logical cores (default `1`, sequential; ignored under `-k`/node-id selection) |
| `--serial GLOB` | (repeatable) pin matching files to a final one-at-a-time pass after the parallel batch |
| `--shuffle` | randomize the order run files execute in, to surface order dependencies; gates keep their listed order and every report stays node-id sorted; CLI-only, never read from `mtest.toml` |
| `--seed N` | fix the `--shuffle` order to a reproducible seed (requires `--shuffle`); without it the runner draws one and prints it |
| `--no-cache` | build without reading or writing the build cache; CLI-only, never read from `mtest.toml` |
| `--cache-clear` | delete `.mtest-cache` (build cache and last-run state), then run; CLI-only, never read from `mtest.toml` |
| `--json PATH\|-` | write the versioned NDJSON event stream to `PATH`, or to stdout with `-` |
| `--junit-xml PATH` | write a schema-validated JUnit XML report, renamed atomically onto `PATH` |
| `--report FORMAT:PATH` | (repeatable once per format) write a self-contained `md` or `html` run report, renamed atomically onto `PATH`; a second destination for the same format, or a `PATH` whose parent does not exist, is a usage error (exit `4`) |
| `--report-style STYLE` | `concise` (default) sections only files that need a second look, `full` sections every file; inert without a `--report` destination |
| `--gh-annotations MODE` | `off\|on\|auto` (default `auto`); `--json -` requires an explicit `--gh-annotations off` |
| `collect [PATHS] [flags]`, `--collect-only` | list node ids, sorted lexicographically, instead of running anything |
| `--format lines\|json` | `collect` only: the plain listing (default) or the versioned NDJSON collect stream |
| `-h`, `--help` | print the usage text and exit `0` |
| `--version` | print the version and exit `0` |

**The first argument is read as a subcommand when it names one.** `mtest new`
is the scaffolding command even in a directory that contains a `new/`, and the
same holds for `collect`, `debug`, `init`, `doctor`, `config`, `version`, and
`help`. Spell the path `./new` to run it instead — a token starting `./` is
never a subcommand, so that spelling keeps working as more subcommands are
added. Only the leading token is affected: `mtest run new` and
`mtest collect new` need no prefix, and neither does `[run] paths` in an
`mtest.toml`.

`-n`/`--workers N` runs discovered files across a pool of `N` worker
processes; `-n auto` sizes the pool to half the machine's logical cores. The
header reports the resolved count, and completion order reflects the
parallelism:

```console
$ pixi run bash -c 'build/mtest -n 2 e2e/matrix'
mtest 1.1.0 (mojo)
root: /home/mikko/dev/mtest   selected: 2 files   excluded: 0   workers: 2

PASS           e2e/matrix/test_beta.mojo       0.02s
PASS           e2e/matrix/test_alpha.mojo      0.02s

===== 5 passed, 0 failed, 0 skipped, builds: 2, cached: 0 (0 excluded, 0 not run) in 1.9s =====
```

`--serial GLOB` pins matching files to a final one-at-a-time pass that runs
after the parallel batch drains, for a file that cannot safely share the
machine with its peers. Pinned files carry a `SERIAL` tag:

```console
$ pixi run bash -c "build/mtest -n 2 --serial 'e2e/matrix/test_alpha.mojo' e2e/matrix"
mtest 1.1.0 (mojo)
root: /home/mikko/dev/mtest   selected: 2 files   excluded: 0   workers: 2

PASS           e2e/matrix/test_beta.mojo       0.02s
PASS           e2e/matrix/test_alpha.mojo      0.03s  SERIAL

===== 5 passed, 0 failed, 0 skipped, builds: 2, cached: 0 (0 excluded, 0 not run) in 2.3s =====
```

The default is `-n 1`: a single worker on the sequential path, byte-for-byte
the same run and output as before the pool existed.

## Run and collect exit codes

These codes are frozen for `run` and `collect`, mirroring pytest. `config show`
and `doctor` have command-specific exit domains in
[§27 of the CLI contract](cli-contract.md#27-inspection-subcommands):

| Code | Meaning |
|------|---------|
| `0` | every selected test's outcome is PASS or SKIP |
| `1` | at least one failing outcome (FAIL, CRASH, TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT, MALFORMED-SUITE, PRECOMPILE-ERROR); or a would-be `0` under `--fail-on-flaky` with at least one FLAKY file |
| `2` | interrupted (SIGINT/SIGTERM); a partial summary is printed |
| `3` | internal mtest error, including protocol drift and a report-destination I/O failure |
| `4` | CLI usage error, detected before any test runs |
| `5` | no tests collected (empty walk, `-k` matched nothing, everything excluded) |

When run/collect outcomes mix: a usage error aborts with `4` before the run;
otherwise an interrupt dominates, then an internal error, then any failing
outcome, then nothing-collected.

The full contract, every flag, the node-id grammar, and the outcome
vocabulary live in the [command-line contract](cli-contract.md).
