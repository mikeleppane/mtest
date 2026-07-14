# AGENTS.md — mtest

This file is the source of truth for working in this repo: scope, doctrine,
gates, pins, and the conventions every change must follow. The skills under
`.agents/skills/` go deeper on specific activities (git, Mojo coding, TDD,
review, architecture); the global `mojo-syntax` skill is the authority on Mojo
syntax. **When a skill and this file disagree, this file wins.** When this file
and a direct instruction from the human disagree, the human wins.

## Scope and non-goals

`mtest` is a pytest-like test runner for Mojo that **orchestrates** the standard
library's per-file `std.testing.TestSuite` — it never replaces it. TestSuite
owns discovery, per-test selection, and the report format inside a single file.
`mtest` owns everything between files: recursive discovery, building each file,
executing and supervising it as a subprocess, aggregating results, and reporting
them for CI.

Non-goals: it is **not** an assertion library (assertions come from
`std.testing`), **not** a property-testing framework, and **not** a replacement
for TestSuite. It has **zero runtime dependencies** — the runner is pure Mojo;
Python appears only in build-time tooling under `scripts/`.

## Product principles

- **Exit-code fidelity is the product.** A runner whose exit code you cannot
  trust is worse than none. Every test file is built and the binary is executed
  directly, because that is the only way Mojo reports a truthful process exit
  code. `mojo run` masks every outcome to `1` and is banned from the gate.
- **A crash is not a failure.** A failed assertion (FAIL) and a process that
  aborts or dies by signal (CRASH) are different events. They stay distinct in
  the summary, the JUnit XML, the annotations, and the exit code.
- **Loud over silent.** Every exclusion, retry, and timeout is reported visibly.
  A run that skipped something must never look like a run that passed everything.
- **CI is the customer.** Machine-readable reports, deterministic ordering
  independent of parallel completion, and a hermetic build are first-class.
- **Toolchain flakiness is weather.** Plan for it (build-not-run, cache
  quarantine, retries for crash-class steps); do not apologize for it.
