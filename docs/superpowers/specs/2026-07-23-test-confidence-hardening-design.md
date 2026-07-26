# Test Confidence Hardening Design

## Purpose

mtest's test suite must answer a release question: if every required check is
green, is it reasonable to believe that discovery, process supervision,
protocol parsing, aggregation, reporting, and exit-code resolution still match
the product contract on every supported platform?

The current suite is already unusually strong. At commit `0c17bf2`, the local
quality floor passes 1,053 classified tests and 72 end-to-end scenarios, the
strict contract checker passes all 60 checks without a skip, and the same
revision has a green Linux and macOS hosted-CI run. The remaining work is not to
maximize a coverage percentage. It is to close specific behavioral
intersections, make release-only evidence blocking, and prove that each new
test detects the defect it claims to prevent.

## Success criteria

The hardening work is complete when:

1. Every supported user-visible contract is exercised by a blocking release
   check at the most realistic practical layer.
2. The high-risk intersections identified below have exact regression tests:
   concurrency plus truncation, transient exec failure plus success, live
   signals plus accounting, descriptor limits plus worker clamping, and raw
   hostile bytes plus each reporter.
3. Every new regression test is demonstrated red before the production fix and
   mutation-proved where the protected property can be temporarily broken.
4. Tests assert exact exit codes, signals, byte sequences, file sets, counts,
   ordering, and diagnostics. Deterministic cases do not use lower bounds such
   as `>= 1`.
5. Test inventory cannot silently omit a misnamed classified Mojo module.
6. Untrusted child output cannot execute terminal control sequences in the
   human console, while the parser and machine reporters retain their existing
   raw-capture and escaping semantics.
7. Source-coverage data, if the pinned toolchain can produce trustworthy data,
   is used as a diagnostic for unvisited code. It is never treated as a
   substitute for behavioral or mutation evidence.

## Test doctrine

### Red, green, refactor

Every observable change follows this cycle:

1. **Red:** Add the smallest test that demonstrates one invariant. Run it and
   capture a failure that proves the test reaches the intended defect.
2. **Green:** Make the smallest production or harness change that satisfies the
   invariant. Run the focused test and the owning suite.
3. **Refactor:** Improve structure only while the focused test remains green.
   Refactoring must not change a transcript, tripwire value, exit code, or
   rendered contract.
4. **Mutation proof:** Temporarily reverse or remove the protected condition,
   confirm the new guard fails for the intended reason, restore the
   implementation, and confirm it passes.
5. **Floor:** Run the affected product-level checks and the full repository
   floor before the change is complete.

A test added after its implementation is not accepted as regression evidence.
Test-only improvements that pin existing correct behavior still require a
negative control or mutation that demonstrates the assertion is load-bearing.

### Exact, layer-owned oracles

Each layer uses the strongest oracle it owns:

- `model` and `config`: exhaustive tables over finite domains.
- `discover`: exact sorted file sets built in temporary trees.
- `protocol`: committed, generator-verified TestSuite transcripts plus minimal
  hostile corruptions.
- `report`: structural and byte-exact assertions over fixed event streams.
- `exec`: real purpose-built actors or direct system binaries, never
  `/bin/sh -c`.
- `session`: known-outcome trees with exact verdicts and accounting.
- `cli`: the complete flag grammar and black-box runs of the built binary.
- package and platform behavior: the installed artifact on the target
  platform, not the source tree standing in for it.

Line execution is not an oracle. A line can execute while the test asserts
nothing meaningful about its effect.

### Intersection-first coverage

Most remaining risk lies between individually tested features. New tests
therefore target combinations rather than adding more single-feature examples.
Each scenario names the two or more guarantees it composes and asserts both
sides. For example, a parallel overflow scenario must prove both bounded
capture and isolation of a neighboring child's exact under-bound stream.

## Workstream 1: Make release evidence blocking

### Strict contract validation

`pixi run contract-check -- --strict` becomes a blocking release check. Its
current exclusion from `ci`, `ci-preflight`, and hosted CI allows a fully green
required floor even when a documented contract check is skipped or fails.

The integration must preserve one canonical invocation and keep topology tests
exact. A strict run has three valid terminal states:

