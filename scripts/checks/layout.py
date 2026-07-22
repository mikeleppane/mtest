#!/usr/bin/env python3
"""Validate exact repository harness layout and invocation policy."""

from __future__ import annotations

import ast
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tomllib

from scripts.e2e import __main__ as e2e_main
from scripts.harness import aggregate
from scripts.harness import dogfood


REPO_ROOT = Path(__file__).resolve().parents[2]

TOP_LEVEL_SCRIPT_FILES = {
    Path("scripts/__init__.py"),
    Path("scripts/gen_transcripts.py"),
}

BUILD_SOURCE_PATHS = (
    Path("scripts/build/__init__.py"),
    Path("scripts/build/mojo_package.sh"),
    Path("scripts/build/native.py"),
    Path("scripts/build/native_strict_flags.txt"),
    Path("scripts/build/package_consumption.py"),
    Path("scripts/build/production_build.sh"),
)
UNIT_SUITES = {
    "test_cache_registry.mojo",
    "test_cli_arity.mojo",
    "test_cli_arity0.mojo",
    "test_cli_build_flags.mojo",
    "test_cli_collect.mojo",
    "test_cli_grammar.mojo",
    "test_cli_inventory.mojo",
    "test_cli_parse.mojo",
    "test_config.mojo",
    "test_discover_fnmatch.mojo",
    "test_discover_normalize.mojo",
    "test_exec_pool_policy.mojo",
    "test_exec_spec.mojo",
    "test_exec_tty.mojo",
    "test_model_events.mojo",
    "test_model_exit_code.mojo",
    "test_model_node_id.mojo",
    "test_model_outcome.mojo",
    "test_model_parse_disposition.mojo",
    "test_model_slow.mojo",
    "test_model_test_counts.mojo",
    "test_model_test_result.mojo",
    "test_protocol_corruption.mojo",
    "test_protocol_matrix.mojo",
    "test_report_annotations.mojo",
    "test_report_composite.mojo",
    "test_report_console.mojo",
    "test_report_coordinator.mojo",
    "test_report_escape.mojo",
    "test_report_json_reporter.mojo",
    "test_report_json_stream.mojo",
    "test_report_junit.mojo",
    "test_report_junit_finalize.mojo",
    "test_report_junit_reporter.mojo",
    "test_report_recording.mojo",
    "test_report_signals.mojo",
    "test_select_logic.mojo",
    "test_select_operands.mojo",
    "test_session_attribution.mojo",
    "test_session_clamp.mojo",
    "test_session_classify.mojo",
    "test_session_detail.mojo",
    "test_session_mangle.mojo",
    "test_session_pipeline.mojo",
    "test_session_precompile_paths.mojo",
    "test_session_resilience.mojo",
    "test_session_retry_class.mojo",
    "test_session_shard.mojo",
    "test_session_verdict.mojo",
}
INTEGRATION_SUITES = {
    "test_discover_pipeline.mojo",
    "test_discover_walk.mojo",
    "test_exec_capture.mojo",
    "test_exec_decode.mojo",
    "test_exec_env.mojo",
    "test_exec_etxtbsy.mojo",
    "test_exec_fdhygiene.mojo",
    "test_exec_flood.mojo",
    "test_exec_interrupt.mojo",
    "test_exec_paths.mojo",
    "test_exec_pool.mojo",
    "test_exec_prestart.mojo",
    "test_exec_reap.mojo",
    "test_exec_sweep.mojo",
    "test_exec_timeout.mojo",
    "test_protocol_collection.mojo",
    "test_protocol_report.mojo",
    "test_session_annotations.mojo",
    "test_session_collect.mojo",
    "test_session_exit_codes.mojo",
    "test_session_flow.mojo",
    "test_session_gates.mojo",
    "test_session_handshake.mojo",
    "test_session_interrupt.mojo",
    "test_session_json_stream.mojo",
    "test_session_junit.mojo",
    "test_session_maxfail.mojo",
    "test_session_outcomes.mojo",
    "test_session_precompile.mojo",
    "test_session_rmtree.mojo",
    "test_session_selection.mojo",
    "test_transcripts_smoke.mojo",
}
CLASSIFIED_PATHS = (
    "tests/integration/test_discover_pipeline.mojo",
    "tests/integration/test_discover_walk.mojo",
    "tests/integration/test_exec_capture.mojo",
    "tests/integration/test_exec_decode.mojo",
    "tests/integration/test_exec_env.mojo",
    "tests/integration/test_exec_etxtbsy.mojo",
    "tests/integration/test_exec_fdhygiene.mojo",
    "tests/integration/test_exec_flood.mojo",
    "tests/integration/test_exec_interrupt.mojo",
    "tests/integration/test_exec_paths.mojo",
    "tests/integration/test_exec_pool.mojo",
    "tests/integration/test_exec_prestart.mojo",
    "tests/integration/test_exec_reap.mojo",
    "tests/integration/test_exec_sweep.mojo",
    "tests/integration/test_exec_timeout.mojo",
    "tests/integration/test_protocol_collection.mojo",
    "tests/integration/test_protocol_report.mojo",
    "tests/integration/test_session_annotations.mojo",
    "tests/integration/test_session_collect.mojo",
    "tests/integration/test_session_exit_codes.mojo",
    "tests/integration/test_session_flow.mojo",
    "tests/integration/test_session_gates.mojo",
    "tests/integration/test_session_handshake.mojo",
    "tests/integration/test_session_interrupt.mojo",
    "tests/integration/test_session_json_stream.mojo",
    "tests/integration/test_session_junit.mojo",
    "tests/integration/test_session_maxfail.mojo",
    "tests/integration/test_session_outcomes.mojo",
    "tests/integration/test_session_precompile.mojo",
    "tests/integration/test_session_rmtree.mojo",
    "tests/integration/test_session_selection.mojo",
    "tests/integration/test_transcripts_smoke.mojo",
    "tests/unit/test_cache_registry.mojo",
    "tests/unit/test_cli_arity.mojo",
    "tests/unit/test_cli_arity0.mojo",
    "tests/unit/test_cli_build_flags.mojo",
    "tests/unit/test_cli_collect.mojo",
    "tests/unit/test_cli_grammar.mojo",
    "tests/unit/test_cli_inventory.mojo",
    "tests/unit/test_cli_parse.mojo",
    "tests/unit/test_config.mojo",
    "tests/unit/test_discover_fnmatch.mojo",
    "tests/unit/test_discover_normalize.mojo",
    "tests/unit/test_exec_pool_policy.mojo",
    "tests/unit/test_exec_spec.mojo",
    "tests/unit/test_exec_tty.mojo",
    "tests/unit/test_model_events.mojo",
    "tests/unit/test_model_exit_code.mojo",
    "tests/unit/test_model_node_id.mojo",
    "tests/unit/test_model_outcome.mojo",
    "tests/unit/test_model_parse_disposition.mojo",
    "tests/unit/test_model_slow.mojo",
    "tests/unit/test_model_test_counts.mojo",
    "tests/unit/test_model_test_result.mojo",
    "tests/unit/test_protocol_corruption.mojo",
    "tests/unit/test_protocol_matrix.mojo",
    "tests/unit/test_report_annotations.mojo",
    "tests/unit/test_report_composite.mojo",
    "tests/unit/test_report_console.mojo",
    "tests/unit/test_report_coordinator.mojo",
    "tests/unit/test_report_escape.mojo",
    "tests/unit/test_report_json_reporter.mojo",
    "tests/unit/test_report_json_stream.mojo",
    "tests/unit/test_report_junit.mojo",
    "tests/unit/test_report_junit_finalize.mojo",
    "tests/unit/test_report_junit_reporter.mojo",
    "tests/unit/test_report_recording.mojo",
    "tests/unit/test_report_signals.mojo",
    "tests/unit/test_select_logic.mojo",
    "tests/unit/test_select_operands.mojo",
    "tests/unit/test_session_attribution.mojo",
    "tests/unit/test_session_clamp.mojo",
    "tests/unit/test_session_classify.mojo",
    "tests/unit/test_session_detail.mojo",
    "tests/unit/test_session_mangle.mojo",
    "tests/unit/test_session_pipeline.mojo",
    "tests/unit/test_session_precompile_paths.mojo",
    "tests/unit/test_session_resilience.mojo",
    "tests/unit/test_session_retry_class.mojo",
    "tests/unit/test_session_shard.mojo",
    "tests/unit/test_session_verdict.mojo",
)
CLASSIFIED_TEST_COUNT = 987
SUPPORT_MODULES = {
    "exec_helpers.mojo",
    "session_fixtures.mojo",
    "tmptree.mojo",
    "transcript_cases.mojo",
}
EXEC_FIXTURES = {
    "README.md",
    "argv_echoer.py",
    "close_streams_then_hang.py",
    "dual_flooder.py",
    "env_echo.py",
    "escaped_pipe_holder.py",
    "etxtbsy_target.sh",
    "exit_nonzero.py",
    "flooding_grandchild.py",
    "grandchild_exit0.py",
    "grandchild_spawner.py",
    "path_probe.sh",
    "path_resolver.py",
    "self_signaler.py",
    "sigterm_grace_exit.py",
    "sigterm_ignorer.py",
    "sleeper.py",
}
PROTOCOL_FIXTURES = {
    "crashing.mojo",
    "empty.mojo",
    "mixed.mojo",
    "noisy.mojo",
    "passing.mojo",
    "raising.mojo",
    "segfault.mojo",
    "skipped.mojo",
    "twofail.mojo",
}
E2E_NATIVE_FIXTURES = {
    "e2e_json_terminal_write_fault.c",
}
E2E_HARNESS_PATHS = {
    Path("scripts/e2e/__init__.py"),
    Path("scripts/e2e/__main__.py"),
    Path("scripts/e2e/assertions.py"),
    Path("scripts/e2e/main_open.py"),
    Path("scripts/e2e/runner.py"),
    Path("scripts/e2e/scenarios/__init__.py"),
    Path("scripts/e2e/scenarios/annotations.py"),
    Path("scripts/e2e/scenarios/core.py"),
    Path("scripts/e2e/scenarios/json_reporter.py"),
    Path("scripts/e2e/scenarios/junit_reporter.py"),
    Path("scripts/e2e/scenarios/resilience.py"),
    Path("scripts/e2e/scenarios/selection.py"),
}

