# Skills simplicity work — findings log (2026-07-17)

Context: the three repo skills (`code-review-and-quality`, `improve-architecture`,
`mojo-coding-guidance`) were edited to incorporate simplicity /
unnecessary-complexity doctrine: a rent test for new constructs, a review axis 7
(Simplicity & necessity) with severity entries, friction item 5 (an abstraction
that never varies), "deeper is often smaller", and deletion-as-success
guardrails. The stale "src/mtest/ is still an empty package" framing was also
fixed in two skills. Method: baseline scenarios against the pre-edit skills
(RED), targeted edits (GREEN), same scenarios re-run to verify.

**Status: log only — nothing below has been acted on. Tackle later.**

---

## 1. Findings about the skills (mine, from the baselines)

These drove the edits; all three are addressed, recorded here for the review
trail.

1. **code-review-and-quality had no structural home for complexity findings.**
   Baseline reviewer facing a rule-compliant but over-abstracted diff flagged
   the speculative abstraction only by reaching outside its contract — "cite
   improve-architecture — the rule lives there, not here" — graded it Medium,
   and did not gate on it. The severity table had no complexity entries at all.
   → Fixed: axis 7 + Medium/High severity-table entries + AI-generated-code
   failure mode ("wrap one comparison in a trait + factory + config struct").

2. **mojo-coding-guidance carried no general simplicity contract.** The only
   simplicity-shaped sentence was the typed-error clause ("don't invent an
   error-type hierarchy speculatively"). The baseline coder under
   "future-proof this" pressure resisted over-engineering only by explicitly
   *generalizing* from that one clause — fragile; a weaker model or different
   scenario walks past it. → Fixed: "Simplicity — every construct must pay
   rent" section (rent test, rationalization table, red flags) + checklist
   item.

3. **improve-architecture's guardrails already worked; its facts were stale.**
   The baseline architect rejected all four speculative proposals crisply, but
   had to note and work around the false premise "src/mtest/ is still an empty
   package — the modules worth scrutiny are under scripts/" (the description
   itself said this). → Fixed: current-state rewrite (layers landed, plus
   `cache`/`select`), needless-structure counterpart doctrine, friction item 5,
   deletion guardrail.

## 2. Reviewer-agent findings (post-edit verification run)

The verification reviewer was given a deliberately over-engineered **synthetic**
diff (a `RetryPolicy` trait + `make_retry_policy` factory + one-field
`RetryPolicyConfig` + single-caller `_has_attempts_remaining` helper wrapping
`attempt < max_retries`). Its findings are evidence the edited skill works —
the diff was never applied to the tree, so these are NOT repo defects:

- **H1 (gating)** — "a speculative plug-in layer with nothing plugged": four
  new names for one integer comparison; each itemized against the rent test
  (single-impl trait with no AGENTS.md-named seam, factory with one product,
  one-field config struct, single-caller one-expression helper); recommended
  fix: delete the module. In the pre-edit baseline the same content was a
  non-gating Medium justified from outside the contract; post-edit it is the
  first gating finding, graded from the skill's own severity table.
- **H2** — the synthetic diff referenced a phantom baseline (`max_retries`,
  `is_crash_class`, 0-based `attempt` — none exist; the real loop is
  `rc.retry_eligible and more_attempts` with 1-based `attempt_index`), plus an
  off-by-one trap if hand-rebased. Both baseline and verification reviewers
  caught this independently — good sign for review rigor generally.
- **M1/M2** — the abstraction's docs claimed hiding it didn't do
  (`make_retry_policy` ignored its config), and `feat` overstated a
  behavior-preserving change (git-conventions).

Architect verification: rejected all four speculative proposals citing the new
material in-contract (friction item 5 verbatim, "deeper is often smaller",
"finding nothing to build is not a failed pass"), and verified every real
`from mtest.` import points down. Coder verification: passed — under explicit
"future-proof this" pressure it proposed one pure function + one latched
reporter field, "zero new structs/traits/config", rejected duplicating
`attempts_planned` onto `FileFinished` as restating what the stream carries,
and cited the rent test verbatim to refuse a speculative wording-config seam.

## 3. Open items to tackle later (real, in this repo)

1. **AGENTS.md layering diagram omits `cache` and `select`.** The diagram
   (AGENTS.md ~lines 53–64) names six layers; `src/mtest/cache/` and
   `src/mtest/select/` exist, and the commit-scope table names `cache` but not
   `select`. The skills now mention both packages; the authoritative diagram
   should place them so skill and doctrine can't drift apart.
