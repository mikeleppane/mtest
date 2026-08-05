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
  against. It answers whether the gates listed in the next section still hold on
  the next stable Mojo release — not whether that release is safe to move to.
  The canary runs neither memory lane, no assertions companion, no cache or
  build-stamp gate, and nothing natively on macOS, so a green stable lane is a
  subset of the evidence a re-pin needs rather than the whole of it.
- **`nightly`** additionally considers Modular's nightly channel, so it sees
  prereleases. This is where a candidate normally appears first, well before the
  stable lane has anything to say about it.

Both lanes ask for a toolchain newer than the pin and below the next major. The
next major is a different question with a different answer and is out of scope
here.

## What a lane runs

A probe relaxes the toolchain pin in a throwaway checkout, installs whatever the
channels publish beyond it, and then runs these gates against the candidate in
this order, stopping at the first that condemns it.

1. **Build.** The runnable binary links.
2. **Tests.** The classified suite — unit and integration modules together —
   runs through that binary. The integration half is not optional here: it is
   the only place subprocess supervision, session scheduling and timeout
   handling are exercised, and those are exactly the behaviours a compiler
   change moves without touching a line of this repository's source.
3. **Command-line contract.** The strict contract checks execute against the
   candidate build, and their roll-call is read rather than merely waited on.
   **Three named checks fail on every candidate and are tolerated**, because
   `mtest doctor` compiles the pinned toolchain identity in and refuses any
   other compiler — correct product behaviour, and the reason the tolerance has
   to exist at all. It is drawn as narrowly as the gate's own reporting allows:
   the failing set must be exactly those three, check name and reported detail
   both. One extra failure condemns the candidate, so does a skip, so does a
   roll-call that does not account for the count printed above it — and so does
   a run in which those three checks *passed*, because a candidate the identity
   guard has stopped refusing is itself the finding.
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
   built binary. Failures are tolerated here on the same terms as in the
   contract gate, and for the same reason: the scenarios that assert which
   toolchain `mtest doctor` reports genuinely fail once the toolchain moves.
   Those two named scenarios are the whole tolerance. Any other failing scenario
   condemns the candidate, as does a failure that named no scenario at all, and
   as does a `doctor` scenario failing when the toolchain did *not* move.
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

Every probe ends in exactly one of eight classifications.

| Classification | What it says |
|----------------|--------------|
| `PASS` | Every gate above held on a toolchain newer than the pin. |
| `NO_NEWER_CANDIDATE` | Nothing newer is published on that lane's channels, so nothing was probed. |
| `PROTOCOL_DRIFT` | The `TestSuite` report format the runner parses moved. |
| `SOURCE_INCOMPATIBLE` | The repository as committed does not solve, compile, test, or behave on the candidate. |
| `PACKAGE_FAILED` | The sources are fine; the package built against the candidate is not. |
| `STAGE_TIMEOUT` | A probe stage outlived its 45-minute budget and was killed, so the day's question was never answered. |
| `CANARY_BROKEN` | The probe can no longer read or trust the answers it works from, so it has stopped probing. |
| `INFRA_FAILURE` | A command the probe needed never ran to completion, so it never obtained a toolchain to ask about. |

### `PASS`

Every gate that lane runs held on the candidate, **including the three
`contract-check-strict` failures every candidate produces**, which are tolerated
by name and reported in the result's detail. A `PASS` is therefore not a promise
that the strict contract gate was clean: re-pinning to this toolchain means
re-recording what `mtest doctor` reports, and until that happens the gate fails
in CI exactly as it failed here.

The result names the exact version and build commit it held on. Read it as one
day's evidence about one toolchain on one lane, and read the previous section
for which gates that lane actually ran: a nightly `PASS` says nothing about
packaging or macOS, because the nightly lane never asks, and neither lane's
`PASS` says anything about the memory, assertions, cache, build-stamp or native
macOS lanes, which the canary does not run at all.

### `NO_NEWER_CANDIDATE`

Nothing newer than the pin matched on that lane's channels, so no gate ran,
because there was no candidate to run one against.

This is a correct result, not a fault. The stable lane reports it on every run
for as long as the pinned toolchain is also the newest one published on the
stable channel, which is the situation while Mojo `1.0.0b2` is both the pin and
the newest stable release — so a stable lane sitting on `NO_NEWER_CANDIDATE`
means "the stable channel has not moved", and needs no investigation. The
nightly channel does publish prereleases beyond the pin, so the nightly lane is
the one that normally has a candidate to exercise.

### `PROTOCOL_DRIFT`