E2E_SCENARIO_NAMES = (
    "manifest-completeness",
    "resilience-matrix",
    "default-suite",
    "hostile",
    "single-pass",
    "exitfirst",
    "maxfail",
    "retries-flaky",
    "crash-attribution",
    "attribution-reruns-crashed-binary",
    "compile-timeout",
    "compile-crash-signature",
    "exclude+stale",
    "all-excluded",
    "empty-dir",
    "failing-gate",
    "timeout",
    "timeout-escalation",
    "precompile",
    "precompile-timeout",
    "precompile-crash-retry",
    "precompile-promotion",
    "quiet-verbose",
    "show-output",
    "durations",
    "color",
    "usage-refusals",
    "selection-keyword",
    "selection-node-id",
    "selection-union",
    "selection-malformed-node-id",
    "selection-unknown-test",
    "selection-empty",
    "selection-chameleon",
    "single-build",
    "stale-recovery-two-builds",
    "collect",
    "passthrough+forbidden",
    "out-of-root",
    "internal-error",
    "runtime-open-failure",
    "interrupt",
    "json-forward-compat",
    "json-purity",
    "json-color-relocated-stderr",
    "json-destination-taxonomy",
    "json-truncation-interrupt",
    "json-truncation-sigkill",
    "json-truncation-dead-pipe",
    "json-terminal-write-failure",
    "junit-scratch-cleanup",
    "junit-schema-gate",
    "junit-determinism",
    "junit-prior-report-intact",
    "junit-finalization-and-interrupt",
    "annotations-modes",
    "annotations-caps",
    "annotations-conflict",
    "annotations-fencing",
)

