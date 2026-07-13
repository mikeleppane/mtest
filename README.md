# mtest

A pytest-like test runner for [Mojo](https://www.modular.com/mojo).

**Status: pre-v1, under active development. Nothing here is stable yet.**

## Why

Mojo's standard library ships a per-file test harness — `TestSuite` — that
discovers `test_*` functions in a module and runs them. It does one file at a
time, and the `mojo test` CLI subcommand that used to drive many files was
removed. That leaves a gap that every project fills by hand: a shell loop over
`mojo build`, some `grep` of stdout, and a prayer that the exit code means what
you think it means.

`mtest` fills that gap. It is an **orchestrator on top of `TestSuite`**, not a
replacement for it. `TestSuite` still owns discovery, per-test selection, and
the report format inside each file; `mtest` owns everything between the files —
finding them, building them, running them under supervision, aggregating the
results, and reporting them the way CI expects.

## What makes it different

- **Exit-code fidelity is the product.** A test runner whose exit code you
  cannot trust is worse than no runner. `mtest` builds each test file and
  executes the binary directly, because that is the only way Mojo reports a
  truthful process exit code — `mojo run` masks every outcome to `1`. Green
  means green; a nonzero exit tells you *which* class of failure happened.
- **A crash is not a failure.** An assertion that fails and a process that
  aborts or segfaults are different events with different causes. `mtest` keeps
  them distinct — in the summary, in the JUnit XML, and in the exit code — so a
  memory bug never hides inside a wall of red assertions.
- **Loud over silent.** Every excluded file, every retry, every timeout is
  reported visibly. A run that skipped something never looks like a run that
  passed everything.
- **CI is the customer.** JUnit XML, GitHub Actions annotations, deterministic
  ordering independent of parallel completion, and a hermetic, zero-runtime-
  dependency build are first-class, not afterthoughts.

## Scope

`mtest` provides, on top of `std.testing.TestSuite`:

- recursive discovery of `test_*.mojo` files
- build-then-execute of each file with a truthful process exit code
- per-test selection, node ids, and substring filtering
- parallel execution with timeouts and crash isolation
- crash / timeout / compile-error outcomes kept distinct from failures
- machine-readable reports (JUnit XML, GitHub annotations)
- a stable, documented CLI contract and exit-code model

## Non-goals

- **Not an assertion library.** Assertions come from `std.testing`
  (`assert_equal`, `assert_raises`, …). Property testing likewise belongs
  upstream.
- **Not a replacement for `TestSuite`.** `mtest` orchestrates it and depends on
  its per-file protocol. When Mojo ships an official multi-file runner, the
  goal is to remain the fastest-to-re-pin orchestrator on top of it, or to be
  absorbed gracefully.
- **No runtime dependencies.** The runner is pure Mojo; Python appears only in
  build-time tooling.


## Toolchain

`mtest` pins Mojo `1.0.0b2`. Re-pinning quickly on each Modular release — and
regenerating the protocol transcripts so the diff *is* the changelog — is a core
part of how the project stays trustworthy.

## License

[MIT](LICENSE).
