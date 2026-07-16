# Phase 2 notes — the per-test layer

Phase 1 shipped a runner that could tell you a file passed or failed but had
no idea what happened inside it. This phase closes that gap: mtest now parses
TestSuite's own report out of the captured bytes, classifies every test
inside a file, and builds selection (`-k`, node ids), `--maxfail`, a
`collect` subcommand, and per-test failure storytelling on top of that
classification. It also turns the tool on itself — `pixi run test` now runs
mtest's own suite through the built binary, not just the glob-driven script
runner. The work was built bottom-up again: model → protocol parser → cache
registry → per-test classification → selection → maxfail → collect → report
storytelling and durations → grammar → end-to-end → self-hosting → docs.

## The reconciliation, before any code

Before writing the parser, the phase started by re-checking what Phase 1
actually shipped rather than trusting memory of the design. A few facts
mattered enough to pin down explicitly:

- `duration_seconds` on `FileFinished` is **run-only** — spawn to reap, not
  build plus run — and it is `0.0` for outcomes that never reached the run
  step. This was confirmed against the Phase-1 code before the slowest-files
  list was built on top of it, because a list that silently mixed build time
  into a "slowest" ranking would be lying about what's actually slow.
- The capture bound is 8 MiB per stream, head and tail preserved with a loud
  truncation marker in between — also inherited from Phase 1. What Phase 1
  didn't have was a cheap way to *ask* whether a stream had overflowed. This
  phase adds `stdout_truncated` / `stderr_truncated` to the exec result, so
  the capture-overflow classifier doesn't have to rescan bytes looking for
  the marker itself.
- The build-artifact name mangling (`_` → `_u`, `/` → `_s`) is injective —
  the fix that closed a real collision in Phase 1. The new build/probe
  registry keys directly on the mangled name, so its correctness now depends
  on that injectivity holding, not just on it being convenient.

None of this is glamorous, but a phase that adds a parser and a cache on top
of a supervision layer without re-checking the layer's actual guarantees is
asking to build on a premise nobody re-verified.

## The R5 native-skip findings

Three facts about TestSuite's native skip API, pinned by new protocol snapshot
transcripts (`skipped--skip-all.txt`, `skipped--only-native.txt`) rather than
assumed:

1. A natively-skipped test is **listed** under `--skip-all` — it shows up as
   a normal `SKIP` row in the collection probe, same as any other test.
2. A natively-skipped test that is explicitly **selected** by name under
   `--only` still reports `SKIP`. Selecting it does not force it to run.
3. And the one that actually matters: `--only <native-skip-test>` output is
   **byte-identical** to `--skip-all` output. Diffing the two snapshot
   transcripts shows the only difference is the `cmd:` line in the header —
   every report byte after it matches, down to `SKIP [ T ] test_runs_normally`
   showing up in *both* transcripts even though the `--only` run never named
   it.

That third fact is the one the whole suppression design rests on. It means
mtest cannot tell a genuinely-reported native SKIP apart from a
selection-induced SKIP by looking at the report alone — the bytes are the
same either way. The only information that distinguishes them lives outside
the report: which names mtest itself selected. So the rule is a
reconciliation, not a parse: a SKIP on a name mtest selected is native (report
it as SKIP); a SKIP on a name mtest did *not* select is a deselection
(suppress the row, count it DESELECTED instead). Everything the selection
pipeline does with `--only` output — the whole-then-`-k`-intersect logic, the
suppression step — exists because of this one byte-identical pair.

## The parser doctrine

`parse_report` is a pure classifier over one child's decoded stdout — no I/O,
no FFI, never raises. A few decisions carry the weight of the whole
corruption-resistance story:

- **Anchor on the LAST matching header, not the first.** A test's own
  `print` output streams to stdout *before* TestSuite's buffered report is
  flushed, so an earlier line that happens to look like `Running N tests for
  <path>` is very likely something a test printed, not the real header. This
  was actually a regression caught during review of the corruption suite: an
  earlier draft anchored on the first match, and a synthetic case (a fixture
  printing a header-lookalike before its real report) exposed it. The fix —
  anchor on the last matching header before the terminal framing — is now
  pinned by a dedicated regression test.
