# Phase 3 notes — resilience without concurrency

Phase 2 closed the per-test gap: mtest could parse a report, classify a test,
and select a subset. What it still couldn't do was survive anything — a
flaky test failed the whole session, a hung compile hung the runner forever,
and a crash told you nothing beyond "something died." This pass is about
trustworthy failure: `--retries` and the FLAKY verdict, `--compile-timeout`
with a compile-specific grace, `--shard` for splitting a suite across
invocations, a bounded crash-attribution pass, atomic precompile promotion,
and narratives that render a crash or timeout honestly instead of guessing.
All of it lands on the same single-child, sequential runner Phase 2 shipped.
The worker pool does not exist yet, and the reason why is the most important
fact in this phase.

Before any of that work started, the pass opened the way Phase 2 did: by
re-checking what was actually shipped, not what memory said was shipped. A
read-only audit walked the report verdict types, the capture-overflow rule,
the build-products registry, `--maxfail` counting, event payloads, the
`collect` exit logic, the contract's served/refused flag table, the exec API,
and the interrupt latch, each against `file:line` in the working tree. Every
item matched. The one thing worth flagging from that pass: the interrupt
latch — assumed in earlier notes to live behind a fixed mmap address — had
already moved into the native C adapter as a `volatile sig_atomic_t`, with
`interrupt_requested()` as the only thing Mojo ever sees. Same behavior,
different address. That relocation turned out to matter a lot once this
phase started asking what a worker pool would need to change.

## Why concurrency waited

The honest headline: this phase shipped resilience for one child, not many.
`-n`/`--workers`, `--serial`, child-environment injection (`env_extra`), and
an interrupt-delivery counter were all left refused, exactly as the CLI
contract already declared them.

The reason is the exec substrate underneath. Supervision runs through a
native C adapter (`native/mtest_exec_native.c`) that keeps exactly one static
process slot and a lock-free state machine. Opening a second child while one
is active doesn't queue or degrade — it fails outright with `EBUSY` from an
atomic `OPEN -> CHILD_ACTIVE` compare-exchange. That's not an oversight to
work around from the Mojo side; it's how the adapter is built, and rightly
so — the single-child ABI is what let Phase 2 reason about supervision
without a scheduler. Giving mtest a real N-child pool means extending that
ABI to a versioned multi-child adapter: new native surface, new native tests,
new gates. That's a deliberate, scoped piece of work on its own, not
something to bolt onto a resilience pass that's already touching retries,
timeouts, sharding, and crash attribution. So this phase drew the line at
capacity one: everything that makes a single child's failure trustworthy
ships now, and the pool — along with `-n`/`--workers`, `--serial`, and the
interrupt counter that only makes sense once more than one child can be
interrupted — waits for the native work that has to come first.

## The child-environment workaround

One piece of resilience did need an environment change and found a way to
get it without touching the native ABI. Quarantining a killed compile means
pointing its rebuild at a fresh module cache via `MODULAR_CACHE_DIR`.
`ProcessSpec` already carries a reserved `env_extra` field for exactly this
kind of thing, but making it live would mean extending the native spec
struct — the same category of change the pool needs, and not one to take on
here.

Instead, the fix uses a fact that's true only because mtest is still
single-threaded: the native adapter snapshots the *live process environ* at
spawn time. So a quarantined rebuild sets `MODULAR_CACHE_DIR` in mtest's own
environment immediately before spawning the rebuild, and restores the prior
value (or unsets it) right after. No native change, no new ABI surface —
just borrowing the parent environment for the width of one spawn. `env_extra`
stays reserved, unread, waiting for the milestone where more than one child
might need a *different* environment at the same time, which is exactly the
case this trick can't cover.

## The killed-compile cache probe

Before committing to a quarantine design, a spike killed a real `mojo build`
mid-flight, repeatedly, to find out what a killed compile actually leaves
behind. Nine trials: SIGTERM-to-the-group and immediate SIGKILL, each at an
early, mid, and late point in the build, each against its own fresh cache.
The sharpest three re-ran the *same* source against the cache the killed
build had just touched, forcing a read of whatever partial state survived.

