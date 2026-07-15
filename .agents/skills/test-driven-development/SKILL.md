---
name: test-driven-development
description: Test-driven development for the mtest repo — a pytest-like test runner for Mojo that supervises the stdlib's per-file TestSuite as subprocesses. Use whenever you write or change observable behavior — a supervision step, a report parser, an exit-code verdict, a discovery walk, a bug fix, a refactor of anything a test can see. Write the failing test first; reproduce a bug with a transcript, fixture, or known-outcome tree before fixing it. Apply on every behavioral change, not only when the user asks for tests. Covers this repo's TestSuite mechanics, the transcript / tripwire / self-verifying-generator patterns, and its integer-exact assertion policy (no tolerances — exit codes and counts are exact). Defers to mojo-coding-guidance for how the code under test is written and to the global mojo-syntax skill for syntax.
---

# Test-Driven Development (mtest)

Write the failing test before the code. For a bug, reproduce it with a test — or
a golden transcript — *before* fixing it. Tests are proof; "looks right" is not
done. This is a test runner, not a numerics project: there is essentially no
float math anywhere in `src/`. A supervised process exits with an exact integer
code or dies by an exact signal; a report declares an exact count of tests; a
discovery walk finds an exact set of files. Every quiet bug here is an off-by-one
or a misattribution — a crash counted as a failure, a report-lookalike line
counted as a result, an exit code masked to 1 — and every test locks one such
invariant exactly, not a coverage number.

This skill covers the *process* and *shape* of a good test here. It does not
restate how the code under test must be written — cite
[mojo-coding-guidance](../mojo-coding-guidance/SKILL.md) for that (especially the
build-then-execute rule and the crash-≠-fail discipline), and the global
`mojo-syntax` skill for test syntax. Project rules live in
[AGENTS.md](../../../AGENTS.md) and override this skill, including the layering
plan, the Python-containment rule, and the transcript lifecycle this skill leans
on.

---

## The TestSuite mechanics

mtest's own tests are ordinary `def ... raises` functions discovered by
`TestSuite` and run against the **precompiled package** (`build/mtest.mojopkg` —
`mojo package` does not exist in `1.0.0b2`, only `mojo precompile`). Every test
file ends with the same runner, exactly as `tests/integration/test_transcripts_smoke.mojo`
does today:

```mojo
from std.testing import assert_equal, assert_true, assert_raises, TestSuite
# from mtest.exec import run_supervised   # once the module lands


def test_false_binary_exits_nonzero() raises:
    var r = run_supervised(ProcessSpec(argv=["/bin/false"]))
    assert_true(r.termination.is_exited())
    assert_equal(r.termination.code(), 1)


def test_bad_timeout_flag_raises() raises:
    with assert_raises(contains="--timeout wants an integer"):
        _ = parse_args(["--timeout", "soon"])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

**Crucially, the repo eats the discipline the product sells.** The suite is run
by `scripts/test_all.sh`, which for each classified suite **builds a binary
with `mojo build` and executes it directly** — never `mojo run`, which masks a
crashing process's exit code to 1 and can JIT-crash in CI (#6413). Run the whole
suite (the canonical green gate), or one file while iterating:

```bash
pixi run test-direct                               # independent gate — build pkg, then build+execute every suite
pixi run build && mojo build --no-optimization -I build -I tests/support \
    tests/integration/test_exec_capture.mojo -o build/tests/integration/test_exec_capture && build/tests/integration/test_exec_capture
