# mtest agent guide

The source of truth for working in this repo: scope, gates, pins, and
conventions. The skills under `.agents/skills/` go deeper on specific
activities; the global `mojo-syntax` skill is the authority on Mojo syntax.
This file beats a skill; a direct instruction from the human beats this file.

## Scope

mtest is a pytest-like test runner for Mojo that orchestrates the standard
library's per-file `std.testing.TestSuite`. TestSuite owns discovery, per-test
selection, and the report format inside one file. mtest owns everything
between files: recursive discovery, building each file, supervising it as a
subprocess, aggregating results, and reporting for CI. It is not a
property-testing framework. The source-only `mtest.assertions` companion only
improves failure detail: it raises ordinary errors inside TestSuite and owns no
discovery, framing, or outcome.

Zero runtime dependencies. `src/` and `companions/assertions/src/` are pure
Mojo; the exec-private POSIX adapter under `native/` is statically linked;
Python lives only in build tooling under `scripts/` and test-only subprocess
actors under `tests/fixtures/exec/`.

## Product principles

- Every test file is built and its binary executed directly: that is the only
  way Mojo reports a truthful exit code. `mojo run` masks every outcome to `1`.
- FAIL and CRASH stay distinct in the summary, JUnit XML, annotations, and the
  exit code.
- Every exclusion, retry, and timeout is reported visibly. A run that skipped
  something never looks like one that passed everything.
- CI consumes the output: machine-readable reports, deterministic ordering, and
  a hermetic build come first.
- Toolchain flakiness is expected: build-not-run, cache quarantine, and
  crash-class retries absorb it.
- The README is the front door. `readme-help-check` executes its command-line
  listing against `--help` and `assertions-check` runs its assertion example;
  everything else is reviewed, so write it to be followed and verify it by
  following it. State limits as plain facts, never as roadmap. Keep its
  mermaid layering diagram and the bolded labels on feature/limitation bullets.

## Layering

Each layer imports only from layers above it, never sideways or downward:

```text
Layer 0  model     outcomes, node ids, events, exit-code resolution
Layer 0  platform  the narrow platform-I/O boundary
Layer 1  config    RunnerConfig
Layer 2  discover | protocol | report | select | cache
Layer 3  exec      the POSIX process adapter, timeouts
Layer 4  session   orchestration: discover -> build -> run -> parse -> events
Layer 5  cli       hand-rolled argument parsing -> RunnerConfig
```

`main` is the composition root above every layer and the only `exit()` caller.
Every directory under `src/mtest` with an `__init__.mojo` is a facade; import
through it. `scripts/checks/layering.py` enforces the rank order, facades, and
the `exit()`/`external_call` confinements.

Three seams carry the design:

- **Reporters** compose at comptime: a closed event set plus a `Reporter` trait
  over a comptime reporter tuple. `session` and `main` reach reporters only
  through `ReportCoordinator` methods (`StandardReportCoordinator` in
  production, `RecordingCoordinator` in tests), so adding a reporter stays
  local to a coordinator.
- **`RunPipeline`** (`session/pipeline.mojo`) owns each file's stage, the
  stale-name recover-once budget, `--retries`, and `-x`/`--maxfail`. It spawns
  nothing and emits nothing. The sequential driver (`session/selection.mojo`)
  executes its `next_step`; the pool (`session/pool.mojo`, `-n`) runs its own
  phase machine and uses only the kernel's policy methods. A scheduling rule for
  both drivers belongs in those policy methods. Concurrency is only across
  files, and `-n 1` is byte-identical to the sequential path.
- **The report stream**: a passing TestSuite prints its report to stdout; a
  failing one raises it as the uncaught-exception message on stderr.
  `session/classify.resolve_run_report` picks the stream from the exit status;
  every run, probe, and selection path goes through it.

## Foreign boundaries and unsafe code

All platform and foreign-ABI knowledge lives in two audited places; no layer
above `exec` makes a raw platform call:

- `src/mtest/platform` (Layer 0): per-call libc operations, each an
  `external_call` with its own `# SAFETY:` proof, or a safe stdlib wrapper
  where one exists. `FfiRecord` is the one way to hand C a struct or out-record:
  a zeroed, 8-byte-aligned, self-freeing buffer with bounds-checked typed
  fields. `c_string_bytes` is the one C-string conversion.
- `native/` and the `mtest_exec_*` ABI: a private C17 adapter for what must be
  async-signal-safe after fork (fork/exec, pipe supervision, signals). It holds
  no product policy. `exec` is its sole consumer; those calls plus the residual
  test-only `kill(2)` in the exec signal helper are the only foreign
  declarations in `exec`. `native/*.c` stays strictly ASCII.

Each `external_call` symbol has exactly one declaration shape per binary,
matching the stdlib's when the stdlib also calls it (`open` is variadic:
`num_fixed_args=2`).

