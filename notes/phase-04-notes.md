# Phase 4 notes — reporters

The durable record for the reporters phase: the three machine-consumed report
formats (`--json`, `--junit-xml`, `--gh-annotations`), the console polish pass,
and the conda packaging that ships the built binary.

The next three sections are the maintainer's manual, out-of-band checklists —
DOCUMENT only, nothing here performs any of these steps. The first one **blocks
the phase's final report** until a maintainer records its result; read it first.

## Manual phase-exit gate: real-Actions annotation rendering

Everything about `--gh-annotations` is verified in-repo without a network: the
unit tests pin the renderer shapes, the sort, the caps, and the escaping; the
console tests pin the stop-commands fencing; `scripts/annotations_check.py` is
the local proxy for what GitHub itself does with the workflow-command lines; and
the e2e cells drive the real binary end to end (mode resolution, the caps, the
`--json -` conflict, and the hostile-console fencing with a forged command and a
seeded resume delimiter).

What the in-repo gates **cannot** prove is that GitHub's own Checks runner places
the inline annotations where we expect and neutralizes a fenced forge exactly as
the local proxy models it. That is a **manual, out-of-band step for the
maintainer** and it **blocks the phase's final report**. Nothing here pushes,
publishes, or dispatches anything — running it is the maintainer's call, in the
maintainer's fork, on the maintainer's push.

### Checklist (maintainer runs this by hand)

1. **Package the binary.** `pixi run build-bin` and confirm `build/mtest` runs
   locally (`./build/mtest --version`).
2. **Stand up a deliberately-failing tree.** A throwaway directory with:
   - a file with two or three ordinary per-test `assert` failures (the `::error`
     rows, with `line=` taken from the `At <path>:<line>:<col>:` detail);
   - a file that crashes or times out (a file-level `::error` with no `line=`);
   - optionally a flaky file under `--retries 1` (the `::warning` row);
   - a file whose test prints a **forged** `::error …` line and a **seeded**
     `::stop-commands::<guess>` / `::<guess>::` pair to its own stdout (the
     hostile-console case — the same shape as
     `e2e/annotations/test_console_forger.mojo`).
3. **Run with annotations on.** `mtest --gh-annotations on --show-output all
   <tree>` (or `--gh-annotations auto` with `GITHUB_ACTIONS=true` set). Confirm
   locally, before pushing, that stdout ends with the per-kind-grouped tail
   (node-id-sorted `::error` block, then `::warning` block, then one `::notice`)
   and that every echoed captured region is wrapped in `::stop-commands::<token>`
   … `::<token>::` with a fresh 128-bit token per run.
4. **Add a throwaway workflow.** A minimal job in the maintainer's own fork that
   checks out the failing tree, builds `mtest`, and runs step 3 as a normal
   build step (so its stdout is the step's stdout GitHub scans).
5. **The maintainer's push, the maintainer's run.** Push to the fork, let the
   throwaway workflow run, and open the run in the GitHub UI.
6. **Confirm, in the real Checks UI:**
   - the per-test `::error` rows land as inline annotations on the right files
     and lines; the crash-class and flaky rows land as file-level
     error/warning annotations; exactly one `::notice` summary appears;
   - the caps hold (no more than ten error and ten warning annotations for the
     step, with the `… and N more …` aggregate line accounting for the rest);
   - the **forged** `::error` from the hostile file does **not** appear as an
     annotation (it was sealed inside the stop-commands fence), and the
     **seeded** resume delimiter did not re-enable commands early;
   - workflow commands are re-enabled before mtest's own tail (the always-runs
     epilogue), so mtest's real `::error`/`::notice` lines are processed.
7. **Tear down** the throwaway workflow and tree. Record the run URL (or a
   screenshot) in the phase's final report as the evidence that the manual gate
   passed.

Until step 6 is confirmed by the maintainer, the phase's final report stays
open on this item.

## Manual checklist: publishing the conda package

