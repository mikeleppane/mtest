# Phase 0 notes — scaffold, the CLI contract, and the TestSuite oracle harness

Phase 0 stands the project up without writing any runner logic. What it delivers
is the harness and the spec: committed TestSuite probe fixtures, normalized
protocol snapshots that pin TestSuite's real per-file protocol at the pinned
toolchain, a regenerate-and-diff CI gate, a Mojo smoke test that parses those
transcripts and reconciles their counts, the committed v1 CLI contract, and —
the one precondition the whole product stands on — the verdict of a subprocess
supervision feasibility spike. `src/mtest/` is an empty package that compiles;
that is the correct state for this phase, not a placeholder to fill.

## Decisions as executed

- **Identity and layout.** Repo at `~/dev/mtest`, package `src/mtest/`, future
  binary `mtest`, branch `main`. The scaffold commit is `main`'s root; the rest
  of the phase is on `phase-00-scaffold`, merged `--no-ff` at the end.
- **License:** MIT.
- **Pins:** `mojo ==1.0.0b2`, `python 3.12.*` (build-time scripts only), donor
  channels, platforms `linux-64` **and** `osx-arm64`, **zero runtime
  dependencies**.
- **CLI parsing will be hand-rolled** (a later phase), behind a config seam.
  `prism` was evaluated and rejected on source evidence at its 1.0.0b2-pinned
  release: a bare `--` enters flag parsing and raises (there is no pass-through
  mechanism), and repeated flags space-concatenate into one string that list
  retrieval re-splits on spaces, so a value containing a space corrupts and
  repeated scalar flags silently concatenate. A follow-up proposal to keep prism
  behind a pre-splitting adapter was **also** rejected: that adapter is the hard
  20% of a parser (pass-through, repeatables, subcommand detection), it would
  keep prism's silent scalar-concatenation footgun for every flag it did not
  pre-consume, and it trades the zero-dependency stance for the easy 80%. Revisit
  only if prism ships native post-`--` pass-through.
- **The oracle harness:** committed `tests/fixtures/protocol/` + normalized
  transcripts under `tests/snapshots/protocol/` + `MANIFEST.txt` + a
  regenerate-and-diff gate. Every
  transcript header carries the resolved mojo version and commit, the os/arch,
  and the normalizer version, so a regeneration on a different toolchain or a
  foreign platform diffs loudly at the header by design.
- **Run model:** build each file, execute the binary directly; never `mojo run`
  in the gate. This repo's own `test` task obeys the same rule.
- **Normalization is anchored, versioned (`v1`), and minimal.** Every rule names
  the exact lines it may touch; over-normalization is treated as a defect on par
  with nondeterminism.

## The subprocess feasibility spike — VERDICT: FEASIBLE

Building the process supervisor from Mojo on this toolchain is feasible via
direct POSIX FFI (`std.ffi.external_call`). A throwaway spike proved, on Linux,
the full supervisor checklist:

- separate, byte-exact stdout/stderr capture, with arguments containing spaces
  and empty strings surviving unchanged and trailing spaces preserved;
- concurrent draining of both streams via `poll`, so large simultaneous output
  cannot pipe-deadlock (drained ~159 KB per stream with no hang);
- a timeout enforced as terminate-signal → grace → hard-kill (killed a 300 s
  sleep in ~400 ms);
- a **process-group** kill that reaches a grandchild — proving both that the
  descendant dies and *why* the group kill is mandatory: a grandchild inherits
  the redirected pipe write end, so killing only the direct child would leave the
  parent's read blocked forever. EOF on both pipes is the completion signal
  precisely because the group kill closes every inherited write end;
- exit-status vs terminating-signal discrimination from the wait status;
- cwd control;
- several children running concurrently.

The working shape (the seed of the `exec` module): build the argv array and all
C strings in the **parent**, `fork`, and in the child call only async-signal-safe
functions — `setpgid(0,0)`, optional `chdir`, `dup2` the pipe write ends onto
1/2, close the pipe fds, `execvp`, `_exit(127)`. In the parent, close the write
ends and `poll` both read fds with a short slice so the deadline is re-checked
mid-drain; on timeout `kill(-pid, SIGTERM)` then, after a grace period,
`kill(-pid, SIGKILL)`; drain to EOF; `waitpid`; decode the status. `/bin/sh -c`
redirection is not a substitute.

