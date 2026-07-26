#!/usr/bin/env python3
"""Validate exact repository harness layout and invocation policy."""

from __future__ import annotations

import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tomllib

from scripts.build import package_consumption
from scripts.e2e import __main__ as e2e_main
from scripts.harness import aggregate, dogfood


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
VENDORED_TOML_PATHS = {
    Path("vendor/mojo-toml/CHECKSUMS.json"),
    Path("vendor/mojo-toml/LICENSE"),
    Path("vendor/mojo-toml/README.md"),
    Path("vendor/mojo-toml/toml/__init__.mojo"),
    Path("vendor/mojo-toml/toml/lexer.mojo"),
    Path("vendor/mojo-toml/toml/parser.mojo"),
}
VENDORED_TOML_RELEASE = "346b7ad723c034f7696723f4846203d47ef86951"
VENDORED_TOML_MAIN = "c3262adea2d314748716991f99d0276f4a0b5e79"
VENDORED_TOML_UPSTREAM_SHA256 = {
    "LICENSE": "f091af39a05aa9864f099a672495096e97ce62e962f03fa90324da83061dab43",
    "src/toml/__init__.mojo": (
        "2c95e4cac433f0639125be700472001963ac319324f397465e309cdde97764e7"
    ),
    "src/toml/lexer.mojo": (
        "408f420337d6a5b2d74c5f04f44f638ae6317333b833ba3a8ff92664cf811b16"
    ),
    "src/toml/parser.mojo": (
        "5b49c67071f99bdf6096c5ec4745037ca043061a7fcbdcfb20a86ee127067a4a"
    ),
}
VENDORED_TOML_LOCAL_CHECKSUM_PATHS = {
    "LICENSE",
    "toml/__init__.mojo",
    "toml/lexer.mojo",
    "toml/parser.mojo",
}
UNIT_SUITES = {
    "test_cache_registry.mojo",
    "test_cli_arity.mojo",
    "test_cli_arity0.mojo",
    "test_cli_build_flags.mojo",
    "test_cli_collect.mojo",
    "test_cli_doctor.mojo",
    "test_cli_grammar.mojo",
    "test_cli_inventory.mojo",
    "test_cli_overlay.mojo",
    "test_cli_parse.mojo",
    "test_config.mojo",
    "test_config_file.mojo",
    "test_config_lossy_utf8.mojo",
    "test_config_resolve.mojo",
    "test_config_show.mojo",
    "test_config_state.mojo",
    "test_config_toml_adversarial.mojo",
    "test_discover_fnmatch.mojo",
    "test_discover_normalize.mojo",
    "test_exec_pool_policy.mojo",
    "test_exec_spec.mojo",
    "test_exec_tty.mojo",
    "test_model_control_chars.mojo",
    "test_model_events.mojo",
    "test_model_exit_code.mojo",
    "test_model_node_id.mojo",
    "test_model_outcome.mojo",
    "test_model_parse_disposition.mojo",
    "test_model_slow.mojo",
    "test_model_test_counts.mojo",
    "test_model_test_result.mojo",
    "test_platform_temp_file.mojo",
    "test_protocol_corruption.mojo",
    "test_protocol_matrix.mojo",
    "test_report_annotations.mojo",
    "test_report_composite.mojo",
    "test_report_console.mojo",
    "test_report_console_text.mojo",
    "test_report_coordinator.mojo",
    "test_report_escape.mojo",
    "test_report_json_reporter.mojo",
    "test_report_json_stream.mojo",
    "test_report_junit.mojo",
    "test_report_junit_finalize.mojo",
    "test_report_junit_reporter.mojo",
    "test_report_recording.mojo",
    "test_report_signals.mojo",
    "test_select_failure_selection.mojo",
    "test_select_logic.mojo",
    "test_select_operands.mojo",
    "test_session_attribution.mojo",
    "test_session_clamp.mojo",
    "test_session_classify.mojo",
    "test_session_detail.mojo",
    "test_session_effective_settings.mojo",
    "test_session_mangle.mojo",
    "test_session_pipeline.mojo",
    "test_session_pool_plan.mojo",
    "test_session_pool_progress.mojo",
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
    "test_session_overrides.mojo",
    "test_session_pool_faults.mojo",
    "test_session_precompile.mojo",
    "test_session_rmtree.mojo",
    "test_session_schedule.mojo",
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
    "tests/integration/test_session_overrides.mojo",
    "tests/integration/test_session_pool_faults.mojo",
    "tests/integration/test_session_precompile.mojo",
    "tests/integration/test_session_rmtree.mojo",
    "tests/integration/test_session_schedule.mojo",
    "tests/integration/test_session_selection.mojo",
    "tests/integration/test_transcripts_smoke.mojo",
    "tests/unit/test_cache_registry.mojo",
    "tests/unit/test_cli_arity.mojo",
    "tests/unit/test_cli_arity0.mojo",
    "tests/unit/test_cli_build_flags.mojo",
    "tests/unit/test_cli_collect.mojo",
    "tests/unit/test_cli_doctor.mojo",
    "tests/unit/test_cli_grammar.mojo",
    "tests/unit/test_cli_inventory.mojo",
    "tests/unit/test_cli_overlay.mojo",
    "tests/unit/test_cli_parse.mojo",
    "tests/unit/test_config.mojo",
    "tests/unit/test_config_file.mojo",
    "tests/unit/test_config_lossy_utf8.mojo",
    "tests/unit/test_config_resolve.mojo",
    "tests/unit/test_config_show.mojo",
    "tests/unit/test_config_state.mojo",
    "tests/unit/test_config_toml_adversarial.mojo",
    "tests/unit/test_discover_fnmatch.mojo",
    "tests/unit/test_discover_normalize.mojo",
    "tests/unit/test_exec_pool_policy.mojo",
    "tests/unit/test_exec_spec.mojo",
    "tests/unit/test_exec_tty.mojo",
    "tests/unit/test_model_control_chars.mojo",
    "tests/unit/test_model_events.mojo",
    "tests/unit/test_model_exit_code.mojo",
    "tests/unit/test_model_node_id.mojo",
    "tests/unit/test_model_outcome.mojo",
    "tests/unit/test_model_parse_disposition.mojo",
    "tests/unit/test_model_slow.mojo",
    "tests/unit/test_model_test_counts.mojo",
    "tests/unit/test_model_test_result.mojo",
    "tests/unit/test_platform_temp_file.mojo",
    "tests/unit/test_protocol_corruption.mojo",
    "tests/unit/test_protocol_matrix.mojo",
    "tests/unit/test_report_annotations.mojo",
    "tests/unit/test_report_composite.mojo",
    "tests/unit/test_report_console.mojo",
    "tests/unit/test_report_console_text.mojo",
    "tests/unit/test_report_coordinator.mojo",
    "tests/unit/test_report_escape.mojo",
    "tests/unit/test_report_json_reporter.mojo",
    "tests/unit/test_report_json_stream.mojo",
    "tests/unit/test_report_junit.mojo",
    "tests/unit/test_report_junit_finalize.mojo",
    "tests/unit/test_report_junit_reporter.mojo",
    "tests/unit/test_report_recording.mojo",
    "tests/unit/test_report_signals.mojo",
    "tests/unit/test_select_failure_selection.mojo",
    "tests/unit/test_select_logic.mojo",
    "tests/unit/test_select_operands.mojo",
    "tests/unit/test_session_attribution.mojo",
    "tests/unit/test_session_clamp.mojo",
    "tests/unit/test_session_classify.mojo",
    "tests/unit/test_session_detail.mojo",
    "tests/unit/test_session_effective_settings.mojo",
    "tests/unit/test_session_mangle.mojo",
    "tests/unit/test_session_pipeline.mojo",
    "tests/unit/test_session_pool_plan.mojo",
    "tests/unit/test_session_pool_progress.mojo",
    "tests/unit/test_session_precompile_paths.mojo",
    "tests/unit/test_session_resilience.mojo",
    "tests/unit/test_session_retry_class.mojo",
    "tests/unit/test_session_shard.mojo",
    "tests/unit/test_session_verdict.mojo",
)
CLASSIFIED_TEST_COUNT = 1300
CLASSIFIED_ROOTS = (
    Path("tests/unit"),
    Path("tests/integration"),
)
CLASSIFIED_PACKAGE_MARKERS = {
    Path("tests/unit/__init__.mojo"),
    Path("tests/integration/__init__.mojo"),
}
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
    "hostile_report_actor.py",
    "path_probe.sh",
    "path_resolver.py",
    "self_signaler.py",
    "sigterm_grace_exit.py",
    "sigterm_ignorer.py",
    "sleeper.py",
    "tagged_streams.py",
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
    "e2e_config_open_fault.c",
    "e2e_json_terminal_write_fault.c",
    "e2e_state_persistence_fault.c",
}
E2E_HARNESS_PATHS = {
    Path("scripts/e2e/__init__.py"),
    Path("scripts/e2e/__main__.py"),
    Path("scripts/e2e/assertions.py"),
    Path("scripts/e2e/main_open.py"),
    Path("scripts/e2e/runner.py"),
    Path("scripts/e2e/scenarios/__init__.py"),
    Path("scripts/e2e/scenarios/annotations.py"),
    Path("scripts/e2e/scenarios/config_file.py"),
    Path("scripts/e2e/scenarios/config_show.py"),
    Path("scripts/e2e/scenarios/core.py"),
    Path("scripts/e2e/scenarios/doctor.py"),
    Path("scripts/e2e/scenarios/json_reporter.py"),
    Path("scripts/e2e/scenarios/junit_reporter.py"),
    Path("scripts/e2e/scenarios/parallel.py"),
    Path("scripts/e2e/scenarios/resilience.py"),
    Path("scripts/e2e/scenarios/selection.py"),
}

