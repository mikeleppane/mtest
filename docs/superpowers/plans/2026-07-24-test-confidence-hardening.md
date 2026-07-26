# Test Confidence Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a green mtest release gate strong evidence that discovery, supervision, parsing, accounting, and reporting still match the real user contract, including the highest-risk feature intersections found by the coverage assessment.

**Architecture:** Keep each oracle at the layer that owns the behavior: pure tables in unit tests, real child actors in `exec`, known-outcome trees in `session`, the built CLI in E2E, and installed artifacts in package jobs. Observable changes use red-green-refactor plus a deliberate mutation proof. Console hardening adds one display-only boundary in `report`; raw captures, protocol parsing, NDJSON, and JUnit retain their present semantics.

**Tech Stack:** Mojo 1.0.0b2, Python 3 test/gate tooling, C17 private POSIX adapter, Pixi, GitHub Actions, ASan/LSan, Valgrind, rattler-build, xmllint/XSD, strict JSON readers.

## Global Constraints

- Follow `AGENTS.md`, `.agents/skills/test-driven-development`, `.agents/skills/mojo-coding-guidance`, the global `mojo-syntax` skill, and `.agents/skills/git-conventions`.
- Never use `mojo run`; build and directly execute binaries.
- Never run two builds against the shared `build/` tree concurrently.
- For each behavior: add the smallest failing test, record the intended failure, implement the minimum fix, refactor under green, then temporarily mutate the protected condition and prove the test goes red for that reason.
- A mutation is temporary and must be reverted before the task commit.
- Do not regenerate protocol transcripts. CRLF remains intentionally off-grammar, and none of this work changes the TestSuite oracle.
- Do not weaken, skip, delete, or add tolerance to a gate to make it pass.
- Keep exact assertions for exit codes, signal numbers, bytes, paths, ordering, event kinds, file identities, and counts. Do not use `>= 1` where the fixture is deterministic.
- Keep product code under `src/` pure Mojo. Python remains test/build tooling only.
- Preserve FAIL versus CRASH, exit-code precedence, raw machine-report semantics, and deterministic ordering.
- Update `scripts/checks/layout.py`, E2E registries, memory-test inventories, and their independent Python tests in the same commit as any new suite, fixture, scenario, or gate row.
- Run `pixi run fmt` before every commit. Use Conventional Commits with an allowed scope and a body explaining why; do not add AI attribution or internal-plan references.
- Do not call the work complete until the full floor and both hosted-platform release jobs pass.

---

## Task 1: Make strict contract validation part of every release floor

**Files:**

- Modify: `pixi.toml`
- Modify: `.github/workflows/ci.yml`
- Modify: `scripts/checks/ci_topology.py`
- Modify: `scripts/tests/test_contract.py`
- Modify: `scripts/tests/test_ci_topology.py`
- Modify: `scripts/qa/contract.py`
- Modify: `AGENTS.md`

**Contract:** `pixi run ci` and both hosted platform chains must run `python -m scripts.qa.contract --strict --no-rebuild` against a `build/mtest` produced explicitly by the same Pixi invocation's `build-bin` dependency. A failed or skipped contract case, a missing binary, or an input that is obviously newer than the binary fails the gate. Fresh-build provenance comes from the exact task edge, not from timestamps; the checker itself must not start another build.

- [ ] **Red — reverse the old exclusion oracle.** In `scripts/tests/test_contract.py`, replace the assertions that `contract-check` is absent from `ci`/`ci-preflight` with:

  ```python
  self.assertEqual(
      tasks["contract-check-strict"],
      {
          "cmd": "python -m scripts.qa.contract --strict --no-rebuild",
          "depends-on": ["build-bin"],
      },
  )
  self.assertIn("contract-check-strict", tasks["ci"]["depends-on"])
  self.assertNotIn("contract-check-strict", tasks["ci-preflight"]["depends-on"])
  ```

  Keep it out of `ci-preflight`: that chain owns build-time static oracles, while strict contract validation consumes the binary produced by it.

- [ ] Extend `scripts/tests/test_ci_topology.py` to require a `contract` row in both `linux-test-matrix` and `macos-test-matrix`, with `task: contract-check-strict`, and require it to depend on its platform preflight job.

- [ ] Run `pixi run harness-check`. Expected red: missing Pixi task/dependency and missing hosted matrix rows.

- [ ] Add contract-tool tests proving `--no-rebuild` fails closed when `build/mtest` is missing or older than any binary input: `src/`, `native/`, `scripts/build/production_build.sh`, `scripts/build/native.py`, `scripts/build/native_strict_flags.txt`, `pixi.toml`, or `pixi.lock`. Replace the current stale-binary warning path in `ensure_binary()` with `_die(...)`. Separately pin the Pixi `contract-check-strict -> build-bin` edge exactly; do not claim an mtime comparison is a content-identity proof.

- [ ] Harden the contract check's now-blocking SIGINT probe before promotion. Replace the fixed post-discovery and orphan sleeps with a bounded readiness barrier for the exact hanging child and a bounded poll for group disappearance. Keep the 120 s outer deadline, send SIGINT only after readiness, and treat missing platform process-inspection support as a strict failure. Add Python negative controls for “child never became ready” and “child survived cleanup.”

- [ ] **Green — add one canonical strict task.** In `pixi.toml`, retain the contributor-friendly `contract-check` task and add:

  ```toml
  contract-check-strict = { cmd = "python -m scripts.qa.contract --strict --no-rebuild", depends-on = [
    "build-bin",
  ] }
  ```

  Append `contract-check-strict` to `ci.depends-on` after `e2e`; do not add it to `ci-preflight`.

- [ ] Add a complete contract row to both platform matrices in `.github/workflows/ci.yml`. The Linux row must contain `runner: ubuntu-24.04`, `lane: strict contract`, `task: contract-check-strict`, `libc_debug: false`, `safety_artifact: false`, `artifact_name: none`, and `artifact_path: none`; place it immediately after the E2E row and before ASan. The macOS row uses `runner: macos-15` with the same remaining fields and follows its E2E row. Each matrix job has a fresh checkout, so the Pixi task's `build-bin` dependency produces the binary inside that job before `--no-rebuild` validates it; no preflight artifact is assumed. Update `LINUX_MATRIX_ROWS`, `MACOS_MATRIX_ROWS`, `CI_TASKS`, and `CI_FLOOR_TASKS` in `scripts/checks/ci_topology.py` to match exactly.

- [ ] Update the quality-floor text in `AGENTS.md` so local `ci` and hosted chains name the strict contract check in their actual order.

- [ ] Run:

  ```text
  pixi run harness-check
  pixi run build
  pixi run contract-check-strict
  ```

  Expected: topology checks pass; the strict contract checker reports 60 passed, 0 skipped, and exits 0.

- [ ] **Mutation proof.** Temporarily change one existing strict contract expectation in a disposable working-tree edit—for example, change the `-V` usage-error check from expected exit 4 to exit 1—run `pixi run contract-check-strict`, and confirm a nonzero exit naming that exact case. Restore the expectation and rerun green.

- [ ] Run `pixi run ci` once because the dependency graph changed.

