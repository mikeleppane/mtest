#!/usr/bin/env python3
"""Unit tests for the canary notifier's issue policy.

The notifier is the only privileged part of the compatibility canary, and the
two ways it can fail are opposites. It can be too loud — a new issue every day,
or an issue about the canary's own plumbing — after which nobody reads any of
them. Or it can be too quiet, which is worse and much harder to notice: a probe
that never reported looks exactly like a probe with nothing to report, and a
canary that has silently stopped probing is indistinguishable from a healthy one
unless something asserts otherwise. The tests below are organised around that
pair.

Every `gh` call is injected, so the whole policy runs here with no network, no
token, and no repository.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
from typing import TYPE_CHECKING, override
import unittest
from unittest import mock

from scripts.canary.notify import (
    ARTIFACT_PREFIX,
    LOUD_CLASSIFICATIONS,
    QUIET_CLASSIFICATIONS,
    find_issue,
    issue_title,
    main,
    result_path,
    run_reference,
)
from scripts.canary.run import (
    CLASSIFICATIONS,
    INFRA_FAILURE,
    NO_NEWER_CANDIDATE,
    CommandResult,
)
from scripts.canary.toolchain import LANES


if TYPE_CHECKING:
    from collections.abc import Sequence


REPO_ROOT = Path(__file__).resolve().parents[2]

# Independently transcribed rather than imported: these are the names the
# workflow, the probe and a maintainer's issue list all have to agree on.
STABLE = "stable"
NIGHTLY = "nightly"
# Named for what it means rather than spelled `PASS`, which reads as a
# credential to the linter.
GREEN = "PASS"
PROTOCOL_DRIFT = "PROTOCOL_DRIFT"
SOURCE_INCOMPATIBLE = "SOURCE_INCOMPATIBLE"
PACKAGE_FAILED = "PACKAGE_FAILED"
STAGE_TIMEOUT = "STAGE_TIMEOUT"

CANDIDATE_VERSION = "1.0.0b3"
CANDIDATE_COMMIT = "cafef00d"
# What the probe records when there was no candidate: the pinned version for a
# lane with nothing newer, `unknown` when nothing resolved at all. Neither is a
# candidate, and a body that presents one as such is telling a maintainer that
# a compiler was exercised when none was.
PINNED_VERSION = "1.0.0b2"


class FakeGh:
    """Answer every `gh` call from a canned issue list and record the calls."""

    def __init__(self, issues: Sequence[dict[str, object]] = ()) -> None:
        self.issues = list(issues)
        self.calls: list[tuple[str, ...]] = []
        self.list_output: str | None = None
        self.failing: str | None = None

    def __call__(self, argv: Sequence[str]) -> CommandResult:
        """Answer one `gh` command."""
        recorded = tuple(argv)
        self.calls.append(recorded)
        subcommand = recorded[2] if len(recorded) > 2 else ""
        if self.failing is not None and subcommand == self.failing:
            return CommandResult(recorded, 1, "", "gh: HTTP 503")
        if subcommand == "list":
            payload = (
                json.dumps(self.issues)
                if self.list_output is None
                else self.list_output
            )
            return CommandResult(recorded, 0, payload, "")
        return CommandResult(recorded, 0, "", "")

    def subcommands(self) -> list[str]:
        """Name each call's issue subcommand, in order."""
        return [call[2] for call in self.calls]

    def argument(self, subcommand: str, flag: str) -> str:
        """Return one flag's value from the single call to a subcommand."""
        matching = [call for call in self.calls if call[2] == subcommand]
        if len(matching) != 1:
            raise AssertionError(f"expected one {subcommand!r} call, got {matching}")
        call = matching[0]
        return call[call.index(flag) + 1]


def _issue(number: int, lane: str, state: str) -> dict[str, object]:
    """Build one issue as `gh issue list --json` reports it."""
    return {"number": number, "title": f"canary: {lane}", "state": state}


