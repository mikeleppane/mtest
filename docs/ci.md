# Continuous integration

mtest is built for a machine to read: deterministic ordering, a failure and a
crash that stay distinct all the way to the exit code, and report formats a CI
system already understands. Wiring it into a hosted pipeline is one job.

## The workflow

Add the package to the workspace, commit the manifest and lock file that
produces, then paste this. It installs the locked environment, runs the suite
with inline annotations and a JUnit report, and keeps the report as an artifact
even when the run fails:

```yaml
name: Tests

on: [push, pull_request]

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - uses: prefix-dev/setup-pixi@a09b6247153796b190642a2b53fac4241043cf6f # v0.10.0
        with:
          locked: true

      - run: >-
          pixi run mtest tests
          --gh-annotations auto
          --junit-xml build/test-results.xml

      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        if: always()
        with:
          name: test-results
          path: build/test-results.xml
```

Annotations are requested in the mode that emits them on GitHub Actions and
does nothing anywhere else, so the same invocation is the one to run locally.
GitHub allows ten error and ten warning annotations per step, so a run with
more failures than that renders the first nine of each and one
`... and N more errors` line in place of the rest; the summary, the JUnit
report, and the exit code still count every failure. The report is written
whether or not tests failed, which is why the upload step is unconditional.

Each action above is pinned to a commit rather than to a tag, the same way this
repository pins its own workflows, and yours should be too: a tag can be moved
onto different code, a commit cannot.

`mtest init --ci github` writes exactly this file to
`.github/workflows/test.yml`, so there is nothing to paste in a project that
starts that way. It is the same bytes rather than a copy of them: a gate
extracts the block above and compares it against what the runner emits, which
is what keeps this page the one place the workflow is written down.

## Spreading one suite across a matrix

Give each cell a shard and a distinct report name, in the `hash:M/N` syntax
defined under
[Sharding a CI matrix](https://github.com/mikeleppane/mtest#sharding-a-ci-matrix).
The union of every shard's selection is exactly the unsharded selection, and no
test runs twice:

```yaml
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      # ... checkout and setup-pixi as above ...
      - run: >-
          pixi run mtest tests
          --shard "hash:${{ matrix.shard }}/4"
          --gh-annotations auto
          --junit-xml "build/test-results-${{ matrix.shard }}.xml"

      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        if: always()
        with:
          name: test-results-${{ matrix.shard }}
          path: build/test-results-${{ matrix.shard }}.xml
```

## Running it as an action

The same run is available as a composite action, if you would rather not repeat
the invocation. It runs mtest and nothing else: the workflow above still
installs the locked environment, and the action replaces only the step that
invokes the runner.

```yaml
      - uses: mikeleppane/mtest@v1
        with:
          paths: tests
          args: --gh-annotations auto --junit-xml build/test-results.xml
```

The second input is appended to the command verbatim, so every flag the runner
accepts stays reachable without the action growing an input of its own. Both
inputs reach the runner through the environment and are split on whitespace, so
a value containing a space cannot be held together by quoting it here. The
major-version tag floats onto each 1.x release; reference a commit instead if
you would rather adopt each release deliberately.

## One thing not to do

Do not restore the build cache between hosted runners. The failure it produces
is a valid cache hit that dies the moment it executes, and the reasoning is
specific enough to be worth reading in full rather than paraphrased here: it is
in the
[Run it in CI section of the README](https://github.com/mikeleppane/mtest#run-it-in-ci).
Cache the package downloads instead.