LIVE_COMMAND_FIXED_PATHS = (
    Path("README.md"),
    Path("AGENTS.md"),
    Path("pixi.toml"),
    Path("notes/console-captures/README.md"),
)
LIVE_COMMAND_GLOBS = (
    "scripts/**/*.py",
    "scripts/**/*.sh",
    "src/**/*.mojo",
    "tests/**/*.mojo",
    "tests/**/*.py",
    "tests/**/*.sh",
    "e2e/**/*.mojo",
    "e2e/**/*.py",
    "e2e/**/*.sh",
    "native/**/*.c",
    "native/**/*.h",
    ".github/workflows/**/*.yml",
    ".github/workflows/**/*.yaml",
    "recipe/**/*",
    ".agents/skills/**/SKILL.md",
)
PYTHON_EXECUTABLE_RE = re.compile(r"python(?:\d+(?:\.\d+)*)?")
DIRECT_SCRIPT_RE = re.compile(r"scripts/[A-Za-z0-9_./-]+\.py")
REGISTRATION_RE = re.compile(
    r"^    suite_(\d+)\.test\[_mtest_module_(\d+)\."
    r"(test_[A-Za-z0-9_]+)\]\(\)$"
)
README_SCAN_EXCLUDED_DIRS = {
    ".git",
    ".pixi",
    "build",
    "notes",
}