2. **improve-architecture "intended shapes" vs real signatures.** Reality:
   `discover` exposes `walk_dir(abs_dir, rel_prefix)` not
   `walk(paths, excludes)`; `session` exposes
   `run_session[*Rs: Reporter](...) raises -> Int` not `run(config) -> ExitCode`.
   The skill now frames these explicitly as intended shapes, not literal names;
   decide later whether to pin the real signatures instead.
3. **`session/session.mojo` is ~2,800 lines** — several times larger than any
   other module file in the repo. Candidate for a genuine architecture pass
   (does it own more than orchestration?) in a later phase — a plan document,
   not a drive-by split.
4. **Parallel uncommitted work in the tree.** 11 modified src/tests files plus
   untracked `tests/unit/test_exec_spec.mojo` were present during this session
   and are unrelated to the skills change — keep the skills commit separate
   from that work.
5. **Codex gpt-5.6-sol xhigh review: DONE — verdict "request changes".** Full
   report appended in section 4 below, with a triage split (new-text findings
   vs pre-existing staleness the review surfaced).
6. Minor observation from the coder exercise (only relevant if/when a
   flaky-notice feature is actually planned — do not build ahead of it): the
   `FileFinished` event carries `attempts_used`/`flaky` but not
   `attempts_planned`, so a "passed on attempt 2 **of 3**" denominator isn't
   available to reporters today.

---

## 4. Codex external review (gpt-5.6-sol, xhigh) — verbatim, untriaged-unfixed

Reviewed: the uncommitted diff to the three SKILL.md files, plus staleness in
adjacent unchanged text (per the brief). Verdict: **request changes**.

Quick triage for later (not yet acted on):

- **Introduced by the simplicity edits:** #6 (reserved-field rule contradicts
  the skill's own canonical docstring example), #8 ("three reporters flow
  through the trait" is false — only Console and Recording conform, and the
  trait+both arrived in one commit, so "predated the second reporter" is also
  false), #11 (facade red-flag vs __init__.mojo re-export guidance conflict),
  #12 ("delete in the commit that notices" vs atomic-commit discipline),
  #16 (malformed phrasing). #5 and #7 are calibration critiques of the new
  rent test / severity entries worth weighing.
- **Pre-existing staleness surfaced by the review (bigger fish):** #1
  (EOF-then-waitpid doctrine contradicts AGENTS.md), #2 (pixi run ci chain
  description stale + fmt-check mutates), #3 (termination model has 4
  variants incl. SpawnFailed; run_supervised signature stale), #4 (parser
  anchor rule drops the Summary qualifier / AMBIGUOUS case), #9 (cache/select
  unplaced in the authoritative layer graph — matches open item 1), #10
  (verify_scenario doesn't own ALL hard-asserts), #13 (abort() dies by
  SIGILL(4) at the pin, not SIGABRT), #14 (build orchestration is
  session-owned, not exec; exit-code precedence split model/session/main),
  #15 ("from mtest import run_supervised" — root package exports no such
  name).