```

`scripts/test_all.sh` builds the package first (fail-fast on a broken toolchain
or a package that no longer compiles), then recursively inventories the requested
classified roots in sorted order — no hand-maintained execution list to drift. A stale `build/mtest.mojopkg` is the
classic "my change did nothing" trap: after any `src/` edit, rebuild before
running a single test file by hand, or the test exercises stale code. One file
per unit under test, named `tests/unit/test_<thing>.mojo` or
`tests/integration/test_<thing>.mojo` according to the boundary it crosses.

**Keep test modules small.** Mojo `#6554` is a `TestSuite`-discovery compile
stall that scales with a module's *function count*, not file size. A file that
grows past a dozen or so `test_*` functions is a stall risk. When a file starts
stalling, split it along the natural seam (`test_exec.mojo`,
`test_protocol.mojo`, `test_discover.mojo` rather than one giant
`test_mtest.mojo`) and add a `SLOW_6554` exclusion array to
`scripts/test_all.sh`. Per-test bracketed timings are unreliable on `1.0.0b2` —
measure wall time with `time`, not the harness's own numbers.

---

## The test pyramid, by layer

`src/mtest/` is built foundational-to-high-level, and each layer earns its own
kind of test:

| Layer | Tests against | Fixture/oracle |
|---|---|---|
| `model` — outcomes, events, exit-code precedence | the precedence function over every outcome multiset | pure logic — enumerate the domain |
| `config` — RunnerConfig | defaults, flag → field mapping | pure logic |
| `discover` — walk, pattern, excludes | a temp tree of `test_*.mojo` + decoys | a hand-built directory |
| `protocol` — report/collect parsing | the committed golden transcripts | `goldens/transcripts/` |
| `report` — reporters | rendered output for a fixed event stream | structural assertions |
| `exec` — the POSIX process adapter | supervision of real system binaries | `/bin/echo`, `/bin/false`, `/bin/sleep` |
| `session` — orchestration | verdict + exit code end to end | the known-outcome tree (below) |
| `cli` — argument parsing | every flag × spelling × arity × domain | the flag-spec table itself |

Each layer reaches for *its own* oracle first: `protocol` tests parse the frozen
transcripts (no need for a live suite to exist); `exec` tests supervise system
binaries as targets (hermetic, fast, no nested `mojo build` inside a unit test);
`session` tests assert verdicts against a committed tree of known-outcome
fixtures. **Spawning a shell as a target fixture is banned** everywhere, exactly
as it is banned in the product — supervise a real binary, not `/bin/sh -c`.

---

## Four patterns worth naming

### Golden-transcript tests — freeze the toolchain's protocol, byte for byte

The transcripts under `goldens/transcripts/` are this repo's golden tests at
project scale: committed probe `fixtures/`, run at the pinned Mojo toolchain,
their normalized output frozen and diffed byte-for-byte by `pixi run
transcripts-check`. **The toolchain IS the oracle** — a transcript pins exactly
what `std.testing.TestSuite` emits at the pinned version, which is what lets the
report parser be written against frozen bytes instead of a remembered format.

