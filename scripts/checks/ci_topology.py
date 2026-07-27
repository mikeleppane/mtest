#!/usr/bin/env python3
"""Validate exact Pixi dependency closures and hosted-CI topology."""

from __future__ import annotations

from pathlib import Path
import re
import sys
import tomllib


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATHS = {
    Path(".github/workflows/ci.yml"),
    Path(".github/workflows/codeql.yml"),
}
"""Every hosted workflow tracked by the repository."""

CHECKOUT_ACTION_SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"
SETUP_PIXI_ACTION_SHA = "a09b6247153796b190642a2b53fac4241043cf6f"
CODEQL_ACTION_SHA = "e4fba868fa4b1b91e1fdab776edc8cfbe6e9fb81"
"""Reviewed immutable action revisions used by the CodeQL workflow."""

HARNESS_CHECK_MODULES = (
    "scripts.tests.test_aggregate",
    "scripts.tests.test_process_watchdog",
    "scripts.tests.test_dogfood",
    "scripts.tests.test_package_consumption",
    "scripts.tests.test_classified",
    "scripts.tests.test_e2e",
    "scripts.tests.test_e2e_json",
    "scripts.tests.test_contract",
    "scripts.tests.test_pty_capture",
    "scripts.tests.test_transcript_compare",
    "scripts.tests.test_readme_help",
    "scripts.tests.test_assertions",
    "scripts.tests.test_community_recipe",
    "scripts.checks.community_recipe",
    "scripts.tests.test_coverage_capability",
    "scripts.tests.test_layout",
    "scripts.checks.layout",
    "scripts.tests.test_ci_topology",
    "scripts.checks.ci_topology",
    "scripts.tests.test_python_quality",
    "scripts.tests.test_annotations_oracle",
)

FORMAT_COMMAND = r"""sh -c '
set -eu
source_list="$(mktemp "${TMPDIR:-/tmp}/mtest-format.XXXXXX")"
sorted_list="${source_list}.sorted"
trap "rm -f \"$source_list\" \"$sorted_list\"" EXIT HUP INT TERM
find -P src companions tests e2e recipe -type f -name "*.mojo" -print > "$source_list"
LC_ALL=C sort "$source_list" > "$sorted_list"
mv "$sorted_list" "$source_list"
if [ ! -s "$source_list" ]; then
    echo "FATAL: fmt: no Mojo sources found" >&2
    exit 1
fi
while IFS= read -r source; do
    mojo format --quiet "$source"
done < "$source_list"
'
"""
"""The exact portable, per-source Mojo formatter command."""

FORMAT_CHECK_TASK = {"cmd": "git diff --exit-code", "depends-on": ["fmt"]}
"""The formatter check must run the formatter before inspecting the diff."""

COVERAGE_CAPABILITY_COMMAND = "python -m scripts.checks.coverage_capability"

CI_PREFLIGHT_TASKS = [
    "version-check",
    "fmt-check",
    "harness-check",
    "safety-check",
    "postfork-check",
    "native-check",
    "junit-check",
    "build",
    "readme-help-check",
    "junit-render-check",
    "transcripts-check",
]
CI_TASKS = [
    "ci-preflight",
    "test",
    "assertions-check",
    "dogfood-check",
    "e2e",
    "contract-check-strict",
    "ci-memory",
]
CI_FLOOR_TASKS = {
    *CI_PREFLIGHT_TASKS,
    "test",
    "assertions-check",
    "dogfood-check",
    "e2e",
    "contract-check-strict",
    "ci-memory",
}

MEMORY_LANE_TASKS = ["asan-check", "valgrind-check"]
"""The memory-safety lanes, in the order the linux-64 aggregate runs them."""

CI_MEMORY_FALLBACK_COMMAND = "python -m scripts.checks.memory.host_support"
"""What `ci-memory` runs off linux-64: a loud, self-defending skip report."""

MEMORY_PLATFORM = "linux-64"
"""The one platform whose task table owns the real memory-lane dependency edge."""

LINUX_CI_FLOOR_TASKS = {*CI_FLOOR_TASKS, *MEMORY_LANE_TASKS}
"""The local floor on linux-64: every portable member plus both memory lanes."""

