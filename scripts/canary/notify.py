#!/usr/bin/env python3
"""Report each lane's canary classification as exactly one pinned issue.

The probe writes a classification down and exits 0 whatever it found, because a
classification is data. This module is where that data becomes policy, and the
policy is deliberately narrow:

| Classification                                            | What happens here       |
|-----------------------------------------------------------|-------------------------|
| `PASS`, `NO_NEWER_CANDIDATE`                              | close the issue, exit 0 |
| `PROTOCOL_DRIFT`, `SOURCE_INCOMPATIBLE`, `PACKAGE_FAILED` | upsert, exit 1          |
| `STAGE_TIMEOUT`                                           | upsert, exit 1          |
| `INFRA_FAILURE`                                           | comment if open, exit 0 |
| no artifact, or one this cannot read                      | upsert, exit 1          |

Three of those rows are worth arguing for.

`STAGE_TIMEOUT` is loud even though a stage that outlived its budget proved
nothing about the candidate. A lane whose probe cannot finish has stopped
answering the question it exists to answer, and a canary that reports the same
quiet non-answer every day for a month is the failure mode this workflow was
built to prevent.

`INFRA_FAILURE` is quiet on purpose. The canary failing to reach a channel is
news about the canary, not about the toolchain, and a scheduled job that opens
an issue every time a network call flaked teaches everyone to close its issues
unread — after which the day it has something real to say is also unread.

A **missing or unreadable artifact is loud**, and it is the assertion that makes
this a canary rather than a decoration. Every other failure mode here announces
itself; a probe job that died before writing anything announces nothing at all,
and without this row the whole workflow could quietly stop probing while every
scheduled run reported green.

The issue title is the lane and nothing else: `canary: nightly`. Putting the
classification in the title reads better for exactly one run and then destroys
the design, because the title is the identity — a title that tracks the weather
opens a new issue every time the weather changes, and the one issue per lane
that a maintainer can watch, mute, or close becomes a stream of near-duplicates
nobody can follow. The classification lives in the body, which is rewritten in
place on every run.

Closed issues are searched alongside open ones for the same reason. The normal
life of a lane is red for a few days and then green again, so the next
regression finds a closed issue with the history in it, and reopening that is
worth more than a fresh issue that starts the story over.

GitHub is reached through the `gh` CLI, which reads `GH_TOKEN` from the
environment and infers the repository from the checkout it runs in. Every call
goes through one injected callable, so the tests below drive every branch above
without a network, a token, or a repository.
"""

from __future__ import annotations

import argparse
from dataclasses import fields
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
from typing import TYPE_CHECKING

from scripts.canary.protocol_compare import PASS, PROTOCOL_DRIFT

# The probe's classification vocabulary and its two records, imported rather
# than restated so a name added on one side cannot go unhandled on the other.
# This does load the probe module in the job holding `issues: write`, and that
# is a smaller thing than it sounds: the import runs constants and dataclass
# definitions out of this repository's own checked-out source, spawns nothing,
# and reads nothing that came off the network. The property the workflow oracle
# pins is that this job never *invokes* the probe, which is about what the
# workflow runs rather than about what an import graph touches.
from scripts.canary.run import (
    CLASSIFICATIONS,
    INFRA_FAILURE,
    NO_NEWER_CANDIDATE,
    PACKAGE_FAILED,
    SOURCE_INCOMPATIBLE,
    STAGE_TIMEOUT,
    CanaryResult,
    CommandResult,
)
from scripts.canary.toolchain import LANES


if TYPE_CHECKING:
    from collections.abc import Callable, Sequence


# The workflow uploads one artifact per lane under this name, and one download
# step per lane unpacks it into a directory of the same name. Per lane rather
# than all at once because `actions/download-artifact` creates that directory
# only while two or more artifacts matched: a run that produced exactly one
# would have it extracted into the download root instead, where nothing below
# looks, and the lane that did report would be indistinguishable from a lane
# that never ran. The two spellings are pinned together:
# `scripts/checks/workflow_security.py` holds the workflow side, and the tests
# hold this one.
ARTIFACT_PREFIX = "canary-result-"
RESULT_FILENAME = "result.json"

# The issue identity. Stable per lane, forever.
TITLE_PREFIX = "canary: "

# Classifications that mean the lane has nothing to report today.
QUIET_CLASSIFICATIONS = (PASS, NO_NEWER_CANDIDATE)
# Classifications that are findings about the candidate toolchain, which is the
# entire product of this workflow.
LOUD_CLASSIFICATIONS = (
    PROTOCOL_DRIFT,
    SOURCE_INCOMPATIBLE,
    PACKAGE_FAILED,
    STAGE_TIMEOUT,
)

