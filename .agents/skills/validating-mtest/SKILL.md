---
name: validating-mtest
description: Use when QA-testing or acceptance-testing the mtest runner, validating it against docs/cli-contract.md, verifying exit codes / outcome labels / determinism / the availability matrix / the collect stream / the source-writing subcommands, checking a change or a Mojo re-pin did not break a user-facing promise, or hunting for silent or contract-violating behavior before a release. Also covers clean-room validation in Docker — when a probe needs a shell or tool the host lacks, a fresh-machine install path, or an environment (non-root, hostile umask, empty PATH) this workstation cannot produce.
---

# Validating mtest

## Overview

mtest's product is **trustworthy verdicts**: an exit code you can gate CI on, an
outcome vocabulary that never lies (a CRASH is not a FAIL), and byte-identical
machine output. Validating it means proving those promises hold — not that the
code "runs".

**The contract is the oracle.** [`docs/cli-contract.md`](../../../docs/cli-contract.md)
is the single source of truth; §24 states what *this build* serves vs. refuses.
Assert what the contract **promises**, never what the implementation happens to
render — console text and error wording are **informal** (§20). Lean on the
STABLE surfaces: exit codes (§9), the `collect` listing (§16), stream routing
(§16/§19), and outcome *distinctions* (§10). When behavior and contract
disagree, that gap is the finding — decide which side is wrong (Triage).

**The one defect that matters most is SILENT test-set corruption:** running the
*wrong set* — a dropped, doubled, mis-deselected, mis-excluded, or wrongly-run
test — while still printing a plausible green summary. Exit codes are coarse and
labels are presence-only, so a bare "did it print PASS?" check is blind to it.
Two techniques defeat it, and the validator is built on them:

- **Exact sets & counts.** Assert the *exact* `collect` node-id set and *exact*
  summary counts — never "non-empty and sorted", never a bare label.
- **Poison probes.** Make the test that should *not* run a FAIL/CRASH. Then a
  broken selection / exclusion / early-stop flips the **frozen exit code**, so
  the check discriminates on the contract's hardest guarantee instead of on
  informal text.

The **build cache (§8.5) is the newest instance of that same defect**, and the
sharpest: *a stale cache hit is a green run that never compiled the code under
test.* The right test set runs, the summary is plausible, the exit code is 0 —
and the binary is the one built before the edit. Hunt it the same way: edit an
input, assert the *counters* say a rebuild happened, and make the edit a poison
one so a wrong reuse flips the exit code instead of merely looking fast.

## When to use

- Acceptance/QA pass over the CLI from a user's perspective.
- Before a release, or after re-pinning Mojo (`transcripts` change → re-validate).
- After any change to `cli`, `discover`, `select`, `session`, `cache`,
  `protocol`, or `report` — confirm no user-facing promise regressed.

Not for: internal unit correctness (`pixi run test`) or protocol-snapshot
drift (`pixi run transcripts-check`).

## Quick start — run the oracle

