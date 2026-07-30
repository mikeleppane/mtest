# Release Build Hardening Design

## Purpose

mtest's checked-out binary and distributed package must be warning-free, use a
portable CPU baseline within each supported package target, and be built with a
small set of measured hardening controls. Moving the macOS build host must not
silently raise the binary's deployment target. The ordinary developer commands
must enforce the same source-quality rules as CI so a new warning is found
during the first local build rather than after a pull request is opened.

The current production pipeline already has good foundations. One shell
entrypoint owns precompilation, the native C object, and the final Mojo link;
Mojo defaults to release-like `-O3` with no debug information; the C adapter is
compiled as C17 with `-O2`, strict baseline diagnostics, hidden visibility, and
no test-only symbols; and both supported package targets consume a
source-built artifact in hosted CI. This design makes those implicit
properties explicit, removes the remaining warnings, selects portable CPU
baselines, and adds focused C formatting and static-analysis gates.

This work does not change the CLI contract, the TestSuite protocol, the Mojo
toolchain pin, or the zero-runtime-dependency policy.

## Success criteria

The work is complete when:

1. Every production precompile and final Mojo build is explicitly warning-free.
2. Every classified repository test is compiled with warnings as errors, while
   mtest does not force that policy onto downstream projects.
3. Production binaries use `-O3`, no debug information, and documented Mojo
   and C CPU baselines instead of the hosted runner's detected CPU.
4. The native adapter passes curated Clang diagnostics, analyzer-only
   Clang-Tidy, and deterministic ClangFormat checks with pinned tools.
5. The production native object is compiled with
   `-fstack-protector-strong`, and the native audit proves the object contains
   stack-protector instrumentation.
6. Every arm64 hosted workflow uses the explicit `macos-26` runner without
   changing any job display name or required-check context, while the binary
   gains an explicit macOS 14.0 deployment floor.
7. The normal `build`, `test`, `fmt`, `fmt-check`, and `native-check` commands
   expose the new policies without adding a parallel set of warning-only
   commands.
8. Linux local verification and the pull request's native macOS 26 lanes pass,
   including packaged-artifact consumption.

## Supported production profiles

The production entrypoint maps the native supported platform tuple to one
profile and fails closed for every other tuple:

| Native platform | Package target | Mojo target | C target | Mojo mode |
| --- | --- | --- | --- | --- |
| Linux x86-64 | `linux-64` | CPU `x86-64`, native Linux triple | `-march=x86-64 -mtune=generic` | `-O3 -g0` |
| Darwin arm64 | `osx-arm64` | CPU `apple-m1`, triple `arm64-apple-macosx14.0.0` | `-mcpu=apple-m1 -mmacosx-version-min=14.0` | `-O3 -g0` |

`--target-cpu` is sufficient on Mojo 1.0.0b2: compiler probes show that
`x86-64` emits the baseline `cmov`, `cx8`, `fxsr`, `mmx`, SSE, SSE2, and x87
features rather than the build host's wider feature set. `apple-m1` similarly
selects the M1 feature set. The production command therefore does not pass an
empty or hand-maintained `--target-features` value.

The Darwin profile also exports `MACOSX_DEPLOYMENT_TARGET=14.0` for the link
driver. The explicit Mojo triple, C minimum-version flag, and environment value
agree on one floor; the final Mach-O audit rejects any other `minos`.

This design's portability claim is deliberately about CPU compatibility and
enforcing an explicit macOS floor. It does not establish or lower a new Linux
libc floor. Linux runners are already explicitly pinned to Ubuntu 24.04, and
the Mojo-produced binary currently references symbols through GLIBC 2.34 even
when the pinned Clang uses its conda sysroot. Changing that runtime boundary
requires a separate sysroot, package-metadata, and Mojo-runtime design.

The link command leaves `--num-threads` unset. Mojo documents its default as
zero, meaning all available compilation threads, so an explicit value would
only duplicate the compiler default or impose an arbitrary CI-specific cap.
This is separate from mtest's per-file worker scheduling, which already budgets
compiler threads across concurrent test builds.