The regenerated transcripts differ from the committed baseline in something
other than the toolchain identity, or the generator failed its own structural
pins — the set of names it emits, and two generations agreeing byte for byte —
which are protocol assertions in their own right even though nothing was
compared. A generator that died for any other reason is not this: killed, it is
`STAGE_TIMEOUT`; otherwise it is `SOURCE_INCOMPATIBLE`, because a compiler that
rejects the syntax in a protocol fixture is the candidate refusing the sources
rather than the report format moving.

This is the finding that reaches a user most directly. mtest parses the report
`TestSuite` prints and refuses a report it does not fully understand rather than
guessing, so on a toolchain whose report format has moved the runner exits 3
instead of producing a false green. Moving the pin past a drifting toolchain
means re-capturing the snapshots and reading what changed first.

### `SOURCE_INCOMPATIBLE`

The candidate could not build the sources, could not run the suite, failed the
strict contract checks, failed the macOS cross-compile, or failed end-to-end
scenarios outside the tolerated `doctor` ones.

It also covers a candidate that never got as far as installing. A relaxed solve
that reached the index and could not produce an environment — because the
candidate's own dependencies cannot sit beside the `python`, `clang` and
platform set `pixi.toml` pins — says the repository as committed cannot adopt
that toolchain, which is the earliest and most total form of the same finding.

The evidence in the result differs by which of those routes produced it. Where a
compiler spoke, the result quotes its own first diagnostic verbatim: the build,
the suite, and the macOS cross-compile all report that way, and can be triaged
from the issue body without re-running anything. The contract, end-to-end and
unsatisfiable-solve routes have no single diagnostic to quote — the finding is a
roll-call read against what was expected, or a solve that failed while the
channels kept answering — so those results carry a sentence naming what was
compared and what did not hold.

### `PACKAGE_FAILED`

The sources compiled, tested, and behaved on the candidate, but the conda
package built and installed against it did not. Only the stable lane can report
this, because it is the only lane that packages.

### `STAGE_TIMEOUT`

A gate ran past the 45-minute budget the probe allows one stage and was killed.
Nothing is known about the candidate from a stage that never finished: three
quarters of an hour of silence on a compiler no cache has been warmed for is not
evidence that the sources stopped compiling, and reporting it as though it were
would put a red in front of a maintainer that cannot be triaged.

It is loud anyway. A lane whose probe cannot finish has stopped answering the
question it exists to answer, and a canary reporting the same quiet non-answer
every day for a month is the failure mode this workflow was built to prevent.

### `CANARY_BROKEN`

An answer came back and the probe could not read it, or could not believe it.
`pixi search --json` printed something that is not the shape this repository
parses; the channels answered without carrying the pinned toolchain at all, so
they are not the channels this repository resolves against; the installed
environment could not say which toolchain it holds; or the relaxed solve
produced a version the search never offered, so nothing the gates went on to
report would have been about the candidate that was screened.

This says nothing about any candidate, and it is loud anyway — louder, in a
sense, than a finding. Each of those conditions recurs on every run until a
person changes something, and reported quietly they would let the canary stop
probing while every scheduled run stayed green, which is the exact failure this
workflow exists to prevent.

### `INFRA_FAILURE`

A command the probe depends on never ran to completion, so it never got as far
as having a toolchain to ask about: a channel search that failed outright, or an
install that failed twice while the control question could no longer be answered
either. It is transient by construction — nothing but a command that failed to
run produces it — which is why it is the one finding that writes an issue and
still leaves the run green.

Two neighbours are deliberately **not** this. An answer that came back unreadable
is `CANARY_BROKEN`, because it does not clear on its own. An install that failed
while the channels still answer is `SOURCE_INCOMPATIBLE`, because that is the
candidate refusing to coexist with this repository's pinned environment.

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
`SOURCE_INCOMPATIBLE`, `PACKAGE_FAILED`, `STAGE_TIMEOUT`, or `CANARY_BROKEN`, and
also when a lane that was supposed to report produced no readable result —
silence is the failure mode a canary exists to make impossible. `INFRA_FAILURE`
is the one row where the issue and the exit code come apart: it writes the lane's
issue like any other finding and still leaves the run green, because it is
produced solely by a command that failed to run and says nothing about the
candidate, while a scheduled job that reddened every time a network call flaked
would teach everyone to ignore it. It is written down rather than passed over
because an unreachable channel is unreachable again tomorrow, and a lane nobody
had opened an issue for could otherwise report a green non-answer every weekday
forever.

Maintainers can also dispatch the workflow by hand and pick a single lane
through its `channel` input. There is nothing here to run against a working
checkout: the probe rewrites tracked files to point them at a candidate, and it
refuses to do that outside a hosted run.
