# mtest agent guide

This file is the source of truth for working in this repo: scope, gates, pins,
and conventions. The skills under `.agents/skills/` go deeper on specific
activities, and the global `mojo-syntax` skill is the authority on Mojo syntax.
When a skill and this file disagree, this file wins. When this file and a direct
instruction from the human disagree, the human wins.

## Scope and non-goals

mtest is a pytest-like test runner for Mojo that orchestrates the standard
library's per-file `std.testing.TestSuite` and never replaces it. TestSuite owns
discovery, per-test selection, and the report format inside a single file. mtest
owns everything between files: recursive discovery, building each file,
executing and supervising it as a subprocess, aggregating results, and reporting
for CI.

It is not a property-testing framework. The optional source-only
`mtest.assertions` companion improves failure detail; it still raises ordinary
errors inside TestSuite and owns no discovery, report framing, or runner
outcome.

Zero runtime dependencies. `src/` and `companions/assertions/src/` are pure
Mojo, the exec-private POSIX adapter under `native/` is statically linked at
build time, and Python appears only in build-time tooling under `scripts/` and
test-only subprocess actors under `tests/fixtures/exec/`.

## Product principles

- Every test file is built and its binary executed directly, because that is
  the only way Mojo reports a truthful exit code. `mojo run` masks every
  outcome to `1` and is banned from the gate.
- FAIL and CRASH are different outcomes and stay distinct in the summary, the
  JUnit XML, the annotations, and the exit code.
- Report every exclusion, retry, and timeout visibly. A run that skipped
  something must never look like a run that passed everything.
- CI consumes the output, so machine-readable reports, deterministic ordering,
  and a hermetic build come first.
- Toolchain flakiness is expected. Plan for it with build-not-run, cache
  quarantine, and crash-class retries.
- The README is the front door. Two parts of it are executed against the built
  binary: the command-line listing (`readme-help-check` versus `--help`) and
  the assertion example, run and matched against its documented outcome.
  Everything else — the install sequence, the captured transcripts, the
  workflows to paste — is reviewed rather than executed, so write it as
  something a reader can follow and verify it by following it. State limits as
  plain facts, never as roadmap, progress, or planning narrative, and never
  let something the build cannot do appear as if it can. The architecture
  section carries a mermaid layering diagram; the feature and limitation
  bullets lead with a bolded label for scanning (README-local formatting).

## Layering: imports go one direction

Every layer may import only from layers above it in this list, never sideways
or downward:

```text
Layer 0  model     outcomes, node ids, events, exit-code resolution
Layer 0  platform  the narrow platform-I/O boundary
Layer 1  config    RunnerConfig
Layer 2  discover | protocol (report/collect parsing) | report
         select (operand and name selection) | cache (build reuse)
Layer 3  exec      the POSIX process adapter, timeouts
Layer 4  session   orchestration: discover -> build -> run -> parse -> events
Layer 5  cli       hand-rolled argument parsing -> RunnerConfig
```

`main` sits above every layer as the composition root, not inside `cli`: the
only `exit()` caller, wiring reporters and session together, owning argv, env,
and exit and nothing else. `exec` is the deepest module, a narrow
process-control interface hiding pipes, concurrent draining, FFI, platform
differences, and cleanup invariants.

`scripts/checks/layering.py` enforces all of this: the rank order, the Layer 2
siblings, deep imports that go around a facade export, and the `exit()` and
`external_call` confinements. Every directory under `src/mtest` carrying an
`__init__.mojo` is a facade — subpackages included, so `session/store/` has
its own enforced surface. An import is judged by the name it imports, not the
alias it binds locally, so `from std.sys import exit as terminate` cannot
launder a call past the rule. Docstrings and comments are stripped before
matching.

Three named seams:

- Reporter composition is comptime. The plugin seam is a closed, typed event
  set plus a `Reporter` trait consumed by a comptime-known reporter tuple
  rather than a runtime trait-object list, because 1.0.0b2 polymorphism is
  static.
