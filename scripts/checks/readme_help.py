#!/usr/bin/env python3
"""Require the CLI reference page's help fence to equal the real binary's stdout.

The listing lives in `docs/cli-reference.md`. The module keeps its
`readme_help` name, and the pixi task its `readme-help-check` name, because
hosted CI calls the task by name.
"""

from __future__ import annotations

import difflib
from pathlib import Path
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
REFERENCE_PATH = Path("docs/cli-reference.md")
SECTION = b"# CLI reference\n"
OPEN_FENCE = b"```text\n"
CLOSE_FENCE = b"```"


def _readme_help_block(contents: bytes) -> bytes:
    """Extract the single text fence in the CLI reference section."""
    if contents.count(SECTION) != 1:
        raise AssertionError(
            f"{REFERENCE_PATH} must contain exactly one CLI reference section"
        )
    section_start = contents.index(SECTION) + len(SECTION)
    next_section = contents.find(b"\n## ", section_start)
    section_end = len(contents) if next_section == -1 else next_section
    section = contents[section_start:section_end]
    lines = section.splitlines(keepends=True)
    opening_indices = [index for index, line in enumerate(lines) if line == OPEN_FENCE]
    if len(opening_indices) != 1:
        raise AssertionError("CLI reference must contain exactly one text fence")
    block_lines: list[bytes] = []
    for line in lines[opening_indices[0] + 1 :]:
        if line in (CLOSE_FENCE + b"\n", CLOSE_FENCE + b"\r\n", CLOSE_FENCE):
            return b"".join(block_lines)
        block_lines.append(line)
    raise AssertionError("CLI reference text fence is not closed")


def check_readme_help(repo_root: Path = REPO_ROOT) -> None:
    """Compare the CLI reference help fence with the built binary byte-for-byte."""
    documented = _readme_help_block((repo_root / REFERENCE_PATH).read_bytes())
    binary = repo_root / "build" / "mtest"
    try:
        run = subprocess.run(
            [binary, "--help"],
            cwd=repo_root,
            capture_output=True,
            timeout=30,
            check=False,
        )
    except FileNotFoundError as exc:
        raise AssertionError(f"built binary is missing: {binary}") from exc
    except subprocess.TimeoutExpired as exc:
        raise AssertionError("built binary --help exceeded 30 seconds") from exc
    if run.returncode != 0:
        raise AssertionError(
            f"built binary --help exited {run.returncode}: "
            f"{run.stderr.decode('utf-8', errors='replace')}"
        )
    if run.stderr:
        raise AssertionError(
            "built binary --help wrote stderr: "
            + run.stderr.decode("utf-8", errors="replace")
        )
    if documented != run.stdout:
        diff = "".join(
            difflib.unified_diff(
                documented.decode("utf-8", errors="replace").splitlines(keepends=True),
                run.stdout.decode("utf-8", errors="replace").splitlines(keepends=True),
                fromfile=f"{REFERENCE_PATH} help fence",
                tofile="build/mtest --help",
            )
        )
        raise AssertionError(
            f"{REFERENCE_PATH} help fence differs from the binary:\n" + diff
        )


def main() -> int:
    """Run the gate and return zero only for byte-identical help."""
    try:
        check_readme_help()
    except AssertionError as exc:
        print(f"readme-help-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print(
        f"readme-help-check: OK — {REFERENCE_PATH} help fence matches "
        "build/mtest --help"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