**Traps recorded:** re-declaring `write` through `external_call` collides with
the stdlib's own `write` external declaration (conflicting signature) — read
back with `read` and build a `String` instead. String→C-string is
`s.as_c_string_slice().unsafe_ptr()`; bytes→String is
`String(StringSlice(unsafe_from_utf8=Span(list)))`. A pointer parameter written
`UnsafePointer[T, _]` is immutable — write struct fields where the pointer has
its concrete allocation origin.

**Adjacent answers:**

- **Module-cache quarantine:** `MODULAR_CACHE_DIR` redirects the compile cache
  (default at `.mojo_cache`; verified that setting it moves the cache). A
  post-kill retry build points it at a per-attempt temp dir. `--clear-cache` and
  `--print-cache-location` also exist.
- **A Mojo test can print to stderr:** `from std.sys import stderr; print(...,
  file=stderr)` writes to fd 2 (verified with stream separation). The noisy
  fixture uses it.
- **`mojo build` exposes a compiler-thread flag:** `--num-threads N` / `-j`,
  default 0 = all threads. So the build is multi-threaded and parallel worker
  sizing must not oversubscribe.

**Honest gaps:** parent-SIGINT cleanup was not exercised in the spike — the kill
primitive (a group kill over tracked children) is proven; the remaining piece is
a signal handler that flips a flag the poll loop checks. macOS was not run; it
rests on the same POSIX surface and is recorded as an assumption until a macOS
runner exists. `posix_spawn` with file-actions/attr is the fork-free alternative,
but the stdlib's `posix_spawnp` passes NULL for both, so `fork`+`exec` is the
route on this toolchain.

## Protocol facts pinned this phase (observed live)

- **Discovery order is source order** — the fixtures use non-alphabetical
  function order to make it a gate.
- **The report is buffered and flushed as one block** at the end: printed on
  success, *raised* on failure so it arrives as the payload of the runtime's
  `Unhandled exception caught during execution:` line (observed on stdout). User
  prints stream first, so the parser anchors on the **last** `Running <N> tests
  for` line.
- **Native skip API exists** (`suite.skip[f]()`, manual construction form); a
  natively-skipped test emits a normal `SKIP` line. The `skipped.mojo` fixture
  and its transcript are therefore included (19 transcripts, not 18).
- **A bare `abort()` emits no `ABORT:` line** — the crash fixture passes a
  message. The crash's `ABORT:` line lands on **stdout**; the stack dump on
  **stderr**; the process dies by **SIGILL (signal 4)** (exit 132 at a shell).
- **The stack dump has two forms** depending on whether llvm-symbolizer is on
  `PATH` — a symbol-less `Stack dump …` header + `N module 0xADDR` frames, or a
  symbolized `#N 0xADDR sym file:line` set that leaks the binary and library
  paths. The normalizer collapses both to `<STACK-DUMP>` and asserts every
  collapsed body line matched a frame pattern, so a new line shape fails
  generation loudly rather than leaking.
- **A malformed `test_` function** (e.g. one taking an argument) is neither a
  compile error nor a silent exclusion: it raises a discovery-time runtime error
  (`test function '<name>' has nonconforming signature`). Recorded here rather
  than made a snapshot, to keep the matrix at exactly the enumerated scenarios.
- **The report colorizes only on a TTY.** Captured through a pipe it is plain
  text; the transcripts and the eventual parser see plain text.

## The anchored normalizer

Three rewrites, and only three, touch captured content: timing tokens collapse to
`[ T ]` **only** on report-grammar lines at or after the last `Running` anchor
(so the noisy fixture's printed report-lookalike line stays byte-exact — this is
why first-match scanning is wrong); the baked absolute repo-root prefix becomes
`<REPO>`; and the crash stack dump collapses to `<STACK-DUMP>`. The generator
hard-asserts matrix completeness, per-scenario structural pins (skip-all listing
equals the fixture's test names, crash terminates by signal, the noisy
lookalikes survive byte-exact), count reconciliation, the framing guard (no
captured line starts with `--- `), the absence of any absolute path, and
byte-identical double generation.

## Proofs

