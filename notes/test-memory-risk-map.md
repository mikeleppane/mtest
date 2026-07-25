# Memory-safety risk map

Every mechanically unsafe or native-backed ownership boundary in the product,
and the executable evidence that covers it. An entry here is a claim about what
*runs*, not about what exists: where nothing instrumented executes a site, the
entry says so and gives the reason.

## How to regenerate the inventory

The lexical inventory this map is built from is the one `pixi run safety-check`
enforces — a `# SAFETY:` comment beside every candidate operation:

```text
grep -rn '# SAFETY:' src/
```

98 product sites at the time of writing, across 13 files. The two prose mentions
in `src/mtest/platform/__init__.mojo` and `src/mtest/exec/tty.mojo` are docstring
text explaining why those modules carry no site, not sites themselves; the
checker's `^\s*#\s*SAFETY:` anchor excludes them, and so does this map.

The 41 `# SAFETY:` sites under `tests/` and `e2e/` are deliberate test-only
constructions (fault injection, the ASan controls, a segfault fixture). They are
excluded from this map: they are the instruments, not the subject.

## The lanes

| Tag | Lane | What it proves |
| --- | --- | --- |
| **A** | `pixi run asan-check` | AddressSanitizer + LeakSanitizer over source-built product code. Catches out-of-bounds, use-after-free, and leaks in the Mojo-side ownership of native buffers. |
| **V** | `pixi run valgrind-check` | Memcheck over source-built product code with `--track-fds=yes`, `--track-origins=yes` and no suppressions. Catches the same classes plus undefined-value reads and descriptor leaks, and pins the runtime-reachable baseline. |
| **N** | native C tests under **V** | `tests/native/test_exec_native.c` and `test_exec_native_signals.c`, linked against the adapter and run in Memcheck. Covers the C side of the boundary the Mojo sites call across. |
| **C** | the real-CLI reporter probe | One fixed `mtest` run, source-built and instrumented, in **both** A and V. It is the only evidence that executes `src/main.mojo` and the surfaces reachable only from it. |

Neither A nor V is part of `pixi run ci`. GitHub runs them as separate matrix
cells, so a regression in either is invisible to the local floor unless the lane
is run explicitly.

### What the CLI probe (C) actually runs

A scratch invocation root holding one `mtest.toml` and one generated test
module, driven by:

```text
mtest --config <scratch>/mtest.toml -k hostile \
      --mojo scripts/fixtures/toolchain/fake_hostile_mojo.py \
      --json <scratch>/hostile.ndjson --junit-xml <scratch>/hostile.xml
```

The `--mojo` stand-in never invokes the real compiler: it writes an executable
copy of `tests/fixtures/exec/hostile_report_actor.py`, which emits invalid UTF-8,
NUL/BEL/DEL/C1 controls, CSI and OSC sequences, JSON- and XML-injection
lookalikes, and then a genuine reconciling `TestSuite` report with one FAIL row.
So the run lands on a real verdict with real captured output, and every reporter
renders it.

Both the stand-in and the actor are children the CLI `execve`s. Under A they are
uninstrumented processes; under V the lane runs `--trace-children=no`, so they
are outside Memcheck. The subject is the mtest parent alone, by design — a
`mojo build` child under Memcheck would dominate the runtime and report on a
toolchain this project does not own.

The probe asserts, each for one named reason: the client exit code, the escaped
rendering of the child's CSI sequence, the absence of any raw ESC/NUL/BEL/DEL
byte, the promoted `.mtest-cache/lastrun` state file, the NDJSON artifact
through `scripts/checks/reports/json_stream.py`, and the JUnit artifact through
`scripts/checks/reports/junit.py` (xmllint against the vendored `junit-10.xsd`,
then the arithmetic invariants). The Valgrind copy additionally asserts its own
Memcheck provenance — the banner, `ERROR SUMMARY: 0 errors from 0 contexts`, the
expected `FILE DESCRIPTORS: 3 open (3 inherited) at exit.`, and the exact client
exit code — because "no errors reported" and "the probe never ran wrapped" are
indistinguishable without it. The ASan copy asserts the equivalent positive
witness in its own way: `LSAN_OPTIONS=verbosity=1` makes LeakSanitizer announce
`LeakSanitizer: checking for leaks` from inside the process under test, so a
clean run proves the leak check *ran* rather than merely not complaining.

## The map

