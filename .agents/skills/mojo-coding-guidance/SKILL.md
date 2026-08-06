---
name: mojo-coding-guidance
description: Mojo implementation and review guidance for the mtest repo — how to write clear, correct, tested, allocation-conscious Mojo for a pytest-like test runner that supervises the stdlib's TestSuite as subprocesses. Use every time you write, modify, refactor, or review Mojo in this codebase — process supervision, protocol parsing, exit-code fidelity, named errors, docstrings, simplicity, and module boundaries all matter here. Apply on every Mojo edit, not only when the user asks for "clean code" or to remove over-engineering. Defers to the global mojo-syntax skill for language syntax and to AGENTS.md for project rules.
---

# Mojo Coding Guidance (mtest)

How to write runner Mojo in this repo: modern, clear, correct, tested code whose
whole product is **truthful exit codes and an honest report**. The tool
orchestrates the stdlib's per-file `std.testing.TestSuite` — it discovers
`test_*.mojo` files, builds each with `mojo build`, executes the binary
*directly*, supervises it as a subprocess, parses the report protocol,
aggregates, and reports for CI. Correctness here is not "close enough": an exit
code is right or it is a lie, and a crash is not a failure.

## Sources of truth (read these first)

- **Language syntax → the global `mojo-syntax` skill.** Mojo evolves fast and
  pretrained models emit obsolete syntax. **Do not rely on your own
  recollection of Mojo syntax; consult it.** This skill does not restate it.
- **Project rules → [AGENTS.md](../../../AGENTS.md).** The layering and the
  two FFI boundaries, the `# SAFETY:` clause list, the transcript lifecycle,
  the pin policy, the classified-test-module rules, and the "Ask first"
  boundaries. AGENTS.md wins over this skill. The recorded failure modes live
  in [.agents/lessons.md](../../lessons.md) — read the section matching what
  you are about to touch, especially "Mojo language, pinned toolchain" before
  non-trivial Mojo and "Process supervision" before exec/native work.
- **When in doubt, compile it.** `pixi run build`, or build a single test
  binary against the package. The syntax moves; a green build is the only proof
  a snippet is current.

## Verification while coding

AGENTS.md's local agentic loop owns the workflow (format, smallest focused
gates, stage-then-gate). The per-edit facts worth repeating:

- `mojo format` (via `pixi run fmt`) is the arbiter of layout — never
  hand-format, and don't argue with it in review.
- Tests run against the **precompiled package**: after a `src/` edit,
  `pixi run build` before running a single test file by hand, or the test
  exercises stale code. `pixi run test-file -- PATH` focuses one module;
  `pixi run test` when a change spans classified modules; `pixi run e2e` after
  CLI/session/exec/reporter behavior changes.

## Build then execute — never `mojo run`

This is the deepest correctness principle in the whole repo: **every test
binary is built with `mojo build` and executed directly.** `mojo run` is banned
from the gate and from the runner it produces, for two independent reasons:

- **It masks a crashing process's exit code to 1.** A test that aborts or
  segfaults comes back as a plain exit 1 — a CRASH becomes indistinguishable
  from a FAIL, precisely the distinction mtest exists to preserve.
