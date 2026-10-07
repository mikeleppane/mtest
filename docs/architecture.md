# Architecture

mtest is pure Mojo, built in layers that import in one direction only: each
module may import only from layers below it. The layer diagram is in the
[README](https://github.com/mikeleppane/mtest#architecture), and
[AGENTS.md](https://github.com/mikeleppane/mtest/blob/main/AGENTS.md#layering)
lists the rank order the layering checker enforces.

- `model` and `platform` are the leaves. `model` holds the outcome
  vocabulary, node ids, the typed event set, and exit-code resolution.
  `platform` is one of exactly two audited foreign-ABI boundaries: the
  narrow set of libc operations a Mojo caller needs directly, each carrying
  a local safety proof. The other is `native/`, a private C17 POSIX adapter
  compiled and statically linked at build time, which owns the machinery
  that must be async-signal-safe after `fork` (spawn, pipe supervision,
  signal handling). `exec` is its sole consumer.
- `protocol` parses `TestSuite`'s printed report, and its collection
  listing, into typed results; a parsed report is accepted only when its
  header count, row count, and summary totals all reconcile.
- `session` drives each file through a small pipeline kernel, a pure state
  machine that answers one question: which step does this file need next
  (build, probe, run, retry, stop)? The sequential driver is the kernel's
  only caller for that question: it walks `next_step` one step at a time and
  folds each completion back. Retry policy, `--maxfail` accounting, and
  stale-state recovery live in the kernel's policy methods —
  `admit_crash_retry`, `record_verdict`, `record_settled`, and the halt state
  (`halt()`, `halt_interrupted()`, `halt_internal_error()`) — and are
  unit-tested without spawning a process. The parallel scheduler runs its own
  build-then-run phase machine over the worker pool, gate files first, then
  the parallel batch, then any `--serial` pass, and reaches into the kernel
  only for those same policy methods; it never walks `next_step`.
- Reporters consume the typed event stream behind a coordinator seam;
  `session` never imports a concrete reporter. The JUnit and annotation
  reporters are fed by the same events the console renders.
- `exec` supervises a pool of up to N children at once through a Supervisor
  over the native ABI: byte-exact stdout/stderr capture, a poll-based drain
  that never deadlocks, deadline kills that always target the whole process
  group, and exit-versus-signal discrimination. At `-n 1` it drives a single
  child, the same path as before the pool.

## Extending mtest

mtest has no plugin API. Mojo cannot load code at runtime, so there is no
hook to register and nothing to import into the process. The `--json` event
stream is the extension mechanism instead, the same posture Go's
`go test -json` takes: run the tool once, let separate-process consumers
subscribe to its typed events.

The stream is versioned on its header line, growth within version 1 is
additive only, and a conforming consumer must ignore unknown fields and
event kinds. [JSON event stream](json-stream.md) freezes the format
and includes a worked consumer skeleton in about twenty lines.
