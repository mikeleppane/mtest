#!/usr/bin/env python3
"""Fast self-tests for repository test harnesses.

These checks use disposable inputs and tool shims so they exercise the real
shell orchestration without recompiling the product test suite.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

from transcript_compare import compare_directories


REPO_ROOT = Path(__file__).resolve().parent.parent
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
    "test_model_events.mojo",
    "test_model_exit_code.mojo",
    "test_model_node_id.mojo",
    "test_model_outcome.mojo",
    "test_model_parse_disposition.mojo",
    "test_model_test_counts.mojo",
    "test_model_test_result.mojo",
    "test_protocol_corruption.mojo",
    "test_protocol_matrix.mojo",
    "test_report_composite.mojo",
    "test_report_console.mojo",
    "test_report_recording.mojo",
    "test_select_logic.mojo",
    "test_select_operands.mojo",
    "test_session_classify.mojo",
    "test_session_detail.mojo",
    "test_session_mangle.mojo",
    "test_session_verdict.mojo",
}
INTEGRATION_SUITES = {
    "test_discover_pipeline.mojo",
    "test_discover_walk.mojo",
    "test_exec_capture.mojo",
    "test_exec_decode.mojo",
    "test_exec_etxtbsy.mojo",
    "test_exec_fdhygiene.mojo",
    "test_exec_flood.mojo",
    "test_exec_interrupt.mojo",
    "test_exec_paths.mojo",
    "test_exec_prestart.mojo",
    "test_exec_reap.mojo",
    "test_exec_sweep.mojo",
    "test_exec_timeout.mojo",
    "test_protocol_collection.mojo",
    "test_protocol_report.mojo",
    "test_session_collect.mojo",
    "test_session_exit_codes.mojo",
    "test_session_flow.mojo",
    "test_session_gates.mojo",
    "test_session_handshake.mojo",
    "test_session_interrupt.mojo",
    "test_session_maxfail.mojo",
    "test_session_outcomes.mojo",
    "test_session_precompile.mojo",
    "test_session_selection.mojo",
    "test_transcripts_smoke.mojo",
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
    "etxtbsy_target.sh",
    "exit_nonzero.py",
    "flooding_grandchild.py",
    "grandchild_exit0.py",
    "grandchild_spawner.py",
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
    "skipped.mojo",
    "twofail.mojo",
}


def _write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def check_recursive_direct_runner() -> None:
    """The direct runner selects supplied roots and maps paths injectively."""
    tests_dir = REPO_ROOT / "tests"
    with tempfile.TemporaryDirectory(
        prefix=".harness-check-", dir=tests_dir
    ) as raw_tmp:
        tmp = Path(raw_tmp)
        root_a = tmp / "first"
        root_b = tmp / "second"
        root_a.mkdir()
        root_b.mkdir()
        source_a = root_a / "test_same_name.mojo"
        source_b = root_b / "test_same_name.mojo"
        source_a.write_text("# harness fixture A\n", encoding="utf-8")
        source_b.write_text("# harness fixture B\n", encoding="utf-8")
        disposable_outputs = REPO_ROOT / "build" / "tests" / tmp.name

        tools_dir = tmp / "tools"
        tools_dir.mkdir()
        log_path = tmp / "mojo-log.jsonl"
        fake_mojo = tools_dir / "mojo"
        _write_executable(
            fake_mojo,
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import stat
import sys

args = sys.argv[1:]
out = Path(args[args.index("-o") + 1])
out.parent.mkdir(parents=True, exist_ok=True)
if args[0] == "precompile":
    raise SystemExit(0)
if args[0] != "build":
    raise SystemExit(f"unexpected fake mojo command: {args}")
source = next(arg for arg in args if arg.endswith(".mojo"))
with open(os.environ["MTEST_FAKE_MOJO_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps({"source": source, "output": str(out)}) + "\\n")
out.write_text("#!/usr/bin/env bash\\nprintf '%s\\n' " + repr("RAN:" + source) + "\\n", encoding="utf-8")
out.chmod(out.stat().st_mode | stat.S_IXUSR)
""",
        )

        roots = [
            os.path.relpath(root_a, REPO_ROOT),
            os.path.relpath(root_b, REPO_ROOT),
        ]
        env = os.environ.copy()
        env["PATH"] = f"{tools_dir}{os.pathsep}{env['PATH']}"
        env["MTEST_FAKE_MOJO_LOG"] = str(log_path)
        try:
            result = subprocess.run(
                ["bash", "scripts/test_all.sh", *roots],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=30,
                check=False,
            )
            if result.returncode != 0:
                raise AssertionError(
                    f"recursive direct-runner probe exited {result.returncode}:\n"
                    f"{result.stdout}"
                )

            records = [
                json.loads(line)
                for line in log_path.read_text(encoding="utf-8").splitlines()
            ]
            expected_sources = {
                roots[index] + "/test_same_name.mojo" for index in range(2)
            }
            actual_sources = {record["source"] for record in records}
            if actual_sources != expected_sources:
                raise AssertionError(
                    "direct runner did not select exactly the supplied recursive "
                    f"roots: expected {sorted(expected_sources)}, got "
                    f"{sorted(actual_sources)}\n{result.stdout}"
                )
            outputs = {record["output"] for record in records}
            if len(outputs) != 2:
                raise AssertionError(
                    "same-basename suites mapped to a colliding output path: "
                    f"{sorted(outputs)}"
                )
            for source in sorted(expected_sources):
                if f"RAN:{source}" not in result.stdout:
                    raise AssertionError(f"direct runner did not execute {source}")
        finally:
            shutil.rmtree(disposable_outputs, ignore_errors=True)


