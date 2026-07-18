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
