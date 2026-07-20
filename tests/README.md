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
  discovery. `pixi run postfork-check` mutation-tests and repeats the complete
  production/testing post-fork call-graph audit; `pixi run native-check`
  depends on that audit before running the ABI and lifecycle gate.
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
$ pixi run test-file -- PATH
$ pixi run test
$ pixi run test-unit
$ pixi run test-integration
$ pixi run safety-check
$ pixi run postfork-check
$ pixi run native-check
$ pixi run asan-check
$ pixi run valgrind-check
```

`pixi run test-file -- PATH` is the focused loop while coding. `pixi run test`
is the exhaustive independent executor for every classified unit and
integration module. Those classifications remain useful maintainer diagnostics
through `test-unit` and `test-integration`; they are not required sequential
local phases. `pixi run dogfood-check` separately drives three standalone
probes through the real `build/mtest` pipeline, while `pixi run e2e` exercises
the external CLI corpus after CLI, session, exec, or reporter behavior changes.
Run `pixi run ci` before a PR.

`asan-check` source-builds the adapter and the highest-risk exec suites with
matching ASan/LSan instrumentation. It first proves that heap overflow,
use-after-free, and leak controls are detected. `valgrind-check` is Linux-only
and substantially slower: it source-builds every `test_exec_*` suite, exercises
Memcheck's invalid-access, undefined-value, leak, and descriptor controls, and
rejects any project/native allocation in the reviewed Mojo-runtime reachable
baseline. These dynamic checks complement the normal behavioral gate; neither
is a claim that all memory or process-lifecycle behavior is proved safe.
