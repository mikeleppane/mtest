#!/usr/bin/env python3
"""Unit tests for the candidate-toolchain probe and the rewrites it depends on.

The probe's product is a classification, so these tests are organised around
the two ways a classification can lie. It can be *green for the wrong reason*:
a solve that quietly resolved the pinned toolchain again, a packaging leg built
with the pinned compiler, an expected-failure guard that has degenerated into
ignoring failures. And it can be *red for the wrong reason*: an internal crash
reported as a fact about the toolchain.

Every subprocess is injected, so the whole pipeline runs here without a Mojo
toolchain, a network, or a package build. What is emphatically *not* faked is
the pair of tracked files the probe rewrites: `pixi.toml` and
`recipe/recipe.yaml` are copied from this checkout, so a change to how either
one spells its compiler pin reds these tests instead of silently disarming the
canary.
"""

from __future__ import annotations

import contextlib
from dataclasses import dataclass
import inspect
import io
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from typing import TYPE_CHECKING, override
import unittest
from unittest import mock

from scripts.canary import toolchain
from scripts.canary.protocol_compare import PASS, PROTOCOL_DRIFT
from scripts.canary.run import (
    INFRA_FAILURE,
    JOB_TIMEOUT_HEADROOM_SECONDS,
    MACOS_CROSS_COMPILE,
    NO_NEWER_CANDIDATE,
    PACKAGE_FAILED,
    SOURCE_INCOMPATIBLE,
    STAGE_TIMEOUT,
    STAGE_TIMEOUT_SECONDS,
    TIMEOUT_RETURNCODE,
    CanaryResult,
    CommandResult,
    classify,
    control_confirms_channels,
    e2e_failure_verdict,
    failed_scenarios,
    first_diagnostic,
    main,
    search_argv,
    search_versions,
)
from scripts.canary.toolchain import (
    CI_ENV_VAR,
    FORCE_ENV_VAR,
    NIGHTLY_CHANNEL,
    RESOLVE_ARGV,
    TOLERATED_E2E_SCENARIOS,
    ResolvedToolchain,
    ToolchainError,
    candidate_channels,
    candidate_matchspec,
    floor_matchspec,
    mutation_permitted,
    pin_recipe_to_candidate,
    relax_workspace_pin,
    relaxed_spec,
    resolved_toolchain,
    workspace_channels,
    workspace_pin,
)
from scripts import gen_transcripts
from scripts.e2e.__main__ import SCENARIOS
from scripts.gen_transcripts import MOJO_VERSION_RE as GENERATOR_VERSION_RE


if TYPE_CHECKING:
    from collections.abc import Sequence


REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / "scripts" / "fixtures" / "canary"

# Independently transcribed from pixi.toml and recipe/recipe.yaml. Reading the
# pin out of the module under test would make every assertion below a tautology.
PINNED_MOJO = "1.0.0b2"
CANDIDATE = ResolvedToolchain("1.0.0b3", "cafef00d")

STABLE = "stable"
NIGHTLY = "nightly"


def _copy_repo(root: Path, fixture: str = "identical_newer") -> Path:
    """Lay out the parts of this checkout the probe reads or rewrites.

    Each call gets its own directory, so one test can probe several throwaway
    checkouts without one probe's rewrites deciding the next one's outcome.
    """
    repo = Path(tempfile.mkdtemp(prefix="repo-", dir=root))
    (repo / "recipe").mkdir(parents=True)
    shutil.copy(REPO_ROOT / "pixi.toml", repo / "pixi.toml")
    shutil.copy(REPO_ROOT / "recipe" / "recipe.yaml", repo / "recipe" / "recipe.yaml")
    shutil.copytree(
        FIXTURES / fixture / "pinned", repo / "tests" / "snapshots" / "protocol"
    )
    return repo


def _stage_of(argv: Sequence[str]) -> str:
    """Name the pipeline stage one probe command belongs to."""
    parts = list(argv)
    if parts[:2] == ["pixi", "search"]:
        # The three searches differ only in their matchspec: the reachability
        # probe asks for the bare package, the candidate probe bounds it above
        # the pin, and the control admits the pin itself.
        spec = parts[-1]
        if " >=" in spec:
            return "search-control"
        if " >" in spec:
            return "search-candidates"
        return "search-published"
    if parts[:2] == ["pixi", "install"]:
        return "install"
    if parts[:2] == ["pixi", "run"]:
        if parts[2] == "python":
            return "transcripts"
        if parts[2] == "mojo":
            return "cross-compile"
        return parts[2]
    return parts[0]


@dataclass
class _Outcome:
    """One canned subprocess result."""

    returncode: int
    stdout: str
    stderr: str


def _search_answer(*versions: str) -> str:
    """Render a `pixi search --json` answer offering exactly these versions.

    Trimmed from a real answer: pixi keys the object by subdir and lists the
    same versions under each, newest first.
    """
    records = [{"name": "mojo", "version": version} for version in versions]
    return json.dumps({"linux-64": records, "osx-arm64": records})


# What the channels offer on an ordinary probe day: something newer than the
# pin exists, so the search stage waves the pipeline through.
_PUBLISHED = _search_answer(CANDIDATE.version, PINNED_MOJO)
_CANDIDATES = _search_answer(CANDIDATE.version)


class FakeRunner:
    """Stand in for every probe subprocess and record what was asked of it.

    Two observations are recorded that no assertion on the argv list could
    make: the text of `pixi.toml` at the instant `pixi install` ran (the
    ordering proof), and the transcript tree the generator "wrote".
    """

    def __init__(self, repo: Path, candidate_tree: Path | None = None) -> None:
        self.repo = repo
        self.candidate_tree = candidate_tree
        self.calls: list[tuple[str, ...]] = []
        self.stages: list[str] = []
        self.pixi_toml_seen_by_install: list[str] = []
        self._outcomes: dict[str, list[_Outcome]] = {
            "search-published": [_Outcome(0, _PUBLISHED, "")],
            "search-candidates": [_Outcome(0, _CANDIDATES, "")],
            "search-control": [_Outcome(0, _PUBLISHED, "")],
        }

    def outcomes(self, stage: str, *outcomes: _Outcome) -> None:
        """Queue results for one stage; the last one repeats."""
        self._outcomes[stage] = list(outcomes)

    def fails(self, stage: str, stdout: str = "", stderr: str = "boom") -> None:
        """Make one stage fail every time it is invoked."""
        self.outcomes(stage, _Outcome(1, stdout, stderr))

    def __call__(self, argv: Sequence[str]) -> CommandResult:
        """Answer one probe command."""
        recorded = tuple(argv)
        self.calls.append(recorded)
        stage = _stage_of(recorded)
        self.stages.append(stage)
        if stage == "install":
            self.pixi_toml_seen_by_install.append(
                (self.repo / "pixi.toml").read_text(encoding="utf-8")
            )
        queued = self._outcomes.get(stage, [_Outcome(0, "", "")])
        outcome = queued.pop(0) if len(queued) > 1 else queued[0]
        if stage == "transcripts" and outcome.returncode == 0:
            self._write_transcripts(recorded)
        return CommandResult(
            recorded, outcome.returncode, outcome.stdout, outcome.stderr
        )

    def _write_transcripts(self, argv: tuple[str, ...]) -> None:
        if self.candidate_tree is None:
            raise AssertionError("the pipeline regenerated transcripts unexpectedly")
        destination = Path(argv[argv.index("--out") + 1])
        shutil.copytree(self.candidate_tree, destination, dirs_exist_ok=True)


