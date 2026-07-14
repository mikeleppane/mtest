---
name: code-review-and-quality
description: Multi-axis code review for the mtest repo before merge — your own code, another agent's, or a phase branch. Adds transcript-fidelity/provenance, exit-code-honesty, and syntax-drift checks on top of the standard correctness / readability / architecture review, plus the standing dual-adversarial external-review gate. Use whenever you are about to merge, or when asked "is this ready?", "review this", "check this", "look this over". Reviewing AI-generated Mojo is a stronger trigger, not a weaker one — obsolete syntax, a crash silently collapsed into a failure, and over-normalized transcripts are the dominant failure modes.
---

# Code Review & Quality (mtest)

Multi-axis review for this repo. The product is **truthful exit codes and an
honest report** — so a review here checks two things a generic reviewer misses:
that a *crash is never laundered into a failure through any layer*, and that
*every committed transcript is traceable and its normalizer is minimal*. The
output is a **structured Markdown report** — findings grouped by severity, each
with a `file:line` reference and a quoted snippet, then a clear verdict.

This is the *review* moment. Companion skills own the *production* rules; when a
finding is "this violates rule X", **cite the owning skill, don't restate it**:

- [mojo-coding-guidance](../mojo-coding-guidance/SKILL.md) — exit-code fidelity,
  process supervision, named errors, protocol anchoring, allocation.
- [test-driven-development](../test-driven-development/SKILL.md) —
  failing-test-first, transcript/tripwire/known-outcome patterns, exact equality.
- [git-conventions](../git-conventions/SKILL.md) — commit shape, scope,
  transcript provenance in messages, no-AI-attribution.
- [improve-architecture](../improve-architecture/SKILL.md) — layering, seams,
  module depth.
- the global **`mojo-syntax`** skill — the authority on current Mojo syntax.

Project rules live in [AGENTS.md](../../../AGENTS.md) and override this skill.
The triage prompts below name *what to look for*; they are not the rules.

---

## The standing quality gate: dual adversarial external review

This repo carries a doctrine above and beyond a single reviewer's pass. **Every
phase gets a DUAL ADVERSARIAL external review at BOTH checkpoints:**

- **The phase PLAN, before any code is written.**
- **The full phase DIFF (`git diff main...<phase-branch>`), before merge.**

Both checkpoints go to **two external reviewers**: **Claude Opus 4.8 at xhigh
reasoning** and **Codex GPT-5.6-sol at xhigh reasoning**. The reviewers are
briefed to **ATTACK, not admire** — find the deadlock, the masked exit code, the
un-anchored parse, the layering violation, the untested claim; a review that
says "looks good" has failed its brief. **Every finding is triaged
fixed-or-rejected in that phase's notes** (`notes/phase-NN-notes.md`), with the
reasoning recorded — a rejected finding needs a stated reason as much as a fixed
one does. This skill's single-reviewer axes below are what *you* run; they do not
replace the two-model gate, they prepare for it.

---

## Before reading a line

1. **Reproduce the floor.** Run the chain yourself, in order: `pixi run
   fmt-check`, `pixi run build`, `pixi run transcripts-check`, `pixi run test` —
   or `pixi run ci`, which is the same chain, fail-fast (AGENTS.md defines it). A
   red gate is finding #1 — stop and report it, and name *which* stage went red (a
   byte diff in `transcripts-check` and a test failure indict different things —
   see axes 2 and 1). *Exception:* for a **docs-only diff** (Markdown,
   docstrings, comments — nothing under `src/`, `tests/`, `scripts/`, `fixtures/`,
   `goldens/`), a `fmt-check` and a read are enough.
2. **Read the diff with its commit messages.** Does each commit do one thing with
   an honest scope and a *why* body? Does a `refactor` commit actually preserve
   behavior (transcripts untouched, no test weakened)? Does a `perf` commit cite
   its before/after numbers?
3. **Check the frozen zones.** Did the change touch committed goldens
   (`goldens/transcripts/`), the probe `fixtures/`, a pin (Mojo, the platform
   set), the transcript on-disk format, or the frozen CLI contract? Those are
   Ask-first boundaries (AGENTS.md) — if crossed, was it raised *before* the
   commit? **Any regenerated transcript must name the oracle-side reason in the
   commit body**; "regenerated transcripts" with no reason reads as hand-fixing a
   failing gate.

---

## The axes

Walk the diff once per axis. The triage prompts are starting points, not a script.

### 1. Correctness

- Does it do what the commit says, on the stated inputs and the edge inputs
  (empty walk, a single file, a file that exits 0 without running anything, a
  hung binary hitting the deadline, a grandchild that outlives its parent, ≥256
  KiB on one stream)?
- Off-by-one in counts, loop bounds, poll slices, exit-code precedence? A signal
  number confused with an exit code?