- [ ] Commit:

  ```text
  ci(test): gate the strict CLI contract

  Make documented exit, stream, and environment behavior blocking on every
  supported platform instead of leaving the exhaustive contract oracle manual.
  ```

---

## Task 2: Make classified-test inventory fail closed and repair misleading tests

**Files:**

- Modify: `scripts/checks/layout.py`
- Modify: `scripts/harness/aggregate.py`
- Modify: `scripts/tests/test_layout.py`
- Modify: `scripts/tests/test_aggregate.py`
- Modify: `tests/unit/test_select_logic.mojo`
- Modify: `tests/unit/test_protocol_corruption.mojo`
- Modify: `tests/unit/test_report_composite.mojo`
- Modify: `tests/unit/test_cli_inventory.mojo`
- Modify: `tests/unit/test_cli_parse.mojo`
- Modify: `scripts/harness/classified.py`
- Modify: `scripts/tests/test_classified.py`
- Modify: `scripts/harness/watchdog.py`
- Modify: `scripts/tests/test_process_watchdog.py`

**Contract:** Every `.mojo` file under `tests/unit/` and `tests/integration/` is either the root package marker `__init__.mojo` or an explicitly registered `test_*.mojo` classified suite. Symlinked files and alternative suffix names are errors. The aggregate reports the last module it started when a run exits, crashes, or times out.

- [ ] **Red — inventory escape.** Add temporary-tree cases to `scripts/tests/test_layout.py` that call a new parameterized universe helper directly and create:

  ```text
  tests/unit/session_shard_test.mojo
  tests/integration/test_probe.mojo.disabled
  tests/unit/test_link.mojo -> outside.mojo
  tests/unit/helper.mojo
  ```

  Require the helper/comparison to reject each with an exact `unexpected classified Mojo file` or `symlinked classified path` diagnostic. Keep `tests/unit/__init__.mojo` and `tests/integration/__init__.mojo` accepted. Add a separate wiring assertion that repository `check_suite_layout()` invokes this helper with `REPO_ROOT`.

- [ ] Run `python -m unittest scripts.tests.test_layout`. Expected red: current `test_*.mojo` glob never sees the suffix/misnamed files.

- [ ] **Green — compare the complete Mojo universe.** Add a helper with this interface to `scripts/checks/layout.py`:

  ```python
  def classified_mojo_universe(root: Path) -> tuple[set[Path], set[Path]]:
      """Return regular and symlinked Mojo paths beneath both classified roots."""
  ```

  Walk every directory entry under both roots without following directory symlinks. Treat a regular file as Mojo-like when `.mojo` appears anywhere in `Path.suffixes`, so both `helper.mojo` and `test_probe.mojo.disabled` enter the universe. Compare the universe against `CLASSIFIED_PATHS | {unit/__init__.mojo, integration/__init__.mojo}` and fail on either set difference. Reject every symlink entry regardless of target or suffix.

- [ ] Add an aggregate parser test showing obsolete `fn test_*` syntax is not silently accepted: `aggregate.test_function_names("fn test_old():\\n    pass\\n")` must raise `declares no test_* functions`. Do not add an `fn` detector to product code; Mojo 1.0.0b2 already rejects `fn`, and the complete-file inventory closes the actual silent-drop path.

- [ ] Repair the misleading tests:

  - Rename `test_named_selecting_none_leaves_empty_selection` to describe its real one-match behavior, then add a genuinely empty selected-name case with exact empty members and deselection count.
  - Replace `test_stderr_content_is_invisible_to_the_parser` with a real single-input boundary test: prefix the report input with stderr-shaped noise and assert the parser’s exact result, or delete the unused variable and rename the test to the exact noise behavior it proves.
  - Make the composite reporter test emit and assert every currently supported event kind, deriving the expected event-kind list from the closed event vocabulary rather than claiming “one of each” for six.
  - Replace the help substring smoke with equality against the CLI flag inventory/help-rendered option set.

- [ ] Run each owning classified file with `pixi run test-file -- <path>`, then `pixi run harness-check`.

- [ ] **Red — aggregate failure provenance.** Add a Python harness test whose generated aggregate prints:

  ```text
  ==> tests/unit/test_first.mojo
  ==> tests/unit/test_crashing.mojo
  ```

  and then exits nonzero, receives SIGTERM, or times out before the third module. Require the final diagnostic to include `last module: tests/unit/test_crashing.mojo` for all three endings.

- [ ] Run `python -m unittest scripts.tests.test_classified`. Expected red: current diagnostics name only `aggregate suite (run ...)`.

- [ ] **Green — track the marker without splitting the aggregate.** Extend the watchdog result/`StepResult` capture only as needed so `classified.py` can retain the last complete `==> <module>` line from aggregate stdout. If stdout/stderr become pipes, drain both concurrently while the child runs, tee bytes to the contributor's original streams, and retain only the bounded marker state; never call `wait()` with an undrained pipe. Add a watchdog-level actor that writes more than the pipe capacity before its marker and then exits/crashes/times out; require all three cases to finish under the outer guard with complete tee output and the correct marker. Add:

  ```python
  def _last_module(output: str) -> str | None:
      """Return the path in the last complete aggregate module marker."""
  ```

  Append `; last module: <path>` to ordinary-exit, signal, and timeout diagnostics. Preserve the aggregate’s one-binary execution model and signal re-raise behavior.

- [ ] Run `python -m unittest scripts.tests.test_classified` and `pixi run harness-check`.

- [ ] **Mutation proof.** Prove every repaired test is load-bearing:

  - change the full-universe walk back to `glob("test_*.mojo")` and require the suffix-name test to fail;
  - temporarily make empty name selection retain the first member and require the genuine-empty test to fail;
  - break the parser's noise/block choice so the stderr-shaped prefix wins and require the boundary test to fail;
  - omit one composite dispatch arm and require the exhaustive event-kind assertion to fail;
  - omit one rendered `FlagSpec` option and require the help/inventory set equality to fail.

  Restore every mutation and rerun the owning focused suite plus `harness-check`.

- [ ] Commit:

  ```text
  test(harness): fail closed on classified inventory drift

  Detect misnamed or symlinked Mojo suites and make aggregate failures identify
  the last module reached so a green inventory cannot hide unexecuted tests.
  ```

---

## Task 3: Pin concurrent bounded capture and ETXTBSY recovery

**Files:**

- Add: `tests/fixtures/exec/tagged_streams.py`
- Modify: `tests/fixtures/exec/etxtbsy_target.sh`
- Modify: `scripts/checks/layout.py`
- Modify: `tests/integration/test_exec_pool.mojo`
- Modify: `tests/integration/test_exec_etxtbsy.mojo`

**Contract:** At pool capacity greater than one, one slot’s capture overflow cannot change another slot’s bytes or termination. ETXTBSY retry must reach a successful `execve`, not merely time out honestly.

- [ ] Add `tagged_streams.py`, a direct Python actor that takes `tag`, `stdout_bytes`, `stderr_bytes`, plus optional `ready_path` and `release_path`. It writes deterministic ASCII payloads with distinct head/tail sentinels via `os.write`; when barrier paths are supplied it creates `ready_path` after writing, polls `release_path` under an actor-local deadline, and exits only after release. Register it in `EXEC_FIXTURES`.