- `ReportCoordinator` is how `session` and `main` reach the report layer.
  Reporter-specific lifecycle interactions (machine stream health, JUnit
  `[not-run]` synthesis and finalize, the annotation tail, the console's
  rendered output and fence token) are named methods on the coordinator, never
  a concrete reporter type or a tuple position. Two conformers exist,
  `StandardReportCoordinator` for production and `RecordingCoordinator` for
  test drivers, so adding a reporter stays a local change inside a coordinator.
- The run-file pipeline kernel (`RunPipeline`,
  `src/mtest/session/pipeline.mojo`) holds each run file's stage between
  discovery and verdict, the stale-name recover-once budget, the `--retries`
  ceiling, and the `-x`/`--maxfail` stop policy, and answers one question:
  which step does the run want next. It spawns nothing, emits no event, and
  owns no captured bytes.

Only the sequential driver executes what the kernel's `next_step` decides:
`session/selection.mojo` services one step at a time through `run_supervised`,
and it is the one that takes the node-id and `-k` path. `session/pool.mojo`,
the parallel scheduler behind `-n`/`--workers`, never calls `next_step` — it
drives its own build/run phase machine, running up to `workers` children at
once under a single `Supervisor` over native ABI v2, and reaches into the
kernel only for `admit_crash_retry`, `record_verdict`, `record_settled`, and
the halt states; `--serial` pins its matching files to a final one-at-a-time
pass after the parallel batch drains. A scheduling feature meant for both
drivers belongs in those kernel policy methods, never in `next_step`.
Concurrency is only ever across files: one file's steps stay strictly ordered,
and `-n 1` is byte-identical to the sequential path (one child per step, no
`--num-threads` on the build argv). Admission, retry, maxfail, serial, and
accounting policy stay in the kernel and `session`, never in `exec` or
`native`. No stage, step kind, or halt reason exists for a future phase: every
one is driven today and pinned by `tests/unit/test_session_pipeline.mojo`.

## Mojo, not Python

`src/` is pure Mojo. Selected project configuration is parsed by the pinned,
vendored native `mojo-toml` parser. All platform and foreign-ABI knowledge lives
in exactly two audited boundaries, and no layer above `exec` carries a raw
platform call:

- `src/mtest/platform` (Layer 0): the small per-call libc operations a Mojo
  caller needs directly, each an in-Mojo `external_call` with its own local
  `# SAFETY:` proof, or a delegation to a safe stdlib wrapper where one
  expresses the exact semantics. Where the stdlib can express an operation, the
  safe call wins and no foreign declaration is written.
- `native/` and the `mtest_exec_*` ABI: a private C17 POSIX adapter for the
  machinery that must be async-signal-safe after fork (fork/exec, pipe
  supervision, signal handling), statically linked. It carries no product
  policy, reporting, parsing, or orchestration. `exec` is its sole consumer;
  those `mtest_exec_*` calls, plus the residual test-only `kill(2)` in the exec
  signal helper, are the only raw foreign declarations that legitimately live
  in `exec`.

A new foreign call belongs in `platform`, unless it is native-adapter
machinery, in which case it belongs in `native/` behind the ABI. Python lives
only under `scripts/` and `tests/fixtures/exec/`. Follow the global
`mojo-syntax` skill for all syntax, because training data is stale. Docstrings
are Google-style, triple-quoted, and mandatory on public entities.

## Unsafe Mojo requires a local proof

Every operation that bypasses Mojo's lifetime, initialization, bounds, type, or
ABI checks carries an adjacent `# SAFETY:` comment immediately before the
smallest operation or contiguous block it justifies, never a distant
function-level assurance. The
argument is concrete and falsifiable, covering pointer provenance and ownership
(who frees), lifetime and non-escape across every borrow or syscall, bounds and
complete initialization before reads, alignment, layout, valid bit patterns,
platform assumptions, the exact foreign ABI and pointer retention,
signal-handler and post-fork restrictions, concurrency, and cleanup on the
success, error, timeout, and partial-initialization paths. Prefer deleting an
unsafe operation when a safe stdlib operation exists. `pixi run safety-check`
enforces comment presence; a green checker is not proof the code is sound.

