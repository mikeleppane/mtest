#!/usr/bin/env python3
"""Probe a candidate Mojo toolchain and reduce the outcome to one name.

This repository pins its compiler exactly, and that pin is load-bearing: the
protocol snapshots are stamped with it, the package declares it as a run
dependency, and the syntax the sources use is whatever that release accepts. So
the interesting question is never "did today's run pass" but "if the pin moved,
what exactly would break". This module answers that with a classification:

| Classification        | What the day's evidence showed                     |
|-----------------------|----------------------------------------------------|
| `PASS`                | Every gate held on a newer toolchain.              |
| `NO_NEWER_CANDIDATE`  | Nothing newer exists; there was nothing to probe.  |
| `PROTOCOL_DRIFT`      | The runner's observable output moved.              |
| `SOURCE_INCOMPATIBLE` | The tree cannot solve, compile, test, or behave.  |
| `PACKAGE_FAILED`      | The sources are fine; the shipped package is not.  |
| `STAGE_TIMEOUT`       | A stage outlived its budget and answered nothing.  |
| `CANARY_BROKEN`       | The probe cannot read or trust the answers it got. |
| `INFRA_FAILURE`       | The probe could not reach the outside world.       |

The classification is DATA, not a verdict, which is why this exits 0 for every
one of them including the red ones. Whether `PROTOCOL_DRIFT` should wake anyone
is a policy question owned by the notifier; a probe that exited nonzero on it
would conflate "the toolchain moved" with "the canary broke", and the second is
the only thing an exit code here can usefully mean. A nonzero exit therefore
says exactly one thing: this module crashed, and the traceback it left behind is
about itself rather than about Mojo.

Only one row is quiet, and the line around it is where this module has been
wrong three times. `INFRA_FAILURE` means the probe could not reach the outside
world, and it is transient by construction: nothing produces it but a command
that failed to run to completion.

It does NOT mean "the environment would not build", because a candidate whose
dependencies cannot sit beside the python, clang and platform set this
repository pins is a fact about that candidate, discovered exactly where this
lane is meant to discover things. And it does NOT mean "an answer came back and
could not be read". pixi changing the shape of `search --json`, a channel set
that no longer carries the version this repository is built against, a solve
that produced a toolchain the search never offered — those are permanent, they
recur every weekday until a person changes something, and reported quietly they
let the probe stop probing while every scheduled run stayed green. They are
`CANARY_BROKEN`, which is loud, because what broke is this module's own grip on
the world rather than any candidate's behaviour, and because "the same quiet
non-answer every day for a month" is the failure mode this whole workflow was
built to prevent.

Every failure the probe cannot attribute to its own plumbing therefore lands on
a loud row, the ones it can are named one at a time with the evidence that
named them, and the only row that stays silent about a candidate is the one
that cannot outlive the outage that produced it.

The ordering of the stages is not cosmetic. "Is there anything newer" is asked
of the channels FIRST, as a question, before a single tracked file is touched:
the relaxed spec can be unsatisfiable — it is on the stable channel today,
where the pinned version is also the newest published — and a probe that only
discovered that by watching the install fail would report a candidate finding
forever while a lane that is simply idle looks broken. Asking first also means
an idle day leaves the checkout unmodified.

The pin is then relaxed before anything is installed, because installing under
the committed spec resolves the pinned version — which the bounded search never
offered, so every day would end on `CANARY_BROKEN` with no candidate ever
probed. The recipe is retargeted before the packaging leg for the same reason,
so that its build is evidence about the candidate rather than about the pin.
And the cheap, specific failures are asked before the expensive ones, so a
toolchain that simply does not compile the sources is named that way rather
than by whichever long gate happened to notice.

Packaging is asked last, after every source leg, because `PACKAGE_FAILED`
claims the sources are fine. Asked earlier it can be reported by a run that
never tested that claim: a candidate that broke Darwin compilation and the
end-to-end suite as well would be filed as a packaging finding, and the
premise the name rests on would have gone unexamined.
"""

from __future__ import annotations

import argparse
import contextlib
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from typing import TYPE_CHECKING

from scripts.canary.protocol_compare import (
    PASS,
    PROTOCOL_DRIFT,
    CompareResult,
    compare_transcript_dirs,
)
from scripts.canary.toolchain import (
    FORCE_ENV_VALUE,
    FORCE_ENV_VAR,
    LANES,
    RESOLVE_ARGV,
    STABLE_LANE,
    TOLERATED_CONTRACT_FAILURES,
    TOLERATED_E2E_SCENARIOS,
    ResolvedToolchain,
    ToolchainError,
    candidate_channels,
    candidate_matchspec,
    floor_matchspec,
    parse_toolchain,
    pin_recipe_to_candidate,
    relax_workspace_pin,
    workspace_pin,
)


if TYPE_CHECKING:
    from collections.abc import Callable, Sequence


REPO_ROOT = Path(__file__).resolve().parents[2]

# `PASS` and `PROTOCOL_DRIFT` are the comparator's own names, imported rather
# than restated so the two modules cannot drift into two vocabularies.
NO_NEWER_CANDIDATE = "NO_NEWER_CANDIDATE"
SOURCE_INCOMPATIBLE = "SOURCE_INCOMPATIBLE"
PACKAGE_FAILED = "PACKAGE_FAILED"
STAGE_TIMEOUT = "STAGE_TIMEOUT"
CANARY_BROKEN = "CANARY_BROKEN"
INFRA_FAILURE = "INFRA_FAILURE"

CLASSIFICATIONS = (
    PASS,
    NO_NEWER_CANDIDATE,
    PROTOCOL_DRIFT,
    SOURCE_INCOMPATIBLE,
    PACKAGE_FAILED,
    STAGE_TIMEOUT,
    CANARY_BROKEN,
    INFRA_FAILURE,
)

# The gates run against the candidate, cheapest and most specific first. The
# suite is the whole classified one, unit and integration together, because the
# breaks this lane exists to find are not all in the unit modules: subprocess
# supervision, session scheduling and timeout handling are exercised by the
# integration modules alone, and they are exactly the surface a compiler change
# moves. The integration half costs on the order of a minute of wall time
# beside a cold-cache build measured in tens, so the budget is not what decides
# this.
SOURCE_TASKS = ("build-bin", "test")

# The strict black-box gate, run after those two and read rather than merely
# waited on: it is the one source gate a moved toolchain is *expected* to fail,
# because `mtest doctor` refuses any compiler but the pinned one.
CONTRACT_TASK = "contract-check-strict"