- Error paths: does the runner's *own* failure raise a named, located error
  (`"exec: fork() failed: …"`), while a child's nonzero/crash stays **data** (a
  `ProcessResult`), not an exception? Is each named error pinned by an
  `assert_raises(contains=...)` test?

### 2. Transcript fidelity & provenance (this repo's signature axis)

- **Is every committed transcript traceable to a fixture, a scenario, and a
  pinned toolchain?** Each golden's header names `gen_transcripts.py`, the
  resolved mojo version + commit, the os/arch, the normalizer version, the fixture,
  and the scenario. A transcript that cannot be traced to a fixture + a matrix row
  + a pinned version does not get committed — full stop. A header that claims a
  version the toolchain isn't pinned to is a **Critical** finding.
- **Is the normalizer ANCHORED and MINIMAL?** The timing-token rewrite fires only
  on report-grammar lines at or after the LAST `Running <N> tests for` anchor; a
  report-lookalike a fixture *printed* must stay byte-exact. **Over-normalization
  is as serious a finding as nondeterminism** — a normalizer that scrubs a byte
  it didn't have to has erased evidence the parser needs, and a first-match scrub
  that catches a printed impostor line is a **High** finding just as much as a
  leaked timestamp is. The only sanctioned rewrites are the repo-root prefix →
  `<REPO>`, timing tokens → `[ T ]` within the report block, and the stack dump →
  `<STACK-DUMP>`. A new rewrite is a deliberate, reviewed extension, never a quiet
  addition.
- **`transcripts-check` regenerates and diffs — it does not trust a hash.** If a
  change to `transcripts_check.sh` (or the generator) makes it compare a hash, a
  size, or a sampled slice instead of regenerating every transcript to a temp dir
  and diffing byte-for-byte, that's a **Critical** finding — it silently weakens
  the strongest gate in the repo.
- **Are the generator's self-asserts hard failures, on every scenario?**
  `gen_transcripts.py` must hard-assert MANIFEST-equals-matrix, no-absolute-path,
  crash-dies-by-signal, impostor-survives-byte-exact, count reconciliation, and
  byte-identical double generation — not for a sample, not as a warning. A
  disagreement belongs at generation time, not as a baffling Mojo failure later.
- **No absolute path in any golden.** The compiler bakes absolute source paths;
  the normalizer rewrites the repo root to `<REPO>`. An absolute path, a
  `llvm-symbolizer` line, or a raw `Stack dump` header surviving into a committed
  transcript is a **Critical** provenance break.
- **Is the harness still hermetic?** The generator builds committed fixtures and
  runs them; it touches no network. A new script or CI step that downloads
  anything is a **High** finding regardless of justification.
- **Any hand edit to a generated artifact?** Transcripts and MANIFEST are
  regenerated by the script only. A hand-edited byte in any of them is
  **Critical** — it breaks the provenance argument the whole repo stands on.

### 3. Exit-code honesty (the product — after correctness)

- **Is crash ≠ fail preserved through EVERY layer?** A signal-terminated child
  must surface as CRASH, an assertion failure as FAIL, all the way from the
  `waitpid` decode in `exec` through the verdict map in `session` to the summary
  and the process exit code. A `Signaled(signo)` collapsed into `Exited(1)`
  anywhere is a **Critical** finding — it is the exact lie the tool exists to
  prevent.
- **Structured termination is NEVER 128+N.** The raw status is decoded
  structurally (`(raw & 0x7f)` for the signal, `(raw >> 8) & 0xff` for the exit
  code); a signal that surfaces as exit `128 + signo` anywhere — an API, a
  summary, the process's own exit — is a **High** finding. That encoding is the
  shell's; the runner must not adopt it.
- **Is a deadline kill attributable to the runner, not the test?** The runner's
  own SIGTERM/SIGKILL must produce a distinct `TimedOut` outcome, never a
  `Signaled` CRASH — a caller must never have to guess whether a SIGKILL was our
  deadline or the test crashing. Collapsing the two is a **High** finding.
- **Does the exit-code precedence match the contract, exactly?** Usage error
  outranks internal error outranks test failure outranks empty walk outranks
  success. An off-by-one or a swapped rank in that pure function is a **High**
  finding — it's what a CI system trusts.
