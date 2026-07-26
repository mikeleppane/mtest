# Test confidence map

What a green release actually proves, and how each claim is checkable. Every
row names a *blocking* oracle — a `pixi` task whose failure stops the release —
and, where one exists, the mutation that proves that oracle detects the defect
it is there for. Where the evidence is thinner than the ambition, the row says
so instead of rounding up.

This document does **not** cover the memory-safety axis. Unsafe and
native-backed ownership boundaries, their ASan/Valgrind evidence, and their
honestly-recorded gaps (macOS has no sanitizer lane; three platform files rest
on the CLI probe alone; neither memory lane is in `pixi run ci`) live in
[`notes/test-memory-risk-map.md`](test-memory-risk-map.md) and are not restated
here.

> **Measured 2026-07-26 at commit `c28d691`. Nothing re-runs the measurements.**
>
> The gate membership in §2 is enforced continuously —
> `scripts/checks/ci_topology.py` compares `pixi.toml` and
> `.github/workflows/ci.yml` against pinned constants on every `harness-check`,
> so a task leaving the floor is a red gate, not a stale note. The §3 per-layer
> numbers are different: they came from a one-off static pass whose recipe is
> printed below, and nothing recomputes them. Re-run the recipe before trusting
> a number in §3 to make a decision, and move the stamp above when you do.

## 1. There is no source coverage number, and that is a gate

Mojo 1.0.0b2 ships no coverage or profile instrumentation. The recorded probe:

```text
pixi run mojo build --help | rg -i 'cover|profile|instrument'
pixi run mojo --help | rg -i 'cover|profile|instrument'
```

