# Architecture simplification — execution notes

Evidence log for the behavior-preserving refactor series on
`refactor/architecture-simplification`, branched from `main` at
`f8db432f208d90f99934bcc13982c3f519795c92`.

Baseline before any change: `pixi run ci` green on the untouched base —
e2e `59/59 scenarios passed`, dogfood `3 passed, 0 failed, 0 skipped`.

## Correcting doctrine that had drifted from the tree

`6b4a7d4` — `docs(agents): correct layer graph and exit-code drift from the tree`

Four statements in `AGENTS.md` no longer matched the tree:

- The Layer 2 graph omitted `select` and `cache`, though the root
  `src/mtest/__init__.mojo` docstring — the graph's own mirror — already listed
  both. Verified by real imports: `select` imports `mtest.model` only; `cache`
  imports nothing internal at all (only `std.collections`).
- The commit scope table had no `select` row despite `src/mtest/select/` being
  a package a commit can touch alone.
- Layer 5 credited `cli` with `main`, but `src/main.mojo` sits above the whole
  package as the composition root, outside `src/mtest/cli/`.
- The Layer 0 row credited `model` with "exit codes" when it decided only
  0, 1, and 5 — as `model/exit_code.mojo`'s own docstring already conceded.

Doctrine that contradicts the tree stops being consulted, so each line was
corrected to match its own tree. The FFI containment wording was deliberately
left alone; consolidating the platform boundary is separate work and would
have made that wording wrong twice.

Proof: `pixi run ci; echo "ci_exit=$?"` → `ci_exit=0`, e2e 59/59.

## Routing every exit-code decision through one resolver

`5e208cb`, `bcd95a5`, `e3a6acb`, `1dcb98d`, `50256b2`, then `bd4ecaa`, `89aed87`

The process exit code — the product's central contract — had **five** owners:
`model/exit_code.mojo` (the outcome mapping), `session`'s
`_resolve_terminal_code`, the JSON shell's `escalate_on_close_failure`,
`main`'s 18 hard-coded `exit(` sites, and a fifth hand-rolled precedence ladder
inside `run_collect` that duplicated the session's shape. Nothing tested the
policy as one total function, and upcoming pool work adds more paths to it.

All five now resolve through one pure, total `resolve_exit_code(TerminalFacts)`
in `model`. Reporters return delivery *facts* rather than transformed codes.
`main` names no exit code of its own except the usage error, which is refused
before any run exists and so has no facts to rank.

`escalate_on_close_failure` was retired as a duplicate, not a variant: with all
four control-flow facts false the resolver's base stage is the identity, so it
reduces to exactly that function's escalation, and the two agree for every
`Int` — not merely the five reachable codes.

Evidence:

- `pixi run ci; echo "ci_exit=$?"` → `ci_exit=0` on the exact tree of each
  commit in the series (59/59 e2e exact-exit scenarios each time).
- The `tests/unit/test_session_terminal.mojo` assertions were migrated into
  `tests/unit/test_model_exit_code.mojo` as a genuine superset: all 14
  `assert_equal` calls survive at identical literal arguments and expected
  codes, including both assertions pinning that an interrupt stands over a
  later write failure. The 10 assertions of the retired
  `test_escalate_on_close_failure_precedence` reappear verbatim against the
  resolver.
- `CLASSIFIED_TEST_COUNT` 913 → 914, recounted independently against the tree.
- An adversarial review of the full series attempted to refute the
  behavior-preservation claim by case analysis over all five owners and could
  not.

Known residual risk, recorded deliberately: `TerminalFacts.outcome_code` is
read two ways — normally the `exit_code_for` result, and on one path an
already-resolved code having the delivery precedence re-applied. That is what
lets one resolver absorb the retired escalation instead of reproducing it. It
is sound today because the sole caller using the second reading passes every
other fact false, and the base stage is the identity for any value when no
fact is set. The field docstring names the constraint; the type does not
enforce it. A future caller that set a control-flow fact alongside an
already-resolved 2 would get 3 where the old code gave 2.

## Naming the report-layer seam instead of reaching through it

`063e549`, `b52d9c9`, `eb57946`, `ea89d2e`

The `Reporter` trait exposed one method, `handle`, yet five lifecycle
interactions reached concrete reporters at fixed comptime tuple indices:
`run_session[1, 2, 3]`, two `comp.reporters[0]` calls in `main`, and four
session helpers that bound a typed pointer to a tuple element. The composition
order was a hand-kept convention restated in prose in three places, with
nothing type-checking any of them against the others, and `session` imported
three concrete reporter types.

Lifecycle now goes through a `ReportCoordinator` trait with named methods, and
two conformers exist from the first commit: the production set, and a recording
coordinator the session's own drivers use. `session` imports no concrete
reporter type — verified by grep, not by inspection.