**A red `transcripts-check` after a repo change indicts the change, not the
transcript.** Regenerating a committed transcript is legitimate *only* when the
oracle side visibly changed — a Mojo pin bump (visible in every transcript
header) or a deliberate fixture/matrix edit — it happens only via `pixi run
transcripts` (never by hand), and it lands as its own commit with the reason
named (AGENTS.md's transcript lifecycle). A "no behavior change" refactor commit
that moves a transcript byte is lying.

### Hostile-output parser tests — a parser that reads garbage must fail

Structural well-formedness is not enough: a parser can "succeed" while reading
the wrong field. The parser tests use the transcripts as fixtures **and**
deliberately corrupt them, because the dominant failure mode is
plausible-but-wrong reading:

- **Anchor discipline.** The `noisy` fixture prints a report-lookalike line
  (`    PASS [ 0.001 ] fake_impostor`) *before* the real report. A test pins that
  the impostor sits before the last `Running <N> tests for` anchor and must never
  be counted — first-match scanning would double-count. This is already the
  `test_noisy_impostor_precedes_the_real_report` shape in
  `test_transcripts_smoke.mojo`.
- **Count reconciliation.** For every report-carrying transcript, assert
  `declared == rows == summary_total == passed + failed + skipped`, tally by
  tally. A parser that reads a mixed-up file satisfies structural checks but fails
  reconciliation.
- **Corruption cases.** A truncated report, a declared count that disagrees with
  the rows, a missing `Summary` line — each is a hand-written three-line fixture
  the parser must reject with a named MALFORMED-SUITE error, tested with
  `assert_raises(contains=...)`.

### Known-outcome trees — assert verdicts against declared expectations

`session`'s oracle is a committed tree of probe files with *declared* outcomes: a
passing file, a mixed pass+fail file, a crashing file (`abort("…")` — the message
is required), a zero-test file (exits 0 → PASS at file level, the manifest says so
explicitly so the ceiling is documented, not hidden), a noisy file, a
compile-error file, a `helper.mojo` that must NOT be discovered, a nested
directory proving recursion, and an excluded directory. A `MANIFEST` maps file →
expected verdict → expected contribution to the exit code, with a rationale line
each. A Python end-to-end harness under `scripts/` builds the runner once and
asserts, per scenario, the **exact exit code** and the **structural** shape of the
output. Python harness logic stays under `scripts/`; test-only subprocess actors
may live under `tests/fixtures/exec/`. The runner itself stays pure Mojo.

### The tripwire and the self-verifying generator

`test_transcripts_smoke.mojo`'s tripwire tests and `gen_transcripts.py`'s
self-verify are the cheapest checks with the highest chance of catching a
*plausible-but-wrong* implementation. Structural checks alone — well-formed, right
row count — cannot catch a parser that reads the wrong field, because a
scrambled-but-consistent read can satisfy every structural invariant at once.

- **The tripwire record**: pin a handful of tiny known values straight into the
  test, with the scenario named in a comment — `crashing--default.txt` terminates
  by **signal 4** and its `ABORT:` line survives normalization;
  `passing--only-unknown.txt` carries the exact stale-name error phrase. If a
  change makes the code read plausible-but-wrong bytes, the pinned values diverge
  even though every structural check still passes. Trust the tripwire over your
  reading of the code when it goes red.
- **The self-verifying generator**: `gen_transcripts.py` hard-asserts, for every
  scenario, that the emitted MANIFEST equals the scenario matrix, that no absolute
  path or symbolizer-dependent line survives normalization, that crash scenarios
  die by signal, that the anchored normalizer left the noisy impostor byte-exact,
  and that declared/rows/summary reconcile — then it regenerates the whole matrix
  a second time and proves it byte-identical. A disagreement dies loudly at
  generation time, never later as a baffling Mojo test failure. Any new
  transcript scenario or fixture gets the same shape: assert the property that
  makes the fixture trustworthy *before* freezing it.

---

## Failing-test-first, applied to the transcript format itself

For most code, "failing test first" means writing a test against code that
doesn't exist yet. Here it also applies one level up, to the transcript format:
when the format gains a field, design the Mojo-side parser test first, against a
tiny hand-written fixture — three lines you can read at a glance — confirm it
fails against the old format, *then* make the generator emit the new shape and
confirm both sides agree. `test_transcripts_smoke.mojo` is what the result looks
like: it fails the moment `gen_transcripts.py` and the Mojo parser's ideas of the
transcript format drift, because both are exercised by the same
anchor/reconcile/tripwire logic.

For a bug in the runner itself, reproduce it before fixing: add the failing
scenario as a fixture + matrix row (regenerate via `pixi run transcripts`) or,
for something too narrow to earn a transcript, a minimal literal inline in the
test (a hand-built temp dir for `discover`, a system binary for `exec`). Confirm
the Mojo output actually disagrees for the reason you claim, fix the code, watch
that specific case turn green.

---

## Exactness — there are no tolerances here

**Assertions in this repo are exact.** Exit codes are integers, signals are
integers, test counts are integers, discovery yields an exact file set — none of
it approximates anything, so `assert_equal`, never `assert_almost_equal`.

| Contract | Assert |
|---|---|
| a supervised child's exit code | `assert_equal` on the integer `code()` |
| a crash | `assert_equal` on the signal number; the outcome is CRASH, not FAIL |
| a deadline kill | assert the outcome is `TimedOut`, distinct from `Signaled` |
| the runner's own exit code (a scenario end to end) | `assert_equal`, exact |
| report counts | `assert_equal`: `declared == rows == summary == p + f + s` |
| the discovered file set | `assert_equal` on the sorted list of paths |
| captured stdout/stderr | `assert_equal`, byte for byte (streams stay separate) |
| a named error path | `assert_raises(contains="...")`, pinning the message substring |

A test that can only pass with a tolerance is a finding about the code, not a
reason to add one. **Loosening an assertion (or a transcript) to make a red test
green is an Ask-first action** (AGENTS.md) — a widened check almost always hides a
real regression, because there is no noise here to hide behind. The one place a
float legitimately appears is a timing number under `bench` — those are
**printed and recorded, never asserted, never a CI gate**.

---

## Determinism and enumeration

- A supervised run is a function of `(argv, cwd, timeout, environment)` — no seed,
  no RNG. Keep unit-test inputs literal and inline; reach for a committed fixture
  only when its provenance matters to the check.
- Discovery and scheduling are deterministic by sorted walk — a test pins the
  exact order, because deterministic order is what makes the console output and
  the end-to-end assertions reproducible.
- Where a domain is small and enumerable — every outcome multiset feeding the
  exit-code precedence, every flag × spelling × arity violation in the parser,
  every termination kind in the verdict map — **enumerate it rather than
  sampling.** A loop bound that quietly stops short of the full domain is a finding
  in review, not a style choice; sampling is how a wrong precedence table or a
  missed flag ships.
- Keep tests independent: no shared mutable state between tests, and no test
  writes under `goldens/`, `fixtures/`, or a committed known-outcome tree — those
  are frozen inputs, not scratch space. A test that needs a directory builds it in
  a temp dir and cleans up.

---

## Process

1. **Write the failing test first.** For a bug, reproduce it (Prove-It): add the
   case as a fixture/scenario or an inline literal, confirm the test fails *for
   the reason you claim*, then the fix makes it pass. A bug fix without a test that
   would have caught it is not done.
2. **Smallest input that shows the behavior.** `/bin/false` for "exit 1",
   `/bin/sh -c` is banned so use a small purpose-built binary or a system tool, a
   three-line malformed report for a parser bug — not a full suite when a one-off
   proves the same point faster.
3. **One invariant per test**, named for what it locks
   (`test_crash_is_not_counted_as_fail`, not `test_exec`).
4. **Reach for the layer's own oracle** (the transcripts for `protocol`, system
   binaries for `exec`, the known-outcome tree for `session`) instead of
   re-deriving expected output by hand — those are already the oracle,
   self-verified at generation time.
