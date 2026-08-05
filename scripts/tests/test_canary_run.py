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
import shutil
import tempfile
from typing import TYPE_CHECKING, override
import unittest
from unittest import mock

from scripts.canary import toolchain
from scripts.canary.protocol_compare import PASS, PROTOCOL_DRIFT
from scripts.canary.run import (
    INFRA_FAILURE,
    MACOS_CROSS_COMPILE,
    NO_NEWER_CANDIDATE,
    PACKAGE_FAILED,
    SOURCE_INCOMPATIBLE,
    CanaryResult,
    CommandResult,
    classify,
    e2e_failure_verdict,
    failed_scenarios,
    first_diagnostic,
    main,
)
from scripts.canary.toolchain import (
    DOCTOR_PREFIX,
    FORCE_ENV_VAR,
    NIGHTLY_CHANNEL,
    ResolvedToolchain,
    ToolchainError,
    pin_recipe_to_candidate,
    relax_workspace_pin,
    resolved_toolchain,
    workspace_pin,
)
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
    """Lay out the parts of this checkout the probe reads or rewrites."""
    repo = root / "repo"
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
        self._outcomes: dict[str, list[_Outcome]] = {}

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
        return classify(repo, lane, run=runner, resolve=lambda: resolved)


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

    def test_it_parses_a_version_banner(self) -> None:
        completed = mock.Mock(stdout="Mojo 1.0.0b3 (cafef00d)\n")
        with mock.patch("subprocess.run", return_value=completed):
            self.assertEqual(resolved_toolchain(), CANDIDATE)

    def test_it_refuses_an_unreadable_banner(self) -> None:
        completed = mock.Mock(stdout="mojo, but who knows which\n")
        with (
            mock.patch("subprocess.run", return_value=completed),
            self.assertRaises(ToolchainError),
        ):
            resolved_toolchain()


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

    def test_the_prefix_names_real_scenarios(self) -> None:
        self.assertEqual(
            [name for name, _scenario in SCENARIOS if name.startswith(DOCTOR_PREFIX)],
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

    def test_a_failing_install_is_retried_once_then_infra(self) -> None:
        repo, runner = self.build()
        runner.fails("install", stderr="could not solve mojo >1.0.0b2,<2\n")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, INFRA_FAILURE)
        self.assertEqual(runner.stages, ["install", "install"])
        self.assertIn("could not solve", result.detail)

    def test_a_retried_install_that_succeeds_continues(self) -> None:
        repo, runner = self.build()
        runner.outcomes("install", _Outcome(1, "", "network"), _Outcome(0, "", ""))
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, PASS, result.detail)
        self.assertEqual(runner.stages.count("install"), 2)

    def test_the_pinned_toolchain_is_no_newer_candidate(self) -> None:
        repo, runner = self.build()
        result = self.classify(
            repo, runner, resolved=ResolvedToolchain(PINNED_MOJO, "2cf4d08a")
        )
        self.assertEqual(result.classification, NO_NEWER_CANDIDATE)
        self.assertEqual(result.version, PINNED_MOJO)
        self.assertEqual(runner.stages, ["install"])
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
        self.assertEqual(runner.stages, ["install", "build-bin"])

    def test_a_failing_unit_lane_is_source_incompatible(self) -> None:
        repo, runner = self.build()
        runner.fails("test-unit")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, SOURCE_INCOMPATIBLE)
        self.assertEqual(runner.stages, ["install", "build-bin", "test-unit"])

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

    def test_a_generator_that_cannot_run_is_protocol_drift(self) -> None:
        repo, runner = self.build()
        runner.fails("transcripts", stderr="non-deterministic transcript\n")
        result = self.classify(repo, runner)
        self.assertEqual(result.classification, PROTOCOL_DRIFT)
        self.assertIn("non-deterministic transcript", result.detail)

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