- **The gate bites (flipped byte).** Editing `tests/snapshots/protocol/
  crashing--default.txt` to read `termination: signal 5` turned
  `transcripts-check` red with a precise diff (`-termination: signal 5` /
  `+termination: signal 4`); `git checkout` of the file restored green. Hand-edits
  are exactly what the gate is built to catch.
- **The definition of done (fresh clone).** Cloning the branch tip to a different
  absolute path (`/tmp/mtest-freshclone-*`), then `pixi install` → `pixi run ci`,
  is green. Because the clone lives at a different absolute path, this also proves
  the normalization: any leaked absolute path would have turned
  `transcripts-check` red at the new location. It did not.

## Deviations from the intended shape of the phase

- The README's phase roadmap was removed at the human's request; the roadmap
  lives in the CLI contract and the working plans instead.
- No `.claude/skills` directory was created (at the human's request). The
  canonical skills live under `.agents/skills/` only.
- The transcript smoke test was written after the generator rather than strictly
  first; the transcript format was locked empirically against the live toolchain
  before either was written, and the commit order keeps every commit green.

## Toolchain surprises

- `mojo package` does not exist in 1.0.0b2 — only `mojo precompile`, which warns
  that `.mojopkg` is deprecated in favor of `.mojoc`. The name is kept so
  `-I build` resolves `from mtest import …`.
- FFI: `external_call` and the C types live in `std.ffi`; the POSIX bindings the
  stdlib already ships (`std.sys._libc`) do not cover redirection or process
  groups (`posix_spawnp` passes NULL file-actions/attr), which is why the
  supervisor goes straight to `external_call`.

## External review triage

The external dual-review gate hit tooling friction this phase. The first attempt
at both reviewers was orphaned when the session was interrupted mid-run,
producing no findings. On the retry the Codex run was dropped at the
maintainer's direction, and the maintainer directed proceeding to the merge; the
Opus 4.8 (xhigh) review then completed just after the merge and its findings were
triaged as post-merge follow-ups on `main`. The merge itself rested on the
automated gate plus a maintainer self-review; the automated basis was:

- `pixi run ci` (fmt-check → build → transcripts-check → test) green on a clean
  tree.
- The flipped-byte proof (the gate goes red on a hand-edited transcript) and the
  fresh-clone proof (`pixi run ci` green at a different absolute path, proving no
  leaked absolute path).
- A self-review of the generator/normalizer with adversarial probes: a
  report-lookalike printed before the anchor is preserved byte-exact; the report
  block after the anchor is normalized; a FAIL-detail line is not
  over-normalized; the stack-dump collapse fails loudly on an unrecognized frame;
  termination is `exit <N>` / `signal <N>`, never `128+N`.

**Opus 4.8 (xhigh) verdict:** structurally sound Phase 0, no CRITICAL/HIGH/MEDIUM
defect; three low findings, all accepted and fixed on `main`:

1. **Normalizer anchoring was unsound for a crash stream** (latent
   over-normalization). Picking the last `Running` line as the report anchor is
   correct only when a real report exists; on a crash the report is lost, so a
   `Running`-lookalike a test prints before aborting could become the anchor and
   its printed rows be rewritten to `[ T ]`. No committed fixture triggered it.
   FIXED: the anchor is now the last `Running` line that is *followed by a
   `Summary` line* — a real report always ends in a Summary, a lost/fake one does
   not — in both `gen_transcripts.py` and the doctrine wording. Verified: snapshots
   unchanged, and a synthetic crash-after-fake-report stream is no longer
   over-normalized.
2. **The smoke test's reconciliation scan ran past `--- stderr ---`** to
   end-of-file, so a report-grammar lookalike in captured stderr could have been
   folded into the stdout tally (it reconciled today only because no
   report-carrying scenario's stderr contains report grammar). FIXED: the scan is
   bounded to the span between the stdout and stderr markers.
3. **NIT — the contract's `collect` exit-code phrasing** could be read against
   the frozen precedence (an all-files-fail-to-compile `collect` reading as 5
   rather than 1). FIXED: reworded to "1 if any file failed to compile, else 5 if
   nothing collectable, else 0," citing the precedence rule.

The standing per-phase dual-adversarial-review doctrine remains in force; the
Codex leg was not completed this phase.
