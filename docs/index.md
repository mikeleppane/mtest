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
mtest 1.1.0
```

[Installation](install.md) explains each step, names the three channels that
have to resolve, and states which toolchain and which platforms each release
supports.

## Where to go next

- [Installation](install.md) — the package, the channels it resolves from, and
  the supported toolchains.
- [Getting started](getting-started.md) — from an empty directory to a green
  run, and what a file that does not compile looks like when it is reported
  honestly.
- [Overview](overview.md) — why mtest exists, what it does, its limitations,
  and what it deliberately does not do.
- [Usage](usage.md) — writing a test file, selection, listing, retries,
  timeouts, sharding, the machine reporters, `mtest.toml`, re-running
  failures, random order, `mtest doctor`, and `mtest debug`.
- [Continuous integration](ci.md) — the workflow to paste, and the sharded
  variant of it.
- [Run reports](reports.md) — the self-contained Markdown or HTML document
  `--report` writes for a reader, and what happens when it cannot be
  delivered.
- [Assertion diagnostics](assertions.md) — the optional source-only
  `assert_equal` that explains a mismatch in more detail.
- [Build cache](build-cache.md) — what is cached, what invalidates it, and when
  it turns itself off.
- [Shell completion](completions.md) — where each shell wants the script
  `mtest completions` prints, and what it completes once it is installed.
- [CLI reference](cli-reference.md) — the complete `--help` listing, every flag,
  and the exit codes.
- [Command-line contract](cli-contract.md) — the specification of every
  subcommand, flag, exit code, and stream.
- [JSON event stream](json-stream.md) — the machine-readable stream, event by
  event.
- [Collect JSON stream](collect-stream.md) — the machine-readable test listing
  `collect --format json` writes.
- [Architecture](architecture.md) — the layers mtest is built from, and why the
  event stream is its extension mechanism.
- [Toolchain compatibility](compatibility.md) — what the weekday canary probes
  on newer Mojo toolchains, and what each of its results does and does not say.
- [Releasing](releasing.md) — the maintainer runbook.

Three parts of these pages are checked against a real binary: the
command-line listing in the CLI reference is compared with the built binary's
own help output, the assertion example is executed and matched against its
documented outcome, and the workflow on the continuous-integration page is
compared with what `mtest init --ci github` writes. The install commands and
the first run on these pages are mirrored byte for byte from the
[README](https://github.com/mikeleppane/mtest#readme) rather than retyped: a
gate compares each mirror to its source on every run, so a page here cannot
quietly disagree with the README.