This oracle is a **blocking release-floor gate**, not a manual tool:
`contract-check-strict` runs inside `pixi run ci` and both hosted platform
matrices (immediately after each platform's end-to-end row). Use the
commands below for local iteration; `pixi run contract-check-strict` is
what actually gates a merge.

```bash
pixi run contract-check --                 # rebuild-if-stale, run the whole roster
pixi run contract-check -- -k select       # filter by check name
pixi run contract-check -- --strict        # safety-critical SKIP fails
pixi run contract-check -- -v --keep       # dump streams, keep scaffold
pixi run contract-check-strict             # the actual blocking gate: --strict --no-rebuild
                                            # against the binary THIS invocation's build-bin just produced
```

`scripts/qa/contract.py` (Python lives under `scripts/`, per AGENTS.md)
scaffolds a throwaway user project — a library, clean all-pass suites with a
**known exact node-id set**, and **poison** files — outside the repo, then drives
`build/mtest` across the contract matrix, printing PASS/FAIL per check tagged
with its contract §. `contract-check` (the local-iteration task above)
**rebuilds `build/mtest` when stale** (a stale binary validates old code — a
real false-green risk); `contract-check-strict` (the gate) instead runs
`--no-rebuild` against the binary its own Pixi `build-bin` dependency just
produced in this invocation, and **fails closed (exit 2)** if that binary is
missing or looks older than its inputs, rather than silently building or
validating something stale. Both **exit 2 on setup failure** (distinct from a
contract failure's 1), and treat a zero-check run or a `--strict` skip as
non-passing. Extend it by adding a `Check(...)` to `build_matrix()` (or a
bespoke method for multi-run checks) — one behavior, cite the §, prefer an
exact/poison assertion over a substring.

This is the mechanical floor. The judgment below finds what the matrix does not
yet encode.

## The frozen spine — exit codes (§9)

Every check ultimately asserts an exit code. Know the table cold; a wrong code is
always a bug:

| Code | Meaning |
|------|---------|
| 0 | every selected outcome PASS or SKIP (exclusions allowed) |
| 1 | any FAIL / CRASH / TIMEOUT / COMPILE-ERROR / **COMPILE-TIMEOUT** / MALFORMED-SUITE / PRECOMPILE-ERROR; or a would-be 0 with a FLAKY file under `--fail-on-flaky` |
| 2 | interrupted (SIGINT/SIGTERM) — partial summary printed |
| 3 | internal mtest error, incl. protocol drift and spawn failure |
| 4 | usage error — detected **before any test runs** |
| 5 | nothing collected (empty walk, `-k` matched nothing, all excluded, only NO-TESTS) |

Precedence when outcomes mix: 4 → 2 → 3 → 1 → 5 → 0, with the `--fail-on-flaky`
rung last of all: it can only move a 0, never displace a code another fact
already decided. Probe that rung from both sides — an interrupt or an
everything-excluded session with a FLAKY file must still exit 2 and 5.

Four commands have narrower domains of their own and the table above does not
govern them: `config show` and `doctor` (§27), `debug` (§28 — `{1,2,3,4}`
pre-handoff, and the debuggee's own status after), and `new`/`init` (§29 —
`{0,3,4}`).

## Running mtest correctly (harness traps that produce false findings)

A false finding wastes everyone's time. Most come from the harness, not mtest:

- **Toolchain on PATH.** mtest spawns `mojo build` per file. Run under the pixi
  environment; the validator captures it and scrubs a stray `MTEST_MOJO` so the
  scaffold and the runner do not build with different toolchains.
- **`PATH` alone is not the pixi environment.** A hand-rolled scaffold outside
  `pixi run` also needs `MODULAR_HOME` (and `CONDA_PREFIX`); without it every
  file COMPILE-ERRORs with `unable to locate module 'std'` and you are one step
  from filing the scaffold as a runner defect. Copy both out of `pixi run env`
  into the scratch environment.
- **The tool shell is zsh, which does not word-split an unquoted variable.** A
  refusal matrix built from `for f in "--retries 1"; do mtest debug $f $NODE`
  passes *one* argument, so every row comes back `unknown flag '--retries 1'`
  and the applicability check you meant to run never happened. Build flag
  matrices in an explicit `bash` script with `"$@"`. `PIPESTATUS` needs the same
  `bash -c`; in zsh it is `pipestatus` and reads empty.
- **Root = current working directory (§2).** An operand outside the root is a
  correct exit-4 error. To test a scaffolded project, run mtest *from inside* it
  — do not pass an absolute path into it from elsewhere and call the exit-4 a bug.
- **Capture exit codes directly.** `mtest ...; echo $?` — never `mtest ... | tail; echo $?`
  (`$?` is the pipe's last command). This bit the original QA pass twice.
- **Separate the streams.** §19 routes help/version to **stdout**, usage errors
  to **stderr**; §16 routes `collect` node ids to **stdout**, diagnostics to
  **stderr**. Merging them (`2>&1`) makes routing regressions invisible — assert
  per stream.
- **A departed reader and a closed descriptor are two different probes.**
  `mtest ... | head -1` tests §9's SIGPIPE promise: the write is lost and the
  exit stays in the domain. `mtest ... >&-` tests something else — there is no
  reader, no pipe and no `EPIPE`, the descriptor is simply gone. Run both, on
  both streams (a usage error only writes to fd 2). A command that survives the
  first can still die on the second, and only the second reaches the writer's
  own error handling.
- **Session suites need the native object.** A bare
  `build/mtest tests/integration/test_session_*.mojo` link-fails on
  `mtest_exec_*` symbols — a missing `-Xlinker build/native/...`, a harness
  artifact, **not** a COMPILE-ERROR bug. `scripts/harness/selfhost.py` passes it
  as `--build-arg=-Xlinker --build-arg=<native object>` on every self-hosted
  invocation.
- **`.mtest-cache/` survives your scaffold.** The store lives in the invocation
  root, so a scaffold you reuse — or a repo checkout you run in twice — starts
  its second run warm. A run that never compiled is a run whose compile-time
  behavior you did not observe: a COMPILE-ERROR probe, a `--compile-timeout`
  probe, or anything asserting build diagnostics silently stops testing what it
  names once the file is in the store. Scaffold a fresh root per scenario, or
  `--cache-clear`.
- **Never time a run against a warm store, and never call time evidence.** The
  compiler keeps a module cache of its own, so an uncached rebuild can finish as
  fast as a hit. The **counters** are the observable: `builds: N, cached: M` on
  the band, `built_files`/`cached_files` on the `--json` `session_finished`
  record. Their SUM is the run's first-attempt compile admissions (compile
  failures included, gates included; retries, `collect` probes, and precompile
  steps excluded) and is stable for identical inputs; how it *divides* depends
  on what the store held at start, so a check pinning `built_files` alone is
  warmth-dependent and will flap. `--no-cache` is how you take a measurement
  with the store out of the picture — it neither reads nor writes, so unlike
  `--cache-clear` it leaves the next run just as warm as it found it.
- **`--cache-clear` also deletes `lastrun`.** A paired scenario that clears the
  store between halves has destroyed the `--lf`/`--ff` state along with it, and
  the clearing run repopulates the store on its way out.
- **A `cache-off` warning is contract, not noise** — an event on the stream, a
  line ahead of the first file on the console, a `collect: cache-off: ...` line
  on stderr under `collect`. Never filter it, never read it as a failure, but do
  notice it: a scenario that meant to exercise the cache and got a `cache-off`
  proved nothing about the cache.

**Reproduce before you report.** Re-run a suspected finding cleanly (fresh CWD,
direct exit capture, correct build) before writing it up. The original pass
produced a false positive (`--color always` vs `NO_COLOR`) from a bad
invocation; a second clean run retracted it. **Rebuild first** — an all-green run
against a stale binary proves nothing.

## Clean-room validation with Docker

Some promises cannot be observed from this workstation: a shell the host does
not have, a *fresh user's* install path, or behavior that depends on an
environment the developer's box has already been configured out of. Reach for a
container there — and only there.

**Reach for Docker when:**

- **The probe needs a tool the host lacks.** The fish completion script shipped
  unparsed by anything for a full task because `fish` is not installed here.
  `docker run --rm -v "$PWD":/w:ro debian:stable-slim` with
  `apt-get install -y zsh fish` parses all three in under a minute.
- **The claim is about a fresh machine.** "The rendered completion script works
  when a user sources it" is a statement about a box that has never seen this
  repo. A pristine image is the only honest oracle for it; your shell has
  history, rc files, and a warm `PATH`.
- **The probe would otherwise install onto the developer's machine.** Mount the
  repo **read-only** (`:ro`) and install inside the container. Nothing you do
  there can touch the host tree.
- **You need an environment the host cannot produce** — a different locale, a
  non-root user with a hostile `umask`, a directory the process genuinely cannot
  write, an empty `PATH`.

**Do NOT reach for Docker when:**

- **`pixi` already provides the tool.** A conda-forge dependency under
  `[target.linux-64.dependencies]` installs into the project's `.pixi/`, not
  system-wide — it does not "mess up the machine" either, and it is the route CI
  can reproduce. Docker is the fallback when a package will not solve, not the
  default.
- **The property is host-dependent in a way Linux cannot fake.** A container
  cannot stand in for the macOS lane: `/tmp` is not a symlink to `/private/tmp`
  there, and an ext4/overlay filesystem is case-**sensitive**, so a
  case-insensitive destination collision (the APFS defect class) is
  unreproducible. Those belong on the real macOS CI lane; a green container run
  proves nothing about them.

**Container traps that manufacture false findings:**

- **You are root by default.** Every permission-refusal probe — `chmod 0500` on
  a parent, an unwritable destination, a read-only directory — is a **no-op for
  root**, so the failure you meant to provoke never happens and the run comes
  back green. Pass `--user "$(id -u):$(id -g)"`, or drop privileges inside.
  **Drop them after the image is built, never at `docker run` time for a
  container that still has to install anything**: `--user` also strips the
  privilege `apt-get` needs, so the same flag that makes a permission probe
  meaningful makes provisioning fail. Install as root in the `Dockerfile`, then
  run the probe with `--user`. That cost a round when the fish scripts were
  first driven headlessly.
- **Mount read-only unless you mean to write.** `-v "$PWD":/w:ro` is the
  default posture; a writable mount lets a container-side build scribble
  root-owned artifacts into the host tree.
- **The binary must match the container's architecture and libc.** Mounting a
  locally built `build/mtest` into an image works only when both are the same
  arch and the image's glibc is new enough. If it will not run, build inside.
- **Bare `apt-get` output is noise.** Redirect it; an installer's progress lines
  buried a real parse error more than once.

**Recipes that work headlessly** (no TTY, no interactive shell):

```bash
# bash: drive the completion function directly
bash -c 'source ./mtest.bash
  COMP_WORDS=(mtest -q doctor --retr); COMP_CWORD=3
  _mtest_complete; printf "%s\n" "${COMPREPLY[@]}"'

# fish: complete -C computes candidates for a command line
fish -c 'source ./mtest.fish; complete -C "mtest --collect-only --"'

# zsh: needs a pseudo-terminal — zpty is the only reliable route
```

Assert the candidate **set**, not a substring of the script's text: a renderer
test that greps for `--collect-only` passes even if the entire feature is
deleted, because that string is also just a flag spelling. This is the same
exact-sets discipline the rest of this skill applies to `collect` output.

## Validation matrix (what the oracle asserts)

Every row below is a check in `scripts/qa/contract.py` unless marked *(manual)*.

| Area | Assertion (frozen-surface / poison) | §|
|------|--------|--|
| version | prints the exact version string | 19 |
| outcomes | PASS/FAIL/CRASH/COMPILE-ERROR/MALFORMED/TIMEOUT — right code; **CRASH ≠ FAIL**; NO-TESTS-only → 5 | 9,10 |
| discovery | nonexistent → 4 (stderr); empty → 5; explicit non-`test_` file runs; escape-root → 4 (stderr) | 2,5 |
| collect set | **exact** node-id set for `tests/`, sorted; byte-identical across runs | 5,16,17 |
| selection | node id runs exactly one, **poison sibling never runs**; `-k` exact count + case-insensitive; empties → 5; unknown test → 4; **dir node-id → 4** | 5,10.1 |
| exclusion | pattern **truly removes** a would-crash file (exit stays 0); stale warns; exclude-all → 5 | 12 |
| early stop | `-x` / `--maxfail` leave the **poison sibling NOT-RUN** (exact not-run count); failing `--gate` aborts (exact not-run) | 11 |
| collect flags | run-only flags (`-x`/`--maxfail`/`--durations`/`--gate`/`-s`/`--retries`/`--json`/`--junit-xml`/`--gh-annotations`, the last three even `off`) → 4; streams split + listing continues; §24.3 deviations (`-k` ignored w/ notice; node-id lists whole file) | 4,16,24.3 |
| build args | `-o`/`--emit`/extra-source → 4 **and the test never ran** (pre-run detection) | 8.4,9 |
| exit 3 | bad `--mojo` (spawn fail) → 3; **off-grammar report (drift) → 3**, never a verdict | 6,16,24.2 |
| refused v1 flags | **all 9 spellings** → 4, each naming the flag + "v1 contract" | 24.1 |
| value validation | bad `--durations`/`--timeout`/`--color`/`--show-output` → 4; `-q -v` → 4 | 3,15.1 |
| precompile | success auto-adds `-I` (import resolves, PASS); failure → `PRECOMPILE-ERROR` + casualty files listed | 8.3,10 |
| interrupt | SIGINT to **mtest only** → exit 2, partial summary, **child tree freed** (tests mtest's own teardown, not a direct signal) | 9,24.2 |
| color | `--color never`→no ANSI, `always`→ANSI, and the flag **wins over `NO_COLOR`** | 15.1 |
| build cache *(manual)* | edit a source → `cached` drops and the **new** behavior runs (poison the edit so a stale hit exits 1); `touch` alone → still a hit; a new `mojo` or an edit under an `-I` root → everything rebuilds; unclassifiable `--build-arg` → one `cache-off` warning, exit unchanged; `--no-cache` writes no store at all; `--cache-clear` on a symlinked or unmarked `.mtest-cache` → 4 with the tree untouched | 8.5,9 |
| flaky verdict *(manual)* | `--fail-on-flaky` and `[run] fail-on-flaky` move a 0 to 1 and **nothing else**: same `TRY` lines, `--maxfail`/`-x` leave the exact same not-run count, and a FLAKY file still *clears* its `lastrun` entry. JUnit stays `failures="0"` beside exit 1; the `--json` `exit_code` and the `::notice` carry the demotion | 13,9 |
| shuffle *(manual)* | one seed = one order, replayed; the **set** never moves (digest the sorted node list across seeds); JUnit / annotations / `--json` projection identical seed to seed; gates first in listed order, `--shard` membership unchanged, `--serial` still last; `--seed` without `--shuffle` and `--shuffle` beside `--lf`/`--ff` → 4; `[run] shuffle`/`seed` → 4 unknown key | 17,18 |
| collect stream *(manual)* | `--format lines` **byte-identical** to the flagless listing; JSON node order == lines order; whole stream byte-identical across runs; terminal `exit_code` == process exit at 0/1/2/3/5; a usage error emits **no stream at all**; stdout carries stream bytes only | 16 |
| debug *(manual)* | two `build:`/`run:` lines, then the debuggee's own status (a crasher exits 139 with no band); paste both lines back and they work; every out-of-grammar flag → 4, reporter refusals naming the reason; `[report]` keys write nothing and `lastrun` stays `cmp`-clean; a malformed doc is still 4 | 28 |
| new / init *(manual)* | `new` refuses `::`, a non-`.mojo` name, an uncollectable basename, and an existing target (4), and what it writes **passes**; `init` re-run is an all-skip at 0, its workflow diffs clean against the first `docs/ci.md` YAML fence, and every `.gitignore` decision agrees with real `git check-ignore` | 29 |
| completions | each shell renders and **parses** (`bash -n`/`zsh -n`/`fish -n`); a missing, repeated, or unrenderable operand → 4, and so does anything past one operand and `-h`; a closed pipe leaves 0 and an unwritable stdout gives 3. Beyond the oracle, `pixi run completions-check` drives the rendered scripts in real shells and asserts the **readline buffer after TAB**, not a candidate list — every defect this feature shipped said the right thing and did the wrong one | 30 |

Still worth a *manual* probe beyond the oracle: `--collect-only` alias
equivalence; exclusion winning over `--gate`/explicit operand (§12); valid
`--build-arg` actually forwarding; the whole build-cache row above, which the
oracle does not encode at all today; and the deepest honesty case — a **new**
protocol drift after a Mojo re-pin must route to exit 3, never launder into a
verdict (the `drift/` scaffold shows the shape; `e2e/hostile` and
`e2e/chameleon` have more).

The cache row is worth building as a *paired* run rather than a single one: the
same scenario twice over one root, asserting the exact counters both times.
Cold then warm proves reuse happens; cold, edit, warm proves it stops happening
when it must. Only the second pair can catch a stale hit, and only the counters
plus a poisoned edit make it fail loudly instead of quietly passing.

Two of the manual rows need a fixture the scaffold does not have:

- **FLAKY on demand.** Nothing about `--fail-on-flaky` is reachable without a
  file that fails crash-class once and passes next. Copy the shape of
  `e2e/flaky/test_flaky.mojo`: a marker path under the invocation root decides
  the outcome, the first attempt writes it and then faults, the retry finds it
  and passes. Delete the marker between scenarios or the second scenario runs
  green on the first attempt and proves nothing about the rung.
- **Shuffle needs a digest, not a count.** A per-seed *count* cannot tell a
  dropped file from a doubled one. Add a poison file, then compare a hash of the
  **sorted** node-id list from each seed's `--junit-xml`: equal digests plus an
  equal exit code across seeds is what proves the order moved and the set did
  not. Keep the digest out of Python's `hash()` — it is salted per process.

## Triage — classify every finding

```
Behavior ≠ contract?
├─ Contract is right, code is wrong ............ BUG → fix (TDD) + add a Check
├─ Code is right, contract is silent/stale ..... DOC gap → amend contract/README
└─ Both agree, behavior is merely surprising ... BY-DESIGN → note, don't "fix"
```

- A **BUG** breaks a promise: wrong exit code, a lie in the outcome (CRASH as
  FAIL), or **silent** wrong behavior. Highest signal.
- A **DOC gap** is real but resolved by writing — e.g. §9 not naming
  NO-TESTS-only among its exit-5 examples, or a §24 availability caveat.
- **BY-DESIGN**: matches a documented rule even if unintuitive — a spawn failure
  is exit 3 "internal error" per §24.2, *not* a usage error; do not "fix" it into
  a 4. Check §24 before calling something a bug.

Severity by user impact: silent-wrong > wrong-exit-code > confusing-output.

## Red flags — STOP

- A check "passes" but you never separated the streams or saw the exit code — you
  piped `$?` or merged `2>&1`.
- A check asserts only that output *exists* (a bare label, "sorted and
  non-empty") — it cannot catch a within-class miscount or wrong set. Assert the
  **exact** set/count, or add a **poison** probe.
- You are asserting informal wording the contract calls out as changeable (§20).
- Running `contract-check` (not `-strict`) by hand and it is all-green but you
  passed `--no-rebuild` — that flag now fails closed (exit 2) on a stale or
  missing binary rather than silently validating old code, but only if you
  pass it; without it, `contract-check` rebuilds first.
- A safety-critical check SKIPped and the suite still exited 0 — run `--strict`.
- A run you called green whose band said `builds: 0` — nothing was compiled, so
  it says nothing about the code you just changed. Check the counters before
  you believe any result about compile-time behavior.
- You edited a source, reran, and the outcome did not change — before filing it,
  confirm `builds` moved. An unchanged verdict from an unchanged binary is a
  cache finding, not a runner finding, and it is the one that matters most.
- You compared two wall-clock numbers and concluded something about the cache.
  Timings here are confounded by the compiler's own module cache; the counters
  are the observable.
- A scenario reused a scaffold root and the second run reported `cached: N` —
  its build-side assertions stopped executing at that point. Fresh root, or
  `--cache-clear`.
- A cache condition changed a verdict or an exit code. §8.5 promises it never
  does: a cache that cannot be trusted must cost a rebuild, never a run. This
  one is always a BUG, at the top of the severity order.
- A flag matrix where every row came back `unknown flag '--x value'` — the shell
  handed mtest one argument, so you tested quoting, not applicability.
- A `--shuffle` scenario whose seed you did not record. The order is an input;
  a failure you cannot replay with `--seed N` is not a finding yet, and the
  console header and `--json` `session_started.shuffle_seed` both carry it.
- A `collect --format json` check that read only the node lines. The terminal's
  `exit_code` is specified to equal the process exit *including teardown* — read
  both and compare them, and treat a **missing** terminal as truncation rather
  than an empty test set.
- A `debug` scenario you scored by its exit status alone. Past the handoff that
  status is the debuggee's, not a verdict — what mtest owes you there is the two
  lines, the refusal set, and having touched no report destination or `lastrun`.

## Complementary gates (do not reinvent)

`pixi run e2e` (known-outcome fixture tree), `pixi run test` (exhaustive Mojo
unit + integration), `pixi run dogfood-check` (three focused real-pipeline
probes), `pixi run transcripts-check` (protocol pin), and `pixi run
cache-protocol-check` (real `build/mtest` processes against throwaway projects,
concurrently and under the publication fault seam — the store's protocol
properties asserted from outside, and the only non-reading coverage `--no-cache`
and `--cache-clear` have). This skill is the black-box, user-perspective layer
**on top** of those; if it and `e2e` ever disagree about a promise, that
disagreement is itself a finding.