- **No `mojo run` anywhere.** In the runner, in a script, in a doc example,
  `mojo run` masks crash exit codes to 1 and can JIT-crash in CI (#6413). Any
  occurrence in a path that reads an exit code is **Critical**.

### 4. Readability & maintainability

- Would the next reader follow the supervision loop or the parser without running
  it? Names carry their fact (`signo` is a signal, `code` is an exit code, `pgid`
  is a process group)? Any clever trick that saves three lines but hides the
  fork/drain/reap ordering?
- Every module, struct, and public function has a triple-quoted **Google-style**
  docstring (`Args:` / `Returns:` / `Raises:`, short, folding in
  mutate/allocate/raise)? Flag `#`-comment doc blocks and any plan/spec reference
  ("Phase 3", "P1-D2", "per the handoff") left in code, docstrings, or comments —
  those documents are unpublished; the reference dangles.

### 5. Mojo currency & safety

- **Any obsolete syntax?** `fn`, `let`, `alias`, `@parameter`,
  `inout`/`owned`/`borrowed`, non-`std.` imports, `s[i]` string indexing. A build
  script or doc example that shells out to `mojo package` is stale too — that
  subcommand doesn't exist on `1.0.0b2`, only `mojo precompile` (AGENTS.md
  *Lessons*). Cite the `mojo-syntax` skill. This is the most common defect in
  generated Mojo — check explicitly, including in ```mojo blocks inside docs.
  Training data is stale; `mojo-syntax` is the authority, not memory.
- **FFI and async-signal-safety in `exec`.** The child path between `fork` and
  `exec` calls only async-signal-safe functions — no allocation, no `String`
  building, no error formatting; argv and C strings are built in the parent
  pre-fork. An allocation in the child is a **Critical** latent-deadlock finding.
  The `external_call["write", ...]` collision, the immutable-origin rule for
  `UnsafePointer[T, _]` helpers, and the `posix_spawn` dead end are the known
  traps (AGENTS.md *Lessons*).
- **Cleanup invariants.** The kill targets the process GROUP (`kill(-pgid, …)`),
  not the lone child; both pipes drain to EOF before `waitpid`; every fd and
  buffer is released in `__del__`; no fd growth across repeated spawns. A missing
  group-kill or a partial drain is a **High** deadlock finding.
- `raises` present iff the function can raise? Correct `.copy()` / `^` transfer
  for non-`ImplicitlyCopyable` types?
- **Determinism.** Does a touched script (`gen_transcripts.py`,
  `transcripts_check.sh`) avoid timestamps, absolute paths, and unsorted
  `dict`/`set` iteration in anything it writes? Everything committed must reproduce
  byte-for-byte on a second run — the generator's double-generation self-check
  enforces this; don't let a change slip past it.

### 6. Architecture

- Does every new import point **down** the layering (`model` → `config` →
  `discover`|`protocol`|`report` → `exec` → `session` → `cli`)? An "up" import or
  a cycle is a **High** finding — cite
  [improve-architecture](../improve-architecture/SKILL.md).
- **All FFI confined to `exec`.** A syscall or an `external_call` outside `exec` is
  a **High** finding — it means the deepest module's seam has leaked.
- **Python containment:** anything Python under `src/` is **Critical**. The
  transcript generator and check harness belong in `scripts/` only.
- **Seams intact?** No caller reaching past `run_supervised` to touch an fd or a
  poll; the reporter receiving every fact through the event seam, never a side
  channel; generated files holding data only. A leaked internal today is a blocked
  extension later.
- Is new code in the right home (`src/mtest` vs `tests` vs `scripts` vs
  `fixtures`)? Does `__init__.mojo` re-export the intended surface and hold no
  top-level code?

---

## Reviewing AI-generated code

False confidence is the dominant failure mode. Generated Mojo tends to: emit
last-year's syntax; reach for `mojo run` (masking crash codes); collapse a signal
into exit 1; decode `waitpid` as 128+N; scan a report from the first `Running`
line instead of the last (miscounting a printed impostor); over-normalize a
transcript to make a diff green; allocate in the child between fork and exec; kill
only the child and deadlock on a grandchild; add tests that mirror the
implementation instead of the oracle; and write commit messages with an AI
trailer this repo forbids. Check each explicitly — polish is not correctness.

---

## Severity and output

Group findings by severity; each carries `file:line` and a quoted snippet.

| Severity | Meaning |
|---|---|
| **Critical** | crash laundered into a fail, `mojo run` in an exit-code path, hand-edited transcript, absolute path in a golden, Python under `src/`, allocation in the child before exec, red gate merged, `transcripts-check` weakened to a hash |
| **High** | 128+N termination, deadline kill collapsed into a crash, wrong exit-code precedence, un-anchored parse, over- or under-normalized transcript, missing group-kill or pipe drain, up-graph import, FFI outside `exec`, obsolete syntax that will break |
| **Medium** | missing test for new behavior, vague/unlocated error message, unpinned magic constant, missing provenance comment, unmeasured perf claim |
| **Low** | naming, a redundant copy, a docstring gap |
| **Nit** | subjective; label it as such |

End with a **verdict**: *approve*, *approve with nits*, or *request changes*, and
the one or two findings that gate the merge. Prefer few high-confidence findings
over a long list; a review the author trusts is one they act on. Remember this
single pass feeds the standing dual-adversarial gate — the findings you surface
here are what the two external reviewers will either confirm or escalate.
