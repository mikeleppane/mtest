# mtest

mtest is a test runner for Mojo. It finds every test file under a directory,
builds each one, executes the resulting binary under supervision, and
aggregates what they report into a single verdict a continuous-integration
system can act on. The standard library's per-file suite keeps owning discovery
and the report format inside each file; mtest owns everything between files.

## Install

The package is published to the modular-community channel, built from source
for linux-64 and osx-arm64. In a Pixi workspace:

```console
$ pixi workspace channel add https://conda.modular.com/max/
$ pixi workspace channel add https://repo.prefix.dev/modular-community
$ pixi add mtest
$ pixi run mtest --version
mtest 1.0.0
```

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
- [Command-line contract](cli-contract.md) — the frozen specification of every
  subcommand, flag, exit code, and stream.
- [JSON event stream](json-stream.md) — the machine-readable stream, event by
  event.
- [Releasing](releasing.md) — the maintainer runbook.

Everything else stays in the
[README](https://github.com/mikeleppane/mtest#readme): selection, retries,
timeouts, sharding, the build cache, assertion diagnostics, and the complete
command-line listing. That document is the front door on purpose — every
command and output in it is executed against the built binary before it is
committed, and the few this site needs are mirrored from it byte for byte
rather than retyped.