# `gh` reaches the network; none of these calls should take anything like this
# long, and a wedged one must not hold a scheduled job open.
GH_TIMEOUT_SECONDS = 120.0

# How many issues to consider when looking for one exact title. GitHub's search
# is fuzzy, so the answer is filtered by exact title here; the limit only bounds
# how much fuzz is examined.
SEARCH_LIMIT = 100

OPEN = "OPEN"

_FOOTER = (
    "This issue is maintained by the compatibility canary. Its body is rewritten "
    "on every run and it closes itself once the lane is green again, so edits "
    "here do not survive; use a comment."
)


class NotifyError(RuntimeError):
    """A `gh` call this module depends on did not succeed."""


class ArtifactError(RuntimeError):
    """A lane's result artifact is absent, unreadable, or not what it claims."""


if TYPE_CHECKING:
    # The module's whole seam onto the outside world: one callable that spawns a
    # `gh` command and reports how it went.
    Gh = Callable[[Sequence[str]], CommandResult]


def gh_runner() -> Gh:
    """Build the runner that really spawns `gh`.

    Returns:
        A callable taking an argv and returning its `CommandResult`. A call that
        outlives `GH_TIMEOUT_SECONDS` is reported as exit 124 rather than
        allowed to hold the job open.
    """

    def run(argv: Sequence[str]) -> CommandResult:
        recorded = tuple(argv)
        try:
            completed = subprocess.run(
                recorded,
                capture_output=True,
                text=True,
                timeout=GH_TIMEOUT_SECONDS,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return CommandResult(
                recorded, 124, "", f"timed out after {GH_TIMEOUT_SECONDS:.0f}s"
            )
        return CommandResult(
            recorded, completed.returncode, completed.stdout, completed.stderr
        )

    return run


def issue_title(lane: str) -> str:
    """Render the one issue title a lane ever uses.

    Args:
        lane: `stable` or `nightly`.

    Returns:
        The title, which names the lane and nothing about today's result.
    """
    return f"{TITLE_PREFIX}{lane}"


def result_path(results: Path, lane: str) -> Path:
    """Locate one lane's uploaded classification.

    Args:
        results: The directory the workflow downloaded every artifact into.
        lane: `stable` or `nightly`.

    Returns:
        The path the probe's `result.json` arrives at for that lane.
    """
    return results / f"{ARTIFACT_PREFIX}{lane}" / RESULT_FILENAME


def read_result(results: Path, lane: str) -> CanaryResult:
    """Read one lane's classification back off the artifact.

    Validated field by field rather than trusted, because this is the one input
    the privileged job takes from the unprivileged one, and because a report
    that is silently wrong about which lane it describes would close the wrong
    issue.

    Args:
        results: The directory the workflow downloaded every artifact into.
        lane: The lane whose artifact is expected.

    Returns:
        The classification the probe wrote.

    Raises:
        ArtifactError: The artifact is missing, is not the JSON object the probe
            writes, describes another lane, or names a classification this
            repository does not define.
    """
    path = result_path(results, lane)
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ArtifactError(f"{path} could not be read: {error}") from error
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ArtifactError(f"{path} is not JSON: {error}") from error
    if not isinstance(payload, dict):
        raise ArtifactError(f"{path} holds {type(payload).__name__}, not an object")

    values: dict[str, str] = {}
    for field in fields(CanaryResult):
        value = payload.get(field.name)
        if not isinstance(value, str):
            raise ArtifactError(f"{path} has no string {field.name!r}")
        values[field.name] = value
    if values["lane"] != lane:
        raise ArtifactError(
            f"{path} reports lane {values['lane']!r}, not {lane!r}; the wrong "
            "artifact would update the wrong issue"
        )
    if values["classification"] not in CLASSIFICATIONS:
        raise ArtifactError(
            f"{path} names classification {values['classification']!r}, which is "
            "not one this repository defines"
        )
    return CanaryResult(
        lane=values["lane"],
        version=values["version"],
        commit=values["commit"],
        classification=values["classification"],
        detail=values["detail"],
    )


def run_reference() -> str:
    """Name the workflow run this notification came from.

    Returns:
        A URL when the hosted environment supplies one, and a plain statement
        that it did not otherwise. An issue body that silently omits the run is
        an issue nobody can trace back.
    """
    server = os.environ.get("GITHUB_SERVER_URL")
    repository = os.environ.get("GITHUB_REPOSITORY")
    run_id = os.environ.get("GITHUB_RUN_ID")
    if not (server and repository and run_id):
        return "not recorded (this notification did not come from a hosted run)"
    return f"{server}/{repository}/actions/runs/{run_id}"


def _opening_sentence(result: CanaryResult) -> str:
    """State what actually happened, in the terms of this classification.

    Args:
        result: The classification the probe wrote.

    Returns:
        One sentence. `NO_NEWER_CANDIDATE` and `INFRA_FAILURE` each mean no
        newer toolchain was exercised, so a body that opened by saying one was
        would be a false statement standing in a durable, maintainer-facing
        artifact — and the two most common quiet results are exactly where a
        reader stops reading.
    """
    lane = f"**{result.lane}**"
    if result.classification == NO_NEWER_CANDIDATE:
        return (
            f"The compatibility canary found nothing newer than the pinned "
            f"toolchain on the {lane} lane's channels, so no gate ran against "
            "a candidate."
        )
    if result.classification == INFRA_FAILURE:
        return (
            f"The compatibility canary never obtained a toolchain to ask the "
            f"{lane} lane's question of. This says nothing about any "
            "candidate; it is news about the canary."
        )
    if result.classification == STAGE_TIMEOUT:
        return (
            f"A stage of the compatibility canary's {lane} probe outlived its "
            "budget and was killed, so the day's question went unanswered."
        )
    return (
        f"The compatibility canary probed the {lane} lane against a toolchain "
        "newer than the one this repository pins."
    )


def render_body(result: CanaryResult) -> str:
    """Render the issue body describing one lane's result.

    Args:
        result: The classification the probe wrote.

    Returns:
        A Markdown body naming the lane, what was probed, and the evidence.
    """
    if result.classification in (NO_NEWER_CANDIDATE, INFRA_FAILURE):
        # `version` here is the pin or `unknown`, neither of which is a
        # candidate. Labelling it as one puts a version this repository
        # already ships under a heading that says something was tried.
        candidate = "- **Candidate:** none was exercised\n"
    else:
        candidate = f"- **Candidate:** mojo {result.version} ({result.commit})\n"
    return (
        f"{_opening_sentence(result)}\n"
        "\n"
        f"- **Classification:** {result.classification}\n"
        f"{candidate}"
        f"- **Run:** {run_reference()}\n"
        "\n"
        "```text\n"
        f"{result.detail}\n"
        "```\n"
        "\n"
        f"{_FOOTER}\n"
    )


def render_silence_body(lane: str, reason: str) -> str:
    """Render the issue body for a lane that reported nothing readable.

    Args:
        lane: The lane whose artifact is missing or unreadable.
        reason: What went wrong reading it.

    Returns:
        A Markdown body explaining that the probe itself, rather than the
        toolchain, is what needs looking at.
    """
    return (
        f"The compatibility canary produced no readable result for the "
        f"**{lane}** lane, so nothing is known about that lane today.\n"
        "\n"
        f"- **Run:** {run_reference()}\n"
        "\n"
        "```text\n"
        f"{reason}\n"
        "```\n"
        "\n"
        "A canary that stops reporting looks exactly like a canary with nothing "
        "to report, which is why this is a failure rather than a quiet day. The "
        "probe job's log and its uploaded diagnostics say what happened.\n"
        "\n"
        f"{_FOOTER}\n"
    )


def _gh(gh: Gh, argv: Sequence[str]) -> CommandResult:
    """Run one `gh` command and refuse to continue if it failed.

    Args:
        gh: The injected runner.
        argv: The command to spawn.

    Returns:
        The completed command.

    Raises:
        NotifyError: The command failed. Every call here either reads the issue
            state this module decides from or performs the decision, so a
            failure that was swallowed would leave the run green and the issue
            wrong.
    """
    result = gh(argv)
    if result.returncode != 0:
        tail = result.stderr.strip() or result.stdout.strip()
        raise NotifyError(
            f"`{shlex.join(result.argv)}` exited {result.returncode}: {tail}"
        )
    return result


def find_issue(gh: Gh, title: str) -> tuple[int, str] | None:
    """Find the one issue a lane owns, whether it is open or closed.

    GitHub's issue search is fuzzy, so its answer is filtered here by exact
    title. When more than one issue somehow carries the title, an open one wins
    over a closed one and the newest wins among equals, which is the issue a
    reader would be looking at.

    Args:
        gh: The injected runner.
        title: The exact title to look for.

    Returns:
        The issue number and state, or None when the lane has no issue yet.

    Raises:
        NotifyError: The search failed, or answered with something other than
            the list of issue objects it was asked for.
    """
    result = _gh(
        gh,
        [
            "gh",
            "issue",
            "list",
            "--state",
            "all",
            "--search",
            f"{title} in:title",
            "--json",
            "number,title,state",
            "--limit",
            str(SEARCH_LIMIT),
        ],
    )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise NotifyError(f"`gh issue list` did not print JSON: {error}") from error
    if not isinstance(payload, list):
        raise NotifyError(
            f"`gh issue list` printed {type(payload).__name__}, not a list"
        )

    matches: list[tuple[int, str]] = []
    for entry in payload:
        if not isinstance(entry, dict):
            raise NotifyError("`gh issue list` printed a non-object issue")
        number = entry.get("number")
        state = entry.get("state")
        if not isinstance(number, int) or not isinstance(state, str):
            raise NotifyError("`gh issue list` printed an issue with no number")
        if entry.get("title") == title:
            matches.append((number, state))
    if not matches:
        return None
    return max(matches, key=lambda match: (match[1] == OPEN, match[0]))


def upsert_issue(gh: Gh, title: str, body: str) -> None:
    """Make sure the lane's issue exists, is open, and says this.

    Args:
        gh: The injected runner.
        title: The lane's stable title.
        body: The body to publish.

    Raises:
        NotifyError: A `gh` call failed.
    """
    found = find_issue(gh, title)
    if found is None:
        _gh(gh, ["gh", "issue", "create", "--title", title, "--body", body])
        return
    number, state = found
    if state != OPEN:
        _gh(gh, ["gh", "issue", "reopen", str(number)])
    _gh(gh, ["gh", "issue", "edit", str(number), "--body", body])


def notify_lane(gh: Gh, results: Path, lane: str) -> bool:
    """Bring one lane's pinned issue in line with what the probe found.

    Args:
        gh: The injected runner.
        results: The directory the workflow downloaded every artifact into.
        lane: The lane to report.

    Returns:
        True when this lane must turn the run red.

    Raises:
        NotifyError: A `gh` call failed.
    """
    title = issue_title(lane)
    try:
        result = read_result(results, lane)
    except ArtifactError as error:
        upsert_issue(gh, title, render_silence_body(lane, str(error)))
        print(f"canary-notify: {lane} -> no readable result: {error}", flush=True)
        return True

    print(f"canary-notify: {lane} -> {result.classification}", flush=True)
    if result.classification in QUIET_CLASSIFICATIONS:
        found = find_issue(gh, title)
        if found is not None and found[1] == OPEN:
            _gh(
                gh,
                [
                    "gh",
                    "issue",
                    "close",
                    str(found[0]),
                    "--comment",
                    render_body(result),
                ],
            )
        return False
    if result.classification == INFRA_FAILURE:
        # Deliberately quiet, and deliberately not silent: a lane already under
        # investigation gets the evidence that its probe could not run, while a
        # lane nobody is looking at does not gain an issue about the canary's
        # own plumbing.
        found = find_issue(gh, title)
        if found is not None and found[1] == OPEN:
            number, _state = found
            _gh(
                gh,
                ["gh", "issue", "comment", str(number), "--body", render_body(result)],
            )
        return False
    upsert_issue(gh, title, render_body(result))
    return True


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Read where the artifacts landed and which lanes should have reported.

    Args:
        argv: Command-line arguments, or None to read `sys.argv`.

    Returns:
        A namespace carrying `results` and `lanes`.
    """
    parser = argparse.ArgumentParser(
        prog="canary-notify",
        description="Turn each lane's canary result into one pinned issue.",
    )
    parser.add_argument(
        "--results",
        type=Path,
        required=True,
        help="directory holding one downloaded artifact per lane",
    )
    parser.add_argument(
        "--lanes",
        required=True,
        help=(
            "whitespace-separated lanes that should have reported; a lane named "
            "here whose artifact never arrived is a failure"
        ),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None, *, gh: Gh | None = None) -> int:
    """Report every lane and decide whether the run goes red.

    Args:
        argv: Command-line arguments, or None to read `sys.argv`.
        gh: The runner to reach GitHub through, or None for the real `gh`.

    Returns:
        0 when every lane is quiet, 1 when any lane has a finding or failed to
        report at all, and 2 when this module could not do its job — the lanes
        were not named, or GitHub could not be reached.
    """
    args = parse_args(argv)
    lanes = str(args.lanes).split()
    unknown = [lane for lane in lanes if lane not in LANES]
    if not lanes or unknown:
        print(
            f"canary-notify: expected lanes from {LANES}, got {args.lanes!r}",
            file=sys.stderr,
        )
        return 2

    runner = gh_runner() if gh is None else gh
    results = Path(args.results)
    try:
        failed = [lane for lane in lanes if notify_lane(runner, results, lane)]
    except NotifyError as error:
        print(f"canary-notify: {error}", file=sys.stderr)
        return 2
    if failed:
        print(f"canary-notify: lanes needing attention: {', '.join(failed)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