## The transcript lifecycle

The committed snapshots under `tests/snapshots/protocol/` pin TestSuite's
per-file protocol at the pinned toolchain. `scripts/gen_transcripts.py` is the
only thing that writes them.

- A red `transcripts-check` after a repo change indicts the change, not the
  snapshots. Regenerating is legitimate only when the oracle side visibly
  changed: a mojo pin bump or a deliberate fixture/matrix edit. "The new output
  looks close enough" is never evidence. On a toolchain re-pin, regenerate
  first and read the diff as the protocol changelog.
- Transcripts are regenerated only by the script, never by hand. A byte that
  cannot be traced to a fixture, a scenario, and the pinned toolchain version
  in the header does not get committed. `mojo format` on a fixture legitimately
  shifts `At <path>:<line>:<col>` coordinates; that is an oracle-side change,
  so regenerate.
- On a red gate, suspect in order: generator nondeterminism, a
  resolved-toolchain mismatch versus the header, byte mangling from a missing
  `.gitattributes` entry.
- The normalizer is anchored and minimal, and each rule names the exact lines
  it may touch. Over-normalization hides real protocol changes and is as
  serious a defect as nondeterminism.

## Hermetic by construction

The source, test, and memory-analysis lanes touch the network once for the
locked `pixi install`; everything after is offline, with one exception. The
Linux Valgrind cell may install glibc debug symbols that MATCH the libc6 it
runs against, logging apt provenance and failing on any mismatch. It prefers
the runner's preinstalled `libc6` revision and installs only `libc6-dbg` at
that version; when the archive has already dropped that revision it moves
`libc6` and `libc6-dbg` together to the archive's current one, because the
property Memcheck needs is that the symbols match, not that libc6 is frozen.
No other package is ever named. Widening this to anything but those two
packages is an Ask-first decision.

The package-consumption jobs, one per gated platform, have their own approved
network contract: rattler-build solves against the pinned Modular and
conda-forge channels, and nothing uploads or authenticates. Do not describe
those jobs as hermetic or fold them into the Valgrind exception.

**Do not restore the build-artifact store across hosted runs.** Tried and
reverted: `KeyBuilder` frames everything about a build except the host CPU,
and restored e2e binaries died with SIGILL on runners with a narrower
instruction set. Anything that moves a compiled artifact between machines has
to frame the machine — and no digest re-check can notice that a byte-perfect
binary is illegal on this host. Full incident: `.agents/lessons.md`
("Harness and workflow").

## Toolchain and verification

`pixi.toml` is the task inventory — read it (or `pixi task list`) rather than
any list here. The gates whose semantics you must know before invoking them:

- `fmt` / `fmt-check`: both formatters rewrite the tree in place; `fmt-check`
  then ends in `git diff --exit-code`, so any remaining diff — including an
  unstaged edit made while a long check ran — reds the gate. Stage the exact
  bytes first, then gate: a result produced against different bytes than you
  commit is not a result, and a background wrapper's exit status is the
  wrapper's, not the gate's — read the gate's own marker.
- `test`: the classified inventory, self-hosted through `build/mtest` itself
  (`scripts/harness/selfhost.py`); `test-file -- <path>` focuses one module.
- `transcripts-check`: regenerates every protocol snapshot to a temp dir and
  diffs byte-for-byte; `transcripts` is the only legitimate writer.
- `contract-check`: local rebuild-if-stale QA against `docs/cli-contract.md`;
  `contract-check-strict` is the blocking gate form (`--strict --no-rebuild`,
  failing closed on a stale or missing binary).
- `safety-check`: inventories every unsafe Mojo operation and its `# SAFETY:`
  proof — presence only; a green checker is not proof an argument is sound.
