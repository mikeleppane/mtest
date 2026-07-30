#!/usr/bin/env python3
"""Format the complete tracked native source inventory with pinned Clang."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys

from scripts.checks.native_sources import require_ascii, tracked_native_sources


ROOT = Path(__file__).resolve().parents[2]
CLANG_FORMAT_VERSION = "clang-format version 18.1.8"


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    """Run one formatter command from the repository root."""
    return subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def require_clang_format() -> None:
    """Fail unless the formatter reports the pinned Clang version."""
    version = run(["clang-format", "--version"])
    if version.returncode != 0 or CLANG_FORMAT_VERSION not in version.stdout:
        raise SystemExit(
            "native-format: expected clang-format 18.1.8, got:\n" + version.stdout
        )


def main() -> int:
    """Format tracked native sources and confirm their ASCII-only invariant."""
    require_clang_format()
    sources = tracked_native_sources(ROOT)
    require_ascii(sources, label="native-format")
    command = [
        "clang-format",
        "-i",
        "--style=file",
        "--fallback-style=none",
        *(str(source) for source in sources),
    ]
    formatted = run(command)
    if formatted.returncode != 0:
        raise SystemExit("native-format: clang-format failed:\n" + formatted.stdout)
    require_ascii(sources, label="native-format")
    print("native-format: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