The production coordinator owns its four reporters as **named fields** rather
than as an indexed composite. Holding a composite inside it and reaching
elements by index would have relocated the escape hatch into the report layer
rather than deleted it. `CompositeReporter` itself survives, inside the
recording coordinator, where a comptime pack is what the drivers actually want.

The inert-path equivalence was checked at source level rather than inferred
from green gates, because it is where a silent exit-code regression would hide:
an always-present but inactive reporter must return exactly what the old
compile-time-elided branch returned. It does, for all five interactions —
stream health `False`, JUnit finalize `JunitFinalizeResult(False, "")`,
annotation tail an empty list. A discrepancy would have escalated a clean run
to exit 3.

The byte-equality guard was mutation-proven before being trusted: dropping
WARNING events made exactly that one test go RED, and it was then reverted.
An observed green test is not a guard.

Evidence: `ci_exit=0` at each commit (59/59 e2e each), plus `junit-check`,
`junit-render-check`, and `transcripts-check` all exit 0 at HEAD. Transcripts
were never regenerated — a red `transcripts-check` after a repo change indicts
the change.

### The movable-only reporter-pack probe

The question was whether the pinned compiler accepts dropping `Copyable` from
`trait Reporter`'s bounds, so a reporter could own a file descriptor.

**It accepts it** — the package and the whole classified inventory build clean
with `trait Reporter(Movable)`. The relaxation was *not* adopted, because
nothing owns a non-copyable resource yet and a widened bound no caller
exercises fails the rent test. It is recorded in AGENTS.md so it need not be
re-probed when a reporter does need to own an fd.

A second, undirected probe corrected a false Lesson. AGENTS.md claimed a
composite may "never" be nested inside another struct. That over-generalized a
`Copyable` failure: `Movable` does synthesize, and declaring
`struct CompositeReporter[*Rs: Reporter](Movable)` lets a coordinator own its
pack. Had the claim been believed, this design would have looked impossible.

## Splitting session.mojo and extracting the pipeline kernel

Stage 1 (move-only): `1a8d1d2` `77885af` `4a5960a` `4352659` `4b55fde`
`cb73029` `61c8994` `0e866fc`
Stage 2 (structural): `fdfb061` `c6d2395` `f9cba39`, fixes `8a7b856` `b7fc3df`

`session/session.mojo` was 4,482 lines in one file spanning scratch plumbing,
build orchestration, attempt machinery, probe/reconcile, the recovery loop,
crash attribution and the entry points. Stage 1 moved those clusters into
focused satellite modules following the package's existing pattern; the file is
now 559 lines (the two `run_session` overloads). The move was proven mechanical
by an entity-level diff: 58 entities in, 58 out, none added, removed or
renamed, bodies and signatures byte-identical — the only deltas were three
trailing section-banner comments becoming module docstrings.

Stage 2 was the one genuinely structural change: the sequential two-pass driver
became an explicit state machine (`session/pipeline.mojo`) with per-file state,
explicit step requests and explicit completions, driven sequentially at
capacity one. The split that matters is that the kernel decides the next step
and the driver executes it — a later phase replaces only the driver with a
worker pool while admission, retry, maxfail and accounting policy stay in the
session. The seam is named in AGENTS.md, including the dependency on a versioned
multi-child native adapter that does not yet exist, so the reader knows the
second driver is named rather than imminent.

An adversarial review of the cutover found one real divergence the differential
console-capture could not have caught: a stale-name recovery whose rebuilt
binary's re-probe crashes lost its crash-attribution entry, because the old
code's recovery-probe result flowed back out into a shared append the kernel
split had hoisted inline. Rendered bytes only — the exit code and counts were
unaffected — but the attribution banner count and one `CrashAttribution` event
would have gone missing. Fixed by mirroring the append into the recovery branch
(`8a7b856`), with a new fixture-driven test that was mutation-proven: removing
the append turned exactly that test RED. The rebuild reproduces the same binary
path (the mangle is a pure injective function of the relative path), so the
attributed binary matches the old behavior.

The kernel's vocabulary is mtest's own — `RunPipeline`, `FileStage`, `StepKind`,
`BUILD_FILE`, `PROBE_FILE`, `RUN_SELECTION`, `admit_crash_retry` — never a
generic job/task/scheduler abstraction. The rent argument: every stage, step
kind and completion field is reached by the sequential driver today and pinned
by 28 unit tests; none exists only for a future pool.

## One owning epilogue in main

`e5f293c`

`main.mojo` repeated a resource-teardown ladder — discard the JUnit scratch,
close the JSON fd, close the runtime, apply a precedence — across most of its
18 `exit(` paths. One `RunResources` struct with a single
`close_into(code, rank_delivery) -> Int` now implements that ladder once; the
18 `exit(` sites became 12 and `main` stays the only `exit()` caller. The JSON
close remains a delivery fact fed to the model resolver, not a locally
transformed code — the reviewed consolidation is preserved. `close_into` takes
a `rank_delivery` flag because the two usage-refusal paths own code 4 and must
not route it through the delivery precedence (which would turn 4 into 3); main,
which owns code 4, makes that call.

