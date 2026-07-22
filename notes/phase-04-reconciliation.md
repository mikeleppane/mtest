# Phase 3 → Phase 4 reconciliation record (mtest, as-landed on `main`)

Read-only audit of the merged tree. No source was modified. `docs/plans/` was not read.
Every claim cites `file:line` against the tree as it currently reads on `main`.

## Verdict up front

- **Ownership check (item A): PASSES.** No `Progress` kind, no `SessionStarted.workers`,
  no `FileFinished.serial` anywhere. Proceed normally — no rogue later-phase code landed.
- **Interrupt check (item J): PASSES.** SIGINT/SIGTERM still emits `SessionFinished`
  (exit code 2) with a partial summary. Not a STOP.
- **One MATERIAL/STOP finding: item F** — FLAKY is represented by EMITTING the
  `Outcome.FLAKY` value (code 9) as the file outcome, contradicting the brief's
  "outcome PASS + flaky bool, FLAKY value unemitted" expectation. Legitimate and
  contract-sanctioned, but the serializer contract differs from the brief's premise.
- **One item to FLAG for a human decision (item Q):** a macOS build lane DID land in CI.

MATERIAL findings: **1** (item F). COSMETIC / matches-expectation: the rest.
Plus one non-semantic FLAG (macOS lane, item Q) the brief explicitly asked to surface.

---

## A. The event set as landed — `src/mtest/model/events.mojo`

**EXPECTED:** exactly 11 kinds, no `Progress`. **FOUND:** exactly 11 kinds
(`events.mojo:44-54`), matching the expected set:
SESSION_STARTED(0), WARNING(1), PRECOMPILE_FAILED(2), FILE_STARTED(3),
FILE_FINISHED(4), SESSION_FINISHED(5), INTERNAL_ERROR(6), TEST_REPORTED(7),
COLLECTION_KNOWN(8), ATTEMPT_FINISHED(9), CRASH_ATTRIBUTION(10). **No `Progress`.**
Classification: **COSMETIC / matches.**

Payload fields per kind (single closed `Event` struct, factory-built, unused fields
defaulted — `events.mojo:99-344`):

- **SessionStarted** (`session_started` `events.mojo:346-368`): `root`, `toolchain`,
  `selected_count`, `excluded_count`, `shard_label` (e.g. "2/5", empty when unsharded),
  `sharded_out_count`. **No `workers` field present.** (`events.mojo:113-127`)
- **Warning** (`events.mojo:370-380`): `warning_kind`, `warning_pattern`.
- **PrecompileFailed** (`events.mojo:382-421`): `step`, `compiler_output`,
  `casualty_count`, `casualties: List[String]` ("empty if only a count is known",
  `events.mojo:143-144`), `ending_known`, plus the shared final-termination fields
  `term_kind`/`term_value`/`escalated`/`timeout_seconds`/`attempts_used`. See item B.
- **FileStarted** (`events.mojo:423-428`): `path`.
- **FileFinished** (`file_finished` `events.mojo:430-488`): `path`, `outcome`,
  `duration_seconds`, `build_argv`, `build_duration_seconds`, `captured_stdout`,
  `captured_stderr` (file-scope raw bytes), `signal_number`, `exit_status`,
  `timeout_seconds`, `exclusion_pattern`, `parse_disposition`, `passed_tests`,
  `failed_tests`, `skipped_tests`, `deselected_tests`, `attempts_used`, `flaky`,
  `slow`, and `escalated`. **No `serial` field present.** (`events.mojo:153-200`)
- **AttemptFinished** (`attempt_finished` `events.mojo:550-602`): `path`, `step`
  ("build"|"run"|"precompile"), `attempt_index` (1-based), `attempts_planned` (N+1),
  full termination identity `term_kind`/`term_value` + latched
  `term_final_kind`/`term_final_value` + `escalated`, `retry_eligible`,
  `classification`, `duration_seconds`, BOUNDED excerpts `captured_stdout`/
  `captured_stderr` with `stdout_truncated`/`stderr_truncated` markers, and
  `attempt_argv`. Carries all fields the brief listed.