class CanaryTestCase(unittest.TestCase):
    """Shared scaffolding: a throwaway checkout that believes it is on CI."""

    @override
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(prefix="mtest-canary-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.enterContext(
            mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}, clear=False)
        )
        os.environ.pop(FORCE_ENV_VAR, None)
        # The retry's backoff is real time the pipeline would spend asleep.
        self.slept: list[float] = []
        self.enterContext(mock.patch("scripts.canary.run.time.sleep", self.slept.append))

    def build(self, fixture: str = "identical_newer") -> tuple[Path, FakeRunner]:
        """Return a throwaway checkout and a runner primed for it."""
        repo = _copy_repo(self.root, fixture)
        return repo, FakeRunner(repo, FIXTURES / fixture / "candidate")

    def classify(
        self,
        repo: Path,
        runner: FakeRunner,
        lane: str = STABLE,
        resolved: ResolvedToolchain = CANDIDATE,
    ) -> CanaryResult:
        """Run the pipeline with everything external injected."""
        return classify(repo, lane, run=runner, resolve=lambda _repo: resolved)


class MutationGuardTests(CanaryTestCase):
    """The two rewrites refuse to touch a developer's checkout."""

    def test_relax_refuses_outside_ci(self) -> None:
        repo = _copy_repo(self.root)
        before = (repo / "pixi.toml").read_text(encoding="utf-8")
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            self.assertRaises(ToolchainError) as raised,
        ):
            relax_workspace_pin(repo, STABLE)
        self.assertIn("GITHUB_ACTIONS", str(raised.exception))
        self.assertEqual((repo / "pixi.toml").read_text(encoding="utf-8"), before)

    def test_recipe_pin_refuses_outside_ci(self) -> None:
        repo = _copy_repo(self.root)
        recipe = repo / "recipe" / "recipe.yaml"
        before = recipe.read_text(encoding="utf-8")
        with (
            mock.patch.dict(os.environ, {}, clear=True),
            self.assertRaises(ToolchainError) as raised,
        ):
            pin_recipe_to_candidate(repo, CANDIDATE)
        self.assertIn("GITHUB_ACTIONS", str(raised.exception))
        self.assertEqual(recipe.read_text(encoding="utf-8"), before)

    def test_a_marker_that_denies_ci_permits_nothing(self) -> None:
        # `GITHUB_ACTIONS=false` is what a step exports to say it is NOT
        # hosted, and `MTEST_CANARY_FORCE=0` is how an operator spells "not
        # this time". Reading either as "set, therefore permitted" turned both
        # into authorization to rewrite a contributor's tracked files.
        repo = _copy_repo(self.root)
        before = (repo / "pixi.toml").read_text(encoding="utf-8")
        for variable, value in (
            (CI_ENV_VAR, "false"),
            (CI_ENV_VAR, "0"),
            (CI_ENV_VAR, "no"),
            (FORCE_ENV_VAR, "0"),
            (FORCE_ENV_VAR, "false"),
        ):
            with (
                self.subTest(variable=variable, value=value),
                mock.patch.dict(os.environ, {variable: value}, clear=True),
            ):
                self.assertFalse(mutation_permitted())
                with self.assertRaises(ToolchainError):
                    relax_workspace_pin(repo, STABLE)
        self.assertEqual((repo / "pixi.toml").read_text(encoding="utf-8"), before)

    def test_only_the_documented_values_permit_a_rewrite(self) -> None:
        # Independently transcribed: GitHub exports `GITHUB_ACTIONS=true`, and
        # `--force` exports `MTEST_CANARY_FORCE=1`.
        for variable, value in ((CI_ENV_VAR, "true"), (FORCE_ENV_VAR, "1")):
            with (
                self.subTest(variable=variable),
                mock.patch.dict(os.environ, {variable: value}, clear=True),
            ):
                self.assertTrue(mutation_permitted())

    def test_an_explicit_force_permits_both_outside_ci(self) -> None:
        repo = _copy_repo(self.root)
        with mock.patch.dict(os.environ, {FORCE_ENV_VAR: "1"}, clear=True):
            relax_workspace_pin(repo, STABLE)
            pin_recipe_to_candidate(repo, CANDIDATE)
        self.assertIn(
            f'mojo = ">{PINNED_MOJO},<2"',
            (repo / "pixi.toml").read_text(encoding="utf-8"),
        )


class WorkspacePinTests(CanaryTestCase):
    """Relaxing the pin is what makes a newer candidate reachable at all."""

    def test_it_reads_this_repositorys_pin(self) -> None:
        self.assertEqual(workspace_pin(REPO_ROOT), PINNED_MOJO)

    def test_it_rewrites_the_operator_and_nothing_else(self) -> None:
        repo = _copy_repo(self.root)
        before = (repo / "pixi.toml").read_text(encoding="utf-8")
        relax_workspace_pin(repo, STABLE)
        after = (repo / "pixi.toml").read_text(encoding="utf-8")
        self.assertEqual(
            after,
            before.replace(
                f'mojo = "=={PINNED_MOJO},<2"', f'mojo = ">{PINNED_MOJO},<2"'
            ),
        )
        self.assertNotEqual(after, before)

    def test_the_relaxed_pin_reads_back(self) -> None:
        repo = _copy_repo(self.root)
        relax_workspace_pin(repo, STABLE)
        self.assertEqual(workspace_pin(repo), PINNED_MOJO)

    def test_it_refuses_an_already_relaxed_pin(self) -> None:
        repo = _copy_repo(self.root)
        relax_workspace_pin(repo, STABLE)
        with self.assertRaises(ToolchainError):
            relax_workspace_pin(repo, STABLE)

    def test_it_refuses_a_manifest_with_two_mojo_specs(self) -> None:
        repo = _copy_repo(self.root)
        path = repo / "pixi.toml"
        text = path.read_text(encoding="utf-8")
        path.write_text(
            text.replace(
                f'mojo = "=={PINNED_MOJO},<2"',
                f'mojo = "=={PINNED_MOJO},<2"\nmojo = "=={PINNED_MOJO},<2"',
            ),
            encoding="utf-8",
        )
        with self.assertRaises(ToolchainError):
            relax_workspace_pin(repo, STABLE)

    def test_the_stable_lane_leaves_the_channels_alone(self) -> None:
        repo = _copy_repo(self.root)
        relax_workspace_pin(repo, STABLE)
        self.assertNotIn(
            NIGHTLY_CHANNEL, (repo / "pixi.toml").read_text(encoding="utf-8")
        )

    def test_the_nightly_lane_prepends_its_channel(self) -> None:
        repo = _copy_repo(self.root)
        relax_workspace_pin(repo, NIGHTLY)
        text = (repo / "pixi.toml").read_text(encoding="utf-8")
        self.assertIn(f'channels = ["{NIGHTLY_CHANNEL}", ', text)
        self.assertIn(f'mojo = ">{PINNED_MOJO},<2"', text)

    def test_it_refuses_an_unknown_lane(self) -> None:
        repo = _copy_repo(self.root)
        with self.assertRaises(ToolchainError):
            relax_workspace_pin(repo, "weekly")


