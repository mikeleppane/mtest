#!/usr/bin/env python3
"""Pin hosted-workflow properties that PR review cannot see.

Every other change to this repository's CI configuration lands through a PR
where the diff to `pixi.toml` or `.github/workflows/ci.yml` is visible in
review, so this module does not mirror that topology. Topology mirroring (the
Pixi task graph, the hosted matrix rows) was removed from this module's
predecessor, `ci_topology.py`. Do not restore it here.

What review genuinely cannot see:

- An action referenced by a mutable tag (e.g. `actions/checkout@v7`) can be
  repointed by its upstream maintainer to a different commit with no diff in
  this repository at all, so every external action must be pinned to an
  immutable commit SHA.
- A one-line `permissions:` escalation buried in a large workflow PR is
  exactly the kind of change line-by-line review misses, so the CodeQL,
  documentation, and release/publication workflows' job permissions are pinned
  exactly, and `continue-on-error:` (which would let a failing security or
  gating step report green) is forbidden outright.
- The composite action this repository publishes runs in someone else's job,
  under someone else's token, and appears in no workflow diff here at all. It
  is reviewed on the same terms as anything else that runs in a job.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATHS = {
    Path(".github/workflows/ci.yml"),
    Path(".github/workflows/codeql.yml"),
    Path(".github/workflows/community-publish.yml"),
    Path(".github/workflows/community-verify.yml"),
    Path(".github/workflows/docs.yml"),
    Path(".github/workflows/release.yml"),
}
"""Every hosted workflow tracked by the repository."""

PUBLISHED_ACTION_PATH = Path("action.yml")
"""The composite action this repository publishes, consumed as `@v1`."""

CHECKOUT_ACTION_SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"
SETUP_PIXI_ACTION_SHA = "a09b6247153796b190642a2b53fac4241043cf6f"
CODEQL_ACTION_SHA = "e4fba868fa4b1b91e1fdab776edc8cfbe6e9fb81"
"""Reviewed immutable action revisions used by the CodeQL workflow."""

UPLOAD_ARTIFACT_ACTION_SHA = "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
"""Reviewed immutable actions/upload-artifact v7.0.1 revision."""

SETUP_UV_ACTION_SHA = "c771a70e6277c0a99b617c7a806ffedaca235ff9"
"""Reviewed immutable astral-sh/setup-uv v9.0.0 revision."""

DOWNLOAD_ARTIFACT_ACTION_SHA = "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"

UPLOAD_PAGES_ARTIFACT_ACTION_SHA = "fc324d3547104276b827a68afc52ff2a11cc49c9"
"""Reviewed immutable actions/upload-pages-artifact v5.0.0 revision."""

DEPLOY_PAGES_ACTION_SHA = "cd2ce8fcbc39b97be8ca5fce6e763baed58fa128"
"""Reviewed immutable actions/deploy-pages v5.0.0 revision.

This is the one action in the repository that is ever handed `pages: write` and
`id-token: write`, so it is also the one whose revision matters most.
"""

ACTION_USE_RE = re.compile(
    r"^\s*(?:-\s*)?uses:\s*"
    r"(?P<action>[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+)"
    r"@(?P<sha>[0-9a-f]{40})\s+#\s*(?P<version>\S+)\s*$"
)
"""An external action pinned by commit with a human-readable version."""

REVIEWED_ACTION_PINS = {
    "actions/checkout": {(CHECKOUT_ACTION_SHA, "v7.0.1")},
    "actions/deploy-pages": {(DEPLOY_PAGES_ACTION_SHA, "v5.0.0")},
    "actions/download-artifact": {(DOWNLOAD_ARTIFACT_ACTION_SHA, "v8.0.1")},
    "actions/upload-artifact": {(UPLOAD_ARTIFACT_ACTION_SHA, "v7.0.1")},
    "actions/upload-pages-artifact": {(UPLOAD_PAGES_ARTIFACT_ACTION_SHA, "v5.0.0")},
    "astral-sh/setup-uv": {(SETUP_UV_ACTION_SHA, "v9.0.0")},
    "github/codeql-action/analyze": {(CODEQL_ACTION_SHA, "v4.37.3")},
    "github/codeql-action/init": {(CODEQL_ACTION_SHA, "v4.37.3")},
    "prefix-dev/setup-pixi": {(SETUP_PIXI_ACTION_SHA, "v0.10.0")},
}
"""A tampered SHA fails even if it is a real, resolvable commit.