# The macOS frontend probe. No pixi task owns this: the hosted macOS lane
# compiles natively and owns that verdict for ordinary changes, so this
# cross-compile exists only here, where the Linux runner must still learn
# whether a candidate broke a Darwin `comptime` branch, `external_call`
# signature, or hand-computed struct offset. `--emit=asm` stops before linking,
# so no Darwin SDK and no native object are needed. Documented in AGENTS.md.
MACOS_CROSS_COMPILE = (
    "pixi",
    "run",
    "mojo",
    "build",
    "--target-triple",
    "arm64-apple-macosx14.0.0",
    "--emit=asm",
    "-I",
    "src",
    "-I",
    "vendor/mojo-toml",
    "src/main.mojo",
    "-o",
    "/dev/null",
)

# No stage may hold the probe forever: a wedged gate is killed and reported as
# `STAGE_TIMEOUT` rather than left to run into a scheduled job that never says
# anything. Reporting it needs room to spare inside the hosting job — the probe
# job in `.github/workflows/compat-canary.yml` is cancelled at
# `timeout-minutes: 60`, and a stage budget equal to it would be reached at the
# exact moment the job dies — so the headroom is what the classification is
# written and uploaded in. A test reads both numbers from their sources and
# refuses to let them close up again.
#
# The headroom buys the report only for a stage that wedges early: the budget
# runs from when the STAGE started, so a gate that hangs after half an hour of
# cold-cache building is killed past the job's own deadline and the day ends
# with a cancelled job and no artifact. That degrades loudly — the notifier
# treats a lane that reported nothing as a failure — which is why this is a
# budget rather than a mechanism.
STAGE_TIMEOUT_SECONDS = 2700.0
JOB_TIMEOUT_HEADROOM_SECONDS = 900.0

# How long to wait before repeating a failed `pixi install`. The retry exists
# for transient network faults, and one issued microseconds later meets the
# same outage — which is to say it bought nothing at all. Long enough for a
# rate limit or a half-published index to clear, short enough that two solves
# and this still sit inside the stage budget.
INSTALL_RETRY_BACKOFF_SECONDS = 30.0

# What `subprocess_runner` reports for a stage it killed. The value is the
# shell's own convention for "terminated by `timeout`", chosen so a reader who
# sees it in an artifact recognises it.
TIMEOUT_RETURNCODE = 124

# Compiler diagnostics, in the shape Mojo emits them. The first one is what a
# reader needs; everything after it is usually cascade.
_DIAGNOSTIC = re.compile(r"^.*?: error: .*$", re.MULTILINE)

# The e2e gate's failure roll-call, printed once per failing scenario.
_E2E_FAILURE = re.compile(r"^FAILED: (\S+)$", re.MULTILINE)

# How `scripts.gen_transcripts` says that one of its own structural pins broke,
# as opposed to something underneath it. It catches `GenError`, prints this
# marker, and leaves on this code; every other way of failing is something the
# generator did not anticipate. A test pins both against that module, because a
# generator that changed how it reports would quietly widen the reading below.
GENERATOR_PIN_EXIT = 2
GENERATOR_PIN_MARKER = "STRUCTURAL PIN FAILED"

# How the strict contract gate accounts for itself: one summary line, then one
# roll-call entry per failing check naming the check, its contract reference,
# and the first line of its detail. Both are pinned against `scripts.qa.contract`
# by a test, because a gate that changed how it reports would leave the reader
# below finding nothing and the probe condemning every candidate.
_CONTRACT_SUMMARY = re.compile(
    r"^===== (?P<passed>\d+) passed, (?P<failed>\d+) failed, "
    r"(?P<skipped>\d+) skipped =====$",
    re.MULTILINE,
)
_CONTRACT_FAILURE = re.compile(
    r"^  - (?P<name>.+?)  \((?P<ref>.+?)\): (?P<detail>.*)$", re.MULTILINE
)

# Stands in for a toolchain identity the probe never got to observe.
UNKNOWN = "unknown"
_UNKNOWN = ResolvedToolchain(UNKNOWN, UNKNOWN)


@dataclass(frozen=True)
class CommandResult:
    """What one probe command did.

    Attributes:
        argv: The command as it was spawned.
        returncode: Its exit status, or 124 when it was killed for running past
            the stage timeout.
        stdout: Captured standard output.
        stderr: Captured standard error.
    """

    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class CanaryResult:
    """One day's finding about one toolchain lane.

    Attributes:
        lane: `stable` or `nightly`.
        version: The candidate's version, or `unknown` if none was resolved.
        commit: The candidate's build commit, on the same terms.
        classification: One of `CLASSIFICATIONS`.
        detail: The specific evidence — a compiler diagnostic, a transcript
            diff, or the command that failed.
    """

    lane: str
    version: str
    commit: str
    classification: str
    detail: str


if TYPE_CHECKING:
    # The probe's whole seam onto the outside world: one callable that spawns a
    # command. Everything the pipeline learns, including which toolchain the
    # install produced, arrives through it, so there is one place where the
    # stage budget, the process-group kill and the checkout binding are applied
    # and no call that quietly sits outside all three.
    Runner = Callable[[Sequence[str]], CommandResult]


def timed_out(result: CommandResult) -> bool:
    """Report whether the probe killed this command for outliving its budget.

    A killed stage produced no evidence, so every reading of its output has to
    be skipped rather than merely distrusted, and the exit status is the only
    place that shows. Asked through a name instead of compared against 124 at
    each site, because the two readings are opposites — 124 from a stage means
    "this said nothing", and every other nonzero means "this said no".

    Args:
        result: A completed probe command.

    Returns:
        True when the runner stopped the command at `STAGE_TIMEOUT_SECONDS`.
    """
    return result.returncode == TIMEOUT_RETURNCODE


