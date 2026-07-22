# AGENTS.md — mtest

This file is the source of truth for working in this repo: scope, doctrine,
gates, pins, and conventions. The skills under `.agents/skills/` go deeper on
specific activities; the global `mojo-syntax` skill is the authority on Mojo
syntax. When a skill and this file disagree, this file wins. When this file and
a direct instruction from the human disagree, the human wins.

## Scope and non-goals

mtest is a pytest-like test runner for Mojo that **orchestrates** the standard
library's per-file `std.testing.TestSuite`, never replaces it. TestSuite owns
discovery, per-test selection, and the report format inside a single file.
mtest owns everything between files: recursive discovery, building each file,
executing and supervising it as a subprocess, aggregating results, and
reporting for CI.

Non-goals: not an assertion library, not a property-testing framework, not a
TestSuite replacement. Zero runtime dependencies: product logic under `src/` is
pure Mojo; the exec-private POSIX adapter under `native/` is compiled and
statically linked at build time; Python appears only in build-time tooling
under `scripts/` and test-only subprocess actors under `tests/fixtures/exec/`.

## Product principles

- **Exit-code fidelity is the product.** Every test file is built and the
  binary executed directly; `mojo run` masks every outcome to `1` and is
  banned from the gate.
- **A crash is not a failure.** FAIL and CRASH stay distinct in the summary,
  the JUnit XML, the annotations, and the exit code.
- **Loud over silent.** Every exclusion, retry, and timeout is reported
  visibly. A run that skipped something must never look like a run that passed
  everything.
- **CI is the customer.** Machine-readable reports, deterministic ordering,
  and a hermetic build are first-class.
- **Toolchain flakiness is weather.** Plan for it (build-not-run, cache
  quarantine, crash-class retries); do not apologize for it.
- **Presentation is a feature.** The README is the front door: professional,
  showing what works TODAY; REAL examples, every command and its output
  executed against the built binary before commit; a CLI section current
  against `--help` exactly; an architecture section with a mermaid layering
  diagram; limits stated as plain facts, never as roadmap, progress, or
  planning narrative. No vaporware: nothing the build cannot do appears as if
  it can.

## The layering plan — one direction only

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
only `exit()` caller, wiring reporters and session together, owning
argv/env/exit and nothing else. `exec` is the deepest module: a narrow
process-control interface hiding pipes, concurrent draining, FFI, platform
differences, and cleanup invariants.

Three named seams:

- **Reporter composition is comptime.** The plugin seam is a closed, typed
  event set plus a `Reporter` trait consumed by a comptime-known reporter
  tuple, not a runtime trait-object list, because 1.0.0b2 polymorphism is
  static.
- **`ReportCoordinator`** is how `session` and `main` reach the report layer.
  Reporter-specific lifecycle interactions (machine stream health, JUnit
  `[not-run]` synthesis and finalize, the annotation tail, the console's
  rendered output and fence token) are named methods on the coordinator, never
  a concrete reporter type or a tuple position. Two conformers:
  `StandardReportCoordinator` (production) and `RecordingCoordinator` (test
  drivers). Adding a reporter stays a local change inside a coordinator.
- **The run-file pipeline kernel** (`RunPipeline`,
  `src/mtest/session/pipeline.mojo`) holds each run file's stage between
  discovery and verdict, the stale-name recover-once budget, the `--retries`
  ceiling, and the `-x`/`--maxfail` stop policy, and answers one question:
  which step does the run want next. It spawns nothing, emits no event, owns
  no captured bytes. The driver in `session/selection.mojo` executes the step
  against `exec` and folds the completion back. The kernel decides; the driver
  executes.

**The sequential driver is the first of two.** It services one step at a time
through `run_supervised`, all the single-child native ABI permits. The worker
pool that `-n`/`--workers` and `--serial` name replaces only the driver (spawn
and wait-for-any in place of run-one-and-block) and requires the versioned
multi-child native adapter, a deliberate, gated change to `native/`. Admission,
retry, maxfail, serial, and accounting policy stay in the kernel and `session`,
never in `exec` or `native`. Nothing in the kernel is reserved for a future
phase: every stage, step kind, and halt reason is reached by the sequential
driver today and pinned by `tests/unit/test_session_pipeline.mojo`.

## Mojo, not Python