- [ ] **Red — overflow plus exact neighbor.** Add `test_pool_truncation_is_slot_local_out_of_completion_order` using `Supervisor(2, capture_bound_bytes=200)`:

  - tag 10 writes 513 bytes to both streams, creates a ready file, then blocks on a release file;
  - tag 20 writes exact `neighbor-out\\n` and `neighbor-err\\n` and exits;
  - wait for tag 20, write tag 10's release file, then wait for tag 10;
  - assert completion order `[20, 10]`;
  - assert both tag-10 truncation flags, exact head/marker/tail bytes, and retained lengths;
  - assert both tag-20 streams byte-for-byte and both flags false;
  - assert both terminations are `Exited(0)`.

- [ ] Add `test_pool_overflow_and_deadline_kill_finish_without_cross_slot_bytes`: one actor overflows both streams while one sleeper hits a 100 ms deadline. Assert the overflow result is exit 0/truncated, the sibling is `TimedOut`, and neither stream contains the other tag.

- [ ] Run `pixi run test-file -- tests/integration/test_exec_pool.mojo`. This pins existing intended behavior; if it unexpectedly passes immediately, perform the mutation proof before accepting it as evidence.

- [ ] **Mutation proof.** Temporarily route one completed slot’s stderr capture through the prior slot index in `src/mtest/exec/supervise.mojo`, or temporarily share its truncation flag. Confirm the new focused test fails on exact neighbor bytes/flags, restore, and rerun green. If the mutation triggers a safety error before assertion, use a safe mutation that copies only the wrong flag.

- [ ] **Red — ETXTBSY then success.** In `test_exec_etxtbsy.mojo`, configure the test adapter to inject `ETXTBSY` for the first two child `execve` attempts and then stop faulting. Run a direct actor with no deadline and assert:

  ```mojo
  assert_equal(bytes_to_str(result.stdout_bytes), "etxtbsy-recovered\n")
  assert_equal(bytes_to_str(result.stderr_bytes), "")
  assert_true(result.termination.is_exited())
  assert_equal(result.termination.value, 0)
  assert_false(result.stdout_truncated)
  assert_false(result.stderr_truncated)
  ```

  Change the already-registered `etxtbsy_target.sh` success body to print exactly `etxtbsy-recovered\n` before exiting 0. The existing timeout/interrupt cases fault before the body and must remain unchanged.

- [ ] Run `pixi run test-file -- tests/integration/test_exec_etxtbsy.mojo`. Expected red if the injected fault is currently sticky; otherwise proceed directly to the negative control.

- [ ] If the fault API cannot express a finite occurrence range, add the smallest test-only adapter control needed to fail occurrences 1 and 2 only. Keep it behind `MTEST_EXEC_TESTING`; do not change the production ABI version or retry constants.

- [ ] **Mutation proof.** Temporarily change the C macro `MTEST_ETXTBSY_RETRIES` to `1`, run `pixi run build-native` to rebuild the test adapter, then run the focused suite. Require the recovery case to fail while the deadline/interrupt cases retain truthful endings. Restore the macro, rebuild the native adapter again, and run:

  ```text
  pixi run test-file -- tests/integration/test_exec_etxtbsy.mojo
  pixi run test-file -- tests/integration/test_exec_pool.mojo
  pixi run native-check
  ```

- [ ] Commit:

  ```text
  test(exec): pin concurrent truncation and busy-exec recovery

  Exercise bounded capture under real pool concurrency and prove transient
  ETXTBSY faults can recover to an ordinary successful child completion.
  ```

---

## Task 4: Exercise live pool machinery failures and selection reconciliation

**Files:**

- Add: `tests/integration/test_session_pool_faults.mojo`
- Modify: `tests/integration/test_session_json_stream.mojo`
- Modify: `tests/integration/test_session_selection.mojo`
- Modify: `scripts/checks/layout.py`
- Modify: `scripts/tests/test_classified.py`

**Contract:** A non-interrupt pool machinery fault resolves to exit 3, stops new scheduling, drains or kills every live group, emits one truthful internal error, and accounts the exact remainder NOT-RUN. User-controlled suite disagreement remains MALFORMED-SUITE/exit 1.

- [ ] Register `test_session_pool_faults.mojo` before running it.

- [ ] Build a three-file known-outcome tree and a `RecordingCoordinator`. Add one focused case for each test-only adapter fault:

  | Boundary | Injected operation | Occurrence | Required result |
  | --- | --- | ---: | --- |
  | build dispatch open | `MTEST_EXEC_OP_PIPE_STDOUT` | 1 | exit 3, 3 NOT-RUN |
  | run dispatch open | `MTEST_EXEC_OP_PIPE_STDOUT` | 2 | exit 3, exact already-built file NOT-RUN |
  | wait-any poll | `MTEST_EXEC_OP_POLL_SET` | 1 | exit 3, all live groups gone |
  | gate-abort cleanup | `MTEST_EXEC_OP_GROUP_TERM` | 1 | exit 3 outranks gate exit 1 |
  | interrupt cleanup | `MTEST_EXEC_OP_GROUP_TERM` | 1 | exit 2 outranks cleanup fault |

  Assert the complete event-kind sequence, the `InternalErrorPayload.step`, exact program/errno, exact file identities that started, and exactly one `SessionFinished`.

  For the occurrence-2 run-dispatch case, configure `workers=2` but provide exactly one run file. The pool dispatches that file's build as open occurrence 1, waits for it, and only then dispatches its run as occurrence 2. Multiple run files would make occurrence 2 another build and fault the wrong boundary.

  For both `GROUP_TERM` cases, make a SIGTERM-ignoring sibling create a ready file, and make the failing gate/interrupt trigger wait for that readiness before settling. This proves `kill_all()` has a live group and must consume occurrence 1. In the interrupt case assert exit 2, never exit 3, with exact NOT-RUN accounting despite the injected cleanup error.

- [ ] **Red.** Run `pixi run test-file -- tests/integration/test_session_pool_faults.mojo`. Record which assertions expose missing behavior; do not relax expected exit/accounting to current output.

- [ ] Add a populated-batch machine-stream failure test using the existing closed-pipe JSON reporter technique: workers=2, four files, stream fails after at least one file event. Assert in-flight files finish, no third dispatch occurs after failure observation, remaining identities are NOT-RUN, final exit is 3, and no terminal record is falsely reported written.

- [ ] Add two selection reconciliation cases with purpose actors:

  - `--skip-all` lists three names, but the `--only` result contains two rows;
  - a non-selected row reports PASS instead of SKIP.

  Assert `MALFORMED-SUITE`, exit 1, never DRIFT/exit 3, and the exact disagreement diagnostic.

- [ ] **Green.** Make only branch-local changes needed by observed reds. Keep the pipeline kernel policy-only; fault handling remains in the pool/selection drivers and reporting remains through `ReportCoordinator`.

- [ ] Run:

  ```text
  pixi run test-file -- tests/integration/test_session_pool_faults.mojo
  pixi run test-file -- tests/integration/test_session_json_stream.mojo
  pixi run test-file -- tests/integration/test_session_selection.mojo
  pixi run harness-check
  ```