Both searches produce **no output and exit 1** (ripgrep's "no match") against
`Mojo 1.0.0b2 (2cf4d08a)`. There is no `--coverage`, no
`--profile-instr-generate`, no `--fprofile-*`, and no coverage subcommand. No
line or branch percentage for `src/` exists anywhere in this repository, and
none is quoted in this document, because there is nothing to measure it with.

`pixi run coverage-capability` (`scripts/checks/coverage_capability.py`) keeps
that statement honest. It is deliberately **asymmetric**: the absence is the
quiet outcome and the *discovery* is the failure, so a toolchain upgrade cannot
silently start publishing a number nobody reviewed.

| Outcome | Behavior |
| --- | --- |
| Neither help text names a coverage flag or mentions one in prose | prints `Mojo source coverage unavailable at 1.0.0b2; behavioral map applies`, exits 0 |
| A coverage-shaped flag is found | echoes each flag with the command that produced it, plus an instruction to gate it, exits nonzero |
| A coverage word appears without a flag (a subcommand, say) | echoes the matching lines, exits nonzero |
| `pixi.toml` no longer pins `==1.0.0b2`, or the probe cannot run | says which, exits nonzero |

The last row matters: the pinned message names a version, so it must not be
printed for a toolchain nobody probed. Moving the `mojo` pin without re-running
the probe and updating both this note and `PINNED_MOJO_VERSION` fails the task.

The task itself is a **diagnostic** — it shells out to the real compiler, so it
is not in the `ci` floor. `check_ci_task_graph` fails if its command drifts,
and the pinned `ci` membership and transitive closure reject adding it to the
floor. Its decision logic *is* blocking:
`scripts.tests.test_coverage_capability` runs inside `harness-check`, injects
representative help text for both branches, and separately pins that `main`
really executes both recorded probe commands rather than merely owning the
branch logic.

## 2. The blocking oracles

Verified from `pixi.toml` and `.github/workflows/ci.yml` — and kept verified,
because `scripts/checks/ci_topology.py` pins the exact task commands, the
`ci-preflight`/`ci` membership and order, both transitive closures, and both
hosted matrices.

`pixi run ci` = `ci-preflight` → `test` → `dogfood-check` → `e2e` →
`contract-check-strict`.

| Gate | What its failure means | Hosted lane | Platforms |
| --- | --- | --- | --- |
| `test` | Any of the classified Mojo suites regressed. One generated entrypoint per test function, one build, executed directly — never `mojo run`, which masks crash exit codes. | matrix row `direct tests` | linux-64, osx-arm64 |
| `e2e` | The real `build/mtest` binary changed its exit code or console structure against the committed known-outcome tree under `e2e/`. | matrix row `end-to-end tests` | linux-64, osx-arm64 |
| `contract-check-strict` | A documented behavior in `docs/cli-contract.md` stopped holding, or could not be checked (`--strict` turns a SKIP into a failure) against the binary this same Pixi invocation's `build-bin` produced. | matrix row `strict contract` | linux-64, osx-arm64 |
| `dogfood-check` | mtest run through mtest changed its discover/build/run/parse/report path. | matrix row `self-hosted tests` | linux-64, osx-arm64 |
| `harness-check` | The build/test tooling's own oracles regressed — including the inventory, topology, e2e-registry, packaging, and coverage-capability checkers. | inside `ci-preflight` | linux-64 |
| `native-check` | The private C exec adapter's ABI, layout, or symbol set moved, or the test-only fault controls leaked into the production object. | `ci-preflight` (Linux); a standalone step in `macos-preflight` | linux-64, osx-arm64 |
| `transcripts-check` | The pinned `TestSuite` protocol snapshots no longer regenerate byte-identically. | inside `ci-preflight` | linux-64 |
| `safety-check`, `postfork-check` | An unsafe operation lost its `# SAFETY:` documentation, or the post-fork child region gained a forbidden call. | inside `ci-preflight` | linux-64 |
| `junit-check`, `junit-render-check`, `readme-help-check`, `fmt-check`, `version-check` | The JUnit oracle, the rendered JUnit document, README's committed CLI help fence, formatting, or the version triple drifted. | inside `ci-preflight` | linux-64 |
| `package-check` | The built conda package does not install into a clean environment and run there. Independent job, not in `ci`. | `Linux / packaged artifact`, `macOS arm64 / packaged artifact` | linux-64, osx-arm64 |
| `asan-check`, `valgrind-check` | See the memory risk map. **Not in `ci`** — separate hosted matrix cells. | matrix rows `ASan + LSan`, `Valgrind Memcheck` | linux-64 only |

Two consequences worth stating plainly:

- **The local `pixi run ci` floor contains no memory-safety evidence.** Running
  it green says nothing about ASan or Valgrind.
- **macOS runs a narrower preflight than Linux.** `macos-preflight` runs
  `native-check`, `build-bin`, and `./build/mtest --help`; the rest of
  `ci-preflight` (formatting, transcripts, safety inventory, JUnit oracles,
  README help) is Linux-only. Those are host-independent checks by
  construction, but the *check* only runs on one host.

## 3. Product layers

Layering (from `AGENTS.md`, enforced by `scripts/checks/layout.py`):
`model`/`platform` → `config` → `discover`/`protocol`/`report`/`select`/`cache`
→ `exec` → `session` → `cli`, with `main` above all of them as the composition
root.

**What the "direct-call modules" column means, exactly.** It is the number of
classified test modules (of 98, holding 1287 test functions, all of which the
`test` aggregate binary executes) that contain a *syntactic* call to or
construction of a symbol imported from that layer, reachable from a
`def test_*` body — directly, or through a helper defined in the same file.

It is **not** a claim that the layer's contract is asserted there. A report
suite constructing a `TestResult` counts toward `model`. Read the column as
"this many suites touch this layer's API", nothing stronger. It is also a
**lower bound**: a call made through a `tests/support/*` helper is invisible to
it. `bytes_to_str` in `tests/support/exec_helpers.mojo` routes every capture
assertion through `config/lossy_utf8.mojo`, so the memory map credits suites
for that file which this column does not.

| Layer | Direct-call modules | Blocking oracles | Notes and residual risk |
| --- | --- | --- | --- |
| `model` | 40 | `test` | The widest surface, because outcomes/events/exit codes are the vocabulary every other layer speaks. |
| `platform` | 1 | `test`, plus `e2e` and `contract-check-strict` through the binary | `tests/unit/test_platform_temp_file.mojo` is the **only** classified suite that calls this layer directly. Everything else reaches it through `main`/`cli`. The memory map's gap 2 is the same thinness seen from the ASan/Valgrind side. |
| `config` | 26 | `test`, `e2e` (`config-*` scenarios), `contract-check-strict` | Includes the vendored TOML parser's callers. `lossy_utf8` is a `config` symbol; `mtest.config` re-exports it, so importing `mtest.config` is not evidence of decoding anything. |
| `discover` | 4 | `test`, `e2e` | Thin, but the layer is small and `e2e` walks real trees. |
| `protocol` | 5 | `test`, `transcripts-check`, `e2e` | `transcripts-check` is the stronger oracle: it regenerates every committed snapshot at the pinned toolchain and diffs byte-for-byte. |
| `report` | 29 | `test`, `junit-check`, `junit-render-check`, `e2e` (reporter scenarios) | The only layer with a schema oracle: `junit-render-check` validates mtest's own emitted document against the vendored `junit-10.xsd`. |
| `select` | 3 | `test`, `e2e` (`selection-*`), `contract-check-strict` | Three suites for the whole selection grammar; `e2e` carries most of the realistic load. |
| `cache` | 1 | `test`, `e2e` (`single-build`, `stale-recovery-two-builds`) | `tests/unit/test_cache_registry.mojo` is the only direct caller. Build-reuse behavior is really pinned end-to-end, not by unit tests. |
| `exec` | 23 | `test`, plus `native-check` for the C adapter and the ASan/Valgrind lanes | The deepest module and the best-covered one; see §4 rows 3–5 and the memory risk map. |
| `session` | 30 | `test`, `e2e`, `dogfood-check` | Orchestration; most integration suites live here. |
| `cli` | 12 | `test`, `contract-check-strict`, `e2e`, `readme-help-check` | `contract-check-strict` is the authority: it asserts every documented exit, stream, and environment behavior against the real binary. |
| `main` (`src/main.mojo`, 853 lines) | **0** | `e2e`, `contract-check-strict`, `dogfood-check`, `package-check` | **No classified suite imports or calls it.** By design — it is the composition root and the only `exit()` caller — but it means every regression in argv/env/exit wiring must be caught by a binary-level gate. This is also why the memory map's CLI probe (`C`) is the sole instrumented evidence for several platform files. |

### How the direct-call column was produced, and how it was checked

A one-off static pass over the 98 classified modules: collect each
`from mtest... import ...` binding, find the top-level function bodies, mark the
`test_*` ones plus every same-file function transitively named from them, and
count a layer when an imported symbol appears in a use position (`SYM(`,
`SYM.`, `SYM[`) on a marked line.

Static analysis of this kind is exactly where the memory risk map found three
false rows, so the pass was validated against five facts established
independently of it — four of them by the dynamic callgrind audit recorded in
that map, one by reading the source:

1. `tests/unit/test_config.mojo` does **not** use `lossy_utf8`, although it
   imports from `mtest.config`, which re-exports it. (Reproduced: absent.)
2. `tests/integration/test_exec_capture.mojo` **does** call `lossy_utf8`
   directly. (Reproduced: present.)
3. `tests/unit/test_config_lossy_utf8.mojo` calls it only through a module-level
   helper, never from a test body. (Reproduced — this is the case that forced
   the transitive step; the first version of the pass reported a false absence.)
4. `tests/integration/test_exec_paths.mojo` calls exactly one `exec` symbol,
   `canonicalize`, and nothing else. (Reproduced.)
5. `tests/integration/test_transcripts_smoke.mojo` imports no product symbol at
   all — it is a deliberate reference mini-parser over the committed snapshots.
   (Reproduced: zero layers.)

What the validation does **not** establish: every positive fact above concerns
one symbol in one file. No independently-known fact pins any per-layer *total*,
so the totals are the least corroborated numbers here — the same caveat, for
the same reason, as the memory map's per-suite counts.

## 4. High-risk intersections

Each row is an intersection this branch deliberately closed. "Pinned by" names
files that exist at `c28d691`. "Mutation proof" names the oracle that detects
the defect **and the property that makes it discriminating** — because "a test
exists" and "a test would notice" are different claims. Only row 13 was
mutation-tested while writing this map; the other rows point at oracles whose
own commits carry their proofs, and this map does not re-assert those runs.

| # | Intersection | Pinned by | Blocking oracle | Mutation proof | Platforms |
| --- | --- | --- | --- | --- | --- |
| 1 | Documented CLI behavior asserted on a binary from *this* invocation, with a SKIP counting as failure | `scripts/qa/contract.py` (`--strict --no-rebuild`, `build-bin` task edge) | `contract-check-strict` | `scripts/tests/test_contract.py`; `scripts/tests/test_ci_topology.py` rejects removing the row from either matrix or reordering `ci` | linux-64, osx-arm64 |
| 2 | Test inventory drift: a suite present on disk but absent from the registry, or an aggregate that dies without naming where | `scripts/checks/layout.py` (`CLASSIFIED_PATHS`, `CLASSIFIED_TEST_COUNT`), `scripts/harness/watchdog.py` | `harness-check`, `test` | `scripts/tests/test_layout.py`, `scripts/tests/test_classified.py`, `scripts/tests/test_process_watchdog.py` | `harness-check`: linux-64; `test`: both |
| 3 | Concurrency × bounded capture: one slot's overflow must not alter another slot's bytes or termination | `tests/integration/test_exec_pool.mojo` — `test_pool_truncation_is_slot_local_out_of_completion_order`, `test_pool_overflow_and_deadline_kill_finish_without_cross_slot_bytes` | `test` | The fixture `tests/fixtures/exec/tagged_streams.py` tags every emitted byte with its slot, so a cross-slot leak fails with the wrong slot's tag in the assertion rather than as an anonymous mismatch | linux-64, osx-arm64 |
| 4 | Transient `ETXTBSY` × retry: the retry must reach a *successful* `execve`, not merely time out honestly | `tests/integration/test_exec_etxtbsy.mojo` — `test_transient_etxtbsy_recovers_to_a_successful_child`, plus the two deadline/interrupt latching tests | `test` | The recovery test asserts a completed child with its exact output, so a retry that merely stopped honestly at the deadline cannot satisfy it; the deadline and interrupt tests own those two outcomes separately, in their own tests | linux-64, osx-arm64 |
| 5 | Live pool machinery fault × accounting: exit 3, no new scheduling, no live group, exact NOT-RUN remainder | `tests/integration/test_session_pool_faults.mojo` — five named faults (build dispatch, run dispatch, `wait_any` poll, gate-abort cleanup, interrupt cleanup) | `test` | Each test injects one fault at one boundary and asserts one exit class, so a fix that resolved every fault to the same code would red exactly one row | linux-64, osx-arm64 |
| 6 | Signals × teardown: SIGINT/SIGTERM during work exits 2 with exact accounting; a second interrupt forces hard termination; no child group survives | `e2e` scenarios `interrupt`, `interrupt-sigterm`, `interrupt-double`, `parallel-interrupt`; `tests/integration/test_exec_pool.mojo` `test_second_activation_*`; `tests/integration/test_exec_interrupt.mojo` | `e2e`, `test` | `scripts/tests/test_e2e.py` pins the runner's own group-signalling helper against a fake leader that forks into its own process group | linux-64, osx-arm64 |
| 7 | Descriptor exhaustion × worker sizing, and compiler resolution order | `e2e` scenarios `parallel-fd-clamp`, `mojo-executable-precedence`; fixtures `scripts/fixtures/toolchain/fake_fd_mojo.py`, `path_mojo.py` | `e2e` | `scripts/tests/test_e2e.py::LimitNofileTests` reads the limit the *spawned child* observed, so a `preexec_fn` that was accepted and ignored fails | linux-64, osx-arm64 |
| 8 | Hostile child bytes × console rendering: no child-controlled text may execute a terminal control | `src/mtest/report/console_text.mojo`; `tests/unit/test_report_console_text.mojo` (one test per control class); `tests/unit/test_report_escape.mojo`; `e2e` `hostile-console` | `test`, `e2e` | Each escaper test asserts one control family's exact rendering, and `test_escape_scalar_leaves_every_interpreted_control_unrenderable` sweeps the whole interpreted set | linux-64, osx-arm64 |
| 9 | Hostile child bytes × machine reports: invalid UTF-8, NUL, XML-illegal controls, and report-lookalike lines must still yield valid NDJSON and JUnit | `tests/fixtures/exec/hostile_report_actor.py`; `e2e` `hostile`, `hostile-reporters`, `junit-schema-gate`, the `json-*` scenarios | `e2e`, `junit-check`, `junit-render-check` | JUnit only: `scripts/tests/test_junit.py::test_a_rejects_the_broken_fixture` proves the checker rejects a broken artifact before `junit-check` runs it. **The NDJSON checker has no equivalent** — see the gap below | linux-64, osx-arm64 |
| 10 | Raw text semantics: RFC 3629 lossy decoding, shell quoting, CRLF as off-grammar drift | `tests/unit/test_config_lossy_utf8.mojo` (byte-exact tables), `tests/unit/test_config.mojo` (quoting tables), `tests/unit/test_protocol_corruption.mojo` (CRLF) | `test` | Every row carries the complete expected `String`, never a length or a substring, so a decoder change cannot pass by coincidence | linux-64, osx-arm64 |
| 11 | Unsafe/native ownership boundaries | — | `asan-check`, `valgrind-check`, `native-check` | See [`notes/test-memory-risk-map.md`](test-memory-risk-map.md) | ASan/Valgrind: **linux-64 only**; `native-check`: both |
| 12 | Packaged artifact × clean environment: the published package must install and run with the dev environment off `PATH` | `scripts/build/package_consumption.py` | `package-check` (`Linux / packaged artifact`, `macOS arm64 / packaged artifact`) | `scripts/tests/test_package_consumption.py`, including a pin that the gate invokes its own probes | linux-64, osx-arm64 |
| 13 | Toolchain upgrade × coverage claims | `scripts/checks/coverage_capability.py` | `harness-check` (branch logic); `coverage-capability` (diagnostic) | `scripts/tests/test_coverage_capability.py` — turning the discovered-flag branch's exit code to 0 reds three tests and only those three, each naming the exit code it expected: the branch test, the prose-fallback test, and the `main`-invocation test | linux-64, osx-arm64 |

### Gaps found while building this map

Both are recorded rather than fixed, because closing them is outside this
task's scope. Neither is a claim of coverage.

1. **The NDJSON stream oracle's self-test is never run by a gate.**
   `scripts/checks/reports/json_stream.py` carries a `_selftest()` covering
   forward compatibility, torn tails, duplicate keys, and non-finite numbers,
   reachable only as `python -m scripts.checks.reports.json_stream` with no
   arguments. No `pixi` task invokes it. Its `parse_stream` is used as an
   oracle by `scripts/e2e/assertions.py` and by both memory lanes, so a
   regression *in the oracle itself* would weaken every one of those callers
   silently. Its JUnit counterpart is wired up correctly:
   `junit-check` runs `scripts/tests/test_junit.py` before the checker.
   Closing this means one `&&` in a Pixi task, no new code.
2. **`src/main.mojo` has no suite at any level.** 853 lines of composition
   root — argv, env, config load, state load, reporter wiring, `exit()` — with
   no classified test module importing it. Every regression there has to
   surface through `e2e`, `contract-check-strict`, `dogfood-check`, or
   `package-check`. Those are strong gates, but they are all binary-level, so a
   fault in a branch none of them takes is invisible. The memory map's residual
   gap 1 is the same shape observed from the instrumentation side.

## 5. Counts, and why almost none of them are written down

The one hand-maintained total that stays is **`CLASSIFIED_TEST_COUNT` in
`scripts/checks/layout.py`**. It is not documentation; it is a tripwire. No
list pins the number of test *functions* inside an already-registered module, so
adding one changes a number nothing else would notice — which is exactly what
makes a deliberate, hand-edited constant the right instrument there.

Everything else is computed:

- The E2E gate's `<passed>/<total> scenarios passed` banner counts the results
  the run produced. `scripts/tests/test_e2e.py` drives `main` with substituted
  registries of several sizes and reads the banner back, and separately fails
  if any docstring under `scripts/e2e/` starts carrying a total.
- `scripts/tests/test_e2e.py` no longer asserts a literal registry length:
  `layout.E2E_SCENARIO_NAMES` already pins exact membership *and* order, so a
  second number would have added no detection.
- `pixi run harness-check` prints the real classified inventory. Use its output
  rather than any number found in a comment; a hand count in a `pixi.toml`
  comment had already gone stale by several hundred tests before this pass
  removed it.
- `contract-check-strict` builds its case list at runtime from
  `scripts/qa/contract.py`; no total is quoted for it here or anywhere else.

## 6. What this map does not claim

- **No line or branch coverage, at all.** Not "high"; not measured. §1 is the
  whole story, and it is a toolchain limitation rather than a decision.
- **No claim that a listed suite asserts a layer's contract.** §3 measures API
  contact, not intent. Only §4 rows claim that a specific behavior is pinned,
  and each names the file and the test.
- **No memory-safety claim.** That axis, including its gaps, belongs to
  `notes/test-memory-risk-map.md`.
- **No claim that `pixi run ci` is the whole gate.** ASan, Valgrind, and both
  package jobs run only in hosted CI.
- **No claim that these numbers stay true.** §2 is continuously enforced. §3 is
  a snapshot with a printed recipe and a stamp, and re-running it is the only
  way to know it still holds.