| File | Sites | What they are | Evidence |
| --- | --- | --- | --- |
| `src/mtest/exec/supervise.mojo` | 52 | argv/env C-string marshalling, the `_NativeBuffers` allocation/free pair, every adapter syscall wrapper (poll set, fd limit, monotonic clock, process open/close, poll, read quantum, setup drain, group, observe, close channel, reap, abort), `Completion.query_effective_cap`, `Supervisor` construction/teardown | **A** 10 exec/session suites · **V** 13 `test_exec_*` suites · **N** both adapter lifecycle binaries · **C** |
| `src/mtest/exec/signals.mojo` | 13 | signal-runtime open/close, the ABI-v1 error record's alloc/read/free including the destructor fallback, the installed/pending queries, `kill(2)` | **A** `test_exec_interrupt`, `test_exec_pool`, `test_session_schedule` · **V** `test_exec_interrupt` and every other exec suite · **N** `test_exec_native_signals.c` · **C** (the CLI opens and closes the runtime for the run) |
| `src/mtest/platform/regular_file.mojo` | 15 | `open(2)`, `fstat(2)` into a 144-byte aligned record, the bounded read loop's pointer arithmetic, and the buffer free on every exit path | **C** only, and only partially — see the gap below. It has four product callers: `src/main.mojo:304` (config file) and `:383` (last-run state), and `src/mtest/cli/doctor.mojo:259` (config file) and `:519` (last-run state). All four are above the `cli` layer, so no unit or integration suite in either lane reaches any of them. The probe's explicit `--config` makes `main.mojo:304` mandatory — an unreadable file named on the command line is a usage error, not a silent skip. |
| `src/mtest/platform/stream.mojo` | 7 | the `errno` location call (Darwin and Linux spellings), `read(2)`, `write(2)`, `creat(2)` (both spellings), `close(2)` | **A** `test_report_json_reporter` (descriptor open, bounded write loop, close) · **A**/**V** `test_report_junit_finalize` · **C** (NDJSON, JUnit, and state writes) |
| `src/mtest/platform/temp_file.mojo` | 3 | `mkstemp(3)` over a mutable template buffer, the post-call template rebuild, and the byte scan that validates it | **A**/**V** `test_report_junit_finalize` · **C** (state temp file and the JUnit target temp file) |
| `src/mtest/platform/fs.mojo` | 1 | `rename(2)` | **A**/**V** `test_report_junit_finalize` · **C** (state promotion, JUnit temp → target) |
| `src/mtest/platform/process.mojo` | 1 | `getpid(2)` | **A**/**V** `test_report_junit_finalize` (the spool prefix) · **C** (state temp template, scratch naming) |
| `src/mtest/report/escape.mojo` | 1 | `unsafe_from_utf8` over the escaper's rebuilt byte buffer | **A**/**V** `test_report_escape` · **C** |
| `src/mtest/report/junit.mojo` | 1 | `unsafe_from_utf8` over the XML text escaper's byte buffer | **A**/**V** `test_report_junit` · **C** |
| `src/mtest/report/json_stream_reporter.mojo` | 1 | a `String`'s bytes borrowed across a partial-write loop, with derived pointer arithmetic per iteration | **A** `test_report_json_reporter` · **C** (its only Memcheck evidence — see the exclusion below) |
| `src/mtest/report/console.mojo` | 1 | `unsafe_from_utf8` over the drained byte suffix of the console's head buffer | **C** only. `tests/unit/test_report_console.mojo` covers it in the plain `pixi run test` lane, but is not in either instrumented inventory; the probe drives the same drain with a hostile capture in it. |
| `src/mtest/select/selection.mojo` | 1 | `unsafe_from_utf8` over the ASCII case fold in `contains_ci` | **C** only, via the probe's `-k hostile`. The probe carries that flag for exactly this reason. |
| `src/mtest/config/lossy_utf8.mojo` | 1 | the UTF-8 validity scan's leading-byte and continuation bounds | **A**/**V** `test_exec_capture` — `test_lossy_utf8_replaces_invalid_preserves_valid` calls it directly on a lone `0xFF`, and `bytes_to_str` in `tests/support/exec_helpers.mojo` routes every capture assertion in that suite through it · **C** (the actor writes bytes no decoder accepts, so the lossy path runs on real hostile input). NOT `test_config`: `mtest.config` only re-exports the symbol (`src/mtest/config/__init__.mojo:41`), and `tests/unit/test_config.mojo` never calls it. |

