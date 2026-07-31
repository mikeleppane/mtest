#!/usr/bin/env python3
"""Mutation tests for the workflow-security oracles.

Each test mutates a real workflow's text in a temporary repository and asserts
the corresponding check rejects it, so every guard is watched firing on the
exact thing it exists to prevent.
"""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from scripts.checks import workflow_security


class WorkflowInventoryAndCodeQLTests(unittest.TestCase):
    """Fail-closed policy for the workflow inventory and the CodeQL workflow."""

    def _workflow(self) -> str:
        """Return the live CodeQL workflow text."""
        return (
            workflow_security.REPO_ROOT / ".github" / "workflows" / "codeql.yml"
        ).read_text(encoding="utf-8")

    def _reject(self, mutated: str, pattern: str) -> None:
        """Require the CodeQL oracle to reject one mutated workflow."""
        self.assertNotEqual(mutated, self._workflow())
        with tempfile.TemporaryDirectory(prefix="mtest-codeql-security-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_path = repo / ".github" / "workflows" / "codeql.yml"
            workflow_path.parent.mkdir(parents=True)
            workflow_path.write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, pattern):
                workflow_security.check_codeql_workflow(repo)

    def _write_inventory(self, root: Path) -> Path:
        """Create the exact expected workflow inventory in a temporary repo."""
        workflow_root = root / ".github" / "workflows"
        workflow_root.mkdir(parents=True)
        for relative in workflow_security.WORKFLOW_PATHS:
            source = workflow_security.REPO_ROOT / relative
            (workflow_root / relative.name).write_text(
                source.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
        return workflow_root

    def test_repository_workflow_inventory_is_exact(self) -> None:
        self.assertEqual(
            workflow_security.WORKFLOW_PATHS,
            {
                Path(".github/workflows/ci.yml"),
                Path(".github/workflows/codeql.yml"),
                Path(".github/workflows/community-publish.yml"),
                Path(".github/workflows/community-verify.yml"),
                Path(".github/workflows/release.yml"),
            },
        )
        workflow_security.check_workflow_inventory()

    def test_javascript_actions_pin_reviewed_node24_releases(self) -> None:
        self.assertEqual(
            workflow_security.CHECKOUT_ACTION_SHA,
            "3d3c42e5aac5ba805825da76410c181273ba90b1",
        )
        self.assertEqual(
            workflow_security.CODEQL_ACTION_SHA,
            "e4fba868fa4b1b91e1fdab776edc8cfbe6e9fb81",
        )
        for path in workflow_security.WORKFLOW_PATHS:
            name = path.name
            workflow = (workflow_security.REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertNotIn("actions/checkout@v4", workflow, name)
            self.assertNotIn(
                "11bd71901bbe5b1630ceea73d27597364c9af683",
                workflow,
                name,
            )
        codeql = self._workflow()
        self.assertNotIn(
            "github/codeql-action/",
            codeql.replace(
                "github/codeql-action/init@e4fba868fa4b1b91e1fdab776edc8cfbe6e9fb81",
                "",
            ).replace(
                "github/codeql-action/analyze@e4fba868fa4b1b91e1fdab776edc8cfbe6e9fb81",
                "",
            ),
        )

    def test_every_external_action_has_an_immutable_pin_and_version_comment(
        self,
    ) -> None:
        workflow_security.check_action_pins()
        workflow = self._workflow()
        mutations = (
            workflow.replace(
                f"actions/checkout@{workflow_security.CHECKOUT_ACTION_SHA} # v7.0.1",
                "actions/checkout@v7",
                1,
            ),
            workflow.replace(
                f"github/codeql-action/init@{workflow_security.CODEQL_ACTION_SHA}"
                " # v4.37.3",
                f"github/codeql-action/init@{workflow_security.CODEQL_ACTION_SHA}",
                1,
            ),
        )
        for mutated in mutations:
            with tempfile.TemporaryDirectory(prefix="mtest-action-pins-") as raw_tmp:
                repo = Path(raw_tmp)
                workflow_root = repo / ".github" / "workflows"
                workflow_root.mkdir(parents=True)
                (workflow_root / "codeql.yml").write_text(
                    mutated,
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(AssertionError, "action pin"):
                    workflow_security.check_action_pins(repo)

    def test_missing_workflow_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-workflow-inventory-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_root = self._write_inventory(repo)
            (workflow_root / "codeql.yml").unlink()
            with self.assertRaisesRegex(AssertionError, "inventory mismatch"):
                workflow_security.check_workflow_inventory(repo)

    def test_extra_yaml_workflow_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-workflow-inventory-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_root = self._write_inventory(repo)
            (workflow_root / "surprise.yaml").write_text(
                "name: Surprise\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "inventory mismatch"):
                workflow_security.check_workflow_inventory(repo)

    def test_symlinked_workflow_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-workflow-inventory-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_root = self._write_inventory(repo)
            (workflow_root / "codeql.yml").unlink()
            (workflow_root / "codeql.yml").symlink_to("ci.yml")
            with self.assertRaisesRegex(AssertionError, "symlink"):
                workflow_security.check_workflow_inventory(repo)

    def test_all_required_triggers_are_pinned(self) -> None:
        workflow = self._workflow()
        mutations = {
            "push": workflow.replace(
                "  push:\n    branches: [main]\n",
                "",
                1,
            ),
            "pull_request": workflow.replace(
                "  pull_request:\n    branches: [main]\n",
                "",
                1,
            ),
            "schedule": workflow.replace(
                '  schedule:\n    - cron: "23 4 * * 1"\n',
                "",
                1,
            ),
            "workflow_dispatch": workflow.replace("  workflow_dispatch:\n", "", 1),
        }
        for trigger, mutated in mutations.items():
            with self.subTest(trigger=trigger):
                self._reject(mutated, "trigger mismatch")

    def test_security_event_write_permission_is_required(self) -> None:
        self._reject(
            self._workflow().replace(
                "  security-events: write",
                "  security-events: read",
                1,
            ),
            "permission mismatch",
        )

    def test_codeql_autobuild_is_rejected(self) -> None:
        workflow = self._workflow()
        marker = "      - name: Analyze C and C++\n"
        mutated = workflow.replace(
            marker,
            "      - name: Autobuild\n"
            "        uses: github/codeql-action/autobuild@"
            f"{workflow_security.CODEQL_ACTION_SHA}"
            " # v4.37.3\n\n" + marker,
            1,
        )
        self._reject(mutated, "autobuild")

    def test_native_job_requires_the_real_manual_build(self) -> None:
        self._reject(
            self._workflow().replace(
                "        run: pixi run build-native",
                "        run: true",
                1,
            ),
            "manual build",
        )

    def test_python_job_must_not_build_the_product(self) -> None:
        workflow = self._workflow()
        marker = "      - name: Analyze Python\n"
        mutated = workflow.replace(
            marker,
            "      - name: Build product\n        run: pixi run build\n\n" + marker,
            1,
        )
        self._reject(mutated, "Python job must not run shell commands")

    def test_action_tag_in_place_of_commit_is_rejected(self) -> None:
        self._reject(
            self._workflow().replace(
                f"github/codeql-action/init@{workflow_security.CODEQL_ACTION_SHA}",
                "github/codeql-action/init@v3",
                1,
            ),
            "action pin mismatch",
        )


class ReleaseWorkflowTests(unittest.TestCase):
    """Fail-closed publication workflow authority and evidence boundaries."""

    def _workflow(self, name: str) -> str:
        return (workflow_security.REPO_ROOT / ".github" / "workflows" / name).read_text(
            encoding="utf-8"
        )

    def _reject(self, name: str, mutated: str, pattern: str) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-release-security-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_root = repo / ".github" / "workflows"
            workflow_root.mkdir(parents=True)
            for workflow_name in (
                "release.yml",
                "community-publish.yml",
                "community-verify.yml",
            ):
                text = (
                    mutated if workflow_name == name else self._workflow(workflow_name)
                )
                (workflow_root / workflow_name).write_text(text, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, pattern):
                workflow_security.check_release_workflows(repo)

    def test_live_publication_workflows_have_closed_authority(self) -> None:
        workflow_security.check_release_workflows()

    def test_setup_pixi_without_install_rejects_install_only_inputs(self) -> None:
        invalid_inputs = ("cache: true", "locked: true")
        good_block = "          cache: false\n          run-install: false"
        for workflow_name in (
            "release.yml",
            "community-publish.yml",
            "community-verify.yml",
        ):
            baseline = self._workflow(workflow_name)
            self.assertIn(good_block, baseline)
            for invalid_input in invalid_inputs:
                with self.subTest(
                    workflow=workflow_name,
                    invalid_input=invalid_input,
                ):
                    mutated = baseline.replace(
                        good_block,
                        f"          {invalid_input}\n          run-install: false",
                        1,
                    )
                    self._reject(
                        workflow_name,
                        mutated,
                        "setup-pixi.*run-install",
                    )

    def test_protected_environments_cannot_be_removed(self) -> None:
        self._reject(
            "release.yml",
            self._workflow("release.yml").replace(
                "    environment: github-release\n",
                "",
                1,
            ),
            "github-release",
        )
        self._reject(
            "community-publish.yml",
            self._workflow("community-publish.yml").replace(
                "    environment: community-publish\n",
                "",
                1,
            ),
            "community-publish",
        )

    def test_fork_token_cannot_escape_prepare_job(self) -> None:
        workflow = self._workflow("community-publish.yml")
        marker = "    runs-on: ubuntu-24.04\n"
        self._reject(
            "community-publish.yml",
            workflow.replace(
                marker,
                marker + "    env: ${{ secrets.COMMUNITY_FORK_TOKEN }}\n",
                1,
            ),
            "fork token",
        )

    def test_release_requires_exact_ci_candidate_and_immutable_state(self) -> None:
        for needle in (".immutable == true",):
            with self.subTest(needle=needle):
                self._reject(
                    "release.yml",
                    self._workflow("release.yml").replace(needle, "false", 1),
                    "release evidence",
                )

    def test_publication_evidence_is_bound_to_canonical_workflow_files(self) -> None:
        release = self._workflow("release.yml")
        community = self._workflow("community-publish.yml")
        ci_endpoint = "actions/workflows/ci.yml/runs?"
        self.assertEqual(release.count(ci_endpoint), 2)
        self.assertEqual(community.count(ci_endpoint), 1)
        self.assertNotIn('.name == "CI"', release + community)
        self.assertEqual(release.count(".workflow_id == $workflow_id"), 2)
        self.assertEqual(
            release.count(
                '(.path | startswith(".github/workflows/community-publish.yml@"))'
            ),
            2,
        )
        self.assertIn(
            '[[ "$WORKFLOW_RUN_PATH" == ".github/workflows/release.yml@"* ]]',
            community,
        )
        self.assertIn(
            'test "$WORKFLOW_RUN_WORKFLOW_ID" = "$release_workflow_id"',
            community,
        )
        self.assertIn(
            'test "$WORKFLOW_DEFINITION_SHA" = "$WORKFLOW_RUN_SHA"',
            community,
        )
        self.assertIn("scripts.release.recipe stage-target", community)
        self.assertIn(
            "api.github.com/repos/$FORK_OWNER/modular-community",
            community,
        )
        self.assertIn("scripts.release.community fork", community)

    def test_manual_prepare_ci_gate_cannot_apply_to_dry_run(self) -> None:
        workflow = self._workflow("community-publish.yml")
        self._reject(
            "community-publish.yml",
            workflow.replace(
                '            if test "$mode" = "prepare"; then\n',
                "            if true; then\n",
                1,
            ),
            "manual prepare CI",
        )

    def test_candidate_workflow_identity_tautology_is_rejected(self) -> None:
        self._reject(
            "release.yml",
            self._workflow("release.yml").replace(
                ".workflow_id == $workflow_id",
                ".workflow_id == .workflow_id",
                1,
            ),
            "candidate workflow identity",
        )

    def test_triggering_workflow_definition_mismatch_is_rejected(self) -> None:
        self._reject(
            "community-publish.yml",
            self._workflow("community-publish.yml").replace(
                'test "$WORKFLOW_RUN_WORKFLOW_ID" = "$release_workflow_id"',
                'test "$WORKFLOW_RUN_WORKFLOW_ID" = "$WORKFLOW_RUN_WORKFLOW_ID"',
                1,
            ),
            "triggering release workflow",
        )

    def test_exact_fork_recipe_staging_cannot_regress_to_overlay_copy(self) -> None:
        self._reject(
            "community-publish.yml",
            self._workflow("community-publish.yml").replace(
                "scripts.release.recipe stage-target",
                "scripts.release.recipe stage",
                1,
            ),
            "stage-target",
        )

    def test_publication_workflows_cannot_gain_oidc_authority(self) -> None:
        self._reject(
            "release.yml",
            self._workflow("release.yml").replace(
                "  actions: read\n",
                "  actions: read\n  id-token: write\n",
                1,
            ),
            "permission",
        )
        self._reject(
            "community-publish.yml",
            self._workflow("community-publish.yml").replace(
                "    environment: community-publish\n",
                "    environment: community-publish\n"
                "    permissions:\n"
                "      id-token: write\n",
                1,
            ),
            "permission",
        )

    def test_reviewed_action_cannot_move_to_an_arbitrary_full_sha(self) -> None:
        workflow = self._workflow("release.yml").replace(
            workflow_security.CHECKOUT_ACTION_SHA,
            "0" * 40,
            1,
        )
        with tempfile.TemporaryDirectory(prefix="mtest-action-pin-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_root = repo / ".github" / "workflows"
            workflow_root.mkdir(parents=True)
            (workflow_root / "release.yml").write_text(workflow, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "reviewed action pin"):
                workflow_security.check_action_pins(repo)

    def test_created_false_workflow_run_must_be_a_noop(self) -> None:
        self._reject(
            "community-publish.yml",
            self._workflow("community-publish.yml").replace(
                '            if test "$(jq -r .created "$evidence")" = "false"; then\n'
                "              active=false\n"
                "            fi\n",
                "",
                1,
            ),
            "created false",
        )

    def test_public_verification_cannot_gain_mutation_authority(self) -> None:
        workflow = self._workflow("community-verify.yml")
        self._reject(
            "community-verify.yml",
            workflow.replace("  contents: read\n", "  contents: write\n", 1),
            "permission",
        )

    def test_community_macos_runner_cannot_float(self) -> None:
        for workflow_name in ("community-publish.yml", "community-verify.yml"):
            workflow = self._workflow(workflow_name)
            self._reject(
                workflow_name,
                workflow.replace("runner: macos-26", "runner: macos-latest", 1),
                "macos-26|platform matrix",
            )


if __name__ == "__main__":
    unittest.main()