def check_top_level_script_layout(repo_root: Path = REPO_ROOT) -> None:
    """Pin the sole provenance-required exceptions to nested script packages."""
    _require_nonempty("top-level script", TOP_LEVEL_SCRIPT_FILES)
    scripts_dir = repo_root / "scripts"
    actual = {
        path.relative_to(repo_root)
        for path in scripts_dir.iterdir()
        if path.is_file() or path.is_symlink()
    }
    expected = set(TOP_LEVEL_SCRIPT_FILES)
    if actual != expected:
        raise AssertionError(
            "top-level scripts membership mismatch: "
            f"missing={sorted(expected - actual)}, extra={sorted(actual - expected)}"
        )


def _independent_test_function_names(source: str) -> tuple[str, ...]:
    """Parse top-level test declarations without aggregate helpers."""
    names: list[str] = []
    for line in source.splitlines():
        if not line.startswith("def "):
            continue
        declaration = line.removeprefix("def ")
        opening = declaration.find("(")
        if opening == -1:
            continue
        prefix = declaration[:opening]
        name = prefix.rstrip()
        if prefix[len(name) :] and not prefix[len(name) :].isspace():
            continue
        if not name.startswith("test_") or len(name) == len("test_"):
            continue
        if not name or any(
            not (character.isascii() and (character.isalnum() or character == "_"))
            for character in name
        ):
            continue
        names.append(name)
    if not names:
        raise AssertionError("independent oracle found no test_* functions")
    if len(names) != len(set(names)):
        raise AssertionError("independent oracle found duplicate test function names")
    return tuple(names)


def independent_registration_membership(
    repo_root: Path, paths: tuple[str, ...]
) -> tuple[tuple[str, str], ...]:
    """Return ordered path/function membership from an independent source parser."""
    membership: list[tuple[str, str]] = []
    for relative in paths:
        source = (repo_root / relative).read_text(encoding="utf-8")
        membership.extend(
            (relative, function)
            for function in _independent_test_function_names(source)
        )
    return tuple(membership)


def check_classified_entrypoint(
    repo_root: Path,
    paths: tuple[str, ...],
    *,
    expected_count: int,
) -> None:
    """Check generated imports and registrations against independent source truth."""
    expected_membership = independent_registration_membership(repo_root, paths)
    if len(expected_membership) != expected_count:
        raise AssertionError(
            "classified test count mismatch: "
            f"expected={expected_count}, actual={len(expected_membership)}"
        )

    modules = aggregate.load_modules(repo_root, [Path(path) for path in paths])
    generated_lines = aggregate.render_entrypoint(modules).splitlines()
    expected_imports = [
        f"import {path.removesuffix('.mojo').replace('/', '.')} "
        f"as _mtest_module_{index}"
        for index, path in enumerate(paths)
    ]
    actual_imports = [
        line for line in generated_lines if line.startswith("import tests.")
    ]
    if actual_imports != expected_imports:
        raise AssertionError("aggregate entrypoint import membership/order drifted")

    expected_markers = [
        f'    print("==> {path}", flush=True)' for path in paths
    ]
    actual_markers = [
        line for line in generated_lines if line.startswith('    print("==> tests/')
    ]
    if actual_markers != expected_markers:
        raise AssertionError("aggregate entrypoint marker membership/order drifted")

    actual_membership: list[tuple[str, str]] = []
    for line in generated_lines:
        if not line.startswith("    suite_") or ".test[" not in line:
            continue
        match = REGISTRATION_RE.fullmatch(line)
        if match is None:
            raise AssertionError(
                "aggregate entrypoint test registration syntax drifted: "
                f"{line!r}"
            )
        suite_index = int(match.group(1))
        module_index = int(match.group(2))
        if suite_index != module_index or module_index >= len(paths):
            raise AssertionError(
                "aggregate entrypoint test registration alias drifted: "
                f"{line!r}"
            )
        actual_membership.append((paths[module_index], match.group(3)))
    if tuple(actual_membership) != expected_membership:
        raise AssertionError(
            "aggregate entrypoint test registration membership/order drifted"
        )


