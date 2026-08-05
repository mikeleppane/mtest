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
import subprocess
import sys
import tempfile
import time
from typing import TYPE_CHECKING, override
import unittest
from unittest import mock

from scripts import gen_transcripts
from scripts.canary import run as canary_run
from scripts.canary import toolchain
from scripts.canary.protocol_compare import PASS, PROTOCOL_DRIFT
from scripts.canary.run import (
    CANARY_BROKEN,
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
    contract_verdict,
    control_confirms_channels,
    e2e_failure_verdict,
    failed_scenarios,
    first_diagnostic,
    main,
    search_argv,
    search_newest,
    search_versions,
)
from scripts.canary.toolchain import (
    CI_ENV_VAR,
    FORCE_ENV_VAR,
    NIGHTLY_CHANNEL,
    RESOLVE_ARGV,
    TOLERATED_CONTRACT_FAILURES,
    TOLERATED_E2E_SCENARIOS,
    ResolvedToolchain,
    ToolchainError,
    candidate_channels,
    candidate_matchspec,
    floor_matchspec,
    mutation_permitted,
    parse_toolchain,
    pin_recipe_to_candidate,
    relax_workspace_pin,
    relaxed_spec,
    workspace_channels,
    workspace_pin,
)
from scripts.e2e.__main__ import SCENARIOS
from scripts.e2e.__main__ import main as e2e_main
from scripts.gen_transcripts import MOJO_VERSION_RE as GENERATOR_VERSION_RE
from scripts.qa.contract import EXPECTED_CHECK_NAMES, Runner, build_matrix
from scripts.qa.contract import main as contract_main


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


def _version_banner(resolved: ResolvedToolchain) -> str:
    """Render `mojo --version` the way the toolchain really prints it."""
    return f"Mojo {resolved.version} ({resolved.commit})\n"


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


def _contract_output(
    *failures: tuple[str, str], passed: int = 124, skipped: int = 0
) -> str:
    """Render `contract-check-strict` output the way that gate really prints it.

    Independently transcribed from `scripts/qa/contract.py`'s own format
    strings: one summary line, then a roll-call naming each failing check, its
    contract reference, and the first line of its detail.
    """
    lines = [
        f"\n===== {passed} passed, {len(failures)} failed, {skipped} skipped ====="
    ]
    if failures:
        lines.append("\nFAILURES (contract clauses NOT upheld):")
        lines += [f"  - {name}  (§9/§27): {detail}" for name, detail in failures]
    if skipped:
        lines.append(
            f"\nNOTE: {skipped} check(s) SKIPPED (not a pass). Use --strict to "
            "fail on skip."
        )
    return "\n".join(lines) + "\n"