E2E_SCENARIO_NAMES = (
    "manifest-completeness",
    "resilience-matrix",
    "default-suite",
    "hostile",
    "hostile-console",
    "hostile-reporters",
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
    "config-resolution",
    "config-diagnostics",
    "config-state",
    "failure-reselection",
    "config-overrides",
    "config-show",
    "doctor-healthy",
    "doctor-malformed-config",
    "doctor-missing-config",
    "doctor-missing-toolchain",
    "doctor-unwritable-state",
    "doctor-interrupt",
    "doctor-config-free",
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
    "mojo-executable-precedence",
    "collect",
    "passthrough+forbidden",
    "out-of-root",
    "internal-error",
    "runtime-open-failure",
    "interrupt",
    "interrupt-sigterm",
    "interrupt-double",
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
    "parallel-projection-eq",
    "parallel-capacity-one",
    "parallel-window-overlap",
    "parallel-interrupt",
    "parallel-shard-disjoint",
    "collect-parallel",
    "parallel-auto-smoke",
    "parallel-json-workers",
    "parallel-j-rejected",
    "parallel-junit-canonical-eq",
    "parallel-progress-tty",
    "parallel-serial-noverlap",
    "parallel-serial-stale-glob",
    "parallel-fd-clamp",
)

LIVE_COMMAND_FIXED_PATHS = (
    Path("README.md"),
    Path("AGENTS.md"),
    Path("pixi.toml"),
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
    # untracked working notes, and linked worktrees holding other branches'
    # checkouts. Both are present locally and absent in a fresh clone, so
    # walking them would make this gate read a different file set on a
    # contributor's machine than on CI, and a README from an unrelated branch
    # could red it.
    "notes",
    ".worktrees",
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

    expected_markers = [f'    print("==> {path}", flush=True)' for path in paths]
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
                f"aggregate entrypoint test registration syntax drifted: {line!r}"
            )
        suite_index = int(match.group(1))
        module_index = int(match.group(2))
        if suite_index != module_index or module_index >= len(paths):
            raise AssertionError(
                f"aggregate entrypoint test registration alias drifted: {line!r}"
            )
        actual_membership.append((paths[module_index], match.group(3)))
    if tuple(actual_membership) != expected_membership:
        raise AssertionError(
            "aggregate entrypoint test registration membership/order drifted"
        )