- **It can JIT-crash in CI** (Mojo #6413), turning a healthy suite red for
  reasons that have nothing to do with the tests.

A prebuilt binary's termination status is the ground truth. Anything that
shells out to `mojo run`, or reads an exit code from a process it did not
build-then-exec, is a bug.

## Exit-code fidelity — the most important convention

The runner moves between three termination facts, and confusing them is how a
CI lie ships:

```text
exit code   the child's own exit status when it exits normally (0..255)
signal      the signal that terminated the child (crash: SIGABRT, SIGSEGV, …)
timeout     the runner's OWN deadline kill — attributable to us, not the test
```

Hard rules that follow:

- **A CRASH is not a FAIL.** A signal-terminated child is a CRASH outcome; a
  child that exits nonzero after running assertions is a FAIL. These are
  different verdicts with different exit-code contributions, and the API keeps
  them separate all the way up — `Signaled(signo)` is never collapsed into
  `Exited(1)`.
- **Decode the raw `waitpid` status structurally, never the shell's 128+N.**
  `(raw & 0x7f) == 0` → exited with `(raw >> 8) & 0xff`; else terminating
  signal `raw & 0x7f`. A structured termination that surfaces as exit
  `128 + signo` anywhere is a defect — the shell encodes that, we must not.
- **A deadline kill is attributable to us.** When the runner's timeout fires
  and it sends `SIGTERM`/`SIGKILL`, the resulting `TimedOut` outcome must be
  distinct from a `Signaled` crash at the API level — the caller must never
  have to guess whether a SIGKILL was our own deadline or the test dying on
  its own.

## Process supervision and the two FFI boundaries

`exec` is the deepest module: a narrow `run_supervised(spec) -> ProcessResult`
interface hiding process supervision entirely — `session` never sees an fd, a
syscall, or a poll.

**All foreign-ABI knowledge lives in exactly two audited boundaries**
(authoritative in [AGENTS.md](../../../AGENTS.md), enforced by
`scripts/checks/layering.py`):

- **`src/mtest/platform` (Layer 0)** — the small per-call libc operations a
  Mojo caller needs directly, each an in-Mojo `external_call` with its own
  local `# SAFETY:` proof. Where the stdlib can express the operation, the
  safe call wins and no foreign declaration is written.
- **`native/` behind the `mtest_exec_*` ABI** — the private C17 POSIX adapter
  for machinery that must be async-signal-safe after fork (fork/exec, pipe
  supervision, signal handling). `exec` is its sole consumer; those
  `mtest_exec_*` calls, plus the residual test-only `kill(2)` in the exec
  signal helper, are the only raw foreign declarations that legitimately live
  in `exec`.

**A new foreign call belongs in `platform`** — unless it is native-adapter
machinery, in which case it belongs in `native/` behind the ABI. Never widen
the layering checker's exec allowance to place one; that is gate-weakening,
an Ask-first action.

The supervision rules that keep the machinery correct (it ships in the native
adapter — see lessons.md "Process supervision" before touching it):

- **The child path after `fork()` calls ONLY async-signal-safe functions
  before `exec`.** No allocation, no `String` building, no error formatting in
  the child; argv, C strings, and message text are built in the parent before
  the fork. An allocation in the child is a latent deadlock/corruption bug.
- **Drain both pipes to EOF before a blocking reap** — but EOF is not
  completion: a child terminates only when `waitpid` reaps it; enforce the
  deadline with `waitpid(WNOHANG)` on a poll slice.
- **Group-kill, never single-child kill.** The child gets its own process
  group (`setpgid`); every kill targets the group (`kill(-pgid, …)`) with
  SIGTERM → grace → SIGKILL. A grandchild inherits the dup2'd write end;
  killing only the child leaves the pipe open and blocks the parent forever.
- **fd hygiene across repeated spawns.** One long-lived process spawns one
  child per file; a leaked pipe end per spawn accumulates. Close every fd; the
  invariant is worth a test that spawns many children and asserts the fd count
  does not grow.

### `# SAFETY:` proofs

The required clause list — provenance, lifetime, bounds, alignment, ABI,
post-fork restrictions, cleanup on every path — is in
[AGENTS.md](../../../AGENTS.md) ("Unsafe Mojo requires a local proof"); apply
it immediately before the smallest operation or contiguous block it justifies.
State the actual proof, not a paraphrase of the operation, and do not write a
clause until the invariant is actually true. Prefer a safe stdlib operation
when one exists. `pixi run safety-check` is a floor gate that proves only that
a nearby argument exists; review proves the argument is true and complete.

## Protocol parsing — anchor on the last report header, trust nothing a test prints

The report parser reads TestSuite's own output. Its central hazard is that a
test can **print** anything — including lines that look exactly like the report
grammar. The parser must never miscount a test's stdout as protocol.

- **Anchor on the LAST `Running <N> tests for` line** (followed by a
  `Summary`). Anything a fixture printed earlier that *looks* like a report
  line sits before the anchor and must be left untouched. First-match scanning
  is wrong — a noisy fixture that prints `    PASS [ 0.001 ] fake_impostor`
  before the suite runs will fool it.
- **Reconcile three independent counts.** The declared count in the header,
  the number of per-test result rows, and the summary tallies must all agree
  (`declared == rows == passed + failed + skipped`). A mismatch is a
  MALFORMED-SUITE signal, not something to paper over by trusting one source.
- **The report grammar is the toolchain's, not ours.** Protocol snapshots pin
  exactly what TestSuite emits at the pinned Mojo version; the parser is
  written against those frozen bytes, not against a remembered format. When
  the transcript changes, the parser follows the transcript.

## Docstrings — Google style, triple-quoted, mandatory

**Every module, struct, and public function/method carries a real
triple-quoted docstring in Google style.** Not `#`-comment doc blocks. The
formatter/linter validates them. Keep them **short: what it does and why,
nothing more**, folding in the four facts a caller needs — what it does,
whether it mutates, whether it allocates, whether it can raise.

- **Module docstring** first in the file, before the imports, stating the
  module's place in the layering. **Struct docstring** first in the struct
  body, usually one line. **Function docstring** first in the body with
  `Args:` / `Returns:` / `Raises:` — omit any section that does not apply;
  note allocation and mutation tersely in `Returns:`.
- Summary line starts with a capital; wrap a leading code identifier in
  backticks if it would otherwise be lowercase.
- **No plan/spec references** in docstrings or comments — no "Phase 1",
  "per the handoff", `docs/plans/…`. Those documents are gitignored; the
  reference dangles. State the reason itself. External prior art ("pytest's
  exit codes", a man page) is fine.

The canonical public-function shape:

```mojo
def run_supervised(spec: ProcessSpec) raises -> ProcessResult:
    """Run one child under full process supervision, capturing both streams.

    Forks and execs `spec.argv` in its own process group, drains stdout and
    stderr to EOF on a poll slice, enforces `spec.timeout_ms` with a
    group SIGTERM->SIGKILL escalation, then reaps the child.

    Args:
        spec: The command to run: argv, optional cwd, timeout. Not mutated.

    Returns:
        The captured streams plus a structured termination
        (Exited(code) | Signaled(signo) | TimedOut(signo_used)) and the
        wall duration. Allocates the two capture buffers.

    Raises:
        Error: If a pre-fork syscall (pipe, fork) fails — named and located
            (`"exec: pipe() failed: <errno>"`); never for a child that
            merely exits nonzero or crashes (that is a ProcessResult).
    """
    ...
```

Comments inside the supervision loop are for what the code *can't* say — why
the drain must precede the reap, why the kill targets the group — never for
narrating steps.

## Simplicity — every construct must pay rent

The unit of cost is the **name** — every new trait, struct, helper, or
parameter is one more thing the next reader must find, open, and hold. The
default shape for new behavior is the smallest one: **a branch before a
helper, a function before a struct, a struct before a trait, a constructor
before a factory** — move up only when the smaller shape demonstrably no
longer holds the logic. (The generic over-abstraction argument lives in the
deep-module literature; what follows is this repo's calibration.)

The rent test — add a construct only when you can name what it buys *today*:

- A **trait** exists when a second conforming implementation exists — or when
  AGENTS.md names the seam (the `Reporter` trait predated the second reporter
  because the plugin seam is doctrine). A single-impl trait with no named seam
  is indirection, not abstraction.
- A **helper function** earns its name by hiding a real decision or invariant,
  or by a second caller. A one-expression wrapper with one call site is a
  detour, not a unit.
- A **struct** earns existence by enforcing an invariant between its fields or
  owning a resource with a lifecycle. A one-field bundle does not.
- A **parameter, field, or config knob** needs a caller that passes a second
  distinct value today. A "reserved" field needs the phase that fills it named
  in AGENTS.md — otherwise it is a guess wearing a type.
- A **factory or builder** exists when construction genuinely has variants or
  steps. A `make_x()` that returns the one concrete `X()` is ceremony.

When a later phase arrives with real variation, add the seam *then* — that
phase has all the cases on the table; a seam guessed today rarely fits and
still gets reworked, now with callers attached.

**Deleting is a first-class edit.** Dead code, an unused re-export, a
parameter nobody passes differently, a helper down to one trivial caller:
remove them in the commit that notices them. Git remembers.

Red flags — stop and inline or delete instead: a trait with one implementation
and no AGENTS.md-named seam; `make_*` returning its only concrete type; a
`*Config` struct with one field; a helper whose body is one expression with one
caller; a parameter every caller passes identically; "for future use" in a
docstring.

## Naming

Types `UpperCamelCase`; functions, methods, variables `snake_case`;
compile-time constants `UPPER_SNAKE_CASE`; type parameters `PascalCase`, value
parameters `lower_snake_case`. Never shadow the reserved convention words
`ref`, `mut`, `out`, `deinit`, `read`, `var` — not as parameter names, not as
locals (see `mojo-syntax` for why). Clear over clever: `signo` is a signal,
`code` is an exit code, `pgid` is a process group.

## Exactness correctness

Exit codes and test counts are integers; there is **no tolerance anywhere**.

- **Exit codes and counts compare exactly, always.** If a verdict is off by
  one, the runner is wrong (see
  [mtest-testing-patterns](../mtest-testing-patterns/SKILL.md)).
- **The exit-code precedence is a pure, total function** of the outcome
  multiset, exhaustively unit-tested. Encode it once, in `model`, and never
  re-derive it ad hoc in `session`.
- **Invariants are enforced where they're cheapest to name.** Count
  reconciliation happens once in `protocol`; a malformed report dies with a
  named MALFORMED-SUITE signal there, not as a silent miscount three layers
  up. Validate at the boundary; trust inside.
- **Totality is a documented contract.** A verdict-mapping function that is
  total on `ProcessResult` says so in its docstring; an impossible input is a
  caller-contract violation guarded by `debug_assert`, not an error path.

## Error handling — named, actionable, cheap

Mojo errors are alternate return values, not unwinding exceptions — raising is
about as cheap as returning a checked `Bool`, so **there is no performance
excuse for a vague error**. `raises` is explicit: present iff the function can
fail — the signature is a contract.

- **Every raise is NAMED and LOCATED.** The message states *what* failed, the
  *offending value*, and *where*: `"exec: fork() failed: errno 12"`,
  `"cli: --timeout wants an integer, got 'soon'"`. A named error teaches and
  is pinned by `assert_raises(contains=...)`; `"bad input"` does neither.
- **Distinguish the runner's own failure from the child's outcome.** A child
  that exits nonzero or crashes is **data** — a `ProcessResult`, not an
  exception. The exec adapter raises only when *its own* machinery fails,
  never to signal a test verdict.
- **Raise at the boundary, keep the core total.** The parser and the CLI
  validate exhaustively with per-case messages; the supervision loop and the
  verdict mapping stay total on the invariants those boundaries proved.
- **One failure, one message shape.** All errors from one module share a
  prefix (`"exec: …"`, `"cli: …"`, `"protocol: …"`) so tests and humans triage
  on sight.
- Default to the built-in `Error` with a well-shaped message; reach for typed
  errors only when a caller genuinely branches on error kind. Re-raise with
  `raise e^` after adding context; wrap foreign errors at the boundary rather
  than letting a raw errno leak through a public function. `comptime assert`
  for compile-time invariants; `debug_assert` for caller contracts on hot
  paths.

## Memory, allocation, and cleanup invariants

- **Say whether a function allocates** in its docstring.
- **Know your conventions.** The default `read` convention is a free borrow.
  Take `Span[Byte]` views instead of copying capture buffers; pass `mut` to
  fill a caller's buffer; transfer with `^` at last use. Keep big types
  `Copyable` but **not** `ImplicitlyCopyable`, so every copy is a visible
  `.copy()` in review.
- Prefer the safe types (`List`, `Span`, `InlineArray`, `Pointer`,
  `OwnedPointer`) over raw `UnsafePointer`. When a struct genuinely owns an fd
  or heap bytes, give the field an explicit origin, release the resource in
  `__del__`, and prove the round-trip with a construct-and-drop test. **The fd
  is the resource that leaks; treat closing it like freeing memory.**
- Pre-size what you can: `List[Byte](capacity=n)` when a bound is known; reuse
  buffers across the spawn loop instead of reallocating per file.

## Module boundaries

The layering graph, the facade rule, and the FFI confinement are authoritative
in [AGENTS.md](../../../AGENTS.md) and enforced by
`scripts/checks/layering.py`. Per edit: one responsibility per file; never
import "up"; `src/` is pure Mojo; `__init__.mojo` is the package's public
surface (re-export the clean names, no executable top-level code); generated
source is a golden that happens to be source — provenance header, never
hand-edited, fix the generator and regenerate.

## Language gotchas

[.agents/lessons.md](../../lessons.md) is the incident log for the pinned
`1.0.0b2` toolchain — "Mojo language, pinned toolchain" for language traps
(FFI naming collisions, string/C-string conversions, `external_call`
declaration arity, variadic-ABI hazards, copy/transfer rules), "Process
supervision" for exec/native traps. Read the matching section before
non-trivial work there; append what you learn.

## Review checklist for a Mojo change

- [ ] `pixi run fmt` clean; affected focused and product gates green
- [ ] Every public function states what it does + mutate/allocate/raise
- [ ] Binaries are build-then-executed; `mojo run` appears nowhere
- [ ] Crash ≠ fail preserved: `Signaled` never collapsed to `Exited`; status
      decoded structurally (never 128+N); a deadline kill is a distinct
      `TimedOut`
- [ ] Child path after `fork` touches only async-signal-safe calls; all
      allocation is pre-fork; the kill targets the process GROUP; both pipes
      drained before the reap, deadline enforced with `WNOHANG` polling
- [ ] Parser anchors on the LAST `Running <N> tests for`; a printed
      report-lookalike is not miscounted; declared == rows == summary
- [ ] Every raise named and located (`module: what + value`); tested with
      `assert_raises(contains=...)`; a child's nonzero/crash is DATA, not a
      raise
- [ ] `raises` present iff the function can raise; hot cores total, boundaries
      validating
- [ ] fds and buffers released in `__del__`; no fd growth across repeated
      spawns
- [ ] All comparisons exact — no tolerance on exit codes or counts
- [ ] Imports point down the layering; `src/` pure Mojo; every foreign call
      inside the two audited boundaries (`platform`, or `native/` via `exec`)
      — a new one belongs in `platform`, and widening the exec allowance is
      Ask-first gate-weakening
- [ ] Every unsafe operation carries a true, complete `# SAFETY:` proof per
      AGENTS.md's clause list
- [ ] Every new construct passes the rent test
- [ ] Syntax matches `mojo-syntax` (no `fn`/`let`/`alias`/`@parameter`/
      `inout`/`owned`)
- [ ] New behavior has a test that would fail without it