```markdown
No Critical findings.

## High

1. [mojo-coding-guidance/SKILL.md:126](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:126), [code-review-and-quality/SKILL.md:186](/home/mikko/dev/mtest/.agents/skills/code-review-and-quality/SKILL.md:186)

> “Drain both pipes to EOF before `waitpid`. The completion signal is EOF…”

This directly contradicts AGENTS.md: EOF is not completion; a child may close both streams and continue running. Completion requires observing/reaping the leader while deadlines remain enforced. Following this guidance can hang the runner or disable timeout enforcement.

Concrete fix: state that pipe EOF means capture completion only; poll/drain and observe child termination independently, continue enforcing deadlines after EOF, and never enter blocking reap merely because both pipes closed. Fix the duplicate checklist wording too.

2. [code-review-and-quality/SKILL.md:55](/home/mikko/dev/mtest/.agents/skills/code-review-and-quality/SKILL.md:55)

> “`fmt-check`, `build`, `transcripts-check`, `test` — or `pixi run ci`, which is the same chain”

It is not the same chain. AGENTS.md adds `harness-check`, `test-direct`, and `e2e`; current `pixi.toml` also includes `safety-check` and `native-check`. A reviewer following the abbreviated sequence skips independent execution, native safety, dogfood, and end-to-end gates. Moreover, `fmt-check` runs `mojo format` in place, so the docs-only exception can mutate unrelated dirty work.

Concrete fix: prescribe `pixi run ci` without duplicating a stale expansion. For docs-only review, use non-mutating checks such as `git diff --check` plus a read/Markdown check, especially in a dirty tree.

3. [improve-architecture/SKILL.md:112](/home/mikko/dev/mtest/.agents/skills/improve-architecture/SKILL.md:112), [mojo-coding-guidance/SKILL.md:218](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:218)

> “`Exited(code) | Signaled(signo) | TimedOut(signo_used)`”

The live termination model has four variants, including `SpawnFailed(errno)`. `TimedOut` also retains final termination kind/value and escalation state. The “canonical” function signature omits the required `ExecRuntime` and optional capture bound. This is precisely the kind of stale template agents will copy.

Concrete fix: rewrite every example around the actual interface:

`run_supervised(mut runtime: ExecRuntime, spec: ProcessSpec, capture_bound_bytes: Int = …) raises -> ProcessResult`

Document all four termination kinds and the actual timeout payload.

4. [code-review-and-quality/SKILL.md:102](/home/mikko/dev/mtest/.agents/skills/code-review-and-quality/SKILL.md:102), [mojo-coding-guidance/SKILL.md:174](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:174)

> “Anchor on the LAST `Running <N> tests for` line.”

This drops two essential qualifications from AGENTS.md. The normalizer uses the last `Running` header followed by a `Summary`; otherwise a crash-stream impostor can be normalized. The parser must not use “last wins” when multiple complete report blocks exist—it returns AMBIGUOUS.

Concrete fix: distinguish the rules explicitly:

- Normalizer: last `Running` header followed by a qualifying `Summary`.
- Parser: identify complete candidates; exactly one may be accepted, while multiple complete blocks are AMBIGUOUS.

## Medium

5. [mojo-coding-guidance/SKILL.md:268](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:268)

> “A struct earns existence by enforcing an invariant between its fields or owning a resource…”

This rejects repo-sanctioned Mojo structures: one-field closed-vocabulary types such as `Outcome` and `ColorWhen`, and small result structs required because annotated tuple returns do not compile on the pinned toolchain. The following “field needs a caller that passes a second value” rule also conflates runtime state with configuration inputs.

Concrete fix: recognize domain/type invariants, language-required result records, structured runtime facts, and lifecycle ownership as valid rent. Apply the “two values today” test only to optional policy/configuration knobs.

6. [mojo-coding-guidance/SKILL.md:226](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:226), [mojo-coding-guidance/SKILL.md:271](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:271)

> “reserved env-extension field”

> “A ‘reserved’ field needs the phase that fills it named in AGENTS.md”

The same skill both endorses and rejects the reserved environment field; AGENTS.md names no environment-extension phase.

Concrete fix: remove the reserved field from the canonical example, or explicitly document an AGENTS-backed exception. Do not leave mutually exclusive production rules.

7. [code-review-and-quality/SKILL.md:223](/home/mikko/dev/mtest/.agents/skills/code-review-and-quality/SKILL.md:223)

> “Each is a Medium finding; a whole speculative layer … is High.”

Severity is being assigned by syntax rather than impact. A local redundant helper may be Low, while a single-implementation trait can be necessary due to a mandated seam or toolchain constraint. Conversely, a speculative public API may be High because of commitment and coupling, not merely because several constructs appear together.

Concrete fix: grade by blast radius, coupling, public-contract cost, and remediation risk. Keep the patterns as prompts, not automatic severities.

8. [improve-architecture/SKILL.md:153](/home/mikko/dev/mtest/.agents/skills/improve-architecture/SKILL.md:153), [mojo-coding-guidance/SKILL.md:260](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:260)

> “three reporters now flow through it”

> “the `Reporter` trait predated the second reporter”

There are two conforming reporter types: `ConsoleReporter` and `RecordingReporter`; `CompositeReporter` does not conform. Git history shows the trait, console, composite, and recorder arrived in the same commit, so the chronology is also false.

Concrete fix: say that AGENTS.md mandated the seam before implementation and required Console to flow through composition from day one; today Console and Recording are its two conformers.

9. [improve-architecture/SKILL.md:13](/home/mikko/dev/mtest/.agents/skills/improve-architecture/SKILL.md:13), [improve-architecture/SKILL.md:271](/home/mikko/dev/mtest/.agents/skills/improve-architecture/SKILL.md:271)

> “each later phase … the cache … will operate”

> “the cache … [is an] own phase”

The cache already landed and is used by session through `BuildRegistry`. The updated status section names `cache` and `select`, but the supposedly authoritative layer graph never places either, leaving reviewers unable to judge their imports.

Concrete fix: describe cache as current, not future. Either update AGENTS.md’s authoritative graph to place `cache` and `select`, or explicitly flag them as currently unplaced auxiliary packages rather than pretending the graph covers them.

10. [improve-architecture/SKILL.md:63](/home/mikko/dev/mtest/.agents/skills/improve-architecture/SKILL.md:63)

> “`verify_scenario()` concentrates every structural hard-assert in one place.”

It does not. Build-temp leakage is checked in `generate()`; manifest/matrix equality and byte-identical double generation are checked in `main()`. The skill then labels assertions outside `verify_scenario()` a layering violation, condemning the actual implementation.

Concrete fix: document the real ownership: per-scenario assertions in `verify_scenario`, generation-local assertions in `generate`, and whole-matrix/determinism assertions in `main`.

11. [improve-architecture/SKILL.md:147](/home/mikko/dev/mtest/.agents/skills/improve-architecture/SKILL.md:147), [improve-architecture/SKILL.md:166](/home/mikko/dev/mtest/.agents/skills/improve-architecture/SKILL.md:166)

> “a facade re-exporting another module’s surface” is speculative

> “Many files … with no re-exported surface … fix … `__init__.mojo`”

These rules conflict. Package `__init__.mojo` re-exports are an established boundary in this repo, not inherently speculative.

Concrete fix: narrow the red flag to a facade that duplicates an existing public package without owning a boundary or policy. Explicitly exempt intentional package surfaces.

12. [mojo-coding-guidance/SKILL.md:281](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:281)

> “remove them in the commit that notices them”

This invites unrelated cleanup and violates atomic-change/task-scope discipline. “Deletion is best” also lacks an explicit guard against deleting tests, gates, or required seams merely to simplify the tree.

Concrete fix: delete only when it is in scope and behavior/public contracts remain proven. Otherwise record it for a separate approved refactor. Explicitly forbid deletion that weakens a gate, fixture, transcript, or mandated seam.

13. [mojo-coding-guidance/SKILL.md:65](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:65)

> “A test that aborts (SIGABRT)…”

For pinned Mojo, direct `abort()` is recorded as SIGILL(4), as AGENTS.md explicitly documents.

Concrete fix: say “Mojo `abort()` currently dies by SIGILL(4) at the pinned toolchain,” while keeping SIGABRT/SIGSEGV as general examples only where accurate.

14. [mojo-coding-guidance/SKILL.md:105](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:105), [mojo-coding-guidance/SKILL.md:325](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:325)

> “the exec adapter builds and executes”

> “Usage error outranks internal error … encode that once, in `model`”

Both ownership claims are stale. Session invokes `mojo build`; exec only supervises commands. Model maps run outcomes to 1/5/0, while session/main decide internal, interrupt, and usage codes.

Concrete fix: describe build orchestration as session-owned and distinguish model’s run-outcome mapping from top-level control-flow precedence.

15. [mojo-coding-guidance/SKILL.md:412](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:412)

> “callers write `from mtest import run_supervised`”

The root package exports no such name; callers use `from mtest.exec import run_supervised`.

Concrete fix: use the real package-level import, unless a separate change deliberately introduces and tests a root-level facade.

## Low

16. [improve-architecture/SKILL.md:182](/home/mikko/dev/mtest/.agents/skills/improve-architecture/SKILL.md:182), [mojo-coding-guidance/SKILL.md:72](/home/mikko/dev/mtest/.agents/skills/mojo-coding-guidance/SKILL.md:72)

> “an internal un-exported”

> “already eats this discipline”

Both are malformed phrasing. Use “an internal name made private” and “already enforces this discipline.”

Numbering, cross-reference targets, table column counts, and `git diff --check` passed. `pixi run fmt-check` could not activate because the read-only sandbox could not create its temporary directory; that is not attributed to the diff.

## Verdict

**Request changes.** The merge gates are the reversed EOF/reap doctrine, the incomplete CI instructions, and the stale three-way termination model. The new simplicity doctrine also needs exceptions for sanctioned Mojo value/result structs before it is safe to operationalize.
```
