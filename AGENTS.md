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
Python appears only in build-time tooling under `scripts/` and test-only
subprocess actors under `tests/fixtures/exec/`.

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

`src/` is **pure Mojo**. Python lives only under `scripts/` (build/test harnesses)
and `tests/fixtures/exec/` (test-only subprocess actors), and is never a runtime
dependency. Follow the
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
pixi run test-direct      # the independent glob-driven twin: build+execute
                           # each unit/integration suite directly, no mtest involved
pixi run test             # the self-hosted dogfood run: build/mtest over its
                           # own tests/, plus exact path-membership verification
                           # against an independent classified inventory
pixi run e2e              # build the binary, drive it against testdata/
                            # (manifest.json), assert exact exit codes/output
```

`pixi run ci` chains `fmt-check -> harness-check -> build -> transcripts-check ->
test-direct -> test -> e2e` fail-fast and is exactly what CI runs. `test-direct` and `test`
both build-then-execute the binary directly — never `mojo run` anywhere in the
gate, because it masks crash exit codes to 1.

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
| `agents` | `AGENTS.md` |
| `notes` | `notes/` |
| `readme` | `README.md` |
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
| `e2e` | end-to-end harness (`scripts/e2e_check.py`) and its `testdata/` manifest and scenarios |
| `bench` | `benchmarks/` |
| `docs` | docstrings, `docs/` |
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
  sequence, exit-vs-signal discrimination, and cwd control — all via
  `fork`/`setpgid`/`dup2`/`execvp` (async-signal-safe child path; argv built in
  the parent) and `pipe`/`poll`/`read`/`waitpid`/`kill`. `/bin/sh -c` is not a
  substitute. **EOF on both read pipes is NOT completion.** A supervised child
  terminates only when `waitpid` reaps it — EOF just means no more output is
  coming, and a child that closes its streams and then hangs must still be
  killed by the deadline. The supervision loop therefore keeps enforcing the
  deadline with `waitpid(..., WNOHANG)` in a poll loop and never issues a
  blocking `waitpid` after EOF (that can hang the runner forever). Every kill —
  the deadline kill and every cleanup kill — targets the process **group**
  (`kill(-pgid, …)`, via `setpgid`), never the direct child alone: a grandchild
  inherits the redirected pipe write end, so killing only the direct child
  leaves the parent's read blocked forever. Two further traps: re-declaring
  `write` via `external_call` collides with the stdlib's own `write` decl (use
  `read`/String instead), and the child after `fork` may call only
  async-signal-safe functions before `exec`.
- **The module cache is redirectable via `MODULAR_CACHE_DIR`** (the cache lives
  at `.mojo_cache`; `--print-cache-location`/`--clear-cache` exist). A post-kill
  retry build points it at a per-attempt temp dir so a killed compile's corrupted
  cache never reaches a fresh attempt. `mojo build --num-threads N` / `-j` exists
  (default 0 = all threads), so `mojo build` is multi-threaded and parallel
  worker sizing must not oversubscribe compiler threads.
- **`mojo package` does not exist in 1.0.0b2** — only `mojo precompile`, which
  produces the same `.mojopkg` (with a deprecation warning suggesting `.mojoc`;
  the name is kept so `-I build` resolves `from mtest import …`).
- **`UnsafePointer[T, _]` helper-argument origins are immutable by default.** A
  helper function whose parameter is written `UnsafePointer[T, _]` receives a
  wildcard origin that cannot be written through — writing a field via that
  pointer fails with a "cannot mutate through immutable origin"-class compile
  error at the write site. Correct move: write struct fields inline at the call
  site, where the pointer still carries its concrete, mutable `alloc` origin,
  rather than threading it through a helper that widens the origin to a
  wildcard.
- **String ↔ C-string/bytes conversion recipes (pinned for this toolchain):**
  String → C string is `s.as_c_string_slice().unsafe_ptr()`; bytes (a
  `List[Byte]`/span) → String is
  `String(StringSlice(unsafe_from_utf8=Span(list)))`. FFI code reuses these
  rather than reinventing byte/string plumbing.
- **Fanning one event to N heterogeneous reporters is a comptime variadic
  type-parameter pack, not a runtime trait-object list** — 1.0.0b2 polymorphism
  is static. The proven pattern: a `struct Composite[*Rs: Reporter]` stores
  `var reporters: Tuple[*Self.Rs]` and dispatches with
  `comptime for i in range(Self.N): self.reporters[i].handle(e)`, where
  `comptime N = Self.Rs.__len__()`. Five traps: inside the struct the pack must
  be written `Self.Rs`, never bare `Rs` (symptom: "unqualified access to struct
  parameter 'Rs'"); the constructor must accept a pre-built `Tuple[*Self.Rs]`
  and move it in (`self.reporters = reporters^`), because a `VariadicPack`
  cannot be splatted directly into `Tuple`'s constructor (symptom: "cannot
  implicitly convert 'Tuple[VariadicPack[...]]' to 'Tuple[*Rs.values]'") — build
  the tuple at the call site instead, `Composite(Tuple(A(...), B(...)))`, and
  let `Rs` be inferred; the iteration length must be the comptime
  `Self.Rs.__len__()`, never a runtime `len(tuple)` (symptom: "cannot use a
  dynamic value in 'for' iterator expression"); reading a stored reporter's
  state back needs no `rebind`, because a comptime-known index recovers the
  concrete element type; and the struct itself cannot be made to conform to a
  `Copyable`-bounded trait, even when every `Rs` element does, because
  `Tuple[*Self.Rs]` is not synthesizably `Copyable` (symptom: "cannot
  synthesize copy constructor because field '...' has non-copyable type
  'Tuple[*Rs.values]'") — use such a composite as the top-level type a consumer
  is generic over, never nested inside another struct. Correct move: adding a
  reporter means adding a tuple element at the call site — dispatch stays fully
  static.
- **`fn` is fully removed in 1.0.0b2** — the compiler rejects it outright
  (`'fn' has been removed; use 'def' instead`), including as a function-VALUE
  type: write `def(...) -> ...`, never `fn(...) -> ...`.
- **There is no module-global `var`, and `std.ffi._Global` crashes the
  compiler** (`ParamInf::inferForStruct`). For state a bare C signal handler
  must reach, the working pattern is a fixed-address anonymous mapping:
  `mmap(FIXED_ADDR, 4096, PROT_READ|WRITE, MAP_PRIVATE|MAP_ANONYMOUS|
  MAP_FIXED_NOREPLACE)`. Anonymous pages are zero-filled, so a flag stored
  there reads False before any handler ever fires — safe to read even when no
  handler was installed. On `MAP_FAILED`, check `errno == EEXIST` (the page is
  already mapped — the idempotent reuse path) versus any other errno (a real
  failure: raise); reusing a fixed address that mmap actually left unmapped
  SIGSEGVs on the next access, so the two cases must not be conflated.
- **A Mojo `def` used as a C callback is not itself usable as a code
  pointer.** The function value IS the code pointer, but `UnsafePointer(to=
  handler)` yields a stack slot that *holds* it — passing that pointer to
  `sigaction` segfaults. Deref once, `UnsafePointer(to=handler).bitcast[
  UInt64]()[0]`, to recover the real text-segment entry address, then write
  those 8 bytes into the sigaction buffer (glibc linux-64 layout: `sa_flags`
  at byte offset 136, struct ≥152 bytes); the kernel then correctly invokes a
  `def(Int32)` handler via the SysV single-int ABI.
- **`UnsafePointer` is non-nullable by construction** — there is no null
  default constructor, and `unsafe_from_address=0` hard-fails at compile time
  (`UnsafePointer is non-nullable. To construct a null pointer, use
  Optional[UnsafePointer] to model nullability.`). For a NULL argv terminator,
  over-allocate the array by one slot and `memset_zero` the whole buffer
  before filling only the real entries — the untouched trailing slot IS the
  terminator. Build a pointer from a raw integer address with
  `UnsafePointer[T, MutAnyOrigin](unsafe_from_address=addr)`. `.alloc`/
  `.offset` instance methods don't exist; use the free `alloc[T](n)` from
  `std.memory` and `p.bitcast[U]()[k]` for byte-offset access.
- **A tuple RETURN-type annotation, `-> (Bool, Int)`, does not compile**
  (`no matching function in initialization` against `Tuple`'s synthesized
  constructors) — return a small `@fieldwise_init` struct for any multi-value
  result instead.
- **A closed-vocabulary struct (an Int-wrapping enum-like type with `comptime
  NAME = Self(n)` constants) must conform to `ImplicitlyCopyable`**, or the
  constants fail to materialize at runtime; these types hold no owned
  resources, so the conformance costs nothing. A large OWNING struct (holding
  `List`s/`String`s) instead stays `Copyable, Movable` only, so every copy is
  a visible, deliberate `.copy()` — reading an owned field into a local, or
  calling `.value()` on an `Optional` of one, is an implicit copy and is
  REJECTED without an explicit `.copy()`.
- **`exit()` is not `noreturn` to Mojo's flow analysis** — after a
  `try/except` whose every branch only calls `exit`, the compiler still
  treats a variable used later as possibly-uninitialized on the fall-through
  path it thinks exists. Seed a sentinel value before the `try`, with a
  comment explaining why, so a reader doesn't "clean up" the dead-looking
  initializer.
- **The filesystem stdlib (1.0.0b2) lives under `std.os`/`std.os.path`/
  `std.tempfile`, not `std.shutil`** — `from std.os.path import exists, isdir,
  isfile, islink, dirname, basename` (`isdir`/`isfile` FOLLOW symlinks;
  `islink` detects them, so a no-follow directory walk must skip `islink`
  entries before recursing into them), `from std.os import listdir, makedirs,
  symlink, remove, rmdir` (`listdir` entries are UNSORTED and `List` has no
  `.sort()` — sort with `from std.builtin.sort import sort`), `from
  std.tempfile import mkdtemp`. There is no `rmtree`; delete recursively by
  hand.
- **`mojo` resolves only through the pixi environment's `PATH`** — a binary
  that itself spawns `mojo` as a child process (as this runner does, to build
  each test file) must run under `pixi run`, or the child's `mojo build`
  fails to spawn. Never scrub the environment before such a spawn: passing it
  straight through is what lets the pixi toolchain reach every grandchild.
- **A parsed report is trusted only via triple count reconciliation, never
  because it "looks" well-formed.** The header's declared count, the actual
  row count, and the Summary line's own total must all agree, AND the row-level
  PASS/FAIL/SKIP tally must equal the Summary's PASS/FAIL/SKIP tally. Trap:
  accepting a report because its rows and its Summary line are each
  individually well-shaped. Correct move: the triple reconciliation is the
  forgery backstop — it is what stands between a hand-forged or off-grammar
  report and a false PASS. The same discipline extends to block count: two or
  more complete, individually well-formed report blocks for the same path are
  never resolved "last wins" — a suite that runs `TestSuite...run()` twice
  produces two well-formed blocks, and picking one would silently launder a
  forged extra block, so multiple complete blocks classify AMBIGUOUS instead.
- **`--only <name>` selecting a natively-skipped test is byte-identical to
  `--skip-all`.** Under `--only`, every non-selected test reports as a
  selection-induced SKIP row, and a natively-skipped SELECTED test also
  reports SKIP — the stdlib does not distinguish the two in the report bytes;
  only the `cmd:` line in the header differs between the two transcripts. Trap:
  treating every SKIP row in a selection run the same way. Correct move:
  reconcile against the names mtest itself selected, not the report alone — a
  SKIP on a SELECTED name is a native skip (report it as SKIP); a SKIP on a
  NON-selected name is a deselection (suppress the row, count it DESELECTED
  instead); a non-selected row that is NOT SKIP is MALFORMED-SUITE (a
  deselected test ran when it should have been suppressed).
- **A truncated capture never yields PASS unless the whole report survived in
  the retained tail.** Trap: parsing the full truncated stdout as one string
  and trusting whatever report block turns up in it — the retained head can
  hold a stale or partial block from before the omission marker. Correct
  move: on a truncated capture (the exec layer's `stdout_truncated` flag),
  re-parse only the text AFTER the LAST truncation-marker line, and accept the
  result only if it parses fully VALID there; otherwise the report was lost to
  truncation and the file is a capture-overflow FAIL — never a drift, never a
  PASS.
- **Reconciliation, suppression, and stale-name/membership disagreements are
  user-class failures (MALFORMED-SUITE, exit 1), never exit 3.** Exit 3
  (drift) is reserved for a genuine off-grammar report from the pinned
  toolchain, decided by the parser's own grammar precedence — not for a
  selection run that disagrees with itself. Trap: routing a suppression or
  membership disagreement (a deselected test that ran, a row set that doesn't
  match the collected universe, a suite that refuses a name it just listed) to
  exit 3 and blaming the toolchain. Correct move: when both a toolchain-drift
  explanation and a file-behaving-badly explanation are open, blame the file —
  MALFORMED-SUITE, exit 1, not drift.
- **More Mojo-syntax gotchas from this toolchain:** `String` conforms to
  `ImplicitlyCopyable` in 1.0.0b2, so the "owning struct stays `Copyable,
  Movable` only, with an explicit `.copy()`" house convention above is a
  deliberate code-review discipline this repo chooses, not something the
  compiler forces on `String` fields — do not treat an implicit `String` copy
  as a compile error to design around. `Int(String)` RAISES on non-digit
  input, so a `def` that must stay pure and non-raising (a report parser, for
  instance) cannot call it — hand-roll digit-by-digit parsing instead (walk
  codepoints, reject anything outside `0`-`9`, accumulate manually, and return
  a sentinel such as `-1` for "not a number"). `std.os.path.realpath` exists
  and resolves symlinks, so canonicalizing a path to the exact string `mojo
  build` bakes into its report lines needs no libc FFI — `from std.os.path
  import realpath` is enough.

## Skills index

- `.agents/skills/git-conventions` — commit/branch/PR conventions for this repo.
- `.agents/skills/mojo-coding-guidance` — per-edit Mojo coding contract.
- `.agents/skills/test-driven-development` — the transcript-golden lifecycle and
  parser-testing discipline.
- `.agents/skills/code-review-and-quality` — pre-merge review axes and the
  standing dual-adversarial-review protocol.
- `.agents/skills/improve-architecture` — deep-module thinking on the layering.
- global `mojo-syntax` — the authority on Mojo syntax.
