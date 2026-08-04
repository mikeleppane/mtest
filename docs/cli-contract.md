# mtest command-line contract

**Status: FROZEN for the 1.x series.** This document specifies the v1
command-line interface of `mtest`. It is the public API of the tool. A surface
freezes on the release that first **serves** it, not on 1.0.0: the inventory
1.0.0 shipped froze there, and a surface added by a later 1.x minor freezes
when that minor ships it. Nothing is retroactively frozen and nothing is
retroactively promised — a surface that was never served carried no promise to
break.

The amendment rule, so the freeze means something concrete. Within 1.x the
surface inventory may grow: a minor release may add subcommands, flags, and
machine-format fields, additively. What FROZEN means is that nothing served
ever changes meaning, is removed, or has its exit domain, grammar, or format
altered within 1.x — those changes are what a major version is for.

**The one compatibility exception, stated rather than buried.** Additive growth
is not free, and the place it costs something is the leading token. `run` is the
default subcommand, so a first argument that is not a known subcommand is a path
(§3). Serving a *new* subcommand therefore reserves that word: `mtest init` ran
a directory named `init` before 1.1 and bootstraps a project after it, and
`mtest new` and `mtest debug` changed from running a path to refusing an
argument list. This is a real change of meaning for those invocations and is
permitted only because the alternative — never adding a subcommand within 1.x —
was judged the worse trade. **The bare subcommand vocabulary is therefore not
frozen; every other served surface is.** A path whose name collides is still
reachable, spelled `./name`, and that spelling is stable: it can never be read
as a subcommand. Scripts that pass a path as the first operand should spell it
`./name` for exactly this reason.

§20 sorts every surface into three tiers and they carry different promises:

- **FROZEN** surfaces — the subcommands, flag names and semantics, exit codes,
  the node-id grammar, `mtest.toml` key names and semantics, the JUnit mapping,
  the annotation shapes, the `--json` event stream, the `collect` formats, and
  the test-module contract — never change meaning and are never removed or
  narrowed within 1.x. The inventory grows only by addition, and a machine
  format grows only at its stated schema `version`: the `--json` event stream
  and the `collect --format json` stream both gain event kinds and fields at
  `version` 1, while a removal or a meaning change bumps the header version.
- **STABLE-INTENT** surfaces carry a weaker promise on purpose. Default values —
  timeouts, `auto` worker sizing — may be tuned in a minor release, and the
  `.mtest-cache/lastrun` format changes only by taking a new format version.
  Tuning a default is not a semantics change to the flag that reads it.
- **INFORMAL** surfaces — console text layout and colors, and the human-facing
  `config show` output — carry no compatibility promise at all. Read the
  `--json` event stream rather than the console rendering if you need stability.

New grammar for a surface that is already served is a major version: changing
how an existing flag parses, what it means, or which codes it can exit with.
§21 lists what is planned and not served; the additive entries there may land
in a future minor, and anything that would move a served surface waits for a
major.

**What 1.1 adds.** Six served command-line surfaces:

- `--fail-on-flaky` demotes a would-be exit `0` to `1` when at least one file
  passed only after a crash-class retry (§13).
- `--shuffle` and `--seed N` randomize the order run files execute in and print
  the seed that reproduces the order (§18).
- `collect --format json` renders the listing as a versioned stream beside the
  plain one, at collect-stream `version` 1 (§16, `docs/collect-stream.md`).
- `mtest debug PATH::TEST` prepares one test and hands it the terminal, exiting
  only before the handoff (§28).
- `mtest new PATH` writes one runnable test file and never overwrites (§29.1).
- `mtest init [--ci github]` bootstraps a project in the invocation root and
  replaces nothing that already exists (§29.2).

Two additions are not command-line surfaces and are easy to miss, so they are
named too:

- the `[run] fail-on-flaky` project-configuration key, which resolves through
  the ordinary layer precedence like every other key (§25);
- the `session_started.shuffle_seed` field on the `--json` event stream, which
  is present only under `--shuffle`. Its absence on an unshuffled run is what
  keeps that record byte-identical to a stream written before the flag existed
  (§15.4, `docs/json-stream.md`).

No previously served surface changed meaning. The one exception is deliberate,
declared above, and confined to the leading token: `new`, `init`, and `debug`
are now subcommands where a bare path of that name used to be an operand.

The rule binds the interface, not the prose: sharpening this document's
description of a surface that does not itself move is not an amendment.