- **CrashAttribution** (`events.mojo:604-624`): `path`, `attribution_disposition`
  (TYPED — `AttributionDisposition`, `events.mojo:239`), `culprit_test`,
  `isolation_reruns`, `attribution_seconds`.
- **CollectionKnown** (`events.mojo:540-548`): `selected_test_total`,
  `deselected_test_total`. (Note: emitted only on the selection path,
  `session.mojo:2694`; NOT emitted on the plain run loop.)
- **InternalError** (`events.mojo:490-503`): `step`, `program`, `errno`.
- **TestReported** (`events.mojo:527-538`): `test: TestResult`; `path` mirrors
  `test.node.path`.
- **SessionFinished** (`session_finished` `events.mojo:505-525`): `summary: Summary`
  (per-outcome tally incl. EXCLUDED/NOT_RUN), `wall_time_seconds`, `exit_code`,
  `test_counts: TestCounts`, `flaky_files`.

**OWNERSHIP CHECK — PASSES.** `Progress` ABSENT; `SessionStarted.workers` ABSENT;
`FileFinished.serial` ABSENT. Per the brief: absence → normal, proceed. **Not a STOP.**

**Fields a machine reporter would still LACK** (the Phase-3 notes do NOT explicitly
answer this — `notes/phase-03-notes.md` has no "still lacks" entry): derived from the
code, a serializer producing the NDJSON stream still lacks (1) a per-event
sequence number or timestamp — no monotonic `seq`/`ts` field exists on `Event`; (2) a
schema/version field; (3) trustworthy per-test timing — `TestResult.timing` rides as a
raw upstream string and the contract deliberately omits per-testcase `time`
(`docs/cli-contract.md:457`). `*_seconds`/duration fields serialize as integer
microseconds per the brief's stated `*_us` convention; the events store them as
`Float64` seconds (`duration_seconds`, `wall_time_seconds`, `attribution_seconds`,
`build_duration_seconds`), so the microsecond conversion is the reporter's job.

---

## B. PrecompileFailed casualties

**EXPECTED:** both `casualty_count: Int` and `casualties: List[String]`; the session
passes the full casualty file list. **FOUND:** both fields exist
(`events.mojo:141-144`). Population: `casualty_count = len(casualties) if casualties
else casualty_count` (`events.mojo:414`) — a non-empty list is authoritative for the
count. The session builds the full casualty list as gates + every run file and passes
it (`session.mojo:3281-3283`, `3310-3321`: `casualties=casualty_files`).
Classification: **COSMETIC / matches.**

---

## C. FileFinished truncation booleans (drives commit 3)

**EXPECTED:** determine whether Phase 3 propagated exec's
`stdout_truncated`/`stderr_truncated` onto FileFinished. **FOUND: NO.** The
`file_finished` factory (`events.mojo:430-488`) has no `stdout_truncated`/
`stderr_truncated` parameters and the `Event` struct exposes those two booleans ONLY
for AttemptFinished (`events.mojo:228-233`). So **commit 3 lands the model change**
(not verify-only).

`ProcessResult` STILL carries both booleans (`src/mtest/exec/result.mojo:27-32`).
**No byte-total field** appeared anywhere (grep of `exec/` and `model/`): the capture
layer records only the boolean overflow flag plus a spliced human marker naming the
omitted byte count inside the stream itself (`exec/capture.mojo:6-8, 94, 127-130`), not
a structured total on any event. Classification: **COSMETIC / expected NO branch**
(informs commit 3 scope; no unexpected total to fold).

---

## D. The seam shape (drives the finalization extension)

**EXPECTED:** `Reporter.handle` still non-raising, no result value, no finalizer;
`Composite` calls only `handle`. **FOUND:** trait `Reporter` has exactly one method
`def handle(mut self, e: Event)` — no return value, docstring "Total over the event
set; must not raise" (`src/mtest/report/reporter.mojo:25-27`); no finalizer method on
the trait. `CompositeReporter.handle` calls only `self.reporters[i].handle(e)`
(`src/mtest/report/composite.mojo:34-37`). The trait did NOT grow a fallible surface.
Classification: **COSMETIC / matches** — the planned status-latch + fallible-finalize
extension is designed against exactly this shape, consumed by `main` on the concrete
reporter value (`src/main.mojo:175`, `comp.reporters[0].output()`).

