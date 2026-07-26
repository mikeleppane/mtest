# Memory-safety risk map

Every mechanically unsafe or native-backed ownership boundary in the product,
and the executable evidence that covers it. An entry here is a claim about what
*runs*, not about what exists: where nothing instrumented executes a site, the
entry says so and gives the reason.

> **Measured 2026-07-26 at commit `27715c1`. Nothing re-runs this.**
>
> Every `A n/14` and `V n/17` below came from a **manual** callgrind run over
> that commit's suite binaries — see "How the evidence column was verified". It
> is not a gate: no CI job, no `pixi` task, and no test recomputes these numbers,
> so nothing will go red when they stop being true. Treat a count as evidence
> about `27715c1`, not as a live guarantee. Add a suite, delete a test, or change
> what a reporter calls, and the count silently becomes a historical fact.
>
> Re-measuring costs about two minutes; the commands are in that section. Do it
> before trusting a count to make a decision, and update the date and commit
> above when you do.
>
> **Least corroborated part:** the per-suite counts. The extractor was validated
> against thirteen independently known facts, but all of the *positive* ones come
> from a single CLI-probe run, so no external fact pins any suite-level number.
> The three C-only rows and the two false rows review found are the
> best-supported claims here; the suite counts are the ones to re-measure first.

## How to regenerate the inventory

The lexical inventory this map is built from is the one `pixi run safety-check`
enforces — a `# SAFETY:` comment beside every candidate operation:

```text
grep -rn '# SAFETY:' src/
```

98 product sites at the time of writing, across 13 files. The two prose mentions
in `src/mtest/platform/__init__.mojo` and `src/mtest/exec/tty.mojo` are docstring
text explaining why those modules carry no site, not sites themselves; the
checker's `^\s*#\s*SAFETY:` anchor excludes them, and so does this map.

The 41 `# SAFETY:` sites under `tests/` and `e2e/` are deliberate test-only
constructions (fault injection, the ASan controls, a segfault fixture). They are
excluded from this map: they are the instruments, not the subject.

## The lanes

| Tag | Lane | What it proves |
| --- | --- | --- |
| **A** | `pixi run asan-check` | AddressSanitizer + LeakSanitizer over source-built product code. Catches out-of-bounds, use-after-free, and leaks in the Mojo-side ownership of native buffers. |
| **V** | `pixi run valgrind-check` | Memcheck over source-built product code with `--track-fds=yes`, `--track-origins=yes` and no suppressions. Catches the same classes plus undefined-value reads and descriptor leaks, and pins the runtime-reachable baseline. |
| **N** | native C tests under **V** | `tests/native/test_exec_native.c` and `test_exec_native_signals.c`, linked against the adapter and run in Memcheck. Covers the C side of the boundary the Mojo sites call across. |
| **C** | the real-CLI reporter probe | One fixed `mtest` run, source-built and instrumented, in **both** A and V. It is the only evidence that executes `src/main.mojo` and the surfaces reachable only from it. |

Neither A nor V is part of `pixi run ci`. GitHub runs them as separate matrix
cells, so a regression in either is invisible to the local floor unless the lane
is run explicitly.

### What the CLI probe (C) actually runs

A scratch invocation root holding one `mtest.toml` and one generated test
module, driven by:

```text
mtest --config <scratch>/mtest.toml -k hostile \
      --mojo scripts/fixtures/toolchain/fake_hostile_mojo.py \
      --json <scratch>/hostile.ndjson --junit-xml <scratch>/hostile.xml
```

The `--mojo` stand-in never invokes the real compiler: it writes an executable
copy of `tests/fixtures/exec/hostile_report_actor.py`, which emits invalid UTF-8,
NUL/BEL/DEL/C1 controls, CSI and OSC sequences, JSON- and XML-injection
lookalikes, and then a genuine reconciling `TestSuite` report with one FAIL row.
So the run lands on a real verdict with real captured output, and every reporter
renders it.

Both the stand-in and the actor are children the CLI `execve`s. Under A they are
uninstrumented processes; under V the lane runs `--trace-children=no`, so they
are outside Memcheck. The subject is the mtest parent alone, by design — a
`mojo build` child under Memcheck would dominate the runtime and report on a
toolchain this project does not own.