class RecipePinTests(CanaryTestCase):
    """All three compiler pins move together or the packaging leg proves nothing."""

    def _recipe(self, repo: Path) -> str:
        return (repo / "recipe" / "recipe.yaml").read_text(encoding="utf-8")

    def _rewrite(self, repo: Path, before: str, after: str, count: int = -1) -> None:
        path = repo / "recipe" / "recipe.yaml"
        text = path.read_text(encoding="utf-8")
        replaced = (
            text.replace(before, after)
            if count < 0
            else text.replace(before, after, count)
        )
        self.assertNotEqual(replaced, text)
        path.write_text(replaced, encoding="utf-8")

    def test_the_checked_in_recipe_pins_three_times(self) -> None:
        text = (REPO_ROOT / "recipe" / "recipe.yaml").read_text(encoding="utf-8")
        self.assertEqual(text.count(f"    - mojo =={PINNED_MOJO}\n"), 1)
        self.assertEqual(text.count(f"    - mojo-compiler =={PINNED_MOJO}\n"), 2)

    def test_it_moves_all_three_pins(self) -> None:
        repo = _copy_repo(self.root)
        pin_recipe_to_candidate(repo, CANDIDATE)
        text = self._recipe(repo)
        self.assertEqual(text.count(f"    - mojo =={CANDIDATE.version}\n"), 1)
        self.assertEqual(text.count(f"    - mojo-compiler =={CANDIDATE.version}\n"), 2)
        self.assertEqual(text.count(f"    - mojo =={PINNED_MOJO}\n"), 0)
        self.assertEqual(text.count(f"    - mojo-compiler =={PINNED_MOJO}\n"), 0)

    def test_it_leaves_every_other_line_alone(self) -> None:
        repo = _copy_repo(self.root)
        before = self._recipe(repo)
        pin_recipe_to_candidate(repo, CANDIDATE)
        self.assertEqual(
            self._recipe(repo),
            before.replace(
                f"    - mojo =={PINNED_MOJO}\n",
                f"    - mojo =={CANDIDATE.version}\n",
            ).replace(
                f"    - mojo-compiler =={PINNED_MOJO}\n",
                f"    - mojo-compiler =={CANDIDATE.version}\n",
            ),
        )

    def test_one_pin_already_at_the_candidate_raises(self) -> None:
        repo = _copy_repo(self.root)
        # The host pin only: `replace(..., 1)` reaches the first of the two
        # `mojo-compiler` lines, which is the host requirement.
        self._rewrite(
            repo,
            f"    - mojo-compiler =={PINNED_MOJO}\n",
            f"    - mojo-compiler =={CANDIDATE.version}\n",
            count=1,
        )
        with self.assertRaises(ToolchainError) as raised:
            pin_recipe_to_candidate(repo, CANDIDATE)
        self.assertIn(CANDIDATE.version, str(raised.exception))

    def test_a_recipe_already_fully_retargeted_raises(self) -> None:
        repo = _copy_repo(self.root)
        pin_recipe_to_candidate(repo, CANDIDATE)
        with self.assertRaises(ToolchainError):
            pin_recipe_to_candidate(repo, CANDIDATE)

    def test_a_missing_build_pin_raises(self) -> None:
        repo = _copy_repo(self.root)
        self._rewrite(repo, f"    - mojo =={PINNED_MOJO}\n", "", count=1)
        with self.assertRaises(ToolchainError) as raised:
            pin_recipe_to_candidate(repo, CANDIDATE)
        self.assertIn("build", str(raised.exception))