- [ ] **Mutation proof.** Perform four independent mutations: map `wait_any` failure to exit 1; map a membership disagreement to drift; suppress the gate-cleanup fault's exit-3 escalation; and let cleanup failure overwrite an already-latched interrupt with exit 3. Confirm the respective tests fail on exit 3 versus 1, MALFORMED versus DRIFT, gate failure versus internal error, and interrupt exit 2 versus internal exit 3. Restore and rerun.

- [ ] Commit:

  ```text
  test(session): cover pool fault and reconciliation exits

  Pin scheduling shutdown, cleanup, and exact NOT-RUN accounting where native
  machinery faults intersect populated batches and user suite disagreements.
  ```

---

## Task 5: Make live signal accounting exact

**Files:**

- Modify: `scripts/e2e/runner.py`
- Modify: `scripts/e2e/scenarios/resilience.py`
- Modify: `scripts/e2e/scenarios/parallel.py`
- Modify: `scripts/e2e/scenarios/json_reporter.py`
- Modify: `scripts/e2e/scenarios/junit_reporter.py`
- Modify: `scripts/e2e/__main__.py`
- Modify: `scripts/checks/layout.py`
- Modify: `scripts/tests/test_e2e.py`
- Modify: `tests/integration/test_exec_pool.mojo`
- Add or modify deterministic slow fixtures under: `e2e/slow/`, `e2e/parallel/`

**Contract:** SIGINT and SIGTERM during work exit 2 with exact completed/NOT-RUN accounting. A second interrupt during teardown forces hard termination. No child process group survives.

- [ ] Replace fixed sleeps as the signal trigger. Extend `run_mtest_signaled` to accept one or more ready-file barriers and optionally a `second_signal` plus teardown barriers:

  ```python
  def run_mtest_signaled(
      self,
      args: list[str],
      *,
      signal_number: int,
      timeout: float,
      ready_files: tuple[str, ...] = (),
      delay: float | None = None,
      second_signal: int | None = None,
      teardown_ready_files: tuple[str, ...] = (),
      owned_pgid_files: tuple[str, ...] = (),
      env_overrides: dict[str, str] | None = None,
  ) -> tuple[Run, int]:
      ...
  ```

  Poll until every required ready file exists under one monotonic deadline; never use an unguarded wait. Retain `delay` temporarily as a mutually exclusive compatibility input so no intermediate commit breaks existing callers, then convert every caller in resilience, parallel, JSON, and JUnit to a readiness barrier before removing it.

- [ ] Deliver test signals to the mtest leader PID with `os.kill(proc.pid, signal_number)`, never to its process group. The product must be what forwards cleanup signals to owned child groups. Keep `kill_group(proc)` only as bounded harness cleanup after evidence is captured or on a harness timeout. Add a Python runner test that records `os.kill`/`os.killpg` calls and proves both managed interrupts and the SIGKILL reporter scenario target only the leader before final cleanup.

- [ ] Handle fatal SIGKILL separately because mtest cannot clean up after its own death and its children use distinct process groups. Require each purpose actor to write its actual PGID to an `owned_pgid_file` before the ready barrier. After capturing the intended torn-reporter evidence, the harness TERM/KILLs every recorded child PGID under a deadline and proves each is gone. Managed SIGINT/SIGTERM scenarios do not use that cleanup until after asserting the product itself removed all recorded child groups.

- [ ] **Red — exact sequential SIGINT.** Arm a fixture only after one passing file has completed and the next child is blocked. Assert exit 2, exact outcome counts, exact NOT-RUN file identities in JSON and JUnit, and no group. Replace the existing `not_run >= 1` assertion with the fixture’s exact count.

- [ ] Add the same deterministic case with SIGTERM and assert the same semantic exit 2/accounting.

- [ ] **Red — exact parallel SIGINT.** With `-n 2`, arm two blocked children and keep a third undispatched. Assert both in-flight identities become NOT-RUN, the third is NOT-RUN, no fourth dispatch appears in the run log, exit 2, exact JSON/JUnit terminal counts, and no group.

- [ ] Add a double-interrupt case. The first SIGINT begins teardown; a fixture that ignores polite termination creates the teardown barrier; the second SIGINT must immediately hard-kill every live child group while mtest itself still emits its partial accounting and exits 2, as required by `docs/cli-contract.md`. Assert exit 2, exact NOT-RUN identities, no TIMEOUT verdict, one terminal summary, and no surviving process group.

- [ ] Pin “immediate” independently of eventual E2E cleanup in `test_exec_pool.mojo`. Spawn a SIGTERM-ignoring actor with `ProcessSpec.grace_ms=5000`, raise two interrupt activations before `wait_any`, and assert final SIGKILL plus completion within a 2 s guard. Removing the second-activation branch would wait the full 5 s grace and fail this test, while ordinary loaded-CI jitter remains well below the 3 s separation.

- [ ] Register new `interrupt-sigterm` and `interrupt-double` scenarios and update the exact registry/owner assertions. Remove the stale “59-scenario” module count from `scripts/e2e/__main__.py`; report only the derived runtime total.

- [ ] Run the four scenarios through `python -m scripts.e2e` while developing, then run `pixi run e2e`.

- [ ] **Mutation proof.** Perform both mutations separately: temporarily let the pool schedule one more file after observing the first interrupt and confirm the E2E run-log/NOT-RUN assertion fails; then temporarily delete the `_sweep` branch for `activations >= 2` and confirm the 5 s-grace integration test fails its 2 s guard. Restore and rerun.

- [ ] Commit:

  ```text
  test(e2e): make interrupt accounting deterministic

  Replace timing-only interrupt probes with readiness barriers and exact file,
  reporter, exit, and process-group assertions for sequential and pooled runs.
  ```

---

## Task 6: Exercise descriptor clamping and Mojo executable precedence through the CLI

**Files:**

- Modify: `scripts/e2e/runner.py`
- Modify: `scripts/e2e/scenarios/parallel.py`
- Modify: `scripts/e2e/scenarios/selection.py`
- Modify: `scripts/e2e/__main__.py`
- Modify: `scripts/checks/layout.py`
- Modify: `scripts/tests/test_e2e.py`
- Add: `scripts/fixtures/toolchain/path_mojo.py`
- Add: `scripts/fixtures/toolchain/fake_fd_mojo.py`

**Contract:** A real low `RLIMIT_NOFILE` clamps requested workers loudly and still runs every file. Compiler resolution is flag, then `MTEST_MOJO`, then `PATH`.

- [ ] Add an optional soft fd limit to `run_mtest` using a POSIX `preexec_fn` that changes only the child:

  ```python
  def _limit_nofile(soft: int) -> Callable[[], None]:
      def apply() -> None:
          import resource
          _old_soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
          resource.setrlimit(resource.RLIMIT_NOFILE, (soft, hard))
      return apply
  ```

  Keep the option absent by default. Skip only on a platform where `RLIMIT_NOFILE` itself is unavailable; Linux and macOS must both execute it.