Each subcommand's exit domain and precedence are frozen. The enumerated
usage-error triggers grow only when a newly served surface adds an argv syntax
or applicability error. For what the *current build* implements today, see
[§24, Availability status (this build)](#24-availability-status-this-build).

`mtest` is an orchestrator layered on top of Mojo's standard-library
`std.testing.TestSuite`. TestSuite owns discovery, per-test selection, and the
report format *inside* a single file; `mtest` owns everything *between* files:
finding them, building them, running them under supervision, aggregating
results, and reporting them for CI. Where this document says "the runner" it
means `mtest`.

---

## 1. Synopsis

```text
mtest [run] [PATHS...] [flags] [-- BUILD-ARGS...]   # run is the default subcommand
mtest collect [PATHS...] [--format lines|json] [flags]   # list node ids
mtest config show [PATHS...] [flags] [-- BUILD-ARGS...] # resolved configuration
mtest doctor [--config PATH | --no-config] [--color WHEN] [-q | -v]
mtest debug PATH::TEST [build flags] [-- BUILD-ARGS...]  # hand over the terminal
mtest new PATH                                      # scaffold one test file
mtest init [--ci github]                            # bootstrap a project
mtest completions bash|zsh|fish            # print a shell completion script
mtest version
mtest --help | mtest help
```

`run` is the default: `mtest tests/` means `mtest run tests/`. A leading token
that is not a known subcommand is treated as a path or flag for `run` — so a
path whose name *is* a subcommand is shadowed by it and must be spelled
`./name` (see the compatibility exception at the top of this document).
`config show` is the sole two-token subcommand. `debug` is the only one that
does not end by reporting: it prepares a single test and then replaces the
mtest process with it (§28). `new` and `init` are the two that write source
files rather than reading them (§29). `completions` is the one that writes
neither: it prints a shell script derived from this document's own flag and
subcommand inventory (§30).

---

## 2. The invocation root

Every relative path the runner reports or matches — node ids, `--exclude`
patterns, cache keys, annotation locations, `collect` output — is relative to a
single **invocation root**. In v1 the root is the **current working directory**.

- Path normalization is **lexical only**: `.` and `..` segments are folded
  textually; symlinks are **not** resolved (documented limitation — resolving
  them would make node ids depend on filesystem state). `--root PATH` is
  reserved for a future release.
- An operand (path or node id) that resolves **outside** the root is a usage
  error (exit 4). This keeps every reported path root-relative and portable.
- Paths supplied by `mtest.toml` are resolved from the invocation root too,
  regardless of where an explicitly selected config file lives. The config
  file's directory never becomes a second root.

---

## 3. Argument grammar

- The **first** token is read as a subcommand when it matches one, and as a
  path or flag for `run` otherwise. The match is exact and unabbreviated, and
  it wins over the filesystem: `mtest new` is the scaffolding subcommand even
  in a directory that contains one called `new`. Spell such a path `./new` —
  a token beginning `./` is never a subcommand, which makes that spelling
  stable across every release. Only the leading token is read this way, so
  `mtest run new` and `mtest collect new` need no prefix at all.
- Flags may be written `--flag value` or `--flag=value`. Both spellings are
  accepted everywhere a flag takes a value.
- Short flags that take no value may not be bundled in v1 (`-x -q`, not `-xq`).
- Flags and positional paths may **interleave** freely:
  `mtest tests/a.mojo -x tests/b.mojo` is valid.
- Parsing stops at a bare `--`. Everything after it is forwarded verbatim as
  build arguments (equivalent to repeated `--build-arg`), subject to the
  forbidden-argument rule (§8.4).
- A repeatable flag (`--exclude`, `--gate`, `--build-arg`, `-I`, `--precompile`,
  `--serial`) may appear multiple times; each occurrence is one value. Values
  containing spaces are preserved exactly (the runner never re-splits a flag
  value on spaces).
- `--config PATH` selects one project-config file; a relative PATH is resolved
  from the invocation root. `--no-config` disables project-config discovery and
  parsing. They are mutually exclusive.
- An unknown flag, a missing required value, or a malformed value is a usage
  error (exit 4), detected before any test runs.

---

## 4. Subcommands and flag applicability

`new` and `init` are absent from the table below because there is nothing to
tabulate: `new` accepts no flag at all except `-h`/`--help`, and `init` accepts
only `--ci VALUE` beside them (§29).

| Flag | `run` | `collect` | `doctor` | `debug` |
|------|:-----:|:---------:|:--------:|:-------:|
| `PATHS...` | ✓ | ✓ | — | one node id |
| `--config PATH`, `--no-config` | ✓ | ✓ | ✓ | ✓ |
| `-k STR` | ✓ | ✓ | — | — |
| `--exclude GLOB` | ✓ | ✓ | — | — |
| `-I PATH` | ✓ | ✓ | — | ✓ |
| `--build-arg ARG`, `-- ARGS` | ✓ | ✓ | — | ✓ |
| `--precompile SRC[:OUT]` | ✓ | ✓ | — | — |
| `--mojo PATH` | ✓ | ✓ | — | ✓ |
| `-x`, `--maxfail N` | ✓ | — | — | — |
| `-n, --workers N\|auto` | ✓ | accepted, inert | — | — |
| `--shard M/N` | ✓ | ✓ | — | — |
| `--lf`, `--last-failed`, `--ff`, `--failed-first` | ✓ | — | — | — |
| `--serial GLOB` | ✓ | accepted, inert | — | — |
| `--timeout`, `--compile-timeout` | ✓ | ✓ (compile only) | — | — |
| `--retries N` | ✓ | — | — | — |
| `--fail-on-flaky` | ✓ | — | — | — |
| `--shuffle`, `--seed N` | ✓ | — | — | — |
| `--no-cache`, `--cache-clear` | ✓ | ✓ | accepted, inert | — |
| `--gate PATH` | ✓ | — | — | — |
| `-s`, `--show-output MODE` | ✓ | — | — | — |
| `--durations N` | ✓ | — | — | — |
| `--junit-xml PATH`, `--gh-annotations` | ✓ | — | — | — |
| `--report FORMAT:PATH`, `--report-style STYLE` | ✓ | — | — | — |
| `--json PATH\|-` | ✓ | — | — | — |
| `--format lines\|json` | — | ✓ | — | — |
| `-q`, `-v` | ✓ | ✓ | ✓ | accepted, inert |
| `--color WHEN` | ✓ | ✓ | ✓ | — |
| `--collect-only` | ✓ (→ behaves as `collect`) | n/a | — | — |

`collect` compiles files to enumerate their tests, so it honors the build and
selection flags; it does not schedule test execution, so run-time flags
(`-x`, `--maxfail`, `--retries`, `--fail-on-flaky`, `--durations`, `--serial`,
`--shuffle`, `--seed`, `--lf`, `--ff`, reporters) do not apply. The
failure-selection flags are refused based on CLI presence under either
`collect` spelling. `--timeout` is
the one exception: unlike the other run-only flags above, it is applicable in
`collect` mode too, because it also bounds each file's `--skip-all` collection
probe (§5, §6) — a probe is a real process spawn with the same hang risk as a
run.

`--format lines|json` runs the other way: it shapes a listing, so it is the one
flag that belongs to `collect` alone, and supplying it where there is no
listing to shape is an applicability error (exit 4). What decides that is the
mode the invocation actually selects, not the head token: `--collect-only` is
`collect` (see the last row of the table), so `mtest --collect-only --format
json` is a collection and is accepted, while a plain `run`, a `config show`, or
a `doctor` has no listing and is refused. `lines` is the default and is the
plain one-node-id-per-line listing this section describes; `json` selects the
machine-readable stream specified in §16.

`-n`/`--workers` and `--serial GLOB` are marked **accepted, inert** under
`collect`, and `--no-cache`/`--cache-clear` under `doctor`, because that is
what this build does: each one parses and none is refused, but nothing acts on
the value. Collection probes files one at a time, so neither worker count nor
serial glob changes anything — and with no parallel pass there is nothing for
`--serial` to pin a file outside of. `doctor` reports on the environment
without building or running; its `state` check does stat `.mtest-cache/`, probe
it for writability, and read `lastrun` (§27.2), but it never consults the build
store under `.mtest-cache/build-v1/` and deletes nothing it did not itself
create, so `mtest doctor --cache-clear` clears no cache. They are recorded
rather than turned into refusals because refusing a flag that earlier builds
accepted would break invocations that pass a uniform flag set to more than one
subcommand. Parallel collection is not reserved — it is simply not implemented
yet, and whichever way it is resolved, both `collect` rows move with it.

`config show` accepts the full `run` grammar, including selection and
per-invocation flags. It resolves the same default, project-file, environment,
and CLI layers as `run`, then renders and exits without discovery, builds,
execution, reporter setup, or state parsing or writes.

`debug` is the narrowest grammar of the five. It takes exactly one `PATH::TEST`
node id — never a plain path, never a second operand — plus the flags that
decide how that one file is compiled, the configuration controls, and `-q`/`-v`.
Every other flag is an applicability error (exit 4), including `--retries` and
`--timeout`, which are refused rather than silently overridden, and including
`--color`: after the handoff there is no reporter left to color. The reporter
flags name the reason in their refusal, because a command that replaces the
mtest process can leave no terminal record behind. `-q` and `-v` are accepted
for command-line consistency and change nothing, since the only output is the
two handover lines. Project-file `[report]` keys and last-run state are
inactive under `debug`: their values are never acted on, though the document
they live in is still validated as a whole (§28).

`doctor` accepts only the configuration controls and ordinary human-output
controls shown in the table. A path operand, passthrough token, or any other
run, build, selection, state, or reporter flag is an argv applicability error
(exit 4). Malformed values, unknown flags, `-q` with `-v`, and `--config` with
`--no-config` retain their ordinary usage refusals.

`new` is narrower still, and for a different reason: it discovers nothing,
builds nothing, and runs nothing, so no flag has anything to act on. It takes
exactly one `PATH` operand and, beside it, only `-h`/`--help`. Every other
token — a second operand, a passthrough `--`, or any flag, the configuration
controls included — is an applicability error (exit 4). It reads no project
configuration at all, so a malformed `mtest.toml` neither changes nor prevents
the file it writes (§29.1).

`init` has the same shape and one flag of its own. It takes no operand at all —
it writes into the invocation root — and accepts `--ci VALUE` beside
`-h`/`--help`. Every other token is an applicability error (exit 4). `--ci`
belongs to `init` alone and is not a general flag: supplying it to any other
subcommand is an unknown-flag usage error (exit 4), which is what keeps
`mtest --ci github tests` from parsing as a run whose `--ci` value nothing
reads. Like `new`, `init` reads no project configuration — it writes the
project configuration (§29.2).

---

## 5. Paths, node ids, and selection

**PATHS** are files, directories, or node ids:

- A **directory** is walked recursively for files matching `test_*.mojo`, in
  sorted order.
- An **explicit file** operand runs regardless of the `test_*` pattern (the
  pattern gates directory walks only) — so `mtest path/to/my_checks.mojo` works.
- A **node id** has the form `<path>::<test_name>` and selects a single test.
  `::` in a file path is unsupported, and that is enforced rather than merely
  discouraged. A directory walk **skips** a `test_*.mojo` file whose
  root-relative path contains `::` and warns about it (kind
  `skipped-unaddressable`, below); `collect` simply does not list it. An
  **operand** whose path carries the separator is a usage error (exit 4)
  naming the operand exactly as it was typed. A token is read that way when its
  text after the first `::` is not a test name at all, or when the operand as
  typed names something on disk; those are the readings under which the
  separator is the operative problem. A token that matches nothing under either
  reading is an ordinary missing path, and keeps `no such path` for its
  node-id file part — `mtest 'tests/gone::l'` says `no such path 'tests/gone'`,
  because `l` is a valid test name and a node id for a file that is not there
  is exactly what it looks like. A genuine node id, with one `::` and a real
  file before it, is unaffected. The rule is about
  addressability, not runnability: such a file may compile and pass perfectly
  well, but nothing could point at the result afterwards — not an operand, not
  a node id in a report, not a `--lf` entry — so admitting it would put a test
  in the run that the tool cannot name.
- Positional PATHS replace `[run] paths` as a whole. With no positional PATHS,
  configured paths are used when present; otherwise the default is `tests/` if
  it exists, else `.`. Configured paths are files or directories, not node ids.
- A path named after a subcommand is only ambiguous in the **leading** position,
  where the subcommand wins (§3). Write `./collect`, `./debug`, `./new`, or
  `./init` to run one, and note that `[run] paths` and every non-leading
  operand are unaffected — nothing there is ever read as a subcommand, so a
  configured `paths = ["init"]` means the directory.

**Walk totality.** A directory walk characterizes every entry it lists, and no
`test_*.mojo` entry it cannot run is dropped in silence. A symlink to a regular
`test_*.mojo` file is collected under the link's own path; a symlinked
directory is never descended (lexical normalization cannot detect a cycle) and
a `test_*.mojo` link that resolves to no usable file is refused. Any other
test-named entry that is not a regular file — a directory wearing a
`test_*.mojo` name, or a FIFO, socket, or device sitting where a test file is
expected — is skipped and never descended. A `test_*.mojo` file whose
root-relative path contains `::` is skipped for a different reason: it is
perfectly runnable and simply cannot be named (above). A **run** reports each
such skip as a warning, once per entry: kind `skipped-symlink` for a refused
link, `skipped-unaddressable` for a path carrying the separator, and
`skipped-nonregular` for the rest. A directory whose own name carries `::` is
still descended, so each unaddressable file under it is announced on its own
rather than as a subtree the reader would have to expand. (`collect` lists
files and emits no discovery warnings, for any of the three kinds.) An entry
the walk cannot characterize at
all — the shape a directory this process may read but not search produces — is
a usage error (exit 4, §9) rather than a subtree quietly reported as empty. A
FIFO, socket, or device whose name does not match `test_*.mojo` cannot hide a
test and is passed over silently, like any other non-matching name.

Two bounds on that guarantee, stated rather than implied:

- **Symlink targets are typed by following the link**, and a target that was
  deleted cannot be told apart from one that exists but cannot be reached (a
  parent directory that is readable but not searchable). Both resolve to
  nothing. A `test_*.mojo` link is therefore reported in both cases — the
  selection is never silently lost — but a link whose name does not match the
  pattern is passed over in both cases, so the `skipped-symlink` warning that
  a *reachable* directory symlink would have produced does not appear. No test
  changes hands either way: a directory symlink is never descended. The same
  ambiguity applies to the default `tests/` probe: when `tests` is a symlink
  whose target cannot be reached, the default operand falls back to `.` as it
  does when `tests` does not exist.
- **An explicit directory operand is walked whatever it is named** (§5's rule
  that naming a path selects it directly). So `mtest tests tests/test_shape.mojo`
  both warns `skipped-nonregular: tests/test_shape.mojo` — the walk of `tests`
  refused that entry — and runs the files under it, because the second operand
  named it directly. Both statements are true of their own operand.

**Node-id canonicalization.** Every node id is canonicalized to **root-relative**
form. That canonical form is the single basis for `-k` matching, `collect`
output, deduplication, and every reporter. Duplicate selections (the same test
named twice, or via both its file and its node id) are de-duplicated; a test
runs at most once.

A nonexistent path, an explicit operand whose file type mtest cannot run (a
FIFO, socket, or device — refused as `unsupported file type`, never as `no such
path`), an operand that spells a path with `::` (refused as `unsupported path`,
quoting the operand as typed), or a node id
naming a file that exists but a test that does
not, is a usage error (exit 4). That check happens **after** the file's
`--skip-all` collection probe (§6) reports its universe of test names: an
unknown node id is an exit-4 error raised post-probe, before any test body
runs.

**`-k STR`** is a case-insensitive substring filter over node ids. At most one
`-k` is accepted in v1 (boolean expressions are reserved). A `-k` that matches
nothing is not an error by itself, but if it leaves the session with nothing to
run the exit code is 5 (§9).

---

## 6. The test-module contract

A test module must define a `main` that runs its suite through TestSuite's
standard entry point:

```mojo
def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

Any behavioral equivalent is acceptable: it must honor `--skip-all`, `--only`,
and `--skip` as arguments and emit TestSuite's standard report. The runner
relies on that protocol, not on the exact source.

Under `--skip-all`, a conforming module executes **no test bodies** at all — it
reports every test as SKIP without running any of them. The runner relies on
that guarantee to use `--skip-all` as a **collection probe** (§5, §16): a
module whose report under `--skip-all` shows anything other than an all-SKIP
listing fails to qualify as a probe, which is the basis for classifying it as
MALFORMED-SUITE below.

- A file that **fails to compile** yields COMPILE-ERROR (or COMPILE-TIMEOUT if
  the build exceeds `--compile-timeout`).
- A file that **compiles but does not speak the protocol** — no parseable
  report or collection listing — yields **MALFORMED-SUITE**, a *user* error in
  the exit-1 class. This is the module's fault, not the runner's.
- A file that emits a report which is *present but violates the pinned grammar*
  is treated as toolchain **protocol drift**: an internal error (exit 3) whose
  message names the offending expectation. This is reserved for a real
  divergence between the installed toolchain and the version the runner was
  pinned against.

The distinction matters: a broken test file must never be reported as a bug in
`mtest`, and a genuine protocol drift must never be silently swallowed as a user
error.

---

## 7. Toolchain selection

The runner invokes a Mojo toolchain to build and (for `collect`) enumerate.

- Default: `mojo` resolved from `PATH` (the pixi-environment pattern).
- `[build] mojo` in `mtest.toml` overrides that default.
- A non-empty `MTEST_MOJO=/path/to/mojo` overrides the project file.
- `--mojo /path/to/mojo` overrides every lower layer.

A runner must be able to serve projects pinned to different Mojo installs, so
the toolchain is never hard-coded.

---

## 8. Building test files

### 8.1 Run model

Each test file is **built to a binary and the binary is executed directly**. The
runner never uses `mojo run` to execute tests: `mojo run` masks a crashing
process's exit code to `1` (making a crash indistinguishable from a failure) and
can itself JIT-crash in CI. Only a prebuilt binary yields a truthful process
exit code, which is the foundation of the whole outcome model.

### 8.2 `--build-arg ARG` and `-I PATH`

`--build-arg` (repeatable) forwards one argument to `mojo build`, after the
runner's own arguments. Everything after a bare `--` is equivalent. `-I PATH`
(repeatable) adds an include path, forwarded to every build.

### 8.3 `--precompile SRC[:OUT]`

Repeatable. Each `--precompile` package is built with `mojo precompile` **before
any test build**, in the order listed. Precompiled packages inherit `-I` and
`--build-arg`. `OUT` defaults to `build/<name>.mojopkg`, and its directory is
automatically added to `-I` so dependent test files resolve `from <name> import
…`. A step whose inputs and whose output are both unchanged is **skipped**
(§8.5): `mojo precompile` does not produce identical bytes for identical
sources, so a step that re-ran every session would rewrite a package every
dependent test file is keyed over and no test build could ever be cached.

Each attempt builds to a temp path beside OUT and is renamed onto OUT **only
after it exits 0**, so a killed, crashed, or rejected attempt never touches OUT:
a good package from an earlier run survives a failed step byte-for-byte, and no
dependent ever builds against a half-written package. The step is bounded by
`--compile-timeout` (§18) and gets the same crash-class `--retries` budget as a
file build (§13): up to N extra attempts on a signal, a compile-timeout, or a
compiler-crash signature, each on a fresh temp and a quarantined module cache. A
precompile that only succeeds after a retry is not a FLAKY verdict — there is no
test identity to carry one — but a loud success-after-retry warning.

If a precompile step's attempts are all exhausted, the session ends in
**PRECOMPILE-ERROR**: there is no test identity to attach it to, so the runner
prints one banner naming the ending, lists every test file that depended on it
as a casualty, and exits 1.

### 8.4 Forbidden build arguments

The runner owns its output artifacts and its source list. Build arguments that
would take that control away are rejected as usage errors (exit 4): output
selection (`-o`), emit-type selection (`--emit`), build parallelism (`-j`,
`--num-threads`, §18), and any **extra source operand** (a positional path
handed to `mojo build`). This applies to `--build-arg`, to `-I` misuse, and to
post-`--` arguments alike.

The runner owns the build thread budget: the worker pool spawns each build as
`mojo build --num-threads K` for a `K` drawn from a cores-wide token budget
(§18), so a user-supplied build thread-count argument (`-j`, `--num-threads`) is
a forbidden build argument (exit 4), rejected like `-o` and `--emit` — it would
fight the runner for the machine's cores. The rejection names `-n`/`--workers`
as the supported way to set parallelism. The one place `--num-threads` appears
is the runner's own build spawn; a COMPILE-TIMEOUT reproduce line prints that
effective `--num-threads K` with the deadline, so the reproduce stays faithful —
that is the runner's flag, not a forwarded user argument.

### 8.5 The build-artifact cache

Built binaries persist across invocations under `.mtest-cache/build-v1/` in the
invocation root, so a rerun over an unchanged tree compiles nothing. The cache
is **on by default** and is local to one checkout. It is deliberately not
persisted across CI runs: moving compiled artifacts into shared state could
reuse a binary built for a different host CPU. It is never shared between
machines.

Each artifact is a directory named `<mangled>_h<digest>`, holding the binary, a
record of the key that produced it, and a record of where it sits in its
source's recency order. The binary and the key record are immutable once
published; the recency record is the one file publication may rewrite
afterwards, to place the generation relative to siblings that appeared while it
was being built. A build compiles into a private staging directory
beside it and is published with one `rename(2)`, so a key and a binary are never
observably paired with anything but each other, and an interrupted publication
leaves nothing a later run can adopt. Two runs that race for one key are not an
error: the loser adopts the winner's artifact.

The key is derived from the compile inputs, never from configuration text. It
covers the resolved compiler and every entry in `<resolved compiler
dir>/../lib/mojo`, five environment variables that move where the toolchain
reads or writes something of its own (`MODULAR_HOME`, `MODULAR_CACHE_DIR`,
`MODULAR_DERIVED_PATH`, `MODULAR_NVPTX_COMPILER_PATH`, `XDG_CACHE_HOME`), the
physical invocation root, the build arguments, every
file named by a build argument, the walked contents of every `-I` root, the
walked contents of the directory the test file sits in, and the test file itself
— by CONTENT, so a modification time that moves without the bytes changing
rebuilds nothing. A file whose bytes are identical across two branches hits on
every switch. A file that differs keeps the generations of both states once it
has been compiled in both, so switching it between exactly two states hits both
ways from the second cycle on, provided every writer of that store is at this
version. A third state evicts the lowest-ranked of the three, which without
concurrent publishers is the oldest; and a configured precompile output that
moves can move the complete key, which no retention bound restores. That
directory is in the key because the compiler resolves a bare
`from helper import ...` against the source file's own directory, with no `-I`
involved: a helper beside a test is a build input nothing else covers.
The keyed `-I` spelling is exact — `-I lib` and `-I ./lib` differ — while the
named directory's contents are walked and digested. Symlink resolution remains
canonicalized. A wrapper script therefore relocates the keyed library directory
beside the wrapper; the real compiler's libraries are not directly keyed.
Settings that cannot change a compiled byte (timeouts, workers, retries,
selection, reporters, and the rest of §25) are absent from it and never
invalidate anything. There is no import-graph analysis: one change under an `-I`
root invalidates every file keyed over that root, and one change beside a test
file invalidates every test in that directory, both of which over-rebuild
deliberately. The test files mtest would discover in that directory are the one
exception, because each is an entry point keyed on its own and folding them
together would rebuild a whole directory for every one-line edit; a file that
imports one of them, or whose imports cannot be read, keys over the whole
directory instead.

A hit re-verifies the stored binary before running it — against the digest
recorded with it, and as something this process can actually execute, since a
restore that drops mode bits leaves the content intact — and reports the
recorded build duration so the SLOW annotation reads the same warm as cold. An
artifact that fails either check is deleted and rebuilt, so a store damaged from
outside heals on the next run rather than failing every one after it. Publishing
an artifact removes that source's generations beyond the two newest, and damage
can quarantine one, so a second run over the same checkout can replace or
quarantine a generation in the window between the check and execution. The same race can reach a generation
this run just published. A run that cannot execute a stored artifact compiles
the file instead, emitting a `cache-rebuild` warning, and the compile is a
recovery rather than a second admission — it moves neither counter (§15.4).
Anything the key cannot characterize honestly — an
unclassifiable `--build-arg`, an include tree that cannot be walked, a store
that cannot be created — turns the cache off for the whole session with one
warning and builds normally. No cache condition ever fails a run that would
otherwise pass.

The store pays for itself from about three test files upward. A session's fixed
cost — chiefly digesting the compiler and every entry of the library directory
beside it — is nearly constant in suite size, so on a one- or two-file suite a
warm run can be slower than the same run with `--no-cache`, while from three
files up the compile it saves exceeds that fixed cost and the margin widens with
the suite. Those measurements are one machine with the compiler's own cache
already warm; CI compiles cold, which raises every compile-bearing run and moves
the crossover further in the cache's favour.

`--compile-timeout` bounds only a compile that happens. A warm hit performs no
compile and therefore cannot produce COMPILE-TIMEOUT; use `--no-cache` when the
compile deadline itself must be exercised.

Retries are outside the cache entirely: a crash-class retry builds to its
invocation-private path under `build/bin/` and publishes nothing, and the file
is rebuilt in the next session. Configured precompile steps are stamped rather
than content-addressed, because their output must land at the contractual path
dependents reach through `-I`; a skip requires both the stamp's key and the
output file's digest to match (§8.3).

A failed build's reproduce line and diagnostics name `build/bin/<mangled>` as
the output path, never the cache's staging directory: the reproduce line is a
command a user runs, and a build that fails has its staging directory deleted
before the verdict is even emitted. A build that succeeds records the artifact
path it was published to, and a hit reports the path recorded with the
artifact — that is the output path `-v` prints (§15.1) and the `--json` stream
reports (§15.4), and unlike a staging directory it is still there when the run
ends.

The single exception is a build that succeeded and could not be published. Its
binary is real and the run needs it, so the staging directory survives the
session and the recorded output path names it — a live `.mtest-cache/.tmp-…`
component. That path is accurate for the run that emitted it and is not
promised beyond it: no later run reads a staging directory, so the file is
rebuilt next time. The directory itself is left behind (§8.5.2). The
`cache-publish` warning marks every such run.

`--no-cache` neither reads nor writes the store. Its gate sits before any
staging, so a run that asked for no cache creates no store directory and leaves
behind no artifact a later run could trust. It does still create `.mtest-cache`
itself, because the last-run state lives there and is written whatever the cache
is doing — and every `.mtest-cache` mtest creates carries the `CACHEDIR.TAG`
deletion-authorization marker, so a directory left by a `--no-cache` run is one
`--cache-clear` can still delete. The marker goes only into a
directory mtest created: an existing `.mtest-cache` is used as it is and left
unmarked, since writing the marker into a directory somebody else made would
manufacture `--cache-clear` deletion authority.

`--cache-clear` deletes `.mtest-cache` — the artifacts and the last-run state
together — and then runs the session normally, which legitimately repopulates
the store. Before deleting, the path is characterized without following
symlinks and must be a real directory carrying the `CACHEDIR.TAG` marker mtest
writes when it creates `.mtest-cache` — as a regular file holding exactly the
text mtest writes, because `CACHEDIR.TAG` is a shared convention and a marker
somebody else wrote does not authorize deleting the directory. A symlink, a
missing or foreign marker, or a deletion that fails partway is a pre-session
usage error (exit 4) with a diagnostic that names the manual removal, and there
is deliberately no "its contents look like ours" override. Combined with `--lf`/`--ff`, a warning
states that the last-run state was just deleted and that selection falls back
to the full set. Nothing under `build/` is ever deleted: test binaries no longer
land there, and configured precompile outputs are user-visible products rather
than cache state.

#### 8.5.1 What the cache does not defend against

The cache defends against developer mistakes — an edit whose rebuild is skipped,
a binary that no longer matches its source — and not against a process running
as the same user that is actively trying to deceive it. Anyone with that access
can already change what a build produces by simpler means: edit the sources,
replace the compiler, point `MODULAR_HOME` somewhere else.

Five boundaries follow, all of them deliberate non-goals that follow from that
scope. The first is listed first because a reader deciding whether to trust a
warm run needs it before anything else here: it states what publication proves
about the build window, and exactly where that proof stops.

- **An input mutated while the compiler is running.** Build inputs must remain
  stable while a compiler invocation runs; mutation during compilation is
  unsupported, and that rule is the contract rather than something the cache
  detects for you. What publication does with an ordinary violation of it is
  the useful part. The inputs a build's OWN key sampled are re-checked before
  anything is stored, by identity (device, inode, size) and by change times
  (mtime and ctime): the test file, the framed files in its directory, each
  directory the walk descended, and, for a symlinked input, both its own name
  and the file its name finally resolves to; on the precompile route, the
  step's source, the directory a single-file source sits in, each of its
  include roots, and the earlier steps' outputs it consumes. The test-file
  route additionally re-reads the source and re-walks its directory and
  compares CONTENT, as it always has. An input that moved in any of those
  senses refuses publication: on the test-file route nothing is stored, one
  `cache-publish` warning names the input, the verdict is reported normally,
  and the file is rebuilt next run; on the precompile route the step is left
  unstamped, silently, and runs again next session.

  What is re-checked is a build's own inputs, not everything in its key. The
  session-scoped frames — the toolchain, the `-I` root contents, and any file
  named by a build argument such as `-Xlinker foo.o` — are sampled once for the
  whole run and are listed among the limits below.

  Comparing identity and times rather than content alone is what covers the edit
  that is undone. An input edited during a slow compile and edited BACK before
  publication — the ordinary shape of changing your mind — leaves both content
  samples agreeing about bytes the compiler never read, and once published, every
  later run over the restored tree would hit that binary. The undo cannot restore
  the metadata: `ctime` moves forward on any write and cannot be set backwards
  from userspace, and a file written afresh under the same name lands on a
  different inode. A file created beside a test and deleted again leaves no file
  to compare at all, which is why each walked directory contributes a record of
  its own — its times move on the membership change.

  The window is honest about its own length. It runs from the moment an input is
  keyed to the moment its build is published, and under the parallel pool that is
  longer than one compile: every selected file is keyed during session seeding,
  before the first compile starts. So a shared helper edited halfway through a
  session refuses every publication in that directory that had not happened yet,
  and those files are rebuilt on the next run. That is the deliberate direction;
  the alternative was a possible false green.

  What is left uncovered, and why:

  - Deliberate metadata restoration by a process running as this user — the
    scope above.
  - A mutate-and-restore that completes inside a single filesystem timestamp
    tick without changing the size, and coarse-timestamp filesystems generally,
    where that tick is large.
  - A directory a build writes its own output into is held to its files but not
    to its membership. A configured precompile step legitimately creates its
    package inside an include root it was given, so that directory's membership
    changes while the step runs, by design.
  - The `-I` root contents, the toolchain, and any file named by a build
    argument (`-Xlinker foo.o`) are sampled once for the whole session rather
    than per build, so no publication re-checks them. Re-walking every include
    root at every publication would narrow that without closing it, at a cost
    scaling with include-tree size times files compiled; the per-file directory
    re-walk is bounded by one directory and paid only on a miss, which is why it
    is worth doing and the session-wide one is not.
  - **A symlink CHAIN.** An input's own name and the file that name finally
    resolves to are both recorded; the intermediate links a chain passes
    through are not. A middle link repointed and repointed back around a
    compile moves neither end.
  - **A directory that becomes a package and stops again.** A subdirectory with
    no `__init__` is not on the compiler's path, so the walk neither frames its
    files nor holds it to its membership. Creating an `__init__` in it during a
    compile and deleting it afterwards puts its modules in the build and leaves
    the tree looking as it did. Holding every non-package subdirectory to its
    membership instead would refuse publication whenever anything at all
    appeared in one, which is a far commoner event than this.
  - **An include root that did not exist when the step was keyed.** Its absence
    is part of the key, but an absence cannot be re-stat'd into a record: a
    root created during the step, consumed, and removed again leaves the key's
    "absent" true at both ends. A root created and LEFT is caught, by the key
    itself, on the next session.
  - A directory's walk is memoized once per session, and a hit publishes
    nothing, so nothing re-checks anything on a hit. A helper edited
    PERSISTENTLY in the middle of a session can therefore leave a later file in
    that directory probing a key computed against the old helper and hitting a
    generation built against it. This one is a gap rather than a non-goal.

  If you suspect any of these, `--no-cache` compiles from what is on disk and
  `--cache-clear` discards anything already stored.

- **`PATH`, and the rest of the inherited environment.** Five variables are
  keyed, and they are named in full above; every other variable the compiler
  child inherits is not. `PATH` is the one whose absence has a concrete
  consequence rather than a theoretical one: on Linux the compiler links
  through a C compiler it resolves through `PATH`, so changing `PATH` so that a
  different `cc` is found leaves every warm entry valid although a fresh build
  would now use a different linker. It is left out because `PATH` changes
  constantly for reasons that never reach a compiled byte — a shell hook, a
  directory change, an editor's integrated terminal — and keying it would cost
  every hit on this machine to cover a case that changes what is linked perhaps
  once a year. `LD_PRELOAD`, `LD_LIBRARY_PATH`, `DYLD_INSERT_LIBRARIES` and
  their neighbours are out for the reason the scope above gives: interposing on
  the compiler is the hostile case, not the developer mistake.

- **The toolchain outside its library directory.** The compiler binary is keyed
  by content, and so is every regular file in `<resolved compiler
  dir>/../lib/mojo`.
  The linker binary beside the compiler, the shared objects it loads at run
  time, and the clang resource directory are not. An ordinary toolchain change
  moves the compiler binary too and so moves the key; a surgical replacement of
  one of those files alone does not. The `--mojo <wrapper>` shape is the case
  where this is easiest to reach, because an unchanged wrapper can be pointed
  at a different compiler.

- **A symlink raced into `--cache-clear`'s path.** The deletion characterizes
  each name with `lstat` and then walks that name, so a concurrent process
  running as the same user can replace a directory with a symlink between those
  two operations and redirect the walk. Closing this needs `openat`/`unlinkat`
  over descriptors, which the pinned toolchain does not expose. Every step still
  refuses what it can see — a symlinked root is never removed and never followed,
  and a child symlink is unlinked rather than descended — and the target is
  always `$PWD/.mtest-cache`, which is a narrowing rather than a proof.

- **Two compilers with one version banner.** The stamp that lets mtest's own
  `pixi run build` skip an unchanged precompile stage identifies the toolchain by
  `mojo --version` and `pixi.lock`, so two different compiler binaries that print
  the same banner under the same lockfile share a stamp. This applies to building
  mtest, not to running it: the per-file cache key described above digests the
  resolved compiler's own contents and does separate two such binaries.

#### 8.5.2 The store grows; nothing shrinks it but `--cache-clear`

There is no size cap, no age limit, and no eviction. Publishing an artifact
removes the generations of **that source** beyond the two newest, which is what
keeps an edit-and-rerun loop from growing without bound, but it is the only
reclamation mtest performs.

Two live generations per source is a best-effort target rather than a hard
bound on the store. Each retained binary is capped at 512 MiB, and three things
loosen the target itself. Nothing here takes a lock: concurrent publishers can
leave a source holding more than two for a while, because a deletion whose
victim turns out to have been republished under the same name is skipped rather
than forced, and the next publication that is not racing reaps the excess. A
generation whose recency record is damaged or absent reads as the oldest there
is, so it is the first thing reaped rather than something that lingers. And the
two-generation promise holds only once every writer of a store is at this
version: an older binary's publication still deletes every other generation of
the source it publishes. Per-checkout stores make one writer the normal case.

Four things accumulate:

- **Generations of sources that no longer exist.** Reaping only ever considers
  the source being published, so renaming or deleting a test file strands its
  artifacts permanently.
- **Staging directories from builds that were killed.** A `.tmp-` directory is
  skipped by both reapers by construction — a concurrent process may be
  compiling into one — and a build ended by SIGKILL or a deadline leaves a full
  binary behind. Only the batch that created a staging directory can remove it,
  and a batch that dies does not.
- **Staging directories from failed publications.** The staged binary is what
  the run is executing, so it cannot be removed while the run needs it, and the
  session does not come back for it afterwards.
- **Binaries too large to publish.** The 512 MiB per-artifact cap bounds one
  generation, not the store.

For a workstation this is noise. For a long-lived CI checkout that never clears,
it is a slow disk-exhaustion path — and an exhausted disk fails a run the cache
was supposed to make faster. `--cache-clear` is the remedy, and `.mtest-cache`
is safe to delete by hand at any time: it holds nothing that cannot be rebuilt.

---

## 9. Run and collect exit codes

Exit domains are per subcommand. This table and precedence govern `run` and
`collect`; §27 defines the narrower domains for `config show` and `doctor`,
§29 defines the `{0, 3, 4}` domains of `new` and `init`, and §28 defines
`debug`'s pre-handoff domain — past the handoff the exit status is the test
binary's own and mtest has no code left to define.
The meanings and precedence within each command domain are **FROZEN**.
Exit-4's enumerated run/collect triggers grow only as served pre-run surfaces
grow:

| Code | Meaning |
|------|---------|
| 0 | the session ran; every selected test's outcome is PASS or SKIP (exclusions allowed) |
| 1 | at least one selected outcome is FAIL, CRASH, TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT, MALFORMED-SUITE, or PRECOMPILE-ERROR; or the session would otherwise exit 0 and, under `--fail-on-flaky` (§13), counted at least one FLAKY file |
| 2 | interrupted (SIGINT/SIGTERM); a partial summary is printed |
| 3 | internal `mtest` error — including protocol drift (a report present but off-grammar) and an environment/I-O failure such as a runtime report-destination open/write failure (a `--json` destination that cannot be opened at session start, or whose stream write later fails — a fatal abort; or a `--junit-xml` target that cannot be created at session start, or whose report cannot be finalized and renamed onto PATH; or a `--report` target that cannot be created at session start, or whose document cannot be finalized and renamed onto PATH), or a direct write to stdout or stderr that the destination could not take at all (a closed descriptor, a full filesystem — anything but a departed consumer, below) |
| 4 | pre-run usage error (unknown flag, bad value, nonexistent path, an explicit operand of a file type mtest cannot run (a FIFO, socket, or device, §5), a path discovery cannot inspect (§5), unknown node id, forbidden build argument, mutually exclusive `--config`/`--no-config`, `--seed` without `--shuffle`, `--shuffle` beside `--lf`/`--ff` (§18), a flag applied to a subcommand it does not belong to (§4) — a run-only flag `collect` marks `—`, `--format` outside `collect`, or any run, build, selection, state, or reporter flag under `doctor` except `--no-cache` and `--cache-clear`, which §4 marks accepted, inert — a `--format` value that is neither `lines` nor `json`, a selected project config that is missing, unreadable, malformed, or has an invalid key/value, a syntactically invalid `--json` or `--junit-xml` report destination — an empty value or a nonexistent parent directory, a `--report` value that is not `md:PATH` or `html:PATH` or names a format twice or a nonexistent parent directory, a `--report-style` value that is neither `concise` nor `full`, two active file destinations that name the same file (§15.5), the machine-stdout conflict — `--json -` without an explicit `--gh-annotations off`, since the byte-pure stream and the annotation tail cannot share stdout, or a `--cache-clear` target mtest can see and cannot prove it owns, or can prove and cannot delete, §8.5 — a target it cannot characterize at all is treated as absent and exits `0`) — detected **before any test runs** |
| 5 | no tests collected (empty walk, `-k` matched nothing, everything excluded) |

**Precedence** when outcomes mix. A usage error aborts before the run with 4.
Otherwise: an interrupt dominates (→ 2); else an internal error (→ 3); else any
failing outcome (→ 1); else nothing collected (→ 5); else, under
`--fail-on-flaky` with at least one FLAKY file, 1 (§13); else 0. A user
interrupt outranks an internal error because the run was truncated on purpose
and its result is no longer authoritative. The flaky rung sits at the bottom on
purpose: it can only ever move a 0, never displace a code some other fact
already decided.

**A domain is closed against a departed consumer.** `mtest` ignores `SIGPIPE`
around every write it makes to a descriptor, so a reader that closes early —
`mtest collect --format json | head -1`, `mtest --help | head -1` — costs the
rest of that write and nothing else. Death at signal 13, which a shell reports
as 141, is a status no subcommand produces, and every command exits with a code
from its own domain whether or not anyone was still reading.

That carve-out is the departed consumer and nothing else, because it is the one
write failure that says nothing about `mtest`: the consumer chose it, and the
bytes it did not read were bytes it did not want. Two errnos mean it, one per
transport — `EPIPE` on a pipe, `ECONNRESET` on a stream socket whose peer reset
the connection.

**Every other write failure means the output was not delivered**, and what that
costs depends on what the bytes were.

- **Primary output — the thing the command was asked to produce — escalates to
  exit 3**, in every command's domain, including the six whose domains are
  otherwise `{0}`, `{0, 3}`, or `{0, 3, 4}` (§19, §27, §29). Help text, the
  version, the `doctor` block, the resolved configuration, `created <path>`,
  the `collect` listing, the `debug` plan lines, and a run's console report are
  all primary output. A descriptor that is closed (`mtest --version >&-`) or a
  destination that is full reports `EBADF` or `ENOSPC`, nobody asked for the
  output to be dropped, and a success code over undelivered output would be a
  lie about the one thing the caller wanted. For a run this arrives through the
  ordinary delivery precedence above, so it behaves exactly as a dead `--json`
  destination does: a 0, 1, or 5 becomes 3, an interrupt's 2 still stands.
- **A diagnostic about an already-resolved refusal does not move that code.**
  A usage error exits **4** whether or not stderr took the prose, because there
  the exit code *is* the machine-readable statement and it was delivered
  perfectly; losing the words costs the words. `2>/dev/null` and `2>&-` are two
  spellings of "I do not want the diagnostic", and neither turns a bad flag
  into a broken runner. The same holds for `new` and `init`'s failure lines,
  which explain a code those subcommands had already decided.

The diagnostic for an undelivered write goes to stderr naming and decoding the
errno, unless stderr is itself the descriptor that failed, in which case it is
silent rather than recursive. No write failure of any kind terminates the
process by signal.

A `--shard` (§18) that owns no run files reaches exit 5 by the same
nothing-collected rule — but only when nothing else ran: a shard whose gates ran
(gates are never sharded) exits by its gate results, so exit 5 means *neither* a
gate *nor* a shard-owned file ran.

---

## 10. Outcome model

### 10.1 Reported outcomes

`PASS`, `FAIL`, `SKIP` (the suite itself skipped the test), `CRASH` (death by
signal or `abort`), `TIMEOUT`, `COMPILE-ERROR`, `COMPILE-TIMEOUT`,
`MALFORMED-SUITE`, and the session-level `PRECOMPILE-ERROR`. A pass produced only
after one or more retries is annotated **FLAKY**.

**A crash is not a failure.** An assertion that fails (FAIL) and a process that
aborts or dies by signal (CRASH) are different events with different causes, and
they stay distinct in the summary, the JUnit XML, the annotations, and the exit
code.

**Selection-induced SKIPs are suppressed.** When the runner uses `--only`/
`--skip` internally to select tests, TestSuite reports the non-selected tests as
SKIP. Those are protocol artifacts, not user-facing skips, and are removed from
results and reporters. Only a test the suite *itself* skipped is reported SKIP.

### 10.2 Internal states

The internal model additionally distinguishes states that keep parallel and
interrupted sessions honest, even though they are not per-test "outcomes":

- **DESELECTED** — removed by `-k` or node selection. Counted in one summary
  line, never listed individually.
- **EXCLUDED** — removed by `--exclude`. Reported loudly on the console (never
  silent).
- **SHARDED-OUT** — a run file assigned to a different `--shard` (§18). Counted
  in the session header (how many files this shard did not own), never listed
  individually — the other shards run them, so naming each here would be noise.
- **NOT-RUN** — never scheduled because `-x`, `--maxfail`, or an interrupt
  truncated the session. Shown in the summary so a truncated run can never
  masquerade as a complete one.

### 10.3 Crash attribution honesty

When the runner reruns a crashed file's tests in isolation to attribute the
crash to a specific test and the crash does not reproduce (an order-dependent
crash can pass every test in isolation), the file-level CRASH **stands
unattributed**. The runner never blames every test and never manufactures
certainty. The file-level CRASH outcome is always authoritative; isolation
reruns are secondary diagnostic evidence only.

The attribution pass runs **after** the main session and is strictly bounded, so
a pathological crasher can never hang the run: at most **32 isolation reruns per
file**, each with a deadline of `min(--timeout, 60)` seconds, under a **120 s
per-file** and **600 s per-session** wall-clock budget (checked before each
rerun). Every crashed file ends with a typed stop reason — **attributed** (a
single culprit reproduced), **no-reproduction** (isolation stayed green),
**probe-failed** (an isolation rerun could not even be built or spawned),
**run-cap** (the 32-rerun ceiling), or **time-budget** (a wall-clock budget) —
and the file-level CRASH stands regardless. Isolation reruns are never subject to
`--retries`, and the whole pass is **skipped under interrupt** (a truncated run's
attribution is not worth the delay).

---

## 11. Stopping early

- `-x`, `--exitfirst` — stop *scheduling* new files after the first failing
  file. Files already in flight finish.
- `--maxfail N` — stop after N failing **tests**. A file-level error outcome
  (crash, timeout, compile error, malformed suite) counts as one. `N=0` means
  no limit — the same 0-disables convention as `--timeout` and `--durations`.
  Only a **final** failing outcome counts: a test that crashed on an earlier
  attempt but passed on retry is FLAKY (§13), a pass, and contributes **0** to
  the `--maxfail` tally.
- `--gate PATH` (repeatable) — gate files run **first**, and a gate failure
  aborts the whole session immediately, regardless of `-x`. This is the
  smoke-test-first pattern: don't spend the pool if the smoke test is red.

---

## 12. Exclusions

`--exclude GLOB` (repeatable) removes files from the run:

- The pattern is an `fnmatch`-style glob (`*`, `?`, `[...]`), matched against the
  **root-relative** path. Note that `fnmatch`'s `*` may cross `/` (documented). A
  plain path (no glob metacharacters) matches by exact equality.
- Every exclusion prints a **loud SKIP line** — an excluded file is visibly
  reported, never silently dropped.
- An exclusion pattern that matches **nothing** prints a loud stale-exclusion
  warning (a stale exclude usually means a renamed file is silently running
  again, or was meant to be excluded and no longer exists).
- On conflict, an exclusion **wins** over `--gate` and over an explicit path
  operand — loudly.

---

## 13. Retries and flakiness

`--retries N` (default 0) retries **crash-class steps only**. N is the number of
*additional* attempts (N+1 total), and the loop resumes from the step that
failed — a run that crashes is re-run against the already-built binary, not
rebuilt.

- **Crash-class**, on the **run** step, is termination by signal or a deadline
  kill (a `--timeout` expiry). On a **build** or **precompile** step it is
  termination by signal, a `--compile-timeout` expiry, **or** a nonzero exit
  whose stderr carries a compiler-crash signature (an ICE banner or stack dump).
  Everything else is deterministic and is **never** retried: any run that exited
  under its own control (a failing assertion, a `worse-of` disagreement, a
  capture-overflow FAIL), an ordinary compile error (a nonzero exit with no
  crash signature), a spawn failure, and an interrupt.
- Each attempt uses a fresh output path; after a **compile** kill the rebuild
  runs against a quarantined per-attempt module cache, since a killed compile
  could in principle leave the shared cache in a state the quarantine probe could
  not rule out. Each attempt is bounded by the same `--timeout` /
  `--compile-timeout` budget as the first.
- Every attempt's diagnostics are retained in the report. The **last** attempt's
  outcome is authoritative. A test that passes only after a retry is reported
  **FLAKY** and, being a pass, exits 0 and by default passes CI.
- Under `--fail-on-flaky` (or `[run] fail-on-flaky`), a session whose outcome
  tier would be 0 and whose summary counts at least one FLAKY file exits 1
  instead. Terminal verdict only: retry behavior, `--maxfail` counting (a flaky
  pass still counts 0), and last-run state (a FLAKY file still clears a prior
  failure — it passed) are unchanged. The report artifacts are unchanged too,
  and the `--junit-xml` document is the one to know about: a FLAKY file is a
  pass with a `flakyFailure` child, so the document still reports
  `failures="0"` beside a process that exits 1. The console band, the
  `--json` stream's `exit_code`, and the `::notice` all carry the demotion;
  a CI that renders JUnit alone sees green.

Retries apply to precompile, build, and run steps on both ordinary and
selection (`-k` or node-id) paths.

---

## 14. Output capture

Child stdout and stderr are captured separately and byte-exactly.

- `--show-output MODE`: `failures` (default) shows captured output for FAIL and
  crash-class outcomes; `all` shows it for every test; `none` suppresses it.
- `-s` is an alias for `--show-output all`.
- `--show-output` governs the **console's** display of captured output only; the
  machine reporters (`--junit-xml`, §15.2; `--json`, §15.4) carry capture per
  their own bounded, always-on rules, unaffected by this flag.

---

## 15. Reporters

### 15.1 Console

`-q` (quiet: files plus summary) and `-v` (verbose) are mutually exclusive.
`--color WHEN` is `auto|always|never`. A resolved `always` or `never` is
absolute, whether it came from the project file or CLI. A resolved `auto` from
either source first disables color when `NO_COLOR` is set, then otherwise uses
the resolved console destination's terminal-ness. The console summary is ordered
deterministically (§17), not by completion order. Console text layout and color
are **informal** and may change.

**Console destination.** The console writes to **stdout** by default, and to
**stderr** when `--json -` owns stdout for the byte-pure event stream (§15.4) —
one resolved destination through which every console byte flows, so a `--json -`
run's stdout carries only stream lines. `--color auto` decides against that
**resolved** destination: stdout's terminal-ness normally, stderr's when the
console is relocated there.

**Terminal text safety.** Every string the console learns from a child process
or from user input — paths, node ids, test names, patterns, program names,
reproduce arguments, warnings, captured stdout and stderr, failure detail, and
compiler diagnostics — is neutralized before it is printed, so no child can emit
bytes a terminal emulator executes. Two modes:

| Code point | Scalar fields | Multiline fields |
| --- | --- | --- |
| `U+0000`..`U+0008`, `U+000B`..`U+001F` | `\xHH` | `\xHH` |
| `U+0009` (Tab) | `\x09` | literal Tab |
| `U+000A` (LF) | `\x0A` | literal LF |
| `U+000D` (CR) | `\x0D` | `\x0D` |
| `U+007F` (DEL) | `\x7F` | `\x7F` |
| `U+0080`..`U+009F` (C1) | `\u00HH` | `\u00HH` |
| everything else | unchanged | unchanged |

`HH` is always two **uppercase** hexadecimal digits. **Scalar** fields are the
ones that occupy exactly one console line: paths, node ids, test names,
patterns, program names, the toolchain label, warning text, and every token of a
reproduce or build command line (each token is neutralized before it is
shell-quoted, so the quoting covers the text actually shown). **Multiline**
fields are the blocks whose line and tab structure is real: captured stdout and
stderr, per-test failure detail, and compiler output.

Every multiline field is additionally **line-prefixed**: each logical line is
printed behind a four-space `| ` gutter (`"    | "`). A trailing LF closes the
last line rather than opening an empty one, an empty logical line still gets its
gutter, and every printed line is LF-terminated. The gutter is what separates
the child's text from mtest's own, since a child can print a perfectly ordinary
line that looks exactly like a verdict row or a summary band.

mtest's own labels, separators, and ANSI color are applied **after** escaping
and are never escaped, so `--color always` still paints mtest's lines while a
child's `ESC [ 3 1 m` shows up as the literal text `\x1B[31m`.

The same neutralization applies to the **GitHub annotation tail** (§15.3), which
mtest prints to this same resolved console destination and which is therefore a
terminal surface as well as a workflow one.

Three further surfaces print untrusted text to a terminal and neutralize the
same set of code points, in the escape spelling their own output format
requires: `mtest doctor` (§23), which quotes the toolchain's own `--version`
output; `mtest config show` (§25), whose values come from `mtest.toml` and which
uses TOML's `\u00HH` form because a TOML basic string has no `\xHH` escape at
all; and the configuration diagnostics, which quote an offending key or value
back from that same file. That last one matters more than it looks: TOML forbids
a raw C0 control inside a basic string, so the parser rejects an ESC before it
can be quoted, but C1 is a legal TOML string character — a hostile `mtest.toml`
could otherwise drive the terminal through the very message that rejects it.
**Which** code points are neutralized is one definition shared by all of these
surfaces; only the spelling differs.

The `collect` listing under `--format lines` (§16) is the one
terminal-reachable output that is **not** escaped, deliberately: it is a
byte-exact machine listing of node ids, specified for tooling to consume, and
escaping it would break that contract. Under `--format json` the same ids are
carried as JSON strings and are escaped by that encoding
(`docs/collect-stream.md`), which is a transport rule rather than this
display boundary.

This boundary is **display-only**. It does not change what mtest captures, what
its parser reads, or what the JUnit report (§15.2) or the machine event stream
(§15.4) contain: those are written to their own destinations and carry the raw
text under their own formats' escaping rules. Console text layout remains
**informal** (§20); the guarantee that no child-controlled control character
reaches the terminal unescaped is not.

**Explicit non-goal: visual spoofing.** The boundary answers "can the child
drive the terminal", not "can the child mislead the reader". Code points that
reorder or disguise text while executing nothing — the bidi overrides and
isolates (`U+202A`..`U+202E`, `U+2066`..`U+2069`), zero-width characters, and
confusable homoglyphs — are passed through **unchanged, by design**. They are a
rendering-layer concern with no single correct answer for a terminal, and
escaping them would corrupt legitimate right-to-left test names and assertion
text. A test name can therefore still *look* like something it is not; it can no
longer *do* anything.

A **live progress counter** — a running `completed/total` line naming the files
currently in flight — is drawn during a parallel run (`-n`/`--workers` > 1). It is
a **terminal-only** affordance: it renders solely when the resolved console
destination (§15.1, stdout or the relocated stderr under `--json -`) is a TTY, is
**erased before** each finished file's result block prints and redrawn beneath it,
is throttled (at most a few updates per second), and is **suppressed under `-q`**.
It is **informal** (§20): it writes no bytes to a non-terminal (piped or
redirected) destination, never appears in the `--json` stream (§15.4, the
`progress` kind is excluded by design), is never part of the §17 determinism
guarantee, and a sequential run (the default, one worker) shows no counter at all.
A file's result still prints when the file finishes; the summary band, the
slowest-files list, and the failure detail all print at completion, and the
deterministic surfaces (§17) never depend on completion order.

**The `SLOW` annotation.** A build or run step whose wall time reaches **60 s**
is flagged `SLOW`. It is an **informal** annotation, never an outcome: it does
not appear in the outcome vocabulary (§10.1), never changes a verdict or the
exit code, and is not part of the §17 determinism guarantee. Under `-v` the note
names *which* step (build or run) crossed the threshold and its duration, so a
comptime-stalled compile is visible at 60 s rather than only at the 600 s
compile deadline.

**The `SERIAL` annotation.** A file pinned by `--serial` (§18) and run
one-at-a-time on the serial pass carries an informal `SERIAL` marker on its
result line. Like `SLOW` it is an annotation, never an outcome: it does not
appear in the outcome vocabulary (§10.1), never changes a verdict or the exit
code, and is not part of the §17 determinism guarantee. The machine stream
carries the same fact as the FileFinished `serial` field (§15.4).

**Slowest files — `--durations N`** (`N` a non-negative integer). After the
summary band, print the `N` slowest **files** by run-only wall-clock (the process time for the run step
alone; build time is not counted). The header states the *actual* number of
rows printed — `min(N, files that ran)` — never the raw requested `N`. This
list is **informal** (§20), like the rest of the console reporter, and is
explicitly **not** part of the §17 determinism guarantee: its content tracks
real elapsed time, which varies run to run, even though the sort itself
(duration descending, path ascending on ties) is deterministic for a given set
of durations. An explicit `--durations` survives `-q` — it prints even in
quiet mode. `N=0` (the default) disables the list. `--durations` is a
**run-only** flag; combining it with `collect` is a usage error (§4).

### 15.2 JUnit XML — `--junit-xml PATH`

`--junit-xml` is **served**: it writes a JUnit XML report — the settled
junit-10 dialect (`scripts/schemas/junit-10.xsd`), the same the committed
`scripts/checks/reports/junit.py` oracle blesses — assembled from the runner's own typed
events, never from a parse of the console text.

- **Document shape.** One `<testsuites>` root carrying `name`, `tests`,
  `failures`, and `errors` — and **not** `skipped` (junit-10 defines no root
  `skipped`; the root skipped total is an arithmetic fact recomputed from the
  child suites). One `<testsuite>` **per file**, carrying all four aggregate
  counts (including `skipped`). Each `<testcase>` carries `name` and `classname`
  (the file's dotted stem) and, optionally, ONE primary outcome child
  (`failure`/`error`/`skipped`) plus any number of ordered rerun/flaky children.
- **Outcome mapping**, total over the vocabulary:

  | Outcome | XML |
  |---------|-----|
  | PASS | `<testcase>` (no child) |
  | FAIL | `<testcase>` with `<failure>` (the verbatim assertion detail) |
  | SKIP | `<testcase>` with `<skipped/>` |
  | CRASH | `<testcase>`/sentinel with `<error>` |
  | TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT, MALFORMED-SUITE, PRECOMPILE-ERROR | sentinel `<testcase>` with `<error type="...">` |

- **Sentinels.** A file-level outcome (no single test identity) attaches to one
  synthesized sentinel testcase inside that file's suite: `[build]` for a
  non-retried file-level failure, or `[attempts]` for a retried one. The two are
  **mutually exclusive** — a suite carries at most ONE outcome-carrying
  sentinel, or none when per-test rows already carry the verdict. A precompile
  failure emits its own `mtest::precompile` suite with a `[precompile]` error,
  plus one `[not-run]` suite per NAMED casualty; a bare casualty count with no
  names invents no rows. A file that was selected but never ran — a precompile
  casualty, or an interrupt/`--maxfail`/gate-abort skip — appears as a
  synthesized `[not-run]` skipped testcase, so the report is total over the
  selected set.
- **Session properties.** The build-cache counters ride one synthesized
  `mtest::cache` `<testsuite>` with all four aggregate counts zero, whose whole
  body is a `<properties>` block naming `built_files` and `cached_files`. It is
  session-level rather than a path, like `mtest::precompile`, and it carries no
  `<testcase>`, so it adds nothing to the root aggregates. Its values are the
  one part of the document that tracks store history rather than inputs (§17).
- **Retries and flakiness** ride Surefire chronology in the `[attempts]` row: a
  flaky pass carries one `<flakyFailure>` per earlier failed attempt (in attempt
  order); a rerun-exhausted failure carries the FIRST failed attempt as the
  primary and every later attempt (the final included) as a `<rerunFailure>`/
  `<rerunError>`. Every rerun/flaky child carries the schema-required `type`.
- **Capture.** Captured child output attaches once per suite as
  `<system-out>`/`<system-err>`, bounded (64 KiB head + 64 KiB tail, elision
  marked) and always-on — independent of `--show-output`, which governs only the
  console (§14). All text is XML-escaped through the one shared path; a sentinel
  `name` (`[build]`, `[attempts]`, `[not-run]`) is emitted verbatim.
- **Time.** Suite-level `time` is the runner's own wall clock per file, formatted
  as fixed-three-decimal seconds (JUnit's own policy, distinct from the JSON
  stream's integer microseconds). Per-testcase `time` and suite `timestamp` are
  **omitted** (schema-optional) while upstream per-test timings are untrustworthy
  (honesty over decoration).
- **Ordering is deterministic**: testcases are sorted by node id, and suites by
  their key, independent of completion order. A testcase whose `name` already
  contains `::` is its own node id (used verbatim); a bracket sentinel is keyed
  as `<file>::[sentinel]` but never renamed.
- **Artifact lifecycle.** A unique temp file is created in the TARGET directory
  at session start — proving it writable BEFORE any build or run — and the
  assembled document is written there and renamed **atomically** onto PATH only
  after a verified complete write. Unlike the live `--json` stream, the prior
  report at PATH is **NEVER truncated**: on any failure the target is left
  exactly as it was. A syntactically bad destination (an empty value or a
  nonexistent parent directory) is a pre-run usage error (exit 4, §9); a runtime
  creation or finalization failure (an unwritable or vanished target) is an
  internal error (exit 3, §9). Report destinations are not root-constrained.
  A PATH that names the same file as another active destination — a `--json`
  file destination or either `--report` path — is a pre-run usage error
  (exit 4), because the other writer would replace this document or be replaced
  by it depending only on finalization order. The comparison is by resolved
  identity, so `out.xml` and `./out.xml` are one destination; the full rule is
  stated once in §15.5.

### 15.3 GitHub annotations — `--gh-annotations MODE`

`--gh-annotations` is **served**: it emits GitHub Actions annotation
workflow-command lines to **stdout**, in a deterministic tail after the console
summary band. `MODE` is `off|on|auto`; **`auto` (the default) is on iff
`GITHUB_ACTIONS=true`**, `on` always renders, `off` never does. The tail renders
only when resolved-on.

**The frozen annotation shapes**, one clear entry per kind:

- **Per-test FAIL** → `::error file=<f>,line=<l>::<node id>: <first assertion
  line>`. `line=` is present **only** when that first line itself carries a
  recognizable `At <path>:<line>:<col>:` backtrace pointer (the same shape the
  console renders root-relative); a detail with no such pointer (e.g. a bare
  `raise`) omits `line=` rather than guess one — **location honesty**: `line`
  appears only where the assertion detail carried it, and `file=` paths assume
  the invocation root is the repo root.
- **Crash-class / file-level** (CRASH, TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT,
  MALFORMED-SUITE) → `::error file=<f>::<f>: <outcome in words>`. Never carries
  `line=` (there is no per-test location for a whole-file abnormal outcome). A
  plain per-test FAIL file is covered entirely by its per-test rows above.
- **FLAKY** → `::warning file=<f>::<f>: flaky — passed on attempt K of N`.
- **Precompile failure** → one `::error::<step>: …` with **no** `file=` property:
  the failure belongs to the STEP, not any one file; the casualty files appear as
  JUnit rows, not per-file annotations, so an annotation flood never burns the
  error cap on a derivative fact.
- **The summary notice** → exactly **one** `::notice::<band text>` per run, never
  subject to the caps.

**Level mapping**: failing → `::error`; FLAKY → `::warning`; the single run
summary → `::notice`.

**The tail is PER-KIND GROUPED**, each block node-id-sorted: the whole
node-id-sorted `::error` block, then the whole node-id-sorted `::warning` block,
then the single `::notice`. This is **not** a global node-id interleave across
error and warning lines — the per-kind caps and the cap-minus-one aggregate line
make per-kind grouping the deterministic, unambiguous form.

**Bounds**. Each payload is escaped via the message escaper (`%`→`%25`,
CR→`%0D`, LF→`%0A`) and each `file=` value via the property escaper (adds
`:`→`%3A`, `,`→`%2C`); user-controlled paths, names, and assertion text are never
interpolated raw into a workflow command, and an escaped-away CR/LF means a
would-be forged second command line can never form. Both escapers then apply the
console's terminal-safety mapping (§15.1) to what remains, because mtest prints
this tail to the **console destination**, which may be a terminal: every C0
control other than the already-encoded CR/LF, plus DEL and the C1 controls,
becomes visible `\xHH`/`\u00HH` text. Tab rides through literally — it is legal
in a workflow command and addresses nothing. The order is load-bearing: the
workflow encoding runs first, so `%0D` and `%0A` survive as GitHub's own
line-folding rather than being rewritten into visible escapes. Each message is
bounded to
**4096 escaped bytes** (measured after escaping), with a truncation marker when
cut. The **per-run per-STEP caps are 10 errors and 10 warnings** (a workflow STEP
is capped at 10 error and 10 warning annotations; the "50" some readers conflate
is the Checks **API**'s own per-request limit, a REST surface mtest never calls);
past the cap the first `cap - 1` sorted rows render individually and one
**aggregate** line (`… and N more …`) replaces the rest, so a block never exceeds
its cap.

**Stop-commands FENCING of echoed child output.** Whenever `GITHUB_ACTIONS=true`
— independent of `MODE`, even `off` — every echoed region of captured **child**
output the console renders (captured stdout/stderr under `--show-output`, failure
and precompile excerpt regions) is wrapped in `::stop-commands::<token>` …
`::<token>::` fencing, so a child's own `::error`-shaped bytes cannot forge a
workflow command. The token is **high-entropy** (≥128-bit random, from
`/dev/urandom`), **per-run-unique**, minted **after** the producing child has
exited, never exposed to any child (not in its env or argv), and **regenerated**
until the complete resume delimiter `::<token>::` is absent from the region being
fenced. Restoration runs through an **always-runs epilogue**: a final resume
delimiter is emitted before mtest's own annotation lines, so no error or
partial-write path can leave workflow commands disabled or a fence unterminated.

A **PRECOMPILE-ERROR** annotates with **no** `file=` (the failure belongs to the
step; its casualties appear as JUnit rows, not per-file annotations).

**The `--json -` interplay.** `--json -` makes stdout the byte-pure event stream,
which the annotation tail cannot share. Beside `--json -`, annotations must be
**explicitly `off`** — the only combination that runs. Both an explicit
`--gh-annotations on` and the **default `auto`** are usage errors (exit 4, §9),
detected by pre-run resolved validation, and the message names both fixes (drop
`--json -`, or set `--gh-annotations off`). `--json PATH` does not own stdout,
so annotations may ride alongside it.

### 15.4 Machine event stream — `--json PATH|-`

`--json` is **served**: it writes a newline-delimited stream of the runner's own
typed events — the same events the console reporter consumes — to `PATH`, or to
stdout when the value is `-`. `docs/json-stream.md` is the **normative** spec;
this section summarizes it.

- **Framing and header.** NDJSON: one complete JSON object per `\n`-terminated
  line, valid escaped UTF-8, no floats (`Infinity`/`-Infinity`/`NaN` never
  appear). Line 1 is the frozen header `{"event":"stream","version":1,
  "generator":"mtest <version>"}`.
- **Events.** The stream mirrors every session event the console reporter sees,
  with the `progress` kind **excluded** by design: it is ephemeral,
  console-only, and never serialized. Each record mirrors the model's payload
  1:1 under its own field names.
- **`*_us` durations.** The sole naming exception: every `*_seconds` duration is
  emitted as an integer-microsecond `*_us` field, so the stream carries no
  floating-point value.
- **Ordering.** An informal timeline with frozen split invariants: per session,
  header → `session_started` → precompile records → per-file events →
  `crash_attribution` → `session_finished` last; per file, contiguous
  `test_reported` rows and monotonic `attempt_finished` records precede that
  file's `file_finished`.
- **Terminal.** Exactly one `session_finished` is dispatched in every scenario
  (normal, interrupt, fatal abort), carrying the final `exit_code`. The stream
  therefore carries zero-or-one terminal record: its **absence** (or a torn final
  fragment) is the truncation signal.
- **Determinism.** Two runs of the same inputs are equal under a closed
  projection (outcomes, per-test sets, counts, dispositions, flags, casualty
  lists, totals, exit code); the byte-payload fields with their omission metadata
  and every measured `*_us` duration are excluded from that comparison.
- **Writes and SIGPIPE.** Each line is drained through a `write_all` loop, so a
  cut stream leaves complete lines plus at most one torn final fragment. SIGPIPE
  is ignored for the run; a latched stream-write failure (a `--json -` consumer
  that closed early, a full or unwritable destination) is a **fatal abort** to
  exit 3, never death at 141.
- **Destinations.** `-` makes stdout the byte-pure stream (the console relocates
  to stderr, §15.1). A `PATH` is written live and a pre-existing file is
  **overwritten** at session start (a live stream cannot rename atomically, so
  this differs from JUnit's atomic write, §15.2); report destinations are not
  root-constrained. A syntactically bad destination is a pre-run usage error
  (exit 4, §9); a runtime open failure is a pre-run internal error (exit 3, §9).
  A `PATH` that names the same file as another active destination — `--junit-xml`
  or either `--report` path — is a pre-run usage error (exit 4), because this
  stream truncates at session start and would destroy whatever the other writer
  was going to publish there. `--json -` is exempt: stdout has no filesystem
  identity to collide with. The comparison is by resolved identity, so `out.json`
  and `./out.json` are one destination; the full rule is stated once in §15.5.
- **Versioning.** Version 1 freezes the framing, header, event names, field
  meanings, and vocabularies. Growth is additive (new fields and kinds);
  consumers **must ignore** unknown fields and kinds. A removal or
  meaning-change bumps the header version; the version lives only on the header.

`--json` is a **run-only** flag in v1 (§4).

---

### 15.5 Run report — `--report FORMAT:PATH`, `--report-style STYLE`

`--report` is **served**: it writes one self-contained document describing the
whole run — a summary table, a per-file section for the files that need a
second look, the reasons any selected file never ran, and a machine index of
reproduce commands. It is assembled from the runner's own typed events, exactly
as the JUnit report is, never from a parse of the console text.

- **Grammar.** `--report FORMAT:PATH`, where `FORMAT` is `md` or `html` and
  `PATH` is a non-empty filesystem path. The value splits at the **first** `:`,
  so a path may contain further colons. The flag is repeatable **once per
  format**: `md` and `html` together compose two documents from one run, while a
  second destination for a format already given is a usage error (exit 4) rather
  than a silent last-wins. An unknown format, a missing separator, and an empty
  path are usage errors too.
- **Destinations.** There is no `-` stdout form: the document is assembled and
  renamed atomically, never streamed live, so `md:-` names an ordinary relative
  file called `-`. The parent directory must already exist. Nothing at `PATH` is
  touched until the final rename, so a prior report survives every failure. A
  unique temp is created **in the target directory** at session start, which is
  what proves that directory writable before any file is built. Report
  destinations are not root-constrained.
- **Destination collisions.** Every active file destination — `--json PATH`,
  `--junit-xml PATH`, and both `--report` paths — must name a different file.
  Two of them naming one file is a usage error (exit 4) detected before the run,
  because each writer would otherwise truncate or rename over the other's work
  and which survived would depend on finalization order. The comparison is by
  resolved identity rather than by spelling, so `out.md` and `./out.md` are the
  one destination they are. Where the destination's own directory ignores case
  — which the runner asks that directory rather than assuming from the platform
  — `Run.out` and `run.out` are also the one destination they are there, and
  the same refusal applies; where it does not, the two are the different files
  they are and the pair is accepted. `--json -` is excluded: it names the
  inherited stdout stream, which has no filesystem identity. The check belongs to the
  commands that open destinations, so `config show` — which resolves without
  touching the filesystem — renders a collision with both values' provenance and
  never refuses (§27.1).
- **`--report-style STYLE`.** `concise` (the default) or `full`, last-wins.
  Under `concise` every file earns a summary row and only a file that needs a
  second look earns a per-file section; under `full` every file earns both. The
  flag is **inert without a resolved destination**: supplying it alone is
  accepted and changes nothing, the `--fail-on-flaky` precedent.
- **Both formats render one model.** Markdown and HTML are two renderings of the
  same typed data, so the two documents describe the same run and differ only in
  presentation. Untrusted text — a failure detail, a captured stream, a path —
  is escaped for the structural position it lands in, and control bytes are
  scalarized before that escaping — except that a captured stream and a failure
  detail, which are rendered as multi-line blocks, deliberately keep their
  literal LF and Tab so the block retains the shape the child produced. Every
  other control byte, including a bare CR, is scalarized there too.
- **Failure handling.** The two sinks are independent: a Markdown failure never
  stops the HTML document from publishing, and neither ever replaces the report
  already at the other's target. A destination that cannot be prepared at
  session start is a pre-run internal error (exit 3, §9), and a report that
  cannot be written, closed, or renamed at finalization is a delivery failure
  that resolves the same way — a requested report that could not be produced is
  an error, so even a green run exits 3.
- **Permissions.** A published report carries the mode an ordinary new file
  would get here — the `0666` an `open(2)` asks for, minus the process umask —
  and not the `0600` of the temporary it was assembled in. A report is written
  to be read by a CI job, a reviewer, or a web server, none of which run as the
  runner's user. The mode is set on the temp before the rename, so there is no
  window in which the published path is owner-readable only, and it is verified
  by observing the file rather than by trusting the call. A filesystem that will
  not apply it — one whose modes come from its mount options, or one that
  refuses `chmod` outright — still receives the complete report, at whatever
  mode it allowed. That is announced on stderr and changes no exit code: the
  requested artifact was delivered, and an exit 3 would say it was not.

`--report` and `--report-style` are **run-only** flags in v1 (§4).

---

## 16. `collect`

`mtest collect [PATHS] [flags]` (and `mtest --collect-only`) lists node ids
sorted **lexicographically**, in one of two formats: `--format lines`, the
default, prints one node id per line, and `--format json` prints the versioned
NDJSON collect stream described below. The runner imposes its own order so the
frozen output format never couples to TestSuite's discovery order (execution
still uses discovery order internally). `collect` accepts the selection and
build flags because it compiles files to enumerate them.

Per file, the build-then-probe (§5, §6) resolves one of four ways:

- A **qualifying** probe (an all-SKIP report, §6) contributes its node ids to
  the listing.
- A **compile error, a crash, a timeout, or MALFORMED-SUITE** (§6) writes a
  diagnostic to stderr and the listing **continues** with the remaining files
  — MALFORMED-SUITE during `collect` is in the same **exit-1 class** as it is
  during a run.
- A **protocol-drift** probe (a report present but off-grammar, §6) is an
  internal error and forces **exit 3**; the listing still diagnoses the
  remaining files to stderr, but the session cannot exit anything but 3.
- An internal/machinery failure (e.g. an unspawnable build) **aborts** the
  listing outright at **exit 3**.

The session exit code is **2** if the collection was interrupted, else **3** if
any drift or internal failure occurred, else
**1** if any file failed to collect (compile error, crash, timeout, or
MALFORMED-SUITE), else **5** if nothing was collectable, else **0** —
consistent with the §9 precedence, under which an interrupt (→ 2) dominates an
internal error (→ 3), which
dominates a failing outcome (→ 1), which dominates "nothing collected" (→ 5).
An interrupt reaches `collect` for the same reason it reaches a run: a
collection probes real child processes, and a `SIGINT` that arrives partway
through ends it where it stands rather than completing a listing nobody waited
for.

`--format json` renders that same listing as a versioned NDJSON stream instead
of plain lines: a header, one `node` record per node id in the identical order,
and a `collect_finished` terminal carrying the node count and the exit code.
Both formats are derived from the one sorted listing, so they can never
describe different test sets, and the diagnostics above stay identical stderr
text under either. The terminal's `exit_code` is the **final process exit
code**, teardown included, so a consumer may gate on the record alone.
`docs/collect-stream.md` is the normative specification; `--format lines` (the
default) is byte-identical to the listing this section describes.

---

## 17. Determinism

Given the same inputs, `mtest` orders every machine and console surface
deterministically — the console summary, the `collect` listing, and the
`--junit-xml` document are all sorted by node id, independent of the order in
which files or parallel workers finished. Parallelism never changes *what* is
reported, only how fast.

That shared ordering does not mean every surface is byte-identical across runs;
each below states its actual promise, scoped precisely:

- **`collect`** output stays **byte-identical** across runs of the same inputs:
  the frozen listing (§16, §20) carries no wall-clock or captured-text content
  to vary.
- **`--junit-xml`** (§15.2) is deterministic in **structure, identity,
  classification, and counts** — the `<testsuite>`/`<testcase>` shape, node-id
  names, `classname`, the `message`/`type` attributes on outcome children, and
  the `tests`/`failures`/`errors`/`skipped` aggregates — but it is **not**
  byte-identical: `time` (the runner's own wall clock, §15.2) and every embedded
  captured/diagnostic text body (`system-out`/`system-err`, a `failure`/`error`
  detail, a stack trace, a rerun/flaky child's text) are exactly the payload
  classes the `--json` projection excludes below, and the committed
  canonicalizer masks precisely those two classes before comparing two runs'
  documents.
- **`--json`** (§15.4; normatively `docs/json-stream.md` §10) promises equality
  under a **closed projection** — outcomes, per-test sets, counts, dispositions,
  flags, casualty lists, totals, and the final exit code — never byte order and
  never a duration or byte-payload field. Two runs' raw streams may differ line
  for line while still agreeing on that projection.

**`--shuffle` randomizes execution order and nothing else.** It reorders the
run files a session executes; every reported surface above stays node-id
sorted, exactly as it does under `-n`, so no listing, document, or summary
moves because the order did. The promises in this section are promises about
the same inputs, and a seed is one of those inputs: `--shuffle --seed N` holds
all of them run to run, while a bare `--shuffle` draws a fresh seed per
invocation, which is a different input each time. The resolved seed is printed
on the console header and, under `--json`, carried on `session_started`, so the
order a run actually took is always attributable and repeatable.

The build cache is the one thing that varies with history rather than with
inputs, and both projections carve it out:

- `session_finished`'s `built_files` and `cached_files` are counts, but they are
  outside the `--json` projection. Their SUM is stable for identical inputs — it
  is the first-attempt compile admission count — while the split records what
  the store happened to hold when the run started, so a cold run and a warm one
  over the same tree divide it differently.
- `--junit-xml`'s `mtest::cache` property suite (§15.2) reports that same split
  and is outside the structural promise for the same reason. The document's
  shape, node ids, classifications, and test aggregates are unaffected.

§17 carries no byte-identity claim over anything wall-clock- or payload-bearing:
not `--junit-xml`'s `time` or embedded captured/diagnostic text, and not
`--json`'s measured `*_us` durations or its capture/argv/casualty payload
fields.

---

## 18. Concurrency

`-n, --workers N|auto` sets the worker count; files run concurrently across the
pool while each file's own steps (build → run → retries) stay strictly ordered.
**The default is one worker** — with no flag, files run sequentially and the
build argv is byte-identical to a single-worker build. `auto` sizing is
runner-chosen and may tune across minor versions: it is a stable *intent*
(benchmark-informed — half the logical cores — taking half rather than the whole
machine to leave headroom for other work and bound capture memory, not because
extra workers starve each other on build threads), not a stable number. Concurrent builds share a
cores-wide thread budget: each build spawns `mojo build --num-threads K` for
`K = max(1, cores // min(workers, cores))`, so the builds' threads never
oversubscribe the machine (a user `-j`/`--num-threads` is forbidden, §8.4); a
run takes no build thread. The resolved worker count is capped by the
environment's effective file-descriptor ceiling: a request above it is **clamped
with a loud warning** that names the cap, and the resolved count — never the
request — is what the run uses and what the machine stream reports (§15.4).

**Sizing `-n`.** The `auto` count is benchmark-informed: a worker-sizing
benchmark measured scaling that keeps paying well past a handful of workers, so
`auto` is `max(1, cores // 2)` — half the logical cores. Half rather than all of
them is deliberate politeness, not a scaling limit: it leaves cores for other
work and keeps the peak output-capture memory in check. That memory is the other
reason to size `-n` with care — each in-flight worker holds up to **16 MiB** of
output-capture buffers at peak (8 MiB for stdout and 8 MiB for stderr per child),
so `N` workers can hold up to `N × 16 MiB` at once, and `auto` at half the cores
bounds that at `cores // 2 × 16 MiB`. It is a worst case, reached only when
children actually emit that much output; the capture is bounded and keeps the
head and tail while dropping the middle (§14), never growing without limit. A
memory-constrained environment should lower `-n` accordingly. `auto` remains an
*intent*, not a promised number (it may tune across minor versions).

`--timeout SECS` (default 300, `0` disables) bounds a single file's **run**;
exceeding it yields TIMEOUT. `--compile-timeout SECS` (default 600, `0`
disables) bounds a single file's **build**; exceeding it yields COMPILE-TIMEOUT
with a hint to split the module or exclude it. It kills after the same
signal-first sequence with a compile-specific grace (~5s longer than a run kill,
since a compiler unwinds more slowly). Timeout kills are signal-first (a
terminate signal, then a grace period, then a hard kill) and reach the owned
process group, not just the direct child. A descendant that deliberately leaves
that group (for example, with `setsid()`) cannot be killed by the group sweep;
if it retains a capture pipe past the bounded cleanup deadline, the run is
reported as an internal cleanup error, never as a pass.

**`--shard [hash:|slice:]M/N`.** Splits the discovered RUN-file set into `N`
disjoint shards and runs only shard `M`'s files, for spreading one suite across
parallel CI jobs. `1 <= M <= N`; a malformed value is a usage error (exit 4).
The partition is applied to the **post-exclusion** run-file universe **before
any build**, so a sharded-out file is never compiled. Two modes:

- **`hash:` (the default).** A file is owned by shard `M` iff
  `fnv1a64(path) % N == M-1`, where `fnv1a64` is canonical FNV-1a 64-bit (frozen
  offset basis `0xcbf29ce484222325`, prime `0x100000001b3`) over the **lexical
  root-relative** NodeId path exactly as discovery produced it — never a
  realpath. Assignment depends only on the path bytes, so it is stable across
  machines and independent of discovery order.
- **`slice:`.** The eligible files, already sorted lexicographically, are dealt
  round-robin: the file at sorted index `i` is owned iff `i % N == M-1`.

Sharding applies to both `run` and `collect` (§4) — sharding what gets
collected, not only what gets run. **Gates are never sharded**: every gate file
runs on every shard, so the smoke-test-first guarantee holds per job. Node-id
operands are validated against the owning shard only — a node id naming a file
this shard does not own is not this shard's to reject. Sharded-out files are
**counted, not listed** (§10.2), and a shard that owns no run files falls under
the empty-collection exit code (§9).

**`--shuffle` and `--seed N`.** `--shuffle` randomizes the order the RUN files
execute in, to surface a test file that only passes because another ran first.
Gate files are never shuffled: they keep their listed order and still run
first. `--seed N` fixes that order to a reproducible draw and requires
`--shuffle` (exit 4 otherwise, as is `--seed` with a value that is not an
integer `>= 0`). Without `--seed` the runner draws a seed itself and reports
it, so any randomized run can be replayed. The seed-to-order mapping is frozen
for 1.x: one seed names one order over one file list, on every platform.
`--shuffle` is refused beside `--lf`/`--ff` (exit 4), because those choose an
order too. It composes with `--shard`: the partition is applied first, over the
sorted list, so shard membership is unchanged and only the order within a
shard's own files moves. It is a run-only flag (§4) and is never read from
`mtest.toml`.

**`--serial GLOB` (repeatable).** Pins every file matching `GLOB` to run outside
the parallel pool, one at a time, for suites with a shared resource (a port, a
device) that cannot tolerate concurrent access. Each occurrence adds one glob
pattern; `--serial` is a **run-only** flag (§4). Matching uses the same
whole-path glob as `--exclude` (§12). Serial files run **after** the parallel
files (serial-last), one whole pipeline at a time: a serial file's build, run,
and any retries all complete — and every parallel slot has drained — before the
next serial file is admitted, so no two serial files (nor a serial and a parallel
file) ever overlap. A `--serial` pattern that matches no discovered file is
reported as a **stale** pattern with a loud warning, exactly as a stale
`--exclude` is. At one worker (`-n 1` or the default) the run is already
sequential, so `--serial` changes nothing but the stale-pattern check. A serial
file's result line carries an informal `SERIAL` marker (§15.1).

---

## 19. Help and version

- `mtest --help`, `mtest -h`, and `mtest help` print usage to **stdout** and exit
  **0**.
- The grouped option help is generated from the parser's flag inventory. Every
  option or combined alias row is value-labelled, aligned to one help-text
  column, rendered on one physical line, and no help line exceeds 78 columns.
- `mtest version` and `mtest --version` print the version to **stdout** and exit
  **0**.
- A usage **error** prints to **stderr** and exits **4**.
- The two **0**s assume stdout took the bytes: the text is the whole product,
  so a write that fails for any reason other than a departed consumer exits
  **3** instead, with a diagnostic on stderr naming the errno (§9). The usage
  error's **4** is not conditional in the same way — the code is itself the
  statement that argv was invalid, and it stands whether or not stderr took the
  prose explaining it.

---

## 20. Stability tiers

- **FROZEN, each from the release that first served it** — the bulk of this
  list shipped in 1.0.0 and froze there; the entries marked below as 1.1's are
  frozen from 1.1. The bare subcommand *vocabulary* is the one declared
  exception (see the header): reserving a new leading token is permitted, while
  every subcommand already served keeps its name, grammar, and meaning. The
  list: subcommands; flag names and semantics;
  exit codes; the node-id grammar; `mtest.toml` key names and semantics (§25);
  `--lf`/`--last-failed` and `--ff`/`--failed-first` semantics (§26);
  *(from 1.1)* `--shuffle`/`--seed` semantics, including what shuffling
  reorders and what it leaves node-id sorted, and the **seed-to-order
  mapping**: one seed names one permutation of one file list, byte-identically
  on every platform, so a printed seed reproduces the order that produced a
  failure (§18); *(from 1.1)* `--fail-on-flaky` semantics and its position in
  the exit precedence (§13, §9); *(from 1.1)* the `--format` value set and
  which subcommand it belongs to (§4, §16); *(from 1.1)* the `--report` value
  grammar, its once-per-format repetition, the `--report-style` value set, and
  the destination-collision refusal (§15.5);
  the JUnit mapping; the annotation shapes; the `--json` event stream schema
  (§15.4; normatively `docs/json-stream.md`) — its framing, header, event and
  field names, and token vocabularies, frozen at stream `version` 1 and
  growing only additively (new fields and kinds; a removal or a meaning-change
  bumps the header version); the `collect` format — the plain listing, and
  *(from 1.1)* the `--format json` collect stream (§16; normatively
  `docs/collect-stream.md`), whose framing, header, event names and field names
  are frozen at collect-stream `version` 1 and grow only additively under that
  same rule; *(from 1.1)* `debug`'s preparation semantics and refusal set, and
  the presence and order of its two `build:`/`run:` lines (§28); *(from 1.1)*
  the refusal rules and exit domains of `new` and `init` (§29); the
  test-module contract.
- **STABLE-INTENT** — default values (timeouts, `auto` worker sizing) may be
  tuned in minor versions; the self-versioned `.mtest-cache/lastrun` format
  (§26), whose incompatible changes require a new format version; the contents
  of every file `new` and `init` scaffold (§29). Those templates may improve in
  a minor release: what is promised is the §29 refusal rules — the no-replace
  publication and the exit domains above — and, for the workflow, byte-parity
  with the first YAML block of [the continuous-integration page](ci.md). That
  parity includes pinning each third-party action to the same commit the
  documentation pins, so a pin that moves in the documentation moves in the
  scaffold — which is what makes those commits a deliberate choice rather than
  a copy that quietly went stale.
- **INFORMAL** — console text layout and colors; the human-facing
  `config show` TOML output (§27.1); the wording of the per-artifact and
  next-step status lines `new` and `init` print (§29); the exact quoting style
  of `debug`'s two lines, whose presence and order are frozen above while the
  shell-quoting that makes them pasteable is not (§28).
- TestSuite invocation details are an internal seam, never public API.

---

## 21. Planned, not served

The following are not served by any build in the 1.x line so far. Nothing here
is a commitment to a release, and each is either unrecognized by the parser or
recognized-but-refused as noted. They do **not** share one release rule, so the
list is split by which one applies: whether serving the item would only add to
the inventory, or would change what something already served means.

**Additive — may land in a future minor.** `--root`; `--pattern`; markers /
`xfail`; `--asan`; watch mode; and a **relocatable** build-cache directory
(`--cache-dir`). Each of these is a new flag whose absence today means "off",
so serving one leaves every existing invocation reading exactly as it does now.
The build cache itself is served (§8.5), but only as a per-checkout store at
the fixed path `.mtest-cache/build-v1/`: choosing where it lives, sharing it
between checkouts or machines, and saving and restoring it in CI are separate
deliverables, each of which needs a key that survives leaving the machine it
was computed on.

**Not additive — these wait for a major**, because serving them would move a
surface that is already frozen:

- **Boolean `-k` expressions.** `-k` is served as a case-insensitive substring
  filter (§5), so today `-k "a and b"` matches node ids containing that literal
  text. Giving `and`, `or`, and `not` meaning would silently change what an
  existing, currently-valid `-k` value selects — a meaning change to a served
  flag, not an addition beside it.
- **A per-test granularity for `--durations`** (the slowest individual *tests*,
  not just files). The file-level `--durations N` is served (§15.1), so this is
  a redefinition of what `N` counts rather than a new surface. It is
  additionally blocked on the same upstream per-test timing gap that blocks
  per-test attribution elsewhere.
- **A machine-readable `config show` format.** §20 freezes the `--format` value
  set *and which subcommand it belongs to*: `--format` is `collect`'s alone,
  and supplying it anywhere else is a usage error (§4). Serving
  `config show --format json` would change that frozen applicability. The
  served TOML display stays informal human output in the meantime (§27.1).

---

## 22. Platforms

Linux and macOS are the v1 targets. Linux carries the native lifecycle,
process-supervision, transcript, dynamic memory-analysis, and packaged-artifact
gates. The unified workflow requires the macOS arm64 preflight to run the native
post-fork/lifecycle audit; on success it dispatches the full direct and
end-to-end behavioral inventory, each cell linking the binary it drives through
its own build dependency. This is the required topology, not yet an executed-evidence
claim: until the first hosted macOS matrix is green and recorded, current macOS
evidence remains the earlier build/link/`--help` smoke and runtime supervision
there remains unverified. Platform divergence in crash reporting is absorbed by
the structured termination model (a terminating signal is recorded as a signal,
never as a shell-encoded `128+N`).

The complete local `pixi run ci` mirror is serial and fail-fast; it is an
optional exhaustive local command. Required hosted CI is the authoritative
merge verdict and preserves that logical floor while overlapping independent
work: a Linux static preflight releases separate direct, end-to-end,
ASan/LSan, and Valgrind cells, and a `compiled oracles` job carrying the
preflight members that need a real compiler runs beside them; a macOS
preflight independently releases separate direct and end-to-end cells. The
three focused dogfood probes have no cell of their own — they block through
the packaged-artifact job, which runs them against the installed
artifact. The Linux packaged-artifact job
starts independently; the macOS packaged-artifact job waits on the macOS
preflight.
Memory-safety cells run for every pull request, configured `main`/`master`
push, and manual unified-CI invocation; there is no scheduled memory-safety
workflow. Protocol transcripts and sanitizers remain Linux-only;
packaged-artifact consumption is blocking on both linux-64 and osx-arm64.

**The packaged artifact.** The distribution recipe builds `mtest` **in-env from
source**, inside an isolated build environment pinned to the same
`mojo`/`clang` versions this repo itself builds against — the prebuilt-binary
branch (repackaging an already-linked executable) is **not** taken. The
installed binary is not loader-clean: it carries a direct link dependency on
the Mojo runtime's shared libraries, whose transitive closure is owned by the
`mojo-compiler` conda package. The recipe therefore declares
`mojo-compiler ==1.0.0b2` as its sole **conda run dependency**. Project
configuration is parsed natively by a pinned vendored Mojo parser compiled
into the binary. A fresh environment carrying only the declared dependency
(not the full build toolchain) is proven sufficient to load and run the
installed binary.
**linux-64 and osx-arm64 are both gated**: each platform has its own dedicated
blocking CI job that builds the package into a local channel, installs it into
a scratch environment from that channel, and exercises the installed binary.
The install is pinned to the exact version AND build string that job just
produced, and the installed `conda-meta` record's SHA-256 and subdir are
compared against the built artifact's, so a same-version package solved from a
remote channel fails the gate instead of standing in for it. Installed-binary
evidence covers `--version`, `--help`, a config-present parse, the focused
dogfood probes, and a known-failing fixture that must exit 1 with exactly one
FAIL row and no PASS row — the installed package is proven to report failure,
not only success. The gate itself is parameterized by an immutable platform
descriptor (subdir, loader-inspection command, loader environment variables);
an unsupported host stops the gate rather than borrowing another platform's
answers. The first hosted green for the macOS package job is pending as stated
above.

---

## 23. Worked examples

```text
# Run the default suite (tests/ if present, else the current directory).
mtest

# Run one directory, stop scheduling after the first failing file.
mtest tests/ -x

# Run a single test by node id.
mtest tests/test_math.mojo::test_addition

# Substring-filter to matmul tests, show output for all of them.
mtest -k matmul -s tests/

# Precompile a library, smoke-test first, exclude the slow suite, forward a
# build flag — the whole configuration lives on the command line.
mtest --precompile src/mylib:build/mylib.mojopkg -I build \
      --build-arg=--no-optimization --gate tests/test_smoke.mojo \
      --exclude 'tests/test_slow_*.mojo' tests/

# Produce CI artifacts.
mtest --junit-xml report.xml --gh-annotations auto tests/

# Machine-readable run for tooling — the versioned event stream to a file.
mtest --json report.ndjson tests/

# List node ids without running anything.
mtest collect tests/

# Show what this invocation resolves to, and which layer supplied each value.
mtest config show

# Re-run only what failed last time; or run everything, remembered failures
# first.
mtest --lf tests/
mtest --ff tests/

# Diagnose the environment without building or running a test.
mtest doctor
```

### 23.1 A configured project, end to end

The transcripts below were executed against this repository's own trees with
the built binary. Environment-dependent values appear as captured: the absolute
invocation root, the wall-clock timings, and the worker count `workers = "auto"`
resolved to on the capturing machine.

They do not all share one setup, and each block's own output says which it had.
The configuration example, `config show`, the invalid-configuration refusal, and
the healthy `doctor` block were captured with the `mtest.toml` below in place —
`doctor` reporting `PASS config: valid 'mtest.toml'` is that file being seen.
The `--lf` and soft-filter transcripts were captured without it, which is why
they carry no `slowest N files:` block despite the configuration setting
`durations`. In the two failing `doctor` blocks, `config: none` comes from the
explicit `--no-config`, not from the file's absence. Each transcript states its
own command, and none is a continuation of the one before it.

`mtest.toml` at the invocation root:

```toml
[run]
paths = ["e2e/matrix"]
workers = "auto"
retries = 1
timeout = 120

[build]
include = ["build"]
compile-timeout = 300

[report]
durations = 2
show-output = "none"

[[override]]
files = ["e2e/matrix/test_beta.mojo"]
timeout = 30
serial = true
```

`[run] paths` supplies the operands, `workers = "auto"` resolves the pool, the
`[[override]]` table pins one file serial, and `[report] durations` adds the
slowest-files list:

```text
$ mtest
mtest 1.0.0 (mojo)
root: /home/mikko/dev/mtest   selected: 2 files   excluded: 0   workers: 16

PASS           e2e/matrix/test_alpha.mojo      0.02s
PASS           e2e/matrix/test_beta.mojo       0.02s  SERIAL

===== 5 passed, 0 failed, 0 skipped (0 excluded, 0 not run) in 0.9s =====

slowest 2 files:
  e2e/matrix/test_alpha.mojo  0.02s
  e2e/matrix/test_beta.mojo  0.02s
$ echo $?
0
```

`config show` renders the resolved values with the supplying layer, and a
command-line value overrides the file in the same rendering (`-k` is accepted
and, being per-invocation selection, not rendered):

```text
$ mtest config show --timeout 30 -n 4 -k alpha
[run]
paths = ["e2e/matrix"]  # (mtest.toml)
exclude = []  # (default)
gates = []  # (default)
serial = []  # (default)
workers = 4  # (cli)
timeout = 30  # (cli)
retries = 1  # (mtest.toml)
maxfail = 0  # (default)
state = true  # (default)
fail-on-flaky = false  # (default)

[build]
mojo = "mojo"  # (default)
include = ["build"]  # (mtest.toml)
build-args = []  # (default)
precompile = []  # (default)
compile-timeout = 300  # (mtest.toml)

[report]
color = "auto"  # (default)
show-output = "none"  # (mtest.toml)
verbosity = "normal"  # (default)
durations = 2  # (mtest.toml)
# junit-xml = (unset)
# json = (unset)
gh-annotations = "auto"  # (default)
# md = (unset)
# html = (unset)
style = "concise"  # (default)

[[override]]
files = "e2e/matrix/test_beta.mojo"  # (mtest.toml)
timeout = 30  # (mtest.toml)
serial = true  # (mtest.toml)

# config file: mtest.toml
# state file: .mtest-cache/lastrun (present)
# selection flags are per invocation and are not rendered
$ echo $?
0
```

An invalid configuration is refused before any build, with the file, table,
key, and expectation named:

```text
$ mtest e2e/matrix
config: mtest.toml: [run] key 'retries': expected integer >= 0; got 'two'
$ echo $?
4
```

The `--lf` iteration loop, over a selection whose one failure was recorded by
the preceding run:

```text
$ cat .mtest-cache/lastrun
mtest-lastrun v1
test	e2e/suite/test_failing.mojo::test_second_fails

$ mtest --lf e2e/matrix e2e/suite/test_failing.mojo
mtest 1.0.0 (mojo)
root: /home/mikko/dev/mtest   selected: 3 files   excluded: 0

FAIL           e2e/suite/test_failing.mojo     0.02s

--- FAIL e2e/suite/test_failing.mojo::test_second_fails ---
    | At e2e/suite/test_failing.mojo:14:17: AssertionError: `left == right` comparison failed:
    |    left: 1
    |   right: 2
reproduce: mtest e2e/suite/test_failing.mojo::test_second_fails

[...file-scoped captured output omitted...]

===== 0 passed, 1 failed, 0 skipped (0 excluded, 2 not run, 7 deselected) in 1.3s =====
$ echo $?
1
```

The soft-filter guarantee, on a selection the persisted records do not
intersect: both diagnostics are emitted and the ordinary full selection runs
rather than exiting 5:

```text
$ mtest --lf e2e/matrix
mtest 1.0.0 (mojo)
root: /home/mikko/dev/mtest   selected: 2 files   excluded: 0

lf: previously-failing e2e/suite/test_failing.mojo::test_second_fails no longer exists — dropped
lf: no previously-failing tests match this selection — running the full selection
PASS           e2e/matrix/test_alpha.mojo      0.02s
PASS           e2e/matrix/test_beta.mojo       0.03s

===== 5 passed, 0 failed, 0 skipped (0 excluded, 0 not run) in 0.9s =====
$ echo $?
0
```

`doctor`, healthy and with one contained failure. The failing check names what
broke; every other check still runs:

```text
$ mtest doctor
PASS version: mtest 1.0.0
PASS platform: Linux x86_64 supported
PASS root: /home/mikko/dev/mtest
PASS exec: runtime acquired
PASS toolchain: 'mojo' from PATH default: Mojo 1.0.0b2 (2cf4d08a)
PASS config: valid 'mtest.toml'
PASS config-semantics: resolved values valid
PASS state: cache and lastrun usable
PASS temp: invocation root and system temp usable
PASS report-destinations: none
$ echo $?
0

$ MTEST_MOJO=/opt/nonexistent/mojo mtest doctor --no-config
PASS version: mtest 1.0.0
PASS platform: Linux x86_64 supported
PASS root: /home/mikko/dev/mtest
PASS exec: runtime acquired
FAIL toolchain: '/opt/nonexistent/mojo' from MTEST_MOJO: could not execute
PASS config: none
PASS config-semantics: resolved values valid
PASS state: cache and lastrun usable
PASS temp: invocation root and system temp usable
PASS report-destinations: none
$ echo $?
1
```

A selected-config failure is a `FAIL`ed check and exit 1 under `doctor`, where
`run` and `config show` refuse it as a usage error and exit 4 (§27.2):

```text
$ mtest doctor --config ci/mtest.toml
PASS version: mtest 1.0.0
PASS platform: Linux x86_64 supported
PASS root: /home/mikko/dev/mtest
PASS exec: runtime acquired
FAIL toolchain: dependency config unavailable
FAIL config: ci/mtest.toml: configuration file does not exist
FAIL config-semantics: dependency config unavailable
PASS state: cache and lastrun usable
PASS temp: invocation root and system temp usable
FAIL report-destinations: dependency config unavailable
$ echo $?
1
```

---

## 24. Availability status (this build)

Everything above is the full frozen-intent v1 contract. This section is
different in kind: it states what the *current build* actually implements,
today, so a reader can tell shipped behavior from target behavior without the
contract above changing at all. Nothing in this section alters any flag
semantic, exit-code meaning, node-id grammar, or outcome vocabulary defined
above — it only reports which of those surfaces are wired up yet.

### 24.1 Flags and subcommands

**Served** (parsed into real behavior): positional `PATHS`, `-k`, `--exclude`,
`--config`, `--no-config`, `-I`, `--build-arg` (and post-`--` passthrough),
`--precompile`, `--mojo`,
`-x`/`--exitfirst`, `--maxfail`, `--timeout`, `--compile-timeout`, `--retries`,
`--fail-on-flaky`,
`--shard`, `--lf`/`--last-failed`, `--ff`/`--failed-first`,
`-n`/`--workers`, `--serial`, `--shuffle`/`--seed`,
`--no-cache`, `--cache-clear`, `--gate`,
`-s`/`--show-output`,
`--durations`, `-q`/`-v`, `--color`, `--format`,
`-h`/`--help`, `--version`, and the `run`, `collect`, `config show`, `doctor`,
`debug`, `new`, `init`, `completions`, `version`, and `help` subcommands
(`--collect-only`
too, as an alias that behaves as `collect`), plus `init`'s own `--ci VALUE`
and `completions`' own `SHELL` operand (§30).
`--shard` applies under both `run` and `collect`. `--json` (the machine event
stream, §15.4), `--junit-xml` (the JUnit report, §15.2), `--gh-annotations`
(the CI annotation tail, §15.3), and `--report`/`--report-style` (the run
report, §15.5) are served too — see §24.2 for how they are now
reached. `--format lines|json` is served under `collect` and refused everywhere
else (§4), with `lines` the default.
`--no-cache`/`--cache-clear` act on the persistent build-artifact
store described in §8.5, which this build reads and writes by default.

Every flag and subcommand in the frozen contract above is now served: nothing is
refused for being unavailable. For `run` and `collect`, exit 4 therefore covers
exactly the frozen §9 causes. `Config show` and `doctor` use the applicability
rules and command-specific exit domains in §27; `debug` uses §28's, `new`
and `init` use §29's, and `completions` uses §30's.

### 24.2 Run and collect exit codes reachable in this build

Run/collect semantics are unchanged from §9; this states which paths to each
code exist today. Section 27 separately covers the reachable `config show` and
`doctor` exits.

- **0** — reachable: every run outcome is PASS or SKIP (exclusions allowed).
- **1** — reachable for FAIL, CRASH, TIMEOUT, COMPILE-ERROR, COMPILE-TIMEOUT,
  MALFORMED-SUITE, and PRECOMPILE-ERROR. FLAKY (a pass produced only after a
  crash-class retry) is also emitted now, and, being a pass, does **not** raise
  the exit code — a FLAKY-only session exits 0. It is additionally reachable
  from a FLAKY-only session under `--fail-on-flaky` (or `[run] fail-on-flaky`),
  which demotes that would-be 0 to 1 (§13).
- **2** — reachable for both the sequential and the parallel path. An interrupt
  (SIGINT/SIGTERM) prints a partial summary, reports the files that had not yet
  started as NOT-RUN, and cleans up every in-flight child's process group with a
  two-pass terminate-then-kill sweep; a second interrupt escalates to an
  immediate hard kill of every group, leaving no survivor. The exit is 2
  regardless of any failing outcome already accounted. It is reachable under
  `collect` too, where a probe is an ordinary child process: the listing ends
  where the interrupt found it, and under `--format json` the terminal record
  carries the same 2 the process exits with.
- **3** — reachable via a spawn failure (the runner could not spawn `mojo` or
  a built binary), via protocol drift (a report present but off-grammar, §6)
  in both `run` and `collect`, via runtime `--json`, `--junit-xml`, or
  `--report`
  report-destination failures (§9), and via undelivered primary output — a
  `collect` listing, or a run's console report, whose destination is closed or
  full. The console reaches it through the same delivery precedence a dead
  `--json` destination uses, so both run drivers behave alike and an interrupt
  still outranks it. A departed consumer never reaches it (§9).
- **4** — reachable under `run` and `collect` for every served cause in §9 —
  including mutually exclusive config controls; `--seed` without `--shuffle`
  and `--shuffle` beside `--lf`/`--ff`; a `--format` value that is neither
  `lines` nor `json`, and `--format` outside `collect` at all; a selected
  config that is
  missing, unreadable, malformed, or invalid; a syntactically invalid `--json`
  or `--junit-xml` destination; a `--report` value outside `md:PATH`/`html:PATH`,
  a repeated format, or a `--report-style` value outside `concise|full`; two
  active file destinations naming one file; the `--json -`/annotations stdout
  conflict; and
  a `--cache-clear` target that is a symlink, carries no deletion-authorization
  marker, or cannot be deleted (§8.5), all detected pre-run.

**`--json` reachability.** `--json PATH|-` is served (§15.4): it is parsed into a
live event-stream reporter composed beside the console. Its destination is
validated syntactically by pre-run resolved validation (exit 4 on an empty value
or a nonexistent parent directory) and opened at session start (exit 3 on a
runtime open failure); a stream write that fails mid-run is a fatal abort to exit
3. The §9 causes are cited here, never restated.

**`--junit-xml` reachability.** `--junit-xml PATH` is served (§15.2): it is
parsed into a JUnit report reporter composed beside the console and the stream.
Its destination is validated syntactically by pre-run resolved validation (exit
4 on an empty value or a nonexistent parent directory) and a unique temp is
created in the target directory at session start to prove it writable (exit 3
on a runtime creation failure). Unlike the stream, a spool failure never aborts
mid-run; it surfaces at finalization, where the report is assembled and renamed
atomically onto PATH (exit 3 on a finalization failure, with the prior report
never truncated). The §9 causes are cited here, never restated.

**`--report` reachability.** `--report FORMAT:PATH` is served (§15.5): it is
parsed into a run-report writer composed beside the console, the stream, and the
JUnit report, with one independent sink per requested format. Each destination
is validated syntactically by pre-run resolved validation (exit 4 on a malformed
value, a repeated format, or a nonexistent parent directory), every active file
destination is checked against its siblings for a collision (exit 4), and a
unique temp is created in each target directory at session start to prove it
writable (exit 3 on a runtime creation failure). Like the JUnit report and
unlike the stream, a spool failure never aborts mid-run; it surfaces at
finalization, where each document is streamed, closed, and renamed atomically
onto its PATH (exit 3 on a finalization failure, with the prior report never
truncated), and a failure in one sink never stops the other from publishing.
`--report-style` shapes those documents and is inert without a destination. The
§9 causes are cited here, never restated.

**`--gh-annotations` reachability.** `--gh-annotations off|on|auto` is served
(§15.3): it is parsed into a self-gating annotations reporter composed beside the
console, the stream, and the JUnit report. `auto` (the default) resolves on iff
`GITHUB_ACTIONS=true`; the tail renders to stdout after the console band only when
resolved-on. Beside `--json -` it must be explicitly `off` — the default `auto`
and an explicit `on` are usage errors (exit 4) detected by pre-run resolved
validation (§9). The stop-commands fencing of echoed child output is active whenever
`GITHUB_ACTIONS=true`, independent of the mode.

**`debug` reachability.** `mtest debug PATH::TEST` is served (§28). Its whole
exit domain is pre-handoff and is `{1, 2, 3, 4}` plus whatever the test binary
itself exits with: 4 for a malformed node id, an unknown path, a node id whose
path is not a runnable file, an unknown test name, or any flag outside its
grammar; 2 for an interrupt during the build or the probe; 3 for a spawn or
machinery failure, for protocol drift, for a failed exec or a failed runtime
restoration, and for the two `build:`/`run:` plan lines when stdout could not
take them — a reader who never received them cannot rerun anything, which is
the whole point of the command before the handoff; and 1 for a failed
precompile step, a compile error, a
build killed at `--compile-timeout`, or a probe that crashed, timed out,
overflowed its capture, or did not read as a collection listing. Once the
handoff happens mtest is gone, so the process's exit status is the binary's own
statement and no code in this section applies to it.

**`new` reachability.** `mtest new PATH` is served (§29.1). Its whole exit
domain is `{0, 3, 4}`: 0 with `created PATH` on stdout, 4 for a target carrying
`::`, a target that is not Mojo source, a basename no directory walk would
collect, a target that already exists, or anything in argv but one operand and
`-h`/`--help`, and 3 for a filesystem failure while creating the directories or
the file, or for a report line its stream could not take (§9). There is no
other code, because nothing is discovered, built, or run.

**`init` reachability.** `mtest init [--ci github]` is served (§29.2). Its
whole exit domain is `{0, 3, 4}`: 0 for a run that created every artifact, one
that skipped every artifact, or any mixture — an all-skip is a success, because
the promise is that the artifacts exist, not that this run made them — 4 for a
`--ci` value other than `github`, for an artifact name held by a symlink or
anything else that is not a regular file, and for anything in argv beyond
`--ci VALUE` and `-h`/`--help`, and 3 for a filesystem failure while creating a
directory, writing an artifact, or rewriting `.gitignore`, for a `.gitignore`
past the 1 MiB rewrite ceiling, for a `.gitignore` that appeared after the
pre-run observation and is not a regular file, and for a report block its
stream could not take (§9). Every exit-4 cause is decided
before the first artifact is created, so a refused `init` leaves the directory
as it found it. There is no other code, because nothing is discovered, built,
or run.

**`--format` reachability.** `--format lines|json` is served under `collect`
(§16): `lines` is the default and leaves the listing byte-identical to a run
without the flag, while `json` renders the collect stream specified in
`docs/collect-stream.md`. Both refusals are pre-run usage errors (exit 4): an
unrecognized value, and the flag supplied to anything but `collect`. Because
the terminal record carries the teardown-adjusted exit code, none of the codes
above becomes unreachable or changes meaning under `json`; the stream reports
whichever one the collection resolves.
- **5** — reachable via an empty walk, via the everything-excluded case, and
  via deselection (`-k` matched nothing, §9).

### 24.3 Selection and parsing deviations in this build

Two surfaces behave more permissively, or cover less ground, today than the
frozen contract above describes. They are stated here so shipped behavior can
be told from target behavior; neither changes a flag semantic, exit code, or
the node-id grammar, and both converge to the contract as the runner matures.

- **`collect` does not narrow by per-test selection yet.** §4 lists `-k` as
  applicable to `collect`, and §16 says `collect` honors the selection flags.
  This build does not yet apply per-test selection to the `collect` listing: a
  `-k` under `collect` prints a loud `-k is ignored in collect mode` notice and
  lists every node id in the discovered files, and a `PATH::TEST` node-id operand
  contributes its whole **file** to the listing rather than the single test.
  `collect` still honors path/directory operands, `--exclude`, `--precompile`,
  `-I`, and the other build flags — only the per-test narrowing is deferred. A
  `run` **does** honor `-k` and node-id narrowing; this deviation is
  `collect`-only. (Narrowing `collect` by `-k` — the `pytest --collect-only -k`
  workflow — arrives with the same selection plumbing.)
- **A repeated single-valued flag takes the last occurrence.** §3 enumerates the
  repeatable flags (`--exclude`, `--gate`, `--build-arg`, `-I`, `--precompile`,
  `--serial`); every other flag is single-valued. The frozen intent is
  at-most-one — e.g. §5 says "at most one `-k` is accepted in v1". This build
  does not yet reject a repeated single-valued option (`-k`, `--shard`,
  `--maxfail`, `--timeout`, `--retries`, `-n`/`--workers`, `--mojo`,
  `--compile-timeout`, `-s`/`--show-output`, `--durations`, `--color`,
  `--format`, `--json`, `--junit-xml`, `--gh-annotations`, `--config`,
  `--seed`, `init`'s `--ci`): it silently uses
  the **last** occurrence (so `-k a -k b` filters by `b`, not `a or b`). Until
  the at-most-one check is enforced (a usage error, exit 4), do not rely on
  repeating these flags. The mutually-exclusive `-q`/`-v` pair is already
  rejected as a usage error; the single-valued-flag check follows the same
  shape.

---

## 25. Project configuration

At the invocation root, `mtest` automatically loads `mtest.toml` when that file
exists. Absence is silent. `--config PATH` selects a different file, including
one outside the root; `--no-config` suppresses both automatic discovery and
parsing. The two controls are mutually exclusive. A selected file inside the root is identified
root-relatively in `session_started.config_file`; an outside file is identified
by its normalized absolute path; absence is the empty string.

The file is TOML parsed natively by the pinned, vendored `mojo-toml` source.
Only the following closed schema is accepted; unknown tables or keys, wrong
types, and invalid values are exit-4 usage errors:

```toml
[run]
paths = ["tests"]                 # replaces the default path list
exclude = ["tests/generated_*"]  # replaces --exclude's lower layer
gates = ["tests/test_smoke.mojo"]
serial = ["tests/gpu_*"]
workers = "auto"                 # or an integer >= 1
timeout = 300                    # integer seconds >= 0
retries = 0                      # integer >= 0
maxfail = 0                      # integer >= 0
state = true
fail-on-flaky = false            # exit 1 on a FLAKY-only session

[build]
mojo = "mojo"
include = ["vendor"]
build-args = ["-DDEBUG"]
precompile = ["src/lib.mojo", "src/gpu.mojo:build/gpu.mojopkg"]
compile-timeout = 600            # integer seconds >= 0

[report]
color = "auto"                   # auto | always | never
show-output = "failures"         # failures | all | none
verbosity = "normal"             # quiet | normal | verbose
durations = 0                    # integer >= 0
junit-xml = "reports/junit.xml"
json = "reports/events.ndjson"   # PATH or "-"
gh-annotations = "auto"          # off | on | auto
md = "reports/run.md"            # the Markdown run report's destination
html = "reports/run.html"        # the HTML run report's destination
style = "concise"                # concise | full

[[override]]
files = ["tests/gpu_*"]          # or one non-empty string
timeout = 60
compile-timeout = 900
retries = 1
serial = true
```

A document must also fit the parser's work budgets, which exist so hostile
input cannot make parsing unbounded: at most 4 MiB of source, 64 levels of
structural nesting, 16,384 structural nodes (`[`, `{`, `=`, `,`), 512
top-level table headers and assignments, and 1 MiB in any single scalar
or comment.
Exceeding one is an exit-4 usage error whose diagnostic names the budget and
its limit. The budgets are sized above anything this schema can express — an
exclude list of a thousand globs and dozens of `[[override]]` tables are both
well inside them — so a configuration that is valid by the rules above is
never refused for size. They are a ceiling on abuse, not a documented capacity.

`[report] style` sits beside the console appearance keys and is not one of
them: `verbosity`, `color`, and `show-output` shape what a human watching the
live run sees, while `style` decides how much detail the WRITTEN `md`/`html`
documents carry (§15.5) and is inert unless one of those destinations is set.

Within a table, a key/value pair ends at the end of its line, as TOML 1.0
requires: `timeout = 1 state = false` on one line is a parse error, not two
settings.

Resolution is per key: built-in defaults < `mtest.toml` < non-empty
`MTEST_MOJO` < CLI. `MTEST_MOJO` affects only `mojo`; `NO_COLOR` is consulted
only after the resolved color is `auto` (§15.1). A supplied list replaces the
lower list, including when it is empty; positional PATHS replace configured
`paths`. Configured path values and override globs are interpreted from the
invocation root, never from the config file's directory.

Run consumes every schema key. Collect consumes only paths, exclusions, both
timeouts, and build keys; run-only scheduling, state, and report values remain
inactive and cannot cause collect-only cross-value failures. Each matching
`[[override]]` table may supply per-file `timeout`, `compile-timeout`, `retries`,
and `serial = true`. For each scalar, the first matching table that supplies it
wins unless CLI supplied that scalar globally. Serial matching is a union:
global serial globs and every matching `serial = true` table pin the file.

There is no generic config environment overlay and no command that clears one
file key. Use a CLI value to replace a scalar/list, positional PATHS to replace
configured paths, or `--no-config` to suppress the whole file.

---

## 26. Last-run state and failure re-selection

When `[run] state` is true (the default), an unsharded run reads
`.mtest-cache/lastrun` and merges fresh verdict observations into its preserved
failure records. Collection never reads or writes it. Sharded runs may read the
state but never write it, because one shard cannot authoritatively replace the
whole suite's result.

The internal v1 text format is deterministic:

```text
mtest-lastrun v1
file<TAB>tests/broken_file.mojo
test<TAB>tests/test_math.mojo::test_divide
```

Record lines are sorted, deduplicated, root-relative, and end with one newline.
`file` records represent terminal file-level failures; `test` records represent
individual failing tests. A malformed header rejects the old contents and a
malformed record is dropped independently; both produce contained, nonfatal
`state-malformed-line` warnings after `session_started`.

The state file is read through the same guarded bounded reader the selected
configuration uses: opened nonblocking and close-on-exec, then checked to be a
regular file before any payload is consumed, so a FIFO, device, or directory at
the state path can never block the run, and a payload above the 1 MiB ceiling is
refused rather than buffered. An unusable state file — unreadable, not a regular
file, or oversized — is ignored, the session proceeds with no previous records,
and the fact is reported through the same contained `state-malformed-line`
channel. State is an accelerator, never a verdict input: no state condition is
an exit cause.

Persistence happens only after reporter finalization and resource close have
established the final exit code, and only for final code 0 or 1. Codes 2, 3, 4,
and 5 leave prior bytes untouched, as do collect, `state = false`, and sharded
runs. The writer creates a PID-qualified temp beside the target, closes it, and
atomically renames it onto `lastrun`. A create, write, close, or rename failure
prints one state diagnostic to stderr, preserves the prior file, and never
changes the session exit or emits a post-terminal event.

`--lf`/`--last-failed` and `--ff`/`--failed-first` are CLI-only run modes; they
are not project-config keys. Both consume state only when `[run] state` is true.
With `state = false`, no state read occurs and either mode prints exactly
`lf: state disabled by mtest.toml — running the full selection` before running
the ordinary selection.

Under `--lf`, persisted records are a soft filter applied after ordinary
discovery and per-file name collection. A `file` record selects the discovered
file while retaining any ordinary `-k` or node-id subset. A `test` record
selects its test only when the file and collected name still exist. Persisted
ids never enter the qualified CLI-selection lookup, so stale state never causes
exit 4. Each missing file or missing test is dropped nonfatally with one line:
`lf: previously-failing <id> no longer exists — dropped`. The identifier is
escaped so hostile state bytes cannot create another physical line.

Missing, empty, malformed/unknown-version, all-stale, or empty-intersection
state prints exactly
`lf: no previously-failing tests match this selection — running the full selection`
and runs the ordinary full selection instead of exiting 5. Codec diagnostics
for malformed input remain separate `state-malformed-line` warnings.

Known state-disabled or empty-state fallback is emitted immediately after the
session starts, before a gate can fail. Collection-dependent stale and
empty-intersection diagnostics remain at the post-gate collection barrier.

`--lf` narrows to surviving remembered failures and preserves discovery order;
it does not reorder that subset. A stale-name recovery intersects its fresh
ordinary selection with the effective `--lf` subset and never widens it.
`--ff` never narrows or validates persisted test names: file and test records
both mark their discovered file at file granularity. It moves those
remembered-failing files before the rest while preserving discovery order
inside each half. In pooled execution this stable partition is applied
independently to the parallel and serial bands, so serial membership never
changes. Gate records are live state but gates themselves remain untouched.
With `-k` or node-id operands, the truthful one-worker selection path uses one
post-gate band; `-n 2` still reports one worker and `--serial` is a no-op there.

`--lf` takes that same selection path, because its filter is applied at the
post-gate collection barrier, so it too resolves to one worker whatever `-n` or
`[run] workers` asked for, and `--serial` is a no-op under it. The header
reports the resolved count, so a `--lf` run simply shows no worker field.
`--ff` is unaffected and keeps the pool it was given. `--lf` also narrows only
what runs: every discovered file is still built and probed for its names before
the barrier the filter applies at, so it reduces executed tests and reported
output, not compilation.

Gates are never filtered or reordered by either mode: they always run first.
`--lf` and `--ff` together are a usage error. Either mode combined with
`--shard` is also a usage error. Either mode under `collect` or
`--collect-only` is refused as run-only based on CLI presence.

---

## 27. Inspection subcommands

### 27.1 Resolved configuration display

`mtest config show` accepts the full `run` grammar and applies the ordinary
resolution order: built-in defaults, `mtest.toml`, non-empty `MTEST_MOJO`, then
CLI. It performs resolution only. It does not discover, build, execute, set up
reporters, read or parse last-run state, or write state. The branch
short-circuits before every side effect the command line could otherwise
request, so `config show --cache-clear` renders the resolution and deletes
nothing: the flag is accepted, as the whole `run` grammar is, and performing its
deletion for a command that only prints would make an inspection command
destructive. `--config` and
`--no-config` keep their ordinary meanings; a missing, unreadable, malformed,
or invalid selected config produces the same exit 4 and byte-identical stderr
diagnostic as `run`.

The human-facing output is valid, copy-pasteable TOML in fixed `[run]`,
`[build]`, `[report]`, then ordered `[[override]]` table order. Every set
configuration key carries one trailing source label: `default`, `mtest.toml`,
`env MTEST_MOJO`, or `cli`.

**The rendering grows with the configuration schema, and that is not a
compatibility event.** A minor that adds a configuration key adds its line
here — 1.1 added `fail-on-flaky = false  # (default)` under `[run]`, so the
same project renders one more line than it did under 1.0. This output is
INFORMAL (§20) precisely so the display can track the schema without every new
key becoming a breaking change; a tool that needs a stable answer should read
the `--json` event stream rather than parse this.

Unset optional destinations are comments.
`workers = "auto"` represents the automatic worker sentinel. Strings and
arrays are TOML basic strings, precompile entries use canonical `SRC` or
`SRC:OUT` form, and enum values use their accepted lowercase spellings.
`NO_COLOR` adds an environment qualifier only when the resolved color remains
`auto`.

Trailers identify the selected config file, report only whether
`.mtest-cache/lastrun` is present, and explain that selection flags are
per-invocation and therefore omitted. Plain path operands remain
config-eligible and render in `[run] paths` with CLI provenance. Node ids,
`-k`, `--shard`, `--lf`, and other run-only non-configuration flags are
accepted but never rendered. When node-id operands displaced a configured path
list, a further trailer says so, because the empty `[run] paths` they leave
behind would otherwise read as a claim that the command line resolved paths to
nothing. The state presence probe never reads the file, so
malformed state contents have no effect. With no selected config, the command
does not initialize the native TOML parser.

The `config show` text is informal human output. A machine-readable
configuration-display format is reserved.

Its exit domain is `{0, 3, 4}`: 0 after successful rendering, 3 when
invocation-root acquisition itself fails or the rendering could not be written
to stdout for any reason other than a departed consumer (§9), and 4 for argv or
selected-config usage failures.

### 27.2 Environment doctor

`mtest doctor` performs a read-only diagnosis and renders exactly one
human-facing `PASS`, `WARN`, or `FAIL` physical line for each check, in this
fixed order:

1. `version` — the mtest version/build identity.
2. `platform` — the Linux/macOS support posture in §22. Linux x86_64 is a
   `PASS`; macOS arm64 is a `WARN` while hosted runtime evidence remains
   pending.
3. `root` — guarded current-working-directory acquisition.
4. `exec` — the guarded exec-runtime acquisition performed before check 1,
   plus its eventual restoration status.
5. `toolchain` — the resolved Mojo path and supplying layer, checked by a
   bounded `mojo --version` probe under the ordinary supervision substrate.
   A pass requires the exact pinned identity
   `Mojo 1.0.0b2 (2cf4d08a)`.
6. `config` — the selected file, `none`, or its normalized parse/read failure.
   `--no-config` is root-independent. An absolute explicit config remains
   checkable without a root; discovery and relative explicit paths require the
   root.
7. `config-semantics` — resolved-layer validation using the same diagnostic a
   run would issue.
8. `state` — `.mtest-cache/` usability and an absent or parseable v1 `lastrun`,
   including removal of any directory doctor created.
9. `temp` — invocation-root and system-temp writability.
10. `report-destinations` — usability of configured JUnit/JSON parent
    directories without opening, creating, or truncating the configured files.
    No configured destination is root-independent, as is an absolute parent;
    relative parents require the root.

Every check body is guarded independently. An unexpected error becomes that
check's contained `FAIL` line, with control characters escaped; later checks
still run. Dependent checks say which earlier capability is unavailable.
Doctor closes an acquired exec runtime on every path. It never discovers,
builds, or runs tests; opens reporters; reads or writes session results; writes
last-run state; or overwrites a predictable path. A probe or created state
directory that cannot be removed makes its check `FAIL`; the diagnostic names
the affected path. A unique probe or doctor-created state directory may remain
only when the filesystem refuses cleanup.

The exec runtime is acquired before the first check, so its interrupt handlers
cover ordinary check execution. Doctor samples the interrupt latch immediately
before runtime restoration begins and immediately after restoration returns,
then renders the complete ten-line block with one stdout write. Runtime close
restores signal dispositions in sequence, so the unavoidable handoff window
begins as soon as a disposition is restored, before close necessarily returns,
and continues through process exit. A signal arriving in that window may
follow the restored disposition rather than being guaranteed a doctor exit
code; the post-close sample observes only signals that reached the latch.

For exits resolved by doctor within the guarded lifecycle, the exit domain is
exactly `{0, 1, 2, 3, 4}`. Termination under a restored disposition during the
disclosed handoff is outside doctor's resolved exit domain:

- **0** — no check emitted `FAIL`; `WARN` is allowed.
- **1** — at least one check emitted `FAIL`, including a missing or unreadable
  explicit config, malformed or invalid selected config, unavailable
  toolchain, unusable state/temp/report parent, or runtime-close failure.
- **2** — SIGINT or SIGTERM latched during guarded doctor execution or either
  close-adjacent sample; cleanup still runs.
- **3** — the one stdout write carrying the whole block failed for a reason
  other than a departed consumer (§9). No check line was delivered, so no
  diagnosis was; that displaces whatever the checks themselves resolved.
- **4** — argv syntax or doctor-flag applicability error only.

Selected-config failures deliberately differ from `run` and `config show`:
doctor reports them as check failures, continues later checks, and exits 1;
the other commands refuse them as usage errors and exit 4.

`--color`, `-q`, and `-v` are accepted for command-line consistency, but the
fixed inventory is completeness-critical: these controls never suppress,
duplicate, or add check lines. Doctor output is uncolored; verbosity does not
alter its one-line details.

---

## 28. Handing the terminal to one test

`mtest debug PATH::TEST` exists for the moment a report is not what you want.
It prepares exactly one test the way a run would, prints the two commands it
used, and then **replaces the mtest process** with the test binary, so the test
owns the raw terminal: its stdin, its stdout and stderr connected directly to
the ones mtest was given rather than to a capture pipe, its signals, its
debugger, and its exit status, with nothing in between. What the replacement
process then does with those descriptors — line buffering, full buffering, none
— is its own runtime's choice, which `execv` cannot constrain.

**Preparation.** Everything before the handoff is ordinary supervised work. The
node id is resolved against the invocation root exactly as a `run` operand is
(§2, §5); the project file's precompile steps run — the flag itself is outside
the grammar below, but `[build] precompile` stays active, because a file that
imports a precompiled package cannot be built without them; the file is built;
and the built binary is probed with `--skip-all` (§6) to learn which tests it
actually collects. The requested name is validated against that listing, so a
typo is refused here rather than discovered later by a binary that would have
run nothing. The build cache is off for the whole preparation and `retries` is
zero, which is what makes the printed `build:` line reproducible by hand: the
output is the deterministic `build/bin/` path, not a content-addressed store
artifact (§8.5).

**Grammar.** Exactly one operand, carrying exactly one `::`. Beside it,
`--mojo PATH`, `-I PATH`, `--build-arg ARG` and post-`--` passthrough,
`--config PATH` or `--no-config`, and `-q`/`-v`. Every other flag is an
applicability error (exit 4, §4). `--retries` and `--timeout` are refused
rather than silently overridden, and `--color` and the reporter flags are
refused because the handoff leaves nothing behind to render or write with; each
reporter refusal says so.

**Inactive configuration.** Under `debug` the project file's `[report]`
destinations and the last-run state are inactive, which means their values are
never acted on: no report destination is resolved, checked, created, opened or
written, and `.mtest-cache/lastrun` is neither read nor written. A
`[report] junit-xml = "r.xml"` therefore produces no file and no diagnostic,
and an existing `lastrun` is left byte-for-byte as it was. The build keys and
both deadlines stay active, so a per-file `[[override]]` still bounds the build
and the probe.

Inactive is not the same as unparsed, and the difference is worth stating
plainly. The selected configuration file is still parsed and validated as a
document before any command projection exists, so a malformed value in *any*
table — `[report] color = "not-a-color"`, `[run] state = "not-a-boolean"` — is
a usage error (exit 4) under `debug` exactly as it is under `run` and
`collect`. A configuration file is well-formed or it is not, and that question
does not depend on which subcommand happens to read it.

**Captured output.** A refusal that came from a child carries what that child
wrote. A build that failed to compile prints the compiler's own banner beneath
its diagnostic, a crashing or malformed probe prints what the binary wrote to
stderr, and a failed precompile step prints the compiler output for that step —
all on stderr, bounded, with control characters escaped and a note when the
tail was dropped. There is no reporter under `debug` to echo them through, so
they travel on the diagnostic channel instead of being lost.

**Exit codes, all decided before the handoff.**

| Code | Cause |
|------|-------|
| 4 | a malformed node id, an unknown path, a node id whose path is not a runnable file, an unknown test name, a flag outside the grammar above, or a selected project config that is missing, unreadable, malformed, or invalid |
| 2 | interrupted during the build or the probe, or an interrupt latched at any point before the handoff — including while the two lines below were still being written |
| 3 | a spawn or machinery failure, protocol drift (§6), a failed exec, or a failed exec-runtime restoration |
| 1 | a failed precompile step, a compile error, a build killed at `--compile-timeout`, or a probe that crashed, timed out, overflowed its capture, or did not read as a collection listing |

**The handoff.** On success mtest writes exactly two lines to stdout,
shell-quoted so they can be pasted back:

```text
build: mojo build tests/test_thing.mojo -o build/bin/tests_stest_uthing
run: build/bin/tests_stest_uthing --only test_case
```

It flushes them, samples the interrupt latch, closes the exec runtime, samples
it once more, and — **only if the close succeeded and neither sample was set**
— replaces itself with the binary. The samples are what stop an interrupt that
arrived during the preparation, or while that write was blocked on a reader
that had stopped reading, from being answered with the debuggee's exit status
as though nothing had been interrupted. A failed close is refused as a
handoff (exit 3) rather than pressed through: restoration is what returns
`SIGPIPE` to its default disposition, and a debuggee that inherited `SIG_IGN`
would survive a broken pipe that should have killed it, so a genuine crash
could read as a pass.

From the exec on there is no mtest. The process id, the process group, the
controlling terminal, the signal routing, and every descriptor not marked
close-on-exec are the test binary's; **mtest renders no summary and makes no
verdict claim**. A post-handoff exit `0` is the binary's statement, not an
mtest PASS, and there is deliberately no machinery that could turn it into one.

Like doctor's restoration (§27.2), the close-to-exec window is disclosed rather
than papered over: restoration puts each signal back one at a time, so a signal
arriving between the first restored disposition and the exec follows the
restored disposition rather than being guaranteed a `debug` exit code. The
window is the price of handing over a process whose signal state is the default
one.

---

## 29. Writing source: `new` and `init`

Two subcommands produce source rather than consuming it. They share one
publication rule and one promise: an artifact is written under a temporary name
in its own destination directory and published with a hard link, so an existing
file is refused by the filesystem itself and its bytes are never opened,
truncated, appended to, or renamed onto. `init`'s `.gitignore` handling is the
one documented departure, specified in §29.2.

Both words are now reserved in the leading position, which is the compatibility
exception declared at the top of this document: `mtest new` and `mtest init`
are these subcommands even in a directory holding files by those names, where
earlier builds would have run them. Spell the path `./new` or `./init` to get
the old behavior back; the prefix is never read as a subcommand.

### 29.1 One test file — `mtest new PATH`

`mtest new PATH` writes a single runnable test file and stops. It is the
narrower of the two subcommands that produce source rather than consuming it —
`init` (§29.2) writes a whole project, this one writes exactly one file — and
it exists because the shape of a Mojo test file is not guessable: `test_*` functions are only half
of it, and a file without the `main()` that hands them to `TestSuite` builds
into a program that runs nothing (§6).

**Grammar.** Exactly one `PATH` operand, plus `-h`/`--help` and nothing else
(§4). No configuration is read, no toolchain is resolved, and no file is
discovered, built, or run. `PATH` is not root-constrained — it names a file to
create rather than a test to select, so the §2 rule for operands does not
apply to it, exactly as it does not apply to a report destination (§15.2).

**What it writes.** A file whose basename a directory walk would collect
(§5) — so `test_*.mojo`, and any other spelling is refused rather than written
somewhere the runner will never look again. A `PATH` containing `::` is refused
for the same reason from the other direction: `::` separates a path from a test
name (§5), so a file created under such a name is one mtest could never be
pointed at afterwards. Missing parent directories are created. The file is
created with the permissions any other tool would give it — `0666` minus the
process umask — not the private mode a temporary file carries.

The file's subject is its own basename with the `test_` prefix and the `.mojo`
suffix removed, so `tests/test_math.mojo` is a file of tests for `math`. That
name is escaped for the docstring it lands in, so every legal basename yields a
file that compiles. It carries a module docstring, the `std.testing` import,
one passing example test, and the `main()` that discovers and runs them, and it
passes as written:

```console
$ mtest new tests/test_math.mojo
created tests/test_math.mojo
$ mtest tests/test_math.mojo; echo "EXIT=$?"
...
EXIT=0
```

**Scaffold targets are never overwritten.** An existing target is refused, and
that refusal is a property of the filesystem rather than of a check: the file
is written under a temporary name in the target's own directory and published
with a hard link, which fails when the destination name is taken. A file
created by anything else between the decision and the publication is therefore
refused too, and its bytes are left exactly as they were. No path through this
subcommand opens, truncates, appends to, or renames onto an existing file.

**Exit codes.**

| Code | Cause |
|------|-------|
| 0 | the file was created; `created PATH` is written to stdout |
| 4 | a target containing `::`, a target that does not end in `.mojo`, a basename no directory walk would collect, a target that already exists, or anything in argv beyond one operand and `-h`/`--help` |
| 3 | a filesystem failure: the parent directories could not be created, or the file could not be written or published; or the report line itself could not be written to its stream for any reason other than a departed consumer (§9) |

Nothing else is reachable. Every diagnostic goes to stderr and the success line
goes to stdout (§19), and the diagnostics themselves are informal text (§20) —
the exit code and the file's presence are what this section freezes. The 3 an
undeliverable report line produces is the one code that does not describe the
file: the artifact may already exist and still be intact, and the exit says
only that the caller was never told so.

### 29.2 A whole project — `mtest init [--ci github]`

`mtest init` writes the files a project needs before a first run means
anything, into the invocation root, and stops. It runs before configuration
discovery for the same reason `new` does, and one better: the configuration it
writes is the file that discovery would have read.

**Grammar.** No operand — the destination is the invocation root — plus
`--ci VALUE` and `-h`/`--help`, and nothing else (§4). No configuration is
read, no toolchain is resolved, and no file is discovered, built, or run.

**What it writes**, in this order:

| Artifact | Content |
|----------|---------|
| `tests/test_example.mojo` | the §29.1 test file, for the subject `example` |
| `mtest.toml` | `[run] paths = ["tests"]`, so a bare `mtest` runs the suite |
| `.github/workflows/test.yml` | under `--ci github` only |
| `.gitignore` | `.mtest-cache/` and `build/bin/` entries, added rather than replaced |

The workflow is byte-identical to the first YAML block of
[the continuous-integration page](ci.md), which is therefore the single place
it is written down; a gate extracts that block and compares it against what the
runner emits, so the two cannot drift. Its `--ci` value is closed: `github` is
the one provider this build writes a workflow for, and any other value is a
usage error (exit 4) raised before anything is created.

**Nothing is replaced.** Each artifact goes through §29's no-replace
publication, so an artifact that already exists is reported and left alone. A
second `init` is therefore an all-skip that still exits 0: the command promises
the artifacts exist, not that this run created them. `skipped` means an
ordinary file is already there and, for `.gitignore`, that the cache is
genuinely ignored — never merely that the name is taken. A name held by a
symlink, a directory, or anything else that is not a regular file is a refusal
(exit 4) decided before the first artifact is created, because reporting it as
`skipped` would claim a file exists that does not. One line is emitted per
artifact —

```text
created <path>
skipped <path> (exists)
updated .gitignore
```

— followed by the prerequisites the project still needs, which are output
rather than decoration. Every one of them is load-bearing and they are ordered:
the workspace has to exist before a channel can be added to it (`pixi workspace
channel add` fails outright without a `pixi.toml`), the package has to be in
the workspace before `mtest` resolves at all, and under `--ci github` the
workflow installs from the lock file, which only exists once `pixi add` has
run. The trailing commit line is emitted under `--ci github` alone, because
without a workflow nothing here needs a committed lock.

```console
$ mtest init --ci github
created tests/test_example.mojo
created mtest.toml
created .github/workflows/test.yml
created .gitignore
next: pixi init .
next: pixi workspace channel add https://conda.modular.com/max/
next: pixi workspace channel add https://repo.prefix.dev/modular-community
next: pixi add mtest
next: mtest
next: commit pixi.toml and pixi.lock, which the workflow installs from
```

`pixi init .` is listed unconditionally rather than conditionally: `init`
writes no `pixi.toml` and reads none, so it cannot tell a fresh directory from
an existing workspace, and the command is a no-op to skip rather than a step to
guess at. In a workspace that already exists, skip it.

**`.gitignore` is the one file `init` edits.** Adding a line to a file means
rewriting it, so this artifact alone is read, appended to, and renamed over —
and the content written back is the content read followed by the added lines,
which is what makes replacing it correct rather than destructive.

Two entries are written, each under its own comment line and each added only
when it is missing: `.mtest-cache/` for the build cache and last-run state
(§8), and `build/bin/` for the binaries every run and every `mtest debug`
compile from the project's test files (§28). `build/` itself is deliberately
not claimed — the rest of that tree belongs to whatever else the project
builds there.

It is read and written as **bytes**. Git accepts a `.gitignore` that is not
valid UTF-8, so decoding one in order to write it back would turn a legal file
into a failed bootstrap; only ASCII is ever compared. A file larger than
1 MiB is refused rather than read to that ceiling and written back truncated.

Whether an entry is already ignored is decided by git's own rules, not by a
substring search: leading whitespace is part of a pattern (so `  .mtest-cache/`
ignores nothing and the entry is still added), trailing whitespace is not, a
`#` comment ignores nothing, a pattern naming an ancestor directory counts (a
project already ignoring `build/` needs no `build/bin/` line), and the **last**
matching pattern decides — a `!.mtest-cache/` after a positive pattern puts the
directory back, so the entry is added again. Wildcards are not expanded, so a
pattern that would only match through a glob reads as no match and the entry is
added. `skipped .gitignore (exists)` therefore means `git check-ignore` would
agree, not merely that some line looked right.

The permission bits of an existing `.gitignore` survive the rewrite, including
a read-only mode: the replacement is a rename in the containing directory, so
the file's own write bit never governs it and a `0444` `.gitignore` is updated
and comes back `0444`. A `.gitignore` whose name is held by a symlink or
anything else that is not a regular file is refused (exit 4) before any
artifact is created, rather than followed or replaced.

The window between that read and the rename is a lost update: a concurrent
writer's change to `.gitignore` inside it is overwritten. This is stated rather
than solved, and the bound on the damage is what makes that acceptable — it is
one file, in a directory a person is looking at, in a command run by hand once
per project.

**Exit codes.**

| Code | Cause |
|------|-------|
| 0 | every artifact exists; the per-artifact lines and the next steps go to stdout |
| 4 | a `--ci` value other than `github`, any artifact name held by a symlink or anything else that is not a regular file, or anything in argv beyond `--ci VALUE` and `-h`/`--help` — each detected before the first artifact is created |
| 3 | a filesystem failure while creating a directory, writing an artifact, or rewriting `.gitignore`; a `.gitignore` larger than 1 MiB; a `.gitignore` that appeared between the pre-run observation and its publication and is not a regular file; or a report block that could not be written to its stream for any reason other than a departed consumer (§9), which says nothing about the artifacts and only that the caller was never told about them |

Nothing else is reachable. A successful run writes to stdout; a failed one
writes what it did and what stopped it to stderr, because the record of a
partial bootstrap belongs with the diagnostic rather than split across two
streams. As in §29.1, the diagnostics are informal text (§20) — the exit code
and the artifacts' presence are what this section freezes.

---

## 30. Shell completion — `mtest completions SHELL`

`mtest completions SHELL` writes a completion script for one shell to stdout
and stops. It is the third subcommand that produces text rather than consuming
a suite, and the only one that produces neither a verdict nor a file: what to
do with the script is the caller's decision.

**Grammar.** Exactly one `SHELL` operand, plus `-h`/`--help` and nothing else
(§4). `SHELL` is closed — `bash`, `zsh`, or `fish` — and any other value is a
usage error (exit 4) raised before anything is written. No configuration is
read, no toolchain is resolved, and no file is discovered, built, or run. The
subcommand is recognized in the leading position only, like every other one
(§3), so `mtest -q completions` is a run with a `completions` path operand.

**What it writes.** A script for the named shell, on stdout, ending in a
newline. Every command-line fact in it — the subcommand vocabulary, each flag
spelling, its one-line description, its value placeholder, and the closed value
set it accepts — is derived from the same inventory this document specifies, so
a script can offer a flag this build does not accept only if the parser accepts
it too.

```console
$ eval "$(mtest completions bash)"       # bash
$ eval "$(mtest completions zsh)"        # zsh, after compinit
$ mtest completions fish > ~/.config/fish/completions/mtest.fish
```

**What the script offers.** The active command is resolved the way `parse_args`
resolves it: from the **leading** word alone, because that is the only position
a subcommand is recognized in. `mtest -q doctor <TAB>` is therefore completed
as a run, matching what it would do if executed. One refinement follows: a run
whose words already contain `--collect-only` is a collection, so it offers
`--format` and withdraws the flags that mode refuses. A bare `config` completes
exactly the mandatory `show` token (§27.1); `completions` completes the three
shell names above; and `new`, `init`, `help`, and `version` offer nothing,
because each takes at most one operand this document does not enumerate.

Within a command, only the flags that command accepts are offered, and a
flag's value is completed only under a command that accepts the flag: after
`mtest doctor --report-style` no style is offered — the line falls through to
`doctor`'s own flags — because that pair is a usage error (§4). A value with a
closed set completes to that set, a value that names a path completes against
the filesystem, and a value the contract does not enumerate — a glob, an
integer, a build argument — completes to nothing rather than to a guess.
`-I PATH` is in that last group rather than with the paths, and deliberately:
§8.2 refuses a Mojo source file there because the runner owns its source list,
so filesystem completion would offer values this build exits 4 on.
`--report FORMAT:PATH` reaches a path under its format prefix (§15.5): the
format first, and then the path after the separator, in all three shells.

**What differs between the three scripts is the shell, not the inventory.**
Each script offers the same flags, subcommands, and values, because all three
are rendered from the same tables; what a shell can *do* with them differs, and
three differences are worth naming. fish resolves the active command by
re-reading the command line on every rule, which is why its head conditions are
functions rather than a `case`, and its rules supply the whole `FORMAT:PATH`
word rather than a prefix and then a path. zsh's own `_files` performs the
second stage there, so path completion follows the reader's zsh styles rather
than anything specified here. And bash is the one shell that splits a word at
the `:` before the completion ever sees it, so what it inserts is the part
after the separator while the other two replace the whole word — visible if a
value is ever completed inside quotes, where bash does not split and the
inserted text carries the prefix instead.

The completions themselves are a convenience, not a contract: which candidates
a shell shows for a given prefix is INFORMAL (§20), and the same reasoning
applies to the script's internal structure. What is frozen is the grammar
above, the exit codes below, and the property that the script never offers a
flag, subcommand, or value this build refuses.

**Exit codes.**

| Code | Cause |
|------|-------|
| 0 | the script was written to stdout |
| 4 | a missing, repeated, or unrecognized `SHELL` operand, or anything in argv beyond one operand and `-h`/`--help` |
| 3 | the script could not be written to stdout for any reason other than a departed consumer (§9) |

Nothing else is reachable. A departed consumer — a closed pipe — is not a
failure of this command any more than it is of `--help` (§19).
