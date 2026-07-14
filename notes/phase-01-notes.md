# Phase 1 notes — the walking skeleton

Phase 1 turns the scaffold into a runnable tool. `mtest [PATHS...]` now
discovers `test_*.mojo` files, builds each one with `mojo build`, executes the
resulting binary directly under full POSIX process supervision, maps the
termination to an honest verdict, renders it through a typed event seam to a
console reporter, and exits with a contract-faithful code. It is sequential —
no parallel workers yet — and it has no per-test knowledge: report parsing
(the piece that reads TestSuite's own PASS/FAIL lines out of the captured
output) is a later capability. The layering was built bottom-up: model →
config → discover/report → exec → session → cli, each layer depending only on
the ones below it.

## The composition micro-spike — WORKING

Before writing any event-model code, a throwaway spike answered the one
architectural question the design had been carrying unproven: can a single
event fan out to N heterogeneous, stateful reporters on this toolchain? The
answer is yes, via a comptime variadic type-parameter pack —
`struct Composite[*Rs: Reporter]` stores `var reporters: Tuple[*Self.Rs]` and
dispatches with `comptime for i in range(Self.N): self.reporters[i].handle(e)`
(where `comptime N = Self.Rs.__len__()`). This is static dispatch, not a
runtime trait-object list — Mojo 1.0.0b2's polymorphism is static, and the
composition has to be built around that rather than against it. This retired
the one unproven bet the design was resting on. The production reporter seam
uses exactly this mechanism, and it is now runtime-proven at N=2: a recording
reporter and a console reporter both observe every event, each keeping
independent state, in the same run.

## Interrupt behavior, measured

SIGINT delivered mid-run against a hanging fixture: the process exits **2**,
prints a **partial summary** with the not-yet-run files accounted as NOT-RUN,
and leaves **no orphaned process group** behind — confirmed by checking that
`os.killpg(pgid, 0)` raises `ProcessLookupError` after the process exits.

The mechanism: `main` installs SIGINT/SIGTERM handlers via `sigaction` (over
FFI) that set a latching flag; the supervision loop polls that flag every
poll slice and, when it's set, group-kills the currently active child
promptly; the session then marks the remaining files NOT-RUN and resolves
exit code 2. Internally, an interrupt surfaces as a `TimedOut` termination —
it's our own kill, mechanically indistinguishable from a deadline firing — so
the session disambiguates a real timeout from a user interrupt via the
latching flag rather than the termination shape alone.

Reproduced independently by hand (not just via the automated gate): launching
`mtest testdata/slow` in its own session, waiting for the run to actually
start, sending `SIGINT` to the whole process group, and then checking for
survivors. Exit code was 2, the summary read `0 passed, 0 failed, 0 crashed,
0 timed out, 0 compile error (0 excluded, 3 not run)`, and a follow-up
`pgrep` for `mtest|mojo` after the process exited turned up nothing.

## The zero-test ceiling, demonstrated

A file that builds and exits 0 without running any tests is reported PASS in
this build. That's not a hidden gap — there is no per-test report parsing
yet, so the runner has no way to know a file collected zero `test_*`
functions versus running some and passing all of them. The committed
`testdata/suite/test_zero.mojo` fixture (a suite with no test functions at
all) makes this concrete: both its manifest row and its end-to-end assertion
pin PASS as the correct-for-this-build outcome, and it's stated plainly in
the README's status section rather than glossed over. Closing this hole is
exactly what the report parser and count reconciliation are for, and that's
the next capability, not a distant one.

## Where the subprocess spike's map diverged from the territory

The subprocess feasibility spike from the previous phase was a starting map,
not a finished one. Productionizing it surfaced several real corrections:

- **The interrupt flag can't be a module global.** Mojo 1.0.0b2 forbids
  module-level `var`, and the sanctioned workaround, `std.ffi._Global`,
  crashes the compiler outright (`ParamInf::inferForStruct`). The working
  equivalent is a fixed-address anonymous mmap page
  (`MAP_FIXED_NOREPLACE`, zero-filled) that a bare C signal handler can
  reach; the `MAP_FAILED` return path is disambiguated by `errno == EEXIST`
  (a harmless re-mapping, safe to treat as reuse) versus a real failure
  (raise), so an unmapped fixed address can't turn into a SIGSEGV later.
- **Installing a Mojo `def` as a C signal handler needs an explicit deref.**
  `UnsafePointer(to=handler)` is a stack slot holding the code pointer, not
  the pointer itself; the actual entry point is
  `UnsafePointer(to=handler).bitcast[UInt64]()[0]`, and that's the value
  that goes into the sigaction buffer.
- **The group-kill had a startup race.** Only the child was calling
  `setpgid(0, 0)`, so a deadline firing in the microsecond window before
  that call could lose its SIGTERM to a process group that didn't exist
  yet. Adding a parent-side `setpgid(pid, 0)` right after `fork` closes the
  window.
- **The build-artifact naming scheme had to be made injective.** A naive
  `/` → `__` mangling scheme collided `a/b.mojo` with a literal
  `a__b.mojo` — one binary would silently overwrite the other, and the
  wrong code would run. The shipped scheme escapes `_` → `_u` and
  `/` → `_s`, which can't collide.
- **Signals are named in words on crash lines** — `signal 4 — SIGILL,
  illegal instruction` — not left as a bare number, matching the crash
  fixture's committed transcript.
- The interrupt path is Linux-only where it matters (the fixed-address mmap
  trick); macOS shares the same POSIX surface for everything else but stays
  an untested assumption.

## Review triage this phase