class NotifyTestCase(unittest.TestCase):
    """Shared scaffolding: a throwaway artifact directory."""

    @override
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(prefix="mtest-canary-notify-")
        self.addCleanup(temp.cleanup)
        self.results = Path(temp.name)

    def write_result(
        self,
        lane: str,
        classification: str,
        *,
        detail: str = "evidence",
        version: str = CANDIDATE_VERSION,
        reported_lane: str | None = None,
    ) -> None:
        """Lay down one lane's artifact exactly where the download puts it."""
        path = result_path(self.results, lane)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {
                    "lane": lane if reported_lane is None else reported_lane,
                    "version": version,
                    "commit": CANDIDATE_COMMIT,
                    "classification": classification,
                    "detail": detail,
                }
            ),
            encoding="utf-8",
        )

    def notify(self, gh: FakeGh, lanes: str = STABLE) -> tuple[int, str]:
        """Run the notifier over the throwaway directory."""
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            code = main(
                ["--results", str(self.results), "--lanes", lanes],
                gh=gh,
            )
        return code, stdout.getvalue() + stderr.getvalue()


class IssueIdentityTests(NotifyTestCase):
    """One issue per lane, for the life of the lane."""

    def test_the_title_names_the_lane_and_nothing_else(self) -> None:
        """A title that tracks the weather opens a new issue every time it changes."""
        self.assertEqual(issue_title(STABLE), "canary: stable")
        self.assertEqual(issue_title(NIGHTLY), "canary: nightly")
        for classification in CLASSIFICATIONS:
            self.assertNotIn(classification, issue_title(STABLE))

    def test_the_classification_reaches_the_body(self) -> None:
        gh = FakeGh()
        self.write_result(STABLE, SOURCE_INCOMPATIBLE, detail="error: no decorator")
        code, _log = self.notify(gh)
        self.assertEqual(code, 1)
        self.assertEqual(gh.argument("create", "--title"), "canary: stable")
        body = gh.argument("create", "--body")
        self.assertIn(SOURCE_INCOMPATIBLE, body)
        self.assertIn("error: no decorator", body)
        self.assertIn(CANDIDATE_VERSION, body)

    def test_every_classification_has_exactly_one_policy(self) -> None:
        """A classification in no group would be silently ignored."""
        self.assertEqual(
            set(QUIET_CLASSIFICATIONS) | set(LOUD_CLASSIFICATIONS) | {INFRA_FAILURE},
            set(CLASSIFICATIONS),
        )
        self.assertEqual(set(QUIET_CLASSIFICATIONS) & set(LOUD_CLASSIFICATIONS), set())

    def test_the_artifact_layout_matches_the_workflow(self) -> None:
        """The upload name and this reader are two halves of one contract.

        The download side is asserted per lane rather than once, because
        `actions/download-artifact` only creates a directory per artifact while
        two or more matched. Downloaded in one step, a run that produced a sole
        artifact — a single-lane dispatch, or a scheduled run where one lane's
        upload never happened — would extract it into the root instead, and
        every lane below would read as silent.
        """
        self.assertEqual(
            result_path(Path("build/canary-results"), STABLE),
            Path("build/canary-results/canary-result-stable/result.json"),
        )
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "compat-canary.yml"
        ).read_text(encoding="utf-8")
        self.assertIn(f"name: {ARTIFACT_PREFIX}" + "${{ matrix.lane }}", workflow)
        for lane in LANES:
            self.assertIn(f"pattern: {ARTIFACT_PREFIX}{lane}\n", workflow)
            self.assertIn(
                f"path: build/canary-results/{ARTIFACT_PREFIX}{lane}/\n", workflow
            )
        self.assertNotIn("path: build/canary-results/\n", workflow)

    def test_a_result_at_the_download_root_is_not_a_lane_report(self) -> None:
        """The layout the flattened download would produce must not be readable.

        This is the shape a sole downloaded artifact lands in when the workflow
        asks for every artifact in one step. Reading it as the lane's answer
        would be worse than reporting silence: the file names one lane and the
        run may have expected two, so a `PASS` extracted flat would close an
        issue on behalf of a lane that never reported at all.
        """
        (self.results / "result.json").write_text(
            json.dumps(
                {
                    "lane": STABLE,
                    "version": CANDIDATE_VERSION,
                    "commit": CANDIDATE_COMMIT,
                    "classification": GREEN,
                    "detail": "every gate held",
                }
            ),
            encoding="utf-8",
        )
        gh = FakeGh([_issue(12, STABLE, "OPEN")])
        code, log = self.notify(gh, lanes=STABLE)
        self.assertEqual(code, 1)
        self.assertIn("no readable result", log)
        self.assertNotIn("close", gh.subcommands())

    def test_an_exact_title_wins_over_a_fuzzy_search_hit(self) -> None:
        """GitHub's search is fuzzy; the identity here is not."""
        gh = FakeGh(
            [
                {"number": 7, "title": "canary: stable lane is slow", "state": "OPEN"},
                _issue(9, STABLE, "CLOSED"),
            ]
        )
        self.assertEqual(find_issue(gh, "canary: stable"), (9, "CLOSED"))

    def test_an_open_issue_wins_over_a_closed_duplicate(self) -> None:
        gh = FakeGh([_issue(4, STABLE, "OPEN"), _issue(9, STABLE, "CLOSED")])
        self.assertEqual(find_issue(gh, "canary: stable"), (4, "OPEN"))