Every operation that bypasses lifetime, initialization, bounds, type, or ABI
checks carries a `# SAFETY:` comment immediately before it: a concrete,
falsifiable argument covering provenance and ownership, lifetime across the
call, bounds and initialization, alignment, the exact foreign ABI and pointer
retention, post-fork restrictions, and cleanup on every path. Prefer a safe
stdlib operation (`List`, `Span`, `ArcPointer`) over a raw one.
`pixi run safety-check` enforces presence only.

## Transcripts

`tests/snapshots/protocol/` pins TestSuite's per-file protocol at the pinned
toolchain; `scripts/gen_transcripts.py` (`pixi run transcripts`) is the only
writer.

- A red `transcripts-check` after a repo change indicts the change. Regenerate
  only for an oracle-side change: a Mojo pin bump or a deliberate fixture or
  matrix edit (including `mojo format` moving `At <path>:<line>:<col>`). On a
  pin bump, regenerate first and read the diff as the protocol changelog.
- On a red gate, suspect in order: generator nondeterminism, a resolved
  toolchain differing from the header, byte mangling from a missing
  `.gitattributes` entry.
- The normalizer is anchored and minimal; each rule names the lines it may
  touch. Over-normalization hides real protocol changes.

## Hermetic builds

The source, test, and memory lanes touch the network once, for the locked
`pixi install`. The single exception: the Linux Valgrind cell may install
`libc6-dbg` matching the runner's `libc6` (moving both together only when the
archive dropped that revision), logging provenance and failing on a mismatch.
Naming any other package is Ask-first. The package-consumption jobs have their
own contract (rattler-build solves against the pinned channels; nothing uploads
or authenticates) and are not hermetic.

**Never move a compiled artifact between machines** (e.g. restoring the build
store across hosted runs): the cache key does not frame the host CPU, and a
restored binary died with SIGILL on a narrower runner. See `.agents/lessons.md`.

## Verification

`pixi.toml` is the task inventory and `.github/workflows/ci.yml` the CI
topology; read them rather than a list here. Gate semantics to know first:

- `fmt` rewrites Mojo and native sources in place; `fmt-check` ends in
  `git diff --exit-code`. Stage the exact bytes, then gate, and read the gate's
  own exit status.
- `test` self-hosts the classified suite through `build/mtest`;
  `test-file -- <path>` focuses one module.
- `transcripts-check` regenerates to a temp dir and diffs byte-for-byte.
- `contract-check` is local QA against `docs/cli-contract.md`;
  `contract-check-strict` is the blocking form.
- `py-check` (ruff, mypy `--strict`) needs `uv` on PATH, so it sits outside
  `pixi run ci`; hosted CI runs it.
- `ci-memory` runs ASan/LSan then Valgrind on linux-64 and reports the lanes
  uncovered elsewhere.
- One build at a time against `build/`: a racing build corrupts
  `build/mtest.mojoc` and reads as a regression.

Before a local commit:

1. `pixi run fmt` for Mojo or C; `pixi run py-fmt` and `pixi run py-check` for
   Python.
2. The smallest checker and focused test modules covering the diff, plus the
   affected product gate (`assertions-check`, `dogfood-check`, `e2e`,
   `contract-check`, `package-check`, or a memory checker).
3. Stage, run those gates against the staged state, record each exit status.

`pixi run ci` is the serial source/test/memory floor for release rehearsals or
reproducing a hosted failure, not a per-commit step. It omits
`package-check`, CodeQL, and `py-check`, so green `ci` says nothing about
those; the required GitHub checks are the merge verdict.

Cross-compile before committing a change to `CompilationTarget` branches,
`external_call`, or a hand-computed struct offset; the Linux floor is blind to
Darwin-only breaks:

```text
mojo build --target-triple arm64-apple-macosx14.0.0 --emit=asm \
  -I src -I vendor/mojo-toml src/main.mojo -o /dev/null
```

### Classified test modules

Every module under `tests/unit/` and `tests/integration/` declares `test_*`
functions and its own `main()` calling `TestSuite.discover_tests`, and is built
and run as its own program. Membership is derived from the sources: adding a test costs no
ledger edit, and a module reaching zero tests fails closed. A change to how
classified modules are built or discovered must cover every consumer — `test`,
`test-file`, ASan, Valgrind, dogfood, self-host, package consumption — with a
harness regression inspecting each build command.

### Hosted CI

Each lane is its own matrix cell; hosted CI never runs `pixi run ci`.
`scripts/checks/workflow_security.py` pins SHA-resolved actions, the sensitive
workflows' permissions, and the composite action's exact invocation.