Pinning to *a* commit stops the upstream-repoint attack; pinning to *this
reviewed set* also stops a compromised or careless PR from swapping in some
other commit of the same action that nobody here has read.
"""


def _yaml_block(text: str, header: str) -> str:
    """Return the indented body under one exact YAML mapping header."""
    lines = text.splitlines()
    matches = [index for index, line in enumerate(lines) if line == header]
    if len(matches) != 1:
        raise AssertionError(
            f"workflow expected one {header!r} header, found {len(matches)}"
        )
    start = matches[0]
    indent = len(header) - len(header.lstrip(" "))
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        stripped = line.lstrip(" ")
        if not stripped or stripped.startswith("#"):
            continue
        line_indent = len(line) - len(stripped)
        if line_indent <= indent:
            end = index
            break
    return "\n".join(lines[start + 1 : end])


def _yaml_mapping_keys(block: str, indent: int) -> list[str]:
    """Return exact mapping keys at one absolute indentation level."""
    prefix = re.escape(" " * indent)
    pattern = re.compile(rf"^{prefix}([A-Za-z0-9_-]+):(?:\s.*)?$")
    return [
        match.group(1)
        for line in block.splitlines()
        if (match := pattern.match(line)) is not None
    ]


def _action_step_inputs(text: str, action: str) -> list[tuple[int, dict[str, str]]]:
    """Return scalar inputs for each use of one action in a workflow."""
    lines = text.splitlines()
    steps: list[tuple[int, dict[str, str]]] = []
    marker = f"uses: {action}@"
    for index, line in enumerate(lines):
        if marker not in line:
            continue
        uses_indent = len(line) - len(line.lstrip(" "))
        step_indent = uses_indent - 2
        input_indent = uses_indent + 2
        end = len(lines)
        for candidate_index in range(index + 1, len(lines)):
            candidate = lines[candidate_index]
            stripped = candidate.lstrip(" ")
            if not stripped or stripped.startswith("#"):
                continue
            indent = len(candidate) - len(stripped)
            if indent <= step_indent:
                end = candidate_index
                break
        inputs: dict[str, str] = {}
        pattern = re.compile(rf"^{' ' * input_indent}([A-Za-z0-9_-]+):\s*(\S+)\s*$")
        for candidate in lines[index + 1 : end]:
            match = pattern.fullmatch(candidate)
            if match is not None:
                inputs[match.group(1)] = match.group(2)
        steps.append((index + 1, inputs))
    return steps


def _permission_grants(block: str) -> tuple[str, ...]:
    """Return the grants in one `permissions:` body, in order.

    `_yaml_block` carries trailing comment lines along with the body it
    returns, because a comment cannot end a YAML block. A grant list has to
    compare equal against the grants alone, so those are dropped here rather
    than at each call site.

    Args:
        block: The indented body under a `permissions:` header.

    Returns:
        Each `<scope>: <level>` grant, stripped, in the order written.
    """
    return tuple(
        stripped
        for line in block.splitlines()
        if (stripped := line.strip()) and not stripped.startswith("#")
    )


def check_workflow_inventory(repo_root: Path = REPO_ROOT) -> None:
    """Require the exact, regular-file workflow set."""
    workflow_root = repo_root / ".github" / "workflows"
    actual = {
        path.relative_to(repo_root)
        for pattern in ("*.yml", "*.yaml")
        for path in workflow_root.glob(pattern)
    }
    if actual != WORKFLOW_PATHS:
        raise AssertionError(
            "workflow inventory mismatch: "
            f"expected={sorted(map(str, WORKFLOW_PATHS))}, "
            f"actual={sorted(map(str, actual))}"
        )
    symlinks = sorted(
        str(path.relative_to(repo_root))
        for path in workflow_root.iterdir()
        if path.is_symlink()
    )
    if symlinks:
        raise AssertionError(f"workflow inventory contains symlinks: {symlinks}")


def check_action_pins(repo_root: Path = REPO_ROOT) -> None:
    """Require immutable revisions and version comments for external actions."""
    workflow_root = repo_root / ".github" / "workflows"
    for pattern in ("*.yml", "*.yaml"):
        for path in sorted(workflow_root.glob(pattern)):
            for line_number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(),
                start=1,
            ):
                if not re.match(r"^\s*(?:-\s*)?uses:", line):
                    continue
                value = line.split("uses:", 1)[1].strip()
                if value.startswith("./"):
                    continue
                match = ACTION_USE_RE.fullmatch(line)
                if match is None:
                    relative = path.relative_to(repo_root)
                    raise AssertionError(
                        "action pin must use a full commit SHA and version "
                        f"comment: {relative}:{line_number}: {line.strip()}"
                    )
                pin = (match.group("sha"), match.group("version"))
                if pin not in REVIEWED_ACTION_PINS.get(match.group("action"), set()):
                    relative = path.relative_to(repo_root)
                    raise AssertionError(
                        "reviewed action pin mismatch: "
                        f"{relative}:{line_number}: {line.strip()}"
                    )


def check_codeql_workflow(repo_root: Path = REPO_ROOT) -> None:
    """Pin CodeQL triggers, permissions, jobs, builds, and action revisions."""
    workflow_path = repo_root / ".github" / "workflows" / "codeql.yml"
    workflow = workflow_path.read_text(encoding="utf-8")
    if not workflow.startswith("name: CodeQL\n"):
        raise AssertionError("CodeQL workflow name mismatch")
    if "continue-on-error:" in workflow:
        raise AssertionError("CodeQL workflow must not contain continue-on-error")
    if "autobuild" in workflow.lower():
        raise AssertionError("CodeQL workflow must not use autobuild")

    trigger_block = _yaml_block(workflow, "on:")
    expected_triggers = ["push", "pull_request", "schedule", "workflow_dispatch"]
    triggers = _yaml_mapping_keys(trigger_block, 2)
    if triggers != expected_triggers:
        raise AssertionError(
            f"CodeQL trigger mismatch: expected={expected_triggers}, actual={triggers}"
        )
    for trigger in ("push", "pull_request"):
        block = _yaml_block(workflow, f"  {trigger}:")
        if block.strip() != "branches: [main]":
            raise AssertionError(
                f"CodeQL trigger mismatch: {trigger} must target only main"
            )
    schedule = _yaml_block(workflow, "  schedule:")
    if schedule.strip() != '- cron: "23 4 * * 1"':
        raise AssertionError("CodeQL trigger mismatch: weekly schedule changed")
    if _yaml_block(workflow, "  workflow_dispatch:").strip():
        raise AssertionError("CodeQL trigger mismatch: workflow_dispatch has inputs")

    permission_block = _yaml_block(workflow, "permissions:")
    expected_permissions = {
        "contents": "read",
        "actions": "read",
        "security-events": "write",
    }
    permissions = dict(
        re.findall(r"^  ([a-z-]+): (read|write|none)$", permission_block, re.MULTILINE)
    )
    if permissions != expected_permissions or _yaml_mapping_keys(
        permission_block, 2
    ) != list(expected_permissions):
        raise AssertionError(
            "CodeQL permission mismatch: "
            f"expected={expected_permissions}, actual={permissions}"
        )

    jobs = _yaml_mapping_keys(_yaml_block(workflow, "jobs:"), 2)
    expected_jobs = ["c-cpp", "python"]
    if jobs != expected_jobs:
        raise AssertionError(
            f"CodeQL job membership mismatch: expected={expected_jobs}, actual={jobs}"
        )
    job_blocks = {name: _yaml_block(workflow, f"  {name}:") for name in jobs}
    expected_names = {"c-cpp": "C and C++", "python": "Python"}
    for name, job in job_blocks.items():
        display = re.findall(r"^    name: (.+)$", job, re.MULTILINE)
        if display != [expected_names[name]]:
            raise AssertionError(
                f"CodeQL job {name!r} display mismatch: actual={display}"
            )
        runners = re.findall(r"^    runs-on: (.+)$", job, re.MULTILINE)
        if runners != ["ubuntu-24.04"]:
            raise AssertionError(
                f"CodeQL job {name!r} runner mismatch: actual={runners}"
            )
        if re.search(r"^    (if|needs):", job, re.MULTILINE):
            raise AssertionError(f"CodeQL job {name!r} must run independently")

    expected_uses = {
        "c-cpp": [
            f"actions/checkout@{CHECKOUT_ACTION_SHA}",
            f"prefix-dev/setup-pixi@{SETUP_PIXI_ACTION_SHA}",
            f"github/codeql-action/init@{CODEQL_ACTION_SHA}",
            f"github/codeql-action/analyze@{CODEQL_ACTION_SHA}",
        ],
        "python": [
            f"actions/checkout@{CHECKOUT_ACTION_SHA}",
            f"github/codeql-action/init@{CODEQL_ACTION_SHA}",
            f"github/codeql-action/analyze@{CODEQL_ACTION_SHA}",
        ],
    }
    expected_pin_lines = {
        f"        uses: actions/checkout@{CHECKOUT_ACTION_SHA} # v7.0.1",
        f"        uses: prefix-dev/setup-pixi@{SETUP_PIXI_ACTION_SHA} # v0.10.0",
        f"        uses: github/codeql-action/init@{CODEQL_ACTION_SHA} # v4.37.3",
        f"        uses: github/codeql-action/analyze@{CODEQL_ACTION_SHA} # v4.37.3",
    }
    for name, job in job_blocks.items():
        uses = re.findall(r"^        uses: ([^ ]+)(?: # .*)?$", job, re.MULTILINE)
        if uses != expected_uses[name]:
            raise AssertionError(
                f"CodeQL action pin mismatch in {name!r}: "
                f"expected={expected_uses[name]}, actual={uses}"
            )
        actual_pin_lines = {
            line for line in job.splitlines() if line.lstrip().startswith("uses:")
        }
        required_pin_lines = {
            line
            for line in expected_pin_lines
            if line.split("uses: ", 1)[1].split("@", 1)[0]
            in {use.split("@", 1)[0] for use in expected_uses[name]}
        }
        if actual_pin_lines != required_pin_lines:
            raise AssertionError(f"CodeQL action version comments mismatch in {name!r}")

    native = job_blocks["c-cpp"]
    native_runs = re.findall(r"^        run: (.+)$", native, re.MULTILINE)
    if native_runs != ["pixi run build-native"]:
        raise AssertionError(
            "CodeQL native manual build mismatch: "
            f"expected=['pixi run build-native'], actual={native_runs}"
        )
    if "          locked: true" not in native or "          cache: true" not in native:
        raise AssertionError("CodeQL native job lacks locked cached Pixi setup")
    native_language = re.findall(
        r"^          languages: (.+)$",
        _yaml_block(native, "      - name: Initialize CodeQL"),
        re.MULTILINE,
    )
    if native_language != ["c-cpp"]:
        raise AssertionError(
            f"CodeQL native language mismatch: actual={native_language}"
        )
    native_category = re.findall(
        r"^          category: (.+)$",
        _yaml_block(native, "      - name: Analyze C and C++"),
        re.MULTILINE,
    )
    if native_category != ['"/language:c-cpp"']:
        raise AssertionError(
            f"CodeQL native analysis category mismatch: actual={native_category}"
        )
    init_index = native.index("      - name: Initialize CodeQL")
    build_index = native.index("      - name: Build native adapter")
    analyze_index = native.index("      - name: Analyze C and C++")
    if not init_index < build_index < analyze_index:
        raise AssertionError("CodeQL native init/build/analyze order mismatch")

    python = job_blocks["python"]
    if re.search(r"^        run:", python, re.MULTILINE):
        raise AssertionError("CodeQL Python job must not run shell commands")
    python_language = re.findall(
        r"^          languages: (.+)$",
        _yaml_block(python, "      - name: Initialize CodeQL"),
        re.MULTILINE,
    )
    if python_language != ["python"]:
        raise AssertionError(
            f"CodeQL Python language mismatch: actual={python_language}"
        )
    python_category = re.findall(
        r"^          category: (.+)$",
        _yaml_block(python, "      - name: Analyze Python"),
        re.MULTILINE,
    )
    if python_category != ['"/language:python"']:
        raise AssertionError(
            f"CodeQL Python analysis category mismatch: actual={python_category}"
        )


def check_docs_workflow(repo_root: Path = REPO_ROOT) -> None:
    """Pin the documentation workflow's privilege, triggers, and build entry.

    This is the only workflow in the repository that is ever granted
    `pages: write` and `id-token: write`, and the release oracle below reads
    three named files, so without this check a publishing workflow would be
    governed by nothing but the inventory and the action pins. What it holds:

    - the top-level grant stays `contents: read`, and the deploy job is the one
      place that widens it;
    - the deploy job publishes only from a push to main, so a pull request from
      a fork reaches the build and stops;
    - the site builds on `pull_request`, because a site that no longer builds
      must fail on the change that broke it rather than on main afterwards;
    - the build shells out to the documentation-build task and nothing else, so
      the pinned tool versions cannot differ between here and a local run;
    - no `continue-on-error:`, which on the build step would turn a strict build
      into decoration.

    Args:
        repo_root: Repository root holding `.github/workflows/docs.yml`.

    Raises:
        AssertionError: The workflow violates one of the properties above.
        OSError: The workflow could not be read.
    """
    workflow_path = repo_root / ".github" / "workflows" / "docs.yml"
    workflow = workflow_path.read_text(encoding="utf-8")
    if not workflow.startswith("name: Docs\n"):
        raise AssertionError("docs workflow name mismatch")
    if "continue-on-error:" in workflow:
        raise AssertionError("docs workflow must not contain continue-on-error")

    expected_triggers = ["pull_request", "push", "workflow_dispatch"]
    triggers = _yaml_mapping_keys(_yaml_block(workflow, "on:"), 2)
    if triggers != expected_triggers:
        raise AssertionError(
            "docs trigger mismatch: the site must build on every pull request, "
            f"expected={expected_triggers}, actual={triggers}"
        )
    if _yaml_block(workflow, "  pull_request:").strip():
        raise AssertionError("docs trigger mismatch: pull_request must not be narrowed")
    if _yaml_block(workflow, "  push:").strip() != "branches: [main]":
        raise AssertionError("docs trigger mismatch: push must target only main")

    top_level_permissions = _permission_grants(_yaml_block(workflow, "permissions:"))
    if top_level_permissions != ("contents: read",):
        raise AssertionError(
            "docs workflow permission mismatch: "
            f"expected=('contents: read',), actual={top_level_permissions}"
        )

    expected_jobs = ["build", "deploy"]
    jobs = _yaml_mapping_keys(_yaml_block(workflow, "jobs:"), 2)
    if jobs != expected_jobs:
        raise AssertionError(
            f"docs job membership mismatch: expected={expected_jobs}, actual={jobs}"
        )
    build_job = _yaml_block(workflow, "  build:")
    deploy_job = _yaml_block(workflow, "  deploy:")

    job_permission_headers = re.findall(r"^    permissions:$", workflow, re.MULTILINE)
    if job_permission_headers != ["    permissions:"]:
        raise AssertionError("docs job permission override membership changed")
    expected_deploy_permissions = ("contents: read", "pages: write", "id-token: write")
    deploy_permissions = _permission_grants(_yaml_block(deploy_job, "    permissions:"))
    if deploy_permissions != expected_deploy_permissions:
        raise AssertionError(
            "docs deploy permission mismatch: "
            f"expected={expected_deploy_permissions}, actual={deploy_permissions}"
        )
    for privilege in ("pages: write", "id-token: write"):
        if workflow.count(privilege) != 1 or deploy_job.count(privilege) != 1:
            raise AssertionError(
                f"docs publication permission escaped the deploy job: {privilege}"
            )

    expected_condition = [
        "github.event_name == 'push' && github.ref == 'refs/heads/main'"
    ]
    condition = re.findall(r"^    if: (.+)$", deploy_job, re.MULTILINE)
    if condition != expected_condition:
        raise AssertionError(
            "docs deploy condition mismatch: the deploy job must publish only "
            f"from a main push, expected={expected_condition}, actual={condition}"
        )
    if re.findall(r"^    needs: (.+)$", deploy_job, re.MULTILINE) != ["build"]:
        raise AssertionError("docs deploy job must wait for the build job")
    environment = _yaml_mapping_keys(_yaml_block(deploy_job, "    environment:"), 6)
    if environment != ["name", "url"] or "      name: github-pages" not in deploy_job:
        raise AssertionError("docs deploy job must use the github-pages environment")

    expected_runs = ["pixi run docs-build"]
    runs = re.findall(r"^\s+run: (.+)$", workflow, re.MULTILINE)
    build_runs = re.findall(r"^\s+run: (.+)$", build_job, re.MULTILINE)
    if runs != expected_runs or build_runs != expected_runs:
        raise AssertionError(
            "docs build entry mismatch: the site must be built through the "
            f"documentation-build task alone, expected={expected_runs}, "
            f"actual={runs}"
        )

    uploads = [
        inputs.get("path")
        for _, inputs in _action_step_inputs(workflow, "actions/upload-pages-artifact")
    ]
    if uploads != ["build/site"]:
        raise AssertionError(
            "docs artifact path mismatch: the uploaded directory must be the "
            f"configured site output, actual={uploads}"
        )


def check_published_action(repo_root: Path = REPO_ROOT) -> None:
    """Review the composite action this repository publishes to consumers.

    Every other oracle here governs an action this repository *consumes*. The
    root `action.yml` is the one it *publishes*: a consumer adopts it by writing
    a single `uses:` line and inherits whatever it does, in their job, with
    their token. Nothing else in the tree looks at it, so it is reviewed here on
    the same terms as anything else that runs in a job.

    What this holds:

    - `runs.using: composite`, so the action stays a wrapper around shell steps
      this repository can read rather than a JavaScript or container entry point
      whose behaviour lives in a built artifact;
    - no `continue-on-error:`, which would let a failing test run report green
      in a consumer's workflow — the exact outcome the product exists to
      prevent;
    - no `secrets.` and no `github.token` reference;
    - any `uses:` inside it pinned to a 40-hex commit SHA carrying a trailing
      version comment and present in `REVIEWED_ACTION_PINS`, exactly as
      `check_action_pins` requires of the workflows. A relative `./` reference
      is rejected rather than skipped as it is there: inside a published
      composite action `./` resolves against the *consumer's* checkout, which
      is a path this repository cannot review at all. Today the action
      references nothing, and this rule is what keeps that a decision instead
      of an accident.

    There is deliberately no `permissions:` assertion, and a reader who expects
    one should not conclude the review is incomplete. A composite action cannot
    declare a `permissions:` block; it runs inside the calling job and inherits
    that job's token whatever the caller granted. The reviewable property is
    therefore not which permissions the action requests but whether it touches
    the caller's credentials at all, which is what the two credential rules
    above assert.

    Args:
        repo_root: Repository root holding the published `action.yml`.

    Raises:
        AssertionError: The action violates one of the properties above.
        OSError: The action could not be read. A published action that has been
            deleted or renamed is a gate failure, not a silent pass.
    """
    action_path = repo_root / PUBLISHED_ACTION_PATH
    action = action_path.read_text(encoding="utf-8")

    using = re.findall(r"^  using: (.+)$", _yaml_block(action, "runs:"), re.MULTILINE)
    if using != ["composite"]:
        raise AssertionError(
            "the published action must be a composite action: "
            f"expected=['composite'], actual={using}"
        )
    if "continue-on-error:" in action:
        raise AssertionError(
            "the published action must not contain continue-on-error: a step "
            "that fails must fail the consumer's job"
        )
    for credential in ("secrets.", "github.token"):
        if credential in action:
            raise AssertionError(
                "the published action must contain no credential reference: "
                f"{credential}"
            )

    for line_number, line in enumerate(action.splitlines(), start=1):
        if not re.match(r"^\s*(?:-\s*)?uses:", line):
            continue
        match = ACTION_USE_RE.fullmatch(line)
        if match is None:
            raise AssertionError(
                "published action pin must use a full commit SHA and version "
                f"comment: {PUBLISHED_ACTION_PATH}:{line_number}: {line.strip()}"
            )
        pin = (match.group("sha"), match.group("version"))
        if pin not in REVIEWED_ACTION_PINS.get(match.group("action"), set()):
            raise AssertionError(
                "reviewed action pin mismatch: "
                f"{PUBLISHED_ACTION_PATH}:{line_number}: {line.strip()}"
            )


def check_release_workflows(repo_root: Path = REPO_ROOT) -> None:
    """Pin publication authority, evidence, platform, and no-op boundaries."""
    workflow_root = repo_root / ".github" / "workflows"
    release = (workflow_root / "release.yml").read_text(encoding="utf-8")
    community = (workflow_root / "community-publish.yml").read_text(encoding="utf-8")
    verify = (workflow_root / "community-verify.yml").read_text(encoding="utf-8")

    expected_names = {
        "release.yml": "name: Release\n",
        "community-publish.yml": "name: Community Publish\n",
        "community-verify.yml": "name: Community Verify\n",
    }
    for name, prefix in expected_names.items():
        text = {
            "release.yml": release,
            "community-publish.yml": community,
            "community-verify.yml": verify,
        }[name]
        if not text.startswith(prefix):
            raise AssertionError(f"{name} workflow name mismatch")
        if "continue-on-error:" in text:
            raise AssertionError(f"{name} must not contain continue-on-error")
        for line_number, inputs in _action_step_inputs(
            text,
            "prefix-dev/setup-pixi",
        ):
            if inputs.get("run-install") != "false":
                continue
            invalid = [key for key in ("cache", "locked") if inputs.get(key) == "true"]
            if invalid:
                raise AssertionError(
                    f"{name}:{line_number}: setup-pixi with run-install false "
                    f"cannot enable {', '.join(invalid)}"
                )

    def require_permissions(
        text: str,
        header: str,
        expected: tuple[str, ...],
        label: str,
    ) -> None:
        actual = tuple(
            line.strip()
            for line in _yaml_block(text, header).splitlines()
            if line.strip()
        )
        if actual != expected:
            raise AssertionError(
                f"{label} permission mismatch: expected={expected}, actual={actual}"
            )

    require_permissions(
        release,
        "permissions:",
        ("contents: read", "actions: read"),
        "release workflow",
    )
    require_permissions(
        community,
        "permissions:",
        ("contents: read", "actions: read"),
        "community workflow",
    )
    require_permissions(
        verify,
        "permissions:",
        ("contents: read",),
        "community verification workflow",
    )
    if re.findall(r"^    permissions:$", release, re.MULTILINE) != ["    permissions:"]:
        raise AssertionError("release job permission override membership changed")
    if re.search(r"^    permissions:$", community + verify, re.MULTILINE):
        raise AssertionError("read-only publication jobs must not override permissions")

    release_jobs = _yaml_mapping_keys(_yaml_block(release, "jobs:"), 2)
    if release_jobs != ["validate", "release"]:
        raise AssertionError(f"release job membership mismatch: {release_jobs}")
    release_job = _yaml_block(release, "  release:")
    validate_job = _yaml_block(release, "  validate:")
    if "    environment: github-release\n" not in release_job:
        raise AssertionError("release job must use github-release environment")
    if "environment:" in validate_job or "contents: write" in validate_job:
        raise AssertionError("release validation must remain unprivileged")
    if "      contents: write\n" not in release_job:
        raise AssertionError("only protected release may receive contents write")
    if release_job.count("          persist-credentials: false") != 1:
        raise AssertionError("protected release must not persist its write credential")
    require_permissions(
        release_job,
        "    permissions:",
        ("contents: write", "actions: read"),
        "protected release job",
    )
    if release.count("contents: write") != 1:
        raise AssertionError("release contents write authority is not isolated")
    sentinels = (
        "vars.RELEASE_ENVIRONMENT_CONFIGURED",
        "vars.RELEASE_IMMUTABILITY_CONFIGURED",
    )
    if any(release_job.count(sentinel) != 1 for sentinel in sentinels):
        raise AssertionError("release protected-environment sentinel mismatch")
    evidence_counts = {
        "actions/workflows/ci.yml/runs?": 2,
        ".immutable == true": 1,
        "scripts.release.attestations candidate validate": 2,
        "scripts.release.github_release classify": 2,
        "repos/$GITHUB_REPOSITORY/branches/main": 2,
    }
    for marker, expected in evidence_counts.items():
        if release.count(marker) != expected:
            raise AssertionError(
                "release evidence check count mismatch: "
                f"marker={marker!r}, expected={expected}, "
                f"actual={release.count(marker)}"
            )
    if (
        release.count(".workflow_id == $workflow_id") != 2
        or release.count('.path == ".github/workflows/community-publish.yml"') != 2
    ):
        raise AssertionError("candidate workflow identity is not revalidated exactly")
    forbidden_release_mutations = ("git push", "git tag", "git reset")
    if any(command in release for command in forbidden_release_mutations):
        raise AssertionError("release must mutate tags only through the GitHub API")

    community_jobs = _yaml_mapping_keys(_yaml_block(community, "jobs:"), 2)
    expected_community_jobs = [
        "resolve",
        "render",
        "validate",
        "validate-selector",
        "candidate-result",
        "prepare",
    ]
    if community_jobs != expected_community_jobs:
        raise AssertionError(
            "community job membership mismatch: "
            f"expected={expected_community_jobs}, actual={community_jobs}"
        )
    prepare = _yaml_block(community, "  prepare:")
    if "    environment: community-publish\n" not in prepare:
        raise AssertionError("prepare job must use community-publish environment")
    if community.count("secrets.COMMUNITY_FORK_TOKEN") != prepare.count(
        "secrets.COMMUNITY_FORK_TOKEN"
    ):
        raise AssertionError("fork token reference escaped the prepare job")
    if "vars.COMMUNITY_ENVIRONMENT_CONFIGURED" not in prepare:
        raise AssertionError("community protected-environment sentinel is missing")
    created_false_noop = (
        'if test "$(jq -r .created "$evidence")" = "false"; then\n'
        "              active=false\n"
        "            fi"
    )
    if created_false_noop not in community:
        raise AssertionError("created false release must be an explicit no-op")
    if (
        community.count('test "$WORKFLOW_RUN_PATH" = ".github/workflows/release.yml"')
        != 1
        or community.count(
            'gh api "repos/$GITHUB_REPOSITORY/actions/workflows/release.yml"'
        )
        != 1
        or community.count('test "$WORKFLOW_RUN_WORKFLOW_ID" = "$release_workflow_id"')
        != 1
        or community.count('test "$WORKFLOW_DEFINITION_SHA" = "$WORKFLOW_RUN_SHA"') != 1
    ):
        raise AssertionError("triggering release workflow identity is not exact")
    ci_endpoint = "actions/workflows/ci.yml/runs?"
    prepare_start = community.find('            if test "$mode" = "prepare"; then\n')
    prepare_end_marker = '              test -n "$tag"\n            fi'
    prepare_end = community.find(prepare_end_marker, prepare_start)
    if (
        community.count(ci_endpoint) != 1
        or prepare_start < 0
        or prepare_end < prepare_start
        or ci_endpoint
        not in community[prepare_start : prepare_end + len(prepare_end_marker)]
    ):
        raise AssertionError("manual prepare CI gate is not isolated from dry run")
    required_community_markers = (
        "github.event.workflow_run.conclusion == 'success'",
        'test "$GITHUB_REF_NAME" = "$DEFAULT_BRANCH"',
        "repos/$GITHUB_REPOSITORY/branches/main",
        "repos/modular/modular-community/commits/main",
        "pixi run lint",
        "pixi run build-all",
        "pulls/$pull_number",
        "api.github.com/repos/$FORK_OWNER/modular-community",
        "scripts.release.community fork",
        "scripts.release.recipe stage-target",
        "--target-platform linux-aarch64",
        "--force-with-lease=",
        "if-no-files-found: error",
    )
    for marker in required_community_markers:
        if marker not in community:
            raise AssertionError(f"community publication check missing: {marker}")
    if "--skip-existing" in community:
        raise AssertionError("skip-existing output cannot prove package creation")
    if "target_commitish ==" in release + community + verify:
        raise AssertionError("release identity must come from dereferenced tags")
    for runner in ("ubuntu-24.04", "macos-26"):
        if community.count(f"runner: {runner}") != 1:
            raise AssertionError(f"community supported-platform matrix lost {runner}")
    if 'test -n "$tag"' not in community:
        raise AssertionError("manual prepare must require a stable release tag")

    verify_jobs = _yaml_mapping_keys(_yaml_block(verify, "jobs:"), 2)
    if verify_jobs != ["verify"]:
        raise AssertionError(f"community verification job mismatch: {verify_jobs}")
    if (
        "contents: write" in verify
        or "secrets." in verify
        or re.search(r"^    environment:", verify, re.MULTILINE)
        or "community-publish.yml" in verify
    ):
        raise AssertionError("community verification must remain read-only")
    if (
        verify.count("runner: ubuntu-24.04") != 1
        or verify.count("runner: macos-26") != 1
    ):
        raise AssertionError("community verification platform matrix mismatch")
    if "scripts.release.public_verify" not in verify:
        raise AssertionError("community verification must call the public verifier")


def main() -> int:
    """Run the independent workflow-security oracles."""
    try:
        check_workflow_inventory()
        check_action_pins()
        check_codeql_workflow()
        check_docs_workflow()
        check_published_action()
        check_release_workflows()
    except (AssertionError, OSError) as exc:
        print(f"workflow-security-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("workflow-security-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