def check_suite_layout() -> None:
    """Every aggregate module and support module has its classified home."""
    _require_nonempty("unit suite", UNIT_SUITES)
    _require_nonempty("integration suite", INTEGRATION_SUITES)
    _require_nonempty("classified path", CLASSIFIED_PATHS)
    _require_nonempty("support module", SUPPORT_MODULES)
    tests_dir = REPO_ROOT / "tests"
    actual_unit = {path.name for path in (tests_dir / "unit").glob("test_*.mojo")}
    actual_integration = {
        path.name for path in (tests_dir / "integration").glob("test_*.mojo")
    }
    if actual_unit != UNIT_SUITES:
        raise AssertionError(
            "unit suite membership mismatch: "
            f"missing={sorted(UNIT_SUITES - actual_unit)}, "
            f"extra={sorted(actual_unit - UNIT_SUITES)}"
        )
    if actual_integration != INTEGRATION_SUITES:
        raise AssertionError(
            "integration suite membership mismatch: "
            f"missing={sorted(INTEGRATION_SUITES - actual_integration)}, "
            f"extra={sorted(actual_integration - INTEGRATION_SUITES)}"
        )
    all_suites = {
        path.relative_to(tests_dir)
        for path in tests_dir.rglob("test_*.mojo")
        if path.is_file()
    }
    classified = {
        *(Path("unit") / name for name in UNIT_SUITES),
        *(Path("integration") / name for name in INTEGRATION_SUITES),
    }
    if all_suites != classified:
        raise AssertionError(
            "tests/ contains a test module outside unit/integration: "
            f"{sorted(str(path) for path in all_suites - classified)}"
        )
    discovered = aggregate.discover_test_files(
        REPO_ROOT,
        [Path("tests/unit"), Path("tests/integration")],
    )
    actual_paths = tuple(path.as_posix() for path in discovered)
    if actual_paths != CLASSIFIED_PATHS:
        raise AssertionError(
            "classified path ordering/membership mismatch: "
            f"expected={list(CLASSIFIED_PATHS)}, actual={list(actual_paths)}"
        )
    check_classified_entrypoint(
        REPO_ROOT,
        CLASSIFIED_PATHS,
        expected_count=CLASSIFIED_TEST_COUNT,
    )
    for package in (tests_dir, tests_dir / "unit", tests_dir / "integration"):
        if not (package / "__init__.mojo").is_file():
            raise AssertionError(f"aggregate package marker missing: {package}")
    for relative in sorted(classified, key=lambda path: os.fsencode(str(path))):
        source = (tests_dir / relative).read_text(encoding="utf-8")
        try:
            aggregate.test_function_names(source)
        except ValueError as exc:
            raise AssertionError(f"invalid aggregate module {relative}: {exc}") from exc
    try:
        dogfood.dogfood_test_files(REPO_ROOT)
    except RuntimeError as exc:
        raise AssertionError(str(exc)) from exc
    actual_support = {
        path.name for path in (tests_dir / "support").glob("*.mojo")
    }
    if actual_support != SUPPORT_MODULES:
        raise AssertionError(
            "support module membership mismatch: "
            f"missing={sorted(SUPPORT_MODULES - actual_support)}, "
            f"extra={sorted(actual_support - SUPPORT_MODULES)}"
        )


def check_exec_fixture_layout() -> None:
    """Exec subprocess actors live with tests, not developer harnesses."""
    _require_nonempty("exec fixture", EXEC_FIXTURES)
    fixture_dir = REPO_ROOT / "tests" / "fixtures" / "exec"
    actual = {path.name for path in fixture_dir.iterdir()} if fixture_dir.exists() else set()
    if actual != EXEC_FIXTURES:
        raise AssertionError(
            "exec fixture membership mismatch: "
            f"missing={sorted(EXEC_FIXTURES - actual)}, "
            f"extra={sorted(actual - EXEC_FIXTURES)}"
        )
    if (REPO_ROOT / "scripts" / "exec_targets").exists():
        raise AssertionError("obsolete scripts/exec_targets directory still exists")