class QuietDayTests(NotifyTestCase):
    """A lane with nothing to report closes its issue and says nothing."""

    def test_a_green_lane_closes_an_open_issue(self) -> None:
        for classification in QUIET_CLASSIFICATIONS:
            with self.subTest(classification=classification):
                gh = FakeGh([_issue(12, STABLE, "OPEN")])
                self.write_result(STABLE, classification)
                code, _log = self.notify(gh)
                self.assertEqual(code, 0)
                self.assertEqual(gh.subcommands(), ["list", "close"])
                self.assertIn("12", gh.calls[1])

    def test_a_no_candidate_closing_comment_claims_nothing_was_probed(self) -> None:
        """A durable artifact must not say a compiler was exercised that was not.

        `NO_NEWER_CANDIDATE` means the channels published nothing beyond the
        pin, and `INFRA_FAILURE` means no toolchain could be obtained at all.
        A body opening "probed against a toolchain newer than the one this
        repository pins", with the pinned version underneath it labelled
        `Candidate`, is false in both cases — and these are the two results a
        maintainer sees most often.
        """
        for classification, subcommand, flag in (
            (NO_NEWER_CANDIDATE, "close", "--comment"),
            (INFRA_FAILURE, "comment", "--body"),
        ):
            with self.subTest(classification=classification):
                gh = FakeGh([_issue(12, STABLE, "OPEN")])
                self.write_result(STABLE, classification, version=PINNED_VERSION)
                code, _log = self.notify(gh)
                self.assertEqual(code, 0)
                body = gh.argument(subcommand, flag)
                self.assertNotIn("newer than the one this repository pins", body)
                self.assertNotIn(f"mojo {PINNED_VERSION}", body)
                self.assertIn("none was exercised", body)
                self.assertIn(classification, body)

    def test_a_finding_body_still_names_the_candidate_it_condemns(self) -> None:
        gh = FakeGh()
        self.write_result(STABLE, PROTOCOL_DRIFT)
        code, _log = self.notify(gh)
        self.assertEqual(code, 1)
        body = gh.argument("create", "--body")
        self.assertIn("newer than the one this repository pins", body)
        self.assertIn(f"mojo {CANDIDATE_VERSION} ({CANDIDATE_COMMIT})", body)

    def test_a_killed_stage_says_the_question_went_unanswered(self) -> None:
        gh = FakeGh()
        self.write_result(STABLE, STAGE_TIMEOUT)
        code, _log = self.notify(gh)
        self.assertEqual(code, 1)
        body = gh.argument("create", "--body")
        self.assertIn("outlived its budget", body)
        self.assertNotIn("newer than the one this repository pins", body)

    def test_a_green_lane_with_no_issue_creates_nothing(self) -> None:
        """A lane's issue begins at its first finding, not at its first run.

        The pinned issue is where a finding lives, so a lane that has never had
        one has nothing to pin. Opening an empty issue on day one and closing
        it in the same run would put the canary's first two notifications in a
        maintainer's inbox with nothing in them, which is how a scheduled job
        teaches everyone to stop reading it.
        """
        gh = FakeGh()
        self.write_result(STABLE, GREEN)
        code, _log = self.notify(gh)
        self.assertEqual(code, 0)
        self.assertEqual(gh.subcommands(), ["list"])

    def test_a_green_lane_leaves_a_closed_issue_closed(self) -> None:
        gh = FakeGh([_issue(12, STABLE, "CLOSED")])
        self.write_result(STABLE, NO_NEWER_CANDIDATE)
        code, _log = self.notify(gh)
        self.assertEqual(code, 0)
        self.assertEqual(gh.subcommands(), ["list"])