No corruption, in any trial. Zero zero-length files, zero `.lock`/`.tmp`
leftovers. The module cache turned out to behave like a temp-then-rename
commit: a killed build's entry is either fully absent (recomputed cold) or
fully valid (reused) — never half-written. One trial made the case
concretely: a build killed late left one complete cache entry behind, and
the rerun reused it and finished in under 5 seconds instead of the usual
8.5 — a poisoned cache would have slowed or broken that rerun; instead it
was a valid speedup.

That result picked the narrower of two quarantine designs. Tainting the
whole session's cache after any compile kill would have been the safe-by-
default choice, but the evidence didn't ask for it: only the killed file's
own retry needs a fresh per-attempt cache dir. Every other file keeps using
the shared cache undisturbed. A loud residual-risk warning still fires on
every compile kill, because nine trials on one machine and one beta
toolchain is real evidence, not a proof — the spike deliberately never tried
to land a kill inside the rename's own atomic window, and no real compiler
ICE showed up in any trial to check the crash-signature list against. That
signature list is therefore assumption-pinned, not observed: it says what an
ICE should look like, not what one actually did.

## The segfault shape

Getting the crash narrative right meant confirming what a real SIGSEGV looks
like on stdout, because a controlled `abort()` (signal 4, with mtest's own
`ABORT:` marker line) and an actual segmentation fault are not the same
shape. A live SIGSEGV kills the child before it gets to print anything
structured — no `ABORT:` line, sometimes a bare stack dump, sometimes
nothing at all. A narrative that assumed every crash carries an `ABORT:`
line would misdescribe the more common case. The crash and timeout
narratives render the signal number in words directly from the typed
`Termination` fields and never assume the `ABORT:` marker exists.

## What shipped differently than the frozen contract describes

A few places where the served behavior is narrower than the full v1
contract, each one a deliberate, documented gap rather than a bug:

- The pool, `-n`/`--workers`, `--serial`, `env_extra`, and the interrupt
  counter are refused, per the native single-child substrate above.
- The FLAKY summary line renders as a plain `, N flaky` clause alongside
  crashed/timed-out/compile-error/etc — not a nested `passed (N flaky)`. It
  follows the exact pattern every other file-level outcome already uses in
  the summary band, rather than inventing a special case for this one.
- `--retries` retries a crash-class run failure under selection (`-k` or a
  node id) but not a crash-class build or precompile failure there — the
  default (non-selection) path retries both. Selection's recovery loop
  already carries one other retry mechanism (stale-name recover-once); wiring
  a second, build-side retry through it is deferred rather than rushed in
  alongside it.
- The SIGKILL-escalation clause is narrated on a run TIMEOUT verdict —
  confirmed by a discriminating pair of e2e scenarios, one child that dies
  politely on SIGTERM and one that doesn't, so the clause is proven
  conditional rather than assumed. A compile-timeout's own escalation isn't
  narrated yet: no fixture exists yet that reliably ignores SIGTERM during a
  compile, so the console code renders the bare deadline rather than
  claiming an escalation nothing has recorded.
- The SLOW marker is a fixed 60-second threshold on either the build or run
  step, with no flag to change it. A live TTY progress counter — the more
  useful answer to "is this thing stuck" — ships with the pool, since a
  single sequential child doesn't need much beyond a duration threshold.
- `-j`/`--num-threads` are forwarded to `mojo build` like any other
  `--build-arg`, not rejected. Rejecting them was tied to a compiler-thread
  budget that only matters once concurrent builds can oversubscribe the
  machine; today `mojo build` just spends whatever it wants by default.
- The probe step's own run duration isn't threaded through to the SLOW
  check yet, so a SLOW marker on a probe path currently reads a stale zero
  instead of the probe's real time. Harmless today — nothing depends on a
  probe ever reading SLOW — but worth fixing whenever someone next touches
  that duration plumbing.

## What the review process caught

The thesis of this phase is that failure output has to be trustworthy — a
crash, timeout, or retry banner should say only what actually happened. The
most useful thing to record here isn't the feature list; it's what the
review process caught before that thesis had a chance to be undermined by
its own reporting code.