## One audited platform-I/O boundary below report

`54bb495` `5e8165c` `8f58f73`

Four modules across three layers carried platform ABI knowledge: `getpid` in
`session/scratch.mojo` and `report/junit_reporter.mojo`, `rename` implemented
twice (`exec/fs.mojo` and `junit_reporter.mojo`), and the JSON stream's
`write`/`creat`/`close`/`__error` cluster. The root cause was structural —
`report` (Layer 2) cannot import `exec` (Layer 3), so fd-owning reporters had
nowhere blessed to get `write`.

A new `src/mtest/platform` package at Layer 0 (it imports no internal module,
so no cycle) now wraps pid, rename, and the streaming open/write/close, and
every higher-layer `external_call` declaration is deleted — verified by grep
that nothing outside `exec/` and `platform/` declares one. `rename` has one
implementation instead of two. AGENTS.md's FFI wording now names the two
audited boundaries — the platform module and `exec`/`native` — rather than
claiming all FFI lives in `exec`. Done in three slices (pid, rename, stream),
each green on `ci`, `safety-check`, `postfork-check` and `native-check`, with
the dead-pipe and artifact-preservation e2e scenarios passing.

## Typed event payloads

`55e073e` `54b6a4d`, fixes `94de8bc` `9bffc72`

`model/events.mojo` was one all-fields `Event` struct plus a `_blank(kind)`
that initialized every unrelated payload, tagged by `EventKind`. A reporter
could read a field meaningless for the current kind and the compiler could not
object. The event set becomes type-safe: one payload struct per kind, held in a
closed `Variant`, with the outer `Event` type name, the factory method names
and signatures, and every serialized NDJSON byte unchanged. The tag is derived
from each payload's `KIND` constant rather than passed in, so kind and payload
cannot disagree; a field meaningless for a kind is simply not on that kind's
payload.

This landed before the worker-pool phase deliberately, so that `Progress` and
the new per-kind fields it adds are built on the typed representation rather
than migrated onto it afterward.

The spike proved `Variant` reproduces the exact bytes on the pinned compiler
before the full migration — a byte-pinned test written RED then green on two
kinds. The byte-identity of the whole set rests on the serializer bodies being
character-identical modulo the payload accessor, against fixtures that were not
touched: an adversarial review confirmed the fixtures are absent from the diff
and the emitting code is unchanged, so the bytes cannot have moved. The review
also confirmed the recording reporter's accessors return, for a non-matching
kind, exactly the value the old `_blank` default exposed — so the integration
drivers that read events back are unaffected.

The throwaway spike test (which exercised fake structs, not the production
serializer) was deleted once the real per-kind byte guard existed; keeping a
test of fake structs alongside the real one is duplication, not coverage.

## One production build authority

`9efdbe4`

The checkout build (precompile + native + link, via `mojo_package.sh`,
`native.py`, and the `build-bin` pixi task) and the published `recipe/build.sh`
were two independent authorities that hardcoded the same strict C flags
separately — a drift risk between the tested artifact and the shipped one, and
a publish-phase blocker.

The recipe runs in rattler-build's isolated env, whose build requirements are
only `mojo` and `clang` — no Python. So the shared entrypoint had to be bash.
`scripts/build/production_build.sh` (bash, source-relative, runnable with
bash+mojo+clang) is now the one definition of the production build, invoked by
both the pixi tasks and `recipe/build.sh`. The strict flags live once in
`scripts/build/native_strict_flags.txt`, read by both that entrypoint and
`native_abi.py`'s symbol verification, so the two authorities cannot drift. The
test-only native variant and the symbol-set checks stay in the CI wrapper,
where the published build does not need them.

Proof that the artifact is unchanged: the production native object is
byte-identical before and after (same sha256), and `build/mtest`'s dynamic
section is identical; `package-check` passes with the isolated recipe env
logged running the shared entrypoint.

## Surface hygiene

`affe722` `3399569` `69b0195` `2c213ed`

Opportunistic trims once the owning packages were already in hand:
`report/__init__.mojo` stopped re-exporting ~26 pure-half JUnit renderer
internals that `src/` never imported from the root (tests now import them by
submodule path, the existing style); the cross-module
`_signal_name_for_target` lost its private-looking underscore since two sibling
modules import it, making it honest package-internal API; and `escape.mojo`'s
GH-Actions fencing protocol split into its own `fencing.mojo`, the two concern
sets sharing no private helpers. `config/lossy_utf8.mojo` was left in place with
a docstring note explaining it is a layer-0-natural text utility parked in
`config` for graph position — twelve importers made moving it more than
opportunistic, and the note removes the puzzle without the churn.
