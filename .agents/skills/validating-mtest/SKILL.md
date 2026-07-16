---
name: validating-mtest
description: Use when QA-testing or acceptance-testing the mtest runner, validating it against docs/cli-contract.md, verifying exit codes / outcome labels / determinism / the availability matrix, checking a change or a Mojo re-pin did not break a user-facing promise, or hunting for silent or contract-violating behavior before a release.
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
FROZEN surfaces: exit codes (§9), the `collect` listing (§16), stream routing
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

## When to use

- Acceptance/QA pass over the CLI from a user's perspective.
- Before a release, or after re-pinning Mojo (`transcripts` change → re-validate).
- After any change to `cli`, `discover`, `select`, `session`, `protocol`, or
  `report` — confirm no user-facing promise regressed.

Not for: internal unit correctness (`pixi run test-direct`) or protocol-snapshot
drift (`pixi run transcripts-check`).

## Quick start — run the oracle

```bash
python scripts/validate_contract.py            # rebuild-if-stale, run all ~55 checks
python scripts/validate_contract.py -k select  # filter by check name
python scripts/validate_contract.py --strict   # a SKIP of a safety-critical check FAILS
python scripts/validate_contract.py -v --keep   # dump streams on failure, keep scaffold
```

`scripts/validate_contract.py` (Python lives under `scripts/`, per AGENTS.md)
scaffolds a throwaway user project — a library, clean all-pass suites with a
**known exact node-id set**, and **poison** files — outside the repo, then drives
`build/mtest` across the contract matrix, printing PASS/FAIL per check tagged
with its contract §. It **rebuilds `build/mtest` when stale** (a stale binary
validates old code — a real false-green risk), **exits 2 on setup failure**
(distinct from a contract failure's 1), and treats a zero-check run or a
`--strict` skip as non-passing. Extend it by adding a `Check(...)` to
`build_matrix()` (or a bespoke method for multi-run checks) — one behavior, cite
the §, prefer an exact/poison assertion over a substring.

This is the mechanical floor. The judgment below finds what the matrix does not
yet encode.

## The frozen spine — exit codes (§9)

Every check ultimately asserts an exit code. Know the table cold; a wrong code is
always a bug:

| Code | Meaning |
|------|---------|
| 0 | every selected outcome PASS or SKIP (exclusions allowed) |
| 1 | any FAIL / CRASH / TIMEOUT / COMPILE-ERROR / **COMPILE-TIMEOUT** / MALFORMED-SUITE / PRECOMPILE-ERROR |
| 2 | interrupted (SIGINT/SIGTERM) — partial summary printed |
| 3 | internal mtest error, incl. protocol drift and spawn failure |
| 4 | usage error — detected **before any test runs** |
| 5 | nothing collected (empty walk, `-k` matched nothing, all excluded, only NO-TESTS) |

Precedence when outcomes mix: 4 → 2 → 3 → 1 → 5 → 0. (COMPILE-TIMEOUT and FLAKY
are in the frozen vocabulary but not emitted by this build yet — §24.2.)

## Running mtest correctly (harness traps that produce false findings)

A false finding wastes everyone's time. Most come from the harness, not mtest:

- **Toolchain on PATH.** mtest spawns `mojo build` per file. Run under the pixi
  environment; the validator captures it and scrubs a stray `MTEST_MOJO` so the
  scaffold and the runner do not build with different toolchains.
- **Root = current working directory (§2).** An operand outside the root is a
  correct exit-4 error. To test a scaffolded project, run mtest *from inside* it
  — do not pass an absolute path into it from elsewhere and call the exit-4 a bug.
- **Capture exit codes directly.** `mtest ...; echo $?` — never `mtest ... | tail; echo $?`
  (`$?` is the pipe's last command). This bit the original QA pass twice.
- **Separate the streams.** §19 routes help/version to **stdout**, usage errors
  to **stderr**; §16 routes `collect` node ids to **stdout**, diagnostics to
  **stderr**. Merging them (`2>&1`) makes routing regressions invisible — assert
  per stream.
- **Session suites need the native object.** A bare
  `build/mtest tests/integration/test_session_*.mojo` link-fails on
  `mtest_exec_*` symbols — a missing `-Xlinker build/native/...`, a harness
  artifact, **not** a COMPILE-ERROR bug. `scripts/test_all.sh` links it.

**Reproduce before you report.** Re-run a suspected finding cleanly (fresh CWD,
direct exit capture, correct build) before writing it up. The original pass
produced a false positive (`--color always` vs `NO_COLOR`) from a bad
invocation; a second clean run retracted it. **Rebuild first** — an all-green run
against a stale binary proves nothing.

## Validation matrix (what the oracle asserts)

Every row below is a check in `validate_contract.py` unless marked *(manual)*.

| Area | Assertion (frozen-surface / poison) | §|
|------|--------|--|
| version | prints the exact version string | 19 |
| outcomes | PASS/FAIL/CRASH/COMPILE-ERROR/MALFORMED/TIMEOUT — right code; **CRASH ≠ FAIL**; NO-TESTS-only → 5 | 9,10 |
| discovery | nonexistent → 4 (stderr); empty → 5; explicit non-`test_` file runs; escape-root → 4 (stderr) | 2,5 |
| collect set | **exact** node-id set for `tests/`, sorted; byte-identical across runs | 5,16,17 |
| selection | node id runs exactly one, **poison sibling never runs**; `-k` exact count + case-insensitive; empties → 5; unknown test → 4; **dir node-id → 4** | 5,10.1 |
| exclusion | pattern **truly removes** a would-crash file (exit stays 0); stale warns; exclude-all → 5 | 12 |
| early stop | `-x` / `--maxfail` leave the **poison sibling NOT-RUN** (exact not-run count); failing `--gate` aborts (exact not-run) | 11 |
| collect flags | run-only flags (`--durations`/`--maxfail`) → 4; streams split + listing continues; §24.3 deviations (`-k` ignored w/ notice; node-id lists whole file) | 4,16,24.3 |
| build args | `-o`/`--emit`/extra-source → 4 **and the test never ran** (pre-run detection) | 8.4,9 |
| exit 3 | bad `--mojo` (spawn fail) → 3; **off-grammar report (drift) → 3**, never a verdict | 6,16,24.2 |
| refused v1 flags | **all 9 spellings** → 4, each naming the flag + "v1 contract" | 24.1 |
| value validation | bad `--durations`/`--timeout`/`--color`/`--show-output` → 4; `-q -v` → 4 | 3,15.1 |
| precompile | success auto-adds `-I` (import resolves, PASS); failure → `PRECOMPILE-ERROR` + casualty files listed | 8.3,10 |
| interrupt | SIGINT to **mtest only** → exit 2, partial summary, **child tree freed** (tests mtest's own teardown, not a direct signal) | 9,24.2 |
| color | `--color never`→no ANSI, `always`→ANSI, and the flag **wins over `NO_COLOR`** | 15.1 |

Still worth a *manual* probe beyond the oracle: `--collect-only` alias
equivalence; exclusion winning over `--gate`/explicit operand (§12); valid
`--build-arg` actually forwarding; and the deepest honesty case — a **new**
protocol drift after a Mojo re-pin must route to exit 3, never launder into a
verdict (the `drift/` scaffold shows the shape; `e2e/hostile` and
`e2e/chameleon` have more).

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
- The oracle is all-green but you did not rebuild — a stale binary validates the
  old code.
- A safety-critical check SKIPped and the suite still exited 0 — run `--strict`.

## Complementary gates (do not reinvent)

`pixi run e2e` (known-outcome fixture tree), `pixi run test-direct` (Mojo unit +
integration), `pixi run transcripts-check` (protocol pin). This skill is the
black-box, user-perspective layer **on top** of those; if it and `e2e` ever
disagree about a promise, that disagreement is itself a finding.