- **Terminal framing is found from the end.** The parser scans backward for
  the last `Summary` line and the `--------` rule before it, then anchors the
  header search on that. Scanning forward would be vulnerable to the same
  lookalike problem in the other direction.
- **Path identity is exact byte-equality**, never a suffix match. A
  symlinked path that resolves to the real source parses correctly; a file
  that merely shares a path *suffix* with the real one — an impostor sitting
  at a different root — reads as `ABSENT`, not as a false match.
- **Triple count reconciliation.** Declared row count, actual row count, and
  the summary line's own tallies all have to agree — and the row-level
  pass/fail/skip tally has to agree with the summary's pass/fail/skip tally
  too. This is what stands between a hand-forged report and a false PASS: a
  forger can print plausible-looking rows, but making every one of those
  counts agree simultaneously is a much taller order.
- **Multiple complete report blocks are AMBIGUOUS, never "last wins."** A
  suite that runs `TestSuite.discover_tests(...).run()` twice back-to-back
  produces two well-formed blocks for the same path. Taking the last one
  would silently launder a forged extra block into a normal-looking verdict;
  refusing to pick a winner is the only safe answer.
- **Capture-overflow detection re-parses only the text after the LAST
  truncation marker.** A report survives a flooded capture only if it landed
  wholly inside the retained tail. If the tail is truncated mid-report, or
  the report never made it into the tail at all, there is nothing to trust.

## The hostile fixtures, run one at a time

`e2e/hostile/` and `e2e/chameleon/` exist to make the doctrine
above concrete. Each one is a known-outcome fixture with a docstring
predicting exactly what should happen, and each was run to confirm the
prediction rather than just trusted from the source:

- **`test_silent`** — compiles, runs, exits 0, prints nothing. No report
  block anywhere, so the parser reads it as `ABSENT`. Verdict:
  **MALFORMED-SUITE**. This is the whole point of closing the zero-test
  ceiling from Phase 1: a clean exit with silence is no longer read as PASS.
- **`test_liar`** — runs a real one-test suite, then hand-prints a second
  trailing `Summary` line with no rule above it. The end-anchored scan takes
  that fake line as terminal, and the grammar underneath it doesn't hold up.
  Verdict: **DRIFT, exit 3** — the sanctioned, user-authored path to the
  internal-error tier. This is deliberate: a file that's actively lying about
  its own report shouldn't be scored as a test failure, but it also
  shouldn't be silently ignored.
- **`test_forger`** — runs the same one-test suite *twice*, so it emits two
  complete, well-formed report blocks for its own path back to back. Neither
  block is individually broken, so this can't be OFF_GRAMMAR; it's
  **AMBIGUOUS**, which routes to **MALFORMED-SUITE**.
- **`test_overflow`** — floods stdout with roughly 13 MiB, well past the 8
  MiB per-stream bound, and exits 0 with no report anywhere in what survives.
  The truncation marker fires, the tail gets re-parsed, and there's nothing
  usable in it. Verdict: **capture-overflow FAIL** — not a PASS, and not a
  drift, because a flooded stream that happens to also contain garbage isn't
  the same failure mode as a file that deliberately breaks the grammar.
- **`test_chameleon`** — lists `test_real` and `test_ghost` under
  `--skip-all`, then refuses `test_ghost` under `--only` (the stdlib raises
  `test not found in suite`). This is the one case where a suite can legally
  contradict its own collection listing. mtest's answer is a loud recollect
  and one retry; if the retry hits the same refusal, the verdict is
  **MALFORMED-SUITE** — deliberately in the **exit-1 class, not exit 3**,
  because this is a suite behaving badly, not an internal or drift condition.
- **`test_zero`** — a valid, honestly-reported zero-test suite (a real report
  block, zero rows, summary says zero). This is the one case in the hostile
  set that's allowed to be boring: verdict **NO-TESTS**. The zero-test
  ceiling from Phase 1 is now closed on both sides — silence is
  MALFORMED-SUITE, an honest empty report is NO-TESTS, and a lone all-zero
  session exits 5.

## The single-build proof

