# Front-page rework and AGENTS trim — record

## What changed

- `README.md` rewritten for outside readers: 1373 -> ~630 lines. Real recorded
  output only; a frozen exit-code table; a writing-a-test-file example; two
  terminal SVG images generated from live PTY runs of `build/mtest` 0.4.0;
  limits stated as plain facts (maintainer ruling: no roadmap or progress
  narrative anywhere on the page).
- `AGENTS.md` compressed 812 -> ~480 lines: doctrine and lessons kept, narrative
  cut, lessons grouped by area.
- New documentation tool `scripts/maintenance/console_svg.py` (pty_capture
  mold): captures scenarios on a PTY, pins each scenario's expected exit code
  and required output markers, publishes `docs/assets/*.svg` only when both
  hold. Deliberately outside every gate.

## External review

Both reviewers were briefed to attack the two commits, severity-ranked, with
concrete failure scenarios: Claude Opus 4.8 (xhigh) and Codex GPT-5.6-sol
(xhigh). Every finding was re-verified against the tree before folding; all
confirmed findings were fixed, none rejected.

Corrections folded into the README:

- FAIL/CRASH distinctness no longer claims the exit code separates them (both
  are exit-1 class).
- The outcome list now names the real vocabulary (MALFORMED-SUITE,
  PRECOMPILE-ERROR, the FLAKY annotation) and presents NO-TESTS as the
  console's zero-test label, not a typed outcome.
- Installation now says `package-check` verifies into a scratch environment
  and tells the reader how to consume the local channel in their own.
- "Zero runtime dependencies" qualified to third-party dependencies next to
  the declared `mojo-compiler` conda run dependency.
- Added the missing test-file anatomy example (quoting
  `e2e/suite/test_passing.mojo`).
- Transcript regeneration wording restored to cover deliberate fixture edits,
  not only toolchain re-pins.
- SIGKILL-escalation wording scoped to run timeouts (a killed compile does not
  carry the escalated bit; `session/attempt.mojo` latches it only for
  TIMEOUT).
- macOS coverage corrected against the recorded green unified run
  (actions/runs/29908117497): direct, dogfood, and end-to-end suites all run
  and pass on macOS arm64; ASan/Valgrind and the packaged artifact remain
  Linux-only. The Developing section now says the *behavioral* floor is
  symmetric while the full preflight chain is Linux-only.
- `NO_COLOR` documented as disabling `auto` only; explicit `--color` wins.
- The `::stop-commands::` fencing claim scoped to `GITHUB_ACTIONS=true`.
- Collect documented as not narrowing per-test in this build (`-k` ignored
  loudly; a node id contributes its whole file).

Corrections folded into AGENTS.md: restored valid-bit-pattern and
concurrency-assumption clauses in the SAFETY checklist; restored transcript
byte-provenance and the normalizer per-rule line allowlist; restored the
literal ci-preflight chain (fmt-check included); restored the Linux-only
transcript/memory/package topology sentence; restored the exec test-only
`kill(2)` carve-out; recorded that the ICE signature list is assumption-pinned;
fixed a `junit-render-check#` spacing typo inherited from the original.

Corrections folded into the SVG tool: total monotonic capture deadline with
process-group kill, `NO_COLOR`/`GITHUB_ACTIONS` scrubbed from the child env,
expected-exit and marker validation before any file is written, and a stderr
warning for SGR codes outside the mapped red/green/yellow palette.

## Provenance

Console captures and images were generated against `build/mtest` 0.4.0 in this
checkout; the quoted text examples predate this rework and are unchanged
recorded output. The stale `notes/console-captures/*.ansi` files (they still
carry a 0.1.0-dev header) were left untouched; regenerate with
`python -m scripts.maintenance.pty_capture` when convenient.