- `py-check`: ruff and mypy `--strict` over `scripts/` and
  `tests/fixtures/exec/`, at versions pinned in
  `scripts/checks/python_quality.py`, run through `uvx`. It needs `uv` on PATH
  and fails loudly without it, which is why it stays out of `pixi run ci`; the
  hosted `Python quality` job installs a pinned `uv` itself and blocks.
  (`pyproject.toml` holds config only — this repo is not a Python package.)
- `ci-memory`: on linux-64, ASan/LSan then Valgrind Memcheck (about 90 seconds
  plus 3 minutes warm). On any other host it reports the two uncovered lanes
  and exits 0 — both lanes are pinned against the Linux toolchain — and fails
  closed if reached on Linux, since that means the target override was
  deleted.
- `ci-preflight` is the fail-fast static barrier and `ci` the complete serial
  floor; their exact memberships live in `pixi.toml` — read them there.

### Local agentic development loop

Do not run the complete serial floor before every local commit. It is too slow
for iterative agentic work and duplicates the required hosted checks.

Before a local commit:

1. Run `pixi run fmt` for Mojo changes, and `pixi run py-fmt` plus
   `pixi run py-check` for Python changes.
2. Run the smallest checker and focused test modules that directly cover the
   diff. A product-facing change also runs its affected product gate:
   `assertions-check`, `dogfood-check`, `e2e`, `contract-check`,
   `package-check`, or a memory checker as applicable.
3. Stage the exact bytes, run the selected gates against that staged state, and
   record each gate's own exit status.

`pixi run ci` is the complete serial source, test, and memory floor, for an
explicit release rehearsal, a hosted failure reproduction, or a human-requested
exhaustive run. It is not a routine per-commit requirement, and it is **not** a
mirror of hosted CI: it omits packaged-artifact consumption (`package-check`),
CodeQL, and Python quality (`py-check`). A green `pixi run ci` therefore says
nothing about whether the built package installs and runs in a clean
environment, about the CodeQL findings, or about ruff and mypy — all three of
which hosted CI does block on. The required GitHub checks are the
authoritative exhaustive merge verdict.

### Hosted CI

Hosted CI never invokes `pixi run ci`. Each lane is its own matrix cell, and
`pixi.toml` plus `.github/workflows/ci.yml` are the only sources of truth for
that topology: a tampered task graph or matrix row is visible in the PR diff.
`scripts/checks/workflow_security.py` pins the properties a diff cannot show:
every external action resolves to a reviewed commit SHA, the sensitive
workflows keep their reviewed permissions and forbid `continue-on-error:`, and
the composite action this repository publishes runs exactly the reviewed
invocation — the one file here that executes inside someone else's job under
someone else's token.

The topology in brief — read `ci.yml` for the detail:

- Linux: a static, nothing-compiles preflight releases the behavioral matrix
  and, beside it, a `compiled oracles` job carrying every preflight member
  that needs a real compiler. macOS: preflight runs the native audit and
  `build-profile-check` before releasing its matrix. Both matrices run
  `fail-fast: false`, so one red lane never cancels the others' verdicts.
- There is no self-hosted dogfood cell. `scripts/harness/dogfood.py` survives
  as a local task and as the helper `package-check` reuses against the
  installed artifact on both platforms — that is where those probes block
  from.
- Transcripts and ASan/Valgrind stay Linux-only. Packaged-artifact consumption
  blocks on both platforms. The cache-protocol and build-stamp cells run on
  both platforms because both spawn real processes and read the filesystem
  directly.
- `native-check` depends on `postfork-check`, so the native gate alone cannot
  skip the child call-graph audit.