def _reraise_walk_error(error: OSError) -> None:
    """Refuse to read an unreadable classified subtree as an empty one.

    `os.walk` swallows a directory-listing failure by default and yields
    nothing for that subtree, which would let an unreadable directory hide an
    unexecuted Mojo file behind a green gate.

    Args:
        error: The listing failure `os.walk` would otherwise have discarded.

    Raises:
        OSError: Always, re-raising `error` unchanged.
    """
    raise error


def classified_mojo_universe(root: Path) -> tuple[set[Path], set[Path]]:
    """Return regular and symlinked Mojo paths beneath both classified roots.

    Walks every directory entry under `tests/unit` and `tests/integration`
    without following directory symlinks. A regular file joins the Mojo
    universe when `.mojo` appears anywhere in its suffixes, so a misnamed
    `helper.mojo` and a parked `test_probe.mojo.disabled` are both visible to
    the caller rather than invisible to a `test_*.mojo` glob. A classified root
    that is itself a symlink is reported rather than walked through.

    Args:
        root: The repository root the classified suite directories live under.

    Returns:
        A pair of root-relative path sets: every regular Mojo-like file, and
        every symlinked entry regardless of its target or suffix.

    Raises:
        OSError: A directory beneath a classified root could not be listed. An
            unreadable subtree is a failure, never an empty one.
    """
    regular: set[Path] = set()
    symlinked: set[Path] = set()
    for classified_root in CLASSIFIED_ROOTS:
        absolute = root / classified_root
        if absolute.is_symlink():
            # `os.walk` always walks its top argument and `is_dir` follows the
            # link, so a relocated root has to be rejected before the walk.
            symlinked.add(classified_root)
            continue
        if not absolute.is_dir():
            continue
        for directory, dirnames, filenames in os.walk(
            absolute, onerror=_reraise_walk_error, followlinks=False
        ):
            current = Path(directory)
            retained: list[str] = []
            for name in dirnames:
                if (current / name).is_symlink():
                    symlinked.add((current / name).relative_to(root))
                else:
                    retained.append(name)
            dirnames[:] = retained
            for name in filenames:
                path = current / name
                relative = path.relative_to(root)
                if path.is_symlink():
                    symlinked.add(relative)
                elif ".mojo" in relative.suffixes:
                    regular.add(relative)
    return regular, symlinked