- [ ] **Red — live clamp.** Add `parallel-fd-clamp`: set soft limit 76, request `-n 16`, and run a fixed four-file pass tree with `--json -`. Use `fake_fd_mojo.py`, a strict compiler stand-in that writes directly executable, valid-report pass actors, so the low descriptor limit exercises mtest's native pool/scheduler rather than imposing an unsupported 76-fd ceiling on LLVM. The formula `min(64, (soft - 64 - 3) // 3)` gives cap 3. Assert:

  - console warning exactly names request 16, cap 3, and resolved 3;
  - `session_started.workers == 3`;
  - all four exact paths finish PASS;
  - summary is 4 passed, 0 other, 0 NOT-RUN;
  - exit 0 and no `INTERNAL-ERROR`/`EMFILE`.

- [ ] Add a unit test for the `preexec_fn` helper that launches a tiny Python child and prints its observed soft limit, proving the E2E runner applies the limit rather than merely accepting an argument.

- [ ] **Red — executable precedence.** Make `path_mojo.py` a direct executable wrapper around the real `mojo` that logs its absolute wrapper identity and exact argv to a path supplied by an environment variable, then `execv`s the real compiler without a shell. Resolve the real compiler once in the E2E parent before prepending the wrapper directory and pass that absolute path as `MTEST_REAL_MOJO`; the wrapper rejects an unset value or a value equal to itself, preventing PATH recursion.

- [ ] Add one E2E scenario with three isolated logs:

  1. `--mojo flag_wrapper` and `MTEST_MOJO=env_wrapper`: only the flag log exists.
  2. no flag and `MTEST_MOJO=env_wrapper`: only the env log exists.
  3. neither, but a temporary PATH directory contains executable `mojo`: only the PATH log exists.

  Assert both collection and build invocations use the selected wrapper and exact argument vectors; do not accept a pure config-unit result.

- [ ] Register both scenarios and update exact E2E inventory tests.

- [ ] Run `pixi run e2e`.

- [ ] **Mutation proof.** Temporarily reverse flag/env resolution in `src/mtest/config/mojo_path.mojo`; confirm only the first E2E case fails and identifies the env wrapper invocation. Restore and rerun.

- [ ] **Clamp mutation proof.** Separately bypass the live cap when calling `resolve_workers` (feed the compile-time capacity instead of `query_effective_cap()`), then require `parallel-fd-clamp` to fail on the missing warning and `session_started.workers != 3`. Restore and rerun.

- [ ] Commit:

  ```text
  test(e2e): cover fd clamping and compiler precedence

  Drive resource-limit worker sizing and all three Mojo executable resolution
  sources through the built command rather than relying on pure policy tests.
  ```

---

## Task 7: Pin raw text semantics before changing display behavior

**Files:**

- Add: `tests/unit/test_config_lossy_utf8.mojo`
- Modify: `tests/unit/test_config.mojo`
- Modify: `tests/unit/test_protocol_corruption.mojo`
- Modify: `scripts/checks/layout.py`
- Modify: `scripts/tests/test_classified.py`

**Contract:** Lossy decoding follows RFC 3629 boundaries with one replacement per invalid byte consumed by the current algorithm; shell quoting remains one safe argv token for all metacharacters; CRLF remains off-grammar drift.

- [ ] Register `test_config_lossy_utf8.mojo`.

- [ ] Add table-driven cases covering ASCII, minimum/maximum valid 2/3/4-byte scalars, lone continuation bytes, overlong encodings, surrogates, values above U+10FFFF, illegal leaders, every truncation position, and valid-invalid-valid adjacency. Each row contains exact input `List[UInt8]` and the complete expected `String`.

- [ ] Add shell-quote rows for:

  ```text
  plain
  space here
  single'quote
  $(touch pwned)
  `cmd`
  $HOME
  semi;colon
  star*glob
  question?glob
  bracket[abc]
  back\\slash
  line\nbreak
  tab\tvalue
  escape-\x1b
  nul-\x00
  snowman-☃
  empty string
  ```

  Assert exact POSIX single-token strings without executing a shell. Add exact `shell_join` and `build_flags_string` tables for the same hostile tokens, including the current literal newline/tab representation. Task 8 owns the later one-physical-line console neutralization. No product or test oracle invokes `/bin/sh -c`.

- [ ] Add a focused mutation for quoting: temporarily add `*` or backslash to `_SHELL_SAFE`, and require the exact `shell_quote`, `shell_join`, and build-flags assertions to fail. Task 8 separately mutation-proves the final console reproduction line.

- [ ] Add a protocol case that converts a valid committed report block from LF to CRLF and asserts `ParseKind.OFF_GRAMMAR`, with no parsed rows or summary. Name it `test_crlf_report_is_intentional_off_grammar_drift`.

- [ ] **Red/negative control.** These pin existing behavior. Temporarily accept `\\r` in `_split_lines`; confirm the CRLF test fails. Temporarily skip continuation validation in `lossy_utf8`; confirm the overlong/surrogate rows fail. Restore both.

- [ ] Run:

  ```text
  pixi run test-file -- tests/unit/test_config_lossy_utf8.mojo
  pixi run test-file -- tests/unit/test_config.mojo
  pixi run test-file -- tests/unit/test_protocol_corruption.mojo
  pixi run harness-check
  ```

- [ ] Commit:

  ```text
  test(config): pin hostile text and CRLF boundaries

  Make decoder, quoting, and protocol newline assumptions explicit before the
  console gains a separate display-only neutralization boundary.
  ```

---

## Task 8: Add one console text-safety boundary

**Files:**

- Add: `src/mtest/report/console_text.mojo`
- Add: `tests/fixtures/exec/hostile_report_actor.py`
- Add: `scripts/fixtures/toolchain/fake_hostile_mojo.py`
- Modify: `src/mtest/report/console.mojo`
- Add: `tests/unit/test_report_console_text.mojo`
- Modify: `tests/unit/test_report_console.mojo`
- Modify: `scripts/e2e/scenarios/core.py`
- Modify: `scripts/e2e/__main__.py`
- Modify: `scripts/checks/layout.py`
- Modify: `scripts/tests/test_e2e.py`
- Modify: `scripts/tests/test_classified.py`
- Modify: `docs/cli-contract.md`
- Modify: `README.md`
- Regenerate: `docs/assets/mtest-run.svg`

**Contract:** Untrusted child-controlled text cannot execute terminal control sequences. Scalar fields escape every C0 control, DEL, and C1 control. Multiline fields preserve LF and tab but escape all other controls. Raw parser inputs, captures, NDJSON, and JUnit are unchanged.

- [ ] Register `test_report_console_text.mojo`.

- [ ] **Red — exact helpers.** Add table tests for these interfaces:

  ```mojo
  def escape_scalar(text: String) -> String
  def escape_multiline(text: String) -> String
  def prefix_lines(text: String, prefix: String = "    | ") -> String
  ```

  Required mapping:

  - scalar U+0000..U+001F -> uppercase `\\xHH`, including LF and tab;
  - multiline preserves LF and tab, maps every other C0 to uppercase `\\xHH`;
  - U+007F -> `\\x7F`;
  - U+0080..U+009F -> uppercase `\\u00HH`;
  - printable Unicode is unchanged;
  - `prefix_lines("a\\n\\nb\\n") == "    | a\\n    | \\n    | b\\n"`;
  - a final LF does not create a phantom fourth prefixed line.