def check_e2e_native_fixture_layout() -> None:
    """The E2E-only native fault sources have exact harness membership."""
    _require_nonempty("E2E native fixture", E2E_NATIVE_FIXTURES)
    fixture_dir = REPO_ROOT / "tests" / "native"
    actual = {path.name for path in fixture_dir.glob("e2e_*")}
    if actual != E2E_NATIVE_FIXTURES:
        raise AssertionError(
            "e2e native fixture membership mismatch: "
            f"missing={sorted(E2E_NATIVE_FIXTURES - actual)}, "
            f"extra={sorted(actual - E2E_NATIVE_FIXTURES)}"
        )



def check_protocol_asset_layout() -> None:
    """Protocol generator inputs and outputs occupy their documented homes."""
    _require_nonempty("protocol fixture", PROTOCOL_FIXTURES)
    fixtures = REPO_ROOT / "tests" / "fixtures" / "protocol"
    actual_fixtures = (
        {path.name for path in fixtures.iterdir()} if fixtures.exists() else set()
    )
    if actual_fixtures != PROTOCOL_FIXTURES:
        raise AssertionError(
            "protocol fixture membership mismatch: "
            f"missing={sorted(PROTOCOL_FIXTURES - actual_fixtures)}, "
            f"extra={sorted(actual_fixtures - PROTOCOL_FIXTURES)}"
        )

    snapshots = REPO_ROOT / "tests" / "snapshots" / "protocol"
    manifest = snapshots / "MANIFEST.txt"
    if not manifest.is_file():
        raise AssertionError("protocol snapshot MANIFEST.txt is missing")
    listed = tuple(manifest.read_text(encoding="utf-8").splitlines())
    actual_snapshots = tuple(
        sorted(path.name for path in snapshots.glob("*.txt") if path != manifest)
    )
    if listed != actual_snapshots or len(listed) != 22:
        raise AssertionError(
            "protocol snapshot manifest/membership mismatch: "
            f"listed={list(listed)}, actual={list(actual_snapshots)}"
        )
    for obsolete in (REPO_ROOT / "fixtures", REPO_ROOT / "goldens"):
        if obsolete.exists():
            raise AssertionError(f"obsolete protocol asset root still exists: {obsolete}")


