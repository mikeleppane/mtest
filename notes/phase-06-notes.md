# Phase 6 notes — developer experience

The durable record for the developer-experience phase: project configuration in
`mtest.toml`, failure re-selection through `--lf`/`--ff` over a persisted
last-run state, the `config show` and `doctor` inspection subcommands, grouped
help with a drift gate that keeps README honest, and the mid-phase decision that
replaced a Python configuration boundary with a vendored native TOML parser. The
phase branched off main `0c17bf2` (after PR #11, the Phase 5 review triage, had
merged) and ships version 0.6.0.

Everything here was internal-first by design: behavior landed and was tested
before the surface that reaches it. `mtest.toml` parses and validates in commit
3, resolves with provenance in commit 4, drives per-file overrides in commit 5,
and persists state in commit 6 — and only in commit 7 does a file on disk change
what a run does. The same pattern the pool phase used for `-n`.

## The reconciliation gate — and a process defect worth fixing

The phase opened with a ten-item read-only reconciliation STOP gate against the
post-Phase-5 tree. It did not stop the phase: execution proceeded to the spike
commit the same day.

**Only one of the ten answers survives in writing.** Item 6 (session anchors)
was recorded in the planning material, dated 2026-07-23: selection remains a
truthful one-worker `_run_selection` path, so selection-active `--ff` uses one
sequential post-gate band with failed files first across that band and discovery
order inside each half; `-n 2` still resolves to one worker and `--serial`
remains a no-op there. The composition oracle pins that shape, and commit 8
implemented exactly it.

The other nine answers were produced in execution sessions and never written to
a file. That is a process defect, not a content one — the plan said "record dated
answers in your working notes (they land in notes/phase-06-notes.md)", and
deferring the write until the notes commit at the end of the phase lost them.
**The fix for next phase: the reconciliation commit is the first commit, not a
paragraph written fourteen commits later.** A gate whose answers are not durable
cannot be audited afterward, and re-deriving them from the finished tree proves
only that the tree is self-consistent, never what the gate actually found.

What can be stated as fact is the as-landed baseline that supersedes those
answers and is the reference for the next phase:

| Pin | As landed |
| --- | --- |
| `CLASSIFIED_TEST_COUNT` | 1194 |
| E2E scenarios | 85 |
| Dogfood probes | 3 |
| ASan lane | the exec probe against the instrumented production adapter |
| Version | 0.6.0, four agreement points |

## The tomllib bridge — built, then deliberately replaced

This is the phase's largest decision and it reversed a planned one.

The plan committed to parsing `mtest.toml` through CPython's `tomllib` over a
lazy `PythonObject` bridge, on the reasoning that the Mojo toolchain already
brings CPython and that a stdlib parser beats a hand-rolled one. The phase
opened by proving that premise rather than assuming it: commit 1
(`chore(maintenance): the tomllib interop spike`) landed a production-shaped
probe — `scripts/maintenance/tomllib_spike.py` plus its bridge and probe Mojo
sources — that exercised the interop in both the development environment and a
fresh package-consumption prefix, checked that a config-free run does not map
libpython, and measured first and warm startup cost. No leg failed — the plan
made any failure a STOP, and execution continued — and commits 3 through 6 built
the real loader on it. The measured startup figures went the way the
reconciliation answers did: reported in an execution session, never written to a
file. The bridge's removal made them moot rather than merely lost, but the
omission has the same cause.

Commit 7 replaced it. `src/mtest/config/toml_bridge.mojo` was rewritten from a
Python boundary into typed conversion over a **vendored native parser**, and the
Python product boundary was deleted outright.

What that bought, stated as checkable facts rather than preference:

- **The conda recipe declares no Python run dependency.** The plan's
  `python >=3.11` addition — needed because `tomllib` is stdlib only from 3.11,
  while the inherited chain floor was 3.10 — was never required. `mojo-compiler
  ==1.0.0b2` remains the sole run dependency, exactly as before configuration
  existed.
- **`src/` stayed pure Mojo.** The doctrine amendment that would have named an
  interop module as the one exception was not needed; AGENTS.md instead reads
  that project configuration is parsed by the pinned, vendored native parser.
- **The laziness obligation disappeared rather than being satisfied.** The whole
  apparatus the plan designed around it — the PYTHONHOME initialization pins on
  five invocation paths, the Linux alive-maps mapping oracle over the built and
  installed artifacts, the "never initializes" README verb chosen carefully to
  not over-claim past its oracle — exists to prove that a config-free run does
  not pay for a dependency it does not use. A parser compiled into the binary
  cannot be lazily initialized because there is nothing to initialize.

The lesson is not "the spike was wasted". The spike is what made the replacement
safe to choose: it converted "CPython interop probably works" into a measured
result, which is exactly what let the alternative be evaluated on its merits
instead of on fear. The trap it avoided is the one the plan review had already
named — an intermediate package that solves Python 3.10, passes a
`--version`-only smoke test, and crashes the first time a user writes an
`mtest.toml`.

