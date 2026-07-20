#!/usr/bin/env python3
"""Validate exact Pixi dependency closures and hosted-CI topology."""

from __future__ import annotations

from pathlib import Path
import re
import sys
import tomllib


REPO_ROOT = Path(__file__).resolve().parents[2]
HARNESS_CHECK_MODULES = (
    "scripts.tests.test_aggregate",
    "scripts.tests.test_process_watchdog",
    "scripts.tests.test_format",
    "scripts.tests.test_dogfood",
    "scripts.tests.test_classified",
    "scripts.tests.test_e2e",
    "scripts.tests.test_e2e_json",
    "scripts.tests.test_contract",
    "scripts.tests.test_transcript_compare",
    "scripts.tests.test_layout",
    "scripts.checks.layout",
    "scripts.tests.test_ci_topology",
    "scripts.checks.ci_topology",
)

CI_PREFLIGHT_TASKS = [
    "version-check",
    "fmt-check",
    "harness-check",
    "safety-check",
    "postfork-check",
    "native-check",
    "junit-check",
    "build",
    "junit-render-check",
    "transcripts-check",
]
CI_TASKS = ["ci-preflight", "test-direct", "test", "e2e"]
CI_FLOOR_TASKS = {
    *CI_PREFLIGHT_TASKS,
    "test-direct",
    "test",
    "e2e",
}

LINUX_MATRIX_ROWS = [
    {
        "runner": "ubuntu-24.04",
        "lane": "direct tests",
        "task": "test-direct",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "self-hosted tests",
        "task": "test",
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
        "task": "test-direct",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "macos-15",
        "lane": "self-hosted tests",
        "task": "test",
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


def check_ci_task_graph(repo_root: Path = REPO_ROOT) -> None:
    """The serial local floor is the exact preflight plus behavioral lanes."""
    with (repo_root / "pixi.toml").open("rb") as manifest:
        tasks = tomllib.load(manifest)["tasks"]
    expected_harness_command = " && ".join(
        f"python -m {module}" for module in HARNESS_CHECK_MODULES
    )
    if tasks.get("harness-check") != expected_harness_command:
        raise AssertionError(
            "harness-check must remain one exact serial owner chain: "
            f"expected={expected_harness_command!r}, "
            f"actual={tasks.get('harness-check')!r}"
        )
    expected_classified_tasks = {
        "test-direct": (
            "python -m scripts.harness.classified tests/unit tests/integration"
        ),
        "test-unit": "python -m scripts.harness.classified tests/unit",
        "test-integration": (
            "python -m scripts.harness.classified tests/integration"
        ),
        "test-file": "python -m scripts.harness.classified",
    }
    for name, command in expected_classified_tasks.items():
        if tasks.get(name) != command:
            raise AssertionError(
                f"{name} classified task command mismatch: "
                f"expected={command!r}, actual={tasks.get(name)!r}"
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
    expected_preflight_closure = {"ci-preflight", *CI_PREFLIGHT_TASKS}
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
            "python -m scripts.tests.test_asan && "
            "python -m scripts.checks.memory.asan"
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
            f"CI workflow trigger mismatch: expected={expected_triggers}, actual={triggers}"
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
    ]
    if jobs != expected_jobs:
        raise AssertionError(
            f"CI workflow job membership mismatch: expected={expected_jobs}, actual={jobs}"
        )
    job_blocks = {name: _yaml_block(workflow, f"  {name}:") for name in jobs}
    expected_needs = {
        "linux-preflight": None,
        "linux-test-matrix": "linux-preflight",
        "package": None,
        "macos-preflight": None,
        "macos-test-matrix": "macos-preflight",
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
    for name, expected in matrices.items():
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
        actual = _matrix_rows(job)
        if actual != expected:
            raise AssertionError(
                f"CI job {name!r} matrix mismatch: expected={expected}, actual={actual}"
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

    behavioral_floor = CI_TASKS[1:]
    expected_matrix_tasks = {
        "linux-test-matrix": [
            *behavioral_floor,
            "asan-check",
            "valgrind-check",
        ],
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

    package_commands = re.findall(
        r"^        run: (.+)$", job_blocks["package"], re.MULTILINE
    )
    expected_package_commands = [
        "pixi run mojo-version",
        "pixi run package-check",
    ]
    if package_commands != expected_package_commands:
        raise AssertionError(
            "independent package command mismatch: "
            f"expected={expected_package_commands}, actual={package_commands}"
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
    for name, expected in expected_linux_steps.items():
        actual = _step_attributes(linux_matrix, name)
        if actual != expected:
            raise AssertionError(
                f"Linux matrix step {name!r} mismatch: "
                f"expected={expected}, actual={actual}"
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
        if job.count("uses: actions/checkout@v4") != 1:
            raise AssertionError(f"CI job {name!r} does not pin checkout@v4 once")
        if job.count("uses: prefix-dev/setup-pixi@v0.10.0") != 1:
            raise AssertionError(f"CI job {name!r} does not pin setup-pixi once")
        if "          locked: true" not in job or "          cache: true" not in job:
            raise AssertionError(f"CI job {name!r} lacks locked cached Pixi setup")

    legacy = repo_root / ".github" / "workflows" / "memory-safety.yml"
    if legacy.exists():
        raise AssertionError("legacy scheduled memory-safety workflow still exists")


def main() -> int:
    """Run the independent exact CI topology oracles."""
    try:
        check_ci_task_graph()
        check_ci_workflow()
    except (AssertionError, OSError) as exc:
        print(f"ci-topology-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("ci-topology-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