5. **Run the floor** — `pixi run fmt`, `pixi run test` (or `pixi run ci` for the
   full chain, including `transcripts-check`) — before declaring done.

---

## Checklist

- [ ] Test written *before* the code (or before the fix, for a bug)
- [ ] It fails without the change, passes with it
- [ ] Smallest input that demonstrates the behavior
- [ ] Assertions are exact (`assert_equal` on codes/signals/counts/paths) — no
      tolerance anywhere; named errors use `assert_raises(contains="...")`
- [ ] Crash asserted as CRASH (signal), not FAIL; a deadline kill asserted as a
      distinct `TimedOut`; binaries build-then-executed, never `mojo run`
- [ ] Parser tests anchor on the LAST `Running <N> tests for`, reject a printed
      report-lookalike, and reconcile declared == rows == summary
- [ ] New behavior checked against the layer's own oracle where one exists
      (transcripts / system binaries / known-outcome tree)
- [ ] A new transcript scenario or fixture gets a self-verify assertion in the
      generator, mirroring `gen_transcripts.py`'s hard asserts
- [ ] A refactor commit does not move a transcript or a tripwire's pinned value
- [ ] Test module stays small (function count, not just file size) — split and
      add to `SLOW_6554` in `scripts/test_all.sh` if it starts stalling
- [ ] `pixi run test-direct` and `pixi run test` green; the new file is in the
      correct classified suite root