- every check passes and the process exits 0;
- any check fails and the process exits nonzero;
- any check skips and strict mode exits nonzero.

The check must run against the same built binary that the surrounding lane
claims to validate. It must not trigger a racing build against the shared
`build/` tree.

### Packaged-artifact parity

Linux package consumption remains blocking, and macOS gains equivalent
installed-package consumption. Source-tree tests do not prove that package
metadata, static native linkage, runtime lookup, or executable entry points
survive packaging on both supported platforms.

The package test must solve and install the exact produced version in a clean
environment, execute that installed binary, and assert its version, help
surface, a passing run, and a failing run with exact exit codes.

### Memory-safety reach

ASan and Valgrind retain their live negative controls. Their source-built risk
subset is expanded only where an audited map shows unsafe or native-backed
paths that currently never execute in either lane. The map must include the
platform boundary and fd-owning/report-finalization paths, not just the exec
adapter.

No memory lane is considered useful unless its negative controls fail when
instrumentation is disabled or the injected defect is hidden.

### Release evidence

The release checklist records:

- the exact commit;
- the complete local `pixi run ci` result;
- strict contract-check success;
- Linux and macOS required-job success;
- Linux and macOS installed-package consumption;
- ASan and Valgrind success with their negative controls.

Counts printed in documentation and harness descriptions are derived from the
authoritative registry or omitted. Stale hand-maintained totals are not release
evidence.

## Workstream 2: Close supervision and orchestration intersections

### Concurrent bounded capture

The pool receives a real `N > 1` test where:

- one child exceeds both stdout and stderr capture bounds;
- one neighboring child remains below the bound with distinctive exact bytes;
- completion order is deliberately different from discovery order;
- the overflowing child reports both truncation flags and exact retained
  lengths;
- the neighbor reports byte-identical, untruncated streams;
- no bytes, flags, tags, or termination facts cross between slots.

A second case composes an overflowing child with a deadline-killed child. It
proves concurrent draining cannot turn timeout into deadlock or contaminate
capture accounting.

### ETXTBSY retry to success

The native test adapter injects a bounded sequence of `ETXTBSY` results followed
by a successful `execve`. The test asserts the actor's exact stdout, stderr, and
exit status and proves the result is an ordinary successful completion, not a
spawn failure or timeout.

Existing ETXTBSY-versus-deadline and ETXTBSY-versus-interrupt tests remain.
Together the three cases pin success, timeout, and interrupt resolution around
the retry loop.

### Pool machinery failures

Deterministic injection covers each materially distinct pool failure boundary:

- native slot/open failure during build dispatch;
- native slot/open failure during run dispatch;
- `wait_any` machinery failure with children in flight;
- cleanup failure after a gate abort;
- machine-stream failure during a populated batch.

Each test asserts the exact runner exit, the internal-error event when required,
the exact NOT-RUN remainder, the absence of newly scheduled work after the
fault, and process-group cleanup. Interrupt remains exit 2 and continues to
outrank cleanup failure; non-interrupt machinery failure resolves to exit 3.

### Live signal accounting

Black-box tests exercise:

- SIGINT during a sequential run;
- SIGTERM during a sequential run;
- SIGINT during a parallel batch;
- a second interrupt while teardown is active.

Every case uses a deterministic fixture set and asserts the exact completed,
failing, and NOT-RUN file counts; terminal JSON and JUnit accounting where
enabled; process exit; and absence of surviving child process groups. The tests
must not settle for "at least one NOT-RUN."

### Descriptor-limit worker clamping

A black-box end-to-end scenario lowers `RLIMIT_NOFILE`, requests more workers
than the safe descriptor budget permits, and asserts:

- the exact effective worker count announced by the session;
- the run still executes every expected file;
- all outcome and test counts remain exact;
- no machinery error or descriptor leak appears.

Pure clamp-policy tests remain useful, but they do not replace this live
composition of resource limits, native slots, and scheduling.

### Mojo executable precedence

Black-box CLI tests prove the complete precedence chain:

1. explicit `--mojo` wins over `MTEST_MOJO`;
2. `MTEST_MOJO` wins when no flag is present;
3. `mojo` from `PATH` is used when neither is present.

