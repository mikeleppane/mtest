# Overview

Why mtest exists, what it does, what to know before you rely on it, and what
it deliberately leaves out.

## Why

Mojo's standard library ships a per-file test harness, `TestSuite`, and the
`mojo test` CLI subcommand that used to drive many files was removed. That
leaves a gap most projects fill by hand: a shell loop over `mojo build`, a
grep of stdout, and an exit code nobody fully trusts. mtest replaces that loop
with one binary. What it does differently:

- **Truthful exit codes.** Every test file is compiled with `mojo build` and
  the binary is executed directly, because that is the only way Mojo reports a
  truthful process exit code. `mojo run` masks every outcome to `1` and is
  never used.
- **CRASH and FAIL stay distinct.** A failed assertion and a process that
  aborts or dies by signal are different events with different causes, and
  they stay separate in the console, the event stream, and the JUnit mapping.
  The exit code groups both into its failing class.
- **Nothing is skipped quietly.** Every excluded file, retry attempt, and
  timeout is reported visibly, so a run that skipped something never looks
  like a run that passed everything.
- **Built for CI.** Deterministic path-sorted output, a hermetic build with
  zero runtime dependencies, sharding for CI matrices, and machine-readable
  reports are all first-class. Product logic is pure Mojo, and project
  configuration is parsed natively by the pinned, vendored `mojo-toml` source.

## Features

- Recursive discovery of `test_*.mojo` files, with `--exclude` globs and
  `-I` include paths.
- Per-test outcomes parsed from each file's `TestSuite` report: `-k`
  substring selection, `path::test` node ids, `--maxfail N`, and
  `mtest collect` to list node ids without running any test body — as plain
  lines, or as a versioned NDJSON stream with `--format json`.
- A full outcome model: PASS, FAIL, SKIP, CRASH, TIMEOUT, COMPILE-ERROR,
  COMPILE-TIMEOUT, MALFORMED-SUITE, and PRECOMPILE-ERROR, plus a FLAKY
  annotation for a pass that needed retries. A file that builds and exits
  cleanly without running a single test is labeled NO-TESTS on the console
  and never counts as a pass. Every abnormal outcome carries captured output
  and a one-line reproduce command, and every signal or timeout is named in
  words (`signal 11 — SIGSEGV, segmentation fault`).
- Crash-class retries (`--retries N`) with an explicit FLAKY verdict for a
  late pass. Deterministic failures, such as an ordinary compile error or a
  failing assertion, are never retried. `--fail-on-flaky` turns a FLAKY-only
  session's `0` into a `1` for a pipeline that will not tolerate one.
- Bounded crash attribution: after a CRASH, a strictly bounded pass re-runs
  that file's tests one at a time to name a culprit, and reports honestly
  when it cannot. It never changes the verdict or the exit code.
- Timeouts for both the run (`--timeout`) and the build
  (`--compile-timeout`). Every kill targets the whole process group, and a
  run timeout that had to go past the polite terminate says so on its
  verdict line (`escalated to SIGKILL`).
- Deterministic sharding (`--shard`) for spreading one suite across a CI
  matrix, and `--shuffle` for the opposite question: run the files in a random
  order to surface a suite that only passes in one. The seed is printed, and
  `--seed N` replays it.
- Three machine reporters: an NDJSON event stream (`--json`),
  schema-validated JUnit XML (`--junit-xml`), and GitHub Actions annotations
  (`--gh-annotations`).
- A run report for a person to read: `--report FORMAT:PATH` writes one
  self-contained Markdown or HTML document — the run's facts, a summary table,
  a section per file that needs a second look, and a machine index of commands
  to paste back — with `--report-style concise|full` choosing how much of it
  each file earns.
- A clean interrupt: Ctrl-C tears down the in-flight process group, prints a
  partial summary with NOT-RUN accounting, and exits `2`.
- Project configuration in `mtest.toml`: a closed schema resolved per key as
  defaults < file < `MTEST_MOJO` < command line, with per-file `[[override]]`
  tables, and `mtest config show` to render the resolved values with the layer
  each one came from.
- Failure re-selection from the last completed run: `--lf` narrows to what
  failed, `--ff` runs those files first. Both are soft filters, so a stale
  entry is dropped loudly, never fatally.
- `mtest doctor`: ten read-only environment checks (toolchain identity,
  configuration, last-run state, temp, report destinations) without building
  or running a test.
- `mtest debug path::test`: prepare one test the way a run would, print the
  build and run commands it used, then hand the terminal to the binary and get
  out of the way — no capture pipe, no summary, no mtest verdict.
- `mtest new` and `mtest init`: write the first test file, or the whole
  starting project (a test, an `mtest.toml`, a `.gitignore` entry, and
  optionally a CI workflow). Neither ever overwrites what is already there.
- Gate files (`--gate`), precompiled package dependencies (`--precompile`),
  a slowest-files list (`--durations`), quiet and verbose modes, and color
  control (`--color`, `NO_COLOR`).

## Limitations

Facts about this build worth knowing before you rely on it:

