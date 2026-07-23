# Phase 5 notes — the worker pool

The durable record for the worker-pool phase: parallel test execution on top of
a new native ABI (v2), the capacity-N `Supervisor` that drives it, the
`-n`/`--workers` and `--serial` flips that finally serve the flags Phase 4 kept
refused, a benchmark that settled the auto-sizing formula, and the two CI
failures whose fixes shaped the concurrency budget. The phase branched off main
`26c0db4` (after PR #9, the architecture simplification, had merged) and ships
version 0.5.0.

The pool is deliberately invisible at one worker. Every commit here carries a
capacity-one byte-identity obligation: at `-n 1` (the default) the scheduler
early-returns a one-worker plan, the pool never runs, no build-thread flag is
passed, no progress counter byte exists, and the console and `--json` streams
are byte-for-byte what Phase 4 emitted. The parallel machinery only wakes when a
run asks for more than one worker.

## Reconciliation: the STOP gate before any pool code

Before a single line of pool code was written, a read-only reconciliation pass
(2026-07-22) checked nine preconditions against the actual tree — the merged
refactor kernel, the Phase 4 contract text, the frozen native adapter, the model
and flag shapes, the tests layout, the dogfood argv, and a live core-count probe
— and returned **PASS / GO** with no material mismatch. The baseline it pinned
(`ci` exit 0, e2e 59/59, dogfood 3/3, ASan 7 suites, Valgrind 12 suites, the
core probe reading 32 on this box) is the reference every later gate result is
measured against.

Two durable corrections surfaced that belong in this record rather than in any
doctrine file:

- **The flag-inventory oracle lives in the test, not the spec.** The frozen
  inventory a served-flag flip must edit by hand is
  `tests/unit/test_cli_inventory.mojo`'s `frozen_inventory()` (the refusal rows),
  **not** `flag_spec.mojo`. `flag_spec.mojo` carries the served/refused table;
  the test is the independent oracle, and the two must move together in the same
  commit — a bijection between them is separately asserted. This mattered
  concretely at the `-n`/`--workers` flip (commit 9), whose hand-edited inventory
  bit would have gone to the wrong file otherwise.
- **The event `kind` guard is convention-only.** `EventKind` is a plain mutable
  field; the "guard" is a docstring, not a `__setattr__` or any runtime check.
  Pool merge and dispatch code must not assume an enforced invariant there.

The corrections were anchor-level facts and a pre-recorded known state, not new
AGENTS.md doctrine, so the conditional opening `docs(agents)` commit was skipped;
the commit numbering was left unchanged.

## The ABI v2 boundary — and what deliberately did not move

The native adapter carries the pool's real concurrency, so the boundary commit
that opened ABI v2 was scoped as narrowly as possible. It added the three new
symbols the Supervisor needs — a blocking `poll_set` multiplexer over the union
of live capture channels, an interrupt counter, and a file-descriptor-limit
probe — and bumped the ABI version from 1 to 2. What it **did not** touch is the
load-bearing part of the record: the child-side region (the post-fork,
pre-exec code path) and the SIGPIPE disposition handling on both the parent and
child sides stayed **byte-for-byte identical** to the v1 adapter. The
concurrency surface grew; the fork/exec/signal core did not.

The commit also added fault-injected EMFILE cleanup tests under Valgrind's
`--track-fds`: one exercising the zero-open-descriptor memory-and-state cleanup
when a `PIPE_STDOUT` allocation fails, one exercising the partial-pipe real-fd
cleanup when `PIPE_STDERR` fails after the first descriptor is already open. Both
were proven with leak-teeth — deliberately break the cleanup, watch the tracker
report the leaked descriptor and a nonzero exit, restore, watch it go clean —
rather than merely run green. The one Valgrind guard that fires on the terminal
predicate was confirmed a **proven false positive**: the slot is single-close by
construction and the descriptor is set to `-1` before the close, so the fix was
additive coverage, not a defect repair, and it weakened no gate.

## The env-override verdict — the STOP gate before cache quarantine

Two commits reworked how a child process gets its environment, gated by an
explicit proof before the second could proceed. The first added a per-child
environment extension: extra variables marshalled across the native boundary the
same way `argv` already was (owned strings freed in the destructor, so the path
is leak-safe; a zero-count extension is byte-identical to no extension at all),
carried on the `ProcessSpec` and applied to the child alone.

Before the cache-quarantine commit that depends on it was allowed to build, the
extension had to clear a four-part STOP-gate proof, and it did — all four green:

- **(a) an extra variable is delivered** — it arrives in the child's environment
  (one line);
- **(b) the full inherited environment survives** — a grandchild still resolves
  `mojo` through the inherited `PATH` and exits 0, so the extension augments
  rather than replaces the environment;
- **(c) an override replaces uniquely** — overriding an existing variable yields
  exactly one line carrying the new value, not two;
- **(d) an extra can steer resolution** — a `PATH` extra changes what the child
  resolves, with a `SpawnFailed` control run proving the attribution.

With that proof in hand, the cache quarantine moved off the process environment
entirely. `setenv`/`unsetenv` are now **absent from `src/`** (confirmed by an
empty grep); the quarantined spawns append `MODULAR_CACHE_DIR` to the **child's**
`env_extra` instead of mutating and restoring the parent's environment around the
fork. The quarantine is now structural — a property of the child spec — rather
than a single-threaded caveat about not touching the shared parent environment,
and the whole change came in at a net fourteen fewer lines. This is the fact any
"never scrub the parent env around a spawn" lesson should now reflect.

## Worker sizing — the benchmark and the formula it settled

The auto-sizing formula shipped through commit 8 as a provisional
`min(4, max(1, cores // 2))` — half the cores, but capped at four on the theory
that stacked cold compiles would starve each other on build threads past a
handful of workers. A dedicated benchmark (`scripts/maintenance/bench_workers.py`,
stdlib-only, run through the un-gated `bench-workers` task) was written to test
that theory against real numbers on this machine.

```
mtest worker-sizing benchmark
machine: 32 logical cores | tree: 16 files | reps: 3 (median reported)

workers  tokens  temp   median_s  speedup_vs_-n1
      1  on      cold      30.37           1.00x
      2  on      cold      16.72           1.82x
      2  off     cold      16.67           1.82x
      4  on      cold       9.49           3.20x
      4  off     cold       9.50           3.20x
     32  on      cold       5.28           5.75x
     32  off     cold       4.44           6.83x
      1  on      warm       6.79           1.00x
      2  on      warm       3.63           1.87x
      2  off     warm       3.58           1.90x
      4  on      warm       2.02           3.36x
      4  off     warm       1.99           3.41x
     32  on      warm       0.97           7.02x
     32  off     warm       0.94           7.22x
```

Here "tokens on" is the real default — one `mtest -n W` process whose concurrent
builds share the cores-wide `--num-threads K` build-token budget — and "tokens
off" is a bench-side control (W concurrent `mtest -n 1` processes over disjoint
file slices, each build spawned at the compiler's default thread count) requiring
no production knob. The control conflates the token budget with process topology
and so is not a surgical isolation of the budget alone, but it is enough to
falsify the budget's stated premise.

The data **disproved the compile-starvation theory**. Token-on and token-off run
essentially the same at every size (the build-token budget is not the bottleneck
at this tree size), and speedup climbs monotonically with no knee before four
workers and substantial gains past it — 4 workers at 3.20x cold, 32 workers at
5.75x cold (7.02x warm). If anything, unbudgeted concurrency was marginally
*faster* at 32 workers (cold 4.44s vs 5.28s), the opposite of starvation. The cap
was leaving roughly half the available speedup unclaimed on this box.

So the cap was **dropped**. The formula became `resolve_auto_workers(cores) =
max(1, cores // 2)` — half the cores, uncapped (32→16, 8→4, 4→2, ≤3→1). This was
the user's decision (an explicit "half the cores, drop the cap" choice). Half the
machine rather than the whole of it is retained not as a starvation limit but as
a **resource-politeness bound**: it leaves cores for other work and holds the
peak output-capture memory to `cores // 2 × 16 MiB` (each in-flight worker can
hold up to 8 MiB of stdout plus 8 MiB of stderr capture), while still capturing
most of the measured speedup. The §18 contract clause that had called `auto`
"conservative, since stacked cold compiles starve each other" was corrected in the
same commit — the starvation premise it rested on is false — and a new sizing note
records the capture-memory arithmetic so a memory-constrained environment knows to
lower `-n`. The unit test that had pinned the cap (`test_auto_is_capped_at_four`)
was replaced by one pinning the uncapped scaling; the floor cases were unchanged,
since they hold identically under both formulas. Live confirmation: `-n auto` now
resolves to 16 on this 32-core box, where it used to resolve to 4.

## The batch order and completion-order independence

A pooled run schedules in three batches, always in the same order:
**gates → parallel → serial**. The order is not arbitrary. Gate files run first
and, on failure, abort immediately with the run's maxfail budget disabled — a
failing gate must stop the run before any run file is built, exactly as the
pre-existing sequential gate→run precedent already did. The parallel batch runs
the bulk of the files across the worker pool. The serial batch runs last, one
whole pipeline at a time, holding a single Supervisor slot through build, run,
and any crash-class retry so that no two serial files (nor a serial and a
parallel file) ever overlap — a property of running that batch at one worker,
proven by construction rather than by timing. A parallel batch that latched a
halt, was interrupted, or hit a machinery fault skips the serial pass entirely;
those files then fall into the derived NOT-RUN accounting.

The pool preserves the two guarantees a parallel scheduler most easily breaks.
First, **exit-code semantics ride the outcome, not the schedule**: a pool
interrupt resolves its exit through the shared `resolve_exit_code(TerminalFacts,
interrupted=True)` path (exit 2, with NOT-RUN accounting for the unstarted
files), never through the halt latch, so the terminal exit code is what a
sequential interrupt would have produced. Second, **aggregation is
completion-order-independent**: every reported surface is sorted by node id, not
by the order workers happened to finish, so parallelism changes only how fast the
run reports, never what it reports. The build-token budget is gated on the spawn
argv alone (at one worker, no `--num-threads` flag is emitted at all), which is
what keeps the capacity-one path byte-identical.

## The concurrency-contract consistency audit

A dedicated audit commit reconciled the contract text and the release-QA oracle
with the now-served flags, and recorded two interaction decisions that need no
doc change but do need to be on the record.

- **The release-QA oracle had gone stale.** `scripts/qa/contract.py` still listed
  `-n`, `--workers`, and `--serial` as "Still refused" — stale since the flips at
  commits 9 and 11 — and would have failed had it been run (it is not in the CI
  gate, so nothing had caught it). The refused list was emptied and all three
  flags moved to the served set. The `contract-check` oracle passes 60/60.
- **`--maxfail N` resets per scheduling batch, but a latched halt carries.** Each
  batch builds its own `RunPipeline` with the full `config.maxfail`, so the
  *count* does not accumulate across the parallel→serial boundary. But a halted
  parallel batch records its halt, and the orchestrator skips the serial pass when
  the parallel batch interrupted, faulted, or halted — so `-x` and a reached
  `--maxfail` limit still stop the run, and the serial files land NOT-RUN. This
  mirrors the pre-existing gate→run precedent exactly (the gate batch also runs
  with maxfail disabled and does not share the run batch's count, yet a failing
  gate still aborts), so §11 needed no edit.
- **`--serial` and `--shard` compose orthogonally.** `--shard i/N` selects *which
  files exist* for this job (it partitions the post-exclusion universe before any
  build); `--serial GLOB` orders *within* that set (it pins the matching subset to
  run last, sequentially). A serial glob matching a file this shard does not own
  simply matches nothing here and raises the ordinary stale-pattern warning. The
  two axes are independent; no combined e2e exists, and no contract clause
  promises one.

## The dogfood gate goes parallel

The dogfood gate was moved onto the pool to give the parallel and `--serial`
paths coverage in the everyday build loop: it now runs at `-n 2` with
`tests/dogfood/exec_probe.mojo` pinned serial. The header-parsing and
PASS-row-parsing regexes survive the new `workers: 2` header term and the
`SERIAL` row marker unchanged (neither is anchored where the new tokens land),
and the membership check re-sorts its extracted set, so it is immune to whichever
order the two parallel probes finish in.

The wall-clock cost went **from 7.48s to 9.02s** for the full `dogfood-check`
chain on this machine. That is not a regression: three tiny probes are dominated
by pool startup overhead at `-n 2`, and the pool's benefit shows up on larger
suites, not a three-file gate. The point of the change is exercising the pool and
serial-pinning path on every dogfood run, not a speedup here.

## The two CI failures — and why concurrency must be verified on CI

The phase's concurrency work passed cleanly on the 32-core dev box long before it
passed on GitHub's slow 2-core runners. Two distinct CI failures had to be fixed
before the branch went green (final green run: 29995262146 on `f128060`, every
job green on both Linux and macOS).

**Failure one — the `kill_all` EBUSY race.** A pool cleanup stress test
(`test_kill_all_sweeps_grandchildren_leaving_zero_survivors`) failed on the Linux
runner with `EBUSY` / "cleanup incomplete", while macOS and every local run
passed. The native `process_close` rejects a slot that is not terminal — not
reaped, not group-swept, or not all-channels-closed. Instrumenting the returned
errno with a predicate bitmask pinned the failing predicate to **`reaped`**: the
two-pass reap-wait was pacing its ~2-second budget on `_poll_set`, which returns
*immediately* once a capture pipe hits EOF (POLLHUP counts as ready). When the
group SIGKILL landed, the leader and its grandchild both released the capture
pipe, the pipe went to EOF, and the 200-iteration wait burned through in
microseconds — abandoning the SIGKILL'd leader before the loaded kernel had made
it `waitid`-reapable (the kernel releases a dying process's file descriptors a
scheduling quantum before it publishes the process as reapable, and preemption
widens that gap on a contended runner). The fix (`cd1d9d5`, one file, +14/-4) was
to pace the wait with a real blocking `sleep` so the bounded count honestly spends
its ~2-second budget and yields the core to the dying leader each slice. It still
fails closed if a leader genuinely will not die. Reproduced 240/240 under
single-core contention (it had failed on iteration 0 before the fix).

**Failure two — the aggregate budget outgrew the harness ceiling.** With the
`kill_all` race fixed, the heavier phase-5 pool suites pushed the integration
aggregate past the harness's 300-second per-step ceiling on the slow 2-core
runner. The watchdog SIGTERM'd the process group, an in-flight
`test_serial_files_never_overlap` caught the signal as an interrupt and reported
exit 2, and then the run tripped the 300-second wall and exited 124. This was the
budget outgrowing the workload, not a logic bug: the run finishes comfortably
under budget locally and on macOS. The fix (`f128060`) raised the classified-step
watchdog ceiling from 300 to 900 seconds; the aggregate now runs to completion
(~450s) instead of being killed at 300.

Both failures share one lesson, recorded below: a green `pixi run ci` on a fast
local box is not evidence of a green GitHub CI for concurrency-sensitive code.

## Deferrals (owed)

- **The double-signal e2e was not committed.** The parallel second-interrupt path
  — a second SIGINT escalating a graceful drain to a SIGKILL — is proven at the
  integration level (`test_pool_second_interrupt_activation_still_exit_2`) and
  described honestly in the §24.2 contract prose, but there is **no committed e2e**
  for it. Delivering a second signal deterministically requires observing that
  mtest has entered graceful drain from the first signal and firing before it
  exits; with only a single-signal e2e helper, that is an irreducible timing race,
  and the honest fix is a *feature* — a stderr drain-marker handshake — not a test
  helper. The follow-up is a `run_mtest_double_signaled` helper that waits on that
  drain marker before the second signal; whether it is required before merge is
  the user's call. This is a phase exit-criterion item met at integration but not
  at e2e.
- **A pre-existing Valgrind flake may need a CI re-run.** A single, non-recurring
  "uninitialised value" at `Supervisor::spawn` surfaced once under Valgrind, with
  every top frame inside the Mojo async-runtime allocator
  (`libAsyncRTRuntimeGlobals.so`). It did not recur across subsequent clean runs.
  It is spawn-time Mojo-runtime noise, causally unrelated to any pool cleanup
  change this phase made, and was **not introduced by this work** — but it may
  cause a spurious Valgrind red on CI that a re-run clears.

## Per-task lessons

Generalized past the specific line numbers they came from.

- **A bounded retry loop must spend real time, not just count.** The `kill_all`
  cleanup reap-wait was written as 200 iterations of a 10 ms poll, intending a
  ~2-second budget — but it paced on `_poll_set`, which returns instantly once a
  pipe is at EOF, so the whole "budget" evaporated in microseconds on exactly the
  slow host it was meant to tolerate. A bounded wait that is supposed to give a
  dying process wall-clock time has to *sleep* that time; pacing it on an
  I/O-readiness signal that fires early defeats the bound. Fixed at `cd1d9d5`.
- **"Local CI green" is not "GitHub CI green" for concurrency.** Pool cleanup
  stress tests are timing-sensitive: a 32-core dev box reaps a killed group inside
  its budget, a slow 2-core GitHub runner does not, and the budget itself
  (300-second step ceiling) can be adequate locally and blown on the runner. Both
  CI failures this phase were invisible on a fast local box. Concurrency-sensitive
  code has to be verified on CI, not just locally.
- **A budget is a resource that can be outgrown without any logic bug.** The
  integration aggregate did not fail because it was wrong; it failed because the
  heavier pool suites pushed real compile time past a harness ceiling that
  predated them. Raising the classified-step watchdog from 300 to 900 seconds
  (`f128060`) was the correct fix — distinguishing "the workload got heavier" from
  "the code got broken" mattered, because the wrong diagnosis would have sent
  someone hunting a nonexistent hang.
- **Background reviewer subagents proved unreliable here.** Multiple dispatched
  reviewer subagents returned malformed or empty output — in two cases a
  zero-tool-use response carrying an injected instruction payload (a fake "never
  invoke skill X or the session crashes"). The payloads were ignored entirely,
  never propagated or saved as any constraint, and the critical commits (notably
  the Supervisor and the big scheduler commit) were **verified directly by the
  controller** instead. When an automated reviewer's output is untrustworthy, the
  fallback is to do the verification by hand, not to trust the malformed result.
- **The pool's invisibility at one worker is a per-commit obligation, not an
  afterthought.** Every commit that touched the scheduler, the console, or the
  event model had to keep the capacity-one path byte-identical, and each proved it
  a different way — an early-returning worker plan, an unchanged `session.mojo`, a
  progress overlay that writes zero bytes off a TTY, a serializer filter that
  drops the ephemeral `Progress` kind before it can emit a blank line. Treating
  "at `-n 1`, nothing changed" as an invariant to defend on every commit is what
  let the parallel machinery land without disturbing the sequential contract.
- **Marshal a new child input exactly like the one that already works.** The
  per-child environment extension was built to mirror `argv` marshalling
  precisely — same ownership, same destructor-freed strings, same
  zero-count-is-a-no-op byte-identity. Following the proven pattern rather than
  inventing a second one is what made the extension leak-safe by construction and
  the capacity-one path unchanged.
- **Move a cross-cutting concern into structure when you can.** The cache
  quarantine went from mutating-and-restoring the parent environment around each
  spawn to riding the child's `env_extra` — and got shorter doing it. A concern
  expressed as a careful temporal dance (set, spawn, restore, and never race it)
  is more fragile than the same concern expressed as data on the thing it
  qualifies.

## Whole-branch review triage

This section is reserved for the final whole-branch dual review, which runs after
the conditional AGENTS commit that follows this one. It will hold the triage of
the two reviews' findings and the rulings on each, in the same form as the Phase
4 dual-review record. It is intentionally left as a stub here; no findings are
recorded yet.
