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
  is reviewed on the same terms as anything else that runs in a job: what its
  steps actually execute, in which shell, which environment names they bind,
  with which expressions substituted into the script text, and with no way to
  report green after a failing run.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys
from typing import NoReturn


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATHS = {
    Path(".github/workflows/ci.yml"),
    Path(".github/workflows/codeql.yml"),
    Path(".github/workflows/community-publish.yml"),
    Path(".github/workflows/community-verify.yml"),
    Path(".github/workflows/compat-canary.yml"),
    Path(".github/workflows/docs.yml"),
    Path(".github/workflows/release.yml"),
}
"""Every hosted workflow tracked by the repository."""

PUBLISHED_ACTION_PATH = Path("action.yml")
"""The composite action this repository publishes, consumed as `@v1`."""

PUBLISHED_ACTION_RUNS = ("pixi run mtest $MTEST_PATHS $MTEST_ARGS",)
"""The exact shell command the published action is allowed to run, in order.

Pinning the text rather than a shape is what makes the review real. The
composite runs in a consumer's job under a consumer's token, so "it invokes
mtest somehow" is not a property anyone can act on; `curl ... | bash` satisfies
it. One entry also pins the step count, because a second `run:` step would have
to appear here to pass.
"""

PUBLISHED_ACTION_EXPRESSION_LINES = (
    "        MTEST_PATHS: ${{ inputs.paths }}",
    "        MTEST_ARGS: ${{ inputs.args }}",
)
"""The only lines of the composite that may carry a `${{ }}` expression.

GitHub substitutes an expression into the script text before bash parses it, so
an expression on a `run:` line is a command-injection sink: a consumer writing
`args: ${{ github.event.pull_request.title }}` would execute the title. Passing
the inputs through `env:` and expanding them as shell variables keeps the
documented word-splitting while leaving nothing for the substitution to inject
into, and pinning these two lines is what stops the sink from coming back.
"""

PUBLISHED_ACTION_ENV_KEYS = ("MTEST_PATHS", "MTEST_ARGS")
"""The only environment keys the composite may bind, in order.

Constraining what an `env:` line may *substitute* leaves what it may *name*
open, and the name alone is enough to run code. GitHub executes a
`shell: bash` step as `bash --noprofile --norc -eo pipefail`, and `--norc` does
not suppress `BASH_ENV`: a non-interactive bash sources whatever that variable
names before it reads the script. So a static, expression-free
`BASH_ENV: ./hook.sh` would execute arbitrary code in the consumer's job ahead
of the reviewed command while satisfying every other rule here, and `PATH`,
`LD_PRELOAD` and `SHELLOPTS` each reach the same place by a different route.

This pins the whole key set rather than rejecting the names known to be
dangerous today. An allow-list of dangerous names is a race against every
future runner image and shell release, and losing it is silent; an exact key
set fails closed on a name nobody here has read, whatever it turns out to do.
"""

CANARY_LANES = ("stable", "nightly")
"""The lanes the compatibility canary probes, in the order the workflow lists.

Restated here rather than imported from `scripts.canary.toolchain`: this module
is the workflow's side of that contract, and an oracle that derived its
expectation from the code it governs would agree with any lane set the code
happened to grow.
"""

CANARY_PIXI_VERSION = "v0.72.0"
"""The pixi release the compatibility canary provisions.

Everything the probe learns about the channels arrives through
`pixi search --json`, and `scripts/canary/run.py` reads that answer as the
subdir-keyed object pixi documents. `prefix-dev/setup-pixi` installs the newest
release when it is given no version, so an unpinned canary probes with a tool
that changes under it: the day the answer's shape moves, both lanes stop
probing at once. This is the release that shape was read against.
"""

CANARY_ARTIFACT_PREFIX = "canary-result-"
CANARY_RESULTS_ROOT = "build/canary-results/"
"""Where one lane's uploaded classification is named, and where it lands.

`scripts/canary/notify.py` reads `<root>/<prefix><lane>/result.json`, and the
download that puts it there is pinned per lane below.
"""

CANARY_CANONICAL_NODE_RE = re.compile(
    r"^(?P<indent> *)(?P<dash>- )?(?P<key>[A-Za-z0-9_-]+):(?P<value>(?: .*)?)$"
)
"""The one line shape a mapping or sequence entry in the canary may take.

The key class is exactly `_yaml_mapping_keys`', and the colon must be followed
by end-of-line or a single space exactly as every `re.findall` over this
workflow assumes. A line this matches is a line those readers and YAML agree
about; a line it does not match is one they can disagree about, which is the
whole subject of `_require_canonical_canary`.
"""

CANARY_SEQUENCE_ENTRY_KEYS = frozenset({"cron", "name"})
"""The only keys a `- ` entry in the canary may open with.

An allow-list rather than a list of the dangerous openers. A step is collected
here as a `- name:` line, so a step written `- run:` or `- uses:` is a step to
YAML and to nothing in this module; refusing the two keys known to do that
leaves `- shell:`, `- with:` and whatever GitHub adds next.
"""

CANARY_BLOCK_MAPPING_KEYS = frozenset(
    {
        "concurrency",
        "env",
        "environment",
        "inputs",
        "jobs",
        "matrix",
        "on",
        "outputs",
        "permissions",
        "schedule",
        "secrets",
        "steps",
        "strategy",
        "with",
        "workflow_dispatch",
    }
)
"""Keys whose value is a collection, which must therefore be written as a block.

`env: {BASH_ENV: ./hook.sh}` and `permissions: {issues: write}` bind and grant
exactly what their block spellings do while sitting on one line that no header
scan here recognises. So does `env: ${{ fromJSON(...) }}`, where the mapping
does not exist until GitHub evaluates the expression. Requiring these keys to
carry nothing at all refuses every one of those without having to enumerate the
ways a collection can be spelled inline.

`defaults:`, `container:` and `services:` are deliberately absent: they are
refused outright below, in any form, and listing them here would answer a
`container: image` mutation with "outside the readable subset" instead of the
rule that actually governs it.
"""