---

## E. Progress docstring / exclusion

**EXPECTED:** `Progress` does not exist on main. **FOUND:** absent (see item A —
no PROGRESS constant in `events.mojo:44-54`). Classification: **COSMETIC / matches.**
No delta; Phase 4's stream must exclude `Progress` by name so the exclusion holds
when the later worker-pool phase introduces it.

---

## F. FLAKY shape as landed — **MATERIAL / STOP**

**EXPECTED (per brief):** a flaky file is `outcome = PASS` + `flaky: Bool` +
`attempts_used`, with the `FLAKY` Outcome VALUE (code 9) remaining UNEMITTED.

**FOUND — differs:** a late pass after a crash-class retry sets the FileFinished
**outcome to `Outcome.FLAKY`** (code 9), not PASS:
`session.mojo:1009-1011` (`var file_out = cls.file_outcome; if flaky: file_out =
Outcome.FLAKY`) and again on the selection path `session.mojo:1928`. That `file_out`
is what rides `Event.file_finished(...)` (`session.mojo:1013-1032`) AND is tallied in
the summary (`summary.counts[fr.outcome.code] += 1`, `session.mojo:2719/2780/3368/
3446`). `flaky=True` and `attempts_used=N (>1)` also ride the same event. The per-test
exit multiset stays the passing one, so a flaky-only run still exits 0
(`session.mojo:1006-1008`). `flaky_files` on SessionFinished is derived as
`summary.count_of(Outcome.FLAKY)` (`session.mojo:3517`). The console renders a `FLAKY`
verdict token (`report/console.mojo:81-82`) and a `, N flaky` summary clause
(`report/console.mojo:1150`).

So the `FLAKY` Outcome value (code 9) **IS emitted** as the file outcome — the exact
opposite of the brief's "unemitted / outcome PASS" premise. `Outcome.is_failing()`
correctly excludes FLAKY (`model/outcome.mojo:75-83`), so exit codes are unaffected.

This is **legitimate, contract-sanctioned** landed behavior, not a rogue phase: the
committed contract already documents it — `docs/cli-contract.md:447` (JUnit maps FLAKY
to a passing `<testcase>` with retry count) and `docs/cli-contract.md:710-712` ("FLAKY
... is also emitted now, and, being a pass, does not raise the exit code"). The brief's
expectation is simply out of date.

**Why MATERIAL for Phase 4:** a JSON/JUnit serializer reading `FileFinished.outcome`
must treat `FLAKY` (code 9) as a first-class outcome that is nonetheless a pass — it
cannot assume flaky files carry `outcome == PASS`. Per the brief's own rule ("A
difference from the above expectation → MATERIAL"), this is **MATERIAL** and must be
surfaced to the human before the serializers are written. **Marked STOP.**

Secondary (COSMETIC) note: `model/outcome.mojo:9-11, 18-19` docstrings are now STALE —
they claim the runner emits "only a subset (PASS, FAIL, CRASH, TIMEOUT, COMPILE_ERROR,
PRECOMPILE_ERROR ...)" and that FLAKY "is not emitted yet". The session now also emits
FLAKY, COMPILE_TIMEOUT (`session.mojo:957-959`), and MALFORMED_SUITE (probe path). A
serializer author trusting that docstring would be misled; the behavior is authoritative.

---

## G. Event-ordering invariants

**EXPECTED:** per-file TestReported contiguity; AttemptFinished per-file monotonicity;
precompile attempts at SESSION level with no FileFinished. **FOUND — matches:**

- **Per-file TestReported contiguity + AttemptFinished-before-verdict:** a file's
  attempt events (TRY lines) are accumulated then PREPENDED to the terminal FileResult,
  and its per-test TestReported rows are the FileResult `pre_events`; the session emits
  `pre_events` then the `FileFinished` verdict, in order, per file
  (`session.mojo:1143-1148`, `1196-1200`, `1231-1234`; emission `session.mojo:3437-3439`
  plain path, `2708-2714` selection path). AttemptFinished events are appended in
  ascending `attempt_index` (`session.mojo:1196-1200`, loop `1158-1234`).
