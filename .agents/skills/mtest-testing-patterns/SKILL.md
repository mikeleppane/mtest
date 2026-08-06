---
name: mtest-testing-patterns
description: The mtest repo's testing reference — which oracle each layer tests against, the four repo test patterns (golden transcripts, hostile-output parser tests, known-outcome trees, tripwires and self-verifying generators), and the integer-exact assertion policy. Use on every observable mtest behavior change — a supervision step, a report parser, an exit-code verdict, a discovery walk, a bug fix — alongside the general TDD process skill, to choose the repo-specific oracle and test shape. Defers to the general test-driven-development process skills for red-green mechanics, to mojo-coding-guidance for how the code under test is written, and to AGENTS.md for the classified-module and transcript rules.
---

# mtest Testing Patterns

Write the failing test before the code; for a bug, reproduce it with a test —
or a protocol snapshot — *before* fixing it. The general TDD skills own that
process; this skill is the repo-specific half: which oracle proves what, the
four named patterns, and the exactness policy. This is a test runner, not a
numerics project: a supervised process exits with an exact integer code or
dies by an exact signal; a report declares an exact count; a walk finds an
exact file set. Every quiet bug here is an off-by-one or a misattribution — a
crash counted as a failure, a report-lookalike line counted as a result, an
exit code masked to 1 — and every test locks one such invariant exactly, not a
coverage number.

Project rules live in [AGENTS.md](../../../AGENTS.md) and override this skill.
In particular, its "Classified test modules" section owns the `main()`
packaging constraint, the derived-membership trade, and the
**harness-consumer audit** every executable-topology change must run; its
"Transcript lifecycle" section owns when regeneration is legitimate.

## The test file shape

Classified modules under `tests/unit/` and `tests/integration/` are ordinary
`def ... raises` functions plus their own `main()` (a packaging constraint —
AGENTS.md has the why), run against the **precompiled package**:

```mojo
from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from mtest.exec import run_supervised


def test_false_binary_exits_nonzero() raises:
    var r = run_supervised(ProcessSpec(argv=["/bin/false"]))
    assert_true(r.termination.is_exited())
    assert_equal(r.termination.code(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

One file per unit under test, `tests/unit/test_<thing>.mojo` or
`tests/integration/test_<thing>.mojo` according to the boundary it crosses.
Run the whole suite with `pixi run test` (self-hosted through `build/mtest`
itself — the repo eats the discipline the product sells, never `mojo run`), or
focus with `pixi run test-file -- <path>`. Keep modules cohesive and split by
SUBJECT when failures stop sharing an investigation boundary —
`.agents/lessons.md` ("Harness and workflow") records the module-size/deadline
trade.

## The test pyramid, by layer

| Layer | Tests against | Fixture/oracle |
|---|---|---|
| `model` — outcomes, events, exit-code precedence | the precedence function over every outcome multiset | pure logic — enumerate the domain |
| `config` — RunnerConfig | defaults, flag → field mapping | pure logic |
| `discover` — walk, pattern, excludes | a temp tree of `test_*.mojo` + decoys | a hand-built directory |
| `protocol` — report/collect parsing | committed protocol snapshots | `tests/snapshots/protocol/` |
| `report` — reporters | rendered output for a fixed event stream | structural assertions |
| `exec` — the POSIX process adapter | supervision of real system binaries | `/bin/echo`, `/bin/false`, `/bin/sleep` |
| `session` — orchestration | verdict + exit code end to end | the known-outcome tree (below) |
| `cli` — argument parsing | every flag × spelling × arity × domain | the flag-spec table itself |

Each layer reaches for *its own* oracle first: `protocol` tests parse the
frozen transcripts; `exec` tests supervise system binaries (hermetic, fast, no
nested `mojo build` inside a unit test); `session` tests assert verdicts
against a committed tree of known-outcome fixtures. **Spawning a shell as a
target fixture is banned** everywhere, exactly as in the product — supervise a
real binary, not `/bin/sh -c`.

## Four patterns worth naming

### Golden-transcript tests — freeze the toolchain's protocol, byte for byte

The transcripts under `tests/snapshots/protocol/` are committed probes run at
the pinned Mojo toolchain, their normalized output frozen and diffed
byte-for-byte by `pixi run transcripts-check`. **The toolchain IS the oracle**
— a transcript pins exactly what `std.testing.TestSuite` emits at the pinned
version, which is what lets the report parser be written against frozen bytes
instead of a remembered format. A red `transcripts-check` after a repo change
indicts the change; regeneration rules are AGENTS.md's transcript lifecycle. A
"no behavior change" refactor commit that moves a transcript byte is lying.

### Hostile-output parser tests — a parser that reads garbage must fail

Structural well-formedness is not enough: a parser can "succeed" while reading
the wrong field. The parser tests use the transcripts as fixtures **and**
deliberately corrupt them:

- **Anchor discipline.** The `noisy` fixture prints a report-lookalike line
  (`    PASS [ 0.001 ] fake_impostor`) *before* the real report. A test pins
  that the impostor sits before the last `Running <N> tests for` anchor and
  must never be counted — first-match scanning would double-count.
- **Count reconciliation.** For every report-carrying transcript, assert
  `declared == rows == summary_total == passed + failed + skipped`, tally by
  tally. A scrambled-but-consistent read satisfies structural checks and fails
  reconciliation.
- **Corruption cases.** A truncated report, a declared count disagreeing with
  the rows, a missing `Summary` line — each a hand-written three-line fixture
  the parser must reject with a named MALFORMED-SUITE error, tested with
  `assert_raises(contains=...)`.

### Known-outcome trees — assert verdicts against declared expectations

`session`'s oracle is a committed tree of probe files with *declared*
outcomes: a passing file, a mixed file, a crashing file (`abort("…")` — the
message is required), a zero-test file, a noisy file, a compile-error file, a
`helper.mojo` that must NOT be discovered, a nested directory proving
recursion, an excluded directory. A `MANIFEST` maps file → expected verdict →
expected exit-code contribution, with a rationale line each. A Python
end-to-end harness under `scripts/` builds the runner once and asserts, per
scenario, the **exact exit code** and the structural shape of the output.

### The tripwire and the self-verifying generator

The cheapest checks with the highest chance of catching a
*plausible-but-wrong* implementation, because structural checks alone cannot
catch a parser that reads the wrong field:

- **The tripwire record**: pin a handful of tiny known values straight into
  the test, scenario named in a comment — `crashing--default.txt` dies by
  **signal 4** and its `ABORT:` line survives normalization. If a change makes
  the code read plausible-but-wrong bytes, the pinned values diverge while
  every structural check still passes. Trust the tripwire over your reading of
  the code when it goes red.
- **The self-verifying generator**: `gen_transcripts.py` hard-asserts, for
  every scenario, MANIFEST-equals-matrix, no absolute path survives
  normalization, crash scenarios die by signal, the noisy impostor stays
  byte-exact, declared/rows/summary reconcile — then regenerates the whole
  matrix a second time and proves it byte-identical. A disagreement dies
  loudly at generation time, never later as a baffling Mojo failure. Any new
  scenario or fixture gets the same shape: assert the property that makes the
  fixture trustworthy *before* freezing it.

Failing-test-first applies to the transcript format itself: when the format
gains a field, design the Mojo-side parser test first against a tiny
hand-written fixture, confirm it fails against the old format, *then* make the
generator emit the new shape and confirm both sides agree
(`test_transcripts_smoke.mojo` is what the result looks like — it fails the
moment the generator's and the parser's ideas of the format drift).

## Exactness — there are no tolerances here

**Assertions in this repo are exact**: `assert_equal`, never
`assert_almost_equal`.

| Contract | Assert |
|---|---|
| a supervised child's exit code | `assert_equal` on the integer `code()` |
| a crash | `assert_equal` on the signal number; the outcome is CRASH, not FAIL |
| a deadline kill | the outcome is `TimedOut`, distinct from `Signaled` |
| the runner's own exit code | `assert_equal`, exact |
| report counts | `declared == rows == summary == p + f + s` |
| the discovered file set | `assert_equal` on the sorted list of paths |
| captured stdout/stderr | `assert_equal`, byte for byte, streams separate |
| a named error path | `assert_raises(contains="...")` |

A test that can only pass with a tolerance is a finding about the code, not a
reason to add one. **Loosening an assertion (or a transcript) to make a red
test green is an Ask-first action** (AGENTS.md) — there is no noise here for a
regression to hide behind. The one place a float appears is a timing number
under `bench` — printed and recorded, never asserted, never a gate.

## Determinism and enumeration

- A supervised run is a function of `(argv, cwd, timeout, environment)` — no
  seed, no RNG. Keep unit-test inputs literal and inline; reach for a
  committed fixture only when its provenance matters to the check.
- Discovery and scheduling are deterministic by sorted walk — a test pins the
  exact order.
- Where a domain is small and enumerable — every outcome multiset feeding the
  exit-code precedence, every flag × spelling × arity violation, every
  termination kind in the verdict map — **enumerate it rather than sampling.**
  Sampling is how a wrong precedence table or a missed flag ships.
- Keep tests independent: no shared mutable state, and no test writes under
  `tests/snapshots/`, `tests/fixtures/`, or a known-outcome tree — frozen
  inputs, not scratch space. A test that needs a directory builds it in a temp
  dir and cleans up.

## Checklist

- [ ] Test written *before* the code (or before the fix); it fails without the
      change for the reason you claim, passes with it
- [ ] Smallest input that shows the behavior (`/bin/false` for "exit 1", a
      three-line malformed report for a parser bug)
- [ ] One invariant per test, named for what it locks
      (`test_crash_is_not_counted_as_fail`, not `test_exec`)
- [ ] The layer's own oracle used where one exists (transcripts / system
      binaries / known-outcome tree) instead of re-deriving expected output
- [ ] Assertions exact; crash asserted as CRASH (signal), a deadline kill as a
      distinct `TimedOut`; binaries build-then-executed, never `mojo run`
- [ ] Parser tests anchor on the LAST `Running <N> tests for`, reject a
      printed report-lookalike, reconcile declared == rows == summary
- [ ] A new transcript scenario or fixture gets a self-verify assertion in the
      generator
- [ ] A refactor commit does not move a transcript or a tripwire's pinned
      value
- [ ] An executable-topology change runs AGENTS.md's harness-consumer audit
      (`test`, `test-file`, ASan, Valgrind, dogfood, self-host, package
      consumption)
- [ ] Focused verification per AGENTS.md's local loop; the new file sits in
      the correct classified suite root