- [ ] Run `pixi run test-file -- tests/unit/test_report_console_text.mojo`. Expected red: missing module.

- [ ] **Red — real terminal boundary.** Before adding `console_text.mojo`, add `hostile_report_actor.py` as a direct bytes actor that emits invalid UTF-8, NUL, ESC/CSI, OSC terminated by BEL and ST, DEL/C1 controls, report-lookalike noise, and a final valid TestSuite block. Add `fake_hostile_mojo.py` as a strict direct compiler stand-in that accepts only the expected build argv, embeds the canonical source path in an executable copy of the actor, and rejects every unexpected command. Register the actor/fixture and one `hostile-console` E2E scenario, then run it against the unchanged CLI. Require no raw ESC/NUL/control bytes and exact prefixed lines. Expected red: current console emits child control bytes verbatim. Keep this failing scenario in the same red-green commit as the console fix.

- [ ] **Green — implement the pure display module.** Iterate Unicode code points, not bytes. Keep hexadecimal generation local and allocation-conscious:

  ```mojo
  def _hex_digit(value: Int) -> String:
      if value < 10:
          return String(chr(48 + value))
      return String(chr(65 + value - 10))

  def _byte_escape(prefix: String, value: Int) -> String:
      return prefix + _hex_digit((value >> 4) & 15) + _hex_digit(value & 15)
  ```

  `escape_scalar` and `escape_multiline` must be the only policy functions; `prefix_lines` owns line fencing only. Give every public entity a Google-style docstring.

- [ ] Apply the boundary to every child/user-controlled console insertion:

  | Console value | Mode |
  | --- | --- |
  | paths, node ids, test names, patterns, program names, repro argv | scalar |
  | warnings and single-line details | scalar |
  | captured stdout/stderr, failure details, compiler diagnostics | multiline then `prefix_lines` |
  | mtest-owned labels, separators, ANSI styling | unchanged and applied after escaping |

  Audit every event handler and renderer in `console.mojo`; no raw event string may be concatenated directly into output.

- [ ] Add exact console tests for NUL, ESC/CSI, OSC with BEL and ST endings, DEL, C1, quotes, tabs, embedded/final newlines, empty logical lines, and a large capture containing controls near both retained ends.

- [ ] Assert mtest’s own `--color always` ANSI is still present while child `\\x1b[31m` appears literally as `\\x1B[31m`. Assert reproduce lines scalarize embedded newlines so they remain one console line.

- [ ] Assert existing NDJSON/JUnit byte tests are unchanged. Do not run escaped console text through their serializers.

- [ ] Update `docs/cli-contract.md` with the exact scalar/multiline mapping and line-prefix rule. Update README examples only where output visibly changes.

- [ ] Build the real binary and regenerate console assets only through `pixi run python -m scripts.maintenance.console_svg`. Inspect the full SVG diff and require `mtest-run.svg` to show the new prefixed/escaped layout; any other asset change must be traced to the named scenario and current binary output. Never hand-edit captured SVG text.

- [ ] **Mutation proof.** Temporarily exempt ESC from `escape_scalar` and `escape_multiline`. Confirm the unit and PTY-facing console tests fail on the raw byte. Restore and rerun:

  ```text
  pixi run test-file -- tests/unit/test_report_console_text.mojo
  pixi run test-file -- tests/unit/test_report_console.mojo
  pixi run junit-render-check
  pixi run contract-check-strict
  pixi run harness-check
  ```

- [ ] Commit as an intentional console contract change:

  ```text
  feat(report)!: neutralize terminal controls in console text

  Route untrusted display text through one scalar or multiline boundary while
  preserving raw captures and machine-reporter escaping semantics.

  BREAKING CHANGE: Console rendering now escapes child-controlled C0, DEL, and
  C1 control characters instead of emitting them verbatim.
  ```

---

## Task 9: Extend the hostile-byte actor through NDJSON and JUnit

**Files:**

- Modify: `scripts/e2e/scenarios/json_reporter.py`
- Modify: `scripts/e2e/scenarios/junit_reporter.py`
- Modify: `scripts/e2e/scenarios/core.py`
- Modify: `scripts/e2e/__main__.py`
- Modify: `scripts/checks/layout.py`
- Modify: `scripts/tests/test_e2e.py`

**Contract:** The actor introduced before the console fix also proves that invalid UTF-8, NUL, XML-illegal controls, quotes, report-lookalike lines, ANSI/OSC bytes, and bounded large captures produce valid NDJSON and JUnit artifacts with truthful exit/accounting.

- [ ] Extend `hostile_report_actor.py` as needed to emit:

  - invalid UTF-8 before and after printable bytes;
  - NUL, XML-illegal C0 controls, DEL, and C1 controls;
  - quotes, backslashes, `<>&`;
  - a false `Running ... tests for ...` line without a Summary;
  - a capture larger than the configured bound;
  - one final valid TestSuite report for the canonical source embedded by the fake compiler.

  Keep payload construction as bytes and write with `os.write`.

- [ ] Keep `fake_hostile_mojo.py` strict: it accepts the exact order mtest issues—`mojo build <source> -o <binary>` followed by configured include/build arguments—copies/configures the actor into the requested output path, makes it executable, and logs its exact invocation. It rejects every unexpected command/argument rather than silently approximating a compiler.

- [ ] Confirm Task 8 registered the actor in `EXEC_FIXTURES` and the fake toolchain script in any checked toolchain-fixture inventory; do not add a second registry entry.

- [ ] Add one E2E scenario that invokes the real `build/mtest` once with `--show-output all`, `--json <path>`, and `--junit-xml <path>` against the actor. The console safety assertion was already demonstrated red in Task 8. The machine-reporter assertions pin existing intended behavior and therefore require the bypass mutation below as their negative control.

- [ ] Assert:

  - exact process exit and outcome;
  - console contains literal uppercase escape tokens and no raw ESC/NUL;
  - every captured console logical line has `    | `;
  - strict JSON parser accepts the stream, rejects duplicate keys/non-finite numbers, and observes the expected replacement characters/escaped controls;
  - xmllint/XSD accepts JUnit, and the parsed testcase/system-out/system-err values match the reporter’s documented sanitization;
  - the false report lookalike never becomes the selected protocol block;
  - truncation flags and byte counts are exact;
  - the raw output differences between console, JSON, and XML match their separate contracts.

- [ ] Split assertions into the existing reporter scenario modules, but keep one actor/invocation so this is a wiring-intersection test, not three serializer unit tests.

- [ ] Register `hostile-reporters` and update exact E2E ownership/inventory.

- [ ] **Mutation proof.** Perform two independent mutations at reporter call sites—not inside the external oracles: bypass `json_escape` and require the strict JSON stage to fail; restore it, then bypass XML character sanitization and require xmllint/XSD to fail. Restore both and rerun `pixi run e2e`.

- [ ] Commit:

  ```text
  test(e2e): send hostile bytes through every reporter

  Join raw subprocess capture with the shipped console, NDJSON, and JUnit
  wiring so escaping helpers cannot pass while their integration is bypassed.
  ```

---

## Task 10: Expand memory-safety reach from an audited risk map

**Files:**

