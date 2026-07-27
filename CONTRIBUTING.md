# Contributing to mtest

## Set up

Install [Pixi](https://pixi.sh), clone the repository, and install the locked
environment:

```console
$ pixi install --locked
$ pixi run mojo-version
```

The project is pinned to Mojo `1.0.0b2`. Python tooling also needs
[`uv`](https://docs.astral.sh/uv/) on `PATH`; `pixi run py-check` fails instead
of skipping when `uvx` is unavailable.

## Make and test a change

Format the languages you changed, then run the smallest tests that cover the
diff. Useful starting points are:

```console
$ pixi run fmt
$ pixi run py-fmt
$ pixi run py-check
$ pixi run test-file -- tests/unit/TEST_FILE.mojo
$ pixi run assertions-check
$ pixi run e2e
```

Run the affected product gate as well. For example, package changes need
`pixi run package-check`, while command-line or reporting changes usually need
`pixi run e2e`. Stage the exact tree you tested before recording a result.
Required GitHub checks run the complete Linux and macOS floor, including the
memory-safety lanes.

## Pull requests

Keep each pull request focused. Use atomic Conventional Commits with a scope,
explain why the change is needed, and include tests for observable behavior.
Keep Linux and macOS behavior aligned.

Ask before changing the Mojo pin, the frozen command-line contract, any
dependency, a blocking gate, or committed TestSuite transcript fixtures.
Regenerate transcript snapshots only when their fixture or pinned toolchain
oracle changes.
