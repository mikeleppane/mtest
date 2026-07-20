#!/usr/bin/env python3
"""Regenerate protocol snapshots in scratch space and compare every byte."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
import subprocess
import sys
import tempfile

from scripts.checks.transcript_compare import DirectoryComparison, compare_directories


REPO_ROOT = Path(__file__).resolve().parents[2]
COMMITTED_SNAPSHOTS = REPO_ROOT / "tests" / "snapshots" / "protocol"

LIFECYCLE_WARNING = """
transcripts-check: committed snapshots differ from a fresh regeneration.
A red check after a repository change indicts the change, not the snapshots.
Regeneration is allowed only for an oracle-side change: a Mojo pin bump or a
deliberate fixture/matrix edit. If the oracle genuinely changed, run
`pixi run transcripts` and commit that result with the reason. Never hand-edit
a transcript to make this pass.
""".strip()


class SnapshotGenerationError(RuntimeError):
    """The provenance-pinned transcript generator failed in check mode."""


def generate_into(output_dir: Path) -> None:
    """Invoke the sole transcript writer against a scratch output directory."""
    completed = subprocess.run(
        [
            sys.executable,
            "-m",
            "scripts.gen_transcripts",
            "--out",
            str(output_dir),
        ],
        cwd=REPO_ROOT,
        stdout=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        raise SnapshotGenerationError(
            "scripts.gen_transcripts failed with exit "
            f"{completed.returncode}"
        )


def check_snapshots(
    expected_root: Path = COMMITTED_SNAPSHOTS,
    *,
    generate_into: Callable[[Path], None] = generate_into,
) -> DirectoryComparison:
    """Generate into an automatically cleaned directory and compare its tree."""
    with tempfile.TemporaryDirectory(prefix="mtest-transcripts-check-") as raw_tmp:
        actual_root = Path(raw_tmp)
        generate_into(actual_root)
        return compare_directories(expected_root, actual_root)


def main() -> int:
    """Run the hermetic protocol-snapshot gate."""
    try:
        result = check_snapshots()
    except (OSError, SnapshotGenerationError, subprocess.SubprocessError) as exc:
        print(f"transcripts-check: generation failed: {exc}", file=sys.stderr)
        return 1

    if not result.ok:
        for error in result.errors:
            print(error, file=sys.stderr, end="" if error.endswith("\n") else "\n")
        print(file=sys.stderr)
        print(LIFECYCLE_WARNING, file=sys.stderr)
        return 1

    print("transcripts-check: OK — transcripts match a fresh regeneration")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