One thing the cache registry claims and needs to actually demonstrate: the
selection probe and the run share a single build per file, rather than
building twice. `scripts/logging_mojo.py` is a stdlib-only wrapper that logs
every `mojo` invocation's subcommand and target before exec-ing the real
`mojo` with an identical argv, so stdout, stderr, and the exit code are
untouched. Run one selection invocation through it —
`mtest --mojo <wrapper> -k one e2e/matrix`, which matches
`test_alpha_one` in one file and `test_beta_one` in another — and the
wrapper's log shows exactly one `mojo build` per file, not two. The probe
phase (learn each file's node ids under `--skip-all`) and the run phase
(execute the selected subset) go through the same `BuildRegistry` entry.

The chameleon fixture is the useful counterexample: its stale-name recovery
path *should* rebuild, and the same logging wrapper over that scenario shows
exactly two `mojo build` entries — the initial build, plus the one
recollect-and-retry rebuild. One file, one legitimate reason to build twice,
confirmed the same way.

## Self-hosting, before and after

Before this phase, `pixi run test` meant "glob for `test_*.mojo` under
`tests/`, build and run each with a Python script." That script is still
around — renamed to `test-direct` — and it still gates CI. What's new is
`test` itself: it now builds `build/mtest` and runs
`build/mtest -I build tests/` — the actual binary, executing its own test
suite, never `mojo run` — and then `scripts/self_host_check.py` propagates
that exit code *and* independently globs `tests/test_*.mojo` on disk, with
nothing but the Python stdlib, to check that the file count agrees with what
mtest itself reported selecting.

Run for real:

```console
$ pixi run bash -c 'build/mtest --durations 5 -q -I build tests/'
===== 510 passed, 0 failed, 0 skipped (0 excluded, 0 not run) in 122.1s =====
```

55 test files, 510 tests, all passing through both runners — the
mtest-independent `test-direct` twin and the dogfooded `test` run. mtest's
own reported file count (55) matches the independent glob (55) exactly.
There's no discrepancy to explain here, which is itself the finding: a
discovery bug that silently dropped a file would show up as a mismatch
between "selected + excluded" and the glob count, and it didn't.

## The README examples, executed for real

Every selection, collect, and durations example in the README was run
against the built binary and pasted from the actual output, not written from
memory of what the output should look like — the same discipline Phase 0 and
Phase 1 held. The mixed-directory example from Phase 1's notes also had to be
re-executed, since NO-TESTS now closes the zero-test ceiling and the summary
band now mixes per-test and per-file counts in a way the old transcript
didn't show.

## Review triage this phase

Every commit went through a spec review and a quality review, and the
findings that mattered got fixed as they came up rather than logged for
later:

- **The parser anchor regression**, described above — anchoring on the first
  matching header instead of the last was caught while building the
  corruption suite, before it ever shipped, and is now pinned by a dedicated
  test.
- **The `collect` precompile exit-code fix** — `run_collect`'s precompile
  step wasn't wrapped the same way `run_session`'s was, so a raise from
  `_run_precompile`'s own machinery propagated to `main`'s generic exit-4
  usage-error handler instead of resolving the correct exit 3. Wrapping it in
  the matching try/except closed the gap.
- **The storytelling verbatim-detail anchoring fix** — the per-test failure
  section needed to render TestSuite's assertion detail *verbatim*, with
  exactly two transforms (stripping TestSuite's own indentation, and
  rewriting `At <abs>:line:col` root-relative) and no more. An earlier draft
  did more than that, which meant the rendered detail was no longer a
  faithful copy of what TestSuite actually said.
- **The contract v1-vs-vNext consistency fix** — the CLI contract's reserved
  section had wording that didn't consistently distinguish "part of the
  frozen v1 contract but not yet served" from "out of scope for v1, reserved
  for a later major version." Both `--json` and the `--shard`/`--serial`
  reservations needed the correct one of those two framings, not a blurred
  version of both.

### External review triage

The standing per-phase gate is a dual adversarial external review — an Opus
4.8 pass and a Codex pass, both briefed to attack the work. Both passes for
this phase, and their triage, will be appended here once the standing gate
runs.