- **Precompile attempts at session level, no FileFinished:** precompile TRY lines and
  warnings are emitted from the precompile loop BEFORE any file event
  (`session.mojo:3284-3324`, emission `3296-3297`), and a failed step emits
  `PrecompileFailed` (`session.mojo:3309-3322`) — never a `FileFinished`. The
  `AttemptFinished` seam is reused with `step_override="precompile"`
  (`session.mojo:2258`, `_make_attempt_finished` `875-934`).

`RecordingReporter` records each event whole in order and exposes `kind_at`/`path_at`/
`event_at`/`parse_disposition_at` accessors the ordering tests assert on
(`src/mtest/report/recording.mojo:22-73`). Classification: **COSMETIC / matches.**

---

## H. Single-writer dispatch — verified single-threaded

**EXPECTED:** every `Reporter.handle` call serialized on the single parent thread.
**FOUND:** the session is sequential by contract — "no parallelism"
(`session.mojo:11-12`), worker pool deferred. Every `reporter.handle(...)` call site
is inside `run_session` / `_run_selection` / `_run_crash_attribution`, all executed on
the one parent thread (call sites: `session.mojo:2558, 2586, 2594, 2629, 2636, 2694,
2708-2772, 3009-3147, 3229-3524`). There is no thread spawn anywhere in `session/`.
Classification: **COSMETIC / matches** (MATERIAL-by-default surface, but confirmed
single-writer). A pinning concurrency test would attach at the `run_session` seam
(`session.mojo:3176`) around `CompositeReporter.handle`
(`report/composite.mojo:34-37`).

---

## I. The console's landed write path

**EXPECTED:** ONE resolved console destination, zero console bytes on a stream fd.
**FOUND:** the `ConsoleReporter` writes NOTHING itself — it accumulates three owned
`String` parts (`_head`, `_sections`, `_summary`) and exposes them via `output()`
(`report/console.mojo:524-639`). Every write site is a buffer append
(`self._head += ...`, `self._sections += ...`, `self._summary = ...`): header/verdict/
excluded/warning/TRY/attribution lines into `_head`
(`console.mojo:698, 740, 775, 836, 868-872, 889, 930-943`), framed failure sections
into `_sections` (`console.mojo:1078, 948`), summary band + slowest-files into
`_summary` (`console.mojo:1172-1173`).

The console picks NO fd — `main` owns the destination and flushes the whole buffer
ONCE to stdout at the end, even on interrupt/partial-summary:
`print(comp.reporters[0].output(), end="", flush=True)` (`src/main.mojo:175`). Color is
resolved from config/TTY at construction only (`console.mojo:599-604`), never a session
fact.

