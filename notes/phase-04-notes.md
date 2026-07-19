# Phase 4 notes — reporters

## Manual phase-exit gate: real-Actions annotation rendering

Everything about `--gh-annotations` is verified in-repo without a network: the
unit tests pin the renderer shapes, the sort, the caps, and the escaping; the
console tests pin the stop-commands fencing; `scripts/annotations_check.py` is
the local proxy for what GitHub itself does with the workflow-command lines; and
the e2e cells drive the real binary end to end (mode resolution, the caps, the
`--json -` conflict, and the hostile-console fencing with a forged command and a
seeded resume delimiter).

What the in-repo gates **cannot** prove is that GitHub's own Checks runner places
the inline annotations where we expect and neutralizes a fenced forge exactly as
the local proxy models it. That is a **manual, out-of-band step for the
maintainer** and it **blocks the phase's final report**. Nothing here pushes,
publishes, or dispatches anything — running it is the maintainer's call, in the
maintainer's fork, on the maintainer's push.

### Checklist (maintainer runs this by hand)

1. **Package the binary.** `pixi run build-bin` and confirm `build/mtest` runs
   locally (`./build/mtest --version`).
2. **Stand up a deliberately-failing tree.** A throwaway directory with:
   - a file with two or three ordinary per-test `assert` failures (the `::error`
     rows, with `line=` taken from the `At <path>:<line>:<col>:` detail);
   - a file that crashes or times out (a file-level `::error` with no `line=`);
   - optionally a flaky file under `--retries 1` (the `::warning` row);
   - a file whose test prints a **forged** `::error …` line and a **seeded**
     `::stop-commands::<guess>` / `::<guess>::` pair to its own stdout (the
     hostile-console case — the same shape as
     `e2e/annotations/test_console_forger.mojo`).
3. **Run with annotations on.** `mtest --gh-annotations on --show-output all
   <tree>` (or `--gh-annotations auto` with `GITHUB_ACTIONS=true` set). Confirm
   locally, before pushing, that stdout ends with the per-kind-grouped tail
   (node-id-sorted `::error` block, then `::warning` block, then one `::notice`)
   and that every echoed captured region is wrapped in `::stop-commands::<token>`
   … `::<token>::` with a fresh 128-bit token per run.
4. **Add a throwaway workflow.** A minimal job in the maintainer's own fork that
   checks out the failing tree, builds `mtest`, and runs step 3 as a normal
   build step (so its stdout is the step's stdout GitHub scans).
5. **The maintainer's push, the maintainer's run.** Push to the fork, let the
   throwaway workflow run, and open the run in the GitHub UI.
6. **Confirm, in the real Checks UI:**
   - the per-test `::error` rows land as inline annotations on the right files
     and lines; the crash-class and flaky rows land as file-level
     error/warning annotations; exactly one `::notice` summary appears;
   - the caps hold (no more than ten error and ten warning annotations for the
     step, with the `… and N more …` aggregate line accounting for the rest);
   - the **forged** `::error` from the hostile file does **not** appear as an
     annotation (it was sealed inside the stop-commands fence), and the
     **seeded** resume delimiter did not re-enable commands early;
   - workflow commands are re-enabled before mtest's own tail (the always-runs
     epilogue), so mtest's real `::error`/`::notice` lines are processed.
7. **Tear down** the throwaway workflow and tree. Record the run URL (or a
   screenshot) in the phase's final report as the evidence that the manual gate
   passed.

Until step 6 is confirmed by the maintainer, the phase's final report stays
open on this item.

## Console polish pass — user-visible message audit

A recursive inventory of every USER-VISIBLE message / output site, its verdict
(keep / fix / exclude), and the rationale. "User-visible" means bytes a person
running `mtest` (or a product-facing tool) can read on their terminal — not
machine contracts, not gate tooling, not test fixtures.

### Scope audited

- **All of `src/`**, recursively: `src/main.mojo` (the pre-session
  internal-error prints), the console reporter, the annotations renderer, the
  session's warnings and pre-session raises, and the exec diagnostics that reach
  a human through the console's `INTERNAL-ERROR` banner.
- **`native/`** — the C adapter, for any bytes it writes directly to a user.
- **Product-facing `scripts/`** — messages a person sees when they run a script
  as a tool (not the CI gates' own PASS/FAIL lines).

### Classified exclusions (named, with why)

- **The transcript/protocol ORACLE — `tests/snapshots/protocol/**` and its
  gates. UNTOUCHABLE**, byte-frozen. No polish may alter an oracle byte; a fix
  that would need one is out of scope by rule.
- **`MODEL` (`src/mtest/model/**`) and `exec/` + `native/` — FROZEN** by the
  brief. `exec/`'s `raise Error("exec: …")` diagnostics DO reach a user (via the
  console `INTERNAL-ERROR` banner), but the strings live in a frozen layer, so
  they are audited-but-excluded from edits. `native/` writes no diagnostic bytes
  of its own — every failure is returned as an errno/status code and rendered by
  the Mojo layer — so there is nothing user-facing to change there.
- **Machine-contract formats** — `json_stream.mojo` / `json_stream_reporter.mojo`
  (the NDJSON stream) and `junit.mojo` / `junit_reporter.mojo` (the JUnit XML).
  These are byte-stable machine contracts consumed by other tools, not human
  prose; polishing their wording would be a contract change, not a console
  polish. Excluded. (The JUnit `message`/`type` attributes are classification,
  guarded by the `junit_canonicalize.py` invariant noted in Fix 2.)