**Running is not blocking.** Required contexts live in repository settings, not
here. Adding, renaming, or splitting a lane must update that list in the same
change; a job's display name is its context, so keep required names
byte-stable. The 20 required contexts: `preflight`, `classified suite`,
`assertions`, `end-to-end tests`, `strict contract`, `cache protocol`,
`build stamp`, and `packaged artifact` under both `Linux /` and
`macOS arm64 /`; `Linux / compiled oracles`, `Linux / ASan + LSan`,
`Linux / Valgrind Memcheck`; and `Python quality`. CodeQL blocks through the
ruleset's `code_scanning` rule, not a status context. `docs.yml` is the only
workflow with `pages: write`/`id-token: write`; `compat-canary.yml` is the only
lane running an unpinned compiler, with its write-scoped job running neither
pixi nor Mojo.

## Pins and ask-first boundaries

Every pin has a recorded reason; never move one to make something pass.

- Mojo `==1.1.0`. CI matches local. After a bump, regenerate transcripts and
  re-audit syntax against `mojo-syntax`.
- Zero runtime dependencies. The CLI parser is hand-rolled (`prism` was
  rejected: no `--` pass-through, repeated flags corrupt values with spaces;
  revisit when it ships native post-`--` pass-through).
- A vendored dependency records three digests: the authorized upstream release,
  upstream `main` at adoption, and every retained file after local patches.
  Update the third and list every local change in the vendor README in the same
  commit.

Ask first before: bumping the Mojo pin; changing the frozen CLI contract;
adding a dependency or reaching for Python where Mojo would do; weakening a gate
(a tolerance, a skip, a delete) to reach green; changing the committed
transcript or fixture format.

After a non-trivial edit, summarize what changed, what was intentionally left
alone, any concerns, and every Ask-first boundary crossed.

## Review gate

Each phase runs an external review at two checkpoints, the plan and the full
diff before merge: Claude Opus and Codex (danger-full-access sandbox), both at
xhigh reasoning, briefed to attack the work with a concrete failure scenario per
finding, severity-ranked. Triage every finding as fixed or rejected-with-reason
in that phase's notes.

## Commits

Conventional Commits with a required scope; atomic; imperative subject <= 72
chars; a body explaining why. Types: `feat`, `fix`, `refactor`, `perf`, `docs`,
`test`, `bench`, `build`, `ci`, `chore`. `skills` is a scope
(`docs(skills): …`). A commit regenerating transcripts names the oracle-side
reason in its body. Commits carry only human authorship: no AI attribution
lines or trailers. Committed files state reasons directly; the gitignored
working plans under `docs/plans/` are never referenced.

| Scope | Area |
| ----- | ---- |
| `scaffold` | repo skeleton, license/readme/gitignore/gitattributes |
| `pixi` | `pixi.toml`, `pixi.lock`, tasks, the environment |
| `fixtures` | `tests/fixtures/` protocol probes and subprocess actors |
| `transcripts` | protocol snapshots, `scripts/gen_transcripts.py`, `scripts/checks/{protocol_snapshots,transcript_compare}.py` |
| `spec` | `docs/cli-contract.md` |
| `agents` | `AGENTS.md`, `.agents/lessons.md` |
| `readme` | `README.md` |
| `model` / `platform` / `config` / `discover` / `protocol` / `select` / `exec` / `session` / `report` / `cli` | the matching `src/mtest/` layer |
| `assertions` | `companions/assertions/src/mtest/assertions` |
| `cache` | in-session build/collection reuse |
| `checks` | `scripts/checks/` policy gates |
| `formats` | `scripts/formats/` report formats and outcome vocabulary |
| `test` | `scripts/harness/`, `scripts/build/mojo_package.sh`, shared test helpers |
| `e2e` | `scripts/e2e/` and the `e2e/` manifest and scenarios |
| `qa` | `scripts/qa/` contract gate |
| `canary` | `scripts/canary/` and the canary workflow |
| `bench` | `benchmarks/` |
| `docs` | docstrings, `docs/` |
| `build` | packaging |
| `release` | `scripts/release/`, version and shipped-claim gates, release workflows |
| `ci` | `.github/workflows/` |
| `skills` | `.agents/skills/` |

## Lessons and skills

Failure modes already hit live in [`.agents/lessons.md`](.agents/lessons.md),
grouped by toolchain and protocol, process supervision, parsing and verdicts,
Mojo language, and harness and workflow. Read the matching section before
touching that area; append new entries there.

Read the matching skill **before** the work:

- Writing, changing, or reviewing Mojo here →
  [`mojo-coding-guidance`](.agents/skills/mojo-coding-guidance/SKILL.md).
- Writing or changing a test, or choosing how to prove a behavior →
  [`mtest-testing-patterns`](.agents/skills/mtest-testing-patterns/SKILL.md).
- Reviewing a diff or preparing to merge →
  [`code-review-and-quality`](.agents/skills/code-review-and-quality/SKILL.md).
- QA, acceptance, or release validation against `docs/cli-contract.md` →
  [`validating-mtest`](.agents/skills/validating-mtest/SKILL.md).
- All Mojo syntax → the global `mojo-syntax` skill.