A test-only executable records invocation without relying on a shell. Each case
asserts the exact selected path and argument vector.

## Workstream 3: Harden text and report boundaries

### Lossy UTF-8 corpus

The decoder receives an exhaustive boundary table covering:

- ASCII and valid two-, three-, and four-byte sequences;
- smallest and largest valid scalar values for each sequence length;
- lone continuation bytes;
- overlong encodings;
- surrogate encodings;
- code points above U+10FFFF;
- illegal leading bytes;
- truncated sequences at every position;
- valid sequences adjacent to invalid bytes.

Each case asserts the entire output string, including the exact number and
placement of U+FFFD replacements. The existing single `0xFF` smoke case is
retained only if it adds a distinct integration boundary.

### Shell-ready reproduction text

`shell_quote`, `shell_join`, build-flag rendering, and console reproduction lines
receive exact cases for spaces, empty strings, single quotes, semicolons,
wildcards, dollar signs, command-substitution syntax, backticks, backslashes,
tabs, newlines, and terminal controls.

Printable shell metacharacters remain safely single-quoted and copy-pasteable.
Arguments containing line or terminal controls are rendered visibly and cannot
forge a second mtest output line. Because spawning `/bin/sh -c` is prohibited in
the test suite, correctness is pinned with exact POSIX quoting expectations and
the final rendered console bytes.

### Hostile bytes through real reporters

A purpose-built subprocess actor emits invalid UTF-8, NUL, XML-illegal controls,
quotes, backslashes, record lookalikes, and large bounded streams. The built
mtest binary carries those bytes through real supervision into:

- console output;
- an NDJSON stream parsed by the strict checker;
- a JUnit document parsed and structurally validated by the existing checker.

The tests assert that JSON stays one-record-per-line, XML remains valid, invalid
UTF-8 is replaced according to the shared codec, capture sizes and omissions
remain exact, and no payload changes the runner's verdict or exit code.

### Protocol line endings

CRLF is not accepted as TestSuite protocol on the supported POSIX platforms.
A minimal parser test explicitly proves that a CRLF report is off-grammar and
therefore protocol drift. The parser must not silently strip carriage returns,
because doing so would hide a toolchain-protocol change that transcript
validation is designed to expose.

### Console control-sequence neutralization

All user-controlled text passes through one console-display boundary after
protocol parsing and classification. The boundary has two explicit modes:

- scalar mode renders every C0 control, including LF and tab, as an uppercase
  `\xHH` token;
- multiline mode preserves LF as the line delimiter and tab as indentation,
  while rendering every other C0 control as `\xHH`.

Both modes render DEL as `\x7F` and U+0080 through U+009F as an uppercase
`\u00HH` token. The boundary therefore:

- preserves printable Unicode;
- renders ESC, CR, BEL, backspace, DEL, and C1 controls visibly;
- applies multiline mode to captured streams, assertion details, and compiler
  diagnostics;
- applies scalar mode to paths, names, and reproduction text;
- does not modify parser input, captured byte arrays, NDJSON, or JUnit data.

Captured child lines receive the exact prefix `    | `, including empty logical
lines; a final LF does not create a phantom extra line. Plain text therefore
cannot masquerade as an mtest verdict. Child ANSI styling is intentionally not
executed. mtest's own `--color` styling continues to work because trusted
reporter-generated control sequences are added after untrusted text is
neutralized.

This is an intentional console-contract change. The CLI contract, console
tests, end-to-end expectations, README examples affected by the rendering, and
the real `--help`/documentation consistency checks change together. It does not
change the frozen TestSuite transcript format.

## Workstream 4: Make the test harness fail closed

### Classified-suite inventory

The layout checker inventories every `.mojo` file under `tests/unit` and
`tests/integration`, not only `test_*.mojo`. It accepts package markers and the
classified naming convention, and rejects any unexpected suffix-named,
misplaced, symlinked, or otherwise unclassified Mojo file with its exact path.

The pinned ordered classified list remains the execution oracle. A test proves
that adding `session_test.mojo` fails the layout check instead of disappearing
from the suite.

