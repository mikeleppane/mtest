# Installation

mtest ships as a conda package built **from source** by
[rattler-build](https://prefix-dev.github.io/rattler-build/) from
[`recipe/recipe.yaml`](https://github.com/mikeleppane/mtest/blob/main/recipe/recipe.yaml),
inside an isolated build environment pinned to the same toolchain the
repository builds against (`mojo ==1.1.0`, `clang ==18.1.8`). The binary links
against the Mojo runtime, so the package declares `mojo-compiler ==1.1.0` as its
sole conda run dependency. The native TOML parser is compiled into the shipped
binary from the pinned vendored source.

mtest is published to
[modular-community](https://prefix.dev/channels/modular-community/packages/mtest)
for linux-64 and osx-arm64. From an empty directory:

```console
$ pixi init .
$ pixi workspace channel add https://conda.modular.com/max/
$ pixi workspace channel add https://repo.prefix.dev/modular-community
$ pixi add mtest
$ pixi run mtest --version
mtest 1.1.0
```

Skip the first command in a workspace that already exists. It is there because
every command after it edits a `pixi.toml`, and `pixi workspace channel add`
fails outright when there is none.

Three channels have to resolve, and they are the same three the release
verifier installs from: `https://conda.modular.com/max/` for the pinned
`mojo-compiler` run dependency, `https://repo.prefix.dev/modular-community`
for mtest itself, and `conda-forge` — which a Pixi workspace already carries
by default — for everything underneath. A workspace missing any one of them
fails to solve.

linux-64 and osx-arm64 are both gated: each has its own blocking CI job that
builds the package, installs the exact artifact it just built into a fresh
environment carrying only the declared run dependencies, and exercises the
installed binary. That includes running a known-failing fixture through it, so
the installed package is proven to report failures truthfully, not just
successes.

To run mtest straight from a checkout instead, see
[CONTRIBUTING.md](https://github.com/mikeleppane/mtest/blob/main/CONTRIBUTING.md).

## Supported toolchains

| mtest | Mojo | Platforms | Status |
|-------|------|-----------|--------|
| `main` | `1.1.0` | linux-64, osx-arm64 | Supported |
| 1.1.x | `1.0.0b2` | linux-64, osx-arm64 | Released |

**Supported** means this repository builds, gates, and publishes that
combination: the pinned toolchain is what the protocol snapshots were captured
against, what both blocking packaged-artifact jobs install, and what the conda
package declares as its run dependency. A **Released** row records the
toolchain a published release was built against. There is no compatibility
range, and that is a deliberate design position rather than an unfinished one. mtest links
the Mojo runtime and parses the exact report `TestSuite` prints, so a build
serves one toolchain; accepting a report the runner does not fully understand
is how a runner produces a false green, and this one exits 3 on protocol drift
instead.

A weekday canary probes toolchains newer than the pin and records what would
break on each; [Toolchain compatibility](compatibility.md) describes what it
covers and what its results do and do not say about support.