def kill_process_group(process: subprocess.Popen[str]) -> None:
    """Kill everything a timed-out stage spawned, and reap what is left of it.

    Killing the direct child is the wrong unit here. Every stage is a pixi
    task, which is to say a launcher for a compiler, a test runner or a package
    build, and those outlive their launcher happily. Left running they keep
    writing to the same caches, prefixes and build directories as the stages
    that follow — inside a probe that has already given up on them and reported
    `STAGE_TIMEOUT` — so what gets signalled is the process group the stage was
    started in.

    The group is named by the stage's own pid rather than looked up. With
    `start_new_session=True` the stage IS the leader of a new group, so its pid
    is that group's id by construction — and it is the only name for the group
    that survives the case this function is reached in. A pixi task can finish
    while the compiler it started keeps the capture pipes open, so
    `communicate` blocks on the pipes past the budget with the launcher already
    exited; asked about a process that has since been reaped, `os.getpgid`
    raises `ProcessLookupError`, which was suppressed here, and the group still
    holding the compiler was never signalled at all.

    The pipes are closed rather than read to end-of-file. Anything that escaped
    the group by starting a session of its own still holds their write ends,
    and a reader waiting on that would hold the job open exactly as the stage
    it replaced did.

    Args:
        process: The stage, started with `start_new_session=True` so that its
            process group holds it and its descendants and nothing else.
    """
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(process.pid, signal.SIGKILL)
    with contextlib.suppress(ProcessLookupError):
        process.kill()
    # Safe to wait on: the direct child was sent an uncatchable signal, so this
    # reaps a process that is already gone rather than waiting for one to stop.
    process.wait()
    for stream in (process.stdout, process.stderr):
        if stream is not None:
            stream.close()