**Running is not the same as blocking.** Which contexts block a merge is
configured in repository settings, not in this repo, and the two lists have
drifted apart before. Adding, renaming, or splitting a lane must update the
required-context list in the same change; a workflow edit alone silently
produces a lane nobody is required to pass, and nothing in this repository can
detect that. A job's display name is its status-check context, so every
required name must stay byte-stable: renaming one does not red the lane, it
removes the lane from the required set and leaves a permanently pending
context. The 20 required contexts are eight names carried on both `Linux /`
and `macOS arm64 /` — `preflight`, `classified suite`, `assertions`,
`end-to-end tests`, `strict contract`, `cache protocol`, `build stamp`,
`packaged artifact` — plus the three Linux-only jobs
`Linux / compiled oracles`, `Linux / ASan + LSan`, and
`Linux / Valgrind Memcheck`, plus the unprefixed `Python quality`.

The two CodeQL jobs (`C and C++`, `Python`) are deliberately not status-check
contexts. Merge protection for them comes from the ruleset's `code_scanning`
rule instead, which blocks on a CodeQL alert at high-or-higher security
severity or an error-level quality alert; a green CodeQL job proves only that
analysis uploaded. The sanitizer negative controls under `MTEST_EXEC_TESTING`
are dismissed there as used-in-tests, on the standing evidence that
`TEST_ONLY_SYMBOLS` in `scripts/checks/native_abi.py` proves them absent from
the production object.

Two lanes sit outside the platform matrices, neither among the required
contexts. `.github/workflows/docs.yml` builds the documentation site on every
pull request and deploys to Pages only from a push to main; it is the only
workflow ever granted `pages: write` and `id-token: write`, and the only place
the site is ever built (`docs-build` runs mkdocs through `uv`, which pixi does
not pin — the job that supplies the tool is the job that may run the task).
`.github/workflows/compat-canary.yml` is the only lane that runs a compiler
this repository does not pin: on weekday nights it relaxes the Mojo pin in a
throwaway checkout and classifies what broke. Its two jobs are split by
credential — the job executing the downloaded compiler holds no write scope;
the job holding `issues: write` runs neither pixi nor Mojo — and
`scripts/checks/workflow_security.py` pins that split.

### Cross-compiling before commit

The local floor compiles for the host target only, so it is blind to a
macOS-only compile failure: a `comptime` branch, `external_call` signature, or
struct-layout offset that is wrong for Darwin passes every Linux gate and reds
the hosted macOS preflight instead, before any test runs. Cross-compile before
committing a change to `CompilationTarget` branching, `external_call`, or a
hand-computed struct offset:

```text
mojo build --target-triple arm64-apple-macosx14.0.0 --emit=asm \
  -I src -I vendor/mojo-toml src/main.mojo -o /dev/null
```

That frontend-compiles every Darwin `comptime` branch in about four seconds, and
`--emit=asm` stops before linking, so no Darwin SDK and no native object are
needed. The reverse direction, `x86_64-unknown-linux-gnu` from a macOS checkout,
holds equally. This is a local pre-commit check, not a gate: `ci-preflight`
omits it because the hosted macOS lane compiles natively and owns that verdict.

### Classified test modules

Classified modules under `tests/unit/` and `tests/integration/` each compile
and run as their own program: they declare `test_*` functions **and must**
declare their own `main()` handing them to `TestSuite.discover_tests`, exactly
like every other test file in this repo. This is a packaging constraint, not a
style choice: `mojo precompile` over a tree containing a `main()` fails with
`'main()' is not supported within packages` — which is why
`tests/unit/__init__.mojo` and `tests/integration/__init__.mojo` do not exist
(package markers would make the directory precompilable) while
`tests/__init__.mojo` does, and why `scripts/checks/layout.py` guards it.
`pixi run test` runs every classified module **through the `build/mtest`
binary itself** (`scripts/harness/selfhost.py`), under a whole-process-group
watchdog, reconciling mtest's own report against an inventory derived from the
sources on disk. Use `pixi run test-file -- <classified-test.mojo>` while
investigating a failure.

