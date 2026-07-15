---
name: mojo-coding-guidance
description: Mojo implementation and review guidance for the mtest repo — how to write clear, correct, tested, allocation-conscious Mojo for a pytest-like test runner that supervises the stdlib's TestSuite as subprocesses. Use every time you write, modify, refactor, or review Mojo in this codebase — process supervision, protocol parsing, exit-code fidelity, named errors, docstrings, and module boundaries all matter here. Apply on every Mojo edit, not only when the user asks for "clean code". Defers to the global mojo-syntax skill for language syntax and to AGENTS.md for project rules.
---

# Mojo Coding Guidance (mtest)

How to write runner Mojo in this repo: modern, clear, correct, tested code whose
whole product is **truthful exit codes and an honest report**. The tool
orchestrates the stdlib's per-file `std.testing.TestSuite` — it discovers
`test_*.mojo` files, builds each with `mojo build`, executes the binary
*directly*, supervises it as a subprocess, parses the report protocol,
aggregates, and reports for CI. Correctness here is not "close enough": an exit
code is right or it is a lie, and a crash is not a failure.

**Where this applies today.** `src/mtest/` is an intentionally empty, compiling
package — there is no `model`/`exec`/`protocol`/`session` code yet to hold this
bar (AGENTS.md). Concretely this skill governs the Mojo that *does* exist now
(the probe `fixtures/`, the tests under `tests/`, `src/mtest/__init__.mojo`'s
docstring) and is the contract each later module must meet the day it lands —
read it before writing `exec` just as much as before touching today's fixtures.

## Sources of truth (read these first)

- **Language syntax → the global `mojo-syntax` skill.** Mojo evolves fast and
  pretrained models emit obsolete syntax. That skill is the authority on `def`
  vs `fn`, `comptime` vs `alias`/`@parameter`, argument conventions
  (`read`/`mut`/`var`/`out`/`deinit`), `std.`-prefixed imports, lifecycle
  methods, traits, SIMD, strings, and pointers. **Do not rely on your own
  recollection of Mojo syntax; consult it.** This skill does not restate it.
- **Project rules → [AGENTS.md](../../../AGENTS.md).** The layering plan, the
  Python-containment rule, the transcript lifecycle, the pin policy, the Lessons
  section, and the "Ask first" boundaries. AGENTS.md wins over this skill.
- **When in doubt, compile it.** `pixi run build`, or build a single test
  binary against the package. The syntax moves; a green build is the only proof
  a snippet is current.

The rest of this skill is the project's *coding* contract on top of that syntax.

---

## The floor

Before any Mojo change is done:

```bash
pixi run fmt   # mojo format — never hand-format, let the tool decide
pixi run ci    # the aggregate gate, fail-fast (AGENTS.md defines the chain); the file you touched must be covered and green
```

`mojo format` is the arbiter of layout. Don't argue with it in review — if it
reformats your code, that's the house style. Remember tests run against the
**precompiled package**: after a `src/` edit, `pixi run build` before running a
single test file by hand, or the test exercises stale code.

---

## Build then execute — never `mojo run`

This is the deepest correctness principle in the whole repo, and it is not
optional: **every test binary is built with `mojo build` and executed
directly.** `mojo run` is banned from the gate and from the runner it produces,
for two independent reasons that both destroy the product:

- **It masks a crashing process's exit code to 1.** A test that aborts (SIGABRT)
  or segfaults (SIGSEGV) comes back from `mojo run` as a plain exit 1 — so a
  CRASH becomes indistinguishable from a FAIL, which is precisely the
  distinction mtest exists to preserve.
