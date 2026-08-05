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
| `INFRA_FAILURE`       | The probe never got a toolchain to ask about.      |

The classification is DATA, not a verdict, which is why this exits 0 for every
one of them including the red ones. Whether `PROTOCOL_DRIFT` should wake anyone
is a policy question owned by the notifier; a probe that exited nonzero on it
would conflate "the toolchain moved" with "the canary broke", and the second is
the only thing an exit code here can usefully mean. A nonzero exit therefore
says exactly one thing: this module crashed, and the traceback it left behind is
about itself rather than about Mojo.

Only one row is quiet, and the line between it and `SOURCE_INCOMPATIBLE` is
where this module has been wrong twice. `INFRA_FAILURE` means the probe could
not ask its question — an unreachable channel, an answer it cannot read. It
does NOT mean "the environment would not build", because a candidate whose
dependencies cannot sit beside the python, clang and platform set this
repository pins is a fact about that candidate, discovered exactly where this
lane is meant to discover things. Every failure the probe cannot attribute to
its own plumbing therefore lands on a loud row, and the ones it can are named
one at a time with the evidence that named them.

The ordering of the stages is not cosmetic. "Is there anything newer" is asked
of the channels FIRST, as a question, before a single tracked file is touched:
the relaxed spec can be unsatisfiable — it is on the stable channel today,
where the pinned version is also the newest published — and a probe that only
discovered that by watching the install fail would report a candidate finding
forever while a lane that is simply idle looks broken. Asking first also means
an idle day leaves the checkout unmodified.

The pin is then relaxed before anything is installed, because installing under
the committed spec resolves the pinned version and would classify every day as
`NO_NEWER_CANDIDATE` — the mirror-image permanent silence. The recipe is
retargeted before the packaging leg for the same reason. And the cheap,
specific failures are asked before the expensive ones, so a toolchain that
simply does not compile the sources is named that way rather than by whichever
long gate happened to notice.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import shlex
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
    STABLE_LANE,
    TOLERATED_CONTRACT_FAILURES,
    TOLERATED_E2E_SCENARIOS,
    ResolvedToolchain,
    ToolchainError,
    candidate_channels,
    candidate_matchspec,
    floor_matchspec,
    pin_recipe_to_candidate,
    relax_workspace_pin,
    resolved_toolchain,
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
INFRA_FAILURE = "INFRA_FAILURE"

CLASSIFICATIONS = (
    PASS,
    NO_NEWER_CANDIDATE,
    PROTOCOL_DRIFT,
    SOURCE_INCOMPATIBLE,
    PACKAGE_FAILED,
    STAGE_TIMEOUT,
    INFRA_FAILURE,
)

# The gates run against the candidate, cheapest and most specific first.
SOURCE_TASKS = ("build-bin", "test-unit")

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
    # command, and one that reports what the install resolved.
    Runner = Callable[[Sequence[str]], CommandResult]
    Resolver = Callable[[Path], ResolvedToolchain]


def subprocess_runner(repo: Path) -> Runner:
    """Build the runner that really spawns probe commands.

    Every probe command is captured rather than streamed, because its output is
    the detail a classification carries and has to survive into the artifact.

    Args:
        repo: The checkout every command runs in.

    Returns:
        A callable taking an argv and returning its `CommandResult`.
    """

    def run(argv: Sequence[str]) -> CommandResult:
        recorded = tuple(argv)
        print(f"canary: $ {shlex.join(recorded)}", flush=True)
        try:
            completed = subprocess.run(
                recorded,
                cwd=repo,
                capture_output=True,
                text=True,
                timeout=STAGE_TIMEOUT_SECONDS,
                check=False,
            )
        except subprocess.TimeoutExpired:
            # The partial output a killed child left behind is not worth
            # decoding: what a reader needs is that this stage never finished.
            return CommandResult(
                recorded,
                TIMEOUT_RETURNCODE,
                "",
                f"timed out after {STAGE_TIMEOUT_SECONDS:.0f}s",
            )
        return CommandResult(
            recorded, completed.returncode, completed.stdout, completed.stderr
        )

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