- Add: `notes/test-memory-risk-map.md`
- Modify: `scripts/checks/memory/asan.py`
- Modify: `scripts/checks/memory/valgrind.py`
- Modify: `scripts/tests/test_asan.py`
- Modify: `scripts/tests/test_valgrind.py`

**Contract:** Every unsafe/native-backed ownership boundary is either exercised by ASan/Valgrind or explicitly justified as unreachable/inapplicable. At least one source-built real CLI run produces machine-report artifacts under instrumentation.

- [ ] Inventory every `# SAFETY:` site from `pixi run safety-check` and map it to ASan, Valgrind, native C tests, or a reasoned exclusion. Include platform fd/path operations, report file ownership/finalization, signal runtime open/close, and native pool cleanup.

- [ ] **Red.** Extend the exact memory inventory tests first. Require the selected suites to include report escaping/JUnit/finalization and the new hostile reporter integration path. Run:

  ```text
  python -m unittest scripts.tests.test_asan scripts.tests.test_valgrind
  ```

  Expected red: risk suites/CLI artifact probe absent.

- [ ] Add `test_report_escape.mojo`, `test_report_json_reporter.mojo`, `test_report_junit.mojo`, and `test_report_junit_finalize.mojo` to the source-built subset where their ownership paths are meaningful.

- [ ] Extend ASan’s existing `check_cli` from `--help` to a fixed, real CLI reporter run that writes NDJSON and JUnit into `build/safety/asan/`, then validate both with the existing strict oracles.

- [ ] Add the equivalent Valgrind CLI probe using the production native object, `--trace-children=no`, and a fixture whose compiler/run children are outside Valgrind scope. Keep `--target-cpu x86-64-v3`.

- [ ] Preserve all current negative controls and exact instrumentation-symbol assertions.

- [ ] Require the new clean Valgrind CLI artifact probe itself to capture and assert Memcheck provenance (`Memcheck`, `ERROR SUMMARY: 0 errors`, the expected fd summary, and client exit 0) in its own log.

- [ ] Run `pixi run asan-check` locally. Run Valgrind where the locked Linux tool is available; otherwise rely on the blocking hosted Linux cell and do not claim that cell green locally.

- [ ] **Mutation proof.** For ASan, replace its instrumented CLI once with uninstrumented `build/mtest` and require the existing ASan-symbol guard to reject it. For Valgrind, temporarily run the new CLI artifact probe directly instead of through the `valgrind` wrapper and require that probe's own Memcheck-provenance assertions to fail; unrelated native controls do not count as proof that this new path was wrapped. Restore and rerun.

- [ ] Commit:

  ```text
  test(exec): extend memory gates to report ownership

  Map unsafe boundaries to executable evidence and make instrumented real-CLI
  reporter finalization part of the blocking memory-safety lanes.
  ```

---

## Task 11: Add macOS installed-package consumption without weakening Linux

**Files:**

- Modify: `scripts/build/package_consumption.py`
- Add: `scripts/tests/test_package_consumption.py`
- Modify: `scripts/checks/layout.py`
- Modify: `pixi.toml`
- Modify: `.github/workflows/ci.yml`
- Modify: `scripts/checks/ci_topology.py`
- Modify: `scripts/tests/test_ci_topology.py`
- Modify: `recipe/recipe.yaml`
- Modify: `AGENTS.md`
- Modify: `README.md`
- Modify: `docs/cli-contract.md`

**Contract:** Both `linux-64` and `osx-arm64` build, install into a clean environment, and consume the exact produced package. The existing `Linux / packaged artifact` job name and Linux behavior remain stable.

- [ ] **Red — platform helpers.** Add unit tests for:

  ```python
  @dataclass(frozen=True)
  class PackagePlatform:
      subdir: str
      loader_command: tuple[str, ...]
      loader_env_names: tuple[str, ...]

  def package_platform(sys_platform: str, machine: str) -> PackagePlatform:
      ...
  ```

  Exact cases:

  - Linux x86_64 -> `linux-64`, `ldd`, scrub `LD_LIBRARY_PATH`;
  - Darwin arm64 -> `osx-arm64`, `otool -L`, scrub `DYLD_LIBRARY_PATH`;
  - every unsupported pair -> `PackageCheckError`.

- [ ] Run `python -m unittest scripts.tests.test_package_consumption`. Expected red: Linux constant and hard-coded paths.

- [ ] **Green.** Replace `GATE_PLATFORM`, `linux-64` globs, `ldd`, and loader-env assumptions with the resolved immutable platform descriptor. Thread `subdir` and the exact built artifact through local channel globs, scratch manifests, tarball globs, installation, and diagnostics.

- [ ] Prove artifact identity after the solve. Constrain the matchspec to the produced version and build string, then read the installed `conda-meta/mtest-<version>-<build>.json` and compare its recorded SHA-256/subdir with the SHA-256 and subdir of the artifact returned by the build stage. Fail if the solver selected a same-version package from a remote channel.

- [ ] Extend installed-binary consumption beyond successful dogfood. Run the installed binary against a fixed failing fixture and assert exact exit 1, the exact FAIL path, and a summary with one failure and no false PASS. Keep the existing passing dogfood membership proof. This makes version, help, passing execution, and failing execution all package-owned evidence.

- [ ] Add a `package-check-macos` task only if the command differs; otherwise reuse `package-check`.

- [ ] Add a separate `macos-package` job depending on `macos-preflight`, using the same locked install and `pixi run package-check`. Keep the current Linux `package` job and display name unchanged so externally configured checks do not drift.

- [ ] Update `ci_topology.py` to require both package jobs, their correct platform runners/needs, and the exact package command. Update topology tests and the recipe comment that currently describes macOS as ungated.

- [ ] Update `README.md` and the package-availability section of `docs/cli-contract.md` in the same commit so they state that installed-artifact consumption is blocking on both `linux-64` and `osx-arm64`.

- [ ] Run:

  ```text
  python -m unittest scripts.tests.test_package_consumption
  pixi run harness-check
  pixi run package-check
  ```

  Expected locally on Linux: full Linux installed-artifact proof remains green.

- [ ] **Mutation proof.** Feed `package_platform("darwin", "arm64")` a descriptor with the Linux subdir or loader environment and confirm its unit test fails. Restore.

- [ ] **Artifact/behavior mutation proof.** Use test doubles in `test_package_consumption.py` to present (a) installed conda metadata whose SHA-256 names a different same-version artifact and (b) an installed mtest that incorrectly exits 0 for the failing fixture. Require the package checker to reject both. Temporarily remove each corresponding guard and confirm its negative control fails, then restore.

- [ ] Push the branch and require both hosted package jobs to pass before completion. A local Linux pass is not evidence for macOS packaging.

- [ ] Commit:

  ```text
  ci(build): consume packages on macOS

  Parameterize the installed-artifact gate by supported platform and add a
  separate macOS package job while preserving the established Linux check.
  ```

---

## Task 12: Record the source-coverage limitation and remove stale count evidence

**Files:**