def check_classified_mojo_inventory(root: Path) -> None:
    """Require the classified roots to hold exactly the registered Mojo files.

    Args:
        root: The repository root the classified suite directories live under.

    Raises:
        AssertionError: A symlink sits under a classified root, or the Mojo
            universe there differs from the registered suites plus the two
            package markers in either direction.
    """
    regular, symlinked = classified_mojo_universe(root)
    if symlinked:
        raise AssertionError(
            "symlinked classified path: "
            f"{sorted(path.as_posix() for path in symlinked)}"
        )
    expected = {Path(path) for path in CLASSIFIED_PATHS} | CLASSIFIED_PACKAGE_MARKERS
    unexpected = regular - expected
    if unexpected:
        raise AssertionError(
            "unexpected classified Mojo file: "
            f"{sorted(path.as_posix() for path in unexpected)}"
        )
    missing = expected - regular
    if missing:
        raise AssertionError(
            "missing classified Mojo file: "
            f"{sorted(path.as_posix() for path in missing)}"
        )


def check_suite_layout() -> None:
    """Every aggregate module and support module has its classified home."""
    _require_nonempty("unit suite", UNIT_SUITES)
    _require_nonempty("integration suite", INTEGRATION_SUITES)
    _require_nonempty("classified path", CLASSIFIED_PATHS)
    _require_nonempty("classified root", CLASSIFIED_ROOTS)
    _require_nonempty("classified package marker", CLASSIFIED_PACKAGE_MARKERS)
    _require_nonempty("support module", SUPPORT_MODULES)
    check_classified_mojo_inventory(REPO_ROOT)
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
    actual_support = {path.name for path in (tests_dir / "support").glob("*.mojo")}
    if actual_support != SUPPORT_MODULES:
        raise AssertionError(
            "support module membership mismatch: "
            f"missing={sorted(SUPPORT_MODULES - actual_support)}, "
            f"extra={sorted(actual_support - SUPPORT_MODULES)}"
        )


