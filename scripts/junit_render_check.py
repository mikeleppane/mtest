#!/usr/bin/env python3
"""Gate mtest's REAL rendered JUnit document through the junit-10 oracle.

`junit_check.py` proves the checker blesses a hand-authored mock; this gate
proves the shipped renderer's OWN output passes it. It builds the tiny
`scripts/junit_emit.mojo` tool against the prebuilt package, runs it to emit a
full `<testsuites>` document that exercises every sentinel-matrix cell (build /
attempts / flaky / rerun-exhausted / retried per-test / non-retried per-test /
not-run / precompile + casualties / suite capture), and runs the schema +
arithmetic + structural checker over that document. It then TAMPERS the root
count and confirms the checker REJECTS it, so a silently-broken gate cannot pass.

Kept separate from the Mojo unit tests on purpose: spawning `python`/`xmllint`
from inside a built Mojo test binary is pathologically slow (the runtime raises
`RLIMIT_NOFILE` to ~1M, so every child's startup crawls), so the oracle runs
here in Python where it is fast and hermetic, while the Mojo unit tests pin the
renderer's structure and the event->fragment mapping directly.
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

from scripts import junit_check


REPO_ROOT = Path(__file__).resolve().parent.parent
EMITTER_SRC = REPO_ROOT / "scripts" / "junit_emit.mojo"
PACKAGE_DIR = REPO_ROOT / "build"


class RenderCheckError(RuntimeError):
    """A build, emit, or oracle-gate failure."""


def _build_emitter(out_binary: Path) -> None:
    """Build the emitter against the prebuilt package, or raise."""
    result = subprocess.run(
        [
            "mojo",
            "build",
            "--no-optimization",
            "-I",
            str(PACKAGE_DIR),
            str(EMITTER_SRC),
            "-o",
            str(out_binary),
        ],
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode != 0:
        raise RenderCheckError(
            f"building {EMITTER_SRC.name} failed:\n{result.stdout}"
        )


def _emit_document(binary: Path) -> str:
    """Run the emitter and return the assembled `<testsuites>` document."""
    result = subprocess.run(
        [str(binary)],
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RenderCheckError(
            f"emitter exited {result.returncode}:\n{result.stderr}"
        )
    if "<testsuites" not in result.stdout:
        raise RenderCheckError(
            f"emitter produced no <testsuites> document:\n{result.stdout!r}"
        )
    return result.stdout


def _accepts(document: str, tmp: Path, name: str) -> None:
    """Write `document` and assert the checker accepts it, or raise."""
    artifact = tmp / name
    artifact.write_text(document, encoding="utf-8")
    junit_check.check_artifact(artifact)


def _rejects(document: str, tmp: Path, name: str) -> None:
    """Write `document` and assert the checker REJECTS it, or raise."""
    artifact = tmp / name
    artifact.write_text(document, encoding="utf-8")
    try:
        junit_check.check_artifact(artifact)
    except junit_check.CheckFailure:
        return
    raise RenderCheckError(
        f"tampered document {name} was accepted; the oracle gate is not live"
    )


def _tamper_root_count(document: str) -> str:
    """Bump the root `tests` count so it disagrees with the summed suites."""
    return re.sub(
        r'(<testsuites\b[^>]*\btests=")(\d+)(")',
        lambda m: f"{m.group(1)}{int(m.group(2)) + 99}{m.group(3)}",
        document,
        count=1,
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="mtest-junit-render-") as raw:
        tmp = Path(raw)
        binary = tmp / "junit_emit"
        try:
            _build_emitter(binary)
            document = _emit_document(binary)
            _accepts(document, tmp, "rendered.xml")
            tampered = _tamper_root_count(document)
            if tampered == document:
                raise RenderCheckError(
                    "could not tamper the root count; the document shape changed"
                )
            _rejects(tampered, tmp, "tampered.xml")
        except (RenderCheckError, junit_check.CheckFailure) as exc:
            print(f"junit-render-check: FAIL: {exc}", file=sys.stderr)
            return 1
    print(
        "junit-render-check: OK: mtest's rendered JUnit document passes the "
        "junit-10 oracle for every sentinel-matrix cell (and a tampered copy is "
        "rejected)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