- Add: `notes/test-confidence-map.md`
- Add: `scripts/checks/coverage_capability.py`
- Add: `scripts/tests/test_coverage_capability.py`
- Modify: `pixi.toml`
- Modify: `scripts/checks/ci_topology.py`
- Modify: `scripts/tests/test_ci_topology.py`
- Modify: `scripts/e2e/__main__.py`
- Modify: comments/docstrings found by the stale-count scan
- Modify: `README.md` only if it contains a hand-maintained test/scenario count

**Contract:** Release confidence is traceable to behavioral evidence. No hand-maintained count is presented as proof, and lack of source/branch coverage in Mojo 1.0.0b2 is explicit.

- [ ] Record the capability probe:

  ```text
  pixi run mojo build --help | rg -i 'cover|profile|instrument'
  pixi run mojo --help | rg -i 'cover|profile|instrument'
  ```

  At Mojo 1.0.0b2 both searches produce no coverage facility. Document that exact pin/result in `notes/test-confidence-map.md`; do not publish a fabricated line percentage.

- [ ] Map each product layer and high-risk intersection to its blocking oracle, mutation proof, and supported platforms. Name any residual risk that remains manual or platform-specific.

- [ ] Add a diagnostic `coverage-capability` Pixi task that runs a small Python probe and has two fail-closed outcomes:

  - when no relevant flags exist, print `Mojo source coverage unavailable at 1.0.0b2; behavioral map applies` and exit 0;
  - when relevant flags are discovered, print the exact flags plus an instruction to evaluate and gate them, then exit nonzero so a toolchain change cannot silently bless an unreviewed metric.

  The task must never silently start emitting an unreviewed percentage after a toolchain change.

- [ ] Unit-test both capability branches by injecting representative compiler-help text: absent flags must produce the pinned unavailable message/exit 0; `--coverage`/`--profile-instr-generate` must be echoed and exit nonzero. Temporarily remove the discovered-flag failure and require the second test to fail, then restore.

- [ ] Add `scripts.tests.test_coverage_capability` to the exact `harness-check` command and `HARNESS_CHECK_MODULES` topology oracle in the same commit.

- [ ] Search for stale manual totals:

  ```text
  rg -n '\b(913|1053|59|72)[ -]?(test|scenario)' README.md AGENTS.md docs scripts tests
  ```

  Remove descriptive totals or derive them from the registry at runtime. Keep `CLASSIFIED_TEST_COUNT` only as the deliberate independent tripwire in `layout.py`.

- [ ] Add a Python test proving the E2E banner total comes from `len(SCENARIOS)` and no module docstring hard-codes a number.

- [ ] **Mutation proof.** Temporarily add a stale numeric count to the checked E2E docstring and confirm the new check fails. Restore.

- [ ] Run `pixi run harness-check` and `pixi run coverage-capability`.

- [ ] Commit:

  ```text
  docs(test): map confidence evidence and coverage limits

  Replace stale count claims with registry-derived evidence and document why
  behavioral and mutation oracles remain necessary at the pinned toolchain.
  ```

---

## Task 13: Run the release proof and adversarial diff review

**Files:**

- Modify only files needed to resolve confirmed review findings.
- Add ignored working record: `docs/plans/test-confidence-hardening-release-evidence.md`
- Do not add generated transcripts unless the oracle side changed; this plan does not authorize that change.

- [ ] Run `pixi run fmt`, inspect every resulting diff, and commit any intended formatting change. Run `pixi run fmt` again, then require both `git diff --exit-code` and `git diff --cached --exit-code` to pass. Inspect `git status --porcelain --untracked-files=all` and allow only these known non-build inputs if they remain untracked: this implementation plan and `notes/phase-04-reconciliation.md`, `notes/phase-04-spike.md`, `notes/skills-simplicity-findings.md`. Any other untracked path—especially under `src/`, `native/`, `scripts/`, `tests/`, or `e2e/`—blocks the release proof. Only then write the exact `git rev-parse HEAD` under test to the release-evidence record. If any later tracked edit, commit, or non-allowlisted untracked file occurs, invalidate the prior record and rerun every claimed check for the new SHA/tree.

- [ ] Run the complete floor serially:

  ```text
  pixi run version-check
  pixi run harness-check
  pixi run safety-check
  pixi run postfork-check
  pixi run native-check
  pixi run junit-check
  pixi run build
  pixi run junit-render-check
  pixi run transcripts-check
  pixi run test
  pixi run dogfood-check
  pixi run e2e
  pixi run contract-check-strict
  ```

- [ ] Run `pixi run ci` as the canonical local chain and capture the real exit code as a separate shell statement.

- [ ] Run Linux ASan and Valgrind with their negative controls. Record Valgrind as pending if it cannot execute locally; do not substitute a different tool or weaken flags.

- [ ] Push and require green:

  - Linux preflight, direct tests, self-hosted tests, strict contract, ASan, Valgrind;
  - Linux E2E;
  - macOS preflight, direct tests, self-hosted tests, strict contract, E2E;
  - Linux packaged artifact;
  - macOS packaged artifact.

- [ ] Record each local command's real exit/result and each hosted required-job URL/status beside that exact SHA in `docs/plans/test-confidence-hardening-release-evidence.md`. The record must distinguish locally executed evidence, hosted-only evidence, and anything still pending; a green result from another commit is not transferable.

- [ ] Request the standing independent full-diff reviews:

  - Claude Opus 4.8, xhigh reasoning;
  - Codex GPT-5.6-sol, xhigh reasoning, danger-full-access.

  Brief both to attack the diff, supply a concrete failure scenario for every finding, rank severity, check transcript fidelity/provenance, exit-code honesty, syntax drift, memory/process cleanup, and unnecessary complexity, and return no finding rather than praise when clean.

- [ ] Triage every finding in a local review record as either fixed or rejected with a concrete technical reason. Rerun the owning focused test plus the complete floor after any fix.

- [ ] Confirm `git diff --check`, `git diff --exit-code`, `git diff --cached --exit-code`, and the same exact untracked-path allowlist over `git status --porcelain --untracked-files=all`; no placeholders; no unexpected generated files; and no changes to the three pre-existing untracked user notes. A dirty tracked tree or non-allowlisted untracked build input invalidates the recorded SHA even if every command passed.

- [ ] Use `superpowers:finishing-a-development-branch` to choose merge/PR/cleanup only after every required local and hosted check is green.

## Plan self-review checklist

- [ ] Every design success criterion has an owning task:

  - blocking release evidence: Tasks 1, 10, 11, 13;
  - concurrency/truncation and ETXTBSY: Task 3;
  - pool faults, signals, fd clamp, executable precedence: Tasks 4–6;
  - hostile text and reporters: Tasks 7–9;
  - inventory and misleading tests: Task 2;
  - source-coverage limitation and risk map: Task 12.

- [ ] Observable product changes occur only in Task 8 and follow red-green-refactor with exact contract documentation.
- [ ] CRLF is tested as intentional drift; transcript format and snapshots are unchanged.
- [ ] Every task identifies exact files, focused commands, expected red/green evidence, mutation proof, and an atomic commit.
- [ ] No unresolved placeholder marker, dependency addition, Mojo pin bump, shell-based product subprocess, or forbidden compiler execution appears in the plan.
- [ ] Interfaces use Mojo 1.0.0b2 syntax (`def`, explicit `raises`, owned values) and public entities require Google-style docstrings.