def subprocess_runner(repo: Path) -> Runner:
    """Build the runner that really spawns probe commands.

    Every probe command is captured rather than streamed, because its output is
    the detail a classification carries and has to survive into the artifact.

    Each one is started in a session of its own, so that the budget below can
    be enforced against everything the stage spawned rather than against the
    one process this module can see. `kill_process_group` says what goes wrong
    without that.

    Args:
        repo: The checkout every command runs in.

    Returns:
        A callable taking an argv and returning its `CommandResult`.
    """

    def run(argv: Sequence[str]) -> CommandResult:
        recorded = tuple(argv)
        print(f"canary: $ {shlex.join(recorded)}", flush=True)
        process = subprocess.Popen(
            recorded,
            cwd=repo,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=STAGE_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            kill_process_group(process)
            # The partial output a killed child left behind is not worth
            # decoding: what a reader needs is that this stage never finished.
            return CommandResult(
                recorded,
                TIMEOUT_RETURNCODE,
                "",
                f"timed out after {STAGE_TIMEOUT_SECONDS:.0f}s",
            )
        return CommandResult(recorded, process.returncode, stdout, stderr)

    return run


def _last_meaningful_line(stream: str) -> str:
    """Return the last non-blank line of a captured stream, or the empty string."""
    lines = [line.strip() for line in stream.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def command_failure(result: CommandResult) -> str:
    """Describe a failed command in one line.

    Args:
        result: The failed command.

    Returns:
        The command, its exit status, and the last thing it said.
    """
    tail = _last_meaningful_line(result.stderr) or _last_meaningful_line(result.stdout)
    described = f"`{shlex.join(result.argv)}` exited {result.returncode}"
    return f"{described}: {tail}" if tail else described


def first_diagnostic(result: CommandResult) -> str:
    """Quote the compiler's own first complaint about a failed build.

    A classification that says only "the build failed" cannot be triaged, and a
    paraphrase of a compiler error is worse than the error. Everything after
    the first diagnostic is normally cascade from it.

    Args:
        result: The failed command.

    Returns:
        The first `... error: ...` line, verbatim, or a description of the
        failed command when it produced no diagnostic at all.
    """
    for stream in (result.stderr, result.stdout):
        match = _DIAGNOSTIC.search(stream)
        if match is not None:
            return match.group(0).rstrip("\r")
    return command_failure(result)


def search_argv(channels: Sequence[str], matchspec: str) -> tuple[str, ...]:
    """Build the command that asks a set of channels what they publish.

    No `--platform` is passed, so pixi answers for every platform the manifest
    declares. This is a screen rather than a solve: its question is whether
    anything newer has been published at all, and the install that follows
    remains the authority on whether it is installable on this runner.

    Args:
        channels: The channels to consider, in preference order.
        matchspec: A conda matchspec, for example `mojo >1.0.0b2,<2`.

    Returns:
        The `pixi search` argv.
    """
    argv = ["pixi", "search", "--json"]
    for channel in channels:
        argv.extend(["-c", channel])
    argv.append(matchspec)
    return tuple(argv)


def _search_subdirs(result: CommandResult) -> tuple[tuple[str, ...], ...]:
    """Read one `pixi search --json` answer into one version list per subdir.

    Args:
        result: A completed, successful search.

    Returns:
        Each subdir's versions, in the order pixi listed them.

    Raises:
        ValueError: The output is not the subdir-keyed object pixi documents,
            which means this reader and that tool have drifted apart.
    """
    described = shlex.join(result.argv)
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError(f"`{described}` did not print JSON: {error}") from error
    if not isinstance(payload, dict):
        raise ValueError(
            f"`{described}` printed {type(payload).__name__}, not an object"
        )

    subdirs: list[tuple[str, ...]] = []
    for records in payload.values():
        if not isinstance(records, list):
            raise ValueError(f"`{described}` printed a non-list of package records")
        versions: list[str] = []
        for record in records:
            version = record.get("version") if isinstance(record, dict) else None
            if not isinstance(version, str):
                raise ValueError(f"`{described}` printed a record with no version")
            versions.append(version)
        subdirs.append(tuple(versions))
    return tuple(subdirs)


def search_versions(result: CommandResult) -> tuple[str, ...]:
    """Read every version out of one `pixi search --json` answer.

    The probe searches without `--platform`, so pixi answers for each subdir
    the manifest declares and this flattens them. The result is emphatically
    NOT ordered newest first: pixi orders the records *within* one subdir, so
    the head here is the newest of whichever subdir came first, and a version
    published for only the second subdir lands behind older versions of the
    first. Callers ask this for membership; `search_newest` is what names a
    newest anything.

    Args:
        result: A completed, successful search.

    Returns:
        The distinct versions offered, in the order the answer listed them,
        deduplicated with the first occurrence winning.

    Raises:
        ValueError: The output is not the subdir-keyed object pixi documents.
    """
    versions: list[str] = []
    for subdir in _search_subdirs(result):
        for version in subdir:
            if version not in versions:
                versions.append(version)
    return tuple(versions)


def search_newest(result: CommandResult) -> tuple[str, ...]:
    """Name the newest version each subdir offers.

    Within one subdir pixi lists records newest first in conda's own version
    ordering, and that is the only ordering claim this module can make
    honestly. Comparing across subdirs would mean implementing that ordering
    here, which is exactly what must not happen: `1.0.0rc0` outranks
    `1.0.0b3.dev2026080406`, and every naive lexical or dotted-numeric
    comparison gets it backwards.

    Args:
        result: A completed, successful search.

    Returns:
        The distinct per-subdir newest versions, in the order the answer listed
        the subdirs. Usually one value, and two only when the platforms this
        repository supports have genuinely diverged.

    Raises:
        ValueError: The output is not the subdir-keyed object pixi documents.
    """
    newest: list[str] = []
    for subdir in _search_subdirs(result):
        if subdir and subdir[0] not in newest:
            newest.append(subdir[0])
    return tuple(newest)


def control_confirms_channels(control: CommandResult, pin: str) -> bool:
    """Decide whether a control search proved the channels can be questioned.

    The bar is deliberately higher than "it exited 0": the control has to come
    back naming the pinned version. An answer that parses but does not carry
    the version this repository is built against is not evidence that the
    channels hold nothing newer — it is evidence that they are not the channels
    this probe thinks it is asking.

    A control the probe killed must never reach this. It answers False, which
    reads as "the channels could not be questioned" and is right about the
    channels but wrong about the day: the stage said nothing because it was
    stopped, and `timed_out` is what callers ask first.

    Args:
        control: The completed control search.
        pin: The pinned version the control admits.

    Returns:
        True when the control succeeded, parsed, and named the pin.
    """
    if control.returncode != 0:
        return False
    try:
        return pin in search_versions(control)
    except ValueError:
        return False


def uncorroborated_classification(control: CommandResult) -> str:
    """Name what a control that did not confirm the channels leaves to report.

    There are two ways for the corroboration to come back unconfirmed and they
    are opposites. The control can have failed to run — which is an outage,
    says nothing about anything, and clears when the outage does. Or it can
    have run, answered, and not named the version this repository is built
    against, which is a channel set that is not the one this probe thinks it is
    asking; that condition does not clear, it recurs every weekday, and quiet
    it would let the lane report a green non-answer indefinitely.

    Args:
        control: The completed control search, which did not confirm.

    Returns:
        `INFRA_FAILURE` when the control never answered, `CANARY_BROKEN` when
        it answered with something this probe cannot build on.
    """
    return INFRA_FAILURE if control.returncode != 0 else CANARY_BROKEN


def failed_scenarios(stdout: str) -> tuple[str, ...]:
    """List the e2e scenarios a failing roster named.

    Args:
        stdout: The e2e gate's captured output.

    Returns:
        The scenario ids, in the order the gate reported them.
    """
    return tuple(_E2E_FAILURE.findall(stdout))


def e2e_failure_verdict(failed: Sequence[str], *, toolchain_moved: bool) -> str | None:
    """Decide whether a set of e2e failures condemns the candidate toolchain.

    `mtest doctor` refuses any toolchain but the one it was built against, so
    the scenarios that require it to report a healthy one genuinely fail as
    soon as the toolchain moves. That tolerance is narrow on purpose, because
    "some failures are expected" degrades into "failures are ignored" the
    moment it stops being checked: the tolerated scenarios are named one by one
    in `TOLERATED_E2E_SCENARIOS`, any other failing scenario condemns, and so
    does a failure that named no scenario at all, which means the roll-call
    this reads has changed shape and the guard has stopped guarding.

    `toolchain_moved` is a **precondition, not a live guard**. `classify` can
    only reach this with a toolchain that differs from the pin, because a solve
    that produced the pin is not in the searched candidate set and stopped the
    pipeline several stages earlier, so the False branch is unreachable from
    the pipeline as it stands today and is covered by this module's tests
    alone. It is kept because the tolerance is
    the dangerous part of this function and this is where it is stated: a
    future caller that reaches the roster by some other route inherits the
    refusal rather than the tolerance, and gets a named reason instead of a
    silent pass.

    Args:
        failed: The scenario ids that failed.
        toolchain_moved: Whether the resolved toolchain differs from the pin.

    Returns:
        The reason these failures condemn the toolchain, or None when they are
        exactly the expected toolchain-reporting drift.
    """
    unexpected = tuple(name for name in failed if name not in TOLERATED_E2E_SCENARIOS)
    if unexpected:
        return (
            "e2e scenarios failed outside the toolchain-reporting surface: "
            f"{', '.join(unexpected)}"
        )
    if not failed:
        return (
            "the e2e gate failed without naming a scenario, so no failure could "
            "be attributed to the toolchain report"
        )
    if not toolchain_moved:
        return (
            "e2e toolchain-reporting scenarios failed against the pinned "
            f"toolchain: {', '.join(failed)}"
        )
    return None


def generator_failure(result: CommandResult) -> CompareResult:
    """Name what a transcript generation that never finished actually showed.

    Reading every nonzero exit as drift claimed the report format had moved
    without a byte having been compared, which is a red nobody can act on and
    an over-claim besides. The generator says which of its two very different
    failures happened: it catches its own `GenError` and leaves on
    `GENERATOR_PIN_EXIT` with `GENERATOR_PIN_MARKER`, and that IS drift even
    though nothing was compared, because the pins it failed — the emitted name
    set, and two generations agreeing byte for byte — are protocol assertions
    in their own right.

    Anything else is not. A compiler that rejects the syntax in a protocol
    fixture stops the generator before it produces anything to compare, and
    that is the candidate refusing the sources. So is a generator that dies for
    a reason this cannot attribute: it runs green on the pinned toolchain every
    day, so its death on the candidate is evidence about the candidate until
    someone shows otherwise. That admits an occasional wrong red — a full disk
    would land here too — and it is the right way round, because the wrong red
    carries the failure's own last line and is corrected the day it is read.

    Args:
        result: The failed generation.

    Returns:
        The classification and the evidence for it.
    """
    if timed_out(result):
        return CompareResult(STAGE_TIMEOUT, command_failure(result))
    if (
        result.returncode == GENERATOR_PIN_EXIT
        and GENERATOR_PIN_MARKER in result.stderr
    ):
        return CompareResult(PROTOCOL_DRIFT, command_failure(result))
    return CompareResult(SOURCE_INCOMPATIBLE, first_diagnostic(result))


@dataclass(frozen=True)
class ContractReport:
    """What one strict contract run said about its own roster.

    Attributes:
        failed: How many checks its summary line counted as failed.
        skipped: How many it counted as skipped. Under `--strict` a skip fails
            the gate without ever reaching the roll-call, so this count is the
            only place one is visible.
        failures: Each named failure, as the check's name and the first line of
            its detail.
    """

    failed: int
    skipped: int
    failures: tuple[tuple[str, str], ...]


def read_contract_report(stdout: str) -> ContractReport | None:
    """Read the roster a strict contract run printed about itself.

    Args:
        stdout: The gate's captured output.

    Returns:
        The report, or None when the output holds no single summary line —
        the gate died, or was killed, before it could account for itself, and
        there is no roster to attribute anything to.
    """
    summaries = list(_CONTRACT_SUMMARY.finditer(stdout))
    if len(summaries) != 1:
        return None
    summary = summaries[0]
    return ContractReport(
        failed=int(summary.group("failed")),
        skipped=int(summary.group("skipped")),
        failures=tuple(
            (match.group("name"), match.group("detail"))
            for match in _CONTRACT_FAILURE.finditer(stdout)
        ),
    )


def contract_verdict(result: CommandResult, *, toolchain_moved: bool) -> str | None:
    """Decide whether a strict contract run condemns the candidate.

    The gate runs `mtest doctor`, and `doctor` refuses any toolchain but the
    one mtest was built against. That refusal is correct — it is the product
    behaviour this lane is probing, not a bug to be relaxed — so the tolerance
    belongs here, in the one process deliberately running an unpinned compiler.

    It is drawn as narrowly as the gate's own reporting allows: the failing set
    must be *exactly* `TOLERATED_CONTRACT_FAILURES`, check name and reported
    detail both. One extra failure condemns; one extra clause inside a
    tolerated check's detail condemns; a skip, which `--strict` fails the gate
    for without printing a roll-call entry, condemns; a roll-call that does not
    account for the count printed above it condemns, in either direction,
    because a reader who cannot match the two cannot say every failure was
    tolerable. And a run where the identity checks did *not* fail condemns too:
    on a moved toolchain they must, so a gate whose other checks failed while
    they passed is a gate whose guard has stopped guarding, which is a finding
    rather than a licence.

    This is asked of every run of that gate rather than of the failing ones
    alone, and the difference is the whole point. An exit of 0 is not the
    absence of a finding here; it is a gate that did not fail the three checks
    a moved toolchain must fail, which is the identical finding to one that
    failed elsewhere while they passed. Read on the nonzero branch only, a
    candidate whose `mojo --version` output no longer matches the identity
    `doctor` compiled in — so that `doctor` stops refusing it — made the gate
    green, skipped this reading entirely, and was reported as `PASS`. The
    empty-expected-set rule `e2e_failure_verdict` states for the end-to-end
    roster is the same rule: an expected failure that did not happen is itself
    the finding.

    Args:
        result: The completed gate, whatever it exited.
        toolchain_moved: Whether the resolved toolchain differs from the pin.

    Returns:
        The reason this run condemns the candidate, or None when the gate
        failed exactly the way a moved toolchain makes it fail.
    """
    report = read_contract_report(result.stdout)
    if report is None:
        return (
            f"{command_failure(result)}; the strict contract gate printed no "
            "roster, so no failure could be attributed to the toolchain identity "
            "check"
        )
    if report.skipped:
        return (
            f"the strict contract gate skipped {report.skipped} check(s), and a "
            "skip is not a pass"
        )
    if report.failed != len(report.failures):
        return (
            f"the strict contract gate counted {report.failed} failures and named "
            f"{len(report.failures)}, so its roll-call cannot be read"
        )
    unexpected = tuple(
        f"{name} ({detail})"
        for name, detail in report.failures
        if (name, detail) not in TOLERATED_CONTRACT_FAILURES
    )
    if unexpected:
        return (
            "strict contract checks failed outside mtest's toolchain-identity "
            f"report: {'; '.join(unexpected)}"
        )
    named = {name for name, _detail in report.failures}
    absent = tuple(
        name for name, _detail in TOLERATED_CONTRACT_FAILURES if name not in named
    )
    if absent:
        return (
            "the strict contract gate did not fail the checks a moved toolchain "
            f"must fail: {', '.join(absent)}; mtest's pinned-identity guard has "
            "stopped guarding"
        )
    if not toolchain_moved:
        return (
            "the strict contract gate reported the toolchain-identity failures "
            "against the pinned toolchain itself"
        )
    return None


def _regenerate_and_compare(repo: Path, run: Runner) -> CompareResult:
    """Regenerate the protocol transcripts on the candidate and diff them.

    The generator writes into a temporary directory, never
    `tests/snapshots/protocol`: the committed baseline is the pinned
    toolchain's testimony and overwriting it would destroy the only thing the
    candidate can be compared against.

    Args:
        repo: The checkout holding the committed baseline.
        run: The probe runner.

    Returns:
        The comparator's own result, or — when there was nothing to compare —
        whatever `generator_failure` could attribute the failure to.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-canary-transcripts-") as raw:
        candidate = Path(raw)
        generated = run(
            [
                "pixi",
                "run",
                "python",
                "-m",
                "scripts.gen_transcripts",
                "--out",
                str(candidate),
            ]
        )
        if generated.returncode != 0:
            return generator_failure(generated)
        return compare_transcript_dirs(
            repo / "tests" / "snapshots" / "protocol", candidate
        )


def classify(repo: Path, lane: str, *, run: Runner) -> CanaryResult:
    """Probe one lane's candidate toolchain and name the outcome.

    Every stage that touches the outside world does so through `run`, and that
    is the whole seam: the pipeline's stage ordering and failure mapping are
    exercised without a toolchain, a network, or a package build. Asking the
    freshly installed toolchain its version is a stage like the rest, because a
    call that spawned itself would be the one outward call outside the stage
    budget and the process-group kill, free to hold a scheduled job open until
    the job's own deadline ended the day with no artifact at all. `run` is
    bound to `repo` by its factory, so no stage can answer about a checkout
    other than the one being probed.

    Args:
        repo: A DISPOSABLE checkout. This rewrites `pixi.toml` and, on the
            stable lane, `recipe/recipe.yaml`.
        lane: `stable` or `nightly`. The nightly lane probes source
            compatibility only: prerelease compilers are not something this
            project would ship a package against, so the packaging and Darwin
            legs are the stable lane's alone.
        run: Spawns one probe command and reports how it went.

    Returns:
        The day's classification and the evidence for it.

    Raises:
        ToolchainError: A tracked-file rewrite was refused or impossible, or
            the installed toolchain printed no identity this repository can
            read. Both are faults in the canary or its checkout, never facts
            about the candidate, so neither is a classification.
        OSError: A tracked file or the committed baseline cannot be read, or a
            probe command cannot be spawned at all — pixi missing from PATH is
            a broken runner rather than a fact about a compiler.
        ValueError: The committed transcript baseline is unreadable or names
            two toolchains, which is a broken repository rather than a verdict.
    """
    pin = workspace_pin(repo)
    channels = candidate_channels(repo, lane)

    # Ask before mutating. Two searches, back to back against the same cached
    # index: the first proves the channels are readable and says what they
    # publish, the second asks conda's own version ordering whether any of it
    # is newer than the pin. That split is what tells an idle lane from a
    # broken one — with only the second, an unsatisfiable spec and an
    # unreachable channel look identical, and the stable lane's spec IS
    # unsatisfiable whenever the pin is also the newest release.
    published = run(search_argv(channels, "mojo"))
    if published.returncode != 0:
        return _stage_failure(
            lane, _UNKNOWN, published, INFRA_FAILURE, command_failure(published)
        )
    try:
        available = search_versions(published)
        newest = search_newest(published)
    except ValueError as error:
        # The search ran and answered; this module could not read the answer.
        # pixi is not pinned by the workflow that provisions it, so it floats,
        # and the day it changes the shape of `search --json` this raises on
        # every run of both lanes forever. Quiet, that is a canary that has
        # silently stopped probing while every scheduled run reports green.
        return _result(lane, _UNKNOWN, CANARY_BROKEN, str(error))
    # The same bar the control is held to, for the same reason. An unbounded
    # search that exits 0 with parseable JSON has proved that pixi ran, not
    # that it asked this repository's channels: an answer carrying no `mojo`
    # at all, or one carrying only versions this project was never built
    # against, describes some other index. Waved through, it left the bounded
    # search free to come back empty and the lane free to report a quiet
    # NO_NEWER_CANDIDATE without ever reaching the corroboration below.
    if pin not in available:
        return _result(
            lane,
            _UNKNOWN,
            CANARY_BROKEN,
            f"`{shlex.join(published.argv)}` never named the pinned mojo {pin}, "
            f"so these are not the channels this repository resolves against "
            f"and nothing they say about a candidate can be read",
        )

    # Everything the probe knows about a candidate before one is installed: a
    # version the channels advertised, and no build commit, because a commit
    # only exists once a toolchain has run and said so. `candidate_was_probed`
    # reads that missing commit as "nothing was exercised", so results carrying
    # this name what was published without claiming anything ran on it. The
    # alternative was throwing the version away and writing `unknown` into an
    # issue body on days when the probe knew perfectly well what it had failed
    # to install.
    published_only = ResolvedToolchain(", ".join(newest) or UNKNOWN, UNKNOWN)

    matchspec = candidate_matchspec(pin)
    found = run(search_argv(channels, matchspec))
    # Asked before the corroboration below and not through it. A killed search
    # printed nothing because it was stopped, not because the channels hold
    # nothing, and the control runs on a fresh connection and can answer
    # instantly from cached repodata — so a stalled connection to the index
    # ended the day with the two of them agreeing on a `NO_NEWER_CANDIDATE`
    # nobody had observed, which is quiet, and which closed the issue of a lane
    # sitting on yesterday's real finding.
    if timed_out(found):
        return _result(lane, _UNKNOWN, STAGE_TIMEOUT, command_failure(found))
    if found.returncode == 0:
        try:
            candidates = search_versions(found)
        except ValueError as error:
            return _result(lane, _UNKNOWN, CANARY_BROKEN, str(error))
    else:
        # pixi exits 1 BOTH when a spec matches nothing and when it cannot
        # answer the question at all, printing nothing to stdout either way, so
        # the exit code is not evidence about the channel's inventory. Reading
        # it as "nothing newer" would silence both lanes for good the first
        # time this one argv failed for a reason the unbounded search cannot
        # exhibit — a rejected matchspec spelling, a channel that went away
        # between the two calls. So the failure is corroborated instead: ask
        # the control, which differs by one operator and names the pinned
        # version the channels must carry. Answered, and the failure above was
        # an empty match set. Unanswered, and the probe cannot ask its own
        # question, which is infrastructure rather than a verdict.
        control = run(search_argv(channels, floor_matchspec(pin)))
        if timed_out(control):
            return _result(lane, _UNKNOWN, STAGE_TIMEOUT, command_failure(control))
        if not control_confirms_channels(control, pin):
            return _result(
                lane,
                _UNKNOWN,
                uncorroborated_classification(control),
                f"{command_failure(found)}; the control "
                f"`{floor_matchspec(pin)}` did not confirm the channels can "
                f"answer that, so an empty match set cannot be inferred",
            )
        candidates = ()
    if not candidates:
        # `_UNKNOWN` rather than the pin. The pin is what this repository
        # already ships; putting it under a heading that says "Candidate" told
        # a maintainer a compiler had been exercised on the commonest quiet day
        # there is. The detail below names the newest release anyway.
        return _result(
            lane,
            _UNKNOWN,
            NO_NEWER_CANDIDATE,
            f"nothing matches `{matchspec}` on {', '.join(channels)}; the newest "
            f"mojo published there is {', '.join(newest) or UNKNOWN}",
        )

    relax_workspace_pin(repo, lane)
    install = run(["pixi", "install"])
    if install.returncode != 0 and not timed_out(install):
        # One retry, because a conda solve reaches the network and a single
        # transient failure is not evidence about a toolchain — after a wait,
        # because an outage is still there microseconds later. A stage the
        # probe killed is not retried at all: a second full budget would carry
        # the job past its own deadline and the day would end with no artifact.
        time.sleep(INSTALL_RETRY_BACKOFF_SECONDS)
        install = run(["pixi", "install"])
    if timed_out(install):
        return _result(lane, published_only, STAGE_TIMEOUT, command_failure(install))
    if install.returncode != 0:
        # A solve that failed twice is one of two opposite things, and the
        # difference decides whether anyone hears about it. Either the probe
        # lost its reach — which says nothing about the candidate — or the
        # candidate cannot coexist with what this repository pins around it.
        # The second is a real property of the candidate and exactly what this
        # lane exists to learn: `pixi.toml` fixes python and clang and declares
        # two platforms, while the search that waved this day through is
        # satisfied by a candidate published for either one, so a relaxed spec
        # that no environment can satisfy is a routine, reportable outcome.
        # Filed as infrastructure it exited 0, so a lane that had learned
        # something real about a candidate reported a green day for it.
        #
        # They are told apart by re-asking the control question. Answered, the
        # index is still reachable from this runner and the install failed on
        # its own terms. That misreads a local fault which leaves the index
        # readable — a full disk, a broken prefix — as a candidate finding, and
        # the direction is deliberate: a wrong red is read and corrected the
        # same day, a wrong green is the silence this workflow exists to end.
        #
        # The detail says only that, and deliberately no more. `pixi install`
        # solves, fetches AND links, so a 5xx on a `.conda` payload, a 429, a
        # truncated transfer or a full prefix all land here with repodata
        # search perfectly healthy. The wording used to call every one of them
        # a spec that "cannot be satisfied beside this repository's own pinned
        # dependencies on every platform the manifest declares" — a solver
        # verdict this probe never observed, standing in a durable artifact.
        control = run(search_argv(channels, floor_matchspec(pin)))
        if timed_out(control):
            return _result(
                lane, published_only, STAGE_TIMEOUT, command_failure(control)
            )
        if not control_confirms_channels(control, pin):
            return _result(
                lane,
                published_only,
                uncorroborated_classification(control),
                f"{command_failure(install)}; the control "
                f"`{floor_matchspec(pin)}` did not answer either, so the probe "
                f"had lost its reach rather than learned anything",
            )
        return _result(
            lane,
            published_only,
            SOURCE_INCOMPATIBLE,
            f"{command_failure(install)}; the channels still answered "
            f"`{floor_matchspec(pin)}` afterwards, so the index was reachable "
            f"both times and `{matchspec}` did not install beside this "
            f"repository's own pinned dependencies. The failure above says "
            f"which of solving, fetching and linking did not complete",
        )

    identity = run(list(RESOLVE_ARGV))
    if identity.returncode != 0:
        return _stage_failure(
            lane,
            published_only,
            identity,
            CANARY_BROKEN,
            f"{command_failure(identity)}; the installed environment could not "
            f"say which toolchain it holds, so nothing the gates below reported "
            f"could be attributed to a candidate",
        )
    resolved = parse_toolchain(identity.stdout)
    if resolved.version not in candidates:
        # Everything below this line reports about `resolved`, so `resolved`
        # has to be the thing the search screened. By here the bounded search
        # has already proved that something newer is published and the manifest
        # has been rewritten to admit exactly that set, so a solve that
        # produced anything else did not answer the question this probe asked.
        # The pin itself is the loudest case and used to be the quietest: read
        # as `NO_NEWER_CANDIDATE` it closed the lane's issue, when what it
        # actually shows is a prefix left over from before the rewrite, a
        # `--repo` pointing at a checkout the search never described, or a
        # solver that ignored the spec. Any other version is worse, because it
        # was accepted silently and every gate below would have reported about
        # a toolchain nobody screened.
        return _result(
            lane,
            resolved,
            CANARY_BROKEN,
            f"the relaxed solve installed mojo {resolved.version}, which "
            f"`{matchspec}` never offered ({', '.join(candidates)}); the probe "
            f"is not holding the candidate it screened",
        )

    if lane == STABLE_LANE:
        pin_recipe_to_candidate(repo, resolved)

    for task in SOURCE_TASKS:
        result = run(["pixi", "run", task])
        if result.returncode != 0:
            return _stage_failure(
                lane, resolved, result, SOURCE_INCOMPATIBLE, first_diagnostic(result)
            )

    # Read whatever it exits, never merely waited on. A zero exit from this
    # gate is not silence but a claim — that `mtest doctor` accepted a compiler
    # it was not built against — and it is exactly the claim a candidate that
    # broke the identity guard would make on the day this lane exists to catch
    # it. `contract_verdict` says why that is the same finding as any other.
    contract = run(["pixi", "run", CONTRACT_TASK])
    verdict = contract_verdict(contract, toolchain_moved=resolved.version != pin)
    if verdict is not None:
        return _stage_failure(lane, resolved, contract, SOURCE_INCOMPATIBLE, verdict)

    comparison = _regenerate_and_compare(repo, run)
    if comparison.classification != PASS:
        return _result(lane, resolved, comparison.classification, comparison.detail)

    if lane == STABLE_LANE:
        cross = run(MACOS_CROSS_COMPILE)
        if cross.returncode != 0:
            return _stage_failure(
                lane, resolved, cross, SOURCE_INCOMPATIBLE, first_diagnostic(cross)
            )

    tolerated: tuple[str, ...] = ()
    e2e = run(["pixi", "run", "e2e"])
    if e2e.returncode != 0:
        tolerated = failed_scenarios(e2e.stdout)
        # Always True here — a solve that produced the pin is not in the
        # searched candidate set and stopped the pipeline long before this
        # line. Computed rather than passed as a literal so that if that
        # earlier return ever moves, the tolerance narrows with it instead of
        # quietly outliving its precondition.
        verdict = e2e_failure_verdict(
            tolerated, toolchain_moved=resolved.version != pin
        )
        if verdict is not None:
            return _stage_failure(lane, resolved, e2e, SOURCE_INCOMPATIBLE, verdict)

    # Packaging is last because of what its name claims. `PACKAGE_FAILED` says
    # the sources are fine and the shipped package is not, and that sentence is
    # only true once every source leg has answered. Run before the Darwin
    # cross-compile and the end-to-end suite, a candidate that broke both would
    # still have been reported as a packaging finding, with the premise the
    # classification rests on never tested at all.
    if lane == STABLE_LANE:
        packaged = run(
            ["pixi", "run", "package-check", "--expect-mojo-version", resolved.version]
        )
        if packaged.returncode != 0:
            return _stage_failure(
                lane, resolved, packaged, PACKAGE_FAILED, command_failure(packaged)
            )

    detail = f"every gate held on mojo {resolved.version} ({resolved.commit})"
    # Unconditional: reaching this line means `contract_verdict` returned None,
    # which it only does for a gate that failed exactly the three identity
    # checks. There is no path here on which they were not tolerated.
    notes: list[str] = [
        (
            f"tolerated the {CONTRACT_TASK} failures `mtest doctor` reports for "
            "an unpinned toolchain"
        )
    ]
    if tolerated:
        notes.append(f"tolerated toolchain-reporting drift in {', '.join(tolerated)}")
    for note in notes:
        detail = f"{detail}; {note}"
    return _result(lane, resolved, PASS, detail)


def _stage_failure(
    lane: str,
    resolved: ResolvedToolchain,
    result: CommandResult,
    classification: str,
    detail: str,
) -> CanaryResult:
    """Classify one failed stage, naming a killed stage as killed.

    A stage the probe stopped for outliving `STAGE_TIMEOUT_SECONDS` produced no
    evidence, so whatever its failure ordinarily means cannot be claimed of it.
    Three quarters of an hour of silence on an unwarmed cache is not "the
    sources no longer compile", and a red whose detail string is the only thing
    saying otherwise cannot be triaged from the issue body.

    Args:
        lane: The lane being probed.
        resolved: The candidate, or `_UNKNOWN` before one was resolved.
        result: The failed command.
        classification: What this stage's failure means when it really failed.
        detail: The evidence for that classification.

    Returns:
        The classification, or `STAGE_TIMEOUT` when the stage was killed.
    """
    if timed_out(result):
        return _result(lane, resolved, STAGE_TIMEOUT, command_failure(result))
    return _result(lane, resolved, classification, detail)


def _result(
    lane: str, resolved: ResolvedToolchain, classification: str, detail: str
) -> CanaryResult:
    """Assemble one classification, checking that its name is a real one."""
    if classification not in CLASSIFICATIONS:
        raise ToolchainError(f"unknown classification {classification!r}")
    return CanaryResult(
        lane=lane,
        version=resolved.version,
        commit=resolved.commit,
        classification=classification,
        detail=detail,
    )


def candidate_was_probed(result: CanaryResult) -> bool:
    """Report whether a candidate toolchain was really installed and exercised.

    The probe learns a version and a build commit together, out of one
    `mojo --version` banner, and it only gets to ask that question once an
    install has succeeded. A real commit is therefore the mark of a toolchain
    that existed on this runner; `unknown` is the mark of one that did not, in
    which case the version field either names nothing or names what the
    channels advertised rather than anything that ran.

    Readers key their prose on this rather than on the classification, because
    the classifications do not partition that way. The unsatisfiable-solve path
    reports `SOURCE_INCOMPATIBLE` having installed nothing at all, and a stage
    killed before the install reports `STAGE_TIMEOUT` on the same terms — so a
    body that decided "a candidate was probed" from the classification told a
    maintainer a compiler had been exercised on days when none was.

    Args:
        result: The day's classification.

    Returns:
        True when a candidate toolchain was installed and identified.
    """
    return result.commit != UNKNOWN


def candidate_line(result: CanaryResult) -> str:
    """Render the one line saying which toolchain, if any, was exercised.

    Shared by this module's summary and the notifier's issue body, so that the
    two durable artifacts of one run cannot disagree about whether anything was
    installed. They did: the summary emitted the candidate unconditionally and
    read `- **Candidate:** mojo unknown (unknown)` on every day nothing
    resolved, while the body suppressed it for two classifications and not for
    the others.

    Args:
        result: The day's classification.

    Returns:
        A Markdown list item, without its trailing newline.
    """
    if candidate_was_probed(result):
        return f"- **Candidate:** mojo {result.version} ({result.commit})"
    if result.version == UNKNOWN:
        return "- **Candidate:** none was exercised"
    return (
        f"- **Candidate:** none was exercised; the channels published mojo "
        f"{result.version}"
    )


def render_summary(result: CanaryResult) -> str:
    """Render the human-readable half of the probe's artifact.

    Args:
        result: The day's classification.

    Returns:
        A Markdown document naming the lane, the toolchain and the evidence.
    """
    return (
        f"# Mojo compatibility canary — {result.lane}\n"
        "\n"
        f"- **Classification:** {result.classification}\n"
        f"{candidate_line(result)}\n"
        "\n"
        "```text\n"
        f"{result.detail}\n"
        "```\n"
    )


def write_artifacts(out_dir: Path, result: CanaryResult) -> None:
    """Write the classification where the notifier and the upload can find it.

    Args:
        out_dir: Directory to write `result.json` and `summary.md` into.
        result: The day's classification.

    Raises:
        OSError: The artifacts cannot be written.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(asdict(result), indent=2, sort_keys=False)
    (out_dir / "result.json").write_text(f"{payload}\n", encoding="utf-8")
    (out_dir / "summary.md").write_text(render_summary(result), encoding="utf-8")


def write_diagnostics(out_dir: Path, report: str) -> None:
    """Record a crash in the probe itself, for upload beside a red job.

    Args:
        out_dir: Directory to write `diagnostics.txt` into.
        report: The formatted traceback.

    Raises:
        OSError: The diagnostics cannot be written. `main` calls this from its
            own crash handler, so a raise here replaces the crash report with
            a second traceback rather than hiding either one.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "diagnostics.txt").write_text(report, encoding="utf-8")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Read the probe's lane, checkout and artifact destination.

    Args:
        argv: Command-line arguments, or None to read `sys.argv`.

    Returns:
        A namespace carrying `lane`, `repo`, `out` and `force`.
    """
    parser = argparse.ArgumentParser(
        prog="canary",
        description="Probe a candidate Mojo toolchain and classify the outcome.",
    )
    parser.add_argument("--lane", choices=LANES, required=True)
    parser.add_argument(
        "--repo",
        type=Path,
        default=REPO_ROOT,
        help="the DISPOSABLE checkout to rewrite and probe (default: this one)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="where to write result.json and summary.md (default: <repo>/build/canary)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="permit the tracked-file rewrites outside CI",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the probe and write its artifact down.

    Args:
        argv: Command-line arguments, or None to read `sys.argv`.

    Returns:
        0 whenever a classification was produced, including the red ones; 2
        when this module itself crashed, in which case `diagnostics.txt`
        describes the crash and no classification is written.
    """
    args = parse_args(argv)
    out_dir: Path = args.out if args.out is not None else args.repo / "build" / "canary"
    if args.force:
        os.environ[FORCE_ENV_VAR] = FORCE_ENV_VALUE

    try:
        result = classify(args.repo, args.lane, run=subprocess_runner(args.repo))
    except Exception:  # noqa: BLE001 - any crash here is the canary's own
        # The probe drives compilers, solvers and package builds; there is no
        # useful enumeration of what they can raise. What matters is that the
        # crash is reported AS a crash rather than as a fact about Mojo, and
        # that the traceback survives for the job that uploads it.
        report = traceback.format_exc()
        write_diagnostics(out_dir, report)
        print(
            f"canary: internal failure, see {out_dir / 'diagnostics.txt'}", flush=True
        )
        print(report, file=sys.stderr, flush=True)
        return 2

    write_artifacts(out_dir, result)
    print(
        f"canary: {result.lane} -> {result.classification}: {result.detail}", flush=True
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