**No live progress line in sequential mode** — confirmed absent (there is no
per-`k/n` counter; `docs/cli-contract.md:409` "There is **no live progress counter** in
this build"). The only other stdout write in the whole program is the `collect` listing,
written OUTSIDE the reporter seam (`src/main.mojo:124-147`, `print(listing...)` at
`:144`) so stdout carries only the listing.

For Phase 4 `--json -`: the single relocation point is `src/main.mojo:175`. The console
buffer can be redirected to stderr while the NDJSON stream owns stdout, with zero
console bytes on the stream fd, because the console never touches an fd itself.
Classification: **COSMETIC / matches** (MATERIAL-by-default surface, resolved).

---

## J. Interrupt semantics — **PASSES (not a STOP)**

**EXPECTED:** SIGINT/SIGTERM produces a partial summary AND `SessionFinished` STILL
FIRES (exit code 2). **FOUND:** on interrupt the run loops `break` (e.g.
`session.mojo:3285-3287, 3338-3340, 3422-3424`), then control flows to the end-of-run
tail: NOT_RUN accounts for the un-started files (`session.mojo:3475-3476`), exit code is
resolved to 2 (`session.mojo:3482-3483`), the crash-attribution pass is SKIPPED under
interrupt (`session.mojo:3502`), and **`SessionFinished` is emitted unconditionally**
with the partial summary and `code` (=2) (`session.mojo:3518-3526`). A late interrupt
during attribution still dominates to 2 via `_finalize_exit_code`
(`session.mojo:1047-1059, 3512`). Contract corroborates:
`docs/cli-contract.md:250, 713-717`. Classification: **COSMETIC / matches — SessionFinished
DOES fire on interrupt. Not a STOP.**

---

## K. The contract as landed (`docs/cli-contract.md`)

All required sections present and worded as expected. Classification: **COSMETIC /
matches** (with the FLAKY-emission wording noted under item F).

- **§9 Exit codes** (`:242-264`): FROZEN 6-row table (0/1/2/3/4/5). Exit 2 row =
  "interrupted (SIGINT/SIGTERM); a partial summary is printed" (`:250`). Precedence
  paragraph present (`:255-259`).
- **§14 Output capture** (`:390-396`).
- **§15.1 Console** (`:402-434`): "no live progress counter in this build" (`:409`);
  SLOW at 60 s informal (`:416-422`); `--durations N` run-only, header states actual
  row count, survives `-q` (`:424-434`).
- **§15.2 JUnit XML** (`:436-458`): FLAKY → passing `<testcase>` with retry count in
  `<system-out>` (`:447`); per-testcase `time` omitted (`:457`).
- **§15.3 GitHub annotations** (`:460-470`).
- **§15.4 `--json PATH|-`** (`:472-482`): explicitly "(not yet served)"; NDJSON of the
  runner's typed events, `-` = stdout, run-only.
- **§17 Determinism** (`:516-521`), **§20 Stability tiers** (`:588-596`),
  **§22 Platforms** (`:622-630`, names macOS arm64 package build + link + `--help`
  smoke; runtime supervision "remains unverified there"), **§23 Worked examples**
  (`:634+`), **§24 Availability** (`:664-738`).
- **§24.1 Refused flags** (`:683-690`): `-n`/`--workers`, `--junit-xml`,
  `--gh-annotations`, `--serial`, `--json` — EXACTLY the expected list, each named with
  the milestone that brings it. Matches the parser (see item below).
- **Transitional exit-4 subcase paragraph PRESENT** (`:692-701` and restated `:721-722`).
- §24.2 exit-code rows (`:703-724`) include the FLAKY-is-emitted-now note (`:710-712`).

Parser cross-check (`src/mtest/cli/flag_spec.mojo:114-144`): the five refused specs have
`available=False` — `-n`/`--workers` ("parallel workers"), `--serial` ("serial execution
pinning"), `--json` ("machine report artifacts"), `--junit-xml`, `--gh-annotations`;
`--json` has arity 1. Refusal raised via `_refuse` (`cli/parser.mojo:357`). Matches
§24.1 exactly.

---

## L. Capture bounds as landed

**EXPECTED:** file-scope 8 MiB head+tail + ProcessResult booleans; attempt-excerpt
64 KiB, find the constant. **FOUND:**

- **File-scope bound:** `_DEFAULT_CAP_BYTES = 8 * 1024 * 1024` (8 MiB, "head + tail",
  `exec/supervise.mojo:22-23`), split evenly `head_cap = capture_bound_bytes // 2`
  (4 MiB head + 4 MiB tail, `supervise.mojo:585`, used at `438-439`). ProcessResult
  still carries `stdout_truncated`/`stderr_truncated` (`exec/result.mojo:27-32`).
- **Attempt-excerpt bound:** constants **`_ATTEMPT_STREAM_HEAD` = 65536** and
  **`_ATTEMPT_STREAM_TAIL` = 65536** (64 KiB each; `session.mojo:97-102`), applied via
  `clamp_stream(bytes, _ATTEMPT_STREAM_HEAD, _ATTEMPT_STREAM_TAIL)`
  (`session.mojo:914-915`). Phase 4's `--json` stream cap should reuse these constants.
  `clamp_stream` is a pure session-side head+tail clamp with a `truncated` flag
  (`src/mtest/session/clamp.mojo:35-60`).
- **Flooding children:** `notes/phase-03-notes.md` has no dedicated flooding-capture
  entry; the rationale lives in code — `clamp.mojo:3-9` explains that keeping every
  attempt's full capture "would let a flooding crash loop blow up memory in proportion
  to the retry budget", hence the bounded excerpt. Classification: **COSMETIC / matches.**

---

## M. `--durations` / deterministic tail

**EXPECTED:** no `-n K ≡ -n 1` machinery; `--durations` exists. **FOUND:** `-n`/`--workers`
is refused (item K) — no worker-comparison machinery exists. `--durations` is served:
flag spec `cli/flag_spec.mojo:107`, parsed to a non-negative Int
(`cli/parser.mojo:107-110, 426-427`), config field `config.durations` threaded to the
console (`src/main.mojo:158`, `console.mojo:544-547`). Deterministic tail:
`_render_slowest_files` (`console.mojo:1175-1204`) sorts accumulated RUN-ONLY durations
by `_slower` = duration descending, path ascending on ties (`console.mojo:477-484`,
`_sort_slowest` `487-503`), prints `min(N, files_run)` rows under a header stating the
ACTUAL row count, survives `-q`. Only files that reached the run step
(`duration_seconds > 0.0`) are recorded (`console.mojo:877-885`). Classification:
**COSMETIC / matches.**

---

## N. collect path under `--shard`

**EXPECTED:** `collect` output still byte-pure under `--shard`. **FOUND:** `run_collect`
partitions `disc.run_files` by the same shard partition as a run
(`session.mojo:3626-3632`), sorts the listing lexicographically (the frozen order,
`session.mojo:3606-3607`), and `main` prints it OUTSIDE the reporter seam so stdout
carries only the listing while diagnostics go to stderr
(`session.mojo:3609-3612`, `src/main.mojo:124-147`). Byte-pure. Classification:
**COSMETIC / matches.**

---

## O. exit-code function

**EXPECTED:** `exit_code_for` untouched; Phase 4 resolves codes AROUND it, never inside.
**FOUND:** `exit_code_for(outcomes: List[Outcome]) -> Int` is pure/total, maps the RUN
multiset to 1/5/0 only (`src/mtest/model/exit_code.mojo:27-47`); codes 2/3/4 are
control-flow codes resolved in the session and main, not inside it
(`exit_code.mojo:5-8`, session precedence `session.mojo:3478-3491`). Untouched through
Phase 3. Classification: **COSMETIC / matches.**

---

## P. Dogfood task shape as landed

**EXPECTED (sequential):** `build/mtest -I build -I tests/support --build-arg=-Xlinker
--build-arg=<native test object> tests/`. **FOUND — matches exactly**
(`scripts/self_host_check.py:116-125`): argv = `[MTEST, "-I", "build", "-I",
"tests/support", "--build-arg=-Xlinker", f"--build-arg={NATIVE_OBJECT}", "tests/"]`,
where `MTEST = build/mtest` (`:34`) and `NATIVE_OBJECT =
build/native/mtest_exec_native_test.o` (`:35-37`). No `-n 2`/`--serial` forms. The pixi
`test` task runs this and depends on `build-bin` (`pixi.toml:133-134`). The packaging
`package_check` should mirror these flags. Classification: **COSMETIC / matches.**

---

## Q. Layout & task-name mapping — one item to FLAG

Restructure confirmed. Source tree (from `find src`): `src/mtest/{model,exec,session,
report,cli,config,discover,select,protocol,cache}/`; the native adapter is referenced as
a linked object `build/native/mtest_exec_native*.o` (built by `scripts/build_native.py`
via `pixi run build-native`, `pixi.toml:43`), statically linked into `build-bin`
(`pixi.toml:50`, `-Xlinker build/native/mtest_exec_native.o`).

Pixi tasks (`pixi.toml:29-162`):
- **ci** (`[tasks.ci]` `:151-163`) depends-on: `fmt-check`, `harness-check`,
  `safety-check`, `postfork-check`, `native-check`, `build`, `transcripts-check`,
  `test-direct`, `test`, `e2e`.
- **build** = `bash scripts/build_pkg.sh` (`:38`); **build-native** (`:43`);
  **build-bin** (`:50`, depends on native).
- **fmt** / **fmt-check** = `mojo format src tests e2e` (+ `git diff --exit-code`)
  (`:57, 61`).
- **e2e** (`[tasks.e2e]` `:143-145`) = `python scripts/e2e_check.py`, depends-on
  `build-bin`. Test lanes: `test-direct`/`test-unit`/`test-integration`
  (`:113-115`) over `tests/unit`+`tests/integration`; **test** (dogfood, item P)
  = `self_host_check.py` (`:133`).
- **ASan/Valgrind lanes exist** but live in a SEPARATE workflow, not `[tasks.ci]`:
  `asan-check` (`:85`) and `valgrind-check` (`:94`), run by
  `.github/workflows/memory-safety.yml` (asan job `:16-18`, valgrind job `:49-51`, both
  `ubuntu-24.04`).

**FLAG (item Q):** a **macOS build lane DID land** — `.github/workflows/ci.yml:56-58`,
job `macos-build` "macOS arm64 build + link" on `runs-on: macos-15`. The brief asks to
flag this so the human decides whether the future package job runs there. The contract
already frames macOS as package-build + link + `--help` smoke, "runtime supervision
remains unverified there" (`docs/cli-contract.md:622-630`). This is NOT a semantic change
to the event seam or capture bounds, so it is **not MATERIAL** by the brief's definition
— it is a decision-requiring FLAG. No event-seam or capture-bound change came from the
restructure branch (events/bounds audited above are intact).

---

## R. AGENTS.md Lessons Phase 3 added (reporters/serialization/composition)

- **Composite-reporter comptime-variadic lesson + its five traps** — present,
  `AGENTS.md:350-373`. A `struct Composite[*Rs: Reporter]` stores
  `var reporters: Tuple[*Self.Rs]` and dispatches `comptime for i in range(Self.N):
  self.reporters[i].handle(e)` with `comptime N = Self.Rs.__len__()`. The five traps:
  (1) inside the struct the pack must be `Self.Rs`, never bare `Rs`; (2) the constructor
  must accept a pre-built `Tuple[*Self.Rs]` and move it in — a `VariadicPack` cannot be
  splatted into `Tuple`'s constructor, so build the tuple at the call site
  (`Composite(Tuple(A(...), B(...)))`) and let `Rs` be inferred; (3) the iteration length
  must be the comptime `Self.Rs.__len__()`, never runtime `len(tuple)`; (4) reading a
  stored reporter's state back needs no `rebind` (a comptime index recovers the concrete
  type); (5) the composite itself cannot conform to a `Copyable`-bounded trait even when
  every element does (`Tuple[*Self.Rs]` isn't synthesizably `Copyable`) — use it as the
  top-level type a consumer is generic over, never nested inside another struct.
- **Closed-vocabulary struct must be `ImplicitlyCopyable`; owning structs stay
  `Copyable, Movable` with explicit `.copy()`** — `AGENTS.md:409-416`. Directly governs
  `EventKind`/`Outcome`/`ParseDisposition`/`AttributionDisposition` (ImplicitlyCopyable)
  vs the owning `Event`/`Summary` (explicit copies) that the serializers consume.
- **Tuple RETURN-type annotation `-> (Bool, Int)` does not compile — return a small
  `@fieldwise_init` struct** — `AGENTS.md:405-408`. Relevant to any multi-value
  serializer helper.
- **`fn` fully removed; use `def`** (`AGENTS.md:374-376`) and **String↔C-string/bytes
  recipes** (`AGENTS.md:345-349`) — apply to writing the reporter/serializer code.
- Layer map notes `report` = `src/mtest/report` (event consumers, reporters),
  `build` = packaging (`AGENTS.md:249, 256`); event fan-out is comptime composition, and
  the first console reporter already flows through it so the seam is proven
  (`AGENTS.md:71-73`).