`mtest` ships as a conda package built by rattler-build from
`recipe/recipe.yaml`, built **from source** inside an isolated build
environment, never repackaging an already-linked binary. Today the package is
built and consumption-gated in CI (a dedicated `package` job: build → install
into a fresh scratch environment from a LOCAL channel → loader-clean probe →
run the installed binary's own suite → tarball-fallback smoke), but it is
**not published anywhere**. Nothing in this repository's tooling uploads a
package to any conda channel, and publishing is the maintainer's call ALONE —
no CI job, pixi task, or script here should ever gain that ability without an
explicit maintainer decision.

### Checklist (maintainer runs this by hand, only if and when publishing is decided)

1. **Confirm the version.** `pixi.toml`'s version and the binary's own version
   string are checked against each other and the released version by a CI
   gate; confirm it is green on the commit being published.
2. **Build the package locally.** `pixi run package-build` (rattler-build →
   a local conda channel directory; nothing uploaded by this step).
3. **Run the consumption gate locally.** `pixi run package-check` (installs
   the built package into a fresh scratch environment from that local
   channel, proving it pulls the `mojo-compiler` run dependency; runs the
   installed binary's own suite; smoke-tests the tarball fallback form).
4. **Choose a channel.** Publishing means uploading the built `.conda`
   artifact to a real conda channel. WHERE (a personal channel, an
   organization channel, a public index) and WHETHER to publish at all is
   entirely the maintainer's decision; nothing in this repository names a
   target channel today.
5. **Upload by hand**, outside `pixi run ci`, outside any workflow this
   repository defines — using the target channel's own upload path. This is
   a manual, out-of-band step this repository deliberately does not
   automate.
6. **Record what was published.** Note the version, the channel, and the
   artifact's checksum somewhere durable (a release note, a tag) so a future
   consumer can verify what they installed.
7. **The macOS caveat.** A macOS target is declared in the recipe and the
   package channels solve for it, but no CI runner has ever built, installed,
   or executed the packaged artifact there. If a maintainer publishes a
   macOS build, treat its packaged-artifact runtime behavior as unverified
   until it is checked by hand.

Running `pixi run package-build` or `pixi run package-check` is always safe —
neither uploads or publishes anything. Only step 5, performed by hand, does.

## Optional: console PNG captures

`notes/console-captures/` holds committed, human-facing ANSI text captures of
the real console output for representative runs (pass, fail, verbose, quiet,
no-color) — see that directory's `README.md` for what each shows and how to
regenerate them. Turning one of those captures into a PNG screenshot for a
docs page is an **optional maintainer step**, not part of this repository's
automation: render a capture in a real terminal and screenshot it, or pipe it
through any terminal-to-image tool that understands ANSI escapes. Nothing
here produces a PNG; the text captures are the only committed artifact.

## Console polish pass — user-visible message audit

A recursive inventory of every USER-VISIBLE message / output site, its verdict
(keep / fix / exclude), and the rationale. "User-visible" means bytes a person
running `mtest` (or a product-facing tool) can read on their terminal — not
machine contracts, not gate tooling, not test fixtures.

### Scope audited

- **All of `src/`**, recursively: `src/main.mojo` (the pre-session
  internal-error prints), the console reporter, the annotations renderer, the
  session's warnings and pre-session raises, and the exec diagnostics that reach
  a human through the console's `INTERNAL-ERROR` banner.
- **`native/`** — the C adapter, for any bytes it writes directly to a user.
- **Product-facing `scripts/`** — messages a person sees when they run a script
  as a tool (not the CI gates' own PASS/FAIL lines).

### Classified exclusions (named, with why)

- **The transcript/protocol ORACLE — `tests/snapshots/protocol/**` and its
  gates. UNTOUCHABLE**, byte-frozen. No polish may alter an oracle byte; a fix
  that would need one is out of scope by rule.
- **`MODEL` (`src/mtest/model/**`) and `exec/` + `native/` — FROZEN**, out of
  scope for edits in this phase. `exec/`'s `raise Error("exec: …")` diagnostics DO reach a user (via the
  console `INTERNAL-ERROR` banner), but the strings live in a frozen layer, so
  they are audited-but-excluded from edits. `native/` writes no diagnostic bytes
  of its own — every failure is returned as an errno/status code and rendered by
  the Mojo layer — so there is nothing user-facing to change there.
- **Machine-contract formats** — `json_stream.mojo` / `json_stream_reporter.mojo`
  (the NDJSON stream) and `junit.mojo` / `junit_reporter.mojo` (the JUnit XML).
  These are byte-stable machine contracts consumed by other tools, not human
  prose; polishing their wording would be a contract change, not a console
  polish. Excluded. (The JUnit `message`/`type` attributes are classification,
  guarded by the `junit_canonicalize.py` invariant noted in Fix 2.)
- **CI gate tooling in `scripts/`** — `e2e_check.py`, `junit_check.py`,
  `harness_check.py`, `safety_check.py`, `postfork_check.py`, `native_check.py`,
  `asan_check.py`, `valgrind_check.py`, `main_open_check.py`, `build_*`, etc.
  Their `OK`/`FAIL` lines address the maintainer/CI, not a product user; they are
  gate infrastructure, not the shipped console. Excluded as not-product-facing.
- **Test-only strings** — `tests/**` and `e2e/**` fixture docstrings and
  assertion text. Test scaffolding, never shipped. Excluded.
- **No internal debug-only user paths were found** — there is no hidden
  `--debug`/verbose-trace channel emitting to users beyond the audited surfaces.

### Audit table

| Site / class | What it is | Verdict | Rationale |
|---|---|---|---|
| `src/main.mojo` collect-fault `except` (`run_collect`) | pre-session internal-error print before exit | **FIX** | On a secondary `_close_runtime` failure it exited 3 WITHOUT printing the primary diagnostic — the operator lost the "why". Moved the primary `_eprintln` above the close check so both close paths print it. |
| `src/main.mojo` `--json` open-fault `except` | pre-session internal-error print | **FIX** | Identical dropped-primary defect; same minimal reorder; removed the dead `return` after `exit(3)`. |
| `src/main.mojo` `--junit-xml` open-fault `except` | pre-session internal-error print | **FIX** | Same dropped-primary defect: print the primary `junit_error` on BOTH the clean-close and failed-close paths; removed the dead `return` after `exit(3)`. |
| `src/main.mojo` `run_session` propagated-usage-error `except` | pre-session/boundary print before exit 4 | **FIX** | Same dropped-primary defect on the secondary-close path; same minimal reorder. |
| `src/main.mojo` `runtime.open()` fault `except` (lines ~124-142) | internal-error print | **KEEP** | Already prints the primary on both close paths (`primary` / `primary; cleanup`); it is the correct model the four fixes above were aligned to. Pinned by `scripts/main_open_check.py` — untouched. |
| `src/main.mojo` help/version/usage-error seam prints | help text, version, usage error to stderr exit 4 | **KEEP** | Consistent and correct; documented seam exceptions. |
| `src/mtest/report/console.mojo` verdict tokens, banners, sections, summary band, warnings, TRY/ATTRIBUTION lines, DRIFT/PRECOMPILE/COMPILE-TIMEOUT banners, slowest-files list | the entire human console design language | **KEEP** | Reviewed end-to-end: fixed glyph-free ASCII vocabulary, color redundant to the tokens, consistent phrasing, honest disposition notes. No wording defect found; polishing working prose here would be churn. |
| `src/mtest/report/annotations.mojo` module docstring | the `file=` path root convention | **FIX** | The `file=` values are run-root-relative and GitHub anchors them at the repo root; that convention was only inherited transitively. Stated it explicitly in the docstring. (No emitted line changed.) |
| `src/mtest/report/annotations.mojo` emitted `::error`/`::warning`/`::notice` lines | workflow-command payloads | **KEEP** | Unit-pinned shapes, caps, sort, escaping. Correct and consistent; not touched. |
| `src/mtest/report/annotations_reporter.mojo`, `composite.mojo` | thin sinks / fan-out | **KEEP** | No user prose of their own. |
| `src/mtest/session/session.mojo` warnings (`stale-exclusion`) + drift/precompile facts | session facts routed through console events | **KEEP** | Rendered by the console; wording consistent. |
| `src/mtest/session/session.mojo` double-fault raises (`primary` / `primary; cleanup`) | error-propagation strings | **KEEP** | Already preserve the primary on both cleanup paths — the correct pattern; no defect. |
| `src/mtest/cli/parser.mojo`, `help_text`, `version_text` | usage errors + help/version | **KEEP** | Audited; consistent, self-describing. No defect. |
| `src/mtest/exec/**` `raise Error("exec: …")` diagnostics | surfaced via the console `INTERNAL-ERROR` banner | **EXCLUDE** | Reaches a user, but lives in the FROZEN exec layer. Audited, not edited. |
| `native/mtest_exec_native.c` | C adapter | **EXCLUDE** | FROZEN, and writes no user-facing diagnostic bytes (errors returned as codes). |
| `scripts/junit_canonicalize.py` mask site | determinism-tool, user-runnable | **FIX** | Added a one-line invariant comment: only `time` + volatile text bodies are masked; `message`/`type` attributes ride through, so a volatile value FAILS the e2e loudly rather than passing silently. |
| `scripts/junit_canonicalize.py` `OK`/`FAIL` result lines | tool output | **KEEP** | Clear and consistent. |
| `e2e/manifest.json` two annotation fixtures | spec-of-record disposition tokens | **FIX** | Both used `"disposition": "VALID"`, absent from the file's own `disposition_meaning` map. Changed both to `"PARSED"` so the spec is self-consistent (documentary only; no script consumes the value). |
| other `scripts/*` (gate tooling, build scripts) | maintainer/CI messages | **EXCLUDE** | Gate infrastructure, not the shipped product console (see exclusions). |

### PTY/ANSI captures

`scripts/maintenance/pty_capture.py` drives the built binary under a real PTY
and records the console's raw ANSI output for representative scenarios into
`notes/console-captures/` (`pass-pty`, `fail-pty`, `fail-verbose-pty`,
`fail-quiet-pty`, `fail-nocolor-pty`). These are DOCUMENTATION of the console's
real appearance, deliberately NOT wired into any gate — see that directory's
`README.md` for what each shows and how to regenerate. PNG screenshots remain an
OPTIONAL maintainer step, documented there, not produced here.

## Reconciliation: the event-contract audit going into this phase

Before the serializers were written, the merged event model on the tree was
read end to end against what a machine-reporter phase needed to be true, with
every claim checked against the actual file and line, no source modified. The
audit covered the event-payload shapes, an outcome finding, the reporter seam
shape, interrupt semantics, the console's write path, the single-writer
guarantee, and the source-tree/task-name layout. Each item below is
classified **material** (changes what a serializer author must assume) or
**cosmetic** (matches what was already expected, no design consequence).

### Event-payload audit

- **Event set and ownership.** Exactly eleven event kinds exist; no
  worker-pool constructs (a `Progress` kind, a `SessionStarted.workers`
  field, a `FileFinished.serial` field) exist yet. No rogue later-phase code
  had landed early. **Cosmetic — matches.**
- **`PrecompileFailed` casualties.** Both a `casualty_count` integer and a
  full `casualties` string list exist; the session passes the complete
  casualty file list (every gate plus every run file), and a non-empty list
  is authoritative for the count over the bare integer. **Cosmetic —
  matches.**
- **`FileFinished` truncation flags.** Before this phase's model change,
  `FileFinished` carried no truncation booleans at all — `stdout_truncated`/
  `stderr_truncated` existed only on `AttemptFinished`, even though the
  underlying process result already carried both flags and the capture layer
  already recorded the overflow signal (plus a spliced human marker naming
  the omitted byte count, never a structured byte total). That is the
  expected "not yet propagated" state, not a surprise — closing exactly that
  gap is this phase's own model commit. **Cosmetic — expected, no
  unaccounted total to fold.**
- **Event-ordering invariants.** A file's per-test rows stay contiguous, its
  attempt records are appended in ascending attempt order and always precede
  the terminal verdict, and precompile attempts run at the session level with
  no `FileFinished` ever emitted for them. **Cosmetic — matches.**

### The one material finding: FLAKY is an emitted outcome

The single material delta going into this phase: a flaky file's outcome is
**not** modeled as a plain PASS plus a boolean flag with the FLAKY value held
back. A late pass following a crash-class retry sets the file's outcome to
the FLAKY value itself, and that is the value a serializer sees on the
finished-file event and the value the run summary tallies. The flaky flag and
the attempts-used count ride the same event, and FLAKY is still correctly
excluded from the failing set, so exit codes are unaffected — a flaky-only
run still exits clean. Only the SHAPE of the value differed from the initial
assumption, never the pass/fail semantics.

This is legitimate, contract-sanctioned behavior — the CLI contract already
documented FLAKY as an emitted, passing outcome, mapped in JUnit to a passing
testcase carrying a retry count — so reconciling it required no design
change to the serializers, only a corrected assumption: a reporter must treat
FLAKY as a first-class, nonetheless-passing outcome, and must never assume a
flaky file's outcome equals plain PASS. A secondary, purely cosmetic note:
one outcome-vocabulary docstring had gone stale, still describing FLAKY as
unemitted; the console-polish pass (above) folded that correction in.

### Seam shape, interrupt semantics, the console's write path, and single-writer dispatch

- **Reporter seam.** The reporter trait still has exactly one method — total,
  non-raising, no return value, no finalizer — and the fan-out composite
  still just forwards to each element's handler. The trait did not grow a
  fallible surface; this phase's status-latch-plus-fallible-finalize pattern
  (used by the JSON stream and JUnit reporters) is layered on top of that
  exact unchanged shape, read off the concrete reporter value at the call
  site. **Cosmetic — matches; the planned extension fits the shape as-is.**
- **Interrupt / `SessionFinished`.** SIGINT/SIGTERM still produces a partial
  summary AND the session's terminal event still fires unconditionally, with
  exit code 2 and NOT-RUN accounting for the unstarted files; crash
  attribution is skipped under interrupt, but the terminal event never is. A
  reporter cannot assume "no terminal event" is possible — it always gets
  exactly one. **Cosmetic — matches; confirmed, not a stop condition.**
- **The console's write path.** The console reporter writes nothing itself:
  it accumulates three owned string buffers and exposes them through one
  `output()` call; there is a single flush point, once, at the very end, even
  on a partial or interrupted run. The console never touches a file
  descriptor or picks one — the caller owns the destination. That single
  relocation point is exactly what lets the byte-pure JSON stream own stdout
  while the console relocates to stderr, with zero console bytes ever
  landing on the stream's own descriptor. **Cosmetic — matches; confirmed
  the write path a machine-stream phase needed to be true.**
- **Single-writer dispatch.** The session is sequential by contract — no
  thread is spawned anywhere in the session layer — so every reporter
  dispatch across a run, a selection, and a crash-attribution pass is
  serialized on the one parent thread. **Cosmetic — matches; confirmed
  rather than assumed, and it is the seam a future concurrency pinning test
  would attach to.**

### Layout and task-name mapping

The source-tree layout and the CI task graph both matched what this phase
assumed going in — the same task names, the same gate dependencies, ASan/
Valgrind living in a separate memory-safety workflow rather than the main
gate. One non-semantic item surfaced for a human call rather than a defect: a
macOS build lane (build, link, and an `--help` smoke run) had already landed
in CI ahead of the packaging work. It changes no event seam and no capture
bound, so it carried no design consequence for the reporters — the contract
already framed macOS runtime supervision as unverified, and that framing
held.

**Net result:** one material finding (the FLAKY shape), reconciled without
any change to the reporter design — only to what a reporter author must
assume about the outcome vocabulary. Everything else audited as cosmetic,
matching expectation.

## Spike verdicts: linkage, packaging, and schema

A short pre-implementation spike answered three tooling questions before the
packaging and JUnit-schema work was built, entirely in throwaway scratch
environments: no repository manifest was touched, no `mojo run`, nothing
pushed or published. Toolchain throughout: `mojo ==1.0.0b2`.

### Linkage verdict

The built binary is **not loader-clean**: it carries a direct link dependency
on the Mojo compiler runtime's shared library, whose own transitive closure
(the C++ standard library plus several Mojo runtime support libraries)
resolves entirely inside the build host's toolchain environment. The
build-host link path baked into the binary is an absolute path into the
local build environment and cannot be relied on after installation.
Neutralizing that link path on a scratch copy of the binary and running it
with an empty library path and no toolchain on `PATH` reproduces the real
failure (a missing shared library at load time), proving the dependency is
real rather than merely masked by the build-host path. Every one of those
transitive libraries is owned by the Mojo compiler's own conda package at the
pinned version — so the conda recipe declares that package as a **run**
dependency, not a build-only one. The native adapter, by contrast, is
statically linked and adds no runtime library dependency of its own.

### Packaging build verdict

Feeding the pinned Mojo toolchain into a rattler-build recipe's isolated
build environment works cleanly: the toolchain installs and runs inside
rattler's own sandbox, so the recipe builds `mtest` from source there,
mirroring the repository's own build pipeline exactly. The prebuilt-binary
alternative — repackaging an already-linked host binary instead of building
from source in the sandbox — was **not needed and is not taken**; there is no
reproducibility trade-off forcing that choice. A full local-channel loop
(build a package into a local channel, install it into a fresh scratch
environment, execute the installed binary) was walked end to end with a
throwaway stub package to prove out the exact command sequence; the same loop
applies to the real package, which additionally must pull the Mojo compiler
runtime at install time per the linkage verdict above.

### Schema proof

Two JUnit-flavored XML schemas were vendored and read directly, not assumed.
The Jenkins xUnit plugin's `junit-10` dialect (MIT-licensed) is the
**primary** validation dialect. A Maven Surefire schema (Apache-2.0) was
checked only for tag-name provenance and confirmed to be a different,
incompatible dialect: it requires a single bare `<testsuite>` root with no
wrapping element, and rejects a genuine multi-suite document with "no
matching global declaration available for the validation root" — proof it is
not the dialect this project validates against.

Reading the primary schema directly settled the open questions:

- The root wrapping element does **not** accept an aggregate `skipped`
  attribute (a real validator rejects it outright), while each individual
  per-file suite element **does** accept an optional `skipped`. The chosen
  approach: carry `skipped` on every per-file suite, drop it from the root
  aggregate, and move that root-level arithmetic into a structural checker
  that runs alongside schema validation rather than trying to hold it in the
  schema.
- The flaky/rerun element family (a shared content type covering a
  retried-pass, a retried failure, and a retried error) **requires** a
  `type` attribute — a validator rejects the element outright without one.
  The renderer must emit `type` on every flaky/rerun element it writes.
  (Confirmed with a negative probe: a document missing `type` fails
  validation with an explicit "attribute is required but missing" error.)
- A suite-level captured-output element **is** accepted directly under a
  suite in the primary dialect — no special-cased fallback encoding is
  needed at the schema level for that case.
- Per-testcase timing and a suite-level timestamp are both **optional** in
  the schema — omitting either validates cleanly, so omitting them needed no
  escalation and no contract change.
- Every other probed shape (the root wrapper itself; a per-file suite with
  its required name/tests/failures/errors; node-id-sorted, dotted-classname
  test-case rows; literal bracket-sentinel names; a rerun-exhausted primary
  failure paired with its rerun record; per-suite aggregate counts)
  validated exactly as designed.

The shipped validation gate follows directly from this reading: the
`skipped` aggregate lives on every per-file suite (schema-valid) and never on
the root wrapper (schema-invalid there), with a companion structural checker
that recomputes the root-level totals from the child suites and asserts
every flaky/rerun element carries its required `type` attribute. No probed
feature produced an unhandled case, and nothing required a human escalation:
no contract-required attribute was rejected by the schema, no acceptable
base-document shape was rejected, and the packaging verdict above meant no
reproducibility trade-off needed a human call either.

## XSD findings and hostile-corpus behavior across the three emitters

### What the schema reading shaped in the shipped renderer

The JUnit renderer turns the typed event/outcome model into the vendored
`junit-10` dialect directly per the schema proof above: a root wrapper that
carries no `skipped` attribute (an arithmetic total, not a schema attribute
at that scope); per-suite counts recomputed from the actual rows so a
declared attribute can never disagree with the body; a decimal-seconds
duration; a dashboard-safe dotted classname; and the frozen node-id row order
with a bracket-sentinel carve-out (a name containing the node-id separator is
its own key; a bracket-form sentinel keys by path plus the bracket name). A
dedicated CI gate builds and runs a small emitter over the real reporter and
runs its shipped output through both schema validation and the structural
arithmetic checker, confirming every scenario validates and a tampered copy
is rejected; the Mojo unit tests separately pin the renderer's structure, the
node-id sort, the single-sentinel invariant, and the event-to-fragment
mapping.

### Hostile-corpus behavior

mtest renders three machine-consumed streams from the same untrusted,
child-process-controlled text: the JSON/NDJSON event stream, the JUnit XML
report, and the GitHub Actions annotation lines. All three share one Layer-2
escaping module rather than duplicating the same logic three times, so one
hostile-input test corpus proves all three contexts at once instead of three
copies drifting apart. Every string reaching these escapers has already been
lossily decoded to valid UTF-8 upstream (invalid bytes become the Unicode
replacement character), so the escapers themselves never re-decode and act
byte-for-byte.

- **JSON/NDJSON.** Control bytes, quotes, and backslashes are all escaped;
  the result is guaranteed to be a single line, so a smuggled newline in
  captured output can never forge a second stream record, and an
  NDJSON-lookalike string embedded in captured text (a fake `{"event":...}`
  payload) is fully neutralized rather than merged into the real stream.
- **JUnit XML.** Two escaping contexts are kept separate and tested
  separately: in element TEXT, a literal quote passes through unescaped and
  tab/newline/carriage-return pass through literally (only `&`, `<`, `>`, and
  raw control bytes are escaped or replaced); in an XML ATTRIBUTE, the quote
  is entity-escaped and tab/newline/carriage-return become numeric character
  references so they can never reappear as literal bytes inside a quoted
  attribute value.
- **GitHub annotations.** Percent, carriage-return, and line-feed are
  percent-encoded, with percent escaped FIRST so a literal percent-encoded
  sequence already present in hostile captured text is never double-escaped
  and a literal CR/LF is never left raw inside a single-line workflow
  command. Colon and comma stay literal in a plain annotation message but are
  additionally escaped in a structured property value, matching the two
  different GitHub Actions escaping rules for those two contexts.
- **The stop-commands fence.** Hostile captured console output can contain a
  forged workflow-command line and a guessed resume token aimed at
  re-enabling GitHub's own command processing early. Every echoed captured
  region is wrapped in a collision-proof fence whose token is minted from a
  real entropy source AFTER the producing child has already exited, never
  present in any child's own environment or arguments, and regenerated until
  the resume delimiter is provably absent from the payload being fenced.
  Restoration runs through an always-runs epilogue before mtest's own
  annotation lines are emitted, so a forged command inside a fenced region
  can never land as a real annotation and a seeded guess can never re-enable
  command processing early.

This escaping layer only has to neutralize hostile BYTES inside an otherwise
well-formed event; a separate, earlier layer already resolves hostile
CHILD-PROCESS BEHAVIOR into a typed, honest outcome before any event is ever
built. A dedicated hostile-fixture corpus proves that: a suite that runs
clean but prints no parseable report at all becomes a malformed-suite verdict
rather than a false pass; a suite that prints a complete report and then
appends a second, forged complete report for the same file is recognized as
an ambiguous double-report and also becomes a malformed-suite verdict, never
a laundered pass; a suite that prints a superficially report-shaped but
off-grammar block is recognized as drift from the pinned toolchain's own
format and routed to the internal-error tier, contributing nothing to the
run's outcome tally; and a suite that floods its own output past the capture
bound with no valid report surviving in the retained tail becomes a capture
overflow, never a pass and never silently truncated into something that
looks clean. By the time any of these reach a reporter, the hostility has
already been resolved to one honest, typed outcome — no emitter ever has to
special-case a forged or malformed child report itself.

## Per-task lessons

A short ledger of lessons harvested while building the three reporters and
the packaging around them — generalized past the specific line numbers they
came from.

- **Shared escaping beats three copies.** Centralizing the JSON, XML, and
  GitHub-annotation escapers in one module meant one hostile-input test
  corpus could prove all three contexts at once; three independent
  escaping implementations would have drifted at different rates under
  different reviewers.
- **A field existing on a struct is not the same as a field being
  populated.** The truncation flags already existed on the shared event
  storage, but a private per-attempt conversion type was silently dropping
  them before they ever reached a real event. Every construction site
  (the plain run loop, the selection path, the collection probe) had to be
  walked by hand, and the honest default was kept for build-only or purely
  synthetic events with no real captured run behind them.
- **A live stream and a spooled document need different finalize
  semantics, on purpose.** The JSON stream aborts the whole run the moment
  a write fails, because a live consumer already depends on stream
  integrity mid-run; the JUnit spool latches silently and only surfaces at
  finalization, because a document assembled once at the end can afford to
  keep running and report the failure honestly afterward. Both use the same
  status-latch pattern at different urgency — collapsing the two into one
  behavior would either kill a run needlessly or hide a real failure too
  long.
- **Destination validation needs two stages, not one.** A syntactically bad
  destination path is a usage error caught before any build runs; a runtime
  open or write failure is a session-time internal error caught only once
  the run is already underway. Putting both checks at the same stage either
  wastes a whole run's work on a knowable-in-advance mistake, or defers a
  parse-time mistake past work that could have been skipped.
- **An atomic rename-on-success only works for a document assembled once.**
  The JUnit report is written to a temp path and renamed onto the real
  destination only after a verified complete write, so a prior report is
  never left truncated. A live stream that must be readable while it grows
  cannot get that same guarantee, and is documented honestly as writing
  live rather than atomically.
- **A broken downstream pipe needs an explicit, scoped signal carve-out.**
  Without ignoring the broken-pipe signal for the run's lifetime, a
  consumer that closed its end early killed the whole process outright
  instead of letting the affected reporter latch an ordinary write failure
  and resolve to an honest, reported exit code; the previous signal
  disposition is restored once the run finishes.
- **Two independent FFI declarations of the same C symbol in one binary is
  a link-time conflict, not a runtime one.** Adding a second, differently
  scoped file-descriptor probe that declared the same libc symbol a
  standard-library test facility already declared collided the moment both
  landed in the same compiled unit. Routing through the existing wrapper
  instead of a second raw declaration removed the conflict entirely.
- **Read the schema; do not assume it.** Two attributes that looked
  required by convention — an aggregate flag on the outermost wrapper, and
  a per-row timing value — turned out to be, respectively, disallowed at
  that scope and genuinely optional, once the real schema was read and
  probed with deliberately-broken documents. Both were caught before the
  renderer shipped rather than discovered later against a real validation
  gate.
- **A regression guard is only proven by watching it fail.** A promotion
  test that never actually exercised the bug it claimed to catch, and an
  escalation "proof" that was only an eyeballed transcript, both slipped in
  before being caught. Mutation-proving a guard — break the property,
  confirm the test goes red, then revert — is the only way to know a test
  is pinning anything rather than just running successfully.
- **Formatting hygiene runs first, and it is absolute.** The very first
  step of a full verification run reformats the tracked source tree and
  then diffs it; it reds on any uncommitted tracked-file diff at all,
  unrelated work-in-progress included, before any test ever executes. A
  full verification pass needs a clean tracked tree first, not just a
  clean version of the file actually under test.
- **Compiler topology mattered more than test execution.** The old package
  self-host stage spent about 14m43s compiling 77 classified modules one at
  a time. The exhaustive aggregate lanes retained all 907 tests and completed
  in 7m09s on Linux and 6m28s on macOS, while the package-consumption job
  completed in 1m58s after it was narrowed to three artifact probes. Those are
  two distinct gains: aggregation reduced repeated compiler startup, and lane
  specialization stopped package validation from duplicating the exhaustive
  inventory. The 1m58s package result is therefore not a like-for-like 7.5x
  compiler speedup.
- **A test module's executable shape is a cross-lane contract.** Making
  classified modules import-only fixed the primary aggregate topology but left
  ASan and Valgrind trying to compile those modules as standalone programs.
  One entrypoint generator now owns full, focused, and memory-safety execution;
  changing that seam requires auditing every harness consumer, not just the
  first green lane.
- **Instrumentation defines a compatibility boundary below the source.** A
  hosted runner advertised `x86-64-v4`, Mojo emitted AVX-512/EVEX instructions,
  and Valgrind failed in its decoder before Memcheck reached project memory.
  Pinning only the Valgrind-built Mojo binaries to `x86-64-v3` kept the complete
  test and memory policy while making the executable understandable to the
  instrument that runs it.
- **Fault injection needs an explicit process-tree boundary.** A loader
  interposer intended to reject mtest's terminal JSON write was inherited by
  the spawned Mojo compiler on macOS, so the run failed during build instead.
  Clearing the loader variable after the library entered mtest confined the
  fault to its intended process. Printing the committed event sequence exposed
  the boundary error immediately: the stream ended at `internal_error(build)`,
  before any `file_finished` event.
