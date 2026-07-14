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
- A repeatable flag (`--exclude`, `--gate`, `--build-arg`, `-I`, `--precompile`)
  may appear multiple times; each occurrence is one value. Values containing
  spaces are preserved exactly (the runner never re-splits a flag value on
  spaces).
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
| `--timeout`, `--compile-timeout` | ✓ | ✓ (compile only) |
| `--retries N` | ✓ | — |
| `--gate PATH` | ✓ | — |
| `-s`, `--show-output MODE` | ✓ | — |
| `--junit-xml PATH`, `--gh-annotations` | ✓ | — |
| `-q`, `-v`, `--color WHEN` | ✓ | ✓ |
| `--collect-only` | ✓ (→ behaves as `collect`) | n/a |

`collect` compiles files to enumerate their tests, so it honors the build and
selection flags; it does not schedule test execution, so run-time flags
(`--timeout` for a run, `-x`, `--retries`, reporters) do not apply.

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
not, is a usage error (exit 4).

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

If a precompile step fails, the session ends in **PRECOMPILE-ERROR**: there is no
test identity to attach it to, so the runner prints one banner, lists every test
file that depended on it as a casualty, and exits 1.

### 8.4 Forbidden build arguments

The runner owns its output artifacts and its source list. Build arguments that
would take that control away are rejected as usage errors (exit 4): output
selection (`-o`), emit-type selection (`--emit`), and any **extra source
operand** (a positional path handed to `mojo build`). This applies to
`--build-arg`, to `-I` misuse, and to post-`--` arguments alike.

---

## 9. Exit codes

Mirrors pytest, and is **FROZEN**:

| Code | Meaning |
|------|---------|
| 0 | the session ran; every selected test's outcome is PASS or SKIP (exclusions allowed) |
| 1 | at least one selected outcome is FAIL, CRASH, TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT, MALFORMED-SUITE, or PRECOMPILE-ERROR |
| 2 | interrupted (SIGINT/SIGTERM); a partial summary is printed |
| 3 | internal `mtest` error — including protocol drift (a report present but off-grammar) |
| 4 | CLI usage error (unknown flag, bad value, nonexistent path, unknown node id, forbidden build argument) — detected **before any test runs** |
| 5 | no tests collected (empty walk, `-k` matched nothing, everything excluded) |

**Precedence** when outcomes mix. A usage error aborts before the run with 4.
Otherwise: an interrupt dominates (→ 2); else an internal error (→ 3); else any
failing outcome (→ 1); else nothing collected (→ 5); else 0. A user interrupt
outranks an internal error because the run was truncated on purpose and its
result is no longer authoritative.

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

---

## 11. Stopping early

- `-x`, `--exitfirst` — stop *scheduling* new files after the first failing
  file. Files already in flight finish.
- `--maxfail N` — stop after N failing **tests**. A file-level error outcome
  (crash, timeout, compile error, malformed suite) counts as one.
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
*additional* attempts (N+1 total).

- **Crash-class** = termination by signal, a timeout, or compiler output
  matching a crash signature. A nonzero exit with ordinary diagnostics is
  deterministic and is **never** retried; neither is a failing assertion.
- Retries apply uniformly to precompile, build, and run steps. Each retry uses a
  fresh output path and a quarantined module cache (a killed compile can corrupt
  the shared cache).
- Every attempt's diagnostics are retained in the report. The **last** attempt's
  outcome is authoritative. A test that passes only after a retry is reported
  **FLAKY** and, by default, passes CI (`--fail-on-flaky` is reserved).

---

## 14. Output capture

Child stdout and stderr are captured separately and byte-exactly.

- `--show-output MODE`: `failures` (default) shows captured output for FAIL and
  crash-class outcomes; `all` shows it for every test; `none` suppresses it.
- `-s` is an alias for `--show-output all`.

---

## 15. Reporters

### 15.1 Console

`-q` (quiet: files plus summary) and `-v` (verbose) are mutually exclusive.
`--color WHEN` is `auto|always|never`; `NO_COLOR` is respected, and the flag
wins over it. The console summary is ordered deterministically (§17), not by
completion order. Console text layout and color are **informal** and may change.

### 15.2 JUnit XML — `--junit-xml PATH`

Written atomically (temp file, then rename). Mapping over the outcome
vocabulary, total:

| Outcome | XML |
|---------|-----|
| PASS | `<testcase>` (no child) |
| FAIL | `<testcase>` with `<failure>` |
| SKIP | `<testcase>` with `<skipped/>` |
| CRASH, TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT, MALFORMED-SUITE, PRECOMPILE-ERROR | `<testcase>` with `<error type="...">` |
| FLAKY | passing `<testcase>` with the retry count in `<system-out>` |

- File-level outcomes (which have no single test identity) attach to one
  synthesized testcase, `<testcase name="<file>::[build]">`, inside that file's
  `<testsuite>`.
- All text is XML-escaped; invalid XML control characters are stripped. Captured
  output attaches as `<system-out>`/`<system-err>` on failing testcases, bounded
  in size with truncation marked.
- Ordering is **deterministic**: testcases are sorted by node id, independent of
  parallel completion order. Suite-level `time` is the runner's own wall-clock
  per file; per-testcase `time` is **omitted** while upstream per-test timings
  are untrustworthy (honesty over decoration).

### 15.3 GitHub annotations — `--gh-annotations MODE`

`auto|on|off`; `auto` is on iff `GITHUB_ACTIONS=true`.

- FAIL → `::error file=<f>,line=<l>::<node id>: <first assertion line>` (location
  taken from the `At <path>:<line>:<col>:` detail).
- Crash-class → `::error file=<f>::…`.
- Plus one summary `::notice`.
- Every payload escapes `%`, CR, and LF as `%25`, `%0D`, `%0A`, and is
  length-bounded. User-controlled paths, names, and assertion text are never
  interpolated raw into a workflow command.