def search_versions(result: CommandResult) -> tuple[str, ...]:
    """Read the versions out of one `pixi search --json` answer.

    pixi answers with an object keyed by subdir, each holding package records
    newest first in conda's own version ordering. That ordering is the reason
    this delegates rather than comparing versions itself: `1.0.0rc0` outranks
    `1.0.0b3.dev2026080406`, and every naive lexical or dotted-numeric
    comparison gets that backwards.

    Args:
        result: A completed, successful search.

    Returns:
        The distinct versions offered, newest first, deduplicated across
        subdirs with the first occurrence winning.

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

    versions: list[str] = []
    for records in payload.values():
        if not isinstance(records, list):
            raise ValueError(f"`{described}` printed a non-list of package records")
        for record in records:
            version = record.get("version") if isinstance(record, dict) else None
            if not isinstance(version, str):
                raise ValueError(f"`{described}` printed a record with no version")
            if version not in versions:
                versions.append(version)
    return tuple(versions)


def control_confirms_channels(control: CommandResult, pin: str) -> bool:
    """Decide whether a control search proved the channels can be questioned.

    The bar is deliberately higher than "it exited 0": the control has to come
    back naming the pinned version. An answer that parses but does not carry
    the version this repository is built against is not evidence that the
    channels hold nothing newer — it is evidence that they are not the channels
    this probe thinks it is asking.

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
    only reach this with a toolchain that differs from the pin, because an
    equal one returned `NO_NEWER_CANDIDATE` several stages earlier, so the
    False branch is unreachable from the pipeline as it stands today and is
    covered by this module's tests alone. It is kept because the tolerance is
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
    if result.returncode == TIMEOUT_RETURNCODE:
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