`src/` is pure Mojo. All platform and foreign-ABI knowledge lives in exactly
two audited boundaries; no layer above `exec` carries a raw platform call:

- **`src/mtest/platform`** (Layer 0): the small per-call libc operations a
  Mojo caller needs directly, each an in-Mojo `external_call` with its own
  local `# SAFETY:` proof, or a delegation to a safe stdlib wrapper where one
  expresses the exact semantics. Where the stdlib can express an operation,
  the safe call wins and no foreign declaration is written.
- **`native/` and the `mtest_exec_*` ABI**: a private C17 POSIX adapter for
  the machinery that must be async-signal-safe after fork (fork/exec, pipe
  supervision, signal handling), statically linked. No product policy,
  reporting, parsing, or orchestration. `exec` is its sole consumer; those
  `mtest_exec_*` calls, plus the residual test-only `kill(2)` in the exec
  signal helper, are the only raw foreign declarations that legitimately
  live in `exec`.

A new foreign call belongs in `platform`, unless it is native-adapter
machinery, in which case it belongs in `native/` behind the ABI. Python lives
only under `scripts/` and `tests/fixtures/exec/`. Follow the global
`mojo-syntax` skill for all syntax; training data is stale. Docstrings are
Google-style, triple-quoted, and mandatory on public entities.

## Unsafe Mojo requires a local proof

Every operation that bypasses Mojo's lifetime, initialization, bounds, type,
or ABI checks has an adjacent `# SAFETY:` comment immediately before the
smallest operation or contiguous block it justifies, never a distant
function-level assurance. The argument is concrete and falsifiable: pointer
provenance and ownership (who frees), lifetime and non-escape across every
borrow or syscall, bounds and complete initialization before reads, alignment,
layout, valid bit patterns, and platform assumptions, the exact foreign ABI and
pointer retention, signal-handler or post-fork restrictions and concurrency
assumptions, and cleanup on success, error, timeout, and
partial-initialization paths. Prefer deleting an unsafe
operation when a safe stdlib operation exists. `pixi run safety-check`
enforces comment presence; a green checker is not proof the code is sound.

## The transcript lifecycle

The committed snapshots under `tests/snapshots/protocol/` pin TestSuite's
per-file protocol at the pinned toolchain. `scripts/gen_transcripts.py` is the
only thing that writes them.

- A red `transcripts-check` after a repo change indicts THE CHANGE, not the
  snapshots. Regenerating is legitimate only when the oracle side visibly
  changed: a mojo pin bump or a deliberate fixture/matrix edit. "The new
  output looks close enough" is never evidence.
- Transcripts are regenerated only by the script, never by hand. A byte that
  cannot be traced to a fixture, a scenario, and the pinned toolchain version
  in the header does not get committed.
- `mojo format` on a fixture legitimately shifts `At <path>:<line>:<col>`
  coordinates: an oracle-side change; regenerate.
- On a red gate, suspect in order: generator nondeterminism, a
  resolved-toolchain mismatch versus the header, byte mangling from a missing
  `.gitattributes` entry.
- The normalizer is anchored and minimal. Over-normalization hides real
  protocol changes and is as serious a defect as nondeterminism. Each rule
  names the exact lines it may touch.
- On a toolchain re-pin, regenerate FIRST and read the diff as the protocol
  changelog.

## Hermetic by construction

The source, test, and memory-analysis lanes touch the network once for the
locked `pixi install`; everything after is offline, with one exception: the
Linux Valgrind cell may install exactly the `libc6-dbg` version matching the
runner's `libc6`, logging apt provenance and failing on any mismatch. The
independent Linux package-consumption job has a separate approved network
contract (rattler-build solves against the pinned Modular and conda-forge
channels; nothing uploads or authenticates). Do not describe that job as
hermetic or collapse it into the Valgrind exception.

## Toolchain and the quality floor

The floor before any change is done, all green, in this order:

```text
pixi run fmt               # format in place (run locally before committing)
pixi run version-check     # manifest, CLI, and shipped-version identity
pixi run harness-check     # validate exact harness/CI membership and invariants
pixi run safety-check      # inventory every unsafe Mojo operation and local proof
pixi run postfork-check    # audit production/testing post-fork call graphs
pixi run native-check      # verify native ABI/layout/exports and lifecycle
pixi run junit-check       # validate the committed JUnit oracle and checker
pixi run build             # the package-compiles gate
pixi run junit-render-check  # validate bytes emitted by the real JUnit reporter
pixi run transcripts-check # regenerate to a temp dir and diff byte-for-byte
pixi run test              # compile the classified inventory into one direct-run binary
pixi run dogfood-check     # run three focused probes through the built mtest binary
pixi run e2e               # exact CLI exits and output against e2e/manifest.json
```