- **CI gate tooling in `scripts/`** — `e2e_check.py`, `junit_check.py`,
  `harness_check.py`, `safety_check.py`, `postfork_check.py`, `native_check.py`,
  `asan_check.py`, `valgrind_check.py`, `main_open_check.py`, `build_*`, etc.
  Their `OK`/`FAIL` lines address the maintainer/CI, not a product user; they are
  gate infrastructure, not the shipped console. Excluded as not-product-facing.
- **Test-only strings** — `tests/**` and `e2e/**` fixture docstrings and
  assertion text. Test scaffolding, never shipped. Excluded.
- **No internal debug-only user paths were found** — there is no hidden
  `--debug`/verbose-trace channel emitting to users beyond the audited surfaces.

### Audit table

| Site / class | What it is | Verdict | Rationale |
|---|---|---|---|
| `src/main.mojo` collect-fault `except` (`run_collect`) | pre-session internal-error print before exit | **FIX** | On a secondary `_close_runtime` failure it exited 3 WITHOUT printing the primary diagnostic — the operator lost the "why". Moved the primary `_eprintln` above the close check so both close paths print it. |
| `src/main.mojo` `--json` open-fault `except` | pre-session internal-error print | **FIX** | Identical dropped-primary defect; same minimal reorder; removed the dead `return` after `exit(3)`. |
| `src/main.mojo` `--junit-xml` open-fault `except` (the named known item) | pre-session internal-error print | **FIX** | The brief's known item: print the primary `junit_error` on BOTH the clean-close and failed-close paths; removed the dead `return` after `exit(3)`. |
| `src/main.mojo` `run_session` propagated-usage-error `except` | pre-session/boundary print before exit 4 | **FIX** | Same dropped-primary defect on the secondary-close path; same minimal reorder. |
| `src/main.mojo` `runtime.open()` fault `except` (lines ~124-142) | internal-error print | **KEEP** | Already prints the primary on both close paths (`primary` / `primary; cleanup`); it is the correct model the four fixes above were aligned to. Pinned by `scripts/main_open_check.py` — untouched. |
| `src/main.mojo` help/version/usage-error seam prints | help text, version, usage error to stderr exit 4 | **KEEP** | Consistent and correct; documented seam exceptions. |
| `src/mtest/report/console.mojo` verdict tokens, banners, sections, summary band, warnings, TRY/ATTRIBUTION lines, DRIFT/PRECOMPILE/COMPILE-TIMEOUT banners, slowest-files list | the entire human console design language | **KEEP** | Reviewed end-to-end: fixed glyph-free ASCII vocabulary, color redundant to the tokens, consistent phrasing, honest disposition notes. No wording defect found; polishing working prose here would be churn. |
| `src/mtest/report/annotations.mojo` module docstring | the `file=` path root convention | **FIX** | The `file=` values are run-root-relative and GitHub anchors them at the repo root; that convention was only inherited transitively. Stated it explicitly in the docstring. (No emitted line changed.) |
| `src/mtest/report/annotations.mojo` emitted `::error`/`::warning`/`::notice` lines | workflow-command payloads | **KEEP** | Unit-pinned shapes, caps, sort, escaping. Correct and consistent; not touched. |
| `src/mtest/report/annotations_reporter.mojo`, `composite.mojo` | thin sinks / fan-out | **KEEP** | No user prose of their own. |
| `src/mtest/session/session.mojo` warnings (`stale-exclusion`) + drift/precompile facts | session facts routed through console events | **KEEP** | Rendered by the console; wording consistent. |
| `src/mtest/session/session.mojo` double-fault raises (`primary` / `primary; cleanup`) | error-propagation strings | **KEEP** | Already preserve the primary on both cleanup paths — the correct pattern; no defect. |
| `src/mtest/cli/parser.mojo`, `help_text`, `version_text` | usage errors + help/version | **KEEP** | Audited; consistent, self-describing. No defect. |
| `src/mtest/exec/**` `raise Error("exec: …")` diagnostics | surfaced via the console `INTERNAL-ERROR` banner | **EXCLUDE** | Reaches a user, but lives in the FROZEN exec layer. Audited, not edited. |
| `native/mtest_exec_native.c` | C adapter | **EXCLUDE** | FROZEN, and writes no user-facing diagnostic bytes (errors returned as codes). |
| `scripts/junit_canonicalize.py` mask site | determinism-tool, user-runnable | **FIX** | Added a one-line invariant comment: only `time` + volatile text bodies are masked; `message`/`type` attributes ride through, so a volatile value FAILS the e2e loudly rather than passing silently. |
| `scripts/junit_canonicalize.py` `OK`/`FAIL` result lines | tool output | **KEEP** | Clear and consistent. |
| `e2e/manifest.json` two annotation fixtures | spec-of-record disposition tokens | **FIX** | Both used `"disposition": "VALID"`, absent from the file's own `disposition_meaning` map. Changed both to `"PARSED"` so the spec is self-consistent (documentary only; no script consumes the value). |
| other `scripts/*` (gate tooling, build scripts) | maintainer/CI messages | **EXCLUDE** | Gate infrastructure, not the shipped product console (see exclusions). |

### PTY/ANSI captures (R11(a))

`scripts/pty_capture.py` drives the built binary under a real PTY and records the
console's raw ANSI output for representative scenarios into
`notes/console-captures/` (`pass-pty`, `fail-pty`, `fail-verbose-pty`,
`fail-quiet-pty`, `fail-nocolor-pty`). These are DOCUMENTATION of the console's
real appearance, deliberately NOT wired into any gate — see that directory's
`README.md` for what each shows and how to regenerate. PNG screenshots remain an
OPTIONAL maintainer step, documented there, not produced here.