class ResolvedToolchainTests(CanaryTestCase):
    """One regex reads `mojo --version`, and it is the generator's."""

    def test_the_generator_owns_the_only_pattern(self) -> None:
        # Two spellings of "what a toolchain identity looks like" would let the
        # module that writes transcript headers and the module that reads them
        # back disagree, so the resolver borrows the generator's pattern rather
        # than compiling one of its own.
        source = inspect.getsource(toolchain)
        self.assertIn("from scripts.gen_transcripts import MOJO_VERSION_RE", source)
        self.assertNotIn("Mojo (", source)
        banner = GENERATOR_VERSION_RE.search("Mojo 1.0.0b3 (cafef00d)")
        self.assertIsNotNone(banner)
        self.assertEqual(
            banner.groups() if banner else (),
            (CANDIDATE.version, CANDIDATE.commit),
        )

    def test_it_reaches_the_toolchain_through_pixi(self) -> None:
        """A bare `mojo` would not be on PATH at the moment this is called.

        The probe runs on the runner's own interpreter with nothing provisioned
        but the pixi binary, and it must stay that way: an environment installed
        before `relax_workspace_pin` rewrites the spec resolves the committed
        pin, and the canary then reports "nothing newer" every day forever while
        every job stays green.
        """
        repo = _copy_repo(self.root)
        completed = mock.Mock(stdout="Mojo 1.0.0b3 (cafef00d)\n")
        with mock.patch("subprocess.run", return_value=completed) as spawned:
            resolved_toolchain(repo)
        self.assertEqual(
            list(spawned.call_args.args[0]), ["pixi", "run", "mojo-version"]
        )
        self.assertEqual(RESOLVE_ARGV, ("pixi", "run", "mojo-version"))

    def test_it_asks_the_checkout_it_was_given(self) -> None:
        """Every other outward call is bound to the probed checkout; so is this.

        Spawned without a working directory, this asked whichever workspace
        the probe happened to be launched from. `--repo /tmp/mtest-copy` then
        relaxed and installed over there and asked THIS checkout what it had
        resolved, was told the pinned version, and reported
        `NO_NEWER_CANDIDATE` on a day with a candidate.
        """
        repo = _copy_repo(self.root)
        completed = mock.Mock(stdout="Mojo 1.0.0b3 (cafef00d)\n")
        with mock.patch("subprocess.run", return_value=completed) as spawned:
            resolved_toolchain(repo)
        self.assertEqual(spawned.call_args.kwargs["cwd"], repo)

    def test_the_pipeline_resolves_against_the_checkout_it_probed(self) -> None:
        repo, runner = self.build()
        asked: list[Path] = []

        def resolve(where: Path) -> ResolvedToolchain:
            asked.append(where)
            return CANDIDATE

        classify(repo, STABLE, run=runner, resolve=resolve)
        self.assertEqual(asked, [repo])

    def test_the_manifest_owns_the_task_the_resolver_runs(self) -> None:
        """Renaming the task would leave the canary asking for nothing."""
        manifest = (REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        self.assertIn('mojo-version = "mojo --version"\n', manifest)

    def test_it_parses_a_version_banner(self) -> None:
        completed = mock.Mock(stdout="Mojo 1.0.0b3 (cafef00d)\n")
        with mock.patch("subprocess.run", return_value=completed):
            self.assertEqual(resolved_toolchain(self.root), CANDIDATE)

    def test_it_refuses_an_unreadable_banner(self) -> None:
        completed = mock.Mock(stdout="mojo, but who knows which\n")
        with (
            mock.patch("subprocess.run", return_value=completed),
            self.assertRaises(ToolchainError),
        ):
            resolved_toolchain(self.root)


class DiagnosticTests(CanaryTestCase):
    """A red compile reports the compiler's own words, not the harness's."""

    def test_it_returns_the_first_error_line_verbatim(self) -> None:
        stderr = (
            "note: building src/main.mojo\n"
            "/repo/src/mtest/cli/parse.mojo:412:9: error: 'String' value has no "
            "attribute '__len__'\n"
            "/repo/src/mtest/cli/parse.mojo:988:1: error: cascading failure\n"
        )
        result = CommandResult(("pixi", "run", "build-bin"), 1, "", stderr)
        self.assertEqual(
            first_diagnostic(result),
            "/repo/src/mtest/cli/parse.mojo:412:9: error: 'String' value has no "
            "attribute '__len__'",
        )

    def test_a_failure_without_a_diagnostic_names_the_command(self) -> None:
        result = CommandResult(("pixi", "run", "test-unit"), 3, "", "killed\n")
        detail = first_diagnostic(result)
        self.assertIn("pixi run test-unit", detail)
        self.assertIn("3", detail)
        self.assertIn("killed", detail)


class E2eGuardTests(CanaryTestCase):
    """Expected failures stay a named, non-empty set, or they are failures."""

    def test_the_tolerated_scenarios_are_registered_and_exhaustive(self) -> None:
        """Only the two scenarios a moved toolchain really breaks are tolerated.

        Each of the other five was read against `scripts/e2e/scenarios/doctor.py`
        and fails for reasons a candidate toolchain cannot supply:
        `doctor-malformed-config` and `doctor-missing-config` assert
        `FAIL toolchain: dependency config unavailable`, which is reached
        before any toolchain is probed; `doctor-missing-toolchain` points
        `MTEST_MOJO` at fake executables and asserts the identity compiled into
        the sources; `doctor-unwritable-state` asserts `FAIL state` and
        `PASS temp` and admits any status on the toolchain line; and
        `doctor-interrupt` asserts exit 2 from a deliberately slow fake probe.
        Tolerating those by prefix meant a candidate that miscompiled the state
        probe was reported as `PASS` and closed the lane's issue.
        """
        self.assertEqual(
            [name for name, _scenario in SCENARIOS if name.startswith("doctor-")],
            [
                "doctor-healthy",
                "doctor-malformed-config",
                "doctor-missing-config",
                "doctor-missing-toolchain",
                "doctor-unwritable-state",
                "doctor-interrupt",
                "doctor-config-free",
            ],
        )
        self.assertEqual(
            sorted(TOLERATED_E2E_SCENARIOS),
            ["doctor-config-free", "doctor-healthy"],
        )

    def test_the_untolerated_doctor_scenarios_condemn(self) -> None:
        for name in (
            "doctor-malformed-config",
            "doctor-missing-config",
            "doctor-missing-toolchain",
            "doctor-unwritable-state",
            "doctor-interrupt",
        ):
            with self.subTest(scenario=name):
                verdict = e2e_failure_verdict((name,), toolchain_moved=True)
                self.assertIsNotNone(verdict)
                self.assertIn(name, str(verdict))

    def test_it_reads_the_gates_failure_lines(self) -> None:
        stdout = (
            "=== mtest end-to-end gate ===\n"
            "\n=== 219/221 scenarios passed ===\n"
            "FAILED: doctor-healthy\n"
            "  stdout did not name the resolved toolchain\n"
            "FAILED: doctor-missing-toolchain\n"
            "  exit 2 != 0\n"
        )
        self.assertEqual(
            failed_scenarios(stdout), ("doctor-healthy", "doctor-missing-toolchain")
        )

    def test_doctor_failures_are_tolerated_when_the_toolchain_moved(self) -> None:
        self.assertIsNone(
            e2e_failure_verdict(("doctor-healthy",), toolchain_moved=True)
        )

    def test_doctor_failures_condemn_an_unmoved_toolchain(self) -> None:
        verdict = e2e_failure_verdict(("doctor-healthy",), toolchain_moved=False)
        self.assertIsNotNone(verdict)
        self.assertIn("doctor-healthy", str(verdict))

    def test_any_other_failure_condemns(self) -> None:
        verdict = e2e_failure_verdict(
            ("doctor-healthy", "parallel-interrupt"), toolchain_moved=True
        )
        self.assertIsNotNone(verdict)
        self.assertIn("parallel-interrupt", str(verdict))
        self.assertNotIn("doctor-healthy", str(verdict))

    def test_an_empty_expected_set_condemns(self) -> None:
        verdict = e2e_failure_verdict((), toolchain_moved=True)
        self.assertIsNotNone(verdict)


class ChannelSearchTests(CanaryTestCase):
    """Reading what a channel publishes, in conda's ordering rather than ours."""

    def test_it_reads_versions_newest_first(self) -> None:
        # Trimmed from a real `pixi search --json` answer. The ordering is
        # pixi's, and it is the reason the versions are never compared here:
        # 1.0.0rc0 outranks 1.0.0b3.dev2026080406, which no lexical or
        # dotted-numeric comparison gets right.
        answer = CommandResult(
            ("pixi", "search", "--json", "mojo"),
            0,
            json.dumps(
                {
                    "linux-64": [
                        {"name": "mojo", "version": "1.0.0rc0"},
                        {"name": "mojo", "version": "1.0.0b3.dev2026080406"},
                    ],
                    "osx-arm64": [
                        {"name": "mojo", "version": "1.0.0rc0"},
                        {"name": "mojo", "version": "1.0.0b3.dev2026080406"},
                    ],
                }
            ),
            "",
        )
        self.assertEqual(search_versions(answer), ("1.0.0rc0", "1.0.0b3.dev2026080406"))

    def test_an_empty_answer_offers_nothing(self) -> None:
        answer = CommandResult(("pixi", "search"), 0, json.dumps({"linux-64": []}), "")
        self.assertEqual(search_versions(answer), ())

    def test_it_refuses_output_that_is_not_json(self) -> None:
        answer = CommandResult(("pixi", "search"), 0, "No packages found\n", "")
        with self.assertRaises(ValueError):
            search_versions(answer)

    def test_it_refuses_records_without_a_version(self) -> None:
        answer = CommandResult(
            ("pixi", "search"), 0, json.dumps({"linux-64": [{"name": "mojo"}]}), ""
        )
        with self.assertRaises(ValueError):
            search_versions(answer)

    def test_the_command_names_every_channel(self) -> None:
        self.assertEqual(
            search_argv(("one", "two"), "mojo >1.0.0b2,<2"),
            ("pixi", "search", "--json", "-c", "one", "-c", "two", "mojo >1.0.0b2,<2"),
        )

    def test_this_repository_resolves_against_two_channels(self) -> None:
        # Independently transcribed from pixi.toml.
        self.assertEqual(
            workspace_channels(REPO_ROOT),
            ("https://conda.modular.com/max/", "conda-forge"),
        )

    def test_the_nightly_lane_searches_its_channel_first(self) -> None:
        self.assertEqual(
            candidate_channels(REPO_ROOT, NIGHTLY),
            (NIGHTLY_CHANNEL, "https://conda.modular.com/max/", "conda-forge"),
        )
        self.assertEqual(
            candidate_channels(REPO_ROOT, STABLE), workspace_channels(REPO_ROOT)
        )

    def test_the_control_differs_by_one_operator(self) -> None:
        # The corroboration is only worth anything if the control is the same
        # question: same package, same version literal, same bound, same argv
        # shape. One operator apart is the whole difference.
        self.assertEqual(candidate_matchspec(PINNED_MOJO), f"mojo >{PINNED_MOJO},<2")
        self.assertEqual(floor_matchspec(PINNED_MOJO), f"mojo >={PINNED_MOJO},<2")
        self.assertEqual(
            floor_matchspec(PINNED_MOJO).replace(">=", ">"),
            candidate_matchspec(PINNED_MOJO),
        )

    def test_a_control_naming_the_pin_confirms_the_channels(self) -> None:
        answer = CommandResult(("pixi", "search"), 0, _search_answer(PINNED_MOJO), "")
        self.assertTrue(control_confirms_channels(answer, PINNED_MOJO))

    def test_a_failed_or_silent_control_confirms_nothing(self) -> None:
        for answer in (
            CommandResult(("pixi", "search"), 1, "", "boom"),
            CommandResult(("pixi", "search"), 0, _search_answer(), ""),
            CommandResult(("pixi", "search"), 0, "not json", ""),
            CommandResult(("pixi", "search"), 0, _search_answer("0.26.2.0"), ""),
        ):
            with self.subTest(returncode=answer.returncode, stdout=answer.stdout):
                self.assertFalse(control_confirms_channels(answer, PINNED_MOJO))

    def test_the_searched_spec_is_the_one_the_manifest_gets(self) -> None:
        # The screen would be worthless if it asked a different question than
        # the solver is later handed.
        repo, runner = self.build()
        self.classify(repo, runner)
        search = next(
            call for call in runner.calls if _stage_of(call) == "search-candidates"
        )
        self.assertEqual(search[-1], candidate_matchspec(PINNED_MOJO))
        self.assertIn(
            f'mojo = "{relaxed_spec(PINNED_MOJO)}"',
            (repo / "pixi.toml").read_text(encoding="utf-8"),
        )

    def test_the_search_asks_the_lanes_channels(self) -> None:
        repo, runner = self.build()
        self.classify(repo, runner, lane=NIGHTLY)
        for stage in ("search-published", "search-candidates"):
            call = next(c for c in runner.calls if _stage_of(c) == stage)
            self.assertEqual(
                [call[index + 1] for index, part in enumerate(call) if part == "-c"],
                list(candidate_channels(REPO_ROOT, NIGHTLY)),
            )


class IdleLaneTests(CanaryTestCase):
    """A channel with nothing newer is an idle lane, never a broken one."""

    def _idle_stable_channel(self, runner: FakeRunner) -> None:
        """Make the channels look the way the stable channel looks today."""
        runner.outcomes(
            "search-published", _Outcome(0, _search_answer(PINNED_MOJO), "")
        )
        # Verbatim from `pixi search --json -c .../max/ -c conda-forge
        # 'mojo >1.0.0b2,<2'`: exit 1, nothing on stdout, the refusal on
        # stderr. An unreachable channel exits 1 with an empty stdout too,
        # which is exactly why the exit code cannot be read on its own.
        runner.outcomes(
            "search-candidates",
            _Outcome(
                1,
                "",
                f"Error:   \u00d7 No packages found matching "
                f"'mojo >{PINNED_MOJO},<2'\n",
            ),
        )

    def test_an_unsatisfiable_spec_is_no_newer_candidate(self) -> None:
        # The stable channel's state today: the pinned version is also the
        # newest published, so `>pin,<2` matches nothing and pixi says so by
        # failing. The control answers, so the failure is an empty match set.
        repo, runner = self.build()
        self._idle_stable_channel(runner)
        runner.outcomes("search-control", _Outcome(0, _search_answer(PINNED_MOJO), ""))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, NO_NEWER_CANDIDATE)
        self.assertEqual(result.version, PINNED_MOJO)
        self.assertEqual(
            runner.stages,
            ["search-published", "search-candidates", "search-control"],
        )

    def test_a_bounded_search_that_cannot_be_corroborated_is_infra(self) -> None:
        # The defect this guards: a failure specific to the bounded argv — a
        # rejected matchspec spelling, a channel that vanished between the two
        # calls — read as "nothing newer" would silence both lanes for good.
        repo, runner = self.build()
        self._idle_stable_channel(runner)
        runner.fails(
            "search-control", stderr="error: invalid version spec '>=1.0.0b2,<2'\n"
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, INFRA_FAILURE)
        self.assertIn(candidate_matchspec(PINNED_MOJO), result.detail)
        self.assertEqual(
            runner.stages,
            ["search-published", "search-candidates", "search-control"],
        )

    def test_a_control_that_cannot_see_the_pin_is_infra(self) -> None:
        # The channels answered, but not with the version this repository is
        # built against. Whatever that is, it is not evidence that nothing
        # newer exists.
        repo, runner = self.build()
        self._idle_stable_channel(runner)
        runner.outcomes("search-control", _Outcome(0, _search_answer(), ""))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, INFRA_FAILURE)

    def test_a_control_that_does_not_parse_is_infra(self) -> None:
        repo, runner = self.build()
        self._idle_stable_channel(runner)
        runner.outcomes("search-control", _Outcome(0, "No packages found\n", ""))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, INFRA_FAILURE)

    def test_an_empty_match_set_needs_no_control(self) -> None:
        # A search that answered, with nothing in the answer, is already the
        # evidence; there is nothing left for the control to corroborate.
        repo, runner = self.build()
        runner.outcomes(
            "search-published", _Outcome(0, _search_answer(PINNED_MOJO), "")
        )
        runner.outcomes("search-candidates", _Outcome(0, _search_answer(), ""))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, NO_NEWER_CANDIDATE)
        self.assertEqual(runner.stages, ["search-published", "search-candidates"])

    def test_the_detail_names_the_channel_and_the_newest_release(self) -> None:
        repo, runner = self.build()
        runner.outcomes(
            "search-published", _Outcome(0, _search_answer(PINNED_MOJO), "")
        )
        runner.fails("search-candidates")
        result = self.classify(repo, runner)
        self.assertIn("https://conda.modular.com/max/", result.detail)
        self.assertIn(candidate_matchspec(PINNED_MOJO), result.detail)
        self.assertIn(
            f"the newest mojo published there is {PINNED_MOJO}", result.detail
        )

    def test_an_idle_lane_leaves_the_checkout_untouched(self) -> None:
        repo, runner = self.build()
        pixi_before = (repo / "pixi.toml").read_text(encoding="utf-8")
        recipe_before = (repo / "recipe" / "recipe.yaml").read_text(encoding="utf-8")
        runner.fails("search-candidates")
        self.classify(repo, runner)
        self.assertEqual((repo / "pixi.toml").read_text(encoding="utf-8"), pixi_before)
        self.assertEqual(
            (repo / "recipe" / "recipe.yaml").read_text(encoding="utf-8"),
            recipe_before,
        )

    def test_unreadable_channels_stay_infra_failure(self) -> None:
        # The other side of the discrimination: a channel that cannot be read
        # says nothing about whether a candidate exists.
        repo, runner = self.build()
        runner.fails(
            "search-published",
            stderr="could not find subdir 'noarch' in channel (404 Not Found)\n",
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, INFRA_FAILURE)
        self.assertIn("404 Not Found", result.detail)
        self.assertEqual(runner.stages, ["search-published"])

    def test_a_published_search_that_cannot_see_the_pin_is_infra(self) -> None:
        # The two searches are held to one bar. Accepting the unbounded one on
        # exit 0 and parseable JSON alone let an answer that names no mojo at
        # all — the wrong channels, an index that lost the package — wave the
        # pipeline through to a bounded search that also came back empty, and
        # the lane reported a quiet NO_NEWER_CANDIDATE without ever consulting
        # the control that exists to catch exactly this.
        repo, runner = self.build()
        for answer in (_search_answer(), _search_answer("0.26.2.0")):
            with self.subTest(answer=answer):
                runner = FakeRunner(repo)
                runner.outcomes("search-published", _Outcome(0, answer, ""))
                result = self.classify(repo, runner)
                self.assertEqual(result.classification, INFRA_FAILURE)
                self.assertIn(PINNED_MOJO, result.detail)
                self.assertEqual(runner.stages, ["search-published"])

    def test_an_unreadable_answer_stays_infra_failure(self) -> None:
        repo, runner = self.build()
        runner.outcomes("search-published", _Outcome(0, "not json at all", ""))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, INFRA_FAILURE)