CANARY_BLOCK_SCALAR_RE = re.compile(r"[|>][+-]?[0-9]*")
"""A `run: |` style indicator, which moves the value off the line naming it.

The reviewed commands are compared as whole `run:` lines. A block scalar puts
the command on the following lines instead, where no command scan, no
expression rule and no credential count looks at it.
"""

CANARY_FLOW_SEQUENCE_RE = re.compile(r"""\[[A-Za-z0-9_. ,'"-]*\]""")
"""The one inline collection the canary may write: a list of plain scalars.

`options: [stable, nightly]` is the closed lane choice, and it is compared as
written. Restricting the characters keeps `steps: [{run: ...}]` — a sequence of
mappings, which is where a step could hide — outside the subset.
"""

CREDENTIAL_REFERENCE_RE = re.compile(
    r"\bsecrets\s*(?:\.|\[)|\bgithub\s*(?:\.\s*token\b|\[\s*['\"]token['\"]\s*\])"
)
"""Any reference to the caller's credentials, in either GitHub expression form.

`secrets.NAME` and `secrets['NAME']` name the same value, as do `github.token`
and `github['token']`; a substring test for the dotted spelling alone rejects
the obvious write and accepts the bracket one beside it.
"""

STEP_CONDITION_RE = re.compile(r"(?m)^\s*(?:-\s*)?if:")
"""A step-level condition, which can turn a failing test run into a skipped one.

A skipped step is a green step. In a published test runner that is the exact
outcome the product exists to prevent, so the composite carries no condition at
all rather than a reviewed one.
"""

ALWAYS_SUCCEED_RE = re.compile(r"\|\|\s*true\b")
"""A trailing `|| true`, which discards the runner's exit code."""

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


def _env_bindings(block: str) -> list[str]:
    """Return every binding made by every block `env:` mapping, in order.

    Lines are returned whole rather than split into key and value, so a caller
    comparing the result against a reviewed list rejects a binding this cannot
    read instead of accepting a half-read one.

    What it does not see is the header: only a line whose stripped form is
    exactly `env:` opens a mapping here, so `env: {BASH_ENV: ./hook.sh}`,
    `"env":` and `env: &anchor` each bind names this returns nothing about. That
    is a completeness gap in the scanner, not in its callers, and it is why
    `_require_canonical_canary` refuses those spellings outright before the
    canary's bindings are compared. In the published `action.yml`,
    `check_published_action` carries the same burden through its expression and
    key pins.

    Args:
        block: The YAML body to scan, at whatever indentation it sits.

    Returns:
        One entry per line under every block `env:` header found, stripped, in
        document order.
    """
    lines = block.splitlines()
    bindings: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() != "env:":
            continue
        header_indent = len(line) - len(line.lstrip(" "))
        for candidate in lines[index + 1 :]:
            body = candidate.lstrip(" ")
            if not body or body.startswith("#"):
                continue
            if len(candidate) - len(body) <= header_indent:
                break
            bindings.append(body.rstrip())
    return bindings


def _env_keys(block: str) -> list[str]:
    """Return every key bound by every `env:` mapping in one block, in order.

    Args:
        block: The YAML body to scan, at whatever indentation it sits.

    Returns:
        One entry per key under every `env:` header found, in document order.
    """
    return [binding.split(":", 1)[0].strip() for binding in _env_bindings(block)]


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


def _action_step_with_entries(text: str, action: str) -> list[tuple[str, ...]]:
    """Return each use of one action's `with:` body, line by line, in order.

    `_action_step_inputs` reads a step's inputs into a mapping and silently
    drops any line it cannot read as `KEY: <one token>` — which is every value
    carrying a space, including every `${{ }}` expression. That is safe for a
    caller asking whether one named input has one named value, and unsafe for a
    caller pinning the whole input map, because the input most worth seeing is
    the one most likely to be dropped. This returns the lines instead, so an
    input nobody here has read cannot pass by being unparseable.

    Args:
        text: The workflow or action text to scan.
        action: The action whose uses to collect, without the `@revision`.

    Returns:
        One tuple per use of the action, in document order, holding that step's
        `with:` entries stripped and in the order written. A step with no
        `with:` block yields an empty tuple.
    """
    lines = text.splitlines()
    marker = f"uses: {action}@"
    steps: list[tuple[str, ...]] = []
    for index, line in enumerate(lines):
        if marker not in line:
            continue
        step_indent = len(line) - len(line.lstrip(" ")) - 2
        end = len(lines)
        for candidate_index in range(index + 1, len(lines)):
            candidate = lines[candidate_index]
            stripped = candidate.lstrip(" ")
            if not stripped or stripped.startswith("#"):
                continue
            if len(candidate) - len(stripped) <= step_indent:
                end = candidate_index
                break
        body = lines[index + 1 : end]
        entries: list[str] = []
        for offset, candidate in enumerate(body):
            if candidate.strip() != "with:":
                continue
            header_indent = len(candidate) - len(candidate.lstrip(" "))
            for following in body[offset + 1 :]:
                stripped = following.lstrip(" ")
                if not stripped or stripped.startswith("#"):
                    continue
                if len(following) - len(stripped) <= header_indent:
                    break
                entries.append(stripped)
        steps.append(tuple(entries))
    return steps