# What the gate prints on a candidate toolchain when nothing is wrong except
# that the toolchain moved: `mtest doctor` reports `FAIL toolchain` and exits
# 1, and the three checks that invoke it expecting a healthy 0 say so.
_IDENTITY_FAILURES = (
    (
        "pipe: every direct-output command survives a closed stdout",
        "doctor: exit 1, want 0",
    ),
    ("served: doctor --no-cache accepted, inert (not exit 4)", "exit 1, want 0"),
    ("served: doctor --cache-clear accepted, inert (not exit 4)", "exit 1, want 0"),
)


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
            # A green `contract-check-strict` is NOT what an ordinary probe day
            # looks like. `mtest doctor` refuses any toolchain but the pinned
            # one, so on a candidate that gate fails, and fails those three
            # checks. Defaulted to exit 0 here, every pipeline test below ran
            # against a gate whose guard had already stopped guarding, and the
            # suite could not see the day that really happens.
            "contract-check-strict": [
                _Outcome(1, _contract_output(*_IDENTITY_FAILURES), "")
            ],
            "mojo-version": [_Outcome(0, _version_banner(CANDIDATE), "")],
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
        self.enterContext(
            mock.patch("scripts.canary.run.time.sleep", self.slept.append)
        )

    def build(self, fixture: str = "identical_newer") -> tuple[Path, FakeRunner]:
        """Return a throwaway checkout and a runner primed for it."""
        repo = _copy_repo(self.root, fixture)
        return repo, FakeRunner(repo, FIXTURES / fixture / "candidate")

    def classify(
        self,
        repo: Path,
        runner: FakeRunner,
        lane: str = STABLE,
        resolved: ResolvedToolchain | None = None,
    ) -> CanaryResult:
        """Run the pipeline with everything external injected."""
        if resolved is not None:
            runner.outcomes("mojo-version", _Outcome(0, _version_banner(resolved), ""))
        return classify(repo, lane, run=runner)


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
        """A bare `mojo` would not be on PATH at the moment this is asked.

        The probe runs on the runner's own interpreter with nothing provisioned
        but the pixi binary, and it must stay that way: an environment installed
        before `relax_workspace_pin` rewrites the spec resolves the committed
        pin, and the canary then reports "nothing newer" every day forever while
        every job stays green.
        """
        repo, runner = self.build()
        self.classify(repo, runner)
        self.assertIn(("pixi", "run", "mojo-version"), runner.calls)
        # Independently transcribed from the constant's documented value.
        self.assertEqual(RESOLVE_ARGV, ("pixi", "run", "mojo-version"))

    def test_the_resolve_is_supervised_like_every_other_stage(self) -> None:
        """It was the one outward call with no timeout at all.

        Spawned on its own it sat outside the stage budget and outside the
        process-group kill, so a `pixi run mojo-version` that wedged held the
        probe open until the hosting job's own deadline cancelled it — and a
        cancelled job uploads no artifact, so the day ended with nothing said
        about either lane rather than with a classification.
        """
        repo, runner = self.build()
        runner.outcomes("mojo-version", _Outcome(TIMEOUT_RETURNCODE, "", "timed out"))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, STAGE_TIMEOUT, result.detail)
        self.assertIn("mojo-version", result.detail)

    def test_an_environment_that_cannot_name_its_toolchain_is_loud(self) -> None:
        repo, runner = self.build()
        runner.fails("mojo-version", stderr="error: task 'mojo-version' not found\n")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, CANARY_BROKEN, result.detail)
        self.assertIn("could not say which toolchain it holds", result.detail)

    def test_the_pipeline_resolves_against_the_checkout_it_probed(self) -> None:
        """Every outward call is bound to the probed checkout, this one included.

        Spawned without a working directory, this asked whichever workspace
        the probe happened to be launched from. `--repo /tmp/mtest-copy` then
        relaxed and installed over there and asked THIS checkout what it had
        resolved, was told the pinned version, and reported
        `NO_NEWER_CANDIDATE` on a day with a candidate. The binding now lives in
        the runner factory, which every stage shares.
        """
        repo = _copy_repo(self.root)
        runner = canary_run.subprocess_runner(repo)
        with contextlib.redirect_stdout(io.StringIO()):
            answered = runner([sys.executable, "-c", "import os; print(os.getcwd())"])
        self.assertEqual(answered.stdout.strip(), str(repo))

    def test_the_manifest_owns_the_task_the_resolver_runs(self) -> None:
        """Renaming the task would leave the canary asking for nothing."""
        manifest = (REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        self.assertIn('mojo-version = "mojo --version"\n', manifest)

    def test_it_parses_a_version_banner(self) -> None:
        self.assertEqual(parse_toolchain("Mojo 1.0.0b3 (cafef00d)\n"), CANDIDATE)

    def test_it_refuses_an_unreadable_banner(self) -> None:
        with self.assertRaises(ToolchainError):
            parse_toolchain("mojo, but who knows which\n")


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
        result = CommandResult(("pixi", "run", "test"), 3, "", "killed\n")
        detail = first_diagnostic(result)
        self.assertIn("pixi run test", detail)
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

    def test_the_gate_still_reports_the_way_this_reads_it(self) -> None:
        """The last read-back format that was not pinned against its emitter.

        The contract roster and the generator's marker both are. This one was
        not, and it is read by a guard that condemns on an e2e failure naming
        no scenario at all — so a duration appended to the roll-call line,
        `FAILED: doctor-healthy (3.1s)`, would leave every candidate
        permanently SOURCE_INCOMPATIBLE, indistinguishable from a real finding.
        """
        self.assertIn('f"FAILED: {name}\\n  {detail}"', inspect.getsource(e2e_main))

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


def _contract_result(
    *failures: tuple[str, str], passed: int = 124, skipped: int = 0, exit_code: int = 1
) -> CommandResult:
    """A completed `contract-check-strict` reporting exactly these failures."""
    return CommandResult(
        ("pixi", "run", "contract-check-strict"),
        exit_code,
        _contract_output(*failures, passed=passed, skipped=skipped),
        "",
    )


class ContractGuardTests(CanaryTestCase):
    """The gate that runs `doctor` may fail for that reason and no other."""

    def test_the_tolerated_failures_are_the_gates_own_doctor_checks(self) -> None:
        """Derived from the live contract tables, not transcribed beside them.

        A fourth check that runs `mtest doctor` expecting a healthy exit would
        fail on every candidate and, unlisted, would condemn every one of them
        — the permanent red this tolerance exists to end.
        """
        healthy = [
            check.name
            for check in build_matrix()
            if check.argv and check.argv[0] == "doctor" and check.exit == 0
        ]
        self.assertEqual(
            healthy,
            [
                "served: doctor --no-cache accepted, inert (not exit 4)",
                "served: doctor --cache-clear accepted, inert (not exit 4)",
            ],
        )
        # The third is bespoke rather than table-driven: one check that drives
        # every direct-output command, `doctor` among them, at its own exit.
        self.assertIn(
            '("doctor", ["doctor"], 0, "")',
            inspect.getsource(Runner.check_direct_output_closed_pipe),
        )
        tolerated = {name for name, _detail in TOLERATED_CONTRACT_FAILURES}
        self.assertEqual(
            tolerated,
            {*healthy, "pipe: every direct-output command survives a closed stdout"},
        )
        for name in tolerated:
            self.assertIn(name, EXPECTED_CHECK_NAMES)

    def test_the_gate_still_reports_the_way_this_reads_it(self) -> None:
        source = inspect.getsource(contract_main)
        self.assertIn(
            'f"\\n===== {n_pass} passed, {n_fail} failed, {n_skip} skipped ====="',
            source,
        )
        self.assertIn('f"  - {name}  ({ref}): "', source)
        # The roll-call's name and reference are separated by two spaces, and
        # that is the only boundary a reader has, so no check name may contain
        # a double space of its own.
        for name in EXPECTED_CHECK_NAMES:
            self.assertNotIn("  ", name)

    def test_the_identity_failures_alone_are_tolerated(self) -> None:
        self.assertIsNone(
            contract_verdict(
                _contract_result(*_IDENTITY_FAILURES), toolchain_moved=True
            )
        )

    def test_any_other_failing_check_condemns(self) -> None:
        verdict = contract_verdict(
            _contract_result(
                *_IDENTITY_FAILURES,
                ("outcome: TIMEOUT -> 1", "exit 0, want 1"),
            ),
            toolchain_moved=True,
        )
        self.assertIsNotNone(verdict)
        self.assertIn("outcome: TIMEOUT -> 1", str(verdict))
        self.assertNotIn("served: doctor", str(verdict))

    def test_a_second_command_inside_a_tolerated_check_condemns(self) -> None:
        # The pipe check drives ten commands and reports a clause for each one
        # that misbehaved. Keyed on the check name alone, a candidate that
        # broke `run`'s EPIPE handling would have ridden along inside a
        # tolerated line.
        verdict = contract_verdict(
            _contract_result(
                (
                    "pipe: every direct-output command survives a closed stdout",
                    "doctor: exit 1, want 0; run: exit 141, want 0",
                ),
                *_IDENTITY_FAILURES[1:],
            ),
            toolchain_moved=True,
        )
        self.assertIsNotNone(verdict)
        self.assertIn("run: exit 141", str(verdict))

    def test_an_identity_check_that_did_not_fail_condemns(self) -> None:
        # `doctor` refusing an unpinned toolchain is the product behaviour this
        # lane is probing. A gate that failed without it is a gate whose guard
        # has stopped guarding, which is a finding of its own.
        verdict = contract_verdict(
            _contract_result(*_IDENTITY_FAILURES[1:]), toolchain_moved=True
        )
        self.assertIsNotNone(verdict)
        self.assertIn("pipe: every direct-output command", str(verdict))

    def test_a_strict_skip_condemns(self) -> None:
        # Under --strict a skip fails the gate without ever reaching the
        # roll-call, so the count is the only place it shows.
        verdict = contract_verdict(
            _contract_result(*_IDENTITY_FAILURES, skipped=1), toolchain_moved=True
        )
        self.assertIsNotNone(verdict)
        self.assertIn("skip", str(verdict))

    def test_a_gate_that_printed_no_roster_condemns(self) -> None:
        for stdout in ("", "error: no checks ran (filter matched nothing)\n"):
            with self.subTest(stdout=stdout):
                gate = CommandResult(("pixi", "run", "x"), 2, stdout, "died")
                verdict = contract_verdict(gate, toolchain_moved=True)
                self.assertIsNotNone(verdict)
                self.assertIn("died", str(verdict))

    def test_a_roll_call_shorter_than_its_own_count_condemns(self) -> None:
        # A reader that cannot see every failure cannot say they were all
        # tolerable, so the count above the roll-call has to account for it.
        whole = _contract_result(*_IDENTITY_FAILURES)
        truncated = CommandResult(
            whole.argv,
            whole.returncode,
            whole.stdout.replace(
                "  - served: doctor --cache-clear accepted, inert (not exit 4)  "
                "(§9/§27): exit 1, want 0\n",
                "",
            ),
            whole.stderr,
        )
        self.assertNotEqual(truncated.stdout, whole.stdout)
        verdict = contract_verdict(truncated, toolchain_moved=True)
        self.assertIsNotNone(verdict)

    def test_identity_failures_condemn_an_unmoved_toolchain(self) -> None:
        verdict = contract_verdict(
            _contract_result(*_IDENTITY_FAILURES), toolchain_moved=False
        )
        self.assertIsNotNone(verdict)

    def test_a_gate_that_passed_everything_condemns(self) -> None:
        """An expected failure that did not happen is itself the finding.

        A candidate that breaks `doctor`'s pinned-identity guard — a
        `mojo --version` banner it no longer recognises, a contract change that
        stops driving `doctor` at all — makes the three checks below pass and
        the gate exit 0. Read on the nonzero branch alone, that skipped this
        reading entirely and the day was reported as `PASS`: the candidate that
        broke the very guard being probed was the one reported green.
        """
        for exit_code in (0, 1):
            with self.subTest(exit_code=exit_code):
                verdict = contract_verdict(
                    _contract_result(passed=127, exit_code=exit_code),
                    toolchain_moved=True,
                )
                self.assertIsNotNone(verdict)
                for name, _detail in TOLERATED_CONTRACT_FAILURES:
                    self.assertIn(name, str(verdict))
                self.assertIn("stopped guarding", str(verdict))


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

    def test_the_flattened_reading_is_not_a_newest_first_ordering(self) -> None:
        # Two subdirs that have diverged, which is the case the flattening
        # cannot represent: pixi orders records inside a subdir, so the head of
        # the flattened list is the first subdir's newest and nothing more.
        # Only the per-subdir maxima can be named without this module
        # implementing conda's version ordering itself.
        answer = CommandResult(
            ("pixi", "search", "--json", "mojo"),
            0,
            json.dumps(
                {
                    "linux-64": [{"name": "mojo", "version": "1.0.0b2"}],
                    "osx-arm64": [
                        {"name": "mojo", "version": "1.0.0rc0"},
                        {"name": "mojo", "version": "1.0.0b2"},
                    ],
                }
            ),
            "",
        )
        self.assertEqual(search_versions(answer), ("1.0.0b2", "1.0.0rc0"))
        self.assertEqual(search_newest(answer), ("1.0.0b2", "1.0.0rc0"))

    def test_an_idle_lane_names_every_subdirs_newest(self) -> None:
        # The subdirs have diverged: one carries the pin, the other stopped at
        # the release before it. Nothing precedes the pin anywhere, which is
        # what makes this an idle lane rather than a contradicted one — pixi
        # lists records newest first WITHIN a subdir, so an older version
        # cannot stand ahead of the pin in one.
        repo, runner = self.build()
        runner.outcomes(
            "search-published",
            _Outcome(
                0,
                json.dumps(
                    {
                        "linux-64": [{"name": "mojo", "version": PINNED_MOJO}],
                        "osx-arm64": [{"name": "mojo", "version": "1.0.0b1"}],
                    }
                ),
                "",
            ),
        )
        runner.outcomes("search-candidates", _Outcome(0, _search_answer(), ""))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, NO_NEWER_CANDIDATE)
        self.assertIn(f"published there is {PINNED_MOJO}, 1.0.0b1", result.detail)

    def test_only_a_subdir_that_carries_the_pin_can_outrank_it(self) -> None:
        """The one ordering claim that can be read straight off an answer.

        pixi orders records newest first inside a subdir, so a version standing
        ahead of the pin THERE is newer than the pin without anything here
        comparing two version strings. A subdir that never names the pin
        supports no such reading: its head may be older, and deciding which
        would mean implementing conda's ordering in this module, which is the
        one thing `search_newest` exists to refuse.
        """
        answer = CommandResult(
            ("pixi", "search", "--json", "mojo"),
            0,
            json.dumps(
                {
                    "linux-64": [
                        {"name": "mojo", "version": "1.0.0rc0"},
                        {"name": "mojo", "version": PINNED_MOJO},
                        {"name": "mojo", "version": "1.0.0b1"},
                    ],
                    "osx-arm64": [
                        {"name": "mojo", "version": "1.0.0rc0"},
                        {"name": "mojo", "version": "1.0.0b3"},
                    ],
                }
            ),
            "",
        )
        self.assertEqual(
            canary_run.versions_newer_than(answer, PINNED_MOJO), ("1.0.0rc0",)
        )
        self.assertEqual(canary_run.versions_newer_than(answer, "1.0.0rc0"), ())
        self.assertEqual(
            canary_run.versions_newer_than(
                CommandResult(("pixi", "search"), 0, _search_answer(), ""), PINNED_MOJO
            ),
            (),
        )

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
        # `unknown`, not the pin. The pin is what this repository already
        # ships, and recorded as the day's version it reached the issue body
        # under a heading reading "Candidate" — a compiler presented as
        # exercised on the commonest quiet day there is. The detail names the
        # newest release instead.
        self.assertEqual(result.version, canary_run.UNKNOWN)
        self.assertIn(PINNED_MOJO, result.detail)
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

    def test_a_control_that_answered_but_confirmed_nothing_is_loud(self) -> None:
        """A control that ran and said the wrong thing is not an outage.

        The channels answered, but not with the version this repository is
        built against, or not in a shape this reads. Neither clears by itself:
        the same wrong channel set answers the same way tomorrow. Filed as
        INFRA_FAILURE it wrote nothing and exited 0, so a lane that had stopped
        probing entirely reported a green day, every day.
        """
        for stdout in (_search_answer(), "No packages found\n"):
            with self.subTest(stdout=stdout):
                repo, runner = self.build()
                self._idle_stable_channel(runner)
                runner.outcomes("search-control", _Outcome(0, stdout, ""))
                result = self.classify(repo, runner)
                self.assertEqual(result.classification, CANARY_BROKEN)

    def test_a_failed_bounded_search_never_contradicts_the_inventory(self) -> None:
        """The run already held the evidence that the quiet answer was wrong.

        The unbounded search names what the channels publish, and it named
        1.0.0b3 above the pin. The bounded search then failed for a reason of
        its own — a transient 503, a connection reset — and the control, which
        answers instantly out of cached repodata, confirmed the channels. That
        was read as an empty match set, so the lane reported the quiet
        `NO_NEWER_CANDIDATE` and closed yesterday's real issue, having observed
        a newer release in its own first query minutes earlier.
        """
        repo, runner = self.build()
        runner.fails("search-candidates", stderr="error sending request: HTTP 503\n")
        result = self.classify(repo, runner)
        self.assertNotEqual(result.classification, NO_NEWER_CANDIDATE, result.detail)
        self.assertEqual(result.classification, INFRA_FAILURE, result.detail)
        self.assertIn(CANDIDATE.version, result.detail)
        self.assertIn("HTTP 503", result.detail)
        self.assertEqual(
            runner.stages,
            ["search-published", "search-candidates", "search-control"],
        )

    def test_a_bounded_search_that_answers_against_the_inventory_is_loud(self) -> None:
        """Two answers from one tool in one run that cannot both be true.

        Here the bounded search succeeds and names nothing while the unbounded
        one has just listed a version above the pin. Nothing transient explains
        that: the matchspec this probe builds does not select what the channels
        say they hold, so the screen is asking a question other than the one
        the pipeline believes it asked, and it will ask it again tomorrow.
        """
        repo, runner = self.build()
        runner.outcomes("search-candidates", _Outcome(0, _search_answer(), ""))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, CANARY_BROKEN, result.detail)
        self.assertIn(CANDIDATE.version, result.detail)
        self.assertIn(PINNED_MOJO, result.detail)

    def test_a_subdir_that_lists_nothing_above_the_pin_stays_quiet(self) -> None:
        """The comparison is pixi's own ordering, never one written here.

        Only a version a subdir lists BEFORE the pin is newer than the pin, and
        only in a subdir that carries the pin at all. A subdir whose newest is
        older than the pin — a platform a release skipped — must not be read as
        newer, or every idle day on a diverged channel set turns loud.
        """
        repo, runner = self.build()
        runner.outcomes(
            "search-published",
            _Outcome(
                0,
                json.dumps(
                    {
                        "linux-64": [
                            {"name": "mojo", "version": PINNED_MOJO},
                            {"name": "mojo", "version": "1.0.0b1"},
                        ],
                        "osx-arm64": [{"name": "mojo", "version": "1.0.0b1"}],
                    }
                ),
                "",
            ),
        )
        runner.fails("search-candidates", stderr="No packages found matching\n")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, NO_NEWER_CANDIDATE, result.detail)

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

    def test_a_published_search_that_cannot_see_the_pin_is_loud(self) -> None:
        # The two searches are held to one bar. Accepting the unbounded one on
        # exit 0 and parseable JSON alone let an answer that names no mojo at
        # all — the wrong channels, an index that lost the package — wave the
        # pipeline through to a bounded search that also came back empty, and
        # the lane reported a quiet NO_NEWER_CANDIDATE without ever consulting
        # the control that exists to catch exactly this. Loud rather than
        # infrastructure because the wrong channel set is still the wrong
        # channel set tomorrow.
        repo, runner = self.build()
        for answer in (_search_answer(), _search_answer("0.26.2.0")):
            with self.subTest(answer=answer):
                runner = FakeRunner(repo)
                runner.outcomes("search-published", _Outcome(0, answer, ""))
                result = self.classify(repo, runner)
                self.assertEqual(result.classification, CANARY_BROKEN)
                self.assertIn(PINNED_MOJO, result.detail)
                self.assertEqual(runner.stages, ["search-published"])

    def test_an_answer_this_cannot_read_is_loud(self) -> None:
        """Pixi floats, so the day its `search --json` shape moves is permanent.

        The workflow provisions pixi without a version, so a release that
        changes the shape of this answer raises here on every run of both lanes
        until someone notices. Quiet, nobody does: the probe has stopped
        probing and every scheduled run still reports green. In `ci.yml` the
        same pixi change would have turned a build red the day it landed.
        """
        for stage in ("search-published", "search-candidates"):
            with self.subTest(stage=stage):
                repo, runner = self.build()
                runner.outcomes(stage, _Outcome(0, "not json at all", ""))
                result = self.classify(repo, runner)
                self.assertEqual(result.classification, CANARY_BROKEN)


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
        for stage in ("build-bin", "test", "contract-check-strict", "e2e"):
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

    def test_the_real_runner_kills_a_stage_that_outlives_its_budget(self) -> None:
        """The negative control the injected 124s cannot be.

        Every other timeout test hands the pipeline a canned exit 124 through
        the fake runner, so all of them stay green with `timeout=` removed from
        the real `subprocess.run` call or with the `TimeoutExpired` handler
        deleted — the two ways this can actually break. This one spawns a
        process that genuinely outlives its budget, under a budget shortened to
        make that affordable, and reads back what the runner turned it into.

        The fast command underneath it is the other half of the control: a
        runner that answered 124 unconditionally would satisfy the first
        assertion on its own.
        """
        runner = canary_run.subprocess_runner(Path.cwd())
        sleeper = [sys.executable, "-c", "import time; time.sleep(30)"]
        with mock.patch.object(canary_run, "STAGE_TIMEOUT_SECONDS", 0.25):
            started = time.monotonic()
            with contextlib.redirect_stdout(io.StringIO()):
                killed = runner(sleeper)
            elapsed = time.monotonic() - started
        self.assertEqual(killed.returncode, TIMEOUT_RETURNCODE)
        self.assertIn("timed out after", killed.stderr)
        self.assertEqual(killed.argv, tuple(sleeper))
        self.assertLess(elapsed, 5.0, "the stage was not killed at its budget")

        with contextlib.redirect_stdout(io.StringIO()):
            finished = runner([sys.executable, "-c", "print('done')"])
        self.assertEqual(finished.returncode, 0)
        self.assertIn("done", finished.stdout)

    def test_a_killed_stage_takes_everything_it_spawned_with_it(self) -> None:
        """A stage is a pixi task, so the thing doing the work is a grandchild.

        Killing only the direct child left the compiler, test runner or package
        build underneath it running — writing to the caches, prefixes and build
        directories of a probe that had already reported `STAGE_TIMEOUT` and
        moved on to the next stage. Reproduced here with a child that spawns a
        sleeper and records its pid, under a budget short enough to be
        affordable: the sleeper has to be gone once the runner has answered.
        """
        marker = self.root / "grandchild.pid"
        spawner = (
            "import subprocess, sys, time\n"
            "child = subprocess.Popen([sys.executable, '-c', "
            "'import time; time.sleep(120)'])\n"
            f"open({str(marker)!r}, 'w').write(str(child.pid))\n"
            "time.sleep(120)\n"
        )
        runner = canary_run.subprocess_runner(Path.cwd())
        with (
            mock.patch.object(canary_run, "STAGE_TIMEOUT_SECONDS", 1.0),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            killed = runner([sys.executable, "-c", spawner])
        self.assertEqual(killed.returncode, TIMEOUT_RETURNCODE)

        grandchild = int(marker.read_text(encoding="utf-8"))
        # Signal 0 checks for the process without touching it. Polled rather
        # than asserted once, because a SIGKILL is delivered asynchronously and
        # the pid stays visible until its reparented parent reaps it.
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            try:
                os.kill(grandchild, 0)
            except ProcessLookupError:
                break
        else:
            os.kill(grandchild, 9)
            raise AssertionError(f"pid {grandchild} outlived the stage that spawned it")

    def test_a_group_outlives_the_launcher_that_led_it(self) -> None:
        """The kill must not depend on the launcher still being reapable.

        A stage is a pixi task, so the task can finish while the compiler it
        started keeps the capture pipes open — and `communicate` then blocks on
        those pipes until the budget runs out, with the launcher already
        exited. Asking the kernel for the group at that point only answers
        while that process is still on the process table; once anything has
        reaped it, `os.getpgid` raises `ProcessLookupError`, the suppression
        swallowed it, and the group still holding the compiler was never
        signalled. Started in a session of its own, the launcher IS the group
        leader, so its pid is the group id and remains a valid target for as
        long as any member of the group is alive.
        """
        marker = self.root / "orphan.pid"
        spawner = (
            "import subprocess, sys\n"
            "child = subprocess.Popen([sys.executable, '-c', "
            "'import time; time.sleep(120)'])\n"
            f"open({str(marker)!r}, 'w').write(str(child.pid))\n"
        )
        process = subprocess.Popen(
            [sys.executable, "-c", spawner],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.communicate(timeout=2.0)
            raise AssertionError("the grandchild did not hold the capture pipes open")
        # The launcher is gone and reaped by here, which is the state the
        # lookup cannot survive: everything the stage spawned is still running,
        # and the only name left for its group is the pid it was started with.
        self.assertEqual(process.poll(), 0)
        with self.assertRaises(ProcessLookupError):
            os.getpgid(process.pid)

        canary_run.kill_process_group(process)
        grandchild = int(marker.read_text(encoding="utf-8"))
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            try:
                os.kill(grandchild, 0)
            except ProcessLookupError:
                break
        else:
            os.kill(grandchild, 9)
            raise AssertionError(f"pid {grandchild} outlived the stage that spawned it")

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

    def test_a_wedged_candidate_search_is_not_an_empty_channel(self) -> None:
        """The corroboration must not be asked about a stage that said nothing.

        A stalled connection to the index wedges the bounded search and it is
        killed at the stage budget. The control then opens a fresh connection
        and answers instantly out of cached repodata, so the failure read as an
        empty match set and the day ended on `NO_NEWER_CANDIDATE` — a positive
        claim about channel inventory nobody had observed, and a quiet one, so
        the lane's open issue was closed on it.
        """
        repo, runner = self.build()
        runner.outcomes(
            "search-candidates", _Outcome(TIMEOUT_RETURNCODE, "", "timed out")
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, STAGE_TIMEOUT, result.detail)
        self.assertIn("timed out", result.detail)
        # The control is not even asked: there is nothing to corroborate.
        self.assertEqual(runner.stages, ["search-published", "search-candidates"])

    def test_a_wedged_control_is_a_timeout_wherever_it_is_asked(self) -> None:
        """A killed control was read as "the probe lost its reach", quietly.

        Both places that corroborate a failure do it with the same argv, and
        both mapped its every non-answer onto `INFRA_FAILURE`. A control the
        probe stopped itself proved nothing about reach, and filing it as
        infrastructure buried it on a lane that had genuinely stopped
        answering.
        """
        for wedged_stage, failing_stage in (
            ("search-control", "search-candidates"),
            ("search-control", "install"),
        ):
            with self.subTest(after=failing_stage):
                repo, runner = self.build()
                runner.fails(failing_stage)
                runner.outcomes(
                    wedged_stage, _Outcome(TIMEOUT_RETURNCODE, "", "timed out")
                )
                result = self.classify(repo, runner)
                self.assertEqual(result.classification, STAGE_TIMEOUT, result.detail)
                self.assertIn(floor_matchspec(PINNED_MOJO), result.detail)


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
                "mojo-version",
                "build-bin",
                "test",
                "contract-check-strict",
                "transcripts",
                "cross-compile",
                "e2e",
                "package-check",
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
            stderr="Error: cannot solve the request: mojo 1.0.0rc0 needs python 3.13\n",
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertIn("needs python 3.13", result.detail)
        self.assertIn(floor_matchspec(PINNED_MOJO), result.detail)
        # The searched newest was computed and thrown away, so the issue body
        # read `mojo unknown (unknown)` about a candidate the probe could name.
        self.assertEqual(result.version, CANDIDATE.version)
        self.assertEqual(result.commit, canary_run.UNKNOWN)
        self.assertIn(
            "- **Candidate:** none was exercised; the channels published mojo "
            f"{CANDIDATE.version}\n",
            canary_run.render_summary(result),
        )

    def test_a_twice_failed_install_claims_only_what_it_saw(self) -> None:
        """`pixi install` solves, fetches and links; the wording claimed a solve.

        The direction is deliberate and stays — a wrong red is read and
        corrected the same day, a wrong green is the silence this workflow
        exists to end. But a CDN 5xx on a `.conda` payload, a 429, a truncated
        transfer or a full prefix all leave repodata search healthy and land
        here, and every one of them was reported as a spec that "cannot be
        satisfied beside this repository's own pinned dependencies on every
        platform the manifest declares" — a solver verdict this probe never
        observed, standing in a durable artifact.
        """
        repo, runner = self.build()
        runner.fails(
            "install",
            stderr="ERROR failed to fetch mojo-1.0.0b3.conda: HTTP status 503\n",
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertNotIn("cannot be satisfied", result.detail)
        self.assertIn("did not install", result.detail)
        self.assertIn("solving, fetching and linking", result.detail)
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

    def test_an_install_outside_the_searched_set_is_loud(self) -> None:
        """Every gate below reports about the toolchain this line names.

        By here the bounded search has already proved something newer is
        published and the manifest has been rewritten to admit exactly that
        set, so a solve that produced anything else did not answer the question
        the probe asked — a prefix left over from before the rewrite, a
        `--repo` pointing at a checkout the search never described, a solver
        that ignored the spec. Resolving the pin was read as
        `NO_NEWER_CANDIDATE`, which is quiet and closed the lane's issue; any
        other unsearched version was waved through as though it were the
        candidate, and every gate below then reported about a toolchain nobody
        had screened.
        """
        for version in (PINNED_MOJO, "1.0.0b9"):
            with self.subTest(version=version):
                repo, runner = self.build()
                result = self.classify(
                    repo, runner, resolved=ResolvedToolchain(version, "2cf4d08a")
                )
                self.assertEqual(result.classification, CANARY_BROKEN, result.detail)
                self.assertIn(version, result.detail)
                self.assertIn(CANDIDATE.version, result.detail)
                self.assertEqual(
                    runner.stages,
                    [
                        "search-published",
                        "search-candidates",
                        "install",
                        "mojo-version",
                    ],
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
            [
                "search-published",
                "search-candidates",
                "install",
                "mojo-version",
                "build-bin",
            ],
        )

    def test_a_failing_suite_is_source_incompatible(self) -> None:
        repo, runner = self.build()
        runner.fails("test")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertEqual(
            runner.stages,
            [
                "search-published",
                "search-candidates",
                "install",
                "mojo-version",
                "build-bin",
                "test",
            ],
        )

    def test_a_failing_contract_check_is_source_incompatible(self) -> None:
        repo, runner = self.build()
        runner.outcomes(
            "contract-check-strict",
            _Outcome(
                1,
                _contract_output(("outcome: TIMEOUT -> 1", "exit 0, want 1")),
                "",
            ),
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertIn("outcome: TIMEOUT -> 1", result.detail)
        self.assertNotIn("transcripts", runner.stages)

    def test_a_candidate_passes_the_gate_that_doctor_has_to_fail(self) -> None:
        """Without this the probe could not report PASS for any candidate at all.

        `contract-check-strict` runs `mtest doctor`, which compiles the pinned
        toolchain identity in and refuses every other one — correct product
        behaviour. So the third source gate failed on every candidate however
        compatible, every probe came back SOURCE_INCOMPATIBLE, and the lane
        read the same on the day a candidate really broke the sources as on
        every other day of its life.
        """
        repo, runner = self.build()
        runner.outcomes(
            "contract-check-strict",
            _Outcome(1, _contract_output(*_IDENTITY_FAILURES), ""),
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, PASS, result.detail)
        self.assertIn("doctor", result.detail)
        self.assertIn("e2e", runner.stages)

    def test_a_contract_gate_that_did_not_fail_stops_the_pipeline(self) -> None:
        """The tolerance was wired into the nonzero branch and nowhere else.

        A candidate that broke `mtest doctor`'s pinned-identity guard so that
        it stops refusing an unpinned compiler makes the gate exit 0. The probe
        then accepted it outright, ran the remaining legs, and reported `PASS`
        — closing the lane's issue on the one candidate this lane exists to
        catch. The roster has to be read on a zero exit too, and a zero exit
        has to condemn.
        """
        repo, runner = self.build()
        runner.outcomes(
            "contract-check-strict", _Outcome(0, _contract_output(passed=127), "")
        )
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE, result.detail)
        self.assertIn("stopped guarding", result.detail)
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
            result.detail,
            "/repo/e2e/fixtures/passing.mojo:3:1: error: unknown attribute",
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

    def test_a_broken_source_leg_outranks_the_package_it_would_ship(self) -> None:
        """`PACKAGE_FAILED` claims the sources are fine, so it is asked last.

        Both remaining source legs fail here as well as packaging. Asked before
        them, the run reported a packaging finding while the premise that
        finding rests on — that the sources compiled, cross-compiled and
        behaved — had never been tested, and a candidate that broke Darwin
        compilation outright was filed as a recipe problem.
        """
        repo, runner = self.build()
        runner.fails(
            "cross-compile",
            stderr="/repo/src/mtest/session/exec.mojo:77:5: error: no matching call\n",
        )
        runner.fails("e2e")
        runner.fails("package-check")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE, result.detail)
        self.assertNotIn("package-check", runner.stages)

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
                "mojo-version",
                "build-bin",
                "test",
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