The probe asserts, each for one named reason: the client exit code, the escaped
rendering of the child's CSI sequence, the absence of any raw ESC/NUL/BEL/DEL
byte, the promoted `.mtest-cache/lastrun` state file, the NDJSON artifact
through `scripts/checks/reports/json_stream.py`, and the JUnit artifact through
`scripts/checks/reports/junit.py` (xmllint against the vendored `junit-10.xsd`,
then the arithmetic invariants). The Valgrind copy additionally asserts its own
Memcheck provenance — the banner, `ERROR SUMMARY: 0 errors from 0 contexts`, the
expected `FILE DESCRIPTORS: 3 open (3 inherited) at exit.`, and the exact client
exit code — because "no errors reported" and "the probe never ran wrapped" are
indistinguishable without it. The ASan copy asserts the equivalent positive
witness in its own way: `LSAN_OPTIONS=verbosity=1` makes LeakSanitizer announce
`LeakSanitizer: checking for leaks` from inside the process under test, so a
clean run proves the leak check *ran* rather than merely not complaining.

## How the evidence column was verified

Every `A n/14`, `V n/17` and `C ✓` below is a measured fact, not a reading of
the import graph. Three earlier rows claimed evidence that did not exist, and
all three failed the same way: a module **re-exports** a symbol, so the suite
compiles and links against it, and nobody checked whether the suite ever
**calls** it. `mtest.config` re-exporting `lossy_utf8` is the canonical example.

Import-closure analysis cannot settle this. It answers "is this code linked
in?", and for `tests/unit/test_config.mojo` it answers *yes* for `lossy_utf8`
via `mtest.cli.doctor` — a module that suite never invokes. The question the map
asks is "does this code RUN?", so the audit was done dynamically:

```text
valgrind --tool=callgrind --trace-children=no --enable-debuginfod=no \
         --callgrind-out-file=<suite>.out build/safety/valgrind/<suite>
```

over each lane's own debug binary, plus one run of the fixed CLI reporter probe.
A row's file counts as executed for a suite when it appears in that suite's
callgrind dump in any positional role — `fl=`, `fi=`/`fe=` (inlined), or
`cfi=`/`cfe=` (the file of a called function). All of them matter: Mojo builds
with optimization, so most of these one-line `# SAFETY:` functions are inlined
and never appear as their own `fn=` entry. Reading `fl=` alone reports
`report/console.mojo` as unexecuted by a probe run that demonstrably escaped
console bytes.

The extractor was validated before any row was rewritten, against eleven
independently known facts: the four false claims found by review, plus seven
positives forced by the probe's own artifacts (it wrote `hostile.ndjson`,
`hostile.xml`, and `.mtest-cache/lastrun`, so the NDJSON, JUnit and temp-file
paths must show as executed). It reproduces all eleven. The line-level
cross-check described above was validated against those eleven plus two more —
that `_write_all` runs under `test_report_json_reporter` and does not under
`test_session_schedule`, both established from source by review rather than by
this tooling — and reproduces all thirteen.

Note what that validation does **not** cover: every positive fact in it comes
from the one CLI-probe dump, so no independently-known fact pins a per-suite
count. The suite counts are the least corroborated numbers in this document,
which is why the header says to re-measure them first.

**Granularity: these counts are per-FILE, checked against per-SITE.** The
callgrind dumps name executed source files, and a suite can enter a file through
a function that carries no `# SAFETY:` comment — entering a file is not
executing a site. So every count below was re-derived a second way, from
callgrind's line positions: each site's enclosing function was given a line
range, and a suite counts only if an executed line falls inside one. The two
agree for twelve of the thirteen rows. The exception is
`report/json_stream_reporter.mojo`, whose row says so explicitly. Read a count
as "this many suites executed a function containing a site in this file", not as
"this many suites executed all 52 sites".

Native C evidence (**N**) is not measured this way: it is the two adapter
binaries the Valgrind lane already runs and asserts on directly.

## The map