## The vendored parser: provenance and hardening

`vendor/mojo-toml/` carries the parser-only portion of DataBooth/mojo-toml
v0.9.1 at release commit `346b7ad7`, with upstream `main` (`c3262ade`) recorded
as byte-identical in lexer, parser, initializer, and license at adoption time.
Retained: `toml/lexer.mojo`, `toml/parser.mojo`, a `toml/__init__.mojo` reduced
to parser exports, and the Apache-2.0 `LICENSE`.

`CHECKSUMS.json` is a three-way record, and the shape is the point: it pins the
authorized release digests, the upstream `main` digests, and — separately — the
digest of every retained file *after* the local patches. The harness recomputes
the local digests. A vendored dependency that records only upstream hashes
cannot tell you whether the bytes you compile are the bytes you reviewed.

The local changes are hardening plus a syntax port, all enumerated in
`vendor/mojo-toml/README.md`: Mojo 1.0.0b2 syntax, parser-only exports, strict
numeric-token and signed-64-bit validation, depth/node/table-update budgets,
duplicate table/key/inline-table rejection, TOML 1.0 escape handling with
positioned lexer failures, terminated control-free strings, and pre-lexer
scalar/structural/depth budgets. The production build precompiles this source
locally and downloads nothing.

`toml_bridge.mojo` keeps a strict division: the vendored parser owns TOML syntax
and generic values; the bridge owns every accepted table, key, type, domain, and
diagnostic, is pure Mojo, and performs no process or file I/O. The budgets it
enforces on top (4 MiB source, depth 64, 1024 nodes, 64 table updates, 1 MiB
scalars) are mtest's, not the parser's.

## The diagnostic boundary and the sentinel test

A configuration diagnostic is mtest-owned framing. The corpus in
`tests/unit/test_config_file.mojo` and
`tests/unit/test_config_toml_adversarial.mojo` exercises every accepted table
and key family and rejects unknown ones, but the load-bearing assertion is the
**sentinel leak test**: a hostile config value carrying an embedded newline and
a forged `FAIL config:` line must render as exactly one physical line, with C0
controls escaped, and must not be able to impersonate a second diagnostic. The
test asserts both directions — the escaped form present, the raw form absent —
because an escaping bug that only drops the payload would pass a
presence-only check.

## The active-key projection

The rule that keeps a project config from breaking `collect`: each command
validates and consumes only its own active key set.

