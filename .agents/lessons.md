# mtest lessons

Failure modes this project has already hit, each with the correct move.
`AGENTS.md` holds the doctrine and the gate rules; this file holds the detail
behind them. Read the section that matches what you are about to touch, and
append here as later phases teach more.

## Toolchain and protocol

- `mojo run` masks crash exit codes to `1` and can JIT-crash in CI. Never use
  it in the gate. Direct-executed `std.os.abort` exits `132` at the shell on
  linux-64 (`128 + SIGILL`); on osx-arm64 the trap is SIGTRAP. The transcript
  generator records the raw signal number structurally, never `132`.
- `mojo build` bakes the absolute canonicalized source path into every location
  line, even when built with a relative path, so transcript portability
  requires normalizing the repo-root prefix to `<REPO>`.
- `mojo format` and `mojo build` do not accept the same source. `where` is a
  keyword the formatter rejects as an identifier while the compiler accepts it,
  so a green build is not evidence the file is well-formed. Never discard a
  gate's output to keep a log tidy: `pixi run fmt` failed silently for several
  commits that way, and only `fmt-check` in CI surfaced it.
- Discovery order is source order (`__functions_in_module()` yields source
  order); the fixtures pin this deliberately with non-alphabetical functions.
- TestSuite buffers its whole report and flushes it at the end, and on failure
  it raises the report, so the block arrives after the runtime's `Unhandled
  exception caught during execution:` line. Anchor on the last `Running <N>
  tests for` line that is followed by a `Summary` line, never the first match;
  a `Running`-lookalike a test prints before crashing has no Summary.
- `suite.skip[f]()` exists (manual construction form); a natively-skipped test
  emits a normal `SKIP` row, distinct from selection-induced SKIPs.
- A bare `abort()` emits no `ABORT:` line, so crash fixtures must pass a
  message. A malformed `test_` function raises a discovery-time runtime error,
  not a compile error.
- The crash stack dump has two forms (symbolized and not); the normalizer
  collapses both to `<STACK-DUMP>` and hard-asserts that every collapsed line
  matched a frame pattern.
- The report colorizes only on a TTY, and mtest and the generator capture
  through pipes, so the parser sees plain text.
- `mojo package` does not exist in 1.0.0b2; `mojo precompile` produces the
  `.mojopkg`.
- The module cache is redirectable via `MODULAR_CACHE_DIR`. `mojo build` is
  multi-threaded by default (`--num-threads`), so parallel worker sizing must
  not oversubscribe compiler threads.
- `mojo precompile` is NOT byte-reproducible: two runs over identical inputs
  produced packages digesting `43fcef41...` and `eb81d1f7...`. Nothing may
  assume a rebuilt `.mojopkg` is byte-stable, and any digest taken over one is
  a fingerprint of *that* build, not of its inputs. The consequence compounds:
  a precompile step that re-runs rewrites its package and therefore moves
  every key derived from it, so a build cache over a project that precompiles
  anything only hits if the unchanged step is *skipped*. Both the production
  build stage and configured `precompile` steps are stamped against their
  inputs for exactly that reason. Prove it by making the second run skip the
  stage — identical bytes because nothing was written, never because the
  compiler settled down.
- A killed `mojo build` never corrupted its cache in a nine-trial kill probe
  (strict temp-then-rename atomicity observed). The per-attempt quarantine dir
  is defense-in-depth for residual risk, not a fix for observed corruption.

## Process supervision

- EOF on both read pipes is not completion: a child terminates only when
  `waitpid` reaps it. Enforce the deadline with `waitpid(WNOHANG)` in a poll
  loop and never issue a blocking `waitpid` after EOF. Every kill targets the
  process group (`kill(-pgid, ...)`, via `setpgid`), because a grandchild
  inherits the pipe write end and killing only the direct child leaves the
  parent's read blocked forever. After `fork` the child may call only
  async-signal-safe functions before `exec`, and `/bin/sh -c` is not a
  substitute. This machinery ships in the native C adapter.
- Native adapter ABI v2 runs a pool: a fixed slot table
  (`MTEST_EXEC_SLOT_CAPACITY`, 64) where `process_open` claims a free slot, and
  `EBUSY` means only capacity exhausted or an unusable runtime. Any adapter
  change is a deliberate gated edit to `native/`, never a workaround.
- Signal handling and the supervision syscalls live in the native C adapter,
  not Mojo FFI. `src/mtest/exec/signals.mojo` calls the `mtest_exec_*` ABI, and
  the interrupt latch surfaces as `interrupt_requested() -> Bool`. Never
  reintroduce Mojo-side syscalls, sigaction layouts, or fixed mmap pages
  (historical hazards: `std.ffi._Global` crashes the compiler; a Mojo `def`
  used as a C callback needs one deref to recover the code pointer).
- The cache quarantine is per-child, never a parent-env mutation: the
  quarantined `MODULAR_CACHE_DIR` rides `ProcessSpec.env_extra`, appended to
  the child's environment only, so concurrent workers never race a shared
  parent `environ`. Never reintroduce a setenv/unsetenv-around-spawn pattern.
  It was safe only single-threaded, and the pool retired it.
- Dynamic-loader fault injection (`LD_PRELOAD`/`DYLD_INSERT_LIBRARIES`)
  inherits into every spawned process, including `mojo build` children. A
  test-only interposer clears its loader variable in a constructor after
  loading into mtest, unless descendant instrumentation is the subject.
- Valgrind needs an instruction-set ceiling: hosted runners may advertise
  x86-64-v4 and Mojo then emits EVEX instructions Valgrind cannot decode.
  Compile the Valgrind-exercised binaries with `--target-cpu x86-64-v3`.
- The adapter releases a process record only once its leader is reaped, its
  group is swept, and all THREE read channels are closed, the setup channel
  included. A teardown path that abandons a slot has to close that channel
  rather than drain it: an abandoned slot yields no `Completion`, so nothing
  can consume the setup record. The setup pipe is close-on-exec, so the
  parent's end reaches EOF only when the child completes `execve` — a child
  killed before it gets that far, or a slot abandoned before its first sweep,
  leaves it open, and `process_close` then reports EBUSY on a teardown that had
  otherwise finished. On an idle host the child always wins that race, so the
  defect only appears on loaded runners. Every existing `kill_all` test
  resolved the setup channel first (waiting on a readiness file, or pumping
  sweeps), which is how the gap survived.

## Parsing and verdict discipline

- A parsed report is trusted only via triple reconciliation: header count, row
  count, and Summary totals must all agree, and the row-level tally must equal
  the Summary tally. Two or more complete well-formed report blocks for one
  path classify AMBIGUOUS, never "last wins".
- Under `--only`, a natively-skipped selected test and a deselected test are
  byte-identical SKIP rows, so reconcile against the names mtest itself
  selected. A SKIP on a selected name is a native skip; a SKIP on a
  non-selected name is a deselection; a non-selected row that is not SKIP is
  MALFORMED-SUITE.
- On a truncated capture, re-parse only the text after the last
  truncation-marker line and accept only a fully valid parse there; otherwise
  the file is a capture-overflow FAIL, never a PASS.
- Reconciliation, suppression, and membership disagreements are user-class
  failures (MALFORMED-SUITE, exit 1), never exit 3. Exit 3 (drift) is reserved
  for a genuine off-grammar report from the pinned toolchain. When both
  explanations are open, blame the file.
- The crash-class retry classifier (`retry_class`) retries only a signal death,
  a deadline kill, or a compiler crash (by signal, or a pinned ICE stderr
  signature on nonzero exit). That signature list is assumption-pinned and has
  never been validated against an observed real ICE, so extend it when a real
  one shows a new banner. A process that exited under its own control, at any
  code, is deterministic and never retried.
- A grammar that reserves a character has to enforce the reservation, or the
  reservation becomes a lie the diagnostics tell. `::` was documented as
  unsupported in a file path and unchecked, so a walk collected
  `tests/co::l/test_x.mojo` and ran it while no operand could address it: an
  operand splits at its FIRST separator, so the refusal read
  `no such path 'tests/co'` — a path the caller never typed. Two rules follow.
  A diagnostic quotes the token as typed, never a fragment a splitter produced.
  And the check belongs at the ONE seam that resolves a token against the world
  (discovery), not scattered across every consumer of the splitter. Unenforced
  rules also grow consumers while nobody is looking: `docs/collect-stream.md`
  had begun telling readers how to parse ids the runner refused to act on.
- BuildProducts registry replacement is atomic (whole-slot): always replace the
  whole product on rebuild, never patch a field, so no stale canonical-source
  or listing survives.
- A content-addressed artifact needs TWO proofs, not one: the key must name
  every input, and publication must prove the artifact came from the snapshot
  the key names. They fail differently, so covering one hides the other. An
  input edited between key time and compile time is *in* the key and still
  produces a binary filed under a digest of bytes the compiler never read;
  undo the edit — ordinary, not hostile — and the tree looks untouched while
  every later run hits. Re-verify at publication, where the cost lands only on
  a miss that already paid for a compile.
- Publish before you run. When a build is staged somewhere and then moved, the
  process that runs it first and records it second reports a path it did not
  execute. The failure is invisible cold and appears warm — the direction that
  reads as a real regression — and it needs a test that makes the child observe
  its own `argv[0]`, because nothing else in a verdict can tell the two apart.
- An executable spelled with a `/` is resolved against a working directory, and
  a supervisor that `chdir`s before `execve` does not share the parent's. Any
  identity taken over such a spelling must be anchored to the directory the
  CHILD will use, or the key names one file and the run executes another.

## Mojo language, pinned toolchain

- `fn` is fully removed, including as a function-value type: write
  `def(...) -> ...`.
- A tuple return annotation `-> (Bool, Int)` does not compile; return a small
  `@fieldwise_init` struct.
- `exit()` is not `noreturn` to flow analysis; seed a sentinel before a `try`
  whose branches all exit, with a comment saying why.
- `UnsafePointer` is non-nullable, and `unsafe_from_address=0` fails at compile
  time. For a NULL argv terminator, over-allocate by one and `memset_zero`. Use
  the free `alloc[T](n)`; `.alloc`/`.offset` methods do not exist.
- `UnsafePointer[T, _]` helper arguments get an immutable wildcard origin, so
  write struct fields inline at the call site where the pointer still has its
  concrete mutable origin.
- String to C string: `s.as_c_string_slice().unsafe_ptr()`. Bytes to String:
  `String(StringSlice(unsafe_from_utf8=Span(list)))`.
- A closed-vocabulary Int-wrapping struct must conform to `ImplicitlyCopyable`
  or its comptime constants fail to materialize. Large owning structs stay
  `Copyable, Movable` only, so every copy is a visible `.copy()`; that is house
  discipline, not compiler-forced (`String` is `ImplicitlyCopyable` in
  1.0.0b2).
- `Int(String)` raises on non-digit input, so a pure non-raising parser
  hand-rolls digit-by-digit parsing. `std.os.path.realpath` exists for
  canonicalizing to the exact string `mojo build` bakes into reports.
- Filesystem stdlib: `std.os` / `std.os.path` / `std.tempfile` (no
  `std.shutil`, no `rmtree`; delete recursively by hand). `isdir`/`isfile`
  follow symlinks, so a recursive delete driven by them removes a link
  target's contents; characterize with `lstat` and unlink the link. `listdir`
  is unsorted; sort with `from std.builtin.sort import sort`.
- Fanning one event to N heterogeneous reporters is a comptime variadic pack:
  `struct Composite[*Rs: Reporter]` holding `Tuple[*Self.Rs]`, dispatched with
  `comptime for`. Traps: write `Self.Rs` inside the struct; build the tuple at
  the call site and move it in (a `VariadicPack` cannot be splatted into
  `Tuple`); iterate with the comptime `Self.Rs.__len__()`. The composite cannot
  synthesize `Copyable`, but `Movable` does synthesize with explicit
  conformance, which is how a coordinator owns its pack, and the pinned
  compiler accepts a movable-only pack when a reporter owns a non-copyable
  resource.
- Reaching a concrete reporter back out of a `CompositeReporter[*Rs]` pack
  takes a comptime index plus a typed reference binding, never a bare `rebind`,
  so a wrong index fails to compile instead of being UB. That reach is
  legitimate only for a test driver pulling its own recorder out of a pack it
  composed; session-level reporter lifecycle goes through `ReportCoordinator`.
- A `comptime if` guard confines only its own block. Statements after the block
  compile for every target, so a `comptime if CompilationTarget.is_macos():`
  that returns inside the branch, followed by a bare
  `comptime assert CompilationTarget.is_linux()`, fails to instantiate on macOS
  and takes the whole binary with it. Every platform branch carries an explicit
  `else`, holding that target's asserts and its return.
- A raw `external_call["isatty", ...]` link-conflicts with
  `std.io.FileDescriptor`'s own declaration once imported next to TestSuite, so
  delegate to the std wrapper. The same discipline governs `write`.
- `print(text, file=FileDescriptor(fd))` OWNS the descriptor it wraps: the
  temporary's teardown closes it, and closing an already-closed descriptor
  faults inside `_IO_fclose` and kills the process with SIGSEGV — a status
  outside every documented exit domain, reached after the command had already
  done its work. `>&-` on any subcommand exposed it. A write to a descriptor
  this process merely BORROWED (stdout, stderr, a console handle main lends the
  session) goes through the raw `write(2)` under `platform`, never a
  `FileDescriptor`. Reading is not the same hazard: `FileDescriptor(fd).isatty()`
  on a closed descriptor was probed and returns cleanly; it is the printing path
  that closes.
- `external_call` emits a NON-variadic call. On Darwin arm64 a variadic
  argument travels on the stack while the emitted call passes it in a register,
  so a variadic argument libc actually *consumes* is silent garbage there while
  Linux passes — `open(2)`'s mode under `O_CREAT`, `fcntl`'s under `F_SETFL`.
  Reach for a fixed-ABI sibling (`creat` instead of `open`+`O_CREAT`), or keep
  the variadic argument unconsumed and say in the SAFETY comment why libc never
  reads it.
- ONE `external_call` declaration shape per libc symbol repo-wide. Arity is
  part of the shape, and a second declaration with a different one breaks the
  link from a file that has nothing to do with either call site — the error
  surfaces at archive time and names neither. `open` is fixed at arity 3 in
  this tree (`platform/regular_file.mojo`, `platform/stream.mojo`); grep for an
  existing declaration before writing a new one.
- `isdir` / `isfile` / `islink` fold every error into `False`, so "I could not
  characterize this" becomes "it is not there" and a thing that should have
  been examined is skipped in silence. Where the difference decides anything,
  use `lstat` + `S_IFMT` (raises, and does not follow) or `listdir` (raises,
  and tells "empty" from "unreadable"). A directory listing read with `isfile`
  cannot tell a missing `__init__.mojo` from one it was not permitted to stat,
  and those two answers lead to opposite decisions.
- A directory can be readable but not *searchable* (mode `0644`): `listdir`
  succeeds and every `stat` inside it fails. A walk built on
  fold-errors-to-`False` predicates then finds nothing, frames nothing, and
  reports success over a tree it never saw. Fail the walk on the first entry it
  cannot characterize.

## Harness and workflow

- `mojo` resolves only through the pixi environment's `PATH`, so a binary that
  spawns `mojo` children must run under `pixi run`. Never scrub the environment
  before such a spawn. A `pixi run`-less invocation of the e2e driver fails
  many scenarios with `INTERNAL-ERROR ... could not execute 'mojo' (errno 2)`.
  Errno 2 on `mojo` means wrong environment, not broken code.
- Do not move a compiled artifact between hosted runners. Restoring the
  build-artifact store across runs was tried and reverted: `KeyBuilder` frames
  the compiler, the toolchain libraries, the environment, the invocation root,
  the build arguments, the include-root contents, and the file's own bytes, and
  nothing about the host CPU — which is complete on one machine, where the CPU
  cannot change between two builds. A binary compiled where a wider instruction
  set was available is a valid cache hit and an illegal program; the restored
  e2e binaries died with SIGILL. This is the same hazard the Valgrind
  `--target-cpu` ceiling above exists for, reached from the other direction.
  "A stale entry is a miss, never a wrong pass" holds only for the inputs the
  key actually frames, and a digest check cannot notice that a byte-perfect
  binary is illegal on this host.
- Capture a gate's real exit as its own statement (`cmd; echo "x=$?"`); a
  trailing pipe silently reports 0.
- An E2E oracle that reads compiler-wrapper side effects (invocation counts,
  build windows, or wrapper-created logs) must pass `--no-cache`. A warm
  artifact store returns before the wrapper is invoked, so the same oracle is
  green on a cold checkout and either empty or one invocation short on the
  second run. This rule applies only when compiler dispatch itself is the
  evidence; the dedicated cold-then-warm cache scenario deliberately keeps the
  cache enabled.
- One test module is one process under one run deadline (300s by default), so a
  module that keeps growing eventually reports TIMEOUT — the one verdict that
  says nothing about the code — and it lands first on the slowest machine in
  the matrix, not locally. Modules whose cases spawn real compilers are the
  ones to watch. Splitting is cheap (the gates derive membership from the
  tree) and split by SUBJECT, never by stopwatch, so the boundary survives the
  next case. Measure the split: cases that were cheap inside a warm process
  pay a cold compiler cache once they are alone, so the total rises even as
  the worst file — the only number the deadline sees — falls.
- The harness gates derive membership from the tree, not from a committed
  list: `scripts/checks/layout.py` and `scripts/harness/selfhost.py` both
  compute their expected suite/fixture/test inventory from disk on each run,
  so adding a new suite, fixture, or test function costs zero ledger edits.
  The boundary that buys: the oracle proves mtest ran every test the sources
  declare *right now*; it cannot prove the sources still declare every test
  they used to. A file dropping from N tests to M (M > 0) is invisible to
  every gate and is a reviewable diff, not a runner defect. A file reaching
  **zero** `test_*` functions is loud and fails closed. See
  `scripts/harness/selfhost.py`'s module docstring for the full argument.
- `mojo precompile` rejects `--target-triple`, so a cross-target check cannot
  reuse the host-target packages under `-I build`; compile from sources with
  `-I src -I vendor/mojo-toml`. There is no test aggregate to cross-compile
  anymore -- each classified module is its own program -- so the equivalent
  coverage is one `--target-triple --emit=asm` invocation per classified
  `test_*.mojo` file (101 of them today; `-I tests/support` added on top of
  those for the integration modules importing `exec_helpers`/
  `session_fixtures`; no `-I .` needed since a standalone file never imports
  another classified module by its `tests.unit.*` package path), and nobody
  has scripted or timed that sweep yet. Omitting an include prints bogus
  `statement indentation must match the rest of the block` errors in files
  that parse fine; resolve the module, never the indentation.
- Never run two builds against the shared `build/` tree at once. A racing build
  corrupted `build/mtest.mojopkg` mid-write and looked exactly like a real
  regression. Builds run one at a time.
- Two mtest processes over one checkout is ORDINARY — `--shard` splits a suite
  across exactly that, and so does a second terminal. Any directory creation on
  that path must be idempotent: `_ensure_dir` was check-then-create, both
  processes saw `build/bin` absent, and the loser's raise surfaced as an
  internal error and exit 3 on a run whose only fault was being second.
  `makedirs(..., exist_ok=True)`, and treat every check-then-act over a shared
  path the same way.
- Never assert on a POSITION in a user-visible stream. Two integration suites
  indexed events by literal offset; the `cache-off` warning that now precedes
  the first file shifted every index, and one of them unpacked the wrong
  payload variant, aborted with SIGILL, and took every test in that binary with
  it. Match on event kind and search for the record you mean. The same trap in
  a gate is quieter: `layout-check` counted lines starting with `mojo
  precompile`, the build script moved those into `PRECOMPILE_CMD_*` arrays, and
  the gate silently became "exactly zero, and there are none" — green on a
  claim it had stopped making. Anything a feature can add — an event, a
  warning, a child process, a spelling — turns an exact-position or
  occurrence-count assertion into a landmine. Assert the property, not the
  offset, and make the failure report the count it actually found.
- A regression guard must be shown to fail when its property is broken:
  mutation-prove it (break the property, watch it go red, revert) before
  calling it a pin. "I ran it and it looked right" is an observation, not a
  guard.
- Mojo test binaries inherit a huge `RLIMIT_NOFILE` (~1M), making subprocess
  spawns from inside a Mojo test pathologically slow. Validate emitted
  artifacts via a separate Python CI gate over the real binary's output, and
  keep Mojo unit tests in-process.
- Multibyte UTF-8 anywhere in `native/*.c` (comments included) misaligns
  `postfork.py`'s byte-offset AST slicing. Keep `native/` strictly ASCII.
- A `DYLD_INSERT_LIBRARIES` interposer must not reach the real function through
  `dlsym(RTLD_NEXT, name)`. Under dyld that returns the interposer's own
  address, so every passthrough re-enters the library forever (a probe on
  macos-15 arm64 shows identical pointers for both `open` and `close`). Call
  the real function directly by name, since dyld does not apply interposing
  tuples to the image that declares them, and keep `dlfcn.h` inside the
  non-Apple branch so the wrong mechanism is unreachable. `LD_PRELOAD` is the
  opposite: there `dlsym(RTLD_NEXT, ...)` is correct. Confine the split to a
  passthrough layer so the fault logic stays single-sourced.
- That self-recursion presents as two unrelated-looking bugs, depending on
  whether the compiler can elide the frame: a `va_start` wrapper cannot be
  tail-called, so it overflows the stack and dies with SIGSEGV and no output,
  while a fixed-arity wrapper tail-calls itself, reuses one frame, and spins
  until the harness timeout. A segfault and a hang in the same subsystem can
  share one cause; look for a common mechanism before splitting the
  investigation.
- Mojo's `CodepointSliceIter` aborts inside its own `__next__`
  (`Optional.value() called on empty Optional`) on macOS arm64 while working on
  Linux x86_64. Scanning sites over known-ASCII tokens walk bytes with
  `s[byte=i]` over `byte_length()`; reserve codepoint iteration for input that
  genuinely is not ASCII. `vendor/mojo-toml` documents each converted site.
- Darwin's `killpg` reports EPERM, not ESRCH, for a process group holding only
  zombies. Group sweeps treat EPERM as "already gone"; reading it as a real
  permission error turns a finished scenario into a spurious harness failure
  and destroys the diagnosis it was supposed to produce.
- A test whose expected outcome is "the operation fails" cannot refute a
  hypothesis that the mechanism is broken, because it passes either way.
  Retiring a theory needs a probe whose pass and fail differ under that theory.
  Prefer reporting the disputed value directly (addresses, errnos, flags) over
  inferring it from a scenario verdict.
- A tool that commits captured program output containing filesystem paths must
  rewrite the ephemeral run root to a stable placeholder before writing (both
  the literal and realpath spellings), the way `scripts/gen_transcripts.py`
  does. `scripts/maintenance/console_svg.py`'s README SVGs are the deliberate
  exception: they are documentation, not oracle evidence, so the absolute repo
  root and wall-clock timings a fresh capture bakes in are expected residual
  variance, not a bug (`scripts/maintenance/pty_capture.py`, which never
  rewrote either, is deleted; `console_svg.py` is its surviving PTY-capture
  tool).
