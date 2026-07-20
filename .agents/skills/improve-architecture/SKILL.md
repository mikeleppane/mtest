---
name: improve-architecture
description: Explore the mtest codebase, surface architectural friction, and propose module-deepening refactors as actionable plan documents under docs/plans/. Use when asked to review architecture, "make this cleaner", "reduce coupling", "this file is doing too much", "is this abstraction worth it", or to evaluate whether a module pulls its weight. Tuned to this repo's one-directional layering (model → config → discover|protocol|report → exec → session → cli), the principle that exec is the deepest module, its pure-Mojo src/ rule, and the conviction that architecture survives years of phases by having fewer parts, not more extension points. Covers the built-out layers under src/mtest/ and the harness scripts under scripts/. Produces a durable refactor plan, not edits — execution is a separate, approved step.
---

# Improve Architecture (mtest)

Explore the codebase organically, surface architectural friction, and propose
**module-deepening refactors as durable plan documents** under `docs/plans/`
(gitignored — plans are working documents, never published, never cited in
commits or code). mtest's whole product is exit-code fidelity: here, architecture
work serves *the ability to add features later without ever letting a crash leak
as a failure* — the seams are where each later phase (parallelism, crash
isolation, JUnit/GH reporters, the cache) will operate, so protecting them **is**
the correctness work you can do before those phases arrive.

A **deep module** (Ousterhout, *A Philosophy of Software Design*) has "a small
interface hiding a large implementation." Deep modules are more testable, more
navigable for humans and agents, and let you test at the boundary instead of
poking internals. This skill finds *shallow* modules — interface nearly as
complex as implementation — and this repo's higher-stakes variant: a **leaked
seam**, where callers see internals that a later phase must be free to replace or
that expose an fd, a syscall, or a raw termination code.

The inverse failure is just as real and this skill hunts it with the same
energy: **needless structure** — a seam nothing varies behind, a layer that only
forwards, an interface with one implementation and no doctrine naming it. Depth
is the ratio of implementation hidden to interface exposed, so every construct
that hides nothing makes the system *shallower* in aggregate. The architecture
that withstands years of change is the one with the fewest parts, each earning
its keep — not the one with the most extension points.

Project rules live in [AGENTS.md](../../../AGENTS.md) and override this skill.
For the per-edit coding contract, cite
[mojo-coding-guidance](../mojo-coding-guidance/SKILL.md); this skill is about
*structure*, not line-level style.