Under `collect`, an explicitly supplied inapplicable CLI flag still exits 4
first — mode-applicability refusals are CLI-presence checks, and the overlay's
presence bits are the evidence. Config-sourced run and report keys are then
excluded from both behavior *and* cross-value validation. The exact oracle is a
configured tree with `[report] json = "-"` and annotations left at default:
`mtest collect` succeeds, where a naive re-check of the whole resolved config
would have inherited the stdout conflict and exited 4. A project's `[run]
retries = 1` must not break `mtest collect`, and neither may a conflict between
two keys `collect` ignores.

## Last-run state: what the merge rule protects

The state file is written by `main`, after the final exit code resolves, and
only for 0 or 1. Codes 2, 3, 4, and 5 leave prior bytes untouched, as do
`collect`, `config show`, `doctor`, sharded runs, and `[run] state = false`.
That placement is forced: `main` can escalate 0/1 to 3 through the resource
close ladder *after* the session finishes, so "write at session end" would
persist state for runs that ended internally broken.

The preservation merge is the part worth remembering. A write records fresh
verdicts and **preserves** entries for files and tests that received no verdict
this run. The scenario that forced it: state holds {A, B}; `--lf -x` observes A
failing and stops; B was never reached. An observed-only write would drop B —
destroying a failure you have not retested yet, on the exact iteration loop the
feature exists to serve. A fully green run over the full selection still clears
state naturally, because every entry got a verdict.

`[run] state = false` disables both directions — no writes, and `--lf`/`--ff`
take the loud fallback naming the key. The writes-only alternative was
considered and rejected: an accelerator feeding on state nothing refreshes gets
progressively wronger, which is worse than no accelerator.

The publish path uses an exclusively created same-directory temporary and
retries an interrupted write without an arbitrary ceiling, so a collision or a
persistence fault preserves prior bytes and never changes the exit code. Not
`mkdtemp` — Mojo 1.0.0b2's is unseeded and unsafe in shared temp directories.

## The soft filter

`--lf` and `--ff` never turn stale state into a usage error. Persisted ids do
not enter the qualified CLI-selection lookup at all, which is the mechanism, not
a promise: an id that cannot reach the lookup cannot produce exit 4 from it.
Missing files and missing tests drop individually with one escaped line each;
missing, empty, malformed, all-stale, or empty-intersection state prints one
fallback line and runs the ordinary full selection rather than exiting 5.

Gates are never filtered or reordered by either mode. `--ff` never narrows or
validates persisted names — file and test records both mark their discovered
file at file granularity — and applies its stable partition independently to the
parallel and serial bands, so serial membership never changes.

## Doctor diverges on purpose

`doctor` treats a missing, unreadable, malformed, or invalid selected config as
a **failed check and exit 1**, where `run` and `config show` refuse the same
input as a usage error and exit 4. This is deliberate and documented as a
contrast, not an inconsistency: a diagnostic command that refuses to run because
the thing you asked it to diagnose is broken is useless.

Two structural properties support it. Every check body is guarded independently,
so an unexpected error becomes that check's contained FAIL with control
characters escaped and later checks still run; dependent checks say which
earlier capability was unavailable. And the fixed ten-line inventory never
shrinks — `--color`, `-q`, and `-v` are accepted for consistency but may not
suppress, duplicate, or add a line, because in a completeness-critical report the
missing line is the one you needed.

The exit domain `{0, 1, 2, 4}` is scoped to exits doctor resolves inside its
guarded lifecycle. Runtime close restores signal dispositions in sequence, so
there is a disclosed handoff window — beginning as soon as a disposition is
restored and continuing through process exit — in which a signal may follow the
restored disposition instead. Doctor samples the interrupt latch immediately
before and immediately after restoration and renders the whole block with one
stdout write. The window is documented rather than papered over.

## Grouped help and the drift gate

Help is generated from the parser's flag table, so every accepted spelling
carries its value label, one-line purpose, and section. The quality bar is
testable rather than aesthetic: every row renders exactly once with non-empty
help text (a coverage test walks `flag_specs()`), columns align, two spellings
of one id render as one row, and no rendered line exceeds 78 columns.

The more durable addition is `scripts/checks/readme_help.py`, wired into
`ci-preflight` immediately after `build`. README carried a promise — "this
section is generated against `build/mtest --help` and is not allowed to drift
from that output" — that was enforced by nothing but intention. The gate
extracts the fenced block and byte-compares it against the real binary. A
promise a machine checks is a different object from a promise a reviewer checks,
and this one was mutation-proven: perturb one byte in the README block, watch it
red, revert.

## Deviations from the plan

- **The tomllib bridge was replaced mid-phase** (above). Commits 1 and 3–6 built
  it; commit 7 removed the Python boundary. Every plan artifact that depended on
  it — the recipe's `python >=3.11`, the five PYTHONHOME pins, the alive-maps
  oracle, the two README dependency sentences' agreed wording — resolved to
  "not needed" rather than "done".
- **One unplanned commit.** `ci(ci): keep ASan on the exec boundary` landed
  between commits 8 and 9. Once the full CLI imported the vendored parser, the
  sanitizer lane would have pulled TOML into its instrumentation surface; ASan
  exists here to cover mtest's native process-supervision risk, so the lane was
  repointed to build and execute the dogfood exec probe against the instrumented
  production adapter, with fault controls and the suite inventory unchanged. TOML
  is deliberately outside ASan instrumentation.
- **The README console images are one version stale.** `docs/assets/mtest-run.svg`
  and `mtest-flaky.svg` still render `mtest 0.5.0`. They are generated by
  `scripts/maintenance/console_svg.py`, which bakes the generating checkout's
  absolute root into the image; regenerating from a worktree would replace the
  repository path with a worktree path, which is a worse artifact than a stale
  version string. They are documentation, wired into no gate. Regenerate from the
  primary checkout after merge.

## Per-task lessons

- **Prove the premise before building on it, and let the proof change the
  answer.** The spike existed to de-risk the bridge and ended up enabling its
  replacement. A spike that can only confirm the plan is not a spike.
- **A dependency you vendor needs three digests, not one.** Upstream release,
  upstream main, and the local post-patch bytes. Only the third tells you what
  you actually compile.
- **Record gate answers when the gate runs.** Nine of ten reconciliation answers
  were lost to deferral. Cheap to fix, impossible to reconstruct.
- **Presence bits are what make applicability rules implementable.** The
  active-key projection, honest color provenance, and CLI-beats-overrides all
  reduce to "did argv actually say this?" The parser had nine `saw_*` bits before
  this phase; the typed overlay generalized them, and that one refactor is what
  the later three features stand on.
- **A soft filter must be soft in its mechanism, not its intent.** `--lf` cannot
  exit 4 on stale state because persisted ids never enter the raising lookup —
  not because a caller remembers to catch.
- **Write ownership follows the final exit code.** State persistence had to move
  to `main` because the exit code is not final until after the close ladder.
- **`git diff --exit-code` in a format gate means staged-or-committed.** The
  local `fmt-check` fails on any unstaged change, so a documentation edit made
  after a CI run starts silently invalidates that run's result. Stage first, then
  gate.

## Whole-branch review triage

Pending. The standing per-phase gate is a dual adversarial review of
`git diff main...phase-06-dx` — Claude Opus 5 at xhigh and Codex GPT-5.6-sol at
xhigh, both briefed to attack the work rather than admire it, with concrete
failure scenarios per finding, severity ranking, and silence meaning no finding.
Every finding is triaged fixed or rejected-with-reason in this section before
merge.
