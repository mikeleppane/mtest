# mtest command-line contract

**Status: DRAFT.** This document specifies the v1 command-line interface of
`mtest`. It is the public API of the tool. Until the v1.0 release it may change;
at v1.0 the surfaces marked **FROZEN** below are frozen and any later change to
them requires a major version bump. The exit-code model is already frozen — it
mirrors pytest's — and will not change. Everything above describes the full v1
target; for what the *current build* actually implements today, see
[§24, Availability status (this build)](#24-availability-status-this-build).

`mtest` is an orchestrator layered on top of Mojo's standard-library
`std.testing.TestSuite`. TestSuite owns discovery, per-test selection, and the
report format *inside* a single file; `mtest` owns everything *between* files:
finding them, building them, running them under supervision, aggregating
results, and reporting them for CI. Where this document says "the runner" it
means `mtest`.

---

## 1. Synopsis

```text
mtest [run] [PATHS...] [flags] [-- BUILD-ARGS...]   # run is the default subcommand
mtest collect [PATHS...] [flags]                    # list node ids, one per line
mtest version
mtest --help | mtest help
```

`run` is the default: `mtest tests/` means `mtest run tests/`. A leading token
that is not a known subcommand is treated as a path or flag for `run`.

---

## 2. The invocation root

Every relative path the runner reports or matches — node ids, `--exclude`
patterns, cache keys, annotation locations, `collect` output — is relative to a
single **invocation root**. In v1 the root is the **current working directory**.

- Path normalization is **lexical only**: `.` and `..` segments are folded
  textually; symlinks are **not** resolved (documented limitation — resolving
  them would make node ids depend on filesystem state). `--root PATH` is
  reserved for a future release.
- An operand (path or node id) that resolves **outside** the root is a usage
  error (exit 4). This keeps every reported path root-relative and portable.

---

## 3. Argument grammar

- Flags may be written `--flag value` or `--flag=value`. Both spellings are
  accepted everywhere a flag takes a value.
- Short flags that take no value may not be bundled in v1 (`-x -q`, not `-xq`).
- Flags and positional paths may **interleave** freely:
  `mtest tests/a.mojo -x tests/b.mojo` is valid.
- Parsing stops at a bare `--`. Everything after it is forwarded verbatim as
  build arguments (equivalent to repeated `--build-arg`), subject to the
  forbidden-argument rule (§8.4).
- A repeatable flag (`--exclude`, `--gate`, `--build-arg`, `-I`, `--precompile`,
  `--serial`) may appear multiple times; each occurrence is one value. Values
  containing spaces are preserved exactly (the runner never re-splits a flag
  value on spaces).
- An unknown flag, a missing required value, or a malformed value is a usage
  error (exit 4), detected before any test runs.

---

## 4. Subcommands and flag applicability

| Flag | `run` | `collect` |
|------|:-----:|:---------:|
| `PATHS...` | ✓ | ✓ |
| `-k STR` | ✓ | ✓ |
| `--exclude GLOB` | ✓ | ✓ |
| `-I PATH` | ✓ | ✓ |
| `--build-arg ARG`, `-- ARGS` | ✓ | ✓ |
| `--precompile SRC[:OUT]` | ✓ | ✓ |
| `--mojo PATH` | ✓ | ✓ |
| `-x`, `--maxfail N` | ✓ | — |
| `-n, --workers N` | ✓ | ✓ |
| `--shard M/N` | ✓ | ✓ |
| `--serial GLOB` | ✓ | — |
| `--timeout`, `--compile-timeout` | ✓ | ✓ (compile only) |
| `--retries N` | ✓ | — |
| `--gate PATH` | ✓ | — |
| `-s`, `--show-output MODE` | ✓ | — |
| `--durations N` | ✓ | — |
| `--junit-xml PATH`, `--gh-annotations` | ✓ | — |
| `--json PATH\|-` | ✓ | — |
| `-q`, `-v`, `--color WHEN` | ✓ | ✓ |
| `--collect-only` | ✓ (→ behaves as `collect`) | n/a |

`collect` compiles files to enumerate their tests, so it honors the build and
selection flags; it does not schedule test execution, so run-time flags
(`-x`, `--maxfail`, `--retries`, `--durations`, `--serial`, reporters) do not
apply. `--timeout` is the one exception: unlike the other run-only flags above,
it is applicable in `collect` mode too, because it also bounds each file's
`--skip-all` collection probe (§5, §6) — a probe is a real process spawn with
the same hang risk as a run.

---

## 5. Paths, node ids, and selection

**PATHS** are files, directories, or node ids:

- A **directory** is walked recursively for files matching `test_*.mojo`, in
  sorted order.
- An **explicit file** operand runs regardless of the `test_*` pattern (the
  pattern gates directory walks only) — so `mtest path/to/my_checks.mojo` works.
- A **node id** has the form `<path>::<test_name>` and selects a single test.
  `::` in a file path is unsupported.
- Default path when no PATHS are given: `tests/` if it exists, else `.`.

**Node-id canonicalization.** Every node id is canonicalized to **root-relative**
form. That canonical form is the single basis for `-k` matching, `collect`
output, deduplication, and every reporter. Duplicate selections (the same test
named twice, or via both its file and its node id) are de-duplicated; a test
runs at most once.

A nonexistent path, or a node id naming a file that exists but a test that does
not, is a usage error (exit 4). That check happens **after** the file's
`--skip-all` collection probe (§6) reports its universe of test names: an
unknown node id is an exit-4 error raised post-probe, before any test body
runs.

**`-k STR`** is a case-insensitive substring filter over node ids. At most one
`-k` is accepted in v1 (boolean expressions are reserved). A `-k` that matches
nothing is not an error by itself, but if it leaves the session with nothing to
run the exit code is 5 (§9).

---

## 6. The test-module contract

A test module must define a `main` that runs its suite through TestSuite's
standard entry point:

```mojo
def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

Any behavioral equivalent is acceptable: it must honor `--skip-all`, `--only`,
and `--skip` as arguments and emit TestSuite's standard report. The runner
relies on that protocol, not on the exact source.

Under `--skip-all`, a conforming module executes **no test bodies** at all — it
reports every test as SKIP without running any of them. The runner relies on
that guarantee to use `--skip-all` as a **collection probe** (§5, §16): a
module whose report under `--skip-all` shows anything other than an all-SKIP
listing fails to qualify as a probe, which is the basis for classifying it as
MALFORMED-SUITE below.

- A file that **fails to compile** yields COMPILE-ERROR (or COMPILE-TIMEOUT if
  the build exceeds `--compile-timeout`).
- A file that **compiles but does not speak the protocol** — no parseable
  report or collection listing — yields **MALFORMED-SUITE**, a *user* error in
  the exit-1 class. This is the module's fault, not the runner's.
- A file that emits a report which is *present but violates the pinned grammar*
  is treated as toolchain **protocol drift**: an internal error (exit 3) whose
  message names the offending expectation. This is reserved for a real
  divergence between the installed toolchain and the version the runner was
  pinned against.

The distinction matters: a broken test file must never be reported as a bug in
`mtest`, and a genuine protocol drift must never be silently swallowed as a user
error.

---

## 7. Toolchain selection

The runner invokes a Mojo toolchain to build and (for `collect`) enumerate.

- Default: `mojo` resolved from `PATH` (the pixi-environment pattern).
- `MTEST_MOJO=/path/to/mojo` overrides the default.
- `--mojo /path/to/mojo` overrides both. The flag wins over the environment
  variable.

A runner must be able to serve projects pinned to different Mojo installs, so
the toolchain is never hard-coded.

---

## 8. Building test files

### 8.1 Run model

Each test file is **built to a binary and the binary is executed directly**. The
runner never uses `mojo run` to execute tests: `mojo run` masks a crashing
process's exit code to `1` (making a crash indistinguishable from a failure) and
can itself JIT-crash in CI. Only a prebuilt binary yields a truthful process
exit code, which is the foundation of the whole outcome model.

### 8.2 `--build-arg ARG` and `-I PATH`

`--build-arg` (repeatable) forwards one argument to `mojo build`, after the
runner's own arguments. Everything after a bare `--` is equivalent. `-I PATH`
(repeatable) adds an include path, forwarded to every build.

### 8.3 `--precompile SRC[:OUT]`

Repeatable. Each `--precompile` package is built with `mojo precompile` **before
any test build**, in the order listed. Precompiled packages inherit `-I` and
`--build-arg`. `OUT` defaults to `build/<name>.mojopkg`, and its directory is
automatically added to `-I` so dependent test files resolve `from <name> import
…`. In v1 precompiled packages are **always rebuilt** (no caching across
invocations — the step is cheap and a wrong cache key is worse than a rebuild).

Each attempt builds to a temp path beside OUT and is renamed onto OUT **only
after it exits 0**, so a killed, crashed, or rejected attempt never touches OUT:
a good package from an earlier run survives a failed step byte-for-byte, and no
dependent ever builds against a half-written package. The step is bounded by
`--compile-timeout` (§18) and gets the same crash-class `--retries` budget as a
file build (§13): up to N extra attempts on a signal, a compile-timeout, or a
compiler-crash signature, each on a fresh temp and a quarantined module cache. A
precompile that only succeeds after a retry is not a FLAKY verdict — there is no
test identity to carry one — but a loud success-after-retry warning.

If a precompile step's attempts are all exhausted, the session ends in
**PRECOMPILE-ERROR**: there is no test identity to attach it to, so the runner
prints one banner naming the ending, lists every test file that depended on it
as a casualty, and exits 1.

### 8.4 Forbidden build arguments

The runner owns its output artifacts and its source list. Build arguments that
would take that control away are rejected as usage errors (exit 4): output
selection (`-o`), emit-type selection (`--emit`), and any **extra source
operand** (a positional path handed to `mojo build`). This applies to
`--build-arg`, to `-I` misuse, and to post-`--` arguments alike.

This build does not manage a build thread budget — there is no worker pool yet
(§24), so a build spends whatever `mojo build` chooses by default. A build
thread-count argument (`-j`, `--num-threads`) is therefore **not** a forbidden
argument today; it is forwarded like any other `--build-arg`. Ownership of the
build's parallelism arrives with the worker pool.

---

## 9. Exit codes

Mirrors pytest, and is **FROZEN**:

| Code | Meaning |
|------|---------|
| 0 | the session ran; every selected test's outcome is PASS or SKIP (exclusions allowed) |
| 1 | at least one selected outcome is FAIL, CRASH, TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT, MALFORMED-SUITE, or PRECOMPILE-ERROR |
| 2 | interrupted (SIGINT/SIGTERM); a partial summary is printed |
| 3 | internal `mtest` error — including protocol drift (a report present but off-grammar), and an environment/I-O failure such as a runtime report-destination open/write failure (a `--json` destination that cannot be opened at session start, or whose stream write later fails — a fatal abort; or a `--junit-xml` target that cannot be created at session start, or whose report cannot be finalized and renamed onto PATH) |
| 4 | CLI usage error (unknown flag, bad value, nonexistent path, unknown node id, forbidden build argument, a syntactically invalid `--json` or `--junit-xml` report destination — an empty value or a nonexistent parent directory, or the machine-stdout conflict — `--json -` without an explicit `--gh-annotations off`, since the byte-pure stream and the annotation tail cannot share stdout) — detected **before any test runs** |
| 5 | no tests collected (empty walk, `-k` matched nothing, everything excluded) |

**Precedence** when outcomes mix. A usage error aborts before the run with 4.
Otherwise: an interrupt dominates (→ 2); else an internal error (→ 3); else any
failing outcome (→ 1); else nothing collected (→ 5); else 0. A user interrupt
outranks an internal error because the run was truncated on purpose and its
result is no longer authoritative.

A `--shard` (§18) that owns no run files reaches exit 5 by the same
nothing-collected rule — but only when nothing else ran: a shard whose gates ran
(gates are never sharded) exits by its gate results, so exit 5 means *neither* a
gate *nor* a shard-owned file ran.

---

## 10. Outcome model

### 10.1 Reported outcomes

`PASS`, `FAIL`, `SKIP` (the suite itself skipped the test), `CRASH` (death by
signal or `abort`), `TIMEOUT`, `COMPILE-ERROR`, `COMPILE-TIMEOUT`,
`MALFORMED-SUITE`, and the session-level `PRECOMPILE-ERROR`. A pass produced only
after one or more retries is annotated **FLAKY**.

**A crash is not a failure.** An assertion that fails (FAIL) and a process that
aborts or dies by signal (CRASH) are different events with different causes, and
they stay distinct in the summary, the JUnit XML, the annotations, and the exit
code.

**Selection-induced SKIPs are suppressed.** When the runner uses `--only`/
`--skip` internally to select tests, TestSuite reports the non-selected tests as
SKIP. Those are protocol artifacts, not user-facing skips, and are removed from
results and reporters. Only a test the suite *itself* skipped is reported SKIP.

### 10.2 Internal states

The internal model additionally distinguishes states that keep parallel and
interrupted sessions honest, even though they are not per-test "outcomes":

- **DESELECTED** — removed by `-k` or node selection. Counted in one summary
  line, never listed individually.
- **EXCLUDED** — removed by `--exclude`. Reported loudly on the console (never
  silent).
- **SHARDED-OUT** — a run file assigned to a different `--shard` (§18). Counted
  in the session header (how many files this shard did not own), never listed
  individually — the other shards run them, so naming each here would be noise.
- **NOT-RUN** — never scheduled because `-x`, `--maxfail`, or an interrupt
  truncated the session. Shown in the summary so a truncated run can never
  masquerade as a complete one.

### 10.3 Crash attribution honesty

When the runner reruns a crashed file's tests in isolation to attribute the
crash to a specific test and the crash does not reproduce (an order-dependent
crash can pass every test in isolation), the file-level CRASH **stands
unattributed**. The runner never blames every test and never manufactures
certainty. The file-level CRASH outcome is always authoritative; isolation
reruns are secondary diagnostic evidence only.

The attribution pass runs **after** the main session and is strictly bounded, so
a pathological crasher can never hang the run: at most **32 isolation reruns per
file**, each with a deadline of `min(--timeout, 60)` seconds, under a **120 s
per-file** and **600 s per-session** wall-clock budget (checked before each
rerun). Every crashed file ends with a typed stop reason — **attributed** (a
single culprit reproduced), **no-reproduction** (isolation stayed green),
**probe-failed** (an isolation rerun could not even be built or spawned),
**run-cap** (the 32-rerun ceiling), or **time-budget** (a wall-clock budget) —
and the file-level CRASH stands regardless. Isolation reruns are never subject to
`--retries`, and the whole pass is **skipped under interrupt** (a truncated run's
attribution is not worth the delay).

---

## 11. Stopping early

- `-x`, `--exitfirst` — stop *scheduling* new files after the first failing
  file. Files already in flight finish.
- `--maxfail N` — stop after N failing **tests**. A file-level error outcome
  (crash, timeout, compile error, malformed suite) counts as one. `N=0` means
  no limit — the same 0-disables convention as `--timeout` and `--durations`.
  Only a **final** failing outcome counts: a test that crashed on an earlier
  attempt but passed on retry is FLAKY (§13), a pass, and contributes **0** to
  the `--maxfail` tally.
- `--gate PATH` (repeatable) — gate files run **first**, and a gate failure
  aborts the whole session immediately, regardless of `-x`. This is the
  smoke-test-first pattern: don't spend the pool if the smoke test is red.

---

## 12. Exclusions

`--exclude GLOB` (repeatable) removes files from the run:

- The pattern is an `fnmatch`-style glob (`*`, `?`, `[...]`), matched against the
  **root-relative** path. Note that `fnmatch`'s `*` may cross `/` (documented). A
  plain path (no glob metacharacters) matches by exact equality.
- Every exclusion prints a **loud SKIP line** — an excluded file is visibly
  reported, never silently dropped.
- An exclusion pattern that matches **nothing** prints a loud stale-exclusion
  warning (a stale exclude usually means a renamed file is silently running
  again, or was meant to be excluded and no longer exists).
- On conflict, an exclusion **wins** over `--gate` and over an explicit path
  operand — loudly.

---

## 13. Retries and flakiness

`--retries N` (default 0) retries **crash-class steps only**. N is the number of
*additional* attempts (N+1 total), and the loop resumes from the step that
failed — a run that crashes is re-run against the already-built binary, not
rebuilt.

- **Crash-class**, on the **run** step, is termination by signal or a deadline
  kill (a `--timeout` expiry). On a **build** or **precompile** step it is
  termination by signal, a `--compile-timeout` expiry, **or** a nonzero exit
  whose stderr carries a compiler-crash signature (an ICE banner or stack dump).
  Everything else is deterministic and is **never** retried: any run that exited
  under its own control (a failing assertion, a `worse-of` disagreement, a
  capture-overflow FAIL), an ordinary compile error (a nonzero exit with no
  crash signature), a spawn failure, and an interrupt.
- Each attempt uses a fresh output path; after a **compile** kill the rebuild
  runs against a quarantined per-attempt module cache, since a killed compile
  can corrupt the shared one. Each attempt is bounded by the same `--timeout` /
  `--compile-timeout` budget as the first.
- Every attempt's diagnostics are retained in the report. The **last** attempt's
  outcome is authoritative. A test that passes only after a retry is reported
  **FLAKY** and, being a pass, exits 0 and by default passes CI
  (`--fail-on-flaky` is reserved).

Retries apply to precompile, build, and run steps. In this build the full
build-and-run retry is wired on the default (non-selection) run path; crash-class
**run** retries also apply under selection (`-k` or a node id), but build-side
retries under selection are not yet wired (§24.3).

---

## 14. Output capture

Child stdout and stderr are captured separately and byte-exactly.

- `--show-output MODE`: `failures` (default) shows captured output for FAIL and
  crash-class outcomes; `all` shows it for every test; `none` suppresses it.
- `-s` is an alias for `--show-output all`.
- `--show-output` governs the **console's** display of captured output only; the
  machine reporters (`--junit-xml`, §15.2; `--json`, §15.4) carry capture per
  their own bounded, always-on rules, unaffected by this flag.

---

## 15. Reporters

### 15.1 Console

`-q` (quiet: files plus summary) and `-v` (verbose) are mutually exclusive.
`--color WHEN` is `auto|always|never`; `NO_COLOR` is respected, and the flag
wins over it. The console summary is ordered deterministically (§17), not by
completion order. Console text layout and color are **informal** and may change.

**Console destination.** The console writes to **stdout** by default, and to
**stderr** when `--json -` owns stdout for the byte-pure event stream (§15.4) —
one resolved destination through which every console byte flows, so a `--json -`
run's stdout carries only stream lines. `--color auto` decides against that
**resolved** destination: stdout's terminal-ness normally, stderr's when the
console is relocated there.

There is **no live progress counter** in this build (a running `k/n` line, which
arrives with the worker pool); a file's result prints when the file finishes, and
the summary band, the slowest-files list, and the failure detail (per-attempt
`TRY` lines from `--retries`, verdict blocks) all print at completion. The
deterministic surfaces (§17) — the summary band and the sort *order* of any list
— never depend on completion order.

**The `SLOW` annotation.** A build or run step whose wall time reaches **60 s**
is flagged `SLOW`. It is an **informal** annotation, never an outcome: it does
not appear in the outcome vocabulary (§10.1), never changes a verdict or the
exit code, and is not part of the §17 determinism guarantee. Under `-v` the note
names *which* step (build or run) crossed the threshold and its duration, so a
comptime-stalled compile is visible at 60 s rather than only at the 600 s
compile deadline.

**Slowest files — `--durations N`** (`N` a non-negative integer). After the
summary band, print the `N` slowest **files** by run-only wall-clock (the process time for the run step
alone; build time is not counted). The header states the *actual* number of
rows printed — `min(N, files that ran)` — never the raw requested `N`. This
list is **informal** (§20), like the rest of the console reporter, and is
explicitly **not** part of the §17 determinism guarantee: its content tracks
real elapsed time, which varies run to run, even though the sort itself
(duration descending, path ascending on ties) is deterministic for a given set
of durations. An explicit `--durations` survives `-q` — it prints even in
quiet mode. `N=0` (the default) disables the list. `--durations` is a
**run-only** flag; combining it with `collect` is a usage error (§4).

### 15.2 JUnit XML — `--junit-xml PATH`

`--junit-xml` is **served**: it writes a JUnit XML report — the settled
junit-10 dialect (`scripts/schemas/junit-10.xsd`), the same the committed
`scripts/junit_check.py` oracle blesses — assembled from the runner's own typed
events, never from a parse of the console text.

- **Document shape.** One `<testsuites>` root carrying `name`, `tests`,
  `failures`, and `errors` — and **not** `skipped` (junit-10 defines no root
  `skipped`; the root skipped total is an arithmetic fact recomputed from the
  child suites). One `<testsuite>` **per file**, carrying all four aggregate
  counts (including `skipped`). Each `<testcase>` carries `name` and `classname`
  (the file's dotted stem) and, optionally, ONE primary outcome child
  (`failure`/`error`/`skipped`) plus any number of ordered rerun/flaky children.
- **Outcome mapping**, total over the vocabulary:

  | Outcome | XML |
  |---------|-----|
  | PASS | `<testcase>` (no child) |
  | FAIL | `<testcase>` with `<failure>` (the verbatim assertion detail) |
  | SKIP | `<testcase>` with `<skipped/>` |
  | CRASH | `<testcase>`/sentinel with `<error>` |
  | TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT, MALFORMED-SUITE, PRECOMPILE-ERROR | sentinel `<testcase>` with `<error type="...">` |

- **Sentinels.** A file-level outcome (no single test identity) attaches to one
  synthesized sentinel testcase inside that file's suite: `[build]` for a
  non-retried file-level failure, or `[attempts]` for a retried one. The two are
  **mutually exclusive** — a suite carries at most ONE outcome-carrying
  sentinel, or none when per-test rows already carry the verdict. A precompile
  failure emits its own `mtest::precompile` suite with a `[precompile]` error,
  plus one `[not-run]` suite per NAMED casualty; a bare casualty count with no
  names invents no rows. A file that was selected but never ran — a precompile
  casualty, or an interrupt/`--maxfail`/gate-abort skip — appears as a
  synthesized `[not-run]` skipped testcase, so the report is total over the
  selected set.
- **Retries and flakiness** ride Surefire chronology in the `[attempts]` row: a
  flaky pass carries one `<flakyFailure>` per earlier failed attempt (in attempt
  order); a rerun-exhausted failure carries the FIRST failed attempt as the
  primary and every later attempt (the final included) as a `<rerunFailure>`/
  `<rerunError>`. Every rerun/flaky child carries the schema-required `type`.
- **Capture.** Captured child output attaches once per suite as
  `<system-out>`/`<system-err>`, bounded (64 KiB head + 64 KiB tail, elision
  marked) and always-on — independent of `--show-output`, which governs only the
  console (§14). All text is XML-escaped through the one shared path; a sentinel
  `name` (`[build]`, `[attempts]`, `[not-run]`) is emitted verbatim.
- **Time.** Suite-level `time` is the runner's own wall clock per file, formatted
  as fixed-three-decimal seconds (JUnit's own policy, distinct from the JSON
  stream's integer microseconds). Per-testcase `time` and suite `timestamp` are
  **omitted** (schema-optional) while upstream per-test timings are untrustworthy
  (honesty over decoration).
- **Ordering is deterministic**: testcases are sorted by node id, and suites by
  their key, independent of completion order. A testcase whose `name` already
  contains `::` is its own node id (used verbatim); a bracket sentinel is keyed
  as `<file>::[sentinel]` but never renamed.
- **Artifact lifecycle.** A unique temp file is created in the TARGET directory
  at session start — proving it writable BEFORE any build or run — and the
  assembled document is written there and renamed **atomically** onto PATH only
  after a verified complete write. Unlike the live `--json` stream, the prior
  report at PATH is **NEVER truncated**: on any failure the target is left
  exactly as it was. A syntactically bad destination (an empty value or a
  nonexistent parent directory) is a pre-run usage error (exit 4, §9); a runtime
  creation or finalization failure (an unwritable or vanished target) is an
  internal error (exit 3, §9). Report destinations are not root-constrained.

### 15.3 GitHub annotations — `--gh-annotations MODE`

`--gh-annotations` is **served**: it emits GitHub Actions annotation
workflow-command lines to **stdout**, in a deterministic tail after the console
summary band. `MODE` is `off|on|auto`; **`auto` (the default) is on iff
`GITHUB_ACTIONS=true`**, `on` always renders, `off` never does. The tail renders
only when resolved-on.

**The frozen annotation shapes**, one clear entry per kind:

- **Per-test FAIL** → `::error file=<f>,line=<l>::<node id>: <first assertion
  line>`. `line=` is present **only** when that first line itself carries a
  recognizable `At <path>:<line>:<col>:` backtrace pointer (the same shape the
  console renders root-relative); a detail with no such pointer (e.g. a bare
  `raise`) omits `line=` rather than guess one — **location honesty**: `line`
  appears only where the assertion detail carried it, and `file=` paths assume
  the invocation root is the repo root.
- **Crash-class / file-level** (CRASH, TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT,
  MALFORMED-SUITE) → `::error file=<f>::<f>: <outcome in words>`. Never carries
  `line=` (there is no per-test location for a whole-file abnormal outcome). A
  plain per-test FAIL file is covered entirely by its per-test rows above.
- **FLAKY** → `::warning file=<f>::<f>: flaky — passed on attempt K of N`.
- **Precompile failure** → one `::error::<step>: …` with **no** `file=` property:
  the failure belongs to the STEP, not any one file; the casualty files appear as
  JUnit rows, not per-file annotations, so an annotation flood never burns the
  error cap on a derivative fact.
- **The summary notice** → exactly **one** `::notice::<band text>` per run, never
  subject to the caps.

**Level mapping**: failing → `::error`; FLAKY → `::warning`; the single run
summary → `::notice`.

**The tail is PER-KIND GROUPED**, each block node-id-sorted: the whole
node-id-sorted `::error` block, then the whole node-id-sorted `::warning` block,
then the single `::notice`. This is **not** a global node-id interleave across
error and warning lines — the per-kind caps and the cap-minus-one aggregate line
make per-kind grouping the deterministic, unambiguous form.

**Bounds**. Each payload is escaped via the message escaper (`%`→`%25`,
CR→`%0D`, LF→`%0A`) and each `file=` value via the property escaper (adds
`:`→`%3A`, `,`→`%2C`); user-controlled paths, names, and assertion text are never
interpolated raw into a workflow command, and an escaped-away CR/LF means a
would-be forged second command line can never form. Each message is bounded to
**4096 escaped bytes** (measured after escaping), with a truncation marker when
cut. The **per-run per-STEP caps are 10 errors and 10 warnings** (a workflow STEP
is capped at 10 error and 10 warning annotations; the "50" some readers conflate
is the Checks **API**'s own per-request limit, a REST surface mtest never calls);
past the cap the first `cap - 1` sorted rows render individually and one
**aggregate** line (`… and N more …`) replaces the rest, so a block never exceeds
its cap.

**Stop-commands FENCING of echoed child output.** Whenever `GITHUB_ACTIONS=true`
— independent of `MODE`, even `off` — every echoed region of captured **child**
output the console renders (captured stdout/stderr under `--show-output`, failure
and precompile excerpt regions) is wrapped in `::stop-commands::<token>` …
`::<token>::` fencing, so a child's own `::error`-shaped bytes cannot forge a
workflow command. The token is **high-entropy** (≥128-bit random, from
`/dev/urandom`), **per-run-unique**, minted **after** the producing child has
exited, never exposed to any child (not in its env or argv), and **regenerated**
until the complete resume delimiter `::<token>::` is absent from the region being
fenced. Restoration runs through an **always-runs epilogue**: a final resume
delimiter is emitted before mtest's own annotation lines, so no error or
partial-write path can leave workflow commands disabled or a fence unterminated.

A **PRECOMPILE-ERROR** annotates with **no** `file=` (the failure belongs to the
step; its casualties appear as JUnit rows, not per-file annotations).

**The `--json -` interplay.** `--json -` makes stdout the byte-pure event stream,
which the annotation tail cannot share. Beside `--json -`, annotations must be
**explicitly `off`** — the only combination that runs. Both an explicit
`--gh-annotations on` and the **default `auto`** are usage errors (exit 4, §9),
detected at parse time, and the message names both fixes (drop `--json -`, or set
`--gh-annotations off`). `--json PATH` does not own stdout, so annotations may
ride alongside it.

### 15.4 Machine event stream — `--json PATH|-`

`--json` is **served**: it writes a newline-delimited stream of the runner's own
typed events — the same events the console reporter consumes — to `PATH`, or to
stdout when the value is `-`. `docs/json-stream.md` is the **normative** spec;
this section summarizes it.

- **Framing and header.** NDJSON: one complete JSON object per `\n`-terminated
  line, valid escaped UTF-8, no floats (`Infinity`/`-Infinity`/`NaN` never
  appear). Line 1 is the frozen header `{"event":"stream","version":1,
  "generator":"mtest <version>"}`.
- **Events.** The stream mirrors every session event the console reporter sees,
  with the `progress` kind **excluded** (there is no live progress in this build,
  §15.1). Each record mirrors the model's payload 1:1 under its own field names.
- **`*_us` durations.** The sole naming exception: every `*_seconds` duration is
  emitted as an integer-microsecond `*_us` field, so the stream carries no
  floating-point value.
- **Ordering.** An informal timeline with frozen split invariants: per session,
  header → `session_started` → precompile records → per-file events →
  `crash_attribution` → `session_finished` last; per file, contiguous
  `test_reported` rows and monotonic `attempt_finished` records precede that
  file's `file_finished`.
- **Terminal.** Exactly one `session_finished` is dispatched in every scenario
  (normal, interrupt, fatal abort), carrying the final `exit_code`. The stream
  therefore carries zero-or-one terminal record: its **absence** (or a torn final
  fragment) is the truncation signal.
- **Determinism.** Two runs of the same inputs are equal under a closed
  projection (outcomes, per-test sets, counts, dispositions, flags, casualty
  lists, totals, exit code); the byte-payload fields with their omission metadata
  and every measured `*_us` duration are excluded from that comparison.
- **Writes and SIGPIPE.** Each line is drained through a `write_all` loop, so a
  cut stream leaves complete lines plus at most one torn final fragment. SIGPIPE
  is ignored for the run; a latched stream-write failure (a `--json -` consumer
  that closed early, a full or unwritable destination) is a **fatal abort** to
  exit 3, never death at 141.
- **Destinations.** `-` makes stdout the byte-pure stream (the console relocates
  to stderr, §15.1). A `PATH` is written live and a pre-existing file is
  **overwritten** at session start (a live stream cannot rename atomically, so
  this differs from JUnit's atomic write, §15.2); report destinations are not
  root-constrained. A syntactically bad destination is a pre-run usage error
  (exit 4, §9); a runtime open failure is a pre-run internal error (exit 3, §9).
- **Versioning.** Version 1 freezes the framing, header, event names, field
  meanings, and vocabularies. Growth is additive (new fields and kinds);
  consumers **must ignore** unknown fields and kinds. A removal or
  meaning-change bumps the header version; the version lives only on the header.

`--json` is a **run-only** flag in v1 (§4).

---

## 16. `collect`

`mtest collect [PATHS] [flags]` (and `mtest --collect-only`) lists node ids, one
per line, sorted **lexicographically**. The runner imposes its own order so the
frozen output format never couples to TestSuite's discovery order (execution
still uses discovery order internally). `collect` accepts the selection and
build flags because it compiles files to enumerate them.

Per file, the build-then-probe (§5, §6) resolves one of four ways:

- A **qualifying** probe (an all-SKIP report, §6) contributes its node ids to
  the listing.
- A **compile error, a crash, a timeout, or MALFORMED-SUITE** (§6) writes a
  diagnostic to stderr and the listing **continues** with the remaining files
  — MALFORMED-SUITE during `collect` is in the same **exit-1 class** as it is
  during a run.
- A **protocol-drift** probe (a report present but off-grammar, §6) is an
  internal error and forces **exit 3**; the listing still diagnoses the
  remaining files to stderr, but the session cannot exit anything but 3.
- An internal/machinery failure (e.g. an unspawnable build) **aborts** the
  listing outright at **exit 3**.

The session exit code is **3** if any drift or internal failure occurred, else
**1** if any file failed to collect (compile error, crash, timeout, or
MALFORMED-SUITE), else **5** if nothing was collectable, else **0** —
consistent with the §9 precedence, under which an internal error (→ 3)
dominates a failing outcome (→ 1), which dominates "nothing collected" (→ 5).

---

## 17. Determinism

Given the same inputs, `mtest` orders every machine and console surface
deterministically — the console summary, the `collect` listing, and the
`--junit-xml` document are all sorted by node id, independent of the order in
which files or parallel workers finished. Parallelism never changes *what* is
reported, only how fast.

That shared ordering does not mean every surface is byte-identical across runs;
each below states its actual promise, scoped precisely:

- **`collect`** output stays **byte-identical** across runs of the same inputs:
  the frozen listing (§16, §20) carries no wall-clock or captured-text content
  to vary.
- **`--junit-xml`** (§15.2) is deterministic in **structure, identity,
  classification, and counts** — the `<testsuite>`/`<testcase>` shape, node-id
  names, `classname`, the `message`/`type` attributes on outcome children, and
  the `tests`/`failures`/`errors`/`skipped` aggregates — but it is **not**
  byte-identical: `time` (the runner's own wall clock, §15.2) and every embedded
  captured/diagnostic text body (`system-out`/`system-err`, a `failure`/`error`
  detail, a stack trace, a rerun/flaky child's text) are exactly the payload
  classes the `--json` projection excludes below, and the committed
  canonicalizer masks precisely those two classes before comparing two runs'
  documents.
- **`--json`** (§15.4; normatively `docs/json-stream.md` §10) promises equality
  under a **closed projection** — outcomes, per-test sets, counts, dispositions,
  flags, casualty lists, totals, and the final exit code — never byte order and
  never a duration or byte-payload field. Two runs' raw streams may differ line
  for line while still agreeing on that projection.

§17 carries no byte-identity claim over anything wall-clock- or payload-bearing:
not `--junit-xml`'s `time` or embedded captured/diagnostic text, and not
`--json`'s measured `*_us` durations or its capture/argv/casualty payload
fields.

---

## 18. Concurrency

`-n, --workers N|auto` sets the worker count. `auto` sizing is runner-chosen and
may tune across minor versions. Because `mojo build` is itself multi-threaded,
`auto` is conservative (stacked cold compiles starve each other). The worker
pool is a later concurrency milestone: **`-n`/`--workers` is not served in this
build** (§24), which runs files sequentially.

`--timeout SECS` (default 300, `0` disables) bounds a single file's **run**;
exceeding it yields TIMEOUT. `--compile-timeout SECS` (default 600, `0`
disables) bounds a single file's **build**; exceeding it yields COMPILE-TIMEOUT
with a hint to split the module or exclude it. It kills after the same
signal-first sequence with a compile-specific grace (~5s longer than a run kill,
since a compiler unwinds more slowly). Timeout kills are signal-first (a
terminate signal, then a grace period, then a hard kill) and reach the owned
process group, not just the direct child. A descendant that deliberately leaves
that group (for example, with `setsid()`) cannot be killed by the group sweep;
if it retains a capture pipe past the bounded cleanup deadline, the run is
reported as an internal cleanup error, never as a pass.

**`--shard [hash:|slice:]M/N`.** Splits the discovered RUN-file set into `N`
disjoint shards and runs only shard `M`'s files, for spreading one suite across
parallel CI jobs. `1 <= M <= N`; a malformed value is a usage error (exit 4).
The partition is applied to the **post-exclusion** run-file universe **before
any build**, so a sharded-out file is never compiled. Two modes:

- **`hash:` (the default).** A file is owned by shard `M` iff
  `fnv1a64(path) % N == M-1`, where `fnv1a64` is canonical FNV-1a 64-bit (frozen
  offset basis `0xcbf29ce484222325`, prime `0x100000001b3`) over the **lexical
  root-relative** NodeId path exactly as discovery produced it — never a
  realpath. Assignment depends only on the path bytes, so it is stable across
  machines and independent of discovery order.
- **`slice:`.** The eligible files, already sorted lexicographically, are dealt
  round-robin: the file at sorted index `i` is owned iff `i % N == M-1`.

Sharding applies to both `run` and `collect` (§4) — sharding what gets
collected, not only what gets run. **Gates are never sharded**: every gate file
runs on every shard, so the smoke-test-first guarantee holds per job. Node-id
operands are validated against the owning shard only — a node id naming a file
this shard does not own is not this shard's to reject. Sharded-out files are
**counted, not listed** (§10.2), and a shard that owns no run files falls under
the empty-collection exit code (§9).

**`--serial GLOB` (not yet served, repeatable).** Pins every file matching
`GLOB` to run outside the parallel pool, one at a time, for suites with a
shared resource (a port, a device) that cannot tolerate concurrent access.
Each occurrence adds one glob pattern; `--serial` is a **run-only** flag (§4).
It is part of the frozen v1 contract, recognized by the parser, but refused
before any test runs (§24) — it ships with the worker pool, since serial
pinning is only meaningful once tests would otherwise run in parallel.

---

## 19. Help and version

- `mtest --help`, `mtest -h`, and `mtest help` print usage to **stdout** and exit
  **0**.
- `mtest version` and `mtest --version` print the version to **stdout** and exit
  **0**.
- A usage **error** prints to **stderr** and exits **4**.

---

## 20. Stability tiers

- **FROZEN at v1.0** — subcommands; flag names and semantics; exit codes; the
  node-id grammar; the JUnit mapping; the annotation shapes; the `--json` event
  stream schema (§15.4; normatively `docs/json-stream.md`) — its framing,
  header, event and field names, and token vocabularies, frozen at stream
  `version` 1 and growing only additively (new fields and kinds; a removal or a
  meaning-change bumps the header version); the `collect` format; the
  test-module contract.
- **STABLE-INTENT** — default values (timeouts, `auto` worker sizing) may be
  tuned in minor versions.
- **INFORMAL** — console text layout and colors.
- TestSuite invocation details are an internal seam, never public API.

---

## 21. Reserved (documented as reserved, not in v1)

The following are out of scope for v1 and reserved for a later major version
(vNext); each is either unrecognized by the parser, or recognized-but-refused
as noted:

`--root`; `--lf`/`--ff` (last/failed-first); boolean `-k` expressions; a config
file (TOML subset or argfile); `--pattern`; a **per-test** granularity for
`--durations` (the slowest individual *tests*, not just files — blocked on the
same upstream per-test timing gap that blocks per-test attribution elsewhere;
the file-level `--durations N` is itself served now, §15.1); markers /
`xfail`; `--asan`; `--shuffle` (file-order randomization to surface order
dependencies); `--fail-on-flaky`; watch mode; and a **persistent**
build/collection cache (`--cache-dir`/`--no-cache`). Within one session the runner builds each file
once and reuses it (`collect` and `run` share the binary), but nothing
persists across invocations in v1: a trustworthy-verdict tool does not ship
"fast but possibly stale", and a correct cache key (transitive source closure,
environment inputs, target triple, schema version, concurrent-writer safety)
is its own deliverable.

---

## 22. Platforms

Linux and macOS are the v1 targets. Linux carries the native lifecycle,
process-supervision, and dynamic memory-analysis gates. macOS arm64 carries a
native post-fork call-graph audit plus package build, executable link, and
`--help` smoke coverage; runtime supervision remains unverified there. Platform
divergence in crash reporting is absorbed by the structured termination model
(a terminating signal is recorded as a signal, never as a shell-encoded
`128+N`).

**The packaged artifact.** The distribution recipe builds `mtest` **in-env from
source**, inside an isolated build environment pinned to the same
`mojo`/`clang` versions this repo itself builds against — the prebuilt-binary
branch (repackaging an already-linked executable) is **not** taken. The
installed binary is not loader-clean: it carries a direct link dependency on
the Mojo runtime's shared libraries, whose transitive closure is owned by the
`mojo-compiler` conda package, so the recipe declares `mojo-compiler ==1.0.0b2`
as a **conda run dependency** rather than vendoring those libraries — a fresh
environment carrying only that declared dependency (not the full build
toolchain) is proven sufficient to load and run the installed binary.
**linux-64 is the gated platform**: a dedicated CI job builds the package into
a local channel, installs it into a scratch environment from that channel, and
exercises the installed binary. **osx-arm64 is declared, not gated**: it
matches the recipe's and the build tool's platform list and the package
channels solve for it, but no CI runner builds or installs the packaged
artifact there — macOS coverage stops at package build, executable link, and
an `--help` smoke run (the same ceiling stated above), so packaged-artifact
runtime supervision on macOS is a documented ceiling, not a proven target.

---

## 23. Worked examples

```text
# Run the default suite (tests/ if present, else the current directory).
mtest

# Run one directory, stop scheduling after the first failing file.
mtest tests/ -x

# Run a single test by node id.
mtest tests/test_math.mojo::test_addition

# Substring-filter to matmul tests, show output for all of them.
mtest -k matmul -s tests/

# Precompile a library, smoke-test first, exclude the slow suite, forward a
# build flag — the whole configuration lives on the command line.
mtest --precompile src/mylib:build/mylib.mojopkg -I build \
      --build-arg=--no-optimization --gate tests/test_smoke.mojo \
      --exclude 'tests/test_slow_*.mojo' tests/

# Produce CI artifacts.
mtest --junit-xml report.xml --gh-annotations auto tests/

# Machine-readable run for tooling — the versioned event stream to a file.
mtest --json report.ndjson tests/

# List node ids without running anything.
mtest collect tests/
```

---

## 24. Availability status (this build)

Everything above is the full frozen-intent v1 contract. This section is
different in kind: it states what the *current build* actually implements,
today, so a reader can tell shipped behavior from target behavior without the
contract above changing at all. Nothing in this section alters any flag
semantic, exit-code meaning, node-id grammar, or outcome vocabulary defined
above — it only reports which of those surfaces are wired up yet.

### 24.1 Flags and subcommands

**Served** (parsed into real behavior): positional `PATHS`, `-k`, `--exclude`,
`-I`, `--build-arg` (and post-`--` passthrough), `--precompile`, `--mojo`,
`-x`/`--exitfirst`, `--maxfail`, `--timeout`, `--compile-timeout`, `--retries`,
`--shard`, `--gate`, `-s`/`--show-output`, `--durations`, `-q`/`-v`, `--color`,
`-h`/`--help`, `--version`, and the `run`, `collect`, `version`, and `help`
subcommands (`--collect-only` too, as an alias that behaves as `collect`).
`--shard` applies under both `run` and `collect`. `--json` (the machine event
stream, §15.4), `--junit-xml` (the JUnit report, §15.2), and `--gh-annotations`
(the CI annotation tail, §15.3) are served too — see §24.2 for how they are now
reached.

**Still refused**: `-n`/`--workers`, `--serial`. Each is recognized by the
parser — it knows the spelling and its arity — but is **refused before any test
runs**, with a usage error that names the flag, states that it is part of the v1
contract, names the capability that brings it (`-n`/`--workers` arrive with
parallel workers; `--serial` arrives with serial execution pinning), and lists
what this build does serve.

**A transitional exit-4 subcase.** That refusal is a usage error and exits 4,
but it is a distinct, *temporary* subcase of §9's exit code 4 — it is not one
of the causes the frozen table enumerates (unknown flag, bad value,
nonexistent path, unknown node id, forbidden build argument). It exists solely
because this build has not yet wired up every v1 surface; a flag that this
build does not serve is treated as a usage error rather than silently
accepted or silently ignored. As each surface above lights up, its refusal
disappears — once every flag and subcommand in the frozen contract is served,
this subcase no longer applies and exit 4 reverts to exactly its frozen
causes.

### 24.2 Exit codes reachable in this build

Semantics are unchanged from §9; this states which paths to each code exist
today.

- **0** — reachable: every run outcome is PASS or SKIP (exclusions allowed).
- **1** — reachable for FAIL, CRASH, TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT,
  MALFORMED-SUITE, and PRECOMPILE-ERROR. FLAKY (a pass produced only after a
  crash-class retry) is also emitted now, and, being a pass, does **not** raise
  the exit code — a FLAKY-only session exits 0.
- **2** — reachable: an interrupt (SIGINT/SIGTERM) is implemented with
  sequential-session semantics — a partial summary is printed, the files
  that had not yet started are reported NOT-RUN, and the active child's
  process group is cleaned up. The parallel-workers interrupt story arrives
  with parallel workers.
- **3** — reachable via a spawn failure (the runner could not spawn `mojo` or
  a built binary), via protocol drift (a report present but off-grammar,
  §6) in both `run` and `collect`, and via a runtime `--json`
  report-destination failure (§9): the destination could not be opened at
  session start, or a stream write later failed (a dead `--json -` pipe, a full
  or unwritable file) and the run was fatally aborted.
- **4** — reachable for every frozen cause in §9 — now including a syntactically
  invalid `--json` destination (an empty value or a nonexistent parent
  directory), detected pre-run — plus the transitional not-yet-available-flag
  refusal subcase in §24.1 above.

**`--json` reachability.** `--json PATH|-` is served (§15.4): it is parsed into a
live event-stream reporter composed beside the console. Its destination is
validated syntactically at parse time (exit 4 on an empty value or a nonexistent
parent directory) and opened at session start (exit 3 on a runtime open failure);
a stream write that fails mid-run is a fatal abort to exit 3. The §9 causes are
cited here, never restated.

**`--junit-xml` reachability.** `--junit-xml PATH` is served (§15.2): it is
parsed into a JUnit report reporter composed beside the console and the stream.
Its destination is validated syntactically at parse time (exit 4 on an empty
value or a nonexistent parent directory) and a unique temp is created in the
target directory at session start to prove it writable (exit 3 on a runtime
creation failure). Unlike the stream, a spool failure never aborts mid-run; it
surfaces at finalization, where the report is assembled and renamed atomically
onto PATH (exit 3 on a finalization failure, with the prior report never
truncated). The §9 causes are cited here, never restated.

**`--gh-annotations` reachability.** `--gh-annotations off|on|auto` is served
(§15.3): it is parsed into a self-gating annotations reporter composed beside the
console, the stream, and the JUnit report. `auto` (the default) resolves on iff
`GITHUB_ACTIONS=true`; the tail renders to stdout after the console band only when
resolved-on. Beside `--json -` it must be explicitly `off` — the default `auto`
and an explicit `on` are usage errors (exit 4) detected at parse time (§9). The
stop-commands fencing of echoed child output is active whenever
`GITHUB_ACTIONS=true`, independent of the mode.
- **5** — reachable via an empty walk, via the everything-excluded case, and
  via deselection (`-k` matched nothing, §9).

### 24.3 Selection and parsing deviations in this build

A few surfaces behave more permissively, or cover less ground, today than the
frozen contract above describes. Each is stated here so shipped behavior can be
told from target behavior; none changes a flag semantic, exit code, or the
node-id grammar, and all converge to the contract as the runner matures.

- **`collect` does not narrow by per-test selection yet.** §4 lists `-k` as
  applicable to `collect`, and §16 says `collect` honors the selection flags.
  This build does not yet apply per-test selection to the `collect` listing: a
  `-k` under `collect` prints a loud `-k is ignored in collect mode` notice and
  lists every node id in the discovered files, and a `PATH::TEST` node-id operand
  contributes its whole **file** to the listing rather than the single test.
  `collect` still honors path/directory operands, `--exclude`, `--precompile`,
  `-I`, and the other build flags — only the per-test narrowing is deferred. A
  `run` **does** honor `-k` and node-id narrowing; this deviation is
  `collect`-only. (Narrowing `collect` by `-k` — the `pytest --collect-only -k`
  workflow — arrives with the same selection plumbing.)
- **A repeated single-valued flag takes the last occurrence.** §3 enumerates the
  repeatable flags (`--exclude`, `--gate`, `--build-arg`, `-I`, `--precompile`,
  `--serial`); every other flag is single-valued. The frozen intent is
  at-most-one — e.g. §5 says "at most one `-k` is accepted in v1". This build
  does not yet reject a repeated single-valued flag (`-k`, `--maxfail`,
  `--timeout`, `--color`, `--show-output`, `--durations`, `--mojo`): it silently
  uses the **last** occurrence (so `-k a -k b` filters by `b`, not `a or b`).
  Until the at-most-one check is enforced (a usage error, exit 4), do not rely on
  repeating these flags. The mutually-exclusive `-q`/`-v` pair is already
  rejected as a usage error; the single-valued-flag check follows the same shape.
- **`--retries` does not rebuild under selection yet.** On the default
  (non-selection) run path, `--retries` (§13) retries the full step chain — a
  crash-class **build** or **precompile** kill is rebuilt, and a crash-class
  **run** is re-run. Under selection (`-k` or a node id), only crash-class
  **run** retries are wired: a run that dies by signal or a deadline is re-run
  against the already-built binary, but a build-side crash-class failure is not
  retried on the selection path. The classification and FLAKY reporting are
  otherwise identical; only the build-side retry under selection is deferred.
