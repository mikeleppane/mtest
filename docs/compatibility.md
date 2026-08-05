# Toolchain compatibility

This repository pins one Mojo toolchain exactly. Every release is built, gated,
and published against that pin alone, and the
[Supported toolchains table in the README](https://github.com/mikeleppane/mtest#supported-toolchains)
is the only statement of support this project makes.

This page describes something separate: the **compatibility canary**, a
scheduled workflow (`.github/workflows/compat-canary.yml`) that asks the
opposite question every other gate asks. The rest of continuous integration
asks whether mtest works on the pinned toolchain. The canary asks what *would*
break if the pin moved, so the answer is already known when Modular publishes
something new instead of being discovered during a re-pin.

## What a canary result is not

A green canary is **not** a statement that mtest works on the toolchain it
probed. It is evidence maintainers use when evaluating a toolchain update, and
nothing else. The toolchain mtest supports changes only in a released version of
mtest: the manifest pin, the compiler the conda package declares as its run
dependency, and the support table move together, in a release, deliberately.
Until that happens a green lane is an observation about a compiler nothing has
shipped against.

A red canary is a maintainer signal in the same way. It says a toolchain that is
not the one mtest is built against would break something. It is not a defect in
any released mtest, and it does not affect an installation, because every
published package declares the pinned compiler as its run dependency and
therefore resolves it.

## The two lanes

The canary runs on weekdays at 01:41 UTC and probes two lanes. Neither lane's
result is evidence about the other, and a lane that fails does not stop the
other from reporting.

- **`stable`** considers only the channels the workspace itself resolves
  against. It answers whether the next stable Mojo release is safe to move to.
- **`nightly`** additionally considers Modular's nightly channel, so it sees
  prereleases. This is where a candidate normally appears first, well before the
  stable lane has anything to say about it.

Both lanes ask for a toolchain newer than the pin and below the next major. The
next major is a different question with a different answer and is out of scope
here.

## What a lane runs

A probe relaxes the toolchain pin in a throwaway checkout, installs whatever the
channels publish beyond it, and then runs these gates against the candidate in
this order, stopping at the first that fails.

1. **Build.** The runnable binary links.
2. **Tests.** The classified suite — unit and integration modules together —
   runs through that binary. The integration half is not optional here: it is
   the only place subprocess supervision, session scheduling and timeout
   handling are exercised, and those are exactly the behaviours a compiler
   change moves without touching a line of this repository's source.
3. **Command-line contract.** The strict contract checks execute against the
   candidate build.
4. **Protocol transcripts.** The `TestSuite` report snapshots are regenerated
   into a temporary directory and compared with the committed baseline. Exactly
   one difference is tolerated — the toolchain identity stamped into each
   transcript's header — and the committed snapshots are never overwritten,
   because they are the pinned toolchain's testimony and the only thing a
   candidate can be compared against.
5. **macOS cross-compile.** *Stable lane only.* The sources are compiled for
   `arm64-apple-macosx` as far as assembly, which catches a Darwin-only break
   from a Linux runner without a Mac.
6. **End-to-end suite.** The committed known-outcome tree is driven through the
   built binary. Failures are tolerated in exactly one place: the scenarios that
   assert which toolchain `mtest doctor` reports, which genuinely fail once the
   toolchain moves. Any other failing scenario condemns the candidate, as does a
   failure that named no scenario at all, and as does a `doctor` scenario
   failing when the toolchain did *not* move.
7. **Packaging.** *Stable lane only.* The conda recipe's three compiler pins are
   retargeted at the candidate, the package is built, and it is installed into a
   scratch environment and run, with the candidate's version asserted as the
   compiler the install actually consumed. It runs last on purpose: its finding
   says the sources are fine and the package is not, and that is only something
   a run can say once every source gate above it has answered.

**The nightly lane runs the source legs only** — steps 1 to 4 and step 6. It
never packages and never cross-compiles. A prerelease compiler is not something
this project would ship a package against, so those two legs belong to the
stable lane alone.

## What a result means

Every probe ends in exactly one of six classifications.

| Classification | What it says |
|----------------|--------------|
| `PASS` | Every gate above held on a toolchain newer than the pin. |
| `NO_NEWER_CANDIDATE` | Nothing newer is published on that lane's channels, so nothing was probed. |
| `PROTOCOL_DRIFT` | The `TestSuite` report format the runner parses moved. |
| `SOURCE_INCOMPATIBLE` | The sources no longer compile, test, or behave. |
| `PACKAGE_FAILED` | The sources are fine; the package built against the candidate is not. |
| `INFRA_FAILURE` | The probe never obtained a toolchain to ask about. |

### `PASS`

Every gate that lane runs held on the candidate, and the result names the exact
version and build commit it held on. Read it as one day's evidence about one
toolchain on one lane, and read the previous section for which gates that lane
actually ran: a nightly `PASS` says nothing about packaging or macOS, because
the nightly lane never asks.

### `NO_NEWER_CANDIDATE`

Nothing newer than the pin matched on that lane's channels, or the solve for a
newer one still landed on the pinned toolchain. Either way no gate ran, because
there was no candidate to run one against.

This is a correct result, not a fault. The stable lane reports it on every run
for as long as the pinned toolchain is also the newest one published on the
stable channel, which is the situation while Mojo `1.0.0b2` is both the pin and
the newest stable release — so a stable lane sitting on `NO_NEWER_CANDIDATE`
means "the stable channel has not moved", and needs no investigation. The
nightly channel does publish prereleases beyond the pin, so the nightly lane is
the one that normally has a candidate to exercise.

### `PROTOCOL_DRIFT`

The regenerated transcripts differ from the committed baseline in something
other than the toolchain identity, or the generator could not complete at all.

This is the finding that reaches a user most directly. mtest parses the report
`TestSuite` prints and refuses a report it does not fully understand rather than
guessing, so on a toolchain whose report format has moved the runner exits 3
instead of producing a false green. Moving the pin past a drifting toolchain
means re-capturing the snapshots and reading what changed first.

### `SOURCE_INCOMPATIBLE`

The candidate could not build the sources, could not run the suite, failed the
strict contract checks, failed the macOS cross-compile, or failed end-to-end
scenarios outside the tolerated `doctor` ones. The result quotes the compiler's
own first diagnostic verbatim rather than paraphrasing it, so the finding can be
triaged from the issue body without re-running anything.

### `PACKAGE_FAILED`

The sources compiled, tested, and behaved on the candidate, but the conda
package built and installed against it did not. Only the stable lane can report
this, because it is the only lane that packages.

### `INFRA_FAILURE`

The probe never got as far as having a toolchain to ask about: a channel was
unreachable, a search answered with something unreadable, or the install failed
twice in a row. This says nothing whatever about the candidate. It is news about
the canary.

## Where the results are

**One pinned issue per lane, from that lane's first finding onwards**, titled
`canary: stable` and `canary: nightly`. A lane that has never had anything to
report has no issue at all: the canary opens one the first time that lane finds
something, and from then on it is that lane's issue forever. The title is the
lane and never the weather, so each lane keeps one issue a maintainer can watch,
mute, or close; the body is rewritten in place on every run with a finding. A
lane that goes quiet — `PASS` or `NO_NEWER_CANDIDATE` — closes its issue with
the result as the closing comment, and the next finding reopens that same issue
rather than starting the story over in a new one. A quiet lane whose issue is
already closed is left exactly as it is, so a run with nothing to say says
nothing.

**One artifact per lane per run**, named `canary-result-<lane>`, holding the
machine-readable `result.json` and a rendered `summary.md`. If the probe crashed
instead of classifying, the artifact holds `diagnostics.txt` with the traceback
and no result at all.

The workflow run goes red when any lane reports `PROTOCOL_DRIFT`,
`SOURCE_INCOMPATIBLE`, or `PACKAGE_FAILED`, and also when a lane that was
supposed to report produced no readable result — silence is the failure mode a
canary exists to make impossible. `INFRA_FAILURE` is deliberately quiet: it
comments on an issue that is already open and otherwise leaves the run green,
because a scheduled job that opened an issue every time a network call flaked
would teach everyone to close its issues unread, including the one that had
something real to say.

Maintainers can also dispatch the workflow by hand and pick a single lane
through its `channel` input. There is nothing here to run against a working
checkout: the probe rewrites tracked files to point them at a candidate, and it
refuses to do that outside a hosted run.