Membership is derived, not declared: there is no committed path list or test
count to update. The trade this makes explicit: the oracle proves mtest ran
every test the sources declare *right now*; it cannot prove the sources still
declare every test they used to. A file dropping from N tests to M (M > 0) is
invisible to every gate — a reviewable diff, not a runner defect. A file
reaching **zero** `test_*` functions is loud and fails closed. See
`scripts/harness/selfhost.py`'s module docstring for the full reasoning.

**An executable-topology change audits every harness consumer.** A change to
whether classified modules own `main()`, how mtest discovers them, or which
inventory a lane runs must cover `test`, `test-file`, ASan, Valgrind, dogfood,
self-host, and package consumption — each classified module is a complete,
directly buildable program in every one of those lanes, and a green primary
test gate does not prove the specialized consumers use the same module
contract. Add a harness regression that inspects each affected build command.

## Pin policy and ask-first boundaries

Every pin below exists for a recorded reason. Do not move one to make something
pass.

- Mojo `==1.0.0b2`. CI must match local; a bump can silently change valid
  syntax and the pinned protocol. After a bump, regenerate the transcripts and
  re-audit syntax against `mojo-syntax`.
- Zero runtime dependencies. The `prism` argument-parsing library was evaluated
  and rejected on source evidence (no `--` pass-through; repeated flags corrupt
  values with spaces), and wrapping it was rejected too. Revisit trigger: prism
  ships native post-`--` pass-through. Until then the parser is hand-rolled.
- A vendored dependency records three digests: the authorized upstream release,
  upstream `main` at adoption, and every retained file after the local patches,
  recomputed by the harness. Only the third tells you whether the bytes you
  compile are the bytes you reviewed, and it goes stale the moment you touch
  the vendored source again. Enumerate every local change in the vendor README
  in the same commit.

Ask first before: bumping the Mojo pin; changing the CLI contract after it
freezes; adding any dependency (or reaching for Python where native Mojo would
do); weakening a gate (a tolerance, a skip, a delete) to reach green; changing
the committed transcript/fixture format.

After any non-trivial edit, summarize what changed, what was intentionally not
touched, and any concerns — and always call out an Ask-first boundary you
crossed.

## The standing per-phase quality gate

Every phase repeats the same external review loop at both checkpoints, the plan
before execution and the full diff before merge: Claude Opus 4.8 and Codex
GPT-5.6-sol, both at xhigh reasoning (Codex in a danger-full-access sandbox),
briefed to attack the work rather than admire it, with concrete failure
scenarios per finding, severity-ranked, and silence meaning no finding. Every
finding is triaged fixed or rejected-with-reason in that phase's notes.

## Commits

Conventional Commits with a required scope, atomic, imperative subject <=72
chars, a body explaining why. Types: `feat`, `fix`, `refactor`, `perf`, `docs`,
`test`, `bench`, `build`, `ci`, `chore`. Merge commits are exempt.
`skills` is a scope, not a type: a docs edit to a skill is `docs(skills): …`,
never `skills(...): …`.

A commit that regenerates any transcript names the oracle-side reason in its
body — a pin bump, a deliberate fixture or matrix edit. "Regenerated
transcripts" with no reason reads as hand-fixing a failing gate.

No AI or assistant attribution anywhere: no `Co-Authored-By` for an AI, no
"Generated with" line, no robot emoji, in any commit, merge commit, or note.

No internal-plan references: the working plans under `docs/plans/` are
gitignored and unpublished, so a decision label, a handoff section name, or any
planning vocabulary must never appear in a committed file. State the reason
itself.

Scope vocabulary (authoritative; keep in sync as modules emerge):

