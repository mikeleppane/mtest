#!/usr/bin/env python3
"""Focused mutation tests for byte-exact transcript comparison."""

from __future__ import annotations

from contextlib import redirect_stderr
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest import mock

from scripts.checks import protocol_snapshots
from scripts.checks.transcript_compare import (
    DirectoryComparison,
    compare_directories,
)


def test_transcript_comparator() -> None:
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
        if mutated.ok or not any(
            "expected/case.txt" in error and "actual/case.txt" in error
            for error in mutated.errors
        ):
            raise AssertionError(
                "snapshot comparator did not report a byte mutation exactly"
            )

        (after / "case.txt").write_bytes((before / "case.txt").read_bytes())
        exact = compare_directories(before, after)
        if not exact.ok:
            raise AssertionError(f"exact snapshot comparator rejected equality: {exact.errors}")
        (after / "extra.txt").write_bytes(b"unexpected\n")
        extra = compare_directories(before, after)
        if extra.ok or "unexpected snapshot files: ['extra.txt']" not in extra.errors:
            raise AssertionError("snapshot comparator did not report an added file")
        (after / "extra.txt").unlink()
        (after / "case.txt").unlink()
        missing = compare_directories(before, after)
        if missing.ok or "missing snapshot files: ['case.txt']" not in missing.errors:
            raise AssertionError("snapshot comparator did not report a deleted file")


def _snapshot_tree(root: Path) -> None:
    """Write the smallest complete snapshot tree used by check-mode tests."""
    root.mkdir()
    (root / "case.txt").write_bytes(b"case bytes\n")
    (root / "MANIFEST.txt").write_bytes(b"case.txt\n")


def _check_with_mutation(
    expected: Path,
    mutate,
) -> tuple[DirectoryComparison, Path]:
    generated_root: Path | None = None

    def generate_into(output_dir: Path) -> None:
        nonlocal generated_root
        generated_root = output_dir
        shutil.copytree(expected, output_dir, dirs_exist_ok=True)
        mutate(output_dir)

    result = protocol_snapshots.check_snapshots(
        expected,
        generate_into=generate_into,
    )
    if generated_root is None:
        raise AssertionError("transcript check did not invoke its generator")
    return result, generated_root


def test_protocol_snapshot_check_mutations() -> None:
    """Check mode diagnoses complete-tree mutations and cleans its scratch tree."""
    with tempfile.TemporaryDirectory(prefix="mtest-protocol-check-test-") as raw_tmp:
        expected = Path(raw_tmp) / "expected"
        _snapshot_tree(expected)
        expected_before = {
            path.name: path.read_bytes() for path in expected.iterdir()
        }

        added, added_root = _check_with_mutation(
            expected,
            lambda output: (output / "added.txt").write_bytes(b"added\n"),
        )
        if added.ok or "unexpected snapshot files: ['added.txt']" not in added.errors:
            raise AssertionError("check mode did not diagnose an added snapshot")

        removed, removed_root = _check_with_mutation(
            expected,
            lambda output: (output / "case.txt").unlink(),
        )
        if removed.ok or "missing snapshot files: ['case.txt']" not in removed.errors:
            raise AssertionError("check mode did not diagnose a removed snapshot")

        modified, modified_root = _check_with_mutation(
            expected,
            lambda output: (output / "MANIFEST.txt").write_bytes(b"changed\n"),
        )
        if modified.ok or not any(
            "expected/MANIFEST.txt" in error and "actual/MANIFEST.txt" in error
            for error in modified.errors
        ):
            raise AssertionError("check mode did not diagnose modified MANIFEST bytes")

        if any(path.exists() for path in (added_root, removed_root, modified_root)):
            raise AssertionError("check mode leaked a generated temporary directory")
        expected_after = {
            path.name: path.read_bytes() for path in expected.iterdir()
        }
        if expected_after != expected_before:
            raise AssertionError("check mode changed the committed-tree stand-in")


def test_protocol_snapshot_check_delegates_to_the_generator() -> None:
    """The check command invokes the provenance-pinned writer as a module."""
    output_dir = Path("/tmp/mtest-generated-protocol-test")
    completed = subprocess.CompletedProcess([], 0)
    with mock.patch.object(
        protocol_snapshots.subprocess,
        "run",
        return_value=completed,
    ) as run:
        protocol_snapshots.generate_into(output_dir)

    run.assert_called_once_with(
        [
            sys.executable,
            "-m",
            "scripts.gen_transcripts",
            "--out",
            str(output_dir),
        ],
        cwd=protocol_snapshots.REPO_ROOT,
        stdout=subprocess.DEVNULL,
        check=False,
    )


def test_protocol_snapshot_failure_retains_lifecycle_warning() -> None:
    """A failed check explains why maintainers must not bless changed bytes."""
    result = DirectoryComparison(False, (), ("byte mismatch in case.txt",))
    stderr = io.StringIO()
    with mock.patch.object(
        protocol_snapshots,
        "check_snapshots",
        return_value=result,
    ):
        with redirect_stderr(stderr):
            returncode = protocol_snapshots.main()

    message = stderr.getvalue()
    if returncode != 1:
        raise AssertionError(f"failed snapshot check exited {returncode}, want 1")
    for expected in (
        "byte mismatch in case.txt",
        "indicts the change",
        "oracle-side change",
        "pixi run transcripts",
        "Never hand-edit",
    ):
        if expected not in message:
            raise AssertionError(f"lifecycle warning omitted {expected!r}")



def main() -> int:
    """Run the transcript comparator's path-only mutation proof."""
    test_transcript_comparator()
    test_protocol_snapshot_check_mutations()
    test_protocol_snapshot_check_delegates_to_the_generator()
    test_protocol_snapshot_failure_retains_lifecycle_warning()
    print("transcript-comparator: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