## Exclusions, with reasons

- **`src/mtest/platform/__init__.mojo:18` and `src/mtest/exec/tty.mojo:19`** —
  prose in module docstrings, not sites. `tty.mojo` says so explicitly: it has
  no raw FFI call to document.
- **`tests/**` and `e2e/**` sites (41)** — test-only constructions. Three of them
  (`tests/native/asan_*_control.mojo`) exist to be caught by ASan and are run as
  negative controls in lane A on every invocation; the rest are fault-injection
  fixtures whose unsafe operations are the instrument under test elsewhere.
- **Darwin-only branches** in `platform/stream.mojo` (`__error`, the Darwin
  `creat`) — unreachable on the Linux hosts where A, V and N run. They are
  compile-checked for macOS from Linux (`mojo build --target-triple
  arm64-apple-macosx14.0.0 --emit=asm`) and exercised by the macOS test cell,
  which has no sanitizer lane. This is a real residual gap, not a claim of
  coverage.
- **`tests/unit/test_report_json_reporter.mojo` from lane V** — its subject *is*
  descriptor misuse. One test hands the reporter a descriptor it closed first so
  the header write must latch `EBADF`; another closes the same descriptor twice
  so the second close must report the failure rather than swallow it. Memcheck's
  `--track-fds=yes` reports both, correctly. Running it with `--track-fds=no`
  would drop the descriptor channel for the one suite that is entirely about
  descriptors, and relaxing `check_product_output` would weaken the contract for
  the other seventeen. Lane A runs it unchanged — LeakSanitizer does not track
  descriptors, so the deliberate `EBADF` calls are inert there — and lane V still
  covers `open_json_fd`, `_write_all`, and `close_json_fd` on live descriptors
  through the CLI probe, under the full flag set. `scripts/tests/test_valgrind.py`
  pins both halves of that arrangement.
- **`MTEST_EXEC_TESTING=1` fault paths in `native/mtest_exec_native.c`** — absent
  from the production object by construction, which `pixi run native-check`
  proves by symbol inspection. The CLI probe links the production variant in both
  lanes, so it cannot reach them.

## Residual gaps

These are known and deliberate. Each is a place where the map claims *less* than
full instrumented coverage.

1. **One probe run covers one of `read_bounded_regular_file`'s four call sites.**
   The probe drives `src/main.mojo:304` (the config read). The other three are
   uninstrumented: `main.mojo:383` because the probe's first run has no state
   file yet, so `_load_state` short-circuits on `exists()` before reaching the
   reader; and both `cli/doctor.mojo:259` and `:519` because the probe never
   invokes the `doctor` subcommand. All four call the same function with the
   same ownership and the same two size bounds, so this is a gap in *entry
   points*, not in the code under the `# SAFETY:` comments — but a `doctor`
   regression in that reader would not be caught by either lane. Closing it
   would mean a second probe run for `doctor` and a third for a warm state file,
   roughly tripling the Memcheck wall time of this probe.
2. **The Valgrind CLI probe drops `possible` from `--errors-for-leak-kinds`.**
   The CLI initializes the Mojo async runtime's CPU device, which starts one
   unjoined worker thread per core; glibc's per-thread TLS descriptor table is
   then reachable only through an interior pointer and Memcheck classifies it
   `possibly lost`. The block count tracks the host's core count, so it cannot be
   pinned the way `EXPECTED_REACHABLE` pins the suites' baseline. The gate still
   rejects any possibly-lost or still-reachable record carrying a `src/mtest/`,
   `src/main.mojo`, or `native/mtest_exec_native.c` frame, and every other lane
   keeps `possible` as a hard error.
3. **No post-fork audit pass for the CLI probe.** The suites get a second,
   unsilenced Memcheck pass that audits the pre-exec fork child. The CLI forks
   for every build and every run child, so that pass would report on transient
   copies of the whole session state rather than on a decidable ownership claim.
   The exec suites already own that channel.
4. **The macOS platform branches have no sanitizer lane at all.** See the
   exclusion above.
5. **Both lanes hold their own copy of the probe definition.** The two gate
   drivers share no module, so the tree, the config, the argv, and the expected
   console rendering are defined twice. `scripts/tests/test_valgrind.py`
   asserts the two copies are equal constant-by-constant, so a divergence is a
   test failure rather than two lanes silently probing different programs.