**When it produces a plan, that plan is a document, not edits** — execution is a
separate, approved step, because refactors touch many files and each is its own
atomic commit. But don't reach for a `docs/plans/` file reflexively: a quick
structural question ("does this import point the wrong way?", "where should this
helper live?") is answered **inline**. Write a durable plan only when the work is
a genuine multi-commit refactor *and* a durable plan was asked for (or the
friction clearly warrants one) — say which you're doing before you do it.

---

## Where the codebase actually is right now

The layers have landed: `src/mtest/` holds `model`, `config`, `discover`,
`protocol`, `report`, `exec`, `session`, and `cli`, plus the `cache` and
`select` packages, with the suites under `tests/` exercising them at their
boundaries. The layering and seam guidance below is judged against **real
imports now** — start every pass by grepping them, not by trusting the diagram.

The harness under `scripts/` remains fair game with the same discipline.
`gen_transcripts.py` is the transcript generator and normalizer that
`scripts/checks/protocol_snapshots.py` drives, and it is the harness's own deep
module:
`normalize(raw, *, is_crash_stream) -> text` is one call that hides the
anchored timing-token rewrite (only on report-grammar lines at or after the
LAST `Running <N> tests for`), the repo-root → `<REPO>` rewrite, the stack-dump
collapse, and the framing guard — none of which leaks to `generate()`. Above
it, `generate()` hides build-fixture → run-scenario → normalize → self-verify →
dedup behind a single `() -> dict[name, transcript]`, and `verify_scenario()`
concentrates every structural hard-assert in one place. Treat a change that
spreads normalization logic into `render`, or that reaches around `normalize`
to scrub a byte ad hoc, or that inlines a self-verify check somewhere other
than `verify_scenario`, exactly like a layering violation in `src/` — same
discipline, different layer names.

---

## The invariants to protect

### One-directional layering (the target)

Lower layers never import higher ones, once there are layers to violate. The
intended graph — authoritative in [AGENTS.md](../../../AGENTS.md) and mirrored in
`src/mtest/__init__.mojo` — is:

```text
model → config → discover  ─┐
                 protocol   ├→ exec → session → cli
                 report     ─┘
```

(`discover`, `protocol`, and `report` are independent Layer-2 siblings; `session`
composes everything below it; `cli` sits on top.) The first check in any
architecture pass: **grep the real `from mtest.` / `from .` imports and confirm
every one points down.** An "up" import or a cycle is the highest-priority
finding — the fix is almost always to move the shared thing *down*, or to invert
the dependency so the lower layer exposes a hook the higher layer fills.

### `exec` is the deepest module — and the FFI containment boundary

`exec` (the POSIX process adapter) is the deepest module in the design: a small
`run_supervised(spec) -> ProcessResult` interface hiding fork/exec, pipes,
concurrent draining, poll-based supervision, the group kill protocol, FFI,
platform differences, and fd cleanup. Two seams must hold:

- **`session` never sees an fd, a syscall, or a poll.** The whole
  fork/drain/reap/kill machinery stays inside `exec`. A caller that can observe a
  pipe or a process group has broken the seam — and a later phase (parallelism,
  crash isolation) that must reshape supervision then can't.
- **All FFI lives in `exec`, nowhere else.** An `external_call` or a raw syscall
  outside `exec` is the same smell as an up-graph import: the containment boundary
  has leaked. Platform `#ifdef`-shaped divergence stays behind the narrow
  interface too.

### The termination seam

`ProcessResult`'s termination is a closed sum — `Exited(code) | Signaled(signo) |
TimedOut(signo_used)` — and that distinction is the product. Any structure that
lets a caller collapse `Signaled` into `Exited`, or that surfaces a raw 128+N
code, has broken the seam the whole tool stands on. The verdict map in `session`
consumes this sum totally; it must never re-derive the termination from a
flattened integer.

### Python containment

`src/mtest/` is pure Mojo, always. The transcript generator and check harness
live in `scripts/`. Any structural proposal that would put Python-derived logic
under `src/` (rather than Python-*generated data* like the transcripts) is dead
on arrival.

---

## Friction to look for

Walk the tree and the imports. Common findings, roughly by value:

1. **Up-graph imports / cycles** — as above. Always a plan item.
2. **A leaked seam** — a caller reaching past `run_supervised` to an fd; a
   `session` verdict re-deriving termination from a flattened code instead of the
   `Exited|Signaled|TimedOut` sum; a reporter fed a fact through a side channel
   instead of the event seam; FFI outside `exec`. Fix the surface *now*; a later
   phase pays the price otherwise. Today's version of the same smell: a scrub
   applied around `normalize` in `gen_transcripts.py` instead of inside it, or a
   self-verify assertion placed outside `verify_scenario`.
3. **A file owning two responsibilities.** A `session` that grows report parsing,
   or an `exec` that also classifies outcomes. Splitting usually reveals the
   hidden dependency (outcome classification sits in `model`/`session`, *above*
   raw supervision).
4. **A shallow module.** A wrapper whose interface is as wide as its body — e.g. a
   "runner" struct that forwards `discover` + `build` + `run` + `parse` and
   exposes all four. Either deepen it (hide the pipeline) or inline it.
5. **An abstraction that never varies.** A trait with one conforming
   implementation and no AGENTS.md-named seam, a `make_*` factory returning its
   only concrete type, a facade re-exporting another module's surface, a config
   struct wrapping one value. These are speculative structure — added for a
   future that will arrive with different cases — and the fix is usually
   **deletion or inlining**, the one refactor that makes the system deeper by
   removing interface. (The `Reporter` trait is the counter-example: doctrine
   named that seam before the second reporter existed, and three reporters now
   flow through it.)
6. **A leaky public surface.** `__init__.mojo` re-exporting internal helpers, or
   callers importing past the package (`from mtest.exec import _drain_pipe`)
   because the clean name isn't exported. Fix the surface, not the callers.
7. **Duplicated parsing/fixture logic across tests.** Several test files each
   re-implementing the transcript walker or the temp-tree builder — extract a
   shared helper the suite owns (under `tests/`, on the `-I tests` path), don't
   let the next copy land.
8. **A struct exposing raw fields** that callers mutate directly, so an invariant
   (a `ProcessResult` whose termination and captured streams must stay
   consistent) can't be enforced. Deepen behind methods.
9. **Flat pile with no boundary.** Many files in one package with no re-exported
   surface — navigational friction; the fix is a package split + `__init__.mojo`,
   not a rewrite.

---

## What "deeper" looks like here

- **The harness shows the shape.** `normalize(raw, *,
  is_crash_stream)` (`scripts/gen_transcripts.py`) is deep: one call hides the
  anchored rewrite, the repo-root scrub, the stack collapse, and the framing
  guard, and nothing about the anchor arithmetic leaks to `render`.
- **`exec` has that shape in the tree.** `run_supervised(spec) -> ProcessResult`
  (`src/mtest/exec/supervise.mojo`) hides fork/pipes/poll/kill entirely — the
  deepest interface-to-implementation ratio in the repo, and exactly the
  boundary the `exec` tests exercise by supervising system binaries.
- **Deeper is often smaller.** Deepening usually means *removing* surface — an
  internal un-exported, a pass-through inlined, two calls collapsed into one —
  not adding a layer. A new layer that forwards is width wearing depth's
  clothes: it adds a name and a jump while hiding nothing. Before proposing any
  new interface, ask what breaks if the construct is deleted instead;
  "nothing" means delete.
- **Test at the boundary.** If testing a module forces you to construct its
  internals (an fd, a half-built pipe), the boundary is in the wrong place. A deep
  module is tested through its public functions on small inputs (see
  [test-driven-development](../test-driven-development/SKILL.md)).
- **The `__init__.mojo` is the contract.** Re-export the names callers should use
  so files can move inside the package without breaking `from mtest import
  run_supervised`.
- **Totality is depth.** A verdict map `outcome_of(result)` that is *total* on
  `ProcessResult` (every termination maps to exactly one outcome, never raises) is
  deeper than one that raises — the caller needs no error path.

### The deep modules and the shapes they must keep

The layers under `src/mtest/` are built; judge each against the shape it was
planned to keep — a simple interface over a substantial implementation. (The
signatures below are the intended shapes; hold the real exported names to the
same ratio, and treat surface *growth* on these modules as friction to explain,
not progress to applaud:)

- **`exec`** — `run_supervised(spec) -> ProcessResult` over fork/exec, pipes,
  poll, the group-kill protocol, and fd cleanup. The syscalls stay internal.
- **`protocol`** — `parse_report(bytes) -> Report` over the anchored scan and the
  declared/rows/summary reconciliation. Whether it scans once or twice must not
  show at the call site.
- **`discover`** — `walk(paths, excludes) -> List[TestFile]` over the recursive
  walk, the `test_*.mojo` pattern, and the root discipline.
- **`session`** — `run(config) -> ExitCode` over discover → build → supervise →
  parse → aggregate. This is the layer `cli` stands on; the others exist to give
  it small surfaces.

---

## The exploration → plan flow

1. **Map before judging.** List the packages under `src/mtest/`, read each
   `__init__.mojo`, and sketch the actual import graph (grep the `from mtest.`
   import lines); compare it to the intended layering above. For the harness,
   read `gen_transcripts.py` and confirm normalization lives in `normalize`,
   self-verification in `verify_scenario`, and orchestration in `generate` —
   nothing reaching around those seams.
2. **Collect friction**, not fixes yet. Note each smell with a `file:line` and
   one sentence on why it costs the reader, the tests, or a later phase.
3. **Cluster into refactors.** Group related smells into a handful of named
   refactors, each independently shippable. A good refactor has a clear before →
   after and a way to prove behavior is unchanged — here that proof is close to
   free: **the transcripts and the Mojo suite must be byte-identical / green on
   both sides.**
4. **Write the plan** to `docs/plans/<short-name>.md`:
   - **Problem** — the friction, with evidence (`file:line`, the import that
     points up, the fd or termination code that leaked).
   - **Proposed structure** — the target layout / interface, and why it's deeper
     (or why the seam is now sealed).
   - **Migration** — the ordered atomic commits (`refactor(<scope>): …`), each
     green under `pixi run ci` on its own.
   - **Risk & proof** — what could break, and the test that guards it. The
     conventional `pixi run test` is the exhaustive classified suite;
     `dogfood-check` and `e2e` are separate proof when the real pipeline or CLI
     boundary changes. Call out any AGENTS.md Ask-first boundary the refactor
     would cross (a CLI-contract or public API rename → `!` commit; anything
     touching the transcript format or a pin → confirm first).
   - **Explicitly out of scope** — what you are *not* changing, so the plan stays
     reviewable.

Remember the no-internal-references rule: the plan file may cite phases and
decisions freely, but the *commits that execute it* state reasons directly —
never "per the plan".

---

## Guardrails

- **Don't rename for taste.** A rename churns `git blame` and cross-references.
  Rename only when the current name actively misleads.
- **No premature abstraction.** Two similar reporters are cheaper to read than one
  clever generic — the one-engine-vs-many call belongs to the phase that has all
  the reporters on the table, not to a cleanup. Extract a shared helper on the
  *third* occurrence, not the second. The per-construct version of this rule is
  the rent test in [mojo-coding-guidance](../mojo-coding-guidance/SKILL.md):
  a trait needs a second implementation or an AGENTS.md-named seam, a helper
  needs a hidden decision or a second caller, a struct needs an invariant to
  enforce.
- **Deletion is the best refactor.** A pass that removes an interface, inlines a
  wrapper, or drops a dead seam has *succeeded*, and a plan whose migration is
  mostly deletions is the most trustworthy kind. Finding nothing to build is
  not a failed pass; building something unneeded is.
- **No feature work dressed up as architecture.** Parallelism, crash isolation,
  the cache, and the JUnit/GH reporters are their own phases with their own tests
  and plans. The architecture pass *protects seams*; it does not add a worker
  pool, a new reporter backend, or a cache layer.
- **Keep the plan small.** A plan proposing to move ten files at once is a plan
  nobody will execute safely. Prefer several small plans over one grand redesign.
- **Match the size of the fix to the size of the problem.** A navigational pile
  needs a package split, not a redesign; a cycle needs one dependency inverted,
  not a new layer.