class FindingTests(NotifyTestCase):
    """A finding about the candidate toolchain turns the run red."""

    def test_each_finding_opens_an_issue_and_fails_the_run(self) -> None:
        for classification in LOUD_CLASSIFICATIONS:
            with self.subTest(classification=classification):
                gh = FakeGh()
                self.write_result(STABLE, classification)
                code, _log = self.notify(gh)
                self.assertEqual(code, 1)
                self.assertEqual(gh.subcommands(), ["list", "create"])
                self.assertIn(classification, gh.argument("create", "--body"))

    def test_a_repeat_finding_updates_rather_than_duplicates(self) -> None:
        gh = FakeGh([_issue(12, STABLE, "OPEN")])
        self.write_result(STABLE, PROTOCOL_DRIFT)
        code, _log = self.notify(gh)
        self.assertEqual(code, 1)
        self.assertEqual(gh.subcommands(), ["list", "edit"])
        self.assertIn("12", gh.calls[1])

    def test_a_returning_finding_reopens_the_lane_s_own_issue(self) -> None:
        """The history of the last regression is worth more than a fresh issue."""
        gh = FakeGh([_issue(12, STABLE, "CLOSED")])
        self.write_result(STABLE, PACKAGE_FAILED)
        code, _log = self.notify(gh)
        self.assertEqual(code, 1)
        self.assertEqual(gh.subcommands(), ["list", "reopen", "edit"])

    def test_one_red_lane_fails_a_run_that_also_had_a_green_one(self) -> None:
        gh = FakeGh()
        self.write_result(STABLE, GREEN)
        self.write_result(NIGHTLY, SOURCE_INCOMPATIBLE)
        code, _log = self.notify(gh, lanes="stable nightly")
        self.assertEqual(code, 1)
        self.assertEqual(gh.argument("create", "--title"), "canary: nightly")


class InfraFailureTests(NotifyTestCase):
    """The canary failing to reach a toolchain is not news about the toolchain."""

    def test_it_comments_on_an_issue_someone_is_already_watching(self) -> None:
        gh = FakeGh([_issue(12, STABLE, "OPEN")])
        self.write_result(STABLE, INFRA_FAILURE, detail="404 Not Found")
        code, _log = self.notify(gh)
        self.assertEqual(code, 0)
        self.assertEqual(gh.subcommands(), ["list", "comment"])
        self.assertIn("404 Not Found", gh.argument("comment", "--body"))

    def test_it_opens_nothing_when_nobody_is_watching(self) -> None:
        gh = FakeGh()
        self.write_result(STABLE, INFRA_FAILURE)
        code, _log = self.notify(gh)
        self.assertEqual(code, 0)
        self.assertEqual(gh.subcommands(), ["list"])

    def test_it_does_not_reopen_a_closed_issue(self) -> None:
        gh = FakeGh([_issue(12, STABLE, "CLOSED")])
        self.write_result(STABLE, INFRA_FAILURE)
        code, _log = self.notify(gh)
        self.assertEqual(code, 0)
        self.assertEqual(gh.subcommands(), ["list"])


