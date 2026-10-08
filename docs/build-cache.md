# Build cache

mtest compiles every test file with `mojo build` before it runs it. The build
cache keeps those binaries under `.mtest-cache/build-v1/` in the invocation
root, so a file whose compile inputs have not changed is not compiled again. It
is on by default and needs no configuration. The store is per-checkout and is
deliberately not persisted across CI runs: moving compiled artifacts into shared
state could reuse a binary built for a different host CPU.

The summary band reports the split. A cold store builds everything:

```console
$ pixi run bash -c 'build/mtest --cache-clear e2e/matrix'
mtest 1.2.0 (mojo)
root: /home/mikko/dev/mtest   selected: 2 files   excluded: 0

PASS           e2e/matrix/test_alpha.mojo      0.02s
PASS           e2e/matrix/test_beta.mojo       0.02s

===== 5 passed, 0 failed, 0 skipped, builds: 2, cached: 0 (0 excluded, 0 not run) in 1.6s =====
```

Run it again over the same tree and nothing is compiled:

```console
$ pixi run bash -c 'build/mtest e2e/matrix'
mtest 1.2.0 (mojo)
root: /home/mikko/dev/mtest   selected: 2 files   excluded: 0

PASS           e2e/matrix/test_alpha.mojo      0.02s
PASS           e2e/matrix/test_beta.mojo       0.02s

===== 5 passed, 0 failed, 0 skipped, builds: 0, cached: 2 (0 excluded, 0 not run) in 0.8s =====
```

`builds` counts files compiled for the first time this run — compile failures
included, because a file that failed to compile was still built. `cached` counts
files served from the store. Their sum is the run's first-attempt compile count.
The pair appears on the band only when the run admitted at least one compile,
and the same two numbers are `built_files` and `cached_files` on the `--json`
stream's `session_finished` record.

What the counters do *not* claim is that `builds: 0` means no compiler ran.
Three paths compile without admitting a first attempt, and none of them moves
either counter: a crash-class retry, a configured precompile step, and the
rebuild that recovers a file whose stored binary would not start. So
`builds: 0, cached: N` means nothing was compiled *to produce a verdict* — the
work the counters are about — and a run showing it can still have spawned the
compiler. Use `-v` if you need to see every command a run actually issued.

Read the counters, not the clock. Both runs above finish in about a second
because the files are tiny and `mojo` keeps a module cache of its own; the
counters are what tell you whether a compile happened.

`--compile-timeout` bounds only a compile that happens. A warm hit performs no
compile and cannot produce COMPILE-TIMEOUT; use `--no-cache` when you need to
exercise the deadline.

## What invalidates an entry

Each cached binary is keyed by a digest over the compile inputs mtest names —
everything an ordinary edit, upgrade, or move can reach:

- the resolved `mojo` executable — its canonical path, its contents, and its
  `--version` output — plus every entry of `<resolved compiler
  dir>/../lib/mojo`, by name and type, and the contents of every regular file
  among them, so a toolchain upgrade rebuilds everything. A wrapper script
  relocates that directory beside the wrapper, so the real compiler's libraries
  are not directly keyed; symlink resolution remains canonicalized;
- `MODULAR_HOME`, `MODULAR_CACHE_DIR`, `MODULAR_DERIVED_PATH`,
  `MODULAR_NVPTX_COMPILER_PATH`, and `XDG_CACHE_HOME` — the variables that move
  where the toolchain reads or writes something of its own, or which tool it
  reaches for. `PATH` is deliberately not among them; see the cache's non-goals
  in [the CLI contract](cli-contract.md) for what that leaves uncovered;
- the canonicalized invocation root;
- the build arguments, with any file or `-I` directory they name resolved and
  digested. The `-I` argument spelling is keyed exactly as written (`-I lib`
  and `-I ./lib` differ), while the named directory contents are walked and
  digested;
- the walked contents of every include root — every `*.mojo`, `*.🔥`, and
  `*.mojoc` an `-I` makes visible, recursing into every subdirectory an import
  can name (one with an `__init__`, or a namespace package whose name is an
  identifier), and nothing else, so a README or a lockfile changing under an
  include root does not evict anything;
- the walked contents of the directory the test file sits in, by those same
  rules — the compiler resolves a bare `from helper import ...` against the
  source file's own directory, with no `-I` involved, so a helper beside a test
  is a build input nothing else in this list covers;
- the test file itself.

Files enter the key by **content**, never by modification time, so a `touch` or
a `git checkout` that rewrites a file with the same bytes still hits. A file
that differs across a branch switch keeps the generations of both states once
it has been compiled in both: switching between exactly two states of a file
hits both ways from the second cycle on, when every writer of the store is at
this version and nothing else is publishing into it concurrently. A third state
evicts the lowest-ranked of the three, which without a concurrent publisher is
the oldest; concurrent runs take no lock, so a source can hold more than two for
a while, and a race can still cost one rebuild. A configured precompile output
that moves can move the complete key besides, so none of this is a promise that
every branch restoration hits. Settings that cannot change a compiled byte —
timeouts, workers, retries, selection, reporters — are not in the key and never
invalidate anything. The
invocation root is in the key, though, so moving or renaming the checkout
invalidates everything in it.

