# Contributing to mtest

Report vulnerabilities privately as [SECURITY.md](SECURITY.md) describes.
Maintainers use [docs/releasing.md](docs/releasing.md) for the GitHub and
modular-community publication procedure, and [CHANGELOG.md](CHANGELOG.md)
records release-to-release changes.

## Set up

Install [Pixi](https://pixi.sh), clone the repository, and install the locked
environment:

```console
$ pixi install --locked
$ pixi run mojo-version
```

The project is pinned to Mojo `1.1.0`. The toolchain and all tasks are pinned
in [pixi.toml](pixi.toml); re-pinning on a Modular release regenerates the
protocol transcripts. Python tooling also needs
[`uv`](https://docs.astral.sh/uv/) on `PATH`; `pixi run py-check` fails instead
of skipping when `uvx` is unavailable.

Build the runnable binary at `build/mtest`:

```console
$ pixi run build-bin
```

To build and verify the conda package locally, without touching a public
channel:

```console
$ pixi run package-build   # rattler-build -> build/conda-channel/*.conda
$ pixi run package-check   # verify: install into a scratch env, run the binary
```

`package-check` installs the exact artifact `package-build` just produced into
a fresh scratch environment — never your own — and runs it, including a
known-failing fixture, so the built package is proven to report failures
truthfully.

## Make and test a change

Format the languages you changed, then run the smallest tests that cover the
diff. Useful starting points:

```console
$ pixi run fmt
$ pixi run py-fmt
$ pixi run py-check
$ pixi run test-file -- tests/unit/test_session_pipeline.mojo
$ pixi run test
$ pixi run assertions-check
$ pixi run e2e
```

Run the affected product gate as well. Package changes need
`pixi run package-check`, command-line or reporting changes usually need
`pixi run e2e`, and a change to the documented CLI behavior in
`docs/cli-contract.md` needs `pixi run contract-check`. Stage the exact tree you
tested before recording a result: `fmt-check` reformats in place and then runs
`git diff --exit-code`, so it reds on any unstaged diff it leaves behind.

Required GitHub checks run the behavioral floor and the strict contract check on
both Linux and macOS arm64, plus packaged-artifact consumption on both. The
memory-safety lanes, ASan/LSan and Valgrind, run on Linux only.

## The tasks

| Task | What it does |
|------|--------------|
| `pixi run fmt` | format Mojo plus every tracked native C source and header in place |
| `pixi run fmt-check` | run both formatters, then reject any resulting tree diff |
| `pixi run py-fmt` | apply ruff's safe lint fixes to the Python tooling, then format it in place |
| `pixi run py-check` | ruff format/lint and `mypy --strict` over the Python tooling (needs `uv`; not part of `ci`) |
| `pixi run clang-tidy-check` | run the focused pinned Clang parse-smoke and analyzer loop over every native C translation unit |
| `pixi run native-check` | own the native verdict: Clang-Tidy and post-fork analysis, ABI/layout/export checks, and lifecycle tests |
| `pixi run build` | precompile the vendored TOML parser and `src/mtest` to `build/toml.mojoc` and `build/mtest.mojoc`, the compile gate |
| `pixi run build-bin` | link the runnable binary at `build/mtest` |
| `pixi run build-profile-check` | verify the production binary and matching compiler IR against the release CPU, stripped-debug, and macOS deployment-target oracles |
| `pixi run test` | run every classified unit and integration module through `build/mtest` itself, then reconcile its report against an inventory derived from the sources on disk |
| `pixi run test-file -- PATH` | the same, focused on one module |
| `pixi run assertions-check` | compile and directly execute the source-only assertion consumers at `-O0` and `-O3` |
| `pixi run dogfood-check` | run three focused probes through the built `mtest` binary itself |
| `pixi run e2e` | drive `build/mtest` against the committed known-outcome tree under `e2e/` and assert exact exit codes and output structure |
| `pixi run transcripts-check` | regenerate the `TestSuite` protocol snapshots to a temp dir and diff byte-for-byte |
| `pixi run cache-protocol-check` | drive real `build/mtest` processes against throwaway projects and assert the build cache's protocol properties from outside |
| `pixi run build-stamp-check` | check the production build's precompile stamp against its inputs in a sandboxed copy of the tree |
| `pixi run ci` | the complete serial source, test, and memory floor: preflight checks, then `test`, `assertions-check`, `dogfood-check`, `e2e`, the two cache gates, the strict contract, and the memory lanes. Not a mirror of hosted CI — packaged-artifact consumption, CodeQL, and `py-check` all run there and not here |
| `pixi run asan-check` | Linux: build and run the highest-risk exec suites under ASan/LSan |
| `pixi run valgrind-check` | Linux: run the exec/native coverage under Memcheck |
| `pixi run ci-memory` | Linux: both memory lanes together, the way `ci` runs them |

`pixi run ci` is there for an explicit exhaustive local run; routine development
uses the focused tasks above, and the required hosted checks are the merge
verdict. The floor opens with a fail-fast preflight (version, formatting,
harness self-tests, repository policy, release tooling, unsafe-Mojo inventory,
post-fork and Clang-Tidy analysis, native ABI, JUnit oracle, build,
production-artifact profile, rendered-JUnit, transcript, ABI-probe, and
coverage-tripwire checks) and closes with `ci-memory`, so a
green local run covers memory safety instead of deferring it.
On Linux that is ASan/LSan then Memcheck; elsewhere it reports the two lanes as
uncovered and names the Linux cells that own them. Hosted CI runs the
behavioral floor (`test`, `assertions-check`, `e2e`) plus the two cache gates
and `contract-check-strict` as parallel cells on both Linux and macOS, runs the
static preflight, compiled oracles, and memory-safety cells on Linux, and
verifies the production artifact profile in the macOS preflight on every pull
request.

## How the tests work

- Everything executes real binaries. Both the classified suite and mtest
  itself build with `mojo build` and run the result directly; `mojo run`
  appears nowhere, because it masks crash exit codes.
- The protocol snapshots under `tests/snapshots/protocol/` pin `TestSuite`'s
  report format at the pinned toolchain. They are regenerated only by the
  committed generator, and only when the oracle side changes: a toolchain
  re-pin, or a deliberate fixture edit. A red
  `transcripts-check` after a repo change indicts the change, not the
  snapshots.
- The console images in the README and the documentation are generated from
  real runs by `scripts/maintenance/console_svg.py`; the text examples are
  captured from the same build they document.

## Pull requests

Keep each pull request focused. Use atomic Conventional Commits with a scope,
explain in the body why the change is needed, and include tests for observable
behavior. Keep Linux and macOS behavior aligned.

Ask before changing the Mojo pin, the command-line contract, any
dependency, a blocking gate, or committed TestSuite transcript fixtures.
Regenerate transcript snapshots only when their fixture or pinned toolchain
oracle changes.
