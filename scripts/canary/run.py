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
| `SOURCE_INCOMPATIBLE` | The sources no longer compile, test, or behave.    |
| `PACKAGE_FAILED`      | The sources are fine; the shipped package is not.  |
| `INFRA_FAILURE`       | The probe never got a toolchain to ask about.      |

The classification is DATA, not a verdict, which is why this exits 0 for every
one of them including the red ones. Whether `PROTOCOL_DRIFT` should wake anyone
is a policy question owned by the notifier; a probe that exited nonzero on it
would conflate "the toolchain moved" with "the canary broke", and the second is
the only thing an exit code here can usefully mean. A nonzero exit therefore
says exactly one thing: this module crashed, and the traceback it left behind is
about itself rather than about Mojo.

The ordering of the stages is not cosmetic. The workspace pin is relaxed before
anything is installed, because installing first resolves the committed pin and
would classify every single day as `NO_NEWER_CANDIDATE` — a canary that is
permanently, silently green. The recipe is retargeted before the packaging leg
for the mirror-image reason. And the cheap, specific failures are asked first,
so a toolchain that simply does not compile the sources is named that way
rather than by whichever expensive gate happened to notice.
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
import traceback
from typing import TYPE_CHECKING

from scripts.canary.protocol_compare import (
    PASS,
    PROTOCOL_DRIFT,
    CompareResult,
    compare_transcript_dirs,
)
from scripts.canary.toolchain import (
    DOCTOR_PREFIX,
    FORCE_ENV_VAR,
    LANES,
    STABLE_LANE,
    ResolvedToolchain,
    ToolchainError,
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
INFRA_FAILURE = "INFRA_FAILURE"

CLASSIFICATIONS = (
    PASS,
    NO_NEWER_CANDIDATE,
    PROTOCOL_DRIFT,
    SOURCE_INCOMPATIBLE,
    PACKAGE_FAILED,
    INFRA_FAILURE,
)

# The gates run against the candidate, cheapest and most specific first.
SOURCE_TASKS = ("build-bin", "test-unit", "contract-check-strict")

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

# No stage may hold the probe forever; a wedged gate becomes that stage's
# classification rather than a scheduled job that never reports.
STAGE_TIMEOUT_SECONDS = 3600.0

# Compiler diagnostics, in the shape Mojo emits them. The first one is what a
# reader needs; everything after it is usually cascade.
_DIAGNOSTIC = re.compile(r"^.*?: error: .*$", re.MULTILINE)

# The e2e gate's failure roll-call, printed once per failing scenario.
_E2E_FAILURE = re.compile(r"^FAILED: (\S+)$", re.MULTILINE)

# Stands in for the toolchain identity before the install has produced one.
_UNKNOWN = ResolvedToolchain("unknown", "unknown")


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
    Resolver = Callable[[], ResolvedToolchain]


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
                124,
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

    `mtest doctor` reports the toolchain it found, so its scenarios genuinely
    fail once the toolchain moves. That tolerance is narrow on purpose, because
    "some failures are expected" degrades into "failures are ignored" the
    moment it stops being checked: any other failing scenario condemns, a
    failure that named no scenario condemns (the roll-call this reads has
    changed shape and the guard has stopped guarding), and doctor scenarios
    failing while the toolchain did NOT move condemns too, since then they
    cannot be blamed on the thing being probed.

    Args:
        failed: The scenario ids that failed.
        toolchain_moved: Whether the resolved toolchain differs from the pin.

    Returns:
        The reason these failures condemn the toolchain, or None when they are
        exactly the expected toolchain-reporting drift.
    """
    unexpected = tuple(name for name in failed if not name.startswith(DOCTOR_PREFIX))
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
        The comparator's own result. A generator that cannot complete at all is
        reported as drift rather than as an infrastructure fault, because its
        structural pins — the emitted name set, and byte-identical output
        across two generations — are protocol assertions in their own right.
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
            return CompareResult(PROTOCOL_DRIFT, command_failure(generated))
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
    network, or a package build.

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

    relax_workspace_pin(repo, lane)
    install = run(["pixi", "install"])
    if install.returncode != 0:
        # One retry, because a conda solve reaches the network and a single
        # transient failure is not evidence about a toolchain.
        install = run(["pixi", "install"])
    if install.returncode != 0:
        return _result(lane, _UNKNOWN, INFRA_FAILURE, command_failure(install))

    resolved = resolve()
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
            return _result(
                lane, resolved, SOURCE_INCOMPATIBLE, first_diagnostic(result)
            )

    comparison = _regenerate_and_compare(repo, run)
    if comparison.classification != PASS:
        return _result(lane, resolved, comparison.classification, comparison.detail)

    if lane == STABLE_LANE:
        packaged = run(
            ["pixi", "run", "package-check", "--expect-mojo-version", resolved.version]
        )
        if packaged.returncode != 0:
            return _result(lane, resolved, PACKAGE_FAILED, command_failure(packaged))

        cross = run(MACOS_CROSS_COMPILE)
        if cross.returncode != 0:
            return _result(lane, resolved, SOURCE_INCOMPATIBLE, first_diagnostic(cross))

    tolerated: tuple[str, ...] = ()
    e2e = run(["pixi", "run", "e2e"])
    if e2e.returncode != 0:
        tolerated = failed_scenarios(e2e.stdout)
        verdict = e2e_failure_verdict(
            tolerated, toolchain_moved=resolved.version != pin
        )
        if verdict is not None:
            return _result(lane, resolved, SOURCE_INCOMPATIBLE, verdict)

    detail = f"every gate held on mojo {resolved.version} ({resolved.commit})"
    if tolerated:
        detail = (
            f"{detail}; tolerated toolchain-reporting drift in {', '.join(tolerated)}"
        )
    return _result(lane, resolved, PASS, detail)


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
        os.environ[FORCE_ENV_VAR] = "1"

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