Build inputs must remain stable while a compiler invocation runs; mutation
during compilation is unsupported. Publication refuses to store a build whose
own inputs did not hold still: the test file, the files beside it, the
directories the walk covered, and both ends of a symlinked input are re-checked
against the filesystem identity and change times they had when they were keyed
— and the test file and its directory against their content as well. So an
input you edited and left edited is caught, and so is one you edited and *undid*
while the compiler was reading it, where both content samples agree and the
stored binary would have come from bytes that are no longer anywhere. Nothing is
published, a `cache-publish` warning names the input, the run itself stays
green, and the file is rebuilt next run. A configured precompile step is covered
the same way: its source, include roots, and the earlier steps' packages it
consumes are re-checked before it is stamped, and a step whose inputs moved is
left unstamped and runs again.

That covers a build's own inputs, not everything in its key: the toolchain, the
`-I` root contents, and files named by build arguments are sampled once per
session. Those, along with a mutate-and-restore finishing inside one filesystem
timestamp tick and a persistent mid-session edit that a later file in the same
directory hits, are stated in full in [the CLI
contract](cli-contract.md) under the cache's non-goals. If you edited
during a slow compile and changed your mind, `--no-cache` compiles from what is
on disk and `--cache-clear` discards what was stored.

The store pays for itself from about three test files upward. Its fixed
per-session cost — mostly digesting the compiler and the library directory
beside it — barely grows with the suite, so on a one- or two-file suite a warm
run can be slower than `--no-cache`, and from three files up it wins by more the
larger the suite gets. That is one machine with the compiler's own cache already
warm; CI compiles cold, which moves the crossover further in the cache's favour.

There is no import-graph analysis. One edit under an `-I` root invalidates every
file keyed over that root, and one edit beside a test file invalidates every test
in that directory; both over-rebuild on purpose, since the alternative is
guessing which files an edit reached and a wrong guess there is a stale binary.

The test files in that directory are the one thing left out of it. Each is an
entry point keyed on its own, so editing one leaves its neighbours cached and an
ordinary edit-and-rerun loop rebuilds one file rather than a directory. mtest
does not assume that is safe: it reads each file's imports, and a file that
imports a neighbouring test file — or one whose imports it cannot read — keys
over the whole directory like everything else.

Configured `precompile` steps are keyed separately, against their own sources
and include roots, so an unchanged step is skipped rather than re-run. A step
that does run rewrites its package, which moves the key every test file in the
session is built from — so skipping unchanged steps is also what lets the file
cache hit at all in a project that precompiles anything.

## When it turns itself off

Anything the key cannot fully characterize switches the cache off for the whole
session rather than risk a wrong hit. You get one `cache-off` warning naming the
first cause, and the run proceeds normally, compiling everything:

```console
$ pixi run bash -c 'build/mtest --build-arg --target-cpu --build-arg x86-64-v3 e2e/matrix'
mtest 1.2.0 (mojo)
root: /home/mikko/dev/mtest   selected: 2 files   excluded: 0

WARNING  cache-off: unrecognized build argument '--target-cpu'
PASS           e2e/matrix/test_alpha.mojo      0.02s
PASS           e2e/matrix/test_beta.mojo       0.02s

===== 5 passed, 0 failed, 0 skipped, builds: 2, cached: 0 (0 excluded, 0 not run) in 3.6s =====
```

The common causes are a build argument mtest's grammar does not recognize (as
above — an unknown flag might change what gets built in a way the key cannot
see), a `-Xlinker <flag>` the cache cannot characterize, a `mojo` that will not
resolve, and an include tree that cannot be walked: a file over the size cap, a
directory that cannot be listed, or a package directory hiding behind a symlink.
`collect` has no reporter to warn through and reports the same condition as a
`collect: cache-off: ...` line on stderr.

No cache condition ever fails a run that would otherwise pass, and none of them
changes a verdict.

## The two flags

`--no-cache` neither reads nor writes the store. Its gate sits ahead of any
staging, so the run creates no `build-v1/` and leaves no artifact a later run
could trust; it also emits no `cache-off` warning, because you asked for it.
(`.mtest-cache/` itself is still created, for the last-run state, and carries
the deletion-authorization marker like any other directory mtest makes.) This is how you get
a measurement with the store out of the picture:

```console
$ pixi run bash -c 'build/mtest --no-cache e2e/matrix'
mtest 1.2.0 (mojo)
root: /home/mikko/dev/mtest   selected: 2 files   excluded: 0

PASS           e2e/matrix/test_alpha.mojo      0.02s
PASS           e2e/matrix/test_beta.mojo       0.02s

===== 5 passed, 0 failed, 0 skipped, builds: 2, cached: 0 (0 excluded, 0 not run) in 0.8s =====
```

`--cache-clear` deletes `.mtest-cache` — the cached binaries and the last-run
state together — and *then* runs, so the session that clears the store also
repopulates it. Both flags are CLI-only and are never read from `mtest.toml`.

The two combine rather than conflict. `--cache-clear --no-cache` deletes the
store and then runs without repopulating it, which is how you get back to a
genuinely empty cache; `--cache-clear` alone leaves a fresh one behind.