def _block_entries(block: str) -> tuple[str, ...]:
    """Return the meaningful lines of one YAML body, stripped and in order.

    `_yaml_block` carries blank and comment lines along with the body it
    returns, because neither can end a YAML block. A body compared for equality
    has to compare against its entries alone, so those are dropped here rather
    than at each call site.

    Args:
        block: The indented body under a mapping header.

    Returns:
        Each entry, stripped, in the order written.
    """
    return tuple(
        stripped
        for line in block.splitlines()
        if (stripped := line.strip()) and not stripped.startswith("#")
    )


def _permission_grants(block: str) -> tuple[str, ...]:
    """Return the grants in one `permissions:` body, in order.

    Args:
        block: The indented body under a `permissions:` header.

    Returns:
        Each `<scope>: <level>` grant, stripped, in the order written.
    """
    return _block_entries(block)


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


def _require_canonical_canary(workflow: str) -> None:
    """Refuse a canary workflow written outside the subset read below.

    Every assertion in `check_compat_canary_workflow` is a regular expression
    over the workflow text, because `scripts/` carries no runtime dependencies
    and there is no YAML parser here to borrow. That is workable only while the
    file is written the one way those expressions read, and YAML does not
    enforce it: a step in inline sequence form opens with `- run:` rather than
    `- name:`, a mapping can be written between braces on the line that names
    it, a key can be quoted or padded away from its colon, an anchor can be
    expanded somewhere else entirely, and a command can live in a block scalar
    under the line naming it. Each parses to exactly the structure the block
    form parses to, and none of them is what a `^      - name: (.+)$` or a
    `line.strip() == "env:"` is looking at.

    Patching each spelling as it is found does not converge, because the next
    one nobody thought of is still accepted by default. So this states the
    subset positively — one line shape, one key class, one dash form, block
    collections only — and refuses everything else *before* any property below
    is asserted. A future YAML form these expressions cannot read is then a
    rejection with a line number rather than a silent pass, and the price is
    that the canary must be written the way it is written today.

    Args:
        workflow: The compatibility-canary workflow text.

    Raises:
        AssertionError: Some line falls outside the subset, naming the line
            number and the line.
    """

    def refuse(number: int, line: str, why: str) -> NoReturn:
        raise AssertionError(
            "compat canary is outside the readable subset: this file is "
            "reviewed by pattern rather than by a YAML parser, so a spelling "
            "those patterns cannot read is refused rather than reviewed "
            f"wrongly — line {number} {why}: {line!r}"
        )

    for number, line in enumerate(workflow.splitlines(), start=1):
        if "\t" in line:
            refuse(number, line, "indents with a tab, which is not YAML indentation")
        if line != line.rstrip():
            # A `(.+)$` capture reads trailing whitespace into the value it
            # pins, so two lines that differ only there compare unequal here
            # and identically to GitHub.
            refuse(number, line, "carries trailing whitespace")
        if not line or line.lstrip(" ").startswith("#"):
            continue
        match = CANARY_CANONICAL_NODE_RE.fullmatch(line)
        if match is None:
            refuse(
                number,
                line,
                "is neither blank, a comment, nor `<key>: <value>` with an "
                "unquoted key against its colon",
            )
        if len(match.group("indent")) % 2:
            # Odd indentation nests somewhere the fixed-indent scans below do
            # not read, while YAML nests it perfectly happily.
            refuse(number, line, "is indented an odd number of columns")
        key = match.group("key")
        value = match.group("value").strip()
        if match.group("dash") and key not in CANARY_SEQUENCE_ENTRY_KEYS:
            refuse(
                number,
                line,
                f"opens a sequence entry with {key!r} rather than "
                f"{sorted(CANARY_SEQUENCE_ENTRY_KEYS)}, so it is a step no step "
                "scan can see",
            )
        if key in CANARY_BLOCK_MAPPING_KEYS and value:
            refuse(
                number,
                line,
                f"gives {key!r} an inline value, and a collection written on "
                "the line that names it is read by no header scan here",
            )
        if value[:1] in {"{", "&", "*", "?", "!"}:
            refuse(
                number,
                line,
                "opens its value with a flow mapping, an anchor, an alias or a "
                "tag, none of which is where this file's value is read from",
            )
        if CANARY_BLOCK_SCALAR_RE.fullmatch(value):
            refuse(
                number,
                line,
                "moves its value into a block scalar, off the line every "
                "command, expression and credential scan here reads",
            )
        if value.startswith("[") and not CANARY_FLOW_SEQUENCE_RE.fullmatch(value):
            refuse(number, line, "writes an inline collection of anything but scalars")