Every task got a spec review and a quality review internally, and the real
findings were fixed as they came up: a `--gate`-must-be-served parser gap;
several exec-layer hardenings (the `errno`/`EEXIST` disambiguation above, the
parent-side `setpgid`, cleanup-before-raise ordering, a bounded post-reap
drain); the injective artifact-name mangling and word-form signal naming
described above; and hardening of the end-to-end harness itself (timeouts on
every scenario, clean scenario-level failures instead of hangs, and
reproduce/`NO_COLOR`/signal pins so the gate doesn't drift with the
environment).

Two findings were minor enough to carry forward rather than fix immediately:
a forward-looking console gap — the DESELECTED outcome already has a verdict
token but no summary count, which is inert today because nothing emits
DESELECTED yet, but per-test selection will need to add that count or the
run/outcome-count invariant desyncs the moment it lands — and a small
shell-quote helper that's duplicated between the CLI and console layers,
because the CLI layer can't depend on the report layer.

### External review triage

*Stub — pending.* The dual adversarial external review for this phase has
not run yet. The maintainer fills in this section with the review verdict
and the triage of its findings once that review completes, following the
same format as the previous phase's external-review section.

## A process hazard worth naming

The execution harness used to write this code defaults, on every commit, to
appending a `Co-Authored-By` AI-attribution trailer. This repo forbids AI
attribution in its history, and that rule overrides the harness default. One
commit slipped a trailer through before it was caught and amended out. A
local `commit-msg` hook now strips any such trailer as a safety net, which is
why every commit message in this history reads clean — not because the
default stopped firing, but because something now catches it.

## An example run, for real

Built fresh with `mojo build -I build src/main.mojo -o build/mtest`, then run
against the committed test fixtures.

A single passing file:

```console
$ build/mtest testdata/suite/test_passing.mojo
mtest 0.1.0-dev (mojo)
root: /home/mikko/dev/mtest   selected: 1 files   excluded: 0

PASS           testdata/suite/test_passing.mojo  0.02s

===== 1 passed, 0 failed, 0 crashed, 0 timed out, 0 compile error (0 excluded, 0 not run) in 0.4s =====
```

Exit code `0`.

A mixed directory — pass, compile error, crash, and a real assertion
failure, all in one run:

```console
$ build/mtest testdata/suite
mtest 0.1.0-dev (mojo)
root: /home/mikko/dev/mtest   selected: 7 files   excluded: 0

PASS           testdata/suite/nested/test_nested.mojo  0.07s
COMPILE-ERROR  testdata/suite/test_compile_error.mojo  0.00s
CRASH          testdata/suite/test_crashing.mojo  1.18s  (signal 4 — SIGILL, illegal instruction)
FAIL           testdata/suite/test_failing.mojo  0.03s
PASS           testdata/suite/test_noisy.mojo  0.02s
PASS           testdata/suite/test_passing.mojo  0.02s
PASS           testdata/suite/test_zero.mojo   0.07s

--- COMPILE-ERROR testdata/suite/test_compile_error.mojo — mojo build said: ---
/home/mikko/dev/mtest/testdata/suite/test_compile_error.mojo:12:17: error: use of unknown declaration 'this_symbol_is_never_defined_anywhere'
    var value = this_symbol_is_never_defined_anywhere()
                ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
mojo: error: failed to parse the provided Mojo source module
reproduce: mojo build testdata/suite/test_compile_error.mojo -o build/bin/testdata_ssuite_stest_ucompile_uerror

--- CRASH testdata/suite/test_crashing.mojo (signal 4 — SIGILL, illegal instruction) — captured stdout ---
ABORT: /home/mikko/dev/mtest/testdata/suite/test_crashing.mojo:17:10: simulated hard crash
--- captured stderr ---
#0 0x... (/home/mikko/dev/mtest/.pixi/envs/default/lib/libKGENCompilerRTShared.so+0x...)
    ... (stack dump, elided here — full frames in the README) ...
reproduce: mtest testdata/suite/test_crashing.mojo

--- FAIL testdata/suite/test_failing.mojo (exit 1) — captured stdout ---
Unhandled exception caught during execution:
Running 3 tests for /home/mikko/dev/mtest/testdata/suite/test_failing.mojo
    PASS [ 0.001 ] test_first_passes
    FAIL [ 0.043 ] test_second_fails
      At /home/mikko/dev/mtest/testdata/suite/test_failing.mojo:14:17: AssertionError: `left == right` comparison failed:
         left: 1
        right: 2
    PASS [ 0.001 ] test_third_passes
--------
Summary [ 0.043 ] 3 tests run: 2 passed , 1 failed , 0 skipped
Test suite' /home/mikko/dev/mtest/testdata/suite/test_failing.mojo 'failed!

--- captured stderr ---
reproduce: mtest testdata/suite/test_failing.mojo


===== 4 passed, 1 failed, 1 crashed, 0 timed out, 1 compile error (0 excluded, 0 not run) in 3.9s =====
```

Exit code `1`. Note `test_zero.mojo` in that PASS list — it collects zero
`test_*` functions and exits 0, so it's reported PASS. That's the zero-test
ceiling above, not a bug in this transcript.

## What Phase 2 must know

- Captured stdout/stderr are stored as raw bytes and only rendered to
  `String` — lossily, if at all — at the event boundary. The report parser
  can rely on the RUN event's captured bytes being byte-exact,
  stream-separated, never reordered, and, under the 8 MiB per-stream cap,
  head-and-tail-preserved with a loud truncation marker in between. The tail
  survives truncation, so the last report block (the one the parser actually
  needs) stays anchorable even on a file that floods its own captured
  output.
- The DESELECTED console-count gap noted above is still open: the token
  exists, the summary count does not, and per-test selection is the work
  that will need to close it.
- Env mutation in the exec API is unproven — the struct reserves a field for
  it, but nothing exercises it yet. Treat a child-environment quarantine as
  a recorded precondition for the retry/cache work, not an assumption to
  make silently.