- **The pool is descriptor-bounded, and capture is per-worker.** `-n auto`
  takes half the logical cores (`max(1, cores // 2)`, a measured politeness
  bound that leaves headroom for other work, not a compile-starvation limit);
  an explicit `-n N` above the environment's file-descriptor ceiling is
  loudly clamped down to what the machine can honor. Each worker buffers up
  to 16 MiB of captured output (8 MiB per stream), so peak capture memory
  scales with the resolved worker count.
- **Captured output is file-scoped.** `TestSuite` does not attribute a
  file's stdout/stderr to individual tests, so mtest cannot either. Parsed
  FAIL assertion details are per-test; the raw captured block is per-file.
- **The console shows child text, it does not execute it.** Every string a
  child or the compiler produced is neutralized before it is printed for a
  human: control characters become visible escapes (`\x1B`, `\x00`, `\u009B`)
  and multi-line blocks are fenced behind a `    | ` gutter, so a test cannot
  repaint your terminal or forge a line that reads as mtest's own. The GitHub
  annotation tail prints to the same destination and gets the same treatment,
  on top of its own `%25`/`%0A`/`%0D` workflow encoding. `mtest doctor`,
  `mtest config show`, and the configuration diagnostics neutralize the same
  set of code points in their own output's escape spelling, and the set is
  defined once and shared so it cannot drift between them. The JUnit report and
  the `--json` stream are written elsewhere and are unaffected: they still
  carry the raw text under their own escaping, as does `mtest collect`, whose
  node-id listing is specified byte-exact for tooling to consume. This stops
  the child *doing* things, not *looking* like things: bidi overrides and
  homoglyphs pass through, so a test name can still be visually misleading.
- **`--maxfail` is checked between files.** A file already in flight always
  finishes, so a file with several failing tests can push the count past
  `N` before scheduling stops.
- **Retries under selection are run-side only.** With `-k` or a node id, a
  crash-class run failure is retried, but a crash-class build failure is
  not.
- **`--durations` ranks whole files** by run-only wall-clock; it does not
  see the slowest individual test inside a fast file.
- **The SLOW annotation is a fixed 60s threshold**, informational only; it
  never changes a verdict or the exit code.
- **Memory analysis is Linux-only; packaging is not.** macOS arm64 CI is a
  blocking check too: it audits the native adapter, runs the direct and
  end-to-end suites, and consumes the installed conda artifact in its own job.
  ASan/LSan and Valgrind run only on linux-64.
- **Release profiles are explicit and artifact-checked.** linux-64 binaries use
  Mojo `x86-64` and C `x86-64` with generic tuning; osx-arm64 binaries use
  `apple-m1` and a macOS 14.0 deployment target. Production Mojo links use
  `-O3 -g0`, while compiler parallelism stays at Mojo's default of all
  available compiler threads. This profile does not promise a lower Linux
  glibc floor.
- **GitHub annotations are capped and root-relative.** GitHub's
  workflow-step limits allow 10 error and 10 warning annotations per step
  (past the cap, one aggregate line accounts for the rest), and every
  `file=` path assumes mtest was invoked from the repository root.
- **The JUnit dialect is one settled choice.** JUnit XML has no universal
  schema; every report is validated against the committed
  `scripts/schemas/junit-10.xsd`, which is a conformance claim about that
  schema, not about every consumer in the wild.
- **A configured key cannot be cleared per key from the command line.** A CLI
  value replaces a configured one, and positional operands replace configured
  `paths`, but there is no spelling that empties a configured list or reverses
  a configured `serial = true`, `state = false`, or `precompile` entry.
  `--no-config` is the all-or-nothing escape.
- **`config show` output is for humans.** It is valid, copy-pasteable TOML,
  but its layout and its `# (source)` comments are informal and may change; a
  machine-readable configuration format is reserved, not shipped.
- **The build cache has no import graph, and no reach past this checkout.** One
  edit under an `-I` root invalidates every file keyed over that root, and one
  edit beside a test file invalidates every test in that directory, so a
  one-line change to a shared library or a shared helper rebuilds the whole
  selection — deliberate over-rebuilding, since the alternative is guessing
  which files an edit reached. The store is per-checkout: there is no spelling
  that moves it
  elsewhere, and it is never shared between machines or between two clones on
  one machine. Anything it cannot characterize turns it off for the session
  rather than guessing. [Build cache](build-cache.md) has the whole picture.
- **Last-run state is one file, last writer wins.** Two sessions running
  concurrently in one invocation root both write it, and the one that finishes
  last is the state the next `--lf` reads. A write failure is one stderr
  diagnostic that preserves the previous file; it never changes the exit code.

## Non-goals

- **A TestSuite replacement.** mtest orchestrates the standard library's
  harness and depends on its per-file protocol. The optional source-only
  `assert_equal` companion only improves mismatch detail, and it still reports
  an ordinary TestSuite failure. Property testing belongs upstream.
- **Third-party runtime dependencies.** mtest has none. Product logic is pure
  Mojo plus one statically linked C adapter and the pinned native TOML parser
  compiled into the shipped binary.