## Production build authority

`scripts/build/production_build.sh` remains the single production authority
used by local builds and the isolated package recipe. Its three stages have
separate policies.

### Precompile

The checkout-owned vendored TOML parser and mtest package are precompiled as
`toml.mojoc` and `mtest.mojoc`. Mojo 1.0.0b2 accepts both `.mojopkg` and
`.mojoc`, but warns that the former extension is deprecated. Their build
stamps, task descriptions, checkout package-consumption checks, tests, and
documentation move together to the warning-free extension.

This is not a repository-wide extension migration. The frozen public
`--precompile SRC[:OUT]` contract continues to default user output to
`build/<name>.mojopkg`; its compatibility tests and documentation remain
unchanged. Changing that default requires separate approval.

Both precompile commands pass `--Werror`. CPU and optimization flags stay out
of this stage because `.mojoc` is the architecture-independent package input;
the final executable build performs target-specific optimization.

The precompile input digest continues to frame the exact command arrays and
the script itself. Changing the extension or warning policy therefore
invalidates an old stamp rather than reusing it.

Before resolving the new checkout-owned packages, the stage removes exactly
`build/toml.mojopkg` and `build/mtest.mojopkg`. Those ignored legacy outputs
could otherwise shadow the new `.mojoc` files after a branch switch. No
user-selected precompile output is removed.

### Native adapter

The production adapter retains the existing shared flags:

```text
-std=c17
-O2
-DNDEBUG
-Wall
-Wextra
-Werror
-Wpedantic
-fPIC
-fvisibility=hidden
```

It adds the portable runtime control:

```text
-fstack-protector-strong
```

It also adds the following curated Clang diagnostics:

```text
-Wconversion
-Wsign-conversion
-Wshadow
-Wstrict-prototypes
-Wmissing-prototypes
-Wformat=2
-Wundef
-Wcast-qual
-Wwrite-strings
-Wvla
-Wimplicit-fallthrough
-Wdouble-promotion
-Wnull-dereference
-Wswitch-enum
-Wswitch-default
-Wcast-align
-Wbad-function-cast
-Wmissing-noreturn
-Wredundant-decls
-Walloca
-Warray-bounds
-Wconditional-uninitialized
-Wunreachable-code-aggressive
```

These flags are held in `scripts/build/native_strict_flags.txt`, which remains
the shared platform-independent inventory for production, test compilation,
and policy checks. The production profile adds the C target flags from the
table above. Both the shell entrypoint and the Python native audit consume one
platform mapping, and tests reject a divergent mapping. The compile command
does not expand ambient `CFLAGS` or `CPPFLAGS`.

Compiler probes against the current production and test translation units
show a small actionable set: qualifier loss for the shell path, signedness
conversions from `pollfd.revents`, casts in intentional sanitizer controls, and
a child-report function that should be `_Noreturn`. The implementation fixes
those causes. It does not add warning suppressions merely to reach green.

The adapter remains at `-O2` rather than matching Mojo's `-O3`. Its process and
signal machinery benefits from ordinary optimization without inviting the more
aggressive code growth and transformations of `-O3`; the much larger
Mojo-generated program retains the compiler's release default.

`_FORTIFY_SOURCE`, CFI, sanitizers, and platform-specific linker hardening are
excluded. They have different runtime, optimizer, libc, deployment-target, or
linker requirements and need independent measurement before adoption.

### Final Mojo build

The final link command explicitly passes:

```text
-O3
-g0
--Werror
--target-cpu <profile CPU>
```

On Darwin it also passes
`--target-triple arm64-apple-macosx14.0.0`. Linux retains its native triple so
this change does not invent a new libc/sysroot contract.

The entrypoint detects only the two native platform tuples above, prints the
selected Mojo and C profiles, and exits nonzero for anything else. Local builds
and rattler-build continue to execute the same command definition. The package
recipe does not grow a second set of optimization or target flags.