A compile-timeout banner claimed the compile "exceeded the deadline every
time" whenever more than one attempt ran — but `attempts_used > 1` just
means more than one attempt happened, not that every one of them timed out.
A first attempt could just as easily die of a compiler crash and get
retried, with only the second attempt actually blowing the deadline. The fix
was to stop claiming anything about attempts the code has no typed record
of, and say only what the final attempt's own fields can prove.

A PRECOMPILE-ERROR banner rendered "exited 0" on a step that had, in fact,
failed — because the compiler really had exited 0 and only the atomic rename
onto the output path lost (the output path existed as a directory, or its
parent was read-only). Reporting an exit code that belongs to a step's
*success* path on a banner announcing its failure is exactly the kind of
detail that sounds authoritative and is backwards. The fix keeps that
result's "ending" deliberately unset and has the banner explain, in words,
that the rename lost — not the compiler.

Crash attribution — the bounded post-pass that reruns a crashed file to try
to name which test inside it actually crashed — had a path where it could
name a culprit out of a *stale* binary. A crash-class build retry rebuilds
to a fresh `.attempt-N` path and runs that, so reconstructing the binary
path from the file's mangled name instead of carrying forward the actual
path that crashed could mean probing a binary that either doesn't exist or,
worse, is a leftover from an earlier, different run — attributing a crash to
code that never executed. The fix carries the exact binary path the crash
came from end to end, and only trusts a cached probe listing when it can
confirm that listing came from that same binary.

A promotion end-to-end test for the atomic precompile guarantee passed —
even against the exact regression it was written to catch — because its
stand-in compiler never actually wrote to the output path it was supposed to
be protecting. A test that can't fail when the property it names is broken
isn't testing anything; it's decoration.

And an escalation "proof" — the claim that a timed-out child's verdict
correctly reports whether the kill needed to escalate from SIGTERM to
SIGKILL — existed only as an observation: run the stubborn fixture, look at
the output, see the right words. That's not nothing, but it's also not proof
the clause is conditional rather than hardcoded. The fix paired the stubborn
fixture (ignores SIGTERM, forces an escalation) with a polite counterpart
(dies cleanly on SIGTERM, no escalation) and asserted both directions: the
escalation clause appears when and only when an escalation actually
happened. The same discriminating-pair pattern closed a related gap in the
crash classifier — a compile that fails with a crash-signature banner in
its stderr is retried and quarantined, while the same nonzero exit with
ordinary error text is not, proving the signature scan is what's deciding,
not just the exit code.

The pattern across all five: none of them were caught by running the code
and eyeballing correct-looking output. They were caught by asking what
happens when the property under test is actually broken — a mutation, a
stand-in that doesn't do its job, a fixture that takes the other branch —
and checking the test goes red. "I ran it and it looked right" is not
evidence a test protects anything. That standard is the one to carry
forward into every phase after this one.

## Process honesty

Three mistakes from this phase, worth naming plainly rather than smoothing
over:

- A shell exit code got masked at one point, which let an already-red branch
  report green. The real failures underneath were gate-registration debt —
  new unit suites and fixtures had been added without registering them in
  the harness membership sets or documenting new unsafe constructs, so the
  harness and safety gates were quietly red until that debt was paid down.
- Running a full build concurrently with another build in progress corrupted
  a shared build artifact mid-write. Builds now run one at a time, serialized,
  full stop.
- Running the e2e harness outside its toolchain environment produced
  failures that looked like real regressions but were actually just the
  wrong `mojo` on the path.

The correction in all three cases is the same shape: run and name the full
gate set every time, read the real unmasked exit code, serialize builds that
touch the same artifacts, and always invoke through the toolchain
environment rather than assuming ambient tools match. None of these cost
correctness in what shipped — they cost time chasing symptoms that traced
back to how the work was being run, not what the work did.

## Still deferred: benchmark / `auto` sizing

`--workers auto` needs to know how many concurrent builds and runs a machine
can sustain without thrashing — a question that has no answer until there's
a pool to size in the first place. There is nothing to benchmark against a
single sequential child, so this waits with everything else the pool
brings.