def check_exec_fixture_layout() -> None:
    """Exec subprocess actors live with tests, not developer harnesses.

    Membership is exact and fail-closed: an unlisted actor is a finding, not a
    tolerated extra. The single exemption is `__pycache__`, which CPython writes
    into this directory the moment anything imports an actor as a module — the
    E2E harness does, to predict the hostile actor's payload — and which is
    generated output rather than a fixture anyone chose to add.
    """
    _require_nonempty("exec fixture", EXEC_FIXTURES)
    fixture_dir = REPO_ROOT / "tests" / "fixtures" / "exec"
    actual = (
        {path.name for path in fixture_dir.iterdir() if path.name != "__pycache__"}
        if fixture_dir.exists()
        else set()
    )
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
            raise AssertionError(
                f"obsolete protocol asset root still exists: {obsolete}"
            )


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

    pixi_manifest = tomllib.loads((REPO_ROOT / "pixi.toml").read_text(encoding="utf-8"))
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
        path.relative_to(REPO_ROOT).as_posix() for path in e2e_root.rglob("test_*.mojo")
    }
    if rows != discovered or len(rows) != 41:
        raise AssertionError(
            "e2e manifest/discovery mismatch: "
            f"missing={sorted(discovered - rows)}, stale={sorted(rows - discovered)}, "
            f"rows={len(rows)}"
        )
    scenario_names = tuple(name for name, _function in e2e_main.SCENARIOS)
    if scenario_names != E2E_SCENARIO_NAMES:
        raise AssertionError(
            "E2E scenario membership/order mismatch: "
            f"expected={list(E2E_SCENARIO_NAMES)}, actual={list(scenario_names)}"
        )
    if len(scenario_names) != 91 or len(set(scenario_names)) != len(scenario_names):
        raise AssertionError(
            "E2E scenarios must contain 91 unique names in the pinned order"
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
                # The helper matches only a literal list/tuple, both of which
                # are expressions; restating that here is what establishes that
                # `node.lineno` exists on the matched node.
                if isinstance(
                    node, (ast.List, ast.Tuple)
                ) and _ast_argv_has_direct_script(node):
                    findings.add(f"{path.as_posix()}:{node.lineno}: direct argv")
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
                flat_imports.extend(
                    f"{path.relative_to(REPO_ROOT)}:{node.lineno}: "
                    f"import {imported.name}"
                    for imported in node.names
                    if imported.name in module_names
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
            f"direct Python script invocations remain: {list(direct_invocations)}"
        )


def check_build_source_visibility(repo_root: Path = REPO_ROOT) -> None:
    """Require the build-tool package to be complete, visible, and tracked."""
    _require_nonempty("build source", BUILD_SOURCE_PATHS)
    build_dir = repo_root / "scripts" / "build"
    actual = (
        {path.relative_to(repo_root) for path in build_dir.iterdir() if path.is_file()}
        if build_dir.is_dir()
        else set()
    )
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
        capture_output=True,
    )
    if ignored.returncode not in (0, 1):
        raise AssertionError(
            f"could not inspect scripts/build ignore status: {ignored.stderr.strip()}"
        )
    if ignored.returncode == 0:
        raise AssertionError(
            f"scripts/build source is ignored: {ignored.stdout.splitlines()}"
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
        capture_output=True,
    )
    if tracked.returncode != 0:
        raise AssertionError("scripts/build source is untracked")