## Mojo warning policy

Warnings are errors for source owned by this repository:

- the two production precompile commands;
- the final production binary;
- classified unit and integration tests compiled by the self-host harness;
- other repository-owned build probes where warning-free compilation is part
  of their existing purpose.

The current warning cleanup covers:

- deprecated `.mojopkg` output names;
- unused initial assignments in the session-store integration test;
- reporter bindings whose lifetime intent is not visible to the compiler;
- an unreachable exception handler in the console reporter tests;
- discouraged `len(String)` use in the resilience tests.

The shipped runner does not inject `--Werror` into arbitrary user test builds.
Users retain the existing opt-in path:

```text
mtest --build-arg=--Werror
```

`--Werror` becomes a recognized cache-safe bare compiler flag. It still
participates in the exact build-argument digest, but it no longer emits the
misleading `cache-off: unrecognized build argument` warning.

The self-host harness supplies `--Werror` through that ordinary digested
build-argument vector. It does not append the flag after cache-key construction,
so a warm binary built before the policy cannot bypass the warning gate.

`--warn-on-unstable-apis` is excluded. With Mojo 1.0.0b2 it diagnoses thousands
of ordinary uses of core standard-library types, so it cannot provide an
actionable warning gate for this repository.

## ClangFormat policy

Pixi pins `clang-tools` to `18.1.8`, matching the existing Clang compiler pin on
both supported platforms. This supplies matching `clang-format` and
`clang-tidy` executables instead of falling through to whichever versions the
host happens to provide. Each focused checker verifies the executable's
reported version before using it.

The root `.clang-format` uses LLVM as a small, recognizable base and overrides
only repository-relevant choices:

```yaml
BasedOnStyle: LLVM
IndentWidth: 4
TabWidth: 4
UseTab: Never
ColumnLimit: 100
BreakBeforeBraces: Attach
DerivePointerAlignment: false
PointerAlignment: Right
SortIncludes: Never
IncludeBlocks: Preserve
AllowShortFunctionsOnASingleLine: None
AllowShortIfStatementsOnASingleLine: Never
AllowShortLoopsOnASingleLine: false
InsertNewlineAtEOF: true
```

Include sorting stays disabled because feature-test macros must precede system
headers and the adapter has conditional platform header blocks. Source and
comments under `native/` remain ASCII because the post-fork checker relies on
byte offsets.

One source inventory derived from tracked `*.c` and `*.h` files under `native/`
and `tests/native/` feeds the mechanical format, `fmt`, Clang-Tidy, ASCII, and
inventory tests. A newly tracked source cannot silently miss one of those
gates.

One mechanical commit formats that complete inventory without semantic edits.
It runs the native and post-fork gates before commit because those checks
consume the same C source bytes. `pixi run fmt` subsequently formats Mojo and C,
while `pixi run fmt-check` preserves the repository's established
format-in-place followed by final-diff verdict.

The native gate also rejects a non-ASCII byte in this inventory. ClangFormat
does not itself enforce the post-fork checker's ASCII/byte-offset invariant.

## Clang-Tidy policy

The root `.clang-tidy` enables:

```yaml
Checks: >-
  -*,
  clang-analyzer-*,
  -clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling
WarningsAsErrors: '*'
SystemHeaders: false
FormatStyle: file
```

The excluded umbrella check treats the adapter's necessary C/POSIX buffer
operations as deprecated unsafe APIs without distinguishing their audited
bounds. Broad `bugprone-*`, `cert-*`, `performance-*`, `portability-*`, and
`-Weverything` profiles are also excluded: probes produced large volumes of
low-value findings around feature-test macros, multi-level POSIX pointers,
intentional sanitizer negative controls, and bounded memory operations.
Adopting those groups would require suppression infrastructure larger than the
signal.

A checked Python driver invokes the pinned tool directly:

- `native/mtest_exec_native.c` is analyzed with `MTEST_EXEC_TESTING=0`;
- each tracked native test translation unit is analyzed separately with
  `MTEST_EXEC_TESTING=1`;
- the adapter is never analyzed with `MTEST_EXEC_TESTING=1`, so intentional
  sanitizer-negative-control implementations are absent from analyzer input;
- test drivers see declarations and calls to those controls, not their
  intentional defective implementations;
- the driver supplies the same language, target, sysroot/resource resolution,
  include, macro, and warning inventory used for real compilation;
- a unit test pins the complete translation-unit inventory and proves a tool
  failure or finding propagates as a nonzero result.

The driver first performs a no-check parse smoke test so a Darwin sysroot or
resource-directory failure is distinguished from a static-analysis finding.
Current analyzer-only probes are clean in both modes.

`native-check` owns the Clang-Tidy verdict. There is also a focused
`clang-tidy-check` task for local iteration, but it is not a second aggregate
quality floor.

## Runtime-hardening verification

Adding a flag to an inventory is not sufficient evidence that it affects the
artifact. The checkout's `build-native` task delegates its production variant
to the same `production_build.sh native` stage the package recipe uses; Python
builds only the additional testing variant. The native audit inspects that
authoritative production output rather than compiling a lookalike object in a
temporary directory.

`native-check` depends on that production native stage, so the object being
inspected is always produced during the same invocation's task graph.

The audit first requires the exact `-fstack-protector-strong` inventory entry,
which catches a downgrade to the weaker flag. It then requires the platform
spelling of the unresolved stack-check routine in the production object:

- `__stack_chk_fail` in an ELF object on Linux;
- `___stack_chk_fail` in a Mach-O object on Darwin.

The audit records at least one named production function whose qualifying frame
is instrumented, so a refactor that legitimately removes the final protected
frame becomes an explicit review event. A dedicated canary translation unit
compiled with and without the exact flag proves the pinned compiler's verdict
changes; the negative control runs in a temporary directory and never edits the
tracked flag inventory.

The audit already distinguishes production and testing objects and verifies
their symbols and exports. Stack-protector verification extends that same
artifact-level boundary.

## Artifact profile verification

The production profile has compiler- and artifact-level evidence:

- the real `src/main.mojo`, resolving mtest and TOML through the new precompiled
  `.mojoc` files, is emitted as LLVM IR with the production target options;
- every emitted function target attribute must name the selected CPU and its
  baseline-derived features, proving precompiled package elaboration did not
  reintroduce the build host's features;
- the final binary contains no ELF `.debug_*` sections or Mach-O `__DWARF`
  segments, proving the `-g0` outcome;
- the final Darwin binary and the pinned runtime libraries in its installed
  dependency closure report a Mach-O `minos` no newer than 14.0;
- the package-consumption jobs still execute the final installed artifact on
  both native targets.

Disassembly mnemonic greps are not used as the primary CPU oracle. They are
incomplete, can confuse embedded data with instructions, and cannot reliably
attribute code supplied by the dynamically loaded pinned Mojo runtime.

## Developer workflow

The normal commands carry the policy:

- `pixi run build` precompiles warning-free `.mojoc` packages;
- `pixi run build-bin` emits the selected production profile and builds the
  warning-free portable binary;
- `pixi run test` compiles every classified test with `--Werror`;
- `pixi run fmt` formats Mojo, C, and headers;
- `pixi run fmt-check` rejects formatting drift in any of those sources;
- `pixi run clang-tidy-check` gives a focused native-analysis loop;
- `pixi run native-check` aggregates native compilation, post-fork, ABI,
  export, ASCII, stack-protector, and static-analysis evidence.

There is no separate Mojo warning task. A developer or agent encounters the
policy in the first ordinary build or test command.

## Hosted CI migration

The arm64 jobs in these workflows move from `macos-15` to explicit
`macos-26`:

- `.github/workflows/ci.yml`;
- `.github/workflows/community-verify.yml`;
- `.github/workflows/community-publish.yml`.

The label is explicit rather than `macos-latest`, so a future GitHub alias
change cannot silently alter the deployment target. Existing job identifiers,
display names, permissions, dependencies, matrices, and release behavior stay
unchanged. In particular, the byte-stable `macOS arm64 / ...` display names
continue to satisfy the configured required-check contexts.

No new Python mirror of the CI runner topology is added: the workflow diff and
the resulting pull-request jobs own that verdict, as required by repository
policy. Existing security-significant assertions for the community publication
and verification matrices already pin their supported runners; those existing
assertions move to `macos-26`.

Pull-request CI executes the product lanes natively on macOS 26. The
publication workflow's state-changing jobs already wait for both Linux and
macOS candidate validation, so a missing macOS runner cannot produce a partial
publication. The release workflows receive static topology and security
validation in the pull request; their publication actions remain subject to
their existing manual or release triggers.

## Test and verification strategy

Observable policy changes follow red, green, refactor:

1. Add focused failing tests for each command, flag inventory, extension,
   platform mapping, cache classification, source inventory, and the existing
   community-workflow runner assertions.
2. Capture the expected failure to prove each test reaches its intended
   boundary.
3. Make the smallest implementation change.
4. Run the focused test and its owning gate.
5. Temporarily remove or reverse load-bearing controls where practical and
   prove the new guard fails before restoring the implementation.

Before publication, verification includes:

- Mojo and Python formatting and quality checks for changed files;
- build-stamp, cache-key, native, workflow-policy, and harness unit checks;
- a full classified test run with warnings as errors;
- Darwin frontend cross-compilation with `--target-cpu apple-m1`, `--Werror`,
  `--target-triple arm64-apple-macosx14.0.0`, and `--emit=asm`;
- real-main emitted-LLVM inspection proving the selected CPU produces baseline
  features after `.mojoc` elaboration;
- final-binary debug-section and Darwin deployment-target inspection;
- Linux packaged-artifact consumption;
- the complete relevant local floor, including Linux memory lanes;
- deterministic ClangFormat verification in the Linux static preflight;
- native macOS 26 build, test, Clang-Tidy, package, and runtime checks in the
  pull request;
- the repository-required adversarial design and full-diff reviews, with every
  finding fixed or rejected with a concrete reason;
- all required status contexts and the configured CodeQL scanning rule.

Transcripts are not regenerated unless an oracle-side fixture or pinned
toolchain change independently requires it. A warning cleanup in test source
that changes a protocol fixture's source coordinates would be such a change;
ordinary classified-test cleanup is not.

## Atomic delivery

The work ships in one pull request as reviewable commits:

1. Record this design.
2. Pin the native quality tools and add their configurations.
3. Format native C and header sources mechanically.
4. Migrate the checkout-owned precompile artifacts to `.mojoc`.
5. Enforce the Mojo warning/cache policy and clean owned warnings.
6. Harden native compilation and repair the resulting diagnostics.
7. Add the ClangFormat and Clang-Tidy gates.
8. Select and verify the portable production profiles and macOS floor.
9. Move the arm64 workflows to macOS 26.

Each commit uses the repository's Conventional Commit scope vocabulary and runs
its smallest owning checks before the next commit is built on top.

## Explicit exclusions

This change does not:

- bump Mojo or any runtime dependency;
- add a Rust-style release mode or unsupported LTO flag;
- disable Mojo assertions with `-D ASSERT=none`;
- impose `--Werror` on downstream tests;
- enable unstable-API warnings;
- enable every available Clang warning or broad Clang-Tidy families;
- add fortification, CFI, sanitizers, or platform-specific linker policy to the
  shipped adapter;
- establish or lower a Linux libc compatibility floor;
- restore build artifacts across hosted machines;
- rename hosted jobs or alter the CLI and protocol contracts.
