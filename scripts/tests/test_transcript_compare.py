#!/usr/bin/env python3
"""Focused mutation tests for byte-exact transcript comparison."""

from __future__ import annotations

from pathlib import Path
import tempfile

from scripts.transcript_compare import compare_directories


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



def main() -> int:
    """Run the transcript comparator's path-only mutation proof."""
    test_transcript_comparator()
    print("transcript-comparator: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