def contract_failure_verdict(stdout: str, *, toolchain_moved: bool) -> str | None:
    """Decide whether a failing strict contract gate condemns the candidate.

    The gate runs `mtest doctor`, and `doctor` refuses any toolchain but the
    one mtest was built against. That refusal is correct — it is the product
    behaviour this lane is probing, not a bug to be relaxed — so the tolerance
    belongs here, in the one process deliberately running an unpinned compiler.

    It is drawn as narrowly as the gate's own reporting allows: the failing set
    must be *exactly* `TOLERATED_CONTRACT_FAILURES`, check name and reported
    detail both. One extra failure condemns; one extra clause inside a
    tolerated check's detail condemns; a skip, which `--strict` fails the gate
    for without printing a roll-call entry, condemns; a roll-call shorter than
    the count above it condemns, because a reader that cannot see every failure
    cannot say they were all tolerable. And a run where the identity checks did
    *not* fail condemns too: on a moved toolchain they must, so a gate that
    failed elsewhere while they passed is a gate whose guard has stopped
    guarding, which is a finding rather than a licence.

    Args:
        stdout: The gate's captured output.
        toolchain_moved: Whether the resolved toolchain differs from the pin.

    Returns:
        The reason this failure condemns the candidate, or None when the gate
        failed exactly the way a moved toolchain makes it fail.
    """
    report = read_contract_report(stdout)
    if report is None:
        return (
            "the strict contract gate failed without printing its roster, so no "
            "failure could be attributed to the toolchain identity check"
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


def classify(
    repo: Path,
    lane: str,
    *,
    run: Runner,
    resolve: Resolver = resolved_toolchain,
) -> CanaryResult:
    """Probe one lane's candidate toolchain and name the outcome.

    Every stage that touches the outside world does so through `run`, and the
    one stage that cannot (asking the freshly installed toolchain its version,
    whose signature belongs to `scripts.canary.toolchain`) goes through
    `resolve`. Together those two arguments are the whole seam: the pipeline's
    stage ordering and failure mapping are exercised without a toolchain, a
    network, or a package build. Both are bound to `repo`, `run` by its factory
    and `resolve` by the argument it is handed, so neither can answer about a
    checkout other than the one being probed.

    Args:
        repo: A DISPOSABLE checkout. This rewrites `pixi.toml` and, on the
            stable lane, `recipe/recipe.yaml`.
        lane: `stable` or `nightly`. The nightly lane probes source
            compatibility only: prerelease compilers are not something this
            project would ship a package against, so the packaging and Darwin
            legs are the stable lane's alone.
        run: Spawns one probe command and reports how it went.
        resolve: Reports the toolchain the install produced.

    Returns:
        The day's classification and the evidence for it.

    Raises:
        ToolchainError: A tracked-file rewrite was refused or impossible. That
            is a fault in the canary or its checkout, never a fact about the
            candidate, so it is not a classification.
        OSError: A tracked file or the committed baseline cannot be read.
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
    except ValueError as error:
        return _result(lane, _UNKNOWN, INFRA_FAILURE, str(error))
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
            INFRA_FAILURE,
            f"`{shlex.join(published.argv)}` never named the pinned mojo {pin}, "
            f"so these are not the channels this repository resolves against "
            f"and nothing they say about a candidate can be read",
        )

    matchspec = candidate_matchspec(pin)
    found = run(search_argv(channels, matchspec))
    if found.returncode == 0:
        try:
            candidates = search_versions(found)
        except ValueError as error:
            return _result(lane, _UNKNOWN, INFRA_FAILURE, str(error))
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
        if not control_confirms_channels(control, pin):
            return _stage_failure(
                lane,
                _UNKNOWN,
                found,
                INFRA_FAILURE,
                f"{command_failure(found)}; the control "
                f"`{floor_matchspec(pin)}` did not confirm the channels can "
                f"answer that, so an empty match set cannot be inferred",
            )
        candidates = ()
    if not candidates:
        newest = available[0] if available else UNKNOWN
        return _result(
            lane,
            ResolvedToolchain(pin, UNKNOWN),
            NO_NEWER_CANDIDATE,
            f"nothing matches `{matchspec}` on {', '.join(channels)}; the newest "
            f"mojo published there is {newest}",
        )

    relax_workspace_pin(repo, lane)
    install = run(["pixi", "install"])
    if install.returncode not in (0, TIMEOUT_RETURNCODE):
        # One retry, because a conda solve reaches the network and a single
        # transient failure is not evidence about a toolchain — after a wait,
        # because an outage is still there microseconds later. A stage the
        # probe killed is not retried at all: a second full budget would carry
        # the job past its own deadline and the day would end with no artifact.
        time.sleep(INSTALL_RETRY_BACKOFF_SECONDS)
        install = run(["pixi", "install"])
    if install.returncode == TIMEOUT_RETURNCODE:
        return _result(lane, _UNKNOWN, STAGE_TIMEOUT, command_failure(install))
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
        # Filed as infrastructure it wrote no issue and exited 0, so a lane
        # that had learned something reported a green day, every day.
        #
        # They are told apart by re-asking the control question. Answered, the
        # index is still reachable from this runner and the solver failed on
        # its own terms. That misreads a local fault which leaves the index
        # readable — a full disk, a broken prefix — as a candidate finding, and
        # the direction is deliberate: a wrong red is read and corrected the
        # same day, a wrong green is the silence this workflow exists to end.
        control = run(search_argv(channels, floor_matchspec(pin)))
        if not control_confirms_channels(control, pin):
            return _result(
                lane,
                _UNKNOWN,
                INFRA_FAILURE,
                f"{command_failure(install)}; the control "
                f"`{floor_matchspec(pin)}` did not answer either, so the probe "
                f"had lost its reach rather than learned anything",
            )
        return _result(
            lane,
            _UNKNOWN,
            SOURCE_INCOMPATIBLE,
            f"{command_failure(install)}; the channels still answer "
            f"`{floor_matchspec(pin)}`, so `{matchspec}` cannot be satisfied "
            f"beside this repository's own pinned dependencies on every "
            f"platform the manifest declares",
        )

    resolved = resolve(repo)
    if resolved.version == pin:
        return _result(
            lane,
            resolved,
            NO_NEWER_CANDIDATE,
            f"the relaxed solve still resolved the pinned toolchain mojo {pin}",
        )

    if lane == STABLE_LANE:
        pin_recipe_to_candidate(repo, resolved)

    for task in SOURCE_TASKS:
        result = run(["pixi", "run", task])
        if result.returncode != 0:
            return _stage_failure(
                lane, resolved, result, SOURCE_INCOMPATIBLE, first_diagnostic(result)
            )

    contract = run(["pixi", "run", CONTRACT_TASK])
    tolerated_contract = False
    if contract.returncode != 0:
        verdict = contract_failure_verdict(
            contract.stdout, toolchain_moved=resolved.version != pin
        )
        if verdict is not None:
            return _stage_failure(
                lane, resolved, contract, SOURCE_INCOMPATIBLE, verdict
            )
        tolerated_contract = True

    comparison = _regenerate_and_compare(repo, run)
    if comparison.classification != PASS:
        return _result(lane, resolved, comparison.classification, comparison.detail)

    if lane == STABLE_LANE:
        packaged = run(
            ["pixi", "run", "package-check", "--expect-mojo-version", resolved.version]
        )
        if packaged.returncode != 0:
            return _stage_failure(
                lane, resolved, packaged, PACKAGE_FAILED, command_failure(packaged)
            )

        cross = run(MACOS_CROSS_COMPILE)
        if cross.returncode != 0:
            return _stage_failure(
                lane, resolved, cross, SOURCE_INCOMPATIBLE, first_diagnostic(cross)
            )

    tolerated: tuple[str, ...] = ()
    e2e = run(["pixi", "run", "e2e"])
    if e2e.returncode != 0:
        tolerated = failed_scenarios(e2e.stdout)
        # Always True here — the pin-equal case returned NO_NEWER_CANDIDATE
        # long before this line. Computed rather than passed as a literal so
        # that if that earlier return ever moves, the tolerance narrows with it
        # instead of quietly outliving its precondition.
        verdict = e2e_failure_verdict(
            tolerated, toolchain_moved=resolved.version != pin
        )
        if verdict is not None:
            return _stage_failure(lane, resolved, e2e, SOURCE_INCOMPATIBLE, verdict)

    detail = f"every gate held on mojo {resolved.version} ({resolved.commit})"
    notes: list[str] = []
    if tolerated_contract:
        notes.append(
            f"tolerated the {CONTRACT_TASK} failures `mtest doctor` reports for "
            "an unpinned toolchain"
        )
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
    if result.returncode == TIMEOUT_RETURNCODE:
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
        f"- **Candidate:** mojo {result.version} ({result.commit})\n"
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