class SilentCanaryTests(NotifyTestCase):
    """A probe that reported nothing is a failure, not a quiet day.

    Without these assertions the workflow could stop probing entirely — a job
    that dies before writing its artifact leaves exactly the same evidence as a
    lane with nothing to say — and every scheduled run would keep reporting
    green.
    """

    def test_a_missing_artifact_opens_an_issue_and_fails_the_run(self) -> None:
        gh = FakeGh()
        code, _log = self.notify(gh)
        self.assertEqual(code, 1)
        self.assertEqual(gh.subcommands(), ["list", "create"])
        self.assertIn("no readable result", _log)

    def test_a_malformed_artifact_opens_an_issue_and_fails_the_run(self) -> None:
        path = result_path(self.results, STABLE)
        path.parent.mkdir(parents=True)
        path.write_text("{not json", encoding="utf-8")
        gh = FakeGh()
        code, _log = self.notify(gh)
        self.assertEqual(code, 1)
        self.assertIn("is not JSON", gh.argument("create", "--body"))

    def test_an_artifact_missing_a_field_fails_the_run(self) -> None:
        path = result_path(self.results, STABLE)
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"lane": STABLE}), encoding="utf-8")
        gh = FakeGh()
        code, _log = self.notify(gh)
        self.assertEqual(code, 1)
        self.assertIn("has no string 'version'", gh.argument("create", "--body"))

    def test_an_artifact_describing_another_lane_fails_the_run(self) -> None:
        """The wrong artifact would otherwise close the wrong issue."""
        gh = FakeGh([_issue(12, STABLE, "OPEN")])
        self.write_result(STABLE, GREEN, reported_lane=NIGHTLY)
        code, _log = self.notify(gh)
        self.assertEqual(code, 1)
        self.assertNotIn("close", gh.subcommands())

    def test_an_unknown_classification_fails_the_run(self) -> None:
        gh = FakeGh()
        self.write_result(STABLE, "EVERYTHING_IS_FINE")
        code, _log = self.notify(gh)
        self.assertEqual(code, 1)
        self.assertIn("EVERYTHING_IS_FINE", gh.argument("create", "--body"))

    def test_a_lane_that_was_never_asked_for_is_not_missing(self) -> None:
        """A dispatch runs one lane, and the other one owes no report."""
        gh = FakeGh()
        self.write_result(STABLE, GREEN)
        code, _log = self.notify(gh, lanes=STABLE)
        self.assertEqual(code, 0)


class OperatorErrorTests(NotifyTestCase):
    """The notifier's own failures are told apart from the canary's findings."""

    def test_an_unreachable_github_exits_two(self) -> None:
        gh = FakeGh()
        gh.failing = "list"
        self.write_result(STABLE, GREEN)
        code, log = self.notify(gh)
        self.assertEqual(code, 2)
        self.assertIn("HTTP 503", log)

    def test_an_unreadable_search_answer_exits_two(self) -> None:
        gh = FakeGh()
        gh.list_output = "not json at all"
        self.write_result(STABLE, GREEN)
        code, log = self.notify(gh)
        self.assertEqual(code, 2)
        self.assertIn("did not print JSON", log)

    def test_an_unknown_lane_exits_two(self) -> None:
        gh = FakeGh()
        code, log = self.notify(gh, lanes="weekly")
        self.assertEqual(code, 2)
        self.assertEqual(gh.subcommands(), [])
        self.assertIn("weekly", log)

    def test_no_lanes_at_all_exits_two(self) -> None:
        """A notifier told to check nothing would report green forever."""
        gh = FakeGh()
        code, _log = self.notify(gh, lanes="   ")
        self.assertEqual(code, 2)

    def test_the_lane_vocabulary_is_the_probes(self) -> None:
        self.assertEqual(LANES, (STABLE, NIGHTLY))


class RunReferenceTests(NotifyTestCase):
    """An issue nobody can trace back to a run is an issue nobody can act on."""

    def test_it_links_the_hosted_run(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/mtest",
                "GITHUB_RUN_ID": "42",
            },
            clear=False,
        ):
            self.assertEqual(
                run_reference(),
                "https://github.com/owner/mtest/actions/runs/42",
            )

    def test_it_says_so_when_there_is_no_run(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIn("not recorded", run_reference())


if __name__ == "__main__":
    unittest.main()