The obsolete `fn test_*` claim requires no product accommodation: `fn` is not
valid syntax in Mojo 1.0.0b2. A module containing it either fails the aggregate
build or, if it contains no valid `def test_*`, fails the harness's nonempty
test-function check.

### Misleading test repairs

Names, comments, and assertions must describe the same property. Immediate
repairs include:

- rename the selection test that says "selecting none" while selecting one;
- replace the parser stderr pseudo-test with a boundary test that actually
  exercises the caller responsible for keeping stderr separate, or rewrite it
  as a precise parser-interface test without an unused variable;
- update the composite-reporter description so it does not claim all event
  kinds while constructing only six;
- replace weak help-presence checks with exact inventory checks where the
  authoritative flag table exists;
- remove or derive stale test and scenario counts.

These repairs must not change product behavior. Their negative controls prove
the corrected assertions fail when the named property is broken.

### Aggregate failure diagnostics

The one-binary aggregate remains the canonical classified gate because it
avoids repeated expensive Mojo builds and preserves direct execution. The
harness gains bounded execution and exact reporting for:

- the last module marker reached;
- a signal death;
- a nonzero ordinary exit;
- a harness deadline.

A crash or hang still makes the gate fail; it can never produce a partial green
result. Per-module execution remains the focused diagnostic path through
`pixi run test-file -- PATH`. Building every test in its own process is outside
scope because it would multiply compile cost without improving release safety:
the aggregate already fails closed.

### Source-coverage visibility

The pinned compiler is probed for source-coverage support without changing the
Mojo pin or adding dependencies.

If it produces stable, path-normalized coverage for precompiled package code,
the result is published as a non-blocking diagnostic and checked for
determinism. No minimum percentage is introduced until branch attribution,
generated code, Mojo package code, and native C coverage are shown to be
trustworthy.

If trustworthy source coverage is unavailable, the project records that
constraint and uses:

- exact source-to-suite risk mapping for unsafe and exit-code-bearing paths;
- exhaustive finite-domain tests;
- adversarial intersection tests;
- mutation proof for every new regression guard;
- ASan and Valgrind negative controls.

Neither path permits an unvisited line report to be treated as proof of a bug,
nor a high percentage to be treated as proof of release safety.

## Error handling and non-regression rules

- A new test that reveals incorrect existing behavior is preserved red before
  the fix. The failure must identify the intended invariant, not a fixture or
  harness mistake.
- A protocol snapshot changes only when the oracle side changes: a Mojo pin,
  protocol fixture, or transcript scenario. Product hardening alone is not a
  reason to regenerate it.
- CRASH, FAIL, TIMEOUT, COMPILE-ERROR, DRIFT, INTERNAL-ERROR, and NOT-RUN remain
  distinct throughout assertions and reports.
- Exit 2 continues to dominate cleanup faults after an interrupt. Exit 3 remains
  machinery or genuine protocol-drift territory, not a generic user-suite
  failure.
- Test-only subprocess actors stay under `tests/fixtures/exec/`; product code
  remains Mojo plus the private C17 adapter.
- No new runtime dependency, Mojo pin change, platform expansion, or weakened
  gate is part of this work.
- Shared `build/` operations remain serialized.

## Delivery structure

The work is delivered as independently reviewable increments:

1. release gates and inventory integrity;
2. exec and pool adversarial intersections;
3. live CLI signals, limits, and executable precedence;
4. text codecs and reporter end-to-end payloads;
5. console neutralization and its contract update;
6. aggregate diagnostics and source-coverage visibility.

Each increment owns its red-green-refactor cycle, mutation proof, focused gate,
full floor, and atomic commit. A later increment may be deferred without
weakening the evidence added by an earlier one.

## Completion gate

Before declaring the hardening complete:

1. Run `pixi run fmt`.
2. Run `pixi run ci`, including the newly integrated strict contract check.
3. Run every affected memory and package-consumption lane.
4. Run hosted Linux and macOS required jobs at the exact candidate commit.
5. Confirm every new regression guard has recorded red and mutation evidence.
6. Confirm the worktree contains no hand-edited protocol snapshots, stale
   inventory totals, test-only artifacts, or weakened assertions.
7. Review the complete diff for transcript provenance, exact exit-code
   semantics, platform parity, and accidental complexity.