class StageBudgetTests(CanaryTestCase):
    """The stage budget has to fit inside the job that hosts it."""

    @staticmethod
    def _probe_job_timeout_minutes() -> int:
        """Read the probe job's own budget out of the workflow."""
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "compat-canary.yml"
        ).read_text(encoding="utf-8")
        probe = workflow.split("\n  notify:", 1)[0].split("\n  probe:", 1)[1]
        found = re.findall(r"^    timeout-minutes: (\d+)$", probe, re.MULTILINE)
        if len(found) != 1:
            raise AssertionError(
                f"the probe job names {len(found)} timeouts; exactly one is "
                "required to bound the stage budget against"
            )
        return int(found[0])

    def test_the_workflow_still_bounds_the_probe(self) -> None:
        # Independently transcribed from the workflow.
        self.assertEqual(self._probe_job_timeout_minutes(), 60)

    def test_the_stage_budget_leaves_headroom_inside_the_job(self) -> None:
        """The arithmetic is necessary for a wedged stage to report; not sufficient.

        A stage reaches its own timeout `STAGE_TIMEOUT_SECONDS` after IT
        started, not after the job did, so this identity only guarantees a
        reported classification when the wedged stage is the first thing the
        job runs. Wedged after half an hour of cold-cache building, the stage
        timeout falls past the job's cancellation and the day produces a
        cancelled job with no artifact — which the notifier reports as a
        missing result, loudly, which is why this stays a budget assertion
        rather than a mechanism.
        """
        job_budget = self._probe_job_timeout_minutes() * 60
        self.assertLessEqual(
            STAGE_TIMEOUT_SECONDS + JOB_TIMEOUT_HEADROOM_SECONDS, job_budget
        )
        self.assertGreaterEqual(JOB_TIMEOUT_HEADROOM_SECONDS, 600)

    def test_a_wedged_stage_is_named_a_timeout_not_a_verdict(self) -> None:
        # 124 is the probe killing a stage that outlived its budget, not the
        # stage answering. Mapped onto the stage's ordinary failure, three
        # quarters of an hour of silence on an unwarmed cache was reported as
        # "the sources no longer compile" with only the detail string saying
        # otherwise.
        for stage in ("build-bin", "test-unit", "contract-check-strict", "e2e"):
            with self.subTest(stage=stage):
                repo, runner = self.build()
                runner.outcomes(
                    stage,
                    _Outcome(
                        TIMEOUT_RETURNCODE,
                        "",
                        f"timed out after {STAGE_TIMEOUT_SECONDS:.0f}s",
                    ),
                )
                result = self.classify(repo, runner)
                self.assertEqual(result.classification, STAGE_TIMEOUT)
                self.assertIn("timed out", result.detail)
                self.assertIn(stage, result.detail)

    def test_a_wedged_install_is_not_retried_into_a_second_budget(self) -> None:
        repo, runner = self.build()
        runner.outcomes("install", _Outcome(TIMEOUT_RETURNCODE, "", "timed out"))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, STAGE_TIMEOUT)
        self.assertEqual(runner.stages.count("install"), 1)

    def test_a_wedged_search_is_a_timeout(self) -> None:
        repo, runner = self.build()
        runner.outcomes(
            "search-published", _Outcome(TIMEOUT_RETURNCODE, "", "timed out")
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, STAGE_TIMEOUT)