def check_vendored_toml_layout(repo_root: Path = REPO_ROOT) -> None:
    """Pin the native TOML source and its offline production-build path."""
    _require_nonempty("vendored TOML source", VENDORED_TOML_PATHS)
    vendor_root = repo_root / "vendor" / "mojo-toml"
    actual = {
        path.relative_to(repo_root) for path in vendor_root.rglob("*") if path.is_file()
    }
    if actual != VENDORED_TOML_PATHS:
        raise AssertionError(
            "vendored TOML membership mismatch: "
            f"missing={sorted(VENDORED_TOML_PATHS - actual)}, "
            f"extra={sorted(actual - VENDORED_TOML_PATHS)}"
        )

    manifest_path = vendor_root / "CHECKSUMS.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_metadata = {
        "repository": "https://github.com/DataBooth/mojo-toml",
        "license": "Apache-2.0",
        "release": VENDORED_TOML_RELEASE,
        "main": VENDORED_TOML_MAIN,
        "release_sha256": VENDORED_TOML_UPSTREAM_SHA256,
        "main_sha256": VENDORED_TOML_UPSTREAM_SHA256,
    }
    expected_keys = {*expected_metadata, "local_sha256"}
    if set(manifest) != expected_keys:
        raise AssertionError(
            "vendored TOML manifest key mismatch: "
            f"expected={sorted(expected_keys)}, got={sorted(manifest)}"
        )
    for key, expected in expected_metadata.items():
        if manifest.get(key) != expected:
            raise AssertionError(
                f"vendored TOML provenance mismatch for {key}: "
                f"expected={expected!r}, got={manifest.get(key)!r}"
            )
    local = manifest.get("local_sha256")
    if not isinstance(local, dict) or set(local) != VENDORED_TOML_LOCAL_CHECKSUM_PATHS:
        raise AssertionError(
            "vendored TOML local checksum membership mismatch: "
            f"expected={sorted(VENDORED_TOML_LOCAL_CHECKSUM_PATHS)}, "
            f"got={sorted(local) if isinstance(local, dict) else local!r}"
        )
    for relative, expected in local.items():
        actual_digest = hashlib.sha256(
            (vendor_root / relative).read_bytes()
        ).hexdigest()
        if actual_digest != expected:
            raise AssertionError(
                f"vendored TOML local checksum mismatch for {relative}: "
                f"expected={expected}, got={actual_digest}"
            )

    build_source = (repo_root / "scripts" / "build" / "production_build.sh").read_text(
        encoding="utf-8"
    )
    required_commands = (
        "mojo precompile vendor/mojo-toml/toml -o build/toml.mojopkg",
        "mojo precompile -I build src/mtest -o build/mtest.mojopkg",
        "mojo build -I build src/main.mojo -o build/mtest",
    )
    if any(command not in build_source for command in required_commands):
        raise AssertionError(
            "production build does not compile and link the vendored TOML package"
        )
    if len(re.findall(r"(?m)^\s*mojo precompile\b", build_source)) != 2:
        raise AssertionError(
            "production build must execute exactly two package precompiles"
        )
    if re.search(r"\b(curl|wget|git\s+(clone|fetch|pull))\b", build_source):
        raise AssertionError("production build fetches a dependency from the network")


def _require_nonempty(name: str, values: object) -> None:
    """Reject an accidentally disabled intended inventory."""
    if not values:
        raise AssertionError(f"{name} intended inventory is empty")


def check_package_fixture_contract(repo_root: Path = REPO_ROOT) -> None:
    """The package gate's failing fixture still has its declared outcome.

    `scripts/build/package_consumption.py` runs one fixed known-failing fixture
    through the INSTALLED binary and asserts an exact verdict and per-test
    arithmetic. Those expectations are only meaningful while the fixture itself
    still declares them, and the package gate costs a full package build to
    discover a drift. This pins the two together in the cheap harness gate.

    Args:
        repo_root: Repository root to read the fixture and E2E manifest from.

    Raises:
        AssertionError: The fixture is missing, is not a real file, or its
            declared outcome disagrees with what the package gate asserts.
    """
    relative = package_consumption.FAILING_FIXTURE
    fixture = repo_root / relative
    if not fixture.is_file() or fixture.is_symlink():
        raise AssertionError(
            f"the package gate's failing fixture is not a real file: {relative}"
        )
    manifest = json.loads(
        (repo_root / "e2e" / "manifest.json").read_text(encoding="utf-8")
    )
    row = manifest["tests"].get(relative)
    if row is None:
        raise AssertionError(
            f"the package gate's failing fixture is not declared in the E2E "
            f"manifest: {relative}"
        )
    declared = (
        row["verdict"],
        row["exit_class"],
        row["per_test"]["passed"],
        row["per_test"]["failed"],
    )
    expected = (
        "FAIL",
        1,
        package_consumption.FAILING_FIXTURE_PASSED,
        package_consumption.FAILING_FIXTURE_FAILED,
    )
    if declared != expected:
        raise AssertionError(
            "the package gate's failing fixture no longer declares the outcome "
            f"the gate asserts: declared={declared}, gate expects={expected}"
        )


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
        check_vendored_toml_layout()
        check_package_fixture_contract()
    except (AssertionError, OSError, subprocess.SubprocessError) as exc:
        print(f"layout-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("layout-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