def check_e2e_layout() -> None:
    """Known-outcome CLI inputs stay outside self-host discovery."""
    _require_nonempty("E2E scenario", E2E_SCENARIO_NAMES)
    _require_nonempty("E2E harness path", E2E_HARNESS_PATHS)
    harness_root = REPO_ROOT / "scripts" / "e2e"
    harness_paths = {
        path.relative_to(REPO_ROOT)
        for path in harness_root.rglob("*.py")
        if path.is_file()
    }
    if harness_paths != E2E_HARNESS_PATHS:
        raise AssertionError(
            "E2E harness package mismatch: "
            f"missing={sorted(E2E_HARNESS_PATHS - harness_paths)}, "
            f"extra={sorted(harness_paths - E2E_HARNESS_PATHS)}"
        )
    obsolete_paths = (
        REPO_ROOT / "scripts" / "e2e_check.py",
        REPO_ROOT / "scripts" / "main_open_check.py",
    )
    if any(path.exists() for path in obsolete_paths):
        raise AssertionError("obsolete top-level E2E compatibility module remains")

    pixi_manifest = tomllib.loads(
        (REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
    )
    e2e_command = pixi_manifest.get("tasks", {}).get("e2e", {}).get("cmd")
    if e2e_command != "python -m scripts.e2e":
        raise AssertionError(
            "the sole E2E task command must be `python -m scripts.e2e`"
        )

    e2e_root = REPO_ROOT / "e2e"
    manifest_path = e2e_root / "manifest.json"
    if not manifest_path.is_file():
        raise AssertionError("e2e/manifest.json is missing")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("e2e_root") != "e2e":
        raise AssertionError("e2e manifest does not declare e2e_root=e2e")
    rows = set(manifest["tests"])
    discovered = {
        path.relative_to(REPO_ROOT).as_posix()
        for path in e2e_root.rglob("test_*.mojo")
    }
    if rows != discovered or len(rows) != 31:
        raise AssertionError(
            "e2e manifest/discovery mismatch: "
            f"missing={sorted(discovered - rows)}, stale={sorted(rows - discovered)}"
        )
    scenario_names = tuple(name for name, _function in e2e_main.SCENARIOS)
    if scenario_names != E2E_SCENARIO_NAMES:
        raise AssertionError(
            "E2E scenario membership/order mismatch: "
            f"expected={list(E2E_SCENARIO_NAMES)}, actual={list(scenario_names)}"
        )
    if len(scenario_names) != 59 or len(set(scenario_names)) != len(scenario_names):
        raise AssertionError(
            "E2E scenarios must contain 59 unique names in the pinned order"
        )
    referenced = {
        *rows,
        *manifest.get("non_discovered", {}).keys(),
        *manifest.get("support_files", {}).keys(),
    }
    if any(not path.startswith("e2e/") for path in referenced):
        raise AssertionError("e2e manifest retains a path outside e2e/")
    if (REPO_ROOT / "testdata").exists():
        raise AssertionError("obsolete testdata/ root still exists")



def live_command_files(repo_root: Path) -> tuple[Path, ...]:
    """Return live source and command surfaces, excluding historical notes."""
    candidates = {
        relative
        for relative in LIVE_COMMAND_FIXED_PATHS
        if (repo_root / relative).is_file()
    }
    for pattern in LIVE_COMMAND_GLOBS:
        candidates.update(
            path.relative_to(repo_root)
            for path in repo_root.glob(pattern)
            if path.is_file()
        )
    for directory, dirnames, filenames in os.walk(repo_root, followlinks=False):
        dirnames[:] = [
            name for name in dirnames if name not in README_SCAN_EXCLUDED_DIRS
        ]
        if "README.md" not in filenames:
            continue
        path = Path(directory) / "README.md"
        candidates.add(path.relative_to(repo_root))
    return tuple(sorted(candidates, key=lambda path: os.fsencode(str(path))))


def _normalized_shell_word(word: str) -> str:
    """Strip presentation punctuation without changing command path content."""
    return word.strip("`'\"[]{}(),:")


def _is_python_executable(word: str) -> bool:
    """Return whether a shell word names a Python interpreter executable."""
    normalized = _normalized_shell_word(word)
    return PYTHON_EXECUTABLE_RE.fullmatch(Path(normalized).name.lower()) is not None


def _is_direct_script(word: str) -> bool:
    """Return whether a shell word is a repository-relative Python script."""
    normalized = _normalized_shell_word(word).removeprefix("./")
    return DIRECT_SCRIPT_RE.fullmatch(normalized) is not None


def _shell_words(text: str) -> list[str]:
    """Split one command-like line, including commands inside quoted fields."""
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        words = list(lexer)
    except ValueError:
        return []
    expanded: list[str] = []
    for word in words:
        if any(character.isspace() for character in word):
            expanded.extend(_shell_words(word))
        else:
            expanded.append(word)
    return expanded


def _argv_has_direct_script(words: list[str]) -> bool:
    """Detect a script operand after an interpreter and its options."""
    option_takes_value = {"-W", "-X", "--check-hash-based-pycs"}
    for interpreter_index, word in enumerate(words):
        if not _is_python_executable(word):
            continue
        index = interpreter_index + 1
        while index < len(words):
            candidate = _normalized_shell_word(words[index])
            if candidate in {";", "&&", "||", "|", "(", ")"}:
                break
            if candidate in {"-m", "-c"}:
                break
            if candidate.startswith("-"):
                consumes_value = candidate in option_takes_value
                index += 2 if consumes_value else 1
                continue
            if _is_direct_script(candidate):
                return True
            break
    return False


def _ast_argv_has_direct_script(node: ast.AST) -> bool:
    """Detect a literal argv headed by sys.executable or a Python path."""
    if not isinstance(node, (ast.List, ast.Tuple)) or not node.elts:
        return False
    first = node.elts[0]
    if (
        isinstance(first, ast.Attribute)
        and isinstance(first.value, ast.Name)
        and first.value.id == "sys"
        and first.attr == "executable"
    ):
        words = ["python"]
    elif isinstance(first, ast.Constant) and isinstance(first.value, str):
        if not _is_python_executable(first.value):
            return False
        words = [first.value]
    else:
        return False
    for element in node.elts[1:]:
        if not isinstance(element, ast.Constant) or not isinstance(element.value, str):
            return False
        words.append(element.value)
    return _argv_has_direct_script(words)


def direct_script_invocations(path: Path, contents: str) -> tuple[str, ...]:
    """Return direct Python-script command forms found in one live surface."""
    findings: set[str] = set()
    for line_number, line in enumerate(contents.splitlines(), start=1):
        if _argv_has_direct_script(_shell_words(line)):
            findings.add(f"{path.as_posix()}:{line_number}: direct command")
    if path.suffix == ".py":
        try:
            tree = ast.parse(contents, filename=str(path))
        except SyntaxError:
            tree = None
        if tree is not None:
            for node in ast.walk(tree):
                if _ast_argv_has_direct_script(node):
                    findings.add(
                        f"{path.as_posix()}:{node.lineno}: direct argv"
                    )
    return tuple(sorted(findings))


def live_direct_invocations(repo_root: Path) -> tuple[str, ...]:
    """Return direct script invocations from live repository command surfaces."""
    findings: list[str] = []
    for relative in live_command_files(repo_root):
        path = repo_root / relative
        try:
            contents = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise AssertionError(
                f"could not inspect live file {relative}: {exc}"
            ) from exc
        findings.extend(direct_script_invocations(relative, contents))
    return tuple(findings)


def check_python_package_invocation() -> None:
    """Python harnesses use package imports and repository-root module commands."""
    scripts_dir = REPO_ROOT / "scripts"
    if not (scripts_dir / "__init__.py").is_file():
        raise AssertionError("scripts package marker is missing")

    module_names = {path.stem for path in scripts_dir.glob("*.py")}
    flat_imports: list[str] = []
    for path in sorted(scripts_dir.glob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for imported in node.names:
                    if imported.name in module_names:
                        flat_imports.append(
                            f"{path.relative_to(REPO_ROOT)}:{node.lineno}: "
                            f"import {imported.name}"
                        )
            elif isinstance(node, ast.ImportFrom) and node.module in module_names:
                flat_imports.append(
                    f"{path.relative_to(REPO_ROOT)}:{node.lineno}: "
                    f"from {node.module} import ..."
                )
    if flat_imports:
        raise AssertionError(f"flat scripts imports remain: {flat_imports}")

    direct_invocations = live_direct_invocations(REPO_ROOT)
    if direct_invocations:
        raise AssertionError(
            "direct Python script invocations remain: "
            f"{list(direct_invocations)}"
        )


def check_build_source_visibility(repo_root: Path = REPO_ROOT) -> None:
    """Require the build-tool package to be complete, visible, and tracked."""
    _require_nonempty("build source", BUILD_SOURCE_PATHS)
    build_dir = repo_root / "scripts" / "build"
    actual = {
        path.relative_to(repo_root)
        for path in build_dir.iterdir()
        if path.is_file()
    } if build_dir.is_dir() else set()
    expected = set(BUILD_SOURCE_PATHS)
    if actual != expected:
        raise AssertionError(
            "scripts/build source membership mismatch: "
            f"missing={sorted(expected - actual)}, extra={sorted(actual - expected)}"
        )

    operands = [path.as_posix() for path in BUILD_SOURCE_PATHS]
    ignored = subprocess.run(
        ["git", "-C", str(repo_root), "check-ignore", "--no-index", *operands],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if ignored.returncode not in (0, 1):
        raise AssertionError(
            f"could not inspect scripts/build ignore status: {ignored.stderr.strip()}"
        )
    if ignored.returncode == 0:
        raise AssertionError(
            "scripts/build source is ignored: "
            f"{ignored.stdout.splitlines()}"
        )

    tracked = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "ls-files",
            "--error-unmatch",
            "--",
            *operands,
        ],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if tracked.returncode != 0:
        raise AssertionError("scripts/build source is untracked")



def _require_nonempty(name: str, values: object) -> None:
    """Reject an accidentally disabled intended inventory."""
    if not values:
        raise AssertionError(f"{name} intended inventory is empty")


def main() -> int:
    """Run every repository layout and command-policy check serially."""
    try:
        check_top_level_script_layout()
        check_suite_layout()
        check_exec_fixture_layout()
        check_e2e_native_fixture_layout()
        check_protocol_asset_layout()
        check_e2e_layout()
        check_python_package_invocation()
        check_build_source_visibility()
    except (AssertionError, OSError, subprocess.SubprocessError) as exc:
        print(f"layout-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("layout-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