class PipelineOrderingTests(CanaryTestCase):
    """The install must see the relaxed pin, or the canary is permanently green."""

    def test_install_observes_the_rewritten_spec(self) -> None:
        repo, runner = self.build()
        self.classify(repo, runner)
        self.assertEqual(len(runner.pixi_toml_seen_by_install), 1)
        self.assertIn(
            f'mojo = ">{PINNED_MOJO},<2"', runner.pixi_toml_seen_by_install[0]
        )
        self.assertNotIn(
            f'mojo = "=={PINNED_MOJO},<2"', runner.pixi_toml_seen_by_install[0]
        )

    def test_the_stages_run_in_the_documented_order(self) -> None:
        repo, runner = self.build()
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, PASS, result.detail)
        self.assertEqual(
            runner.stages,
            [
                "search-published",
                "search-candidates",
                "install",
                "build-bin",
                "test-unit",
                "contract-check-strict",
                "transcripts",
                "package-check",
                "cross-compile",
                "e2e",
            ],
        )


class StageClassificationTests(CanaryTestCase):
    """Each stage's failure has exactly one name, and it stops the pipeline."""

    def test_an_unsatisfiable_solve_is_a_finding_about_the_candidate(self) -> None:
        """A solve that reached the index and failed is news about the candidate.

        `pixi.toml` declares two platforms and fixes python and clang, while
        the search that waved this day through is satisfied by a candidate
        published for either platform. A candidate whose dependencies cannot
        sit beside those pins therefore fails here — every weekday, for as long
        as it is the newest release. Called INFRA_FAILURE, that wrote no issue,
        left no comment, and exited 0: a lane that had learned something real
        about the candidate reported a green run instead, forever.
        """
        repo, runner = self.build()
        runner.fails(
            "install",
            stderr="× cannot solve the request: mojo 1.0.0rc0 needs python 3.13\n",
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertIn("needs python 3.13", result.detail)
        self.assertIn(floor_matchspec(PINNED_MOJO), result.detail)
        self.assertEqual(
            runner.stages,
            [
                "search-published",
                "search-candidates",
                "install",
                "install",
                "search-control",
            ],
        )

    def test_an_uncorroborated_install_failure_is_infra(self) -> None:
        # The other side of that discrimination: a probe that has lost its
        # reach cannot tell an unsatisfiable solve from an unreachable index,
        # so it claims neither.
        repo, runner = self.build()
        runner.fails("install", stderr="failed to fetch repodata\n")
        runner.fails("search-control", stderr="error sending request\n")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, INFRA_FAILURE)
        self.assertIn("failed to fetch repodata", result.detail)

    def test_the_retry_waits_before_asking_again(self) -> None:
        # An immediate repeat meets the same outage microseconds later, so the
        # retry bought nothing it was added for.
        repo, runner = self.build()
        runner.outcomes("install", _Outcome(1, "", "network"), _Outcome(0, "", ""))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, PASS, result.detail)
        self.assertEqual(runner.stages.count("install"), 2)
        # Independently transcribed from the constant's documented value.
        self.assertEqual(self.slept, [30.0])

    def test_a_killed_install_is_not_slept_on(self) -> None:
        repo, runner = self.build()
        runner.outcomes("install", _Outcome(TIMEOUT_RETURNCODE, "", "timed out"))
        self.classify(repo, runner)
        self.assertEqual(self.slept, [])

    def test_the_pinned_toolchain_is_no_newer_candidate(self) -> None:
        repo, runner = self.build()
        result = self.classify(
            repo, runner, resolved=ResolvedToolchain(PINNED_MOJO, "2cf4d08a")
        )
        self.assertEqual(result.classification, NO_NEWER_CANDIDATE)
        self.assertEqual(result.version, PINNED_MOJO)
        self.assertEqual(
            runner.stages, ["search-published", "search-candidates", "install"]
        )
        self.assertIn(
            f"    - mojo =={PINNED_MOJO}\n",
            (repo / "recipe" / "recipe.yaml").read_text(encoding="utf-8"),
        )

    def test_a_failing_build_is_source_incompatible(self) -> None:
        repo, runner = self.build()
        runner.fails(
            "build-bin", stderr="/repo/src/main.mojo:9:1: error: unknown decorator\n"
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertEqual(
            result.detail, "/repo/src/main.mojo:9:1: error: unknown decorator"
        )
        self.assertEqual(
            runner.stages,
            ["search-published", "search-candidates", "install", "build-bin"],
        )

    def test_a_failing_unit_lane_is_source_incompatible(self) -> None:
        repo, runner = self.build()
        runner.fails("test-unit")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertEqual(
            runner.stages,
            [
                "search-published",
                "search-candidates",
                "install",
                "build-bin",
                "test-unit",
            ],
        )

    def test_a_failing_contract_check_is_source_incompatible(self) -> None:
        repo, runner = self.build()
        runner.fails("contract-check-strict")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertNotIn("transcripts", runner.stages)

    def test_moved_transcripts_are_protocol_drift(self) -> None:
        repo, runner = self.build("drifted_stdout")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, PROTOCOL_DRIFT)
        self.assertIn("passing--default.txt", result.detail)
        self.assertNotIn("package-check", runner.stages)

    def test_a_failed_structural_pin_is_protocol_drift(self) -> None:
        # The generator's own pins — the emitted name set, and two generations
        # that agree byte for byte — are protocol assertions in their own
        # right, so failing one of them is drift even though no transcript was
        # ever compared.
        repo, runner = self.build()
        runner.outcomes(
            "transcripts",
            _Outcome(
                2,
                "",
                "gen_transcripts: STRUCTURAL PIN FAILED: non-deterministic "
                "transcript on regeneration: passing--default.txt\n",
            ),
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, PROTOCOL_DRIFT)
        self.assertIn("non-deterministic transcript", result.detail)

    def test_the_generator_still_reports_its_pins_the_way_this_reads(self) -> None:
        """A generator that changed how it reports would silently widen this.

        Every non-pin failure below is read as a fact about the candidate, so
        if the marker or the exit code moved, a real protocol pin would arrive
        under the wrong name with nothing to notice it.
        """
        source = inspect.getsource(gen_transcripts)
        self.assertIn('f"gen_transcripts: STRUCTURAL PIN FAILED: {e}"', source)
        self.assertIn("sys.exit(2)", source)

    def test_a_fixture_the_candidate_refuses_is_source_incompatible(self) -> None:
        # A compiler that rejects the syntax in a protocol fixture is not a
        # report format that moved; nothing was generated to compare.
        repo, runner = self.build()
        runner.fails(
            "transcripts",
            stderr="/repo/e2e/fixtures/passing.mojo:3:1: error: unknown attribute\n",
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertEqual(
            result.detail, "/repo/e2e/fixtures/passing.mojo:3:1: error: unknown attribute"
        )

    def test_an_unattributed_generator_death_is_not_called_drift(self) -> None:
        repo, runner = self.build()
        runner.fails(
            "transcripts",
            stderr="Traceback (most recent call last):\n"
            "OSError: [Errno 28] No space left on device\n",
        )
        result = self.classify(repo, runner)
        self.assertNotEqual(result.classification, PROTOCOL_DRIFT)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertIn("No space left on device", result.detail)

    def test_a_wedged_generator_is_a_timeout(self) -> None:
        repo, runner = self.build()
        runner.outcomes(
            "transcripts", _Outcome(TIMEOUT_RETURNCODE, "", "timed out after 2700s")
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, STAGE_TIMEOUT)

    def test_the_generator_writes_outside_the_committed_snapshots(self) -> None:
        repo, runner = self.build()
        self.classify(repo, runner)
        generate = next(
            call for call in runner.calls if _stage_of(call) == "transcripts"
        )
        out = Path(generate[generate.index("--out") + 1])
        self.assertFalse(
            out.is_relative_to(repo), f"{out} would overwrite the committed baseline"
        )

    def test_a_failing_package_check_is_package_failed(self) -> None:
        repo, runner = self.build()
        runner.fails("package-check", stderr="install did NOT pull mojo-compiler\n")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, PACKAGE_FAILED)
        self.assertIn("install did NOT pull mojo-compiler", result.detail)

    def test_the_package_check_expects_the_candidate(self) -> None:
        repo, runner = self.build()
        self.classify(repo, runner)
        self.assertIn(
            (
                "pixi",
                "run",
                "package-check",
                "--expect-mojo-version",
                CANDIDATE.version,
            ),
            runner.calls,
        )

    def test_a_failing_cross_compile_is_source_incompatible(self) -> None:
        repo, runner = self.build()
        runner.fails(
            "cross-compile",
            stderr="/repo/src/mtest/session/exec.mojo:77:5: error: no matching call\n",
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertEqual(
            result.detail,
            "/repo/src/mtest/session/exec.mojo:77:5: error: no matching call",
        )

    def test_the_cross_compile_targets_darwin_without_linking(self) -> None:
        self.assertEqual(
            MACOS_CROSS_COMPILE,
            (
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
            ),
        )

    def test_doctor_only_e2e_failures_still_pass(self) -> None:
        repo, runner = self.build()
        runner.fails("e2e", stdout="FAILED: doctor-healthy\n  toolchain moved\n")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, PASS)
        self.assertIn("doctor-healthy", result.detail)

    def test_another_e2e_failure_is_source_incompatible(self) -> None:
        repo, runner = self.build()
        runner.fails(
            "e2e", stdout="FAILED: doctor-healthy\nFAILED: parallel-interrupt\n"
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertIn("parallel-interrupt", result.detail)

    def test_an_unattributed_e2e_failure_is_source_incompatible(self) -> None:
        repo, runner = self.build()
        runner.fails("e2e", stdout="=== 0/221 scenarios passed ===\n")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)

    def test_a_clean_probe_passes(self) -> None:
        repo, runner = self.build()
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, PASS, result.detail)
        self.assertEqual(result.version, CANDIDATE.version)
        self.assertEqual(result.commit, CANDIDATE.commit)
        self.assertEqual(result.lane, STABLE)