| Scope | Area |
| ----- | ---- |
| `scaffold` | repo skeleton, license/readme/gitignore/gitattributes |
| `pixi` | `pixi.toml`, `pixi.lock`, tasks, the environment |
| `fixtures` | `tests/fixtures/`: protocol probes and subprocess actors |
| `transcripts` | protocol snapshots plus `scripts/gen_transcripts.py` and `scripts/checks/{protocol_snapshots,transcript_compare}.py` |
| `spec` | `docs/cli-contract.md` |
| `agents` | `AGENTS.md`, `.agents/lessons.md` |
| `readme` | `README.md` |
| `model` | `src/mtest/model` (outcomes, node ids, events, exit codes) |
| `platform` | `src/mtest/platform` (the narrow platform-I/O boundary) |
| `config` | `src/mtest/config` (RunnerConfig) |
| `discover` | `src/mtest/discover` (file walking) |
| `protocol` | `src/mtest/protocol` (report/collect parsing) |
| `select` | `src/mtest/select` (operand and name selection) |
| `exec` | `src/mtest/exec` (the POSIX process adapter) |
| `session` | `src/mtest/session` (orchestration) |
| `report` | `src/mtest/report` (event consumers, reporters) |
| `assertions` | source-only companion under `companions/assertions/src/mtest/assertions` |
| `cli` | `src/mtest/cli` (arg parsing, main) |
| `cache` | in-session build/collection reuse |
| `checks` | `scripts/checks/` policy gates |
| `formats` | `scripts/formats/` report-format library and the outcome vocabulary |
| `test` | test infrastructure (`scripts/harness/{selfhost,dogfood}.py`, `scripts/build/mojo_package.sh`, shared helpers) |
| `e2e` | end-to-end harness (`scripts/e2e/`) and its `e2e/` manifest and scenarios |
| `qa` | the contract gate (`scripts/qa/`) and its own tests |
| `canary` | the toolchain compatibility canary (`scripts/canary/`), its fixtures and tests, and the canary workflow |
| `bench` | `benchmarks/` |
| `docs` | docstrings, `docs/` |
| `build` | packaging |
| `release` | release and publication tooling: `scripts/release/`, the version and shipped-claim gates, and the workflows that drive them |
| `ci` | `.github/workflows/` |
| `skills` | `.agents/skills/` |

## Lessons

Failure modes this project has already hit are collected in
[`.agents/lessons.md`](.agents/lessons.md), grouped by toolchain and protocol,
process supervision, parsing and verdict discipline, pinned-toolchain Mojo
language, and harness and workflow. Read the matching section before touching
that area, and append new entries there.

The six that come up most often:

- `mojo run` masks crash exit codes to `1`. Build, then execute the binary.
- `fmt-check` reformats Mojo and tracked native C/headers in place and ends in
  `git diff --exit-code`, so any unstaged diff it leaves behind reds the gate.
  Stage first, then gate.
- Never run two builds against the shared `build/` tree at once; a racing
  build corrupts `build/mtest.mojoc` and reads as a real regression.
- `fn` is fully removed from the pinned toolchain, including as a
  function-value type. Write `def(...) -> ...`.
- Every kill targets the process group, never the direct child alone.
- `native/*.c` stays strictly ASCII, comments included.

## Skills index

The skills under `.agents/skills/` are reference documents reached from here.
Read the matching one **before** the work it names:

- Writing, modifying, refactoring, or reviewing any Mojo in this repo →
  [`mojo-coding-guidance`](.agents/skills/mojo-coding-guidance/SKILL.md): the
  coding contract — exit-code fidelity, supervision invariants, error shapes,
  docstrings, the rent test.
- Writing or changing any test, or choosing how to prove a behavior →
  [`mtest-testing-patterns`](.agents/skills/mtest-testing-patterns/SKILL.md):
  which oracle each layer tests against, the four repo test patterns, and the
  exactness policy.
- About to merge, or asked to review a diff →
  [`code-review-and-quality`](.agents/skills/code-review-and-quality/SKILL.md):
  the repo-signature review axes (transcript fidelity, exit-code honesty) and
  the severity table.
- QA, acceptance, or release validation against `docs/cli-contract.md` →
  [`validating-mtest`](.agents/skills/validating-mtest/SKILL.md):
  contract-as-oracle checks, poison probes, harness traps, clean-room Docker.
- All Mojo syntax → the global `mojo-syntax` skill; training data is stale.
