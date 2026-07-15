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


REPO_ROOT = Path(__file__).resolve().parent.parent


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


def main() -> int:
    try:
        check_recursive_direct_runner()
    except (AssertionError, OSError, subprocess.SubprocessError) as exc:
        print(f"harness-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("harness-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