`pixi run ci-preflight` chains `version-check -> fmt-check -> harness-check ->
safety-check -> postfork-check -> native-check -> junit-check -> build ->
junit-render-check -> transcripts-check` in that exact fail-fast order; the
canonical local `pixi run ci` is serial: `ci-preflight ->
test -> dogfood-check -> e2e`. Hosted CI runs the same logical floor as two
platform-local chains: Linux preflight releases fail-fast `test`,
`dogfood-check`, `e2e`, ASan, and Valgrind cells; macOS preflight releases
`test`, `dogfood-check`, and `e2e` cells with `fail-fast: false`. Every lane
is a blocking check; memory safety runs on every pull request and configured
main-branch push, not on a schedule. Transcripts, ASan/Valgrind, and
packaged-artifact consumption remain Linux-only. The matrix lane display names
`direct tests` and `self-hosted tests` are externally configured required
check names and must stay stable. `native-check` depends on `postfork-check`,
so the native gate alone cannot skip the child call-graph audit.

Classified modules under `tests/unit/` and `tests/integration/` are
import-only: they declare `test_*` functions and MUST NOT declare `main()`.
`scripts/harness/aggregate.py` imports them and registers every test function
explicitly; every harness that executes a classified module (test, test-file,
ASan, Valgrind) generates its entrypoint through that script. Standalone
protocol fixtures, e2e fixtures, and dogfood probes still declare their own
`main()` because mtest compiles them as individual programs. Use
`pixi run test-file -- <classified-test.mojo>` while investigating a failure.

## Pin policy and ask-first boundaries

Pins are provenance, not preference.

- **Mojo `==1.0.0b2`.** CI must match local; a bump can silently change valid
  syntax AND the pinned protocol. After a bump, regenerate the transcripts and
  re-audit syntax against `mojo-syntax`.
- **Zero runtime dependencies.** The `prism` argument-parsing library was
  evaluated and rejected on source evidence (no `--` pass-through; repeated
  flags corrupt values with spaces); wrapping it was rejected too. Revisit
  trigger: prism ships native post-`--` pass-through. Until then the parser is
  hand-rolled.

**Ask first** before: bumping the Mojo pin; changing the CLI contract after it
freezes; adding any dependency (or reaching for Python where native Mojo would
do); weakening a gate (a tolerance, a skip, a delete) to reach green; changing
the committed transcript/fixture format.

## The standing per-phase quality gate

Every phase repeats the same external review loop at both checkpoints, the
plan before execution and the full diff before merge: Claude Opus 4.8 at
xhigh reasoning, and Codex GPT-5.6-sol at xhigh reasoning
(danger-full-access sandbox), both briefed to attack the work, not admire it:
concrete failure scenarios per finding, severity-ranked, silence meaning no
finding. Every finding is triaged fixed or rejected-with-reason in that
phase's notes.

## Commits

Conventional Commits with a required scope, atomic, imperative subject <=72
chars, a body explaining why. Types: `feat`, `fix`, `refactor`, `perf`,
`docs`, `test`, `bench`, `build`, `ci`, `chore`. Merge commits are exempt.

**No AI/assistant attribution anywhere**: no `Co-Authored-By` for an AI, no
"Generated with" line, no robot emoji, in any commit, merge commit, or note.
**No internal-plan references**: the working plans under `docs/plans/` are
gitignored and unpublished; a decision label, a handoff section name, or any
planning vocabulary must never appear in a committed file. State the reason
itself.

Scope vocabulary (authoritative; keep in sync as modules emerge):