| File | Sites | What they are | Evidence |
| --- | --- | --- | --- |
| `src/mtest/exec/supervise.mojo` | 52 | argv/env C-string marshalling, the `_NativeBuffers` allocation/free pair, every adapter syscall wrapper (poll set, fd limit, monotonic clock, process open/close, poll, read quantum, setup drain, group, observe, close channel, reap, abort), `Completion.query_effective_cap`, `Supervisor` construction/teardown | **A** 10/14 · **V** 12/17 · **N** both adapter lifecycle binaries · **C** ✓. Every `test_exec_*` suite in each lane except `test_exec_paths`, which resolves paths and executes nothing else. |
| `src/mtest/exec/signals.mojo` | 13 | signal-runtime open/close, the ABI-v1 error record's alloc/read/free including the destructor fallback, the installed/pending queries, `kill(2)` | **A** 10/14 · **V** 12/17 · **N** `test_exec_native_signals.c` · **C** ✓. The runtime opens for any supervised run, so its coverage matches `supervise.mojo` exactly rather than the three suites an earlier version of this row named. |
| `src/mtest/platform/regular_file.mojo` | 15 | `open(2)`, `fstat(2)` into a 144-byte aligned record, the bounded read loop's pointer arithmetic, and the buffer free on every exit path | **A** 0/14 · **V** 0/17 · **C** ✓ only — see gap 2. Four product callers, all above the `cli` layer: `src/main.mojo:304` (config) and `:383` (state), `src/mtest/cli/doctor.mojo:259` (config) and `:519` (state). The probe's explicit `--config` makes `main.mojo:304` mandatory: an unreadable file named on the command line is a usage error, not a silent skip. |
| `src/mtest/platform/stream.mojo` | 7 | the `errno` location call (Darwin and Linux spellings), `read(2)`, `write(2)`, `creat(2)` (both spellings), `close(2)` | **A** 1/14 (`test_report_json_reporter`) · **V** 0/17 · **C** ✓ — see gap 2. No Valgrind-lane suite executes this file: `test_report_json_reporter` is the only suite that reaches it and it is excluded from lane V (see the exclusions). Its Memcheck evidence is the CLI probe alone, which drives NDJSON, JUnit, and state writes through it. |
| `src/mtest/platform/temp_file.mojo` | 3 | `mkstemp(3)` over a mutable template buffer, the post-call template rebuild, and the byte scan that validates it | **A** 0/14 · **V** 0/17 · **C** ✓ only — see gap 2. `create_unique_temp` has exactly two callers, `src/main.mojo:415` (state) and `src/mtest/cli/doctor.mojo:312`; the probe reaches the first. NOT the JUnit spool: `junit_reporter.mojo` imports only `process_id` and `rename_path` from `mtest.platform` and builds its temp from `_junit_nonce()` plus builtin `open` (`junit_reporter.mojo:198-209`), so `test_report_junit_finalize` never enters this file. |
| `src/mtest/platform/fs.mojo` | 1 | `rename(2)` | **A** 1/14 · **V** 1/17 (`test_report_junit_finalize`, both lanes) · **C** ✓ (state promotion, JUnit temp → target). |
| `src/mtest/platform/process.mojo` | 1 | `getpid(2)` | **A** 4/14 · **V** 3/17 (`test_exec_interrupt`, `test_exec_pool`, `test_report_junit_finalize`; plus `test_session_schedule` in A) · **C** ✓. |
| `src/mtest/report/escape.mojo` | 1 | `unsafe_from_utf8` over the escaper's rebuilt byte buffer | **A** 4/14 · **V** 3/17 (`test_report_escape`, `test_report_junit`, `test_report_junit_finalize`; plus `test_report_json_reporter` in A) · **C** ✓. |
| `src/mtest/report/junit.mojo` | 1 | `unsafe_from_utf8` over the XML text escaper's byte buffer | **A** 2/14 · **V** 2/17 (`test_report_junit`, `test_report_junit_finalize`) · **C** ✓. |
| `src/mtest/report/json_stream_reporter.mojo` | 1 | a `String`'s bytes borrowed across a partial-write loop, with derived pointer arithmetic per iteration | **A** 1/14 (`test_report_json_reporter`) · **V** 0/17 · **C** ✓ — its only Memcheck evidence, for the reason in the exclusions. `test_session_schedule` ENTERS this file but does not reach the site: with no `--json`, `coordinator.mojo:338` builds a `JsonStreamReporter.inert()` that never opens a descriptor, so `_write_all` — the function the `# SAFETY:` comment is in — never runs. This is the one row where the file-level and site-level counts differ; see the note on granularity above. |
| `src/mtest/report/console.mojo` | 1 | `unsafe_from_utf8` over the drained byte suffix of the console's head buffer | **A** 0/14 · **V** 0/17 · **C** ✓ only — see gap 7. NOT `tests/unit/test_report_console.mojo`: the site is inside `ConsoleReporter.drain` (`console.mojo:972`), that suite asserts through `output()` (`console.mojo:959`, which neither calls `drain` nor touches `unsafe_from_utf8`), and `rg '\.drain\(' tests/unit/test_report_console.mojo` returns nothing. The suite that does execute it in the plain `pixi run test` lane is `tests/unit/test_report_coordinator.mojo` — `test_standard_coordinator_incremental_drain_reconstructs_output` (`:133`) reaches it through `coordinator.mojo:283` — and that suite is in neither instrumented inventory; the probe drives the same drain with a hostile capture in it. |
| `src/mtest/select/selection.mojo` | 1 | `unsafe_from_utf8` over the ASCII case fold in `contains_ci` | **A** 0/14 · **V** 0/17 · **C** ✓ only — see gap 7, via the probe's `-k hostile`. The probe carries that flag for exactly this reason; drop it and the site loses all instrumented evidence. |
| `src/mtest/config/lossy_utf8.mojo` | 1 | the UTF-8 validity scan's leading-byte and continuation bounds | **A** 8/14 · **V** 7/17 · **C** ✓. `test_exec_capture` calls it directly on a lone `0xFF` (`test_lossy_utf8_replaces_invalid_preserves_valid`), and `bytes_to_str` in `tests/support/exec_helpers.mojo` routes every capture assertion through it. NOT `test_config`: `mtest.config` only re-exports the symbol (`src/mtest/config/__init__.mojo:41`) and that suite never calls it — confirmed by callgrind, no frame from this file executes. |

## Exclusions, with reasons

- **`src/mtest/platform/__init__.mojo:18` and `src/mtest/exec/tty.mojo:19`** —
  prose in module docstrings, not sites. `tty.mojo` says so explicitly: it has
  no raw FFI call to document.
- **`tests/**` and `e2e/**` sites (41)** — test-only constructions. Three of them
  (`tests/native/asan_*_control.mojo`) exist to be caught by ASan and are run as
  negative controls in lane A on every invocation; the rest are fault-injection
  fixtures whose unsafe operations are the instrument under test elsewhere.
- **Darwin-only branches** in `platform/stream.mojo` (`__error`, the Darwin
  `creat`) — unreachable on the Linux hosts where A, V and N run. They are
  compile-checked for macOS from Linux (`mojo build --target-triple
  arm64-apple-macosx14.0.0 --emit=asm`) and exercised by the macOS test cell,
  which has no sanitizer lane. This is a real residual gap, not a claim of
  coverage.
- **`tests/unit/test_report_json_reporter.mojo` from lane V** — its subject *is*
  descriptor misuse. One test hands the reporter a descriptor it closed first so
  the header write must latch `EBADF`; another closes the same descriptor twice
  so the second close must report the failure rather than swallow it. Memcheck's
  `--track-fds=yes` reports both, correctly. Running it with `--track-fds=no`
  would drop the descriptor channel for the one suite that is entirely about
  descriptors, and relaxing `check_product_output` would weaken the contract for
  the other seventeen. Lane A runs it unchanged — LeakSanitizer does not track
  descriptors, so the deliberate `EBADF` calls are inert there — and lane V still
  covers `open_json_fd`, `_write_all`, and `close_json_fd` on live descriptors
  through the CLI probe, under the full flag set. `scripts/tests/test_valgrind.py`
  pins both halves of that arrangement.

  This exclusion has a second, less obvious cost, now measured: it is also why
  `platform/stream.mojo` has **no** lane-V suite evidence. That suite is the only
  one in either inventory that executes `stream.mojo` at all, so excluding it
  from V leaves the CLI probe as the file's entire Memcheck evidence. See gap 2
  for the cheap way to restore it.
- **`MTEST_EXEC_TESTING=1` fault paths in `native/mtest_exec_native.c`** — absent
  from the production object by construction, which `pixi run native-check`
  proves by symbol inspection. The CLI probe links the production variant in both
  lanes, so it cannot reach them.

## Residual gaps

These are known and deliberate. Each is a place where the map claims *less* than
full instrumented coverage.

1. **One probe run covers one of `read_bounded_regular_file`'s four call sites.**
   The probe drives `src/main.mojo:304` (the config read). The other three are
   uninstrumented: `main.mojo:383` because the probe's first run has no state
   file yet, so `_load_state` short-circuits on `exists()` before reaching the
   reader; and both `cli/doctor.mojo:259` and `:519` because the probe never
   invokes the `doctor` subcommand. All four call the same function with the
   same ownership and the same two size bounds, so this is a gap in *entry
   points*, not in the code under the `# SAFETY:` comments — but a `doctor`
   regression in that reader would not be caught by either lane. Closing it
   would mean a second probe run for `doctor` and a third for a warm state file,
   roughly tripling the Memcheck wall time of this probe.
2. **Three platform files have no suite evidence in either lane, only the CLI
   probe.** `platform/temp_file.mojo`, `platform/regular_file.mojo` and — in
   lane V — `platform/stream.mojo` are executed by no suite in the instrumented
   inventories. Callgrind confirms it: no lane suite enters `temp_file.mojo` or
   `regular_file.mojo` at all, and `stream.mojo` is reached only by
   `test_report_json_reporter`, which lane V excludes. So for these three, one
   probe run is the entire instrumented evidence — if it stopped exercising them
   the map's claim would evaporate with no suite to fall back on.

   **Cost of closing: low, and specific.** `tests/unit/test_platform_temp_file.mojo`
   already exists and already covers exactly these three
   (`test_unique_temp_never_reuses_predictable_links_or_collisions`,
   `test_create_and_write_failures_leave_cleanup_to_the_exact_owner`,
   `test_bounded_read_validates_the_opened_regular_file`). Adding it to both
   inventories costs one instrumented build per lane plus two Memcheck passes —
   roughly 90 seconds of Valgrind wall time — and would give all three files
   real suite-level evidence. It is not done here only because this task's brief
   fixes the added-suite list at the four report suites; it is the single
   highest-value follow-up in this document.
3. **The Valgrind CLI probe drops `possible` from `--errors-for-leak-kinds`.**
   The CLI initializes the Mojo async runtime's CPU device, which starts one
   unjoined worker thread per core; glibc's per-thread TLS descriptor table is
   then reachable only through an interior pointer and Memcheck classifies it
   `possibly lost`. The block count tracks the host's core count, so it cannot be
   pinned the way `EXPECTED_REACHABLE` pins the suites' baseline. The gate still
   rejects any possibly-lost or still-reachable record carrying a `src/mtest/`,
   `src/main.mojo`, or `native/mtest_exec_native.c` frame, and every other lane
   keeps `possible` as a hard error.
4. **No post-fork audit pass for the CLI probe.** The suites get a second,
   unsilenced Memcheck pass that audits the pre-exec fork child. The CLI forks
   for every build and every run child, so that pass would report on transient
   copies of the whole session state rather than on a decidable ownership claim.
   The exec suites already own that channel.
5. **The macOS platform branches have no sanitizer lane at all.** See the
   exclusion above.
6. **Both lanes hold their own copy of the probe definition.** The two gate
   drivers share no module, so the tree, the config, the argv, and the expected
   console rendering are defined twice. `scripts/tests/test_valgrind.py` asserts
   the two copies are equal constant-by-constant AND compares the source of all
   three duplicated functions, so a divergence is a test failure rather than two
   lanes silently probing different programs.
7. **`report/console.mojo` and `select/selection.mojo` are CLI-probe-only.**
   Neither has a suite in either inventory. `selection.mojo` is reached solely
   because the probe passes `-k hostile`; remove that flag and its one
   `# SAFETY:` site has no instrumented evidence at all. Closing the console one
   would mean adding `tests/unit/test_report_coordinator.mojo` (13,680 bytes) —
   **not** `tests/unit/test_report_console.mojo`, which is 85,536 bytes and,
   despite its name, never calls `drain` and so would add no evidence for this
   site at all. Adding the coordinator suite is therefore cheap in wall time;
   what it is not is free, since each addition is paid on every run of both
   lanes. The probe carries the burden today; this gap is a candidate to close,
   and the earlier claim that closing it required the 86 KB suite was wrong.