- **Presentation is a feature.** The README is the front door, held to a
  standing per-phase doctrine: a professional front page showing what works
  TODAY; REAL examples, every command and its output executed against the built
  binary before commit (the runs recorded in that phase's notes); a CLI section
  current against `--help` exactly; an architecture section with a mermaid
  layering diagram; and honest status — the current ceiling, the untested
  platforms, the behaviors not yet built. No vaporware: nothing the build cannot
  do appears as if it can. Until a runnable binary exists, "executed examples"
  means the real developer commands (`pixi run ci` and friends), and the status
  says plainly that the runner itself is not built yet.

## The layering plan — one direction only

Every layer may import only from layers above it, never sideways or downward:

```text
Layer 0  model     outcomes, node ids, events, exit codes   (no internal imports)
Layer 1  config    RunnerConfig
Layer 2  discover | protocol (report/collect parsing) | report (event consumers)
Layer 3  exec      the POSIX process adapter, timeouts
Layer 4  session   orchestration: discover -> build -> run -> parse -> events
Layer 5  cli       hand-rolled argument parsing -> RunnerConfig; main
```

`exec` is the **deepest module**: a small process-control interface hiding pipes,
concurrent draining, FFI, platform differences, and cleanup invariants. Its
interface stays narrow even as its implementation absorbs that complexity.

The plugin seam is a **closed, typed event set** plus a `Reporter` trait consumed
by **comptime composition** (a comptime-known reporter tuple) — not a runtime
heterogeneous trait-object list, because 1.0.0b2 polymorphism is static. The
first console reporter must already flow through this composition: the seam is
proven the first time it exists.

## Mojo, not Python

`src/` is **pure Mojo**. Python lives only under `scripts/` (the transcript
generator and check harness) and is never a runtime dependency. Follow the
global `mojo-syntax` skill for all syntax — training data is stale, and this
toolchain has removed or renamed much of what a model will reach for by default
(`def` not `fn`, `comptime` not `alias`/`@parameter`, `var` not `let`,
`std.`-prefixed imports, `s[byte=i]` not `s[i]`). Docstrings are Google-style,
triple-quoted, and mandatory on public entities.

## The transcript lifecycle — doctrine

The committed golden transcripts under `goldens/transcripts/` pin TestSuite's
actual per-file protocol at the pinned toolchain. `scripts/gen_transcripts.py`
is the only thing that writes them.

- **A red `transcripts-check` after a repo change indicts THE CHANGE, not the
  goldens.** Regenerating (`pixi run transcripts`) is legitimate **only** when
  the oracle side visibly changed: a mojo pin bump (which appears in every
  transcript header) or a deliberate fixture/matrix edit. "The new output looks
  close enough" is never evidence.
- **Transcripts are regenerated only by the script, never by hand.** If a byte
  cannot be traced to a fixture, a scenario, and the pinned toolchain version in
  the header, it does not get committed.
- Running `mojo format` on a fixture legitimately shifts its `At
  <path>:<line>:<col>` coordinates. That is an **oracle-side change**: regenerate
  the transcripts; the red gate is correct, not flaky.
- When `transcripts-check` goes red, suspect in order: (1) generator
  nondeterminism (iteration order, environment leakage, an un-normalized
  absolute path); (2) a resolved-toolchain mismatch versus the header; (3) byte
  mangling from a missing `.gitattributes` entry on a new path.
- The normalizer is **anchored and minimal**. Over-normalization (a rule that
  touches a line it should not) is as serious a defect as nondeterminism —
  it hides a real protocol change. Each rule names the exact lines it may touch.

On a toolchain re-pin, regenerate FIRST and read the diff as the protocol
changelog; every changed line is a potential parser break and is triaged in the
phase notes.

## Hermetic by construction

CI touches the network exactly once: the locked `pixi install`. Everything after
is offline — the fixtures and the transcript generator are committed, and the
generator rebuilds the fixtures with the locked toolchain. A change that needs
the network in the gate is wrong.

## Toolchain and the quality floor

The floor before any change is done — all green, in this order:

```text
pixi run fmt              # format in place (run locally before committing)
pixi run build            # the package-compiles gate
pixi run transcripts-check# regenerate to a temp dir and diff byte-for-byte
pixi run test             # build each test and execute the binary directly
```

`pixi run ci` chains `fmt-check -> build -> transcripts-check -> test`
fail-fast and is exactly what CI runs. Never use `mojo run` in the gate.

## Pin policy and Ask-first boundaries

Pins are provenance, not preference.

- **Mojo `==1.0.0b2`.** CI must match local; a bump can silently change valid
  syntax **and** the pinned protocol. After a bump, regenerate the transcripts
  (the diff is the protocol changelog) and re-audit syntax against `mojo-syntax`.
- **Zero runtime dependencies.** The `prism` argument-parsing library was
  evaluated and **rejected** on source evidence: at its 1.0.0b2-pinned release a
  bare `--` enters flag parsing and raises (no pass-through), and repeated flags
  space-concatenate and re-split on spaces (values with spaces corrupt). A
  proposal to wrap prism with a pre-splitting adapter was also rejected — the
  wrapper is the hard part of a parser, the footgun remains for unwrapped flags,
  and it trades away the zero-dependency stance. **Revisit trigger:** prism ships
  native post-`--` pass-through. Until then the parser is hand-rolled.

**Ask first** before: bumping the Mojo pin; changing the CLI contract after it
freezes; adding any dependency (or reaching for Python where native Mojo would
do); weakening a gate (a tolerance, a skip, a delete) to reach green; changing
the committed transcript/fixture format.

## The standing per-phase quality gate

Every phase repeats the same external review loop, at **both** checkpoints — the
phase plan before execution, and the full phase diff before merge:

- **Claude Opus 4.8** at **xhigh** reasoning, and
- **Codex GPT-5.6-sol** at **xhigh** reasoning (danger-full-access sandbox),

both briefed to **attack** the work, not admire it — concrete failure scenarios
per finding, severity-ranked, silence meaning no finding. Every finding is
triaged **fixed or rejected-with-reason** in that phase's notes. This is standing
doctrine, not a one-off.

## Commits

Conventional Commits with a **required scope**, atomic, imperative subject ≤72
chars, a body explaining *why*. The type is one of the fixed set: `feat`, `fix`,
`refactor`, `perf`, `docs`, `test`, `bench`, `build`, `ci`, `chore`. Merge
commits are exempt from the grammar.

**No AI/assistant attribution anywhere** — no `Co-Authored-By` for an AI, no
"Generated with" line, no robot emoji, in any commit, merge commit, or note.
**No internal-plan references** — the working plans under `docs/plans/` are
gitignored and unpublished; a decision label, a handoff section name, or any
planning vocabulary must never appear in a committed file. State the reason
itself.

Scope vocabulary (authoritative; keep in sync as modules emerge):

| Scope | Area |
| ----- | ---- |
| `scaffold` | repo skeleton, license/readme/gitignore/gitattributes |
| `pixi` | `pixi.toml`, `pixi.lock`, tasks, the environment |
| `fixtures` | `fixtures/` — the committed TestSuite probe modules |
| `transcripts` | `goldens/transcripts/` + `scripts/gen_transcripts.py` + `scripts/transcripts_check.sh` |
| `spec` | `docs/cli-contract.md` |
| `agents` | `AGENTS.md`, `notes/` |
| `model` | `src/mtest/model` (outcomes, node ids, events, exit codes) |
| `config` | `src/mtest/config` (RunnerConfig) |
| `discover` | `src/mtest/discover` (file walking) |
| `protocol` | `src/mtest/protocol` (report/collect parsing) |
| `exec` | `src/mtest/exec` (the POSIX process adapter) |
| `session` | `src/mtest/session` (orchestration) |
| `report` | `src/mtest/report` (event consumers, reporters) |
| `cli` | `src/mtest/cli` (arg parsing, main) |
| `cache` | in-session build/collection reuse |
| `test` | test infrastructure (`scripts/test_all.sh`, `scripts/build_pkg.sh`, shared helpers) |
| `bench` | `benchmarks/` |
| `docs` | README, docstrings, `docs/` |
| `build` | packaging |
| `ci` | `.github/workflows/` |
| `skills` | `.agents/skills/` |

## Lessons

Accumulated the hard way; append as later phases teach more.

- **`mojo run` masks crash exit codes to 1** and can JIT-crash in CI, so it never
  appears in the gate. The runner and this repo's own `test` task both build a
  binary and execute it directly — the only way a crashing process's signal
  death is distinguishable from an assertion failure. A direct-executed abort
  exits `132` at the shell (`128 + SIGILL(4)`); the transcript generator records
  the raw signal number structurally (`termination: signal 4`), never `132`.
- **`mojo build` bakes the ABSOLUTE canonicalized source path** into every
  location line (`Running … for <path>`, `At <path>:…`, `ABORT: <path>:…`), even
  when built with a repo-relative path. Transcript portability therefore requires
  normalizing the repo-root prefix to `<REPO>`; there is no "build with relative
  paths" escape.
- **Discovery order is SOURCE order.** TestSuite registers `test_*` functions in
  the order `__functions_in_module()` yields them, which is source order. The
  fixtures deliberately use non-alphabetical function order so the transcripts
  pin this as a gate.
- **TestSuite buffers its whole report and flushes it as one block at the end.**
  On success it prints the block; on failure it *raises* the report, so the block
  arrives as the payload of the runtime's `Unhandled exception caught during
  execution:` line (observed on stdout). User `print`s stream immediately and
  precede it — so the report parser must anchor on the **last** `Running <N>
  tests for` line **that is followed by a `Summary` line**, never the first
  match. The Summary qualifier matters on a crash stream, where the report is
  lost: a `Running`-lookalike a test prints before aborting has no Summary after
  it, so it is not mistaken for the report and the lines a test printed are left
  byte-exact.
- **TestSuite exposes an in-code skip API** (`suite.skip[f]()`), used via the
  manual construction form (discover, skip, then `run()`). A natively-skipped
  test emits a normal `SKIP` report line — distinct from the selection-induced
  SKIPs that `--skip-all`/`--only`/`--skip` produce.
- **A `bare abort()` emits no `ABORT:` line** — the crash fixture must pass a
  message. A malformed `test_` function (e.g. one taking an argument) is not a
  compile error and is not silently excluded: it raises a discovery-time runtime
  error, `test function '<name>' has nonconforming signature`.
- **The crash stack dump has two forms** depending on whether llvm-symbolizer is
  on `PATH`: a symbol-less `Stack dump …` header plus `N module 0xADDR` frames,
  or a symbolized set of `#N 0xADDR sym file:line` frames that leak the binary
  and library paths. The normalizer collapses both to `<STACK-DUMP>` (header
  included), and hard-asserts every collapsed line matched a frame pattern so a
  new line shape fails generation loudly.
- **The report colorizes only on a TTY.** TestSuite emits `Text[Color.*]`, which
  is plain text through a pipe. `mtest` and the generator always capture through
  pipes, so the parser sees plain text; the transcripts pin the plain-text form.
- **Subprocess supervision is feasible from Mojo via POSIX FFI** (`std.ffi`
  `external_call`). A feasibility spike proved, on this toolchain, separate
  byte-exact stdout/stderr capture (args with spaces and empty strings survive),
  concurrent non-deadlocking drain via `poll`, timeout with a terminate-then-kill
  sequence, a process-**group** kill that reaches a grandchild, exit-vs-signal
  discrimination, and cwd control — all via `fork`/`setpgid`/`dup2`/`execvp`
  (async-signal-safe child path; argv built in the parent) and
  `pipe`/`poll`/`read`/`waitpid`/`kill`. `/bin/sh -c` is not a substitute. Two
  traps: re-declaring `write` via `external_call` collides with the stdlib's own
  `write` decl (use `read`/String instead), and the child after `fork` may call
  only async-signal-safe functions before `exec`.
- **The module cache is redirectable via `MODULAR_CACHE_DIR`** (the cache lives
  at `.mojo_cache`; `--print-cache-location`/`--clear-cache` exist). A post-kill
  retry build points it at a per-attempt temp dir so a killed compile's corrupted
  cache never reaches a fresh attempt. `mojo build --num-threads N` / `-j` exists
  (default 0 = all threads), so `mojo build` is multi-threaded and parallel
  worker sizing must not oversubscribe compiler threads.
- **`mojo package` does not exist in 1.0.0b2** — only `mojo precompile`, which
  produces the same `.mojopkg` (with a deprecation warning suggesting `.mojoc`;
  the name is kept so `-I build` resolves `from mtest import …`).

## Skills index

- `.agents/skills/git-conventions` — commit/branch/PR conventions for this repo.
- `.agents/skills/mojo-coding-guidance` — per-edit Mojo coding contract.
- `.agents/skills/test-driven-development` — the transcript-golden lifecycle and
  parser-testing discipline.
- `.agents/skills/code-review-and-quality` — pre-merge review axes and the
  standing dual-adversarial-review protocol.
- `.agents/skills/improve-architecture` — deep-module thinking on the layering.
- global `mojo-syntax` — the authority on Mojo syntax.