- **It can JIT-crash in CI** (Mojo #6413), turning a healthy test suite red for
  reasons that have nothing to do with the tests.

A prebuilt binary's termination status is the ground truth. `scripts/test_all.sh`
already eats this discipline for mtest's own suite; the runner must enforce the
same rule on the code it tests. Anything that shells out to `mojo run`, or that
reads an exit code from a process it did not build-then-exec, is a bug.

---

## Exit-code fidelity — the most important convention

The runner moves between three termination facts, and confusing them is how a CI
lie ships:

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
  `(raw & 0x7f) == 0` → exited with `(raw >> 8) & 0xff`; else terminating signal
  `raw & 0x7f`. A structured termination that surfaces as exit `128 + signo`
  anywhere is a defect — the shell encodes that, we must not.
- **A deadline kill is attributable to us.** When the runner's timeout fires and
  it sends `SIGTERM`/`SIGKILL`, the resulting `TimedOut` outcome must be distinct
  from a `Signaled` crash at the API level — the caller must never have to guess
  whether a SIGKILL was our own deadline or the test dying on its own.
- **Truthful exit codes come only from prebuilt binaries.** See the section
  above; it is the reason the exec adapter builds and executes rather than
  delegating to `mojo run`.

---

## Process supervision — the exec module is the deepest one

`exec` (the POSIX process adapter) is the deepest module in the design: a narrow
`run_supervised(spec) -> ProcessResult` interface hiding fork/exec, pipes,
concurrent draining, poll-based supervision, the kill protocol, FFI, platform
differences, and fd cleanup. **All FFI lives here and nowhere else.** The rules
that keep it correct:

- **The child path after `fork()` calls ONLY async-signal-safe functions before
  `exec`.** Between fork and exec the child may touch only the syscall-thin set —
  `setpgid`, `dup2`, `close`, optional `chdir`, then `execvp` or `_exit(127)`.
  **No allocation, no `String` building, no error formatting in the child.** All
  of that — the argv array, the C strings, any message text — is built in the
  **parent before the fork**. An allocation in the child between fork and exec is
  a latent deadlock/corruption bug, not a style nit.
- **Drain both pipes to EOF before `waitpid`.** The completion signal is EOF on
  both read fds. Poll on a time slice, re-check the deadline mid-drain, and drain
  fully — a partial drain plus `waitpid` can deadlock when the child (or a
  grandchild that inherited the write end) still holds a pipe open.
- **Group-kill, never single-child kill.** Put the child in its own process group
  (`setpgid`) and kill the *group* (`kill(-pgid, …)`) with SIGTERM → grace →
  SIGKILL. A grandchild inherits the dup2'd write end; killing only the child
  leaves the pipe open and blocks the parent's read forever.
- **fd hygiene across repeated spawns.** The runner spawns one child per file, in
  one long-lived process; a leaked pipe end per spawn accumulates. Close every fd
  you open; the invariant is worth a test that spawns many children and asserts
  the fd count does not grow.
- **Platform differences stay inside `exec`.** Linux is the gate; macOS shares the
  POSIX surface. Any `#ifdef`-shaped divergence is hidden behind the module's
  narrow interface — `session` never sees an fd or a syscall.

---

## Protocol parsing — anchor on the last report header, trust nothing a test prints

The report parser reads TestSuite's own output. Its central hazard is that a
test can **print** anything — including lines that look exactly like the report
grammar. The parser must never miscount a test's stdout as protocol.

- **Anchor on the LAST `Running <N> tests for` line.** The real report block
  begins at the final occurrence of that header; anything a fixture printed
  earlier that *looks* like a report line sits before the anchor and must be left
  untouched. First-match scanning is wrong — a `noisy` fixture that prints
  `    PASS [ 0.001 ] fake_impostor` before the suite runs will fool it.
- **Reconcile three independent counts.** The declared count in the header, the
  number of per-test result rows, and the summary tallies must all agree
  (`declared == rows == passed + failed + skipped`). A mismatch is a
  MALFORMED-SUITE signal, not something to paper over by trusting one source.
- **The report grammar is the toolchain's, not ours.** The golden transcripts pin
  exactly what TestSuite emits at the pinned Mojo version; the parser is written
  against those frozen bytes, not against a remembered format. When the transcript
  changes, the parser follows the transcript.

---

## Docstrings — Google style, triple-quoted, mandatory

**Every module, struct, and public function/method carries a real triple-quoted
docstring in Google style.** Not `#`-comment doc blocks. The formatter/linter
validates them, so this is the house style, not a preference. Keep them
**short: what it does and why, nothing more.** Fold the four facts a caller
needs — **what it does, whether it mutates, whether it allocates, whether it can
raise** — into the sections below.

Rules:

- **Module docstring** is the first statement in the file, **before the
  imports**, and states the module's place in the layering.
- **Struct docstring** is the first statement in the struct body — usually one line.
- **Function/method docstring** is the first statement in the body, with
  `Args:` / `Returns:` / `Raises:` sections. **Omit any section that does not
  apply.** Note **allocation and mutation** tersely in `Returns:`; document
  raising via `Raises:` (`Error: <when>`).
- Summary line starts with a capital; wrap a leading code identifier in
  backticks if it would otherwise be lowercase.
- **No plan/spec references** anywhere in docstrings or comments — no
  "Phase 1", "P1-D3", "per the handoff", `docs/plans/…`. Those documents are
  gitignored; the reference dangles. State the reason itself. External prior art
  ("pytest's exit codes", "the POSIX `waitpid` contract", a man page) is fine.

Public function — the canonical shape:

```mojo
def run_supervised(spec: ProcessSpec) raises -> ProcessResult:
    """Run one child under full process supervision, capturing both streams.

    Forks and execs `spec.argv` in its own process group, drains stdout and
    stderr to EOF on a poll slice, enforces `spec.timeout_ms` with a
    group SIGTERM->SIGKILL escalation, then reaps the child.

    Args:
        spec: The command to run: argv, optional cwd, timeout, reserved
            env-extension field. Not mutated.

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

Comments inside the supervision loop are for what the code *can't* say — why the
drain must precede the reap, why the kill targets the group — never for narrating
steps.

---

## Naming

Clear over clever. Types `UpperCamelCase` (`ProcessResult`, `RunnerConfig`);
functions, methods, variables `snake_case` (`run_supervised`, `pgid`);
compile-time constants `UPPER_SNAKE_CASE` (`comptime POLL_SLICE_MS = 100`,
`comptime GRACE_MS = 2000`). Type parameters `PascalCase` (`T`, `ReporterType`);
value parameters `lower_snake_case` (`capacity`, `n_streams`) — the manual's
convention.

Never shadow the reserved convention words `ref`, `mut`, `out`, `deinit`,
`read`, `var` — not as parameter names, not as locals. (See the `mojo-syntax`
skill for why.)

---

## Exactness correctness

Exit codes and test counts are integers; there is **no tolerance anywhere**.

- **Exit codes and counts compare exactly, always.** "Almost the right count" or
  "usually exits 0" does not exist for a test runner — if a verdict is off by
  one, the runner is wrong. (See
  [test-driven-development](../test-driven-development/SKILL.md).)
- **The exit-code precedence is a pure, total function** of the outcome multiset,
  exhaustively unit-tested. A usage error outranks an internal error outranks a
  test failure outranks an empty walk outranks success — encode that once, in
  `model`, and never re-derive it ad hoc in `session`.
- **Invariants are enforced where they're cheapest to name.** Count
  reconciliation happens once in `protocol` (declared == rows == summary); a
  malformed report dies with a named MALFORMED-SUITE signal there, not as a
  silent miscount three layers up. Validate at the boundary; trust inside.
- **Totality is a documented contract.** A verdict-mapping function that is
  *total* on `ProcessResult` (every termination maps to exactly one outcome, no
  raise) says so in its docstring, and an impossible input is a caller-contract
  violation guarded by `debug_assert` — not an error path.

---

## Error handling — named, actionable, cheap

Mojo errors are alternate return values, not unwinding exceptions — raising is
about as cheap as returning a checked `Bool`, so **there is no performance excuse
for a vague error**. `raises` is explicit: add it when a function can fail; omit
it (compiler-enforced) when it cannot — the signature is a contract the reader
relies on.

- **Every raise is NAMED and LOCATED.** The message states *what* failed, the
  *offending value*, and *where*: `"exec: fork() failed: errno 12"`,
  `"cli: --timeout wants an integer, got 'soon'"`, `"protocol: declared 5 tests,
  parsed 4 rows"`. A named error teaches and is pinned by
  `assert_raises(contains=...)`; `"bad input"` does neither.
- **Distinguish the runner's own failure from the child's outcome.** A child that
  exits nonzero or crashes is **data** — a `ProcessResult`, not an exception. The
  exec adapter raises only when *its own* machinery fails (a pipe or fork
  syscall), never to signal a test verdict. Confusing the two is how "the test
  crashed" turns into "the runner crashed".
- **Raise at the boundary, keep the core total.** The parser and the CLI validate
  exhaustively with per-case messages; the supervision loop and the
  verdict-mapping stay total on the invariants those boundaries proved.
- **One failure, one message shape.** All errors from one module share a prefix
  (`"exec: …"`, `"cli: …"`, `"protocol: …"`) so tests and humans triage on sight.
- Default to the built-in `Error` with a well-shaped message. Reach for **typed
  errors** only when a caller genuinely branches on error kind — a function
  declares at most one error type, and typed errors don't capture stack traces.
  Don't invent an error-type hierarchy speculatively.
- Re-raise with `raise e^` after adding context; wrap foreign/FFI errors at the
  exec boundary rather than letting a raw errno leak through a public function
  whose docstring never mentioned it.
- Use `comptime assert` for invariants knowable at compile time (inside a
  function body); `debug_assert` for caller contracts on hot paths.

---

## Memory, allocation, and cleanup invariants

- **Say whether a function allocates** in its docstring. The capture buffers in
  `exec` are the obvious allocators; a reader tracking behavior must know without
  reading the body.
- **Know your conventions.** The default `read` convention is a free borrow. Take
  `Span[Byte]` views instead of copying capture buffers; pass `mut` to fill a
  caller's buffer; transfer with `^` at last use. Keep big types `Copyable` but
  **not** `ImplicitlyCopyable`, so every copy of a config or a result buffer is a
  visible `.copy()` in review.
- Prefer the safe types (`List`, `Span`, `InlineArray`, `Pointer`,
  `OwnedPointer`) over raw `UnsafePointer`. FFI forces `UnsafePointer` at the
  `exec` boundary — when a struct genuinely owns an fd or heap bytes, give the
  field an explicit origin, release the resource in `__del__` (close the fd, free
  the buffer), and prove the round-trip with a construct-and-drop test. **The fd
  is the resource that leaks; treat closing it like freeing memory.**
- Pre-size what you can: `List[Byte](capacity=n)` when a bound is known; reuse
  buffers across the spawn loop instead of reallocating per file.

---

## Module boundaries

- **One responsibility per file**, layered one direction (authoritative graph in
  [AGENTS.md](../../../AGENTS.md) and mirrored in `src/mtest/__init__.mojo`):
  `model` → `config` → `discover`|`protocol`|`report` → `exec` → `session` →
  `cli`. Never import "up"; a cycle is a bug. Structure findings and refactor
  planning live in [improve-architecture](../improve-architecture/SKILL.md).
- **`src/` is pure Mojo.** Python exists only under `scripts/` (build/test
  harnesses) and `tests/fixtures/exec/` (test-only subprocess actors). A
  `from mtest import ...` under `src/` is a Mojo import of *this* package.
- **Generated source is a golden that happens to be source.** Any file emitted by
  a generator carries a provenance header and is **never hand-edited** — fix the
  generator and regenerate, exactly like a transcript.
- **Internals behind seams.** `exec` hides every fd, syscall, and pipe behind
  `run_supervised`; `session` must not be able to tell how supervision works. If a
  caller can see an fd or a poll, the seam has failed.
- **`__init__.mojo` is the package's public surface** — re-export the clean names
  so callers write `from mtest import run_supervised`, and files can move inside
  the package without breaking them. No executable top-level code.

---

## Language gotchas that bite in this repo

The `mojo-syntax` skill has the full language list; AGENTS.md **Lessons** has the
pinned-`1.0.0b2` incident log (read it before non-trivial Mojo). The ones that
recur in FFI/subprocess/parser code:

- **FFI naming collisions.** `external_call["write", ...]` collides with the
  stdlib's own `write` — never re-declare it. A helper taking
  `UnsafePointer[T, _]` gets an IMMUTABLE origin; write fields inline where the
  pointer has its concrete `alloc` origin.
- **String ↔ C string / bytes.** String→cstring is
  `s.as_c_string_slice().unsafe_ptr()`; bytes→String is
  `String(StringSlice(unsafe_from_utf8=Span(list)))`. `String` is UTF-8 and
  byte-indexed — no `s[i]`; the keyword form `s[byte=i]` is the only index.
  `len(s)` warns; use `.byte_length()`. Prefer `startswith` / `removeprefix` /
  `split` for protocol-line parsing.
- **`List` has no variadic constructor** — bracket literals: `var v = [1, 2, 3]`.
  **Negative indices are rejected** at compile time — `lst[len(lst) - 1]`.
- **Explicit copy/transfer** for non-`ImplicitlyCopyable` types: `.copy()` or
  `^`. You cannot `^` a single field out of a still-live aggregate.
- **`posix_spawn` is a dead end on 1.0.0b2** (the stdlib passes NULL
  file_actions/attr) — fork+exec is the route; don't reach for it.
- **Compiler stalls (#6554-class):** a test module whose function count grows too
  large stalls TestSuite discovery for minutes — a known toolchain bug. Keep test
  modules small; split along the natural seam and record the pattern in AGENTS.md
  Lessons; don't sit waiting.

---

## Review checklist for a Mojo change

- [ ] `pixi run fmt` clean, `pixi run ci` green (fmt + build + transcripts + tests)
- [ ] Every public function states what it does + mutate/allocate/raise
- [ ] Binaries are build-then-executed; `mojo run` appears nowhere
- [ ] Crash ≠ fail preserved: `Signaled` never collapsed to `Exited`; status decoded structurally (never 128+N); a deadline kill is a distinct `TimedOut`
- [ ] Child path after `fork` touches only async-signal-safe calls; all allocation is pre-fork; the kill targets the process GROUP; both pipes drained to EOF before `waitpid`
- [ ] Parser anchors on the LAST `Running <N> tests for`; a test's printed report-lookalike is not miscounted; declared == rows == summary reconciled
- [ ] Every raise named and located (`module: what + value`); tested with `assert_raises(contains=...)`; a child's nonzero/crash is DATA, not a raise
- [ ] `raises` present iff the function can raise; hot cores total, boundaries validating
- [ ] fds and buffers released in `__del__`; no fd growth across repeated spawns
- [ ] All comparisons exact — no tolerance on exit codes or counts
- [ ] Imports point down the layering; `src/` pure Mojo; all FFI confined to `exec`
- [ ] Syntax matches `mojo-syntax` (no `fn`/`let`/`alias`/`@parameter`/`inout`/`owned`)
- [ ] New behavior has a test that would fail without it