| Scope | Area |
| ----- | ---- |
| `scaffold` | repo skeleton, license/readme/gitignore/gitattributes |
| `pixi` | `pixi.toml`, `pixi.lock`, tasks, the environment |
| `fixtures` | `tests/fixtures/` — protocol probes and subprocess actors |
| `transcripts` | protocol snapshots plus `scripts/gen_transcripts.py` and `scripts/checks/{protocol_snapshots,transcript_compare}.py` |
| `spec` | `docs/cli-contract.md` |
| `agents` | `AGENTS.md` |
| `notes` | `notes/` |
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
| `cli` | `src/mtest/cli` (arg parsing, main) |
| `cache` | in-session build/collection reuse |
| `test` | test infrastructure (`scripts/harness/{classified,dogfood}.py`, `scripts/build/mojo_package.sh`, shared helpers) |
| `e2e` | end-to-end harness (`scripts/e2e/`) and its `e2e/` manifest and scenarios |
| `bench` | `benchmarks/` |
| `docs` | docstrings, `docs/` |
| `build` | packaging |
| `ci` | `.github/workflows/` |
| `skills` | `.agents/skills/` |

## Lessons

Accumulated the hard way; append as later phases teach more. Each entry is a
trap and its correct move.

**Toolchain and protocol**

- `mojo run` masks crash exit codes to `1` and can JIT-crash in CI; never in
  the gate. Direct-executed `std.os.abort` exits `132` at the shell on
  linux-64 (`128 + SIGILL`); on osx-arm64 the trap is SIGTRAP. The transcript
  generator records the raw signal number structurally, never `132`.
- `mojo build` bakes the ABSOLUTE canonicalized source path into every
  location line, even when built with a relative path; transcript portability
  requires normalizing the repo-root prefix to `<REPO>`.
- Discovery order is SOURCE order (`__functions_in_module()` yields source
  order); the fixtures pin this deliberately with non-alphabetical functions.