LINUX_MATRIX_ROWS = [
    {
        "runner": "ubuntu-24.04",
        "lane": "direct tests",
        "task": "test",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "assertions",
        "task": "assertions-check",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "self-hosted tests",
        "task": "dogfood-check",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "end-to-end tests",
        "task": "e2e",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "strict contract",
        "task": "contract-check-strict",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "ASan + LSan",
        "task": "asan-check",
        "libc_debug": "false",
        "safety_artifact": "true",
        "artifact_name": "asan-logs",
        "artifact_path": "build/safety/asan/*.log",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "Valgrind Memcheck",
        "task": "valgrind-check",
        "libc_debug": "true",
        "safety_artifact": "true",
        "artifact_name": "valgrind-logs",
        "artifact_path": "build/safety/valgrind/*.log",
    },
]
MACOS_MATRIX_ROWS = [
    {
        "runner": "macos-15",
        "lane": "direct tests",
        "task": "test",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "macos-15",
        "lane": "assertions",
        "task": "assertions-check",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "macos-15",
        "lane": "self-hosted tests",
        "task": "dogfood-check",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "macos-15",
        "lane": "end-to-end tests",
        "task": "e2e",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "macos-15",
        "lane": "strict contract",
        "task": "contract-check-strict",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
]


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


def _matrix_rows(job: str) -> list[dict[str, str]]:
    """Parse the workflow's deliberately scalar-only matrix include rows."""
    rows: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in job.splitlines():
        first = re.match(r"^          - ([a-z_-]+): (.+)$", line)
        if first is not None:
            if current is not None:
                rows.append(current)
            current = {first.group(1): first.group(2)}
            continue
        field = re.match(r"^            ([a-z_-]+): (.+)$", line)
        if current is not None and field is not None:
            current[field.group(1)] = field.group(2)
    if current is not None:
        rows.append(current)
    return rows


def _step_attributes(job: str, name: str) -> dict[str, str]:
    """Return executable scalar attributes from one exact named workflow step."""
    block = _yaml_block(job, f"      - name: {name}")
    attributes: dict[str, str] = {}
    for line in block.splitlines():
        match = re.match(r"^        (if|run|uses): (.+)$", line)
        if match is None:
            continue
        key = match.group(1)
        if key in attributes:
            raise AssertionError(f"workflow step {name!r} repeats {key!r}")
        attributes[key] = match.group(2)
    return attributes


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


def _task_dependencies(tasks: dict[str, object], name: str) -> list[str]:
    """Read one Pixi task's direct dependency list without accepting shorthands."""
    task = tasks.get(name)
    if not isinstance(task, dict):
        raise AssertionError(f"Pixi task {name!r} must be a dependency aggregate")
    dependencies = task.get("depends-on")
    if not isinstance(dependencies, list) or not all(
        isinstance(item, str) for item in dependencies
    ):
        raise AssertionError(f"Pixi task {name!r} has no string dependency list")
    return dependencies


def _transitive_tasks(tasks: dict[str, object], root: str) -> set[str]:
    """Expand declared Pixi task dependencies from one aggregate root."""
    seen: set[str] = set()
    pending = [root]
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        task = tasks.get(name)
        if isinstance(task, dict):
            dependencies = task.get("depends-on", [])
            if not isinstance(dependencies, list) or not all(
                isinstance(item, str) for item in dependencies
            ):
                raise AssertionError(f"Pixi task {name!r} has invalid dependencies")
            pending.extend(dependencies)
    return seen


PLATFORM_TASK_OVERRIDES = {"ci-memory"}
"""The ONLY task any platform table may override, and the reason it is bounded.

A `[target.<platform>.tasks]` entry silently replaces the base task of the same
name, with no warning from pixi, and every other exact-command pin in this module
reads the base `[tasks]` table. So an unbounded override table is a hole big
enough to drive a lane through: adding `asan-check = "true"` under linux-64 would
leave `pixi run ci`, `harness-check`, AND the hosted "ASan + LSan" required check
all green while running nothing, because the lane never leaves either view by
name. Bounding the table to one known entry is what closes that.
"""

PLATFORM_TARGET_KEYS = {"dependencies", "tasks"}
"""What a `[target.<platform>]` table may contain, so a new one cannot hide."""


def _platform_tasks(manifest: dict[str, object], platform: str) -> dict[str, object]:
    """Read one platform's task overrides, bounding what may live there.

    Args:
        manifest: The parsed `pixi.toml`.
        platform: The platform whose task table is required to exist.

    Returns:
        That platform's task overrides.

    Raises:
        AssertionError: If the table is missing, if any platform other than
            `platform` declares task overrides, if a target table grows an
            unexpected key, or if the override table names a task outside
            `PLATFORM_TASK_OVERRIDES`.
    """
    targets = manifest.get("target")
    if not isinstance(targets, dict):
        raise AssertionError("pixi.toml has no [target] table")
    for name, table in targets.items():
        if not isinstance(table, dict):
            raise AssertionError(f"[target.{name}] is not a table")
        unexpected = set(table) - PLATFORM_TARGET_KEYS
        if unexpected:
            raise AssertionError(
                f"[target.{name}] carries unexpected keys {sorted(unexpected)}; "
                f"only {sorted(PLATFORM_TARGET_KEYS)} are pinned here"
            )
        overrides = table.get("tasks")
        if overrides is None:
            continue
        if not isinstance(overrides, dict):
            raise AssertionError(f"[target.{name}.tasks] is not a table")
        if name != platform:
            raise AssertionError(
                f"[target.{name}.tasks] overrides tasks {sorted(overrides)}, but "
                f"only {platform} may override a task; a platform override "
                "silently replaces the base command and is invisible to every "
                "exact-command pin in this module"
            )
        outside = set(overrides) - PLATFORM_TASK_OVERRIDES
        if outside:
            raise AssertionError(
                f"[target.{name}.tasks] overrides {sorted(outside)}, which is "
                f"outside the pinned set {sorted(PLATFORM_TASK_OVERRIDES)}; an "
                "override replaces the base command with no warning, so a lane "
                "can stay in every view by name while running nothing"
            )
    target = targets.get(platform)
    if not isinstance(target, dict):
        raise AssertionError(f"pixi.toml has no [target.{platform}] table")
    tasks = target.get("tasks")
    if not isinstance(tasks, dict):
        raise AssertionError(f"pixi.toml has no [target.{platform}.tasks] table")
    return tasks


def check_ci_task_graph(repo_root: Path = REPO_ROOT) -> None:
    """The serial local floor is the exact preflight plus behavioral lanes."""
    with (repo_root / "pixi.toml").open("rb") as handle:
        manifest = tomllib.load(handle)
    tasks = manifest["tasks"]
    expected_harness_command = " && ".join(
        f"python -m {module}" for module in HARNESS_CHECK_MODULES
    )
    if tasks.get("harness-check") != expected_harness_command:
        raise AssertionError(
            "harness-check must remain one exact serial owner chain: "
            f"expected={expected_harness_command!r}, "
            f"actual={tasks.get('harness-check')!r}"
        )
    if tasks.get("fmt") != FORMAT_COMMAND:
        raise AssertionError(
            "fmt task mismatch: "
            f"expected={FORMAT_COMMAND!r}, actual={tasks.get('fmt')!r}"
        )
    if tasks.get("fmt-check") != FORMAT_CHECK_TASK:
        raise AssertionError(
            "fmt-check task mismatch: "
            f"expected={FORMAT_CHECK_TASK!r}, actual={tasks.get('fmt-check')!r}"
        )
    if "test-direct" in tasks:
        raise AssertionError("obsolete test-direct Pixi alias still exists")
    expected_classified_tasks = {
        "test": ("python -m scripts.harness.classified tests/unit tests/integration"),
        "test-unit": "python -m scripts.harness.classified tests/unit",
        "test-integration": ("python -m scripts.harness.classified tests/integration"),
        "test-file": "python -m scripts.harness.classified",
    }
    for name, command in expected_classified_tasks.items():
        if tasks.get(name) != command:
            raise AssertionError(
                f"{name} classified task command mismatch: "
                f"expected={command!r}, actual={tasks.get(name)!r}"
            )
    expected_dogfood = {
        "cmd": "python -m scripts.harness.dogfood",
        "depends-on": ["build-bin"],
    }
    if tasks.get("dogfood-check") != expected_dogfood:
        raise AssertionError(
            "dogfood-check task mismatch: "
            f"expected={expected_dogfood!r}, actual={tasks.get('dogfood-check')!r}"
        )
    expected_assertions = (
        "python -m scripts.tests.test_assertions && python -m scripts.checks.assertions"
    )
    if tasks.get("assertions-check") != expected_assertions:
        raise AssertionError(
            "assertions-check task mismatch: "
            f"expected={expected_assertions!r}, "
            f"actual={tasks.get('assertions-check')!r}"
        )
    expected_readme_help = {
        "cmd": "python -m scripts.checks.readme_help",
        "depends-on": ["build-bin"],
    }
    if tasks.get("readme-help-check") != expected_readme_help:
        raise AssertionError(
            "readme-help-check task mismatch: "
            f"expected={expected_readme_help!r}, "
            f"actual={tasks.get('readme-help-check')!r}"
        )
    preflight = _task_dependencies(tasks, "ci-preflight")
    if preflight != CI_PREFLIGHT_TASKS:
        raise AssertionError(
            "ci-preflight membership/order mismatch: "
            f"expected={CI_PREFLIGHT_TASKS}, actual={preflight}"
        )
    ci = _task_dependencies(tasks, "ci")
    if ci != CI_TASKS:
        raise AssertionError(
            f"ci membership/order mismatch: expected={CI_TASKS}, actual={ci}"
        )
    expected_preflight_closure = {
        "ci-preflight",
        "fmt",
        "build-bin",
        "build-native",
        *CI_PREFLIGHT_TASKS,
    }
    preflight_closure = _transitive_tasks(tasks, "ci-preflight")
    if preflight_closure != expected_preflight_closure:
        raise AssertionError(
            "ci-preflight transitive closure mismatch: "
            f"missing={sorted(expected_preflight_closure - preflight_closure)}, "
            f"extra={sorted(preflight_closure - expected_preflight_closure)}"
        )
    expected_ci_closure = {
        "ci",
        "ci-preflight",
        "fmt",
        "build-bin",
        "build-native",
        *CI_FLOOR_TASKS,
    }
    closure = _transitive_tasks(tasks, "ci")
    if closure != expected_ci_closure:
        raise AssertionError(
            "ci transitive floor mismatch: "
            f"missing={sorted(expected_ci_closure - closure)}, "
            f"extra={sorted(closure - expected_ci_closure)}"
        )
    exact_safety_tasks = {
        "asan-check": (
            "python -m scripts.tests.test_asan && python -m scripts.checks.memory.asan"
        ),
        "valgrind-check": (
            "python -m scripts.tests.test_valgrind && "
            "python -m scripts.checks.memory.valgrind"
        ),
    }
    for name, command in exact_safety_tasks.items():
        if tasks.get(name) != command:
            raise AssertionError(
                f"{name} no longer runs its exact negative-control harness"
            )
    # Both memory lanes are members of the LOCAL floor, not hosted-only. The
    # `ci` closure below is what proves it; these two pin the shape that makes
    # it work. The base command must stay the loud non-Linux report, because a
    # bare `true` there would let a macOS floor imply a verdict it skipped.
    if tasks.get("ci-memory") != CI_MEMORY_FALLBACK_COMMAND:
        raise AssertionError(
            "ci-memory base command mismatch: "
            f"expected={CI_MEMORY_FALLBACK_COMMAND!r}, "
            f"actual={tasks.get('ci-memory')!r}"
        )
    platform_tasks = _platform_tasks(manifest, MEMORY_PLATFORM)
    expected_memory_aggregate = {"depends-on": MEMORY_LANE_TASKS}
    if platform_tasks.get("ci-memory") != expected_memory_aggregate:
        raise AssertionError(
            f"[target.{MEMORY_PLATFORM}.tasks] ci-memory mismatch: "
            f"expected={expected_memory_aggregate!r}, "
            f"actual={platform_tasks.get('ci-memory')!r}"
        )
    linux_tasks = {**tasks, **platform_tasks}
    expected_linux_closure = {
        "ci",
        "ci-preflight",
        "fmt",
        "build-bin",
        "build-native",
        *LINUX_CI_FLOOR_TASKS,
    }
    linux_closure = _transitive_tasks(linux_tasks, "ci")
    if linux_closure != expected_linux_closure:
        raise AssertionError(
            f"ci transitive floor on {MEMORY_PLATFORM} mismatch: "
            f"missing={sorted(expected_linux_closure - linux_closure)}, "
            f"extra={sorted(linux_closure - expected_linux_closure)}"
        )
    # The closure equality above already proves each lane is present BY NAME.
    # What it cannot see is a lane whose command was replaced, so check the
    # merged table's commands rather than re-testing membership. `_platform_tasks`
    # bounds which tasks may be overridden at all; this is the second lock, and
    # the one that would fire if that set were ever widened.
    for lane in MEMORY_LANE_TASKS:
        if linux_tasks.get(lane) != exact_safety_tasks[lane]:
            raise AssertionError(
                f"{lane} does not run its exact negative-control harness on "
                f"{MEMORY_PLATFORM}: expected={exact_safety_tasks[lane]!r}, "
                f"actual={linux_tasks.get(lane)!r}. A green `pixi run ci` would "
                "claim memory-safety coverage it did not compute."
            )
    # The coverage-capability probe is diagnostic, so nothing in the `ci`
    # closure depends on it and nothing else would notice it disappearing.
    # Pin its exact command here: it is the one thing standing between a
    # toolchain upgrade and an unreviewed coverage number.
    if tasks.get("coverage-capability") != COVERAGE_CAPABILITY_COMMAND:
        raise AssertionError(
            "coverage-capability task mismatch: "
            f"expected={COVERAGE_CAPABILITY_COMMAND!r}, "
            f"actual={tasks.get('coverage-capability')!r}"
        )


def check_ci_workflow(repo_root: Path = REPO_ROOT) -> None:
    """The hosted gate has independent platform-local preflight/matrix chains."""
    workflow_path = repo_root / ".github" / "workflows" / "ci.yml"
    workflow = workflow_path.read_text(encoding="utf-8")
    if "continue-on-error:" in workflow:
        raise AssertionError("CI workflow must not contain continue-on-error")
    triggers = _yaml_mapping_keys(_yaml_block(workflow, "on:"), 2)
    expected_triggers = ["push", "pull_request", "workflow_dispatch"]
    if triggers != expected_triggers or "schedule:" in _yaml_block(workflow, "on:"):
        raise AssertionError(
            f"CI workflow trigger mismatch: expected={expected_triggers}, "
            f"actual={triggers}"
        )
    if "    branches: [main, master]" not in _yaml_block(workflow, "on:"):
        raise AssertionError("CI push trigger no longer pins main and master")

    jobs = _yaml_mapping_keys(_yaml_block(workflow, "jobs:"), 2)
    expected_jobs = [
        "linux-preflight",
        "linux-test-matrix",
        "package",
        "macos-preflight",
        "macos-test-matrix",
        "macos-package",
    ]
    if jobs != expected_jobs:
        raise AssertionError(
            f"CI workflow job membership mismatch: expected={expected_jobs}, "
            f"actual={jobs}"
        )
    job_blocks = {name: _yaml_block(workflow, f"  {name}:") for name in jobs}
    expected_needs = {
        "linux-preflight": None,
        "linux-test-matrix": "linux-preflight",
        "package": None,
        "macos-preflight": None,
        "macos-test-matrix": "macos-preflight",
        "macos-package": "macos-preflight",
    }
    for name, expected in expected_needs.items():
        if re.search(r"^    if:", job_blocks[name], re.MULTILINE):
            raise AssertionError(f"CI job {name!r} must not be conditionally disabled")
        matches = re.findall(r"^    needs:(.*)$", job_blocks[name], re.MULTILINE)
        expected_lines = [] if expected is None else [f" {expected}"]
        if matches != expected_lines:
            raise AssertionError(
                f"CI job {name!r} needs mismatch: "
                f"expected={expected_lines}, actual={matches}"
            )

    matrices = {
        "linux-test-matrix": LINUX_MATRIX_ROWS,
        "macos-test-matrix": MACOS_MATRIX_ROWS,
    }
    expected_fail_fast = {
        "linux-test-matrix": "true",
        "macos-test-matrix": "false",
    }
    for name, expected_rows in matrices.items():
        job = job_blocks[name]
        expected_strategy = (
            "    strategy:\n"
            f"      fail-fast: {expected_fail_fast[name]}\n"
            "      matrix:\n"
            "        include:"
        )
        if expected_strategy not in job:
            raise AssertionError(
                f"CI job {name!r} strategy/fail-fast layout mismatch: "
                f"expected={expected_strategy!r}"
            )
        actual_rows = _matrix_rows(job)
        if actual_rows != expected_rows:
            raise AssertionError(
                f"CI job {name!r} matrix mismatch: "
                f"expected={expected_rows}, actual={actual_rows}"
            )
        runs_on = re.findall(r"^    runs-on: (.+)$", job, re.MULTILINE)
        if runs_on != ["${{ matrix.runner }}"]:
            raise AssertionError(
                f"CI job {name!r} runner dispatch mismatch: actual={runs_on}"
            )
        run_step = _step_attributes(job, "Run ${{ matrix.lane }}")
        if run_step != {"run": "pixi run ${{ matrix.task }}"}:
            raise AssertionError(
                f"CI job {name!r} matrix task dispatch mismatch: actual={run_step}"
            )

    # The hosted matrix runs the memory LANES, one cell each, never the
    # `ci-memory` aggregate that exists to put both of them in the serial local
    # floor. Deriving the expected rows from CI_TASKS keeps the two views tied
    # together, and this equality is what refuses to let the local floor gain a
    # member the hosted matrix silently never runs.
    behavioral_floor = [task for task in CI_TASKS[1:] if task != "ci-memory"]
    if ["ci-preflight", *behavioral_floor, "ci-memory"] != CI_TASKS:
        raise AssertionError(
            "the local floor no longer ends with the memory aggregate; the "
            f"hosted matrix expansion below is derived from it: {CI_TASKS}"
        )
    expected_matrix_tasks = {
        "linux-test-matrix": [*behavioral_floor, *MEMORY_LANE_TASKS],
        "macos-test-matrix": behavioral_floor,
    }
    for name, expected_tasks in expected_matrix_tasks.items():
        actual_tasks = [row.get("task") for row in _matrix_rows(job_blocks[name])]
        if actual_tasks != expected_tasks:
            raise AssertionError(
                f"CI job {name!r} task coverage mismatch against the required "
                f"floor: expected={expected_tasks}, actual={actual_tasks}"
            )

    linux_preflight = job_blocks["linux-preflight"]
    linux_commands = re.findall(r"^        run: (.+)$", linux_preflight, re.MULTILINE)
    expected_linux_commands = ["pixi run mojo-version", "pixi run ci-preflight"]
    if linux_commands != expected_linux_commands:
        raise AssertionError(
            "Linux preflight command mismatch: "
            f"expected={expected_linux_commands}, actual={linux_commands}"
        )
    macos_preflight = job_blocks["macos-preflight"]
    macos_commands = re.findall(r"^        run: (.+)$", macos_preflight, re.MULTILINE)
    expected_macos_commands = [
        "|",
        "pixi run native-check",
        "pixi run build-bin",
        "./build/mtest --help",
    ]
    if macos_commands != expected_macos_commands:
        raise AssertionError(
            "macOS preflight prerequisite order mismatch: "
            f"expected={expected_macos_commands}, actual={macos_commands}"
        )

    # Both gated platforms consume the installed artifact, and both do it with
    # the same task. The Linux job's `package` key and `Linux / packaged
    # artifact` display name are externally configured required checks: renaming
    # either silently drops branch protection, so both are pinned here.
    expected_package_commands = [
        "pixi run mojo-version",
        "pixi run package-check",
    ]
    expected_package_runners = {
        "package": "ubuntu-24.04",
        "macos-package": "macos-15",
    }
    expected_package_names = {
        "package": "Linux / packaged artifact",
        "macos-package": "macOS arm64 / packaged artifact",
    }
    for name, expected_runner in expected_package_runners.items():
        package_commands = re.findall(
            r"^        run: (.+)$", job_blocks[name], re.MULTILINE
        )
        if package_commands != expected_package_commands:
            raise AssertionError(
                f"{name} package command mismatch: "
                f"expected={expected_package_commands}, actual={package_commands}"
            )
        runs_on = re.findall(r"^    runs-on: (.+)$", job_blocks[name], re.MULTILINE)
        if runs_on != [expected_runner]:
            raise AssertionError(
                f"{name} package runner mismatch: "
                f"expected={[expected_runner]}, actual={runs_on}"
            )
        display = re.findall(r"^    name: (.+)$", job_blocks[name], re.MULTILINE)
        if display != [expected_package_names[name]]:
            raise AssertionError(
                f"{name} package display name mismatch: "
                f"expected={[expected_package_names[name]]}, actual={display}"
            )

    linux_matrix = job_blocks["linux-test-matrix"]
    expected_linux_steps = {
        "Install matching glibc debug symbols": {
            "if": "${{ matrix.libc_debug }}",
            "run": "|",
        },
        "Tool provenance": {"run": "|"},
        "Valgrind provenance": {
            "if": "${{ matrix.libc_debug }}",
            "run": "pixi run valgrind --version",
        },
        "Build safety prerequisite": {
            "if": "${{ matrix.safety_artifact }}",
            "run": "pixi run build",
        },
        "Upload safety logs": {
            "if": "${{ always() && matrix.safety_artifact }}",
            "uses": "actions/upload-artifact@v4",
        },
    }
    for name, expected_step in expected_linux_steps.items():
        actual_step = _step_attributes(linux_matrix, name)
        if actual_step != expected_step:
            raise AssertionError(
                f"Linux matrix step {name!r} mismatch: "
                f"expected={expected_step}, actual={actual_step}"
            )

    required_linux_lines = [
        "libc_version=\"$(dpkg-query -W -f='${Version}' libc6)\"",
        "sudo apt-get update",
        "apt-cache policy libc6 libc6-dbg",
        'sudo apt-get install --yes --no-install-recommends "libc6-dbg=$libc_version"',
        "installed_libc_version=\"$(dpkg-query -W -f='${Version}' libc6)\"",
        "debug_version=\"$(dpkg-query -W -f='${Version}' libc6-dbg)\"",
        'test "$installed_libc_version" = "$libc_version"',
        'test "$debug_version" = "$libc_version"',
        "pixi run mojo-version",
        "pixi run clang --version",
        "ldd --version | head -1",
    ]
    linux_lines = linux_matrix.splitlines()
    missing_lines = [
        line for line in required_linux_lines if f"          {line}" not in linux_lines
    ]
    if missing_lines:
        raise AssertionError(
            f"Linux matrix lost memory-safety commands: missing={missing_lines}"
        )
    upload_block = _yaml_block(linux_matrix, "      - name: Upload safety logs")
    expected_upload_lines = {
        "          name: ${{ matrix.artifact_name }}",
        "          path: ${{ matrix.artifact_path }}",
        "          if-no-files-found: warn",
        "          retention-days: 30",
    }
    actual_upload_lines = {
        line for line in upload_block.splitlines() if line.startswith("          ")
    }
    if actual_upload_lines != expected_upload_lines:
        raise AssertionError(
            "Linux safety artifact inputs mismatch: "
            f"expected={sorted(expected_upload_lines)}, "
            f"actual={sorted(actual_upload_lines)}"
        )

    for name, job in job_blocks.items():
        if job.count(f"uses: actions/checkout@{CHECKOUT_ACTION_SHA}") != 1:
            raise AssertionError(f"CI job {name!r} does not pin checkout v7.0.1 once")
        if job.count(f"uses: prefix-dev/setup-pixi@{SETUP_PIXI_ACTION_SHA}") != 1:
            raise AssertionError(f"CI job {name!r} does not pin setup-pixi once")
        if "          locked: true" not in job or "          cache: true" not in job:
            raise AssertionError(f"CI job {name!r} lacks locked cached Pixi setup")

    legacy = repo_root / ".github" / "workflows" / "memory-safety.yml"
    if legacy.exists():
        raise AssertionError("legacy scheduled memory-safety workflow still exists")


def main() -> int:
    """Run the independent exact CI topology oracles."""
    try:
        check_workflow_inventory()
        check_ci_task_graph()
        check_ci_workflow()
        check_codeql_workflow()
    except (AssertionError, OSError) as exc:
        print(f"ci-topology-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("ci-topology-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
