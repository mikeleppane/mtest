# Test layout

The repository keeps executable product tests, their support code, and their
generated protocol evidence in separate homes:

- `unit/` contains in-memory tests of pure logic and typed model behavior. A
  unit suite must not depend on filesystem layout, compiler subprocesses, or
  process supervision.
- `integration/` contains tests that cross one of those boundaries: filesystem
  discovery, real compiler invocations, subprocess control, or multi-layer
  session behavior.
- `native/` contains C17 ABI, ownership, signal-transaction, sanitizer-control,
  and deterministic fault tests for the exec-private POSIX adapter. These are
  built by the pinned Clang and are deliberately outside Mojo TestSuite
  discovery; `pixi run native-check` runs their normal gate.
- `support/` contains Mojo helper modules imported by executable suites. Files
  here are not test suites and must not be discovered as `test_*.mojo`.
- `fixtures/exec/` contains subprocess actors used to exercise the exec layer.
- `fixtures/protocol/` contains the TestSuite programs used solely by the
  protocol snapshot generator.
- `snapshots/protocol/` contains generated, byte-exact TestSuite transcripts.
  They are immutable test evidence: update them only through
  `pixi run transcripts`, and only when the oracle side deliberately changes.

The hostile known-outcome CLI corpus lives in `../e2e/`, outside `tests/`, so
self-host discovery cannot accidentally execute crashes, hangs, compile
errors, or intentionally malformed suites as ordinary product tests.

Run the classified suites directly with:

```console
$ pixi run test-unit
$ pixi run test-integration
$ pixi run test-direct
$ pixi run native-check
```

`test-direct` is the aggregate independent executor. `pixi run test` is the
separate self-hosted check that drives `build/mtest` over the same unit and
integration suites, while `pixi run e2e` exercises the external CLI corpus.