- TestSuite buffers its whole report and flushes it at the end; on failure it
  RAISES the report, so the block arrives after the runtime's `Unhandled
  exception caught during execution:` line. Anchor on the LAST `Running <N>
  tests for` line that is FOLLOWED by a `Summary` line, never the first
  match; a `Running`-lookalike a test prints before crashing has no Summary.
- `suite.skip[f]()` exists (manual construction form); a natively-skipped
  test emits a normal `SKIP` row, distinct from selection-induced SKIPs.
- A bare `abort()` emits no `ABORT:` line (crash fixtures must pass a
  message). A malformed `test_` function raises a discovery-time runtime
  error, not a compile error.
- The crash stack dump has two forms (symbolized and not); the normalizer
  collapses both to `<STACK-DUMP>` and hard-asserts every collapsed line
  matched a frame pattern.
- The report colorizes only on a TTY; mtest and the generator capture through
  pipes, so the parser sees plain text.
- `mojo package` does not exist in 1.0.0b2; `mojo precompile` produces the
  `.mojopkg`.
- The module cache is redirectable via `MODULAR_CACHE_DIR`. `mojo build` is
  multi-threaded by default (`--num-threads`), so parallel worker sizing must
  not oversubscribe compiler threads.
- A killed `mojo build` never corrupted its cache in a nine-trial kill probe
  (strict temp-then-rename atomicity observed); the per-attempt quarantine
  dir is defense-in-depth for residual risk, not a fix for observed
  corruption.

**Process supervision**

- EOF on both read pipes is NOT completion: a child terminates only when
  `waitpid` reaps it. Keep enforcing the deadline with `waitpid(WNOHANG)` in
  a poll loop; never issue a blocking `waitpid` after EOF. Every kill targets
  the process GROUP (`kill(-pgid, ...)`, via `setpgid`); a grandchild
  inherits the pipe write end, and killing only the direct child leaves the
  parent's read blocked forever. The child after `fork` may call only
  async-signal-safe functions before `exec`. `/bin/sh -c` is not a
  substitute. This machinery now ships in the native C adapter.
- Native adapter ABI v2 admits a pool; supervision still drives one child at a
  time (for now). The adapter keeps a fixed slot table
  (`MTEST_EXEC_SLOT_CAPACITY`, 64): `process_open` claims a FREE slot with a
  per-slot compare-exchange and only fails `EBUSY` when every slot is ACTIVE
  (capacity exhausted, `error.detail == 0`) or the runtime is unusable, so a
  second `process_open` now SUCCEEDS into another slot. `runtime_close` drains
  every live handle. The higher-level SUPERVISION contract is still capacity-1
  (the sequential driver runs one child per step); running the pool
  concurrently is a later, gated change to the Mojo side, never a workaround.
  Any adapter change is a deliberate gated edit to `native/`.
- Signal handling and the supervision syscalls live in the native C adapter,
  not Mojo FFI. `src/mtest/exec/signals.mojo` calls the `mtest_exec_*` ABI;
  the interrupt latch surfaces as `interrupt_requested() -> Bool`. Never
  reintroduce Mojo-side syscalls, sigaction layouts, or fixed mmap pages
  (historical hazards: `std.ffi._Global` crashes the compiler; a Mojo `def`
  used as a C callback needs one deref to recover the code pointer).
- The post-kill cache quarantine mutates the PARENT's environment
  (`MODULAR_CACHE_DIR`) right before spawn and restores it after; the native
  adapter snapshots live `environ` at spawn. Safe ONLY while the session is
  single-threaded; a concurrent pool must route per-child env through
  `ProcessSpec.env_extra` (reserved, still unread) or two children will race
  the shared parent env.
- Dynamic-loader fault injection (`LD_PRELOAD`/`DYLD_INSERT_LIBRARIES`)
  inherits into every spawned process, including `mojo build` children. A
  test-only interposer clears its loader variable in a constructor after
  loading into mtest, unless descendant instrumentation is the subject.
- Valgrind needs an instruction-set ceiling: hosted runners may advertise
  x86-64-v4 and Mojo then emits EVEX instructions Valgrind cannot decode.
  Compile the Valgrind-exercised binaries with `--target-cpu x86-64-v3`.

**Parsing and verdict discipline**

- A parsed report is trusted only via triple reconciliation: header count,
  row count, and Summary totals must all agree, AND the row-level tally must
  equal the Summary tally. Two or more complete well-formed report blocks for
  one path classify AMBIGUOUS, never "last wins".
- Under `--only`, a natively-skipped SELECTED test and a deselected test are
  byte-identical SKIP rows; reconcile against the names mtest itself
  selected. A SKIP on a selected name is a native skip; a SKIP on a
  non-selected name is a deselection; a non-selected row that is NOT SKIP is
  MALFORMED-SUITE.
- On a truncated capture, re-parse only the text AFTER the LAST
  truncation-marker line and accept only a fully VALID parse there; otherwise
  the file is a capture-overflow FAIL, never a PASS.
- Reconciliation, suppression, and membership disagreements are user-class
  failures (MALFORMED-SUITE, exit 1), never exit 3. Exit 3 (drift) is
  reserved for a genuine off-grammar report from the pinned toolchain. When
  both explanations are open, blame the file.
- The crash-class retry classifier (`retry_class`) retries ONLY a signal
  death, a deadline kill, or a compiler crash (by signal, or a pinned ICE
  stderr signature on nonzero exit; the signature list is assumption-pinned,
  never validated against an observed real ICE, so extend it when a real one
  shows a new banner). A process that Exited under its own control, at ANY
  code, is deterministic and never retried.
- BuildProducts registry replacement is atomic (whole-slot): always replace
  the whole product on rebuild, never patch a field, so no stale
  canonical-source or listing survives.

**Mojo language, pinned toolchain**

- `fn` is fully removed, including as a function-value type: write
  `def(...) -> ...`.
- A tuple return annotation `-> (Bool, Int)` does not compile; return a small
  `@fieldwise_init` struct.
- `exit()` is not `noreturn` to flow analysis; seed a sentinel before a
  `try` whose branches all exit, with a comment saying why.
- `UnsafePointer` is non-nullable; `unsafe_from_address=0` fails at compile
  time. For a NULL argv terminator, over-allocate by one and `memset_zero`.
  Use the free `alloc[T](n)`; `.alloc`/`.offset` methods do not exist.
- `UnsafePointer[T, _]` helper arguments get an immutable wildcard origin;
  write struct fields inline at the call site where the pointer still has its
  concrete mutable origin.
- String -> C string: `s.as_c_string_slice().unsafe_ptr()`. Bytes -> String:
  `String(StringSlice(unsafe_from_utf8=Span(list)))`.
- A closed-vocabulary Int-wrapping struct must conform to
  `ImplicitlyCopyable` or its comptime constants fail to materialize. Large
  owning structs stay `Copyable, Movable` only, so every copy is a visible
  `.copy()`; this is house discipline, not compiler-forced (`String` is
  `ImplicitlyCopyable` in 1.0.0b2).
- `Int(String)` RAISES on non-digit input; a pure non-raising parser
  hand-rolls digit-by-digit parsing. `std.os.path.realpath` exists for
  canonicalizing to the exact string `mojo build` bakes into reports.
- Filesystem stdlib: `std.os` / `std.os.path` / `std.tempfile` (no
  `std.shutil`, no `rmtree`; delete recursively by hand). `isdir`/`isfile`
  FOLLOW symlinks; skip `islink` entries before recursing. `listdir` is
  unsorted; sort with `from std.builtin.sort import sort`.
- Fanning one event to N heterogeneous reporters is a comptime variadic
  pack: `struct Composite[*Rs: Reporter]` holding `Tuple[*Self.Rs]`,
  dispatched with `comptime for`. Traps: write `Self.Rs` inside the struct;
  build the tuple at the call site and move it in (a `VariadicPack` cannot be
  splatted into `Tuple`); iterate with the comptime `Self.Rs.__len__()`; the
  composite cannot synthesize `Copyable`, but `Movable` DOES synthesize with
  explicit conformance, which is how a coordinator owns its pack. The pinned
  compiler accepts a movable-only reporter pack if a reporter must ever own a
  non-copyable resource.
- Reaching a concrete reporter back out of a `CompositeReporter[*Rs]` pack
  takes a comptime index plus a typed reference binding, never a bare
  `rebind` (a wrong index then fails to compile instead of being UB). That
  reach is legitimate only for a test driver pulling its own recorder out of
  a pack it composed; session-level reporter lifecycle goes through the
  `ReportCoordinator` named methods.
- A raw `external_call["isatty", ...]` link-conflicts with
  `std.io.FileDescriptor`'s own declaration once imported next to TestSuite;
  delegate to the std wrapper. The same discipline governs `write`.

**Harness and workflow**

- `mojo` resolves only through the pixi environment's `PATH`; a binary that
  spawns `mojo` children must run under `pixi run`. Never scrub the
  environment before such a spawn.
- A `pixi run`-less invocation of the e2e driver fails many scenarios with
  `INTERNAL-ERROR ... could not execute 'mojo' (errno 2)`. Errno 2 on `mojo`
  means wrong environment, not broken code.
- `fmt-check` is the first `ci` gate and reds on ANY uncommitted diff; commit
  or stash first. Capture a gate's REAL exit as its own statement
  (`cmd; echo "x=$?"`); a trailing pipe silently reports 0.
- The harness gates enforce explicit membership (`scripts/checks/layout.py`
  pins exact suite/fixture sets and counts); register a new suite, fixture,
  snapshot, or e2e file in the SAME commit that adds it.
- Never run two builds against the shared `build/` tree at once; a racing
  build corrupted `build/mtest.mojopkg` mid-write and looked exactly like a
  real regression. Builds run one at a time, full stop.
- A regression guard must be shown to FAIL when its property is broken:
  mutation-prove it (break the property, watch it go red, revert) before
  calling it a pin. "I ran it and it looked right" is an observation, not a
  guard.
- Mojo test binaries inherit a huge `RLIMIT_NOFILE` (~1M), making subprocess
  spawns from inside a Mojo test pathologically slow. Validate emitted
  artifacts via a separate Python CI gate over the real binary's output; keep
  Mojo unit tests in-process.
- Multibyte UTF-8 anywhere in `native/*.c` (comments included) misaligns
  `postfork.py`'s byte-offset AST slicing. Keep `native/` strictly ASCII.
- A tool that COMMITS captured program output containing filesystem paths
  must rewrite the ephemeral run root to a stable placeholder before writing
  (both the literal and realpath spellings), the way
  `scripts/maintenance/pty_capture.py` and `scripts/gen_transcripts.py` do.

## Skills index

- `.agents/skills/git-conventions` — commit/branch/PR conventions.
- `.agents/skills/mojo-coding-guidance` — per-edit Mojo coding contract.
- `.agents/skills/test-driven-development` — the protocol-snapshot lifecycle
  and parser-testing discipline.
- `.agents/skills/code-review-and-quality` — pre-merge review axes and the
  dual-adversarial-review protocol.
- `.agents/skills/improve-architecture` — deep-module thinking on the
  layering.
- global `mojo-syntax` — the authority on Mojo syntax.