def check_compat_canary_workflow(repo_root: Path = REPO_ROOT) -> None:
    """Pin the compatibility canary's credential split, schedule, and steps.

    This is the only workflow in the repository that downloads a compiler from a
    package channel and executes it against the source tree, and the only reason
    that is acceptable is the split between its two jobs: `probe` runs the
    downloaded compiler under no write scope at all, `notify` holds
    `issues: write` and runs one reviewed command over a JSON file. Neither half
    is safe alone, and nothing in a workflow diff makes it obvious that a step
    moved from one job to the other has crossed that line. So the split is
    pinned here, positively (what each job runs, in which order, with which
    grants) and negatively (what the privileged job may never contain).

    Every assertion here is a pattern over the workflow text, so the first one
    is about the text itself: `_require_canonical_canary` refuses any spelling
    those patterns cannot read — an inline sequence entry, a flow mapping, a
    quoted or padded key, an anchor, a block scalar — before a single property
    is asserted. Read that function before trusting anything below it. Without
    it each rule here governs one spelling of the thing it names and silently
    permits the others, which is how a step, an `env:` mapping and a whole third
    job can each be written where nothing looks.

    The probe job's property is stated as a scope rather than as an absence.
    GitHub mints a `GITHUB_TOKEN` for every job whether the workflow asks for
    one or not, so "the probe holds no token" is simply false, and a security
    oracle whose stated property is false is one nobody can reason from. What
    is true, and what is pinned below, is that the probe's grant is
    `contents: read` — the least a job that checks this repository out can be
    given — that its checkout sets `persist-credentials: false` so nothing
    lands in `.git/config` beside the downloaded compiler, and that the only
    environment binding this workflow makes in that job is the lane name. The
    runner's own variables are not this workflow's to constrain and are not
    claimed here.

    Within that subset, what a step or a job is handed is pinned by value rather
    than by shape. An `env:` mapping is compared binding by binding rather than
    key by key, because a key set that still reads `CANARY_LANES` says nothing
    about a job told to report on one lane and stay quiet about the other; a
    `with:` map is compared line by line for the same reason, because the input
    this workflow can least afford to have moved — the `repository:` and `ref:`
    the privileged job checks out and then executes — is spelled exactly like
    the input beside it. Credential references are counted in both expression
    forms, since `github.token` and `github['token']` name one value.

    Five keys are refused outright rather than reviewed: `defaults:`,
    `container:` and `services:` on a job, and `shell:` and
    `working-directory:` on a step. None appears in this workflow and each
    changes what a `run:` line executes without touching the line — a shell
    wrapper that sources a downloaded file before the reviewed command reaches
    it, a floating image that supplies the interpreter, or a directory that
    decides where `python3 -m` resolves `scripts.canary` from, which in the
    privileged job is the difference between this repository's notifier and
    one that arrived in an artifact. An allow-list of safe values for those
    keys is a review this repository would have to keep redoing; the absence is
    one it can keep.

    Beyond the security split, two functional properties are pinned because
    losing either leaves a workflow that runs, stays green, and reports nothing:

    - `run-install: false` on the pixi setup. Installing the environment in the
      workflow solves the committed `==` pin before the probe relaxes it, so the
      install resolves the pinned toolchain and every day classifies as
      "nothing newer" while looking healthy;
    - `if: always()` on the artifact upload, on the notify job, and on each
      notifier step that reports a lane. The classification artifact is the only
      thing the notifier reads, the days worth reading it are the ones where the
      probe job failed, and an unconditioned step is `if: success()` — so one
      download that threw would take the other lane's download and the upsert
      down with it, and a lane that found real drift would write no issue.
      Pinned by value rather than merely permitted: `always()` is the one
      condition that cannot skip a step, which is what the ban it replaced was
      protecting.

    Args:
        repo_root: Repository root holding `.github/workflows/compat-canary.yml`.

    Raises:
        AssertionError: The workflow violates one of the properties above.
        OSError: The workflow could not be read.
    """
    workflow_path = repo_root / ".github" / "workflows" / "compat-canary.yml"
    workflow = workflow_path.read_text(encoding="utf-8")
    # First, and before any property below is asserted: every one of them is a
    # pattern over this text, and a pattern is only a review while the text is
    # written the one way the pattern reads.
    _require_canonical_canary(workflow)
    if not workflow.startswith("name: Compat Canary\n"):
        raise AssertionError("compat canary workflow name mismatch")
    if "continue-on-error:" in workflow:
        raise AssertionError(
            "compat canary must not contain continue-on-error: a probe that "
            "reports green after failing says nothing about the toolchain"
        )
    if re.search(r"\bsecrets\s*(?:\.|\[)", workflow):
        raise AssertionError(
            "compat canary credential mismatch: the notifier uses the run's own "
            "token, so no configured secret may be referenced here"
        )
    substitution = re.search(
        r"(?m)^\s*(?:-\s*)?(defaults|container|services|shell|working-directory):",
        workflow,
    )
    if substitution is not None:
        raise AssertionError(
            "compat canary execution mismatch: `defaults:`, `container:`, "
            "`services:`, a step-level `shell:` and a step-level "
            "`working-directory:` each change what a `run:` line executes "
            "without changing the line — a wrapper that sources a downloaded "
            "file ahead of the reviewed command, an image that supplies the "
            "interpreter, or a directory the reviewed command resolves its own "
            "imports from — so none of them may appear here at all, found "
            f"{substitution.group(1)!r}"
        )

    expected_triggers = ["schedule", "workflow_dispatch"]
    triggers = _yaml_mapping_keys(_yaml_block(workflow, "on:"), 2)
    if triggers != expected_triggers:
        raise AssertionError(
            "compat canary trigger mismatch: the probe is scheduled and manually "
            f"dispatched, never event-driven, expected={expected_triggers}, "
            f"actual={triggers}"
        )
    schedule = _yaml_block(workflow, "  schedule:").strip()
    if schedule != '- cron: "41 1 * * 1-5"':
        raise AssertionError(
            f"compat canary trigger mismatch: weekday schedule changed: {schedule!r}"
        )
    expected_dispatch = (
        "    inputs:\n"
        "      channel:\n"
        '        description: "stable or nightly"\n'
        '        default: "stable"\n'
        "        type: choice\n"
        "        options: [stable, nightly]"
    )
    dispatch = _yaml_block(workflow, "  workflow_dispatch:").rstrip()
    if dispatch != expected_dispatch:
        raise AssertionError(
            "compat canary dispatch input mismatch: a closed choice of the two "
            "lanes is what makes a manual run reproducible and what stops an "
            f"operator string reaching the probe, actual={dispatch!r}"
        )

    top_level_permissions = _permission_grants(_yaml_block(workflow, "permissions:"))
    if top_level_permissions != ("contents: read",):
        raise AssertionError(
            "compat canary workflow permission mismatch: "
            f"expected=('contents: read',), actual={top_level_permissions}"
        )
    expected_concurrency = ("group: compat-canary", "cancel-in-progress: false")
    concurrency = _block_entries(_yaml_block(workflow, "concurrency:"))
    if concurrency != expected_concurrency:
        raise AssertionError(
            "compat canary concurrency mismatch: overlapping runs must queue, "
            "because two runs rewriting one pinned issue do not necessarily "
            f"finish in the order they started, expected={expected_concurrency}, "
            f"actual={concurrency}"
        )

    expected_jobs = ["probe", "notify"]
    jobs_block = _yaml_block(workflow, "jobs:")
    jobs = _yaml_mapping_keys(jobs_block, 2)
    # Read twice, once as keys the rest of this function can look up and once as
    # raw lines. The second reading assumes nothing about what a key may look
    # like, so a third job cannot become invisible by being spelled in some way
    # the key pattern happens not to match — which is the same failure the
    # canonical-subset check above refuses, asserted here where losing it would
    # cost the credential split rather than a diagnostic.
    job_lines = [line for line in jobs_block.splitlines() if re.match(r"^  \S", line)]
    if jobs != expected_jobs or job_lines != [f"  {name}:" for name in expected_jobs]:
        raise AssertionError(
            "compat canary job membership mismatch: the split into an "
            "unprivileged probe and a privileged notifier is the whole security "
            f"design, expected={expected_jobs}, actual={jobs or job_lines}"
        )
    probe = _yaml_block(workflow, "  probe:")
    notify = _yaml_block(workflow, "  notify:")

    # The run's own token, counted in both expression spellings rather than in
    # the one this file happens to use. `github.token` and `github['token']` name
    # the same value, and a count of the literal `${{ github.token }}` — inner
    # spaces and all — sees neither `${{github.token}}` nor the bracket form.
    credentials = CREDENTIAL_REFERENCE_RE.findall(workflow)
    if len(credentials) != 1 or CREDENTIAL_REFERENCE_RE.search(probe) is not None:
        raise AssertionError(
            "compat canary credential mismatch: exactly one credential "
            "reference belongs in this workflow and it belongs to the notifier "
            f"job, found {credentials}"
        )

    expected_job_names = {"probe": '"Probe / ${{ matrix.lane }}"', "notify": "Notify"}
    for name, job in (("probe", probe), ("notify", notify)):
        display = re.findall(r"^    name: (.+)$", job, re.MULTILINE)
        if display != [expected_job_names[name]]:
            raise AssertionError(
                f"compat canary job {name!r} display mismatch: actual={display}"
            )
        runners = re.findall(r"^    runs-on: (.+)$", job, re.MULTILINE)
        if runners != ["ubuntu-24.04"]:
            raise AssertionError(
                f"compat canary job {name!r} runner mismatch: actual={runners}"
            )
    expected_timeouts = {"probe": ["60"], "notify": ["20"]}
    for name, job in (("probe", probe), ("notify", notify)):
        timeouts = re.findall(r"^    timeout-minutes: (.+)$", job, re.MULTILINE)
        if timeouts != expected_timeouts[name]:
            raise AssertionError(
                f"compat canary job {name!r} timeout mismatch: a wedged stage "
                "must become a failed run rather than a job that never reports, "
                f"expected={expected_timeouts[name]}, actual={timeouts}"
            )

    if re.findall(r"^    needs: (.+)$", probe, re.MULTILINE) or re.findall(
        r"^    needs: (.+)$", notify, re.MULTILINE
    ) != ["probe"]:
        raise AssertionError(
            "compat canary notifier must wait for the probe: it reports what the "
            "probe wrote down"
        )
    if re.findall(r"^    if: (.+)$", probe, re.MULTILINE):
        raise AssertionError(
            "compat canary probe job condition mismatch: the probe runs on every "
            "scheduled and dispatched run"
        )
    if re.findall(r"^    if: (.+)$", notify, re.MULTILINE) != ["always()"]:
        raise AssertionError(
            "compat canary notifier condition mismatch: a lane whose probe job "
            "died is exactly the case a silent canary would hide, so the "
            "notifier must run whatever happened"
        )

    job_permission_headers = re.findall(r"^    permissions:$", workflow, re.MULTILINE)
    if len(job_permission_headers) != 2:
        raise AssertionError(
            "compat canary job permission mismatch: both jobs declare their own "
            f"grants, found {len(job_permission_headers)} overrides"
        )
    expected_permissions = {
        "probe": ("contents: read",),
        "notify": ("contents: read", "issues: write"),
    }
    for name, job in (("probe", probe), ("notify", notify)):
        grants = _permission_grants(_yaml_block(job, "    permissions:"))
        if grants != expected_permissions[name]:
            raise AssertionError(
                f"compat canary job {name!r} permission mismatch: the job that "
                "runs a downloaded compiler holds no write scope and the job "
                "that holds issue-write authority runs nothing, expected="
                f"{expected_permissions[name]}, actual={grants}"
            )
    # Counted over grant lines rather than over the whole text: the workflow's
    # own commentary names this grant while explaining why it is isolated.
    issue_grants = [
        line for line in workflow.splitlines() if line.strip() == "issues: write"
    ]
    if len(issue_grants) != 1 or notify.count("      issues: write") != 1:
        raise AssertionError(
            "compat canary permission mismatch: issue-write authority escaped "
            f"the notifier job, found {len(issue_grants)} grants"
        )
    if (
        workflow.count("          persist-credentials: false") != 2
        or probe.count("          persist-credentials: false") != 1
        or notify.count("          persist-credentials: false") != 1
    ):
        raise AssertionError(
            "compat canary checkout mismatch: both checkouts must set "
            "persist-credentials: false, or a token sits in `.git/config` while "
            "a downloaded compiler runs beside it"
        )

    expected_steps = {
        "probe": [
            "Check out sources",
            "Set up Pixi",
            "Probe the candidate toolchain",
            "Upload the classification",
        ],
        "notify": [
            "Check out sources",
            "Download the stable lane's classification",
            "Download the nightly lane's classification",
            "Upsert the pinned issues",
        ],
    }
    for name, job in (("probe", probe), ("notify", notify)):
        steps = re.findall(r"^      - name: (.+)$", job, re.MULTILINE)
        if steps != expected_steps[name]:
            raise AssertionError(
                f"compat canary job {name!r} step sequence mismatch: "
                f"expected={expected_steps[name]}, actual={steps}"
            )

    expected_pin_lines = {
        "probe": [
            f"        uses: actions/checkout@{CHECKOUT_ACTION_SHA} # v7.0.1",
            f"        uses: prefix-dev/setup-pixi@{SETUP_PIXI_ACTION_SHA} # v0.10.0",
            (
                "        uses: actions/upload-artifact@"
                f"{UPLOAD_ARTIFACT_ACTION_SHA} # v7.0.1"
            ),
        ],
        "notify": [
            f"        uses: actions/checkout@{CHECKOUT_ACTION_SHA} # v7.0.1",
            (
                "        uses: actions/download-artifact@"
                f"{DOWNLOAD_ARTIFACT_ACTION_SHA} # v8.0.1"
            ),
            (
                "        uses: actions/download-artifact@"
                f"{DOWNLOAD_ARTIFACT_ACTION_SHA} # v8.0.1"
            ),
        ],
    }
    for name, job in (("probe", probe), ("notify", notify)):
        pin_lines = [
            line for line in job.splitlines() if line.lstrip().startswith("uses:")
        ]
        if pin_lines != expected_pin_lines[name]:
            raise AssertionError(
                f"compat canary action pin mismatch in {name!r}: "
                f"expected={expected_pin_lines[name]}, actual={pin_lines}"
            )

    pixi_setups = _action_step_inputs(workflow, "prefix-dev/setup-pixi")
    expected_pixi_inputs = [
        {"pixi-version": CANARY_PIXI_VERSION, "run-install": "false"}
    ]
    if [inputs for _line, inputs in pixi_setups] != expected_pixi_inputs:
        raise AssertionError(
            "compat canary setup-pixi mismatch: the workflow provisions one "
            "reviewed pixi binary and nothing else. An install here would solve "
            "the committed `==` pin before the probe relaxes it, so the probe "
            "would resolve the pinned toolchain and classify every day as having "
            "nothing newer; an unpinned pixi floats to whatever released most "
            "recently, and the day `search --json` changes shape both lanes stop "
            f"probing at once, expected={expected_pixi_inputs}, "
            f"actual={[inputs for _line, inputs in pixi_setups]}"
        )

    # Every input every action is handed, by value. The checkout entries are
    # the load-bearing ones: `repository:` and `ref:` decide which tree the
    # privileged job clones and the probe job then executes, they are spelled
    # exactly like the `persist-credentials:` line beside them, and nothing
    # else here would notice them arriving.
    expected_step_inputs = {
        "actions/checkout": [
            ("persist-credentials: false",),
            ("persist-credentials: false",),
        ],
        "prefix-dev/setup-pixi": [
            (f"pixi-version: {CANARY_PIXI_VERSION}", "run-install: false"),
        ],
        "actions/upload-artifact": [
            ("name: canary-result-${{ matrix.lane }}", "path: build/canary/"),
        ],
    }
    for action, expected_inputs in expected_step_inputs.items():
        actual_inputs = _action_step_with_entries(workflow, action)
        if actual_inputs != expected_inputs:
            raise AssertionError(
                f"compat canary step input mismatch for {action}: every input "
                "each action is handed is reviewed by value, because the ones "
                "that decide which tree is checked out and executed read like "
                f"the ones beside them, expected={expected_inputs}, "
                f"actual={actual_inputs}"
            )

    expected_matrix = (
        "        lane: ${{ fromJSON(github.event_name == 'workflow_dispatch' && "
        'format(\'["{0}"]\', inputs.channel) || \'["stable","nightly"]\') }}'
    )
    expected_strategy = ("fail-fast: false", "matrix:", expected_matrix.strip())
    strategy = _block_entries(_yaml_block(probe, "    strategy:"))
    if strategy != expected_strategy or "    strategy:" in notify:
        raise AssertionError(
            "compat canary lane matrix mismatch: a scheduled run probes both "
            "lanes and a dispatch probes the requested one, neither lane's "
            "failure may cancel the other, and the privileged job carries no "
            f"matrix of its own, expected={expected_strategy}, actual={strategy}"
        )

    if "                run:" in workflow or re.search(
        r"^\s+run: .*\$\{\{", workflow, re.MULTILINE
    ):
        raise AssertionError(
            "compat canary expression mismatch: a `${{ }}` expression is "
            "substituted into the script text before bash parses it, so inputs "
            "reach a command through the environment or not at all"
        )
    expected_runs = {
        "probe": ['python3 -m scripts.canary.run --lane "$CANARY_LANE"'],
        "notify": [
            (
                "python3 -m scripts.canary.notify --results "
                'build/canary-results/ --lanes "$CANARY_LANES"'
            )
        ],
    }
    expected_env = {
        "probe": ["CANARY_LANE: ${{ matrix.lane }}"],
        "notify": [
            "GH_TOKEN: ${{ github.token }}",
            (
                "CANARY_LANES: ${{ github.event_name == 'workflow_dispatch' && "
                "inputs.channel || 'stable nightly' }}"
            ),
        ],
    }
    for name, job in (("probe", probe), ("notify", notify)):
        # The notifier's negative space, checked before the positive form so a
        # privileged job that grew a second command is diagnosed by what it
        # gained rather than by the list it no longer equals.
        if name == "notify":
            for forbidden in ("setup-pixi", "pixi", "mojo", "scripts.canary.run"):
                if forbidden in job.lower():
                    raise AssertionError(
                        "compat canary notifier mismatch: the job holding "
                        "`issues: write` must never run a toolchain, an "
                        f"environment, or the probe itself, found {forbidden!r}"
                    )
        runs = re.findall(r"^        run: (.+)$", job, re.MULTILINE)
        if runs != expected_runs[name]:
            raise AssertionError(
                f"compat canary job {name!r} run command mismatch: "
                f"expected={expected_runs[name]}, actual={runs}"
            )
        bindings = _env_bindings(job)
        if bindings != expected_env[name]:
            raise AssertionError(
                f"compat canary job {name!r} environment mismatch: a name bash "
                "acts on before it reads the script, such as BASH_ENV, runs code "
                "without substituting anything, and a value alone decides which "
                "lanes are reported and which go unmentioned, so both are pinned: "
                f"expected={expected_env[name]}, actual={bindings}"
            )
    # Over the whole file, so a binding made above the jobs — where neither
    # job's own body would show it, and where it applies to both — is caught
    # as an addition rather than missed as an absence.
    workflow_bindings = _env_bindings(workflow)
    if workflow_bindings != expected_env["probe"] + expected_env["notify"]:
        raise AssertionError(
            "compat canary environment mismatch: the only bindings in this "
            "workflow are the two steps' own, because a workflow-level or "
            "job-level `env:` reaches the privileged job without appearing in "
            f"its step, actual={workflow_bindings}"
        )

    probe_conditions = re.findall(r"^        if: (.+)$", probe, re.MULTILINE)
    upload_step = _yaml_block(probe, "      - name: Upload the classification")
    if probe_conditions != ["always()"] or "        if: always()" not in upload_step:
        raise AssertionError(
            "compat canary upload condition mismatch: the classification is the "
            "only thing the notifier reads and the interesting days are the ones "
            "the probe job failed, so the upload alone is conditioned, and it is "
            f"conditioned on always(), actual={probe_conditions}"
        )
    # `always()` by value, on every notifier step that has to survive the one
    # before it, and no other condition anywhere. The ban this replaces was
    # against a step being *skipped*, and `always()` is the one condition that
    # cannot skip: an unconditioned step is `if: success()`, so a download that
    # throws — `actions/download-artifact` defaults `digest-mismatch: error` —
    # skipped the other lane's download and the upsert with it, and a run where
    # the nightly lane found real drift wrote no issue. The issue is the durable
    # artifact; the red run is not.
    conditioned_notify_steps = (
        "Download the stable lane's classification",
        "Download the nightly lane's classification",
        "Upsert the pinned issues",
    )
    notify_conditions = re.findall(r"^        if: (.+)$", notify, re.MULTILINE)
    unconditioned = [
        step
        for step in conditioned_notify_steps
        if "        if: always()"
        not in _yaml_block(notify, f"      - name: {step}").splitlines()
    ]
    expected_notify_conditions = ["always()"] * len(conditioned_notify_steps)
    if notify_conditions != expected_notify_conditions or unconditioned:
        raise AssertionError(
            "compat canary notifier step condition mismatch: each step that "
            "reports a lane must run whatever the step before it did, and it "
            "must do so under `always()` — anything else can skip an upsert and "
            "leave a green run that told nobody anything, expected "
            f"{list(conditioned_notify_steps)} conditioned on always(), "
            f"actual={notify_conditions}, unconditioned={unconditioned}"
        )

    if (
        "          name: canary-result-${{ matrix.lane }}" not in probe
        or "          path: build/canary/" not in probe
    ):
        raise AssertionError(
            "compat canary artifact mismatch: one artifact per lane, named for "
            "its lane, holding the directory the probe writes"
        )
    downloads = _action_step_with_entries(notify, "actions/download-artifact")
    expected_downloads = [
        (
            f"pattern: {CANARY_ARTIFACT_PREFIX}{lane}",
            f"path: {CANARY_RESULTS_ROOT}{CANARY_ARTIFACT_PREFIX}{lane}/",
            "merge-multiple: true",
        )
        for lane in CANARY_LANES
    ]
    if downloads != expected_downloads:
        raise AssertionError(
            "compat canary download layout mismatch: `actions/download-artifact` "
            "creates a directory per artifact only while two or more matched, "
            "and extracts a sole match straight into `path:` — so a run that "
            "produced one artifact would land it where the notifier does not "
            "look and every lane would be reported silent. One step per lane, "
            f"each with its own destination, expected={expected_downloads}, "
            f"actual={downloads}"
        )
    if (
        workflow.count("${{ github.token }}") != 1
        or notify.count("${{ github.token }}") != 1
    ):
        raise AssertionError(
            "compat canary credential mismatch: the run token belongs to the "
            "notifier job alone"
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
    - the deploy job carries exactly one reviewed `actions/deploy-pages` step
      and no step-level condition. Requiring the upload alone leaves a green
      `deploy` job that publishes nothing: swap the deploy step for another
      reviewed action, or condition it away, and every other assertion here
      still passes while the site silently stops being updated;
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

    expected_deploy = [f"actions/deploy-pages@{DEPLOY_PAGES_ACTION_SHA} # v5.0.0"]
    deploys = re.findall(
        r"^\s+uses: (actions/deploy-pages@.+)$", deploy_job, re.MULTILINE
    )
    if deploys != expected_deploy or workflow.count("actions/deploy-pages@") != 1:
        raise AssertionError(
            "docs deploy step mismatch: the deploy job must publish through "
            "exactly one reviewed deploy-pages step, or it is a green job that "
            f"publishes nothing, expected={expected_deploy}, actual={deploys}"
        )
    if re.search(r"^        if:", deploy_job, re.MULTILINE):
        raise AssertionError(
            "docs deploy step mismatch: a step-level condition can skip the "
            "publication while the deploy job still reports success"
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
    - the `run:` lines are exactly `PUBLISHED_ACTION_RUNS`, so what the action
      executes is reviewed rather than merely constrained. Checking the shape
      of a composite while never reading its command accepts
      `curl ... | bash` as readily as the real invocation, which is the highest
      -risk surface in the repository governed by the weakest rule;
    - every step declares `shell: bash`, so the command above is parsed by the
      shell it was written for rather than by whatever a runner defaults to;
    - `${{ }}` expressions appear only on `PUBLISHED_ACTION_EXPRESSION_LINES`.
      An expression is substituted into the script text before bash sees it, so
      one on a `run:` line executes whatever a consumer passed in;
    - the `env:` keys are exactly `PUBLISHED_ACTION_ENV_KEYS`. Pinning what a
      binding may substitute leaves what it may name unconstrained, and the
      name alone runs code: bash reads `BASH_ENV` even under `--norc`, so a
      static binding that no expression rule can object to would execute ahead
      of the reviewed command in the consumer's job;
    - no `continue-on-error:`, no step-level `if:`, and no `|| true`, each of
      which would let a failing test run report green in a consumer's workflow —
      the exact outcome the product exists to prevent;
    - no reference to the caller's credentials, in either the dotted or the
      bracket expression form;
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
    runs_block = _yaml_block(action, "runs:")

    using = re.findall(r"^  using: (.+)$", runs_block, re.MULTILINE)
    if using != ["composite"]:
        raise AssertionError(
            "the published action must be a composite action: "
            f"expected=['composite'], actual={using}"
        )

    # Ordered most specific first, so a mutation is diagnosed by the rule that
    # names what is wrong with it rather than by whichever rule it also trips.
    credential = CREDENTIAL_REFERENCE_RE.search(action)
    if credential is not None:
        raise AssertionError(
            "the published action must contain no credential reference: "
            f"{credential.group(0)!r}"
        )
    if "continue-on-error:" in action:
        raise AssertionError(
            "the published action must not contain continue-on-error: a step "
            "that fails must fail the consumer's job"
        )
    if STEP_CONDITION_RE.search(runs_block):
        raise AssertionError(
            "the published action must not condition a step: a skipped test "
            "run reports green in the consumer's workflow"
        )
    if ALWAYS_SUCCEED_RE.search(action):
        raise AssertionError(
            "the published action must not discard an exit code with `|| true`"
        )

    commands = re.findall(r"^\s+run: (.+)$", runs_block, re.MULTILINE)
    if commands != list(PUBLISHED_ACTION_RUNS):
        raise AssertionError(
            "the published action must run exactly the reviewed invocation: "
            f"expected={list(PUBLISHED_ACTION_RUNS)}, actual={commands}"
        )
    shells = re.findall(r"^\s+(?:-\s+)?shell: (.+)$", runs_block, re.MULTILINE)
    if shells != ["bash"] * len(PUBLISHED_ACTION_RUNS):
        raise AssertionError(
            "every step of the published action must declare shell bash: "
            f"expected={['bash'] * len(PUBLISHED_ACTION_RUNS)}, actual={shells}"
        )
    expressions = [line for line in runs_block.splitlines() if "${{" in line]
    if expressions != list(PUBLISHED_ACTION_EXPRESSION_LINES):
        raise AssertionError(
            "a GitHub expression is substituted into the script text before "
            "bash parses it, so the published action may carry one only on the "
            f"reviewed environment lines: expected="
            f"{list(PUBLISHED_ACTION_EXPRESSION_LINES)}, actual={expressions}"
        )
    env_keys = _env_keys(runs_block)
    if env_keys != list(PUBLISHED_ACTION_ENV_KEYS):
        raise AssertionError(
            "the published action may bind only the reviewed environment "
            "keys: a name bash acts on before it reads the script, such as "
            "BASH_ENV, runs code without substituting anything, so expected="
            f"{list(PUBLISHED_ACTION_ENV_KEYS)}, actual={env_keys}"
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
        check_compat_canary_workflow()
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