class NightlyLaneTests(CanaryTestCase):
    """The nightly lane probes source compatibility, never the release package."""

    def test_it_skips_the_packaging_and_darwin_legs(self) -> None:
        repo, runner = self.build()
        result = self.classify(repo, runner, lane=NIGHTLY)
        self.assertEqual(result.classification, PASS, result.detail)
        self.assertEqual(
            runner.stages,
            [
                "search-published",
                "search-candidates",
                "install",
                "build-bin",
                "test-unit",
                "contract-check-strict",
                "transcripts",
                "e2e",
            ],
        )

    def test_it_leaves_the_recipe_pinned(self) -> None:
        repo, runner = self.build()
        self.classify(repo, runner, lane=NIGHTLY)
        self.assertIn(
            f"    - mojo =={PINNED_MOJO}\n",
            (repo / "recipe" / "recipe.yaml").read_text(encoding="utf-8"),
        )


class ArtifactTests(CanaryTestCase):
    """The classification is the product, so it is written down and exits 0."""

    def _run_main(self, result: CanaryResult | Exception) -> tuple[int, Path]:
        repo = _copy_repo(self.root)
        out = self.root / "artifacts"
        side_effect = (
            mock.Mock(side_effect=result)
            if isinstance(result, Exception)
            else mock.Mock(return_value=result)
        )
        with (
            mock.patch("scripts.canary.run.classify", side_effect),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = main(["--lane", STABLE, "--repo", str(repo), "--out", str(out)])
        return code, out

    def test_a_classification_is_written_and_exits_zero(self) -> None:
        code, out = self._run_main(
            CanaryResult(
                lane=STABLE,
                version=CANDIDATE.version,
                commit=CANDIDATE.commit,
                classification=SOURCE_INCOMPATIBLE,
                detail="/repo/src/main.mojo:9:1: error: unknown decorator",
            )
        )
        self.assertEqual(code, 0)
        payload = json.loads((out / "result.json").read_text(encoding="utf-8"))
        self.assertEqual(
            payload,
            {
                "lane": STABLE,
                "version": CANDIDATE.version,
                "commit": CANDIDATE.commit,
                "classification": SOURCE_INCOMPATIBLE,
                "detail": "/repo/src/main.mojo:9:1: error: unknown decorator",
            },
        )
        summary = (out / "summary.md").read_text(encoding="utf-8")
        self.assertIn(SOURCE_INCOMPATIBLE, summary)
        self.assertIn(CANDIDATE.version, summary)

    def test_an_internal_crash_exits_nonzero_with_diagnostics(self) -> None:
        code, out = self._run_main(RuntimeError("the canary itself broke"))
        self.assertNotEqual(code, 0)
        self.assertFalse((out / "result.json").exists())
        diagnostics = (out / "diagnostics.txt").read_text(encoding="utf-8")
        self.assertIn("the canary itself broke", diagnostics)
        self.assertIn("Traceback", diagnostics)


if __name__ == "__main__":
    unittest.main()
