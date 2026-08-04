# mtest

mtest is a test runner for Mojo. It finds every test file under a directory,
builds each one, executes the resulting binary under supervision, and
aggregates what they report into a single verdict a continuous-integration
system can act on. The standard library's per-file suite keeps owning discovery
and the report format inside each file; mtest owns everything between files.

## Install

The package is published to the modular-community channel, built from source
for linux-64 and osx-arm64. From an empty directory:

```console
$ pixi init .
$ pixi workspace channel add https://conda.modular.com/max/
$ pixi workspace channel add https://repo.prefix.dev/modular-community
$ pixi add mtest
$ pixi run mtest --version
mtest 1.0.0
```

Skip the first command in a workspace that already exists. It is there because
every command after it edits a `pixi.toml`, and `pixi workspace channel add`
fails outright when there is none.

Three channels have to resolve for that to solve, and the package declares the
pinned Mojo compiler as its run dependency. The
[Installation section of the README](https://github.com/mikeleppane/mtest#installation)
names all three, and states which toolchain and which platforms each release
supports.

## Where to go next

- [Getting started](getting-started.md) — from an empty directory to a green
  run, and what a file that does not compile looks like when it is reported
  honestly.
- [Continuous integration](ci.md) — the workflow to paste, and the sharded
  variant of it.
- [Run reports](reports.md) — the self-contained Markdown or HTML document
  `--report` writes for a reader, and what happens when it cannot be
  delivered.
- [Shell completion](completions.md) — where each shell wants the script
  `mtest completions` prints, and what it completes once it is installed.
- [Command-line contract](cli-contract.md) — the frozen specification of every
  subcommand, flag, exit code, and stream.
- [JSON event stream](json-stream.md) — the machine-readable stream, event by
  event.
- [Collect JSON stream](collect-stream.md) — the machine-readable test listing
  `collect --format json` writes.
- [Releasing](releasing.md) — the maintainer runbook.

Everything else stays in the
[README](https://github.com/mikeleppane/mtest#readme): selection, retries and
failing a run on flaky files, timeouts, sharding, random run order, the build
cache, project scaffolding, handing the terminal to a single test, assertion
diagnostics, and the complete command-line listing. That document is the front door on purpose, and the few
commands and outputs this site needs are mirrored from it byte for byte rather
than retyped: a gate compares each mirror to its source on every run, so a page
here cannot quietly disagree with the README. Two parts of the README are
checked against a real binary as well — the command-line listing is compared
with the built binary's own help output, and the assertion example is executed
and matched against its documented outcome.