def check_suite_layout() -> None:
    """Every executable suite and support module has its classified home."""
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
            "tests/ contains an executable suite outside unit/integration: "
            f"{sorted(str(path) for path in all_suites - classified)}"
        )
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


def check_transcript_comparator() -> None:
    """The real snapshot comparator accepts only an explicit path relocation."""
    with tempfile.TemporaryDirectory(prefix="mtest-transcript-compare-") as raw_tmp:
        tmp = Path(raw_tmp)
        before = tmp / "before"
        after = tmp / "after"
        before.mkdir()
        after.mkdir()
        old = b"<REPO>/fixtures/"
        new = b"<REPO>/tests/fixtures/protocol/"
        (before / "case.txt").write_bytes(b"source: " + old + b"passing.mojo\nPASS\n")
        (before / "MANIFEST.txt").write_bytes(b"case.txt\n")
        (after / "case.txt").write_bytes(b"source: " + new + b"passing.mojo\nPASS\n")
        (after / "MANIFEST.txt").write_bytes(b"case.txt\n")

        relocated = compare_directories(before, after, replacement=(old, new))
        if not relocated.ok or relocated.changed_files != ("case.txt",):
            raise AssertionError(
                "snapshot comparator rejected a path-only relocation: "
                f"{relocated.errors}"
            )

        (after / "case.txt").write_bytes(
            b"source: " + new + b"passing.mojo\nFAIL\n"
        )
        mutated = compare_directories(before, after, replacement=(old, new))
        if mutated.ok:
            raise AssertionError("snapshot comparator accepted a non-path mutation")

        (after / "case.txt").write_bytes((before / "case.txt").read_bytes())
        exact = compare_directories(before, after)
        if not exact.ok:
            raise AssertionError(f"exact snapshot comparator rejected equality: {exact.errors}")
        (after / "extra.txt").write_bytes(b"unexpected\n")
        extra = compare_directories(before, after)
        if extra.ok:
            raise AssertionError("snapshot comparator accepted an extra file")


def check_protocol_asset_layout() -> None:
    """Protocol generator inputs and outputs occupy their documented homes."""
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
    if listed != actual_snapshots or len(listed) != 21:
        raise AssertionError(
            "protocol snapshot manifest/membership mismatch: "
            f"listed={list(listed)}, actual={list(actual_snapshots)}"
        )
    for obsolete in (REPO_ROOT / "fixtures", REPO_ROOT / "goldens"):
        if obsolete.exists():
            raise AssertionError(f"obsolete protocol asset root still exists: {obsolete}")


def check_e2e_layout() -> None:
    """Known-outcome CLI inputs stay outside self-host discovery."""
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
    if rows != discovered or len(rows) != 25:
        raise AssertionError(
            "e2e manifest/discovery mismatch: "
            f"missing={sorted(discovered - rows)}, stale={sorted(rows - discovered)}"
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


def main() -> int:
    try:
        check_recursive_direct_runner()
        check_suite_layout()
        check_exec_fixture_layout()
        check_transcript_comparator()
        check_protocol_asset_layout()
        check_e2e_layout()
    except (AssertionError, OSError, subprocess.SubprocessError) as exc:
        print(f"harness-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("harness-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