---

## 16. `collect`

`mtest collect [PATHS] [flags]` (and `mtest --collect-only`) lists node ids, one
per line, sorted **lexicographically**. The runner imposes its own order so the
frozen output format never couples to TestSuite's discovery order (execution
still uses discovery order internally). `collect` accepts the selection and
build flags because it compiles files to enumerate them. A file that does not
compile reports its error on stderr and listing continues; the exit code is **1
if any file failed to compile**, else **5 if nothing was collectable**, else
**0** — consistent with the §9 precedence, under which a compile failure (a
failing outcome → 1) dominates "nothing collected" (→ 5).

---

## 17. Determinism

Given the same inputs, `mtest` produces byte-identical machine output: the
console summary, the `collect` listing, and the JUnit XML are all ordered by node
id, independent of the order in which parallel workers finished. Parallelism
never changes *what* is reported, only how fast.

---

## 18. Concurrency

`-n, --workers N|auto` sets the worker count. `auto` sizing is runner-chosen and
may tune across minor versions. Because `mojo build` is itself multi-threaded,
`auto` is conservative (stacked cold compiles starve each other).

`--timeout SECS` (default 300, `0` disables) bounds a single file's **run**;
exceeding it yields TIMEOUT. `--compile-timeout SECS` (default 600) bounds a
single file's **build**; exceeding it yields COMPILE-TIMEOUT with a hint to split
the module or exclude it. Timeout kills are signal-first (a terminate signal,
then a grace period, then a hard kill) and reach the whole process tree, not just
the direct child.

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
  node-id grammar; the JUnit mapping; the annotation shapes; the `collect`
  format; the test-module contract.
- **STABLE-INTENT** — default values (timeouts, `auto` worker sizing) may be
  tuned in minor versions.
- **INFORMAL** — console text layout and colors.
- TestSuite invocation details are an internal seam, never public API.

---

## 21. Reserved (documented as reserved, not in v1)

`--root`; `--lf`/`--ff` (last/failed-first); boolean `-k` expressions; a config
file (TOML subset or argfile); `--pattern`; `--durations` (blocked on an upstream
timing bug); a `--json` event stream; markers / `xfail`; `--asan`; `--shuffle`
(file-order randomization to surface order dependencies); `--fail-on-flaky`;
watch mode; a plugin mechanism; and a **persistent** build/collection cache
(`--cache-dir`/`--no-cache`). Within one session the runner builds each file once
and reuses it (`collect` and `run` share the binary), but nothing persists across
invocations in v1: a trustworthy-verdict tool does not ship "fast but possibly
stale", and a correct cache key (transitive source closure, environment inputs,
target triple, schema version, concurrent-writer safety) is its own deliverable.

---

## 22. Platforms

Linux and macOS are the v1 targets. The automated gate runs on Linux; macOS
support rests on the same POSIX process surface and gains its own gate in a later
release. Platform divergence in crash reporting is absorbed by the structured
termination model (a terminating signal is recorded as a signal, never as a
shell-encoded `128+N`).

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

**Served** (parsed into real behavior): positional `PATHS`, `--exclude`, `-I`,
`--build-arg` (and post-`--` passthrough), `--precompile`, `--mojo`,
`-x`/`--exitfirst`, `--timeout`, `--gate`, `-s`/`--show-output`, `-q`/`-v`,
`--color`, `-h`/`--help`, `--version`, and the `run`, `version`, and `help`
subcommands.

**Not yet available**: `-k`, `--maxfail`, `-n`/`--workers`,
`--compile-timeout`, `--retries`, `--junit-xml`, `--gh-annotations`,
`--collect-only`, and the `collect` subcommand. Each is recognized by the
parser — it knows the spelling and its arity — but is **refused before any
test runs**, with a usage error that names the flag, states that it is part
of the v1 contract, names the capability that brings it (e.g. `-k` arrives
with the report parser; `--collect-only` and `collect` arrive with test
collection; `-n`/`--workers` arrive with parallel workers), and lists what
this build does serve.

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
- **1** — reachable for FAIL, CRASH, TIMEOUT, COMPILE-ERROR, and
  PRECOMPILE-ERROR. COMPILE-TIMEOUT, MALFORMED-SUITE, and FLAKY are part of
  the frozen outcome vocabulary but are **not emitted by this build** — they
  arrive with later capabilities (compile-timeout enforcement, report
  parsing, and retries, respectively).
- **2** — reachable: an interrupt (SIGINT/SIGTERM) is implemented with
  sequential-session semantics — a partial summary is printed, the files
  that had not yet started are reported NOT-RUN, and the active child's
  process group is cleaned up. The parallel-workers interrupt story arrives
  with parallel workers.
- **3** — reachable via a spawn failure (the runner could not spawn `mojo` or
  a built binary). The protocol-drift cause of exit 3 (a report present but
  off-grammar) needs the report parser and is **not reachable** in this
  build.
- **4** — reachable for every frozen cause in §9, plus the transitional
  not-yet-available-flag refusal subcase in §24.1 above.
- **5** — reachable via an empty walk and via the everything-excluded case.
  The deselection cause (`-k` matched nothing) needs per-test selection and
  is **not reachable** in this build, since `-k` itself is refused (§24.1).

### 24.3 The zero-test ceiling

This build does not yet parse the per-file report TestSuite emits, so a
verdict is decided from the child process's termination status alone: a file
that exits 0 without running a single test is indistinguishable from a file
that exits 0 after running and passing its tests, and is reported **PASS**.
Report parsing and count reconciliation close this hole in a later build;
until then, treat a PASS as "the file's process exited cleanly," not yet as
"every test in it ran and passed."
