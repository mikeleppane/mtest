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
- BuildProducts registry replacement is atomic (whole-slot): always replace the
  whole product on rebuild, never patch a field, so no stale canonical-source
  or listing survives.

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
  follow symlinks, so skip `islink` entries before recursing. `listdir` is
  unsorted; sort with `from std.builtin.sort import sort`.
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

## Harness and workflow

- `mojo` resolves only through the pixi environment's `PATH`, so a binary that
  spawns `mojo` children must run under `pixi run`. Never scrub the environment
  before such a spawn. A `pixi run`-less invocation of the e2e driver fails
  many scenarios with `INTERNAL-ERROR ... could not execute 'mojo' (errno 2)`.
  Errno 2 on `mojo` means wrong environment, not broken code.
- Capture a gate's real exit as its own statement (`cmd; echo "x=$?"`); a
  trailing pipe silently reports 0.
- The harness gates enforce explicit membership (`scripts/checks/layout.py`
  pins exact suite/fixture sets and counts), so register a new suite, fixture,
  snapshot, or e2e file in the same commit that adds it.
- `mojo precompile` rejects `--target-triple`, so a cross-target check cannot
  reuse the host-target packages under `-I build`; compile from sources with
  `-I src -I vendor/mojo-toml`. Cross-compiling the test aggregate needs
  `-I . -I tests/support` on top of those (generate the entrypoint first, about
  eighty seconds). Omitting an include prints bogus `statement indentation must
  match the rest of the block` errors in files that parse fine; resolve the
  module, never the indentation.
- Never run two builds against the shared `build/` tree at once. A racing build
  corrupted `build/mtest.mojopkg` mid-write and looked exactly like a real
  regression. Builds run one at a time.
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
  the literal and realpath spellings), the way
  `scripts/maintenance/pty_capture.py` and `scripts/gen_transcripts.py` do.