That flag is also the only thing that shrinks the store. Publishing a binary
removes everything for *that* source beyond the two newest generations, so an
edit-and-rerun loop stays flat while an alternation between two states stays
warm — a target rather than a hard bound, since concurrent runs take no lock and
can leave a source over it until the next unraced publication. There is no size
cap and no expiry. Artifacts of tests you renamed or
deleted stay forever, and a build killed mid-compile — a timeout, a `Ctrl-C`,
a CI runner going away — leaves its half-staged directory behind. On a laptop
this is noise. On a CI checkout that lives for months it is worth clearing
periodically, or just `rm -rf .mtest-cache`: nothing in there cannot be rebuilt.

Deletion is guarded, because `.mtest-cache` is a path anything could be sitting
at. mtest writes a `CACHEDIR.TAG` marker whenever it creates that directory, and
`--cache-clear` refuses whatever the marker does not authorize it to delete — a symlink, a
directory with no marker, or a marker whose whole text does not match — as a pre-run usage
error, exit `4`, with the tree untouched:

```console
$ mtest --cache-clear tests
cache-clear: /tmp/demo/.mtest-cache: refusing to delete a symlink — only a real cache directory carrying mtest's exact deletion-authorization marker may be deleted, and following this link would delete whatever it points at; remove or repoint the link yourself, then rerun
$ echo $?
4
```

There is deliberately no "but its contents look like ours" override: that
heuristic is exactly how a directory somebody else created gets deleted. Nor is
the marker's presence enough — `CACHEDIR.TAG` is a shared convention that backup
tools and users write themselves, so mtest compares the whole file against the
text it writes. The diagnostic always hands over the manual `rm -rf`. mtest writes
the marker only into a `.mtest-cache/` it created itself — cache enabled or not,
since the directory is made for the last-run state either way — and never into
one it finds, nor over one that is already there. A directory that was already
there is therefore refused until you remove it yourself; a run that marked it
would be manufacturing the deletion authority this guard exists to ask for. Nothing under
`build/` is ever deleted.

Two outcomes are not refusals and are worth knowing about. A cache directory
mtest cannot characterize at all — a parent it may not search — is treated like
an absent one: nothing is deleted, no diagnostic is printed, and the run that
follows is simply cold. And once the guards pass, deletion can still fail
partway, on an unwritable entry or against another mtest writing into the store
at the same moment. That is the one case that leaves the tree changed; it exits
`4` and its diagnostic says the cache is now partial and hands you the `rm -rf`
to finish.

## The store is yours to throw away

```text
.mtest-cache/
├── CACHEDIR.TAG                                       # deletion-authorization marker
├── lastrun                                            # --lf/--ff state
└── build-v1/
    ├── e2e_smatrix_stest_ualpha_h8a5ff16933785.../
    │   ├── bin                                        # the cached binary
    │   ├── meta                                       # the key it was built for
    │   └── seq                                        # its place in the source's order
    └── e2e_smatrix_stest_ubeta_hfb59d7660a4b3.../
        ├── bin
        ├── meta
        └── seq
```

`CACHEDIR.TAG` carries the standard cachedir signature, so backup and archiving
tools that honor the convention skip the directory. The store is per-checkout,
is never shared between machines, is deliberately not persisted across CI runs,
and belongs in `.gitignore` — the same `.mtest-cache/` line that covers the
last-run state covers it. Deleting it by hand at any moment is safe; the next
run is simply cold.

A build compiles into a private staging directory beside its final home, and is
published with a single `rename(2)` once its bytes are on disk, so an
interrupted run never leaves a half-written entry for a later run to trust. Two
runs racing for one key is not an error either: the loser revalidates the
winner's entry and adopts it.

## It is never authoritative

Before a stored binary is run, the store re-checks that its directory is a real
directory and not a symlink, that its record parses, that the record names the
*whole* key and not just the half the directory name carries, and that the
binary on disk still digests to what the record says. A check that fails is a
miss, and the file is rebuilt; the entry is deleted too, unless it is something
the cache did not create — a symlink planted at a generation's path is refused
and left where it is, because deleting it would destroy evidence that something
else is writing into the store.

Those checks happen before the binary is executed, and a second mtest run over
the same checkout can replace or quarantine a generation in between. The same
race can reach a generation this run just published. A run that cannot execute
a stored binary compiles the file instead and says so with a `cache-rebuild`
warning, rather than failing a run whose only fault was the cache.

That is the shape of every decision here. A key that errs in the conservative
direction costs one rebuild, and no ordinary mistake — an edit, a toolchain
upgrade, an interrupted run, a store damaged from outside — costs a wrong
verdict. What that scope excludes is a hostile process running as you on your
machine: a compiler interposed through `LD_PRELOAD`, a helper swapped out
underneath a compile that is already running, a symlink raced into the path
`--cache-clear` is walking. Anyone who can do those can change your build far
more easily by editing it. [§8.5.1 of the command-line
contract](cli-contract.md#851-what-the-cache-does-not-defend-against)
states each boundary and why it is drawn there.
