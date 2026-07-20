#!/usr/bin/env python3
"""Capture the mtest console's real ANSI/color output under a PTY.

This is a DOCUMENTATION tool, not a gate. It drives the already-built
`build/mtest` binary against tiny throwaway suites with stdout+stderr attached to
a real pseudo-terminal, so `--color auto` resolves exactly as it does for a human
at an interactive terminal, and records the raw bytes (ANSI escapes included)
into `notes/console-captures/`. The committed captures are a faithful picture of
what the console looks like for representative runs; they are deliberately NOT
wired into any oracle or CI check, so an incidental byte (a timing, a token) never
freezes a gate.

Regenerate with `python -m scripts.maintenance.pty_capture` after building the
binary (`pixi run build-bin`). Each scenario writes `<name>.ansi` (raw, view with
`cat`/`less -R`) next to this module's output directory. Turning a capture into a
PNG screenshot for docs is an OPTIONAL maintainer step (e.g. pipe a capture
through a terminal-to-image tool); this script only produces the text captures.
"""

from __future__ import annotations

import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time


REPO_ROOT = Path(__file__).resolve().parents[2]
MTEST = REPO_ROOT / "build" / "mtest"
OUTPUT_DIR = REPO_ROOT / "notes" / "console-captures"
RUN_TIMEOUT = 120.0

# The ephemeral throwaway suite root is rewritten to this stable, neutral
# placeholder in every capture so no machine-specific temp path is ever
# committed. It contains none of the run-varying bytes (no TMPDIR, no mkdtemp
# suffix), so captures are reproducible regardless of where they were generated.
_ROOT_PLACEHOLDER = b"<suite-root>"

# Two self-contained suites the binary compiles with the real toolchain. Kept
# inline so a capture never depends on an e2e fixture that may change under it.
_PASSING_SUITE = '''\
"""Capture fixture: an all-passing suite (three passing tests)."""
from std.testing import assert_equal, TestSuite


def test_addition_holds() raises:
    assert_equal(2 + 2, 4)


def test_identity_holds() raises:
    assert_equal("mtest", "mtest")


def test_ordering_holds() raises:
    assert_equal(1 < 2, True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
'''

_FAILING_SUITE = '''\
"""Capture fixture: one assertion fails, so the file reports FAIL."""
from std.testing import assert_equal, TestSuite


def test_first_passes() raises:
    assert_equal(1, 1)


def test_second_fails() raises:
    assert_equal(2 + 2, 5)


def test_third_passes() raises:
    assert_equal(3, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
'''


class CaptureError(RuntimeError):
    """A build-missing or runner-hang failure while capturing."""


def _kill_group(proc: subprocess.Popen) -> None:
    """Kill the runner's whole process group so a hang cannot wedge the tool."""
    try:
        pgid = os.getpgid(proc.pid)
    except ProcessLookupError:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            return
        time.sleep(0.1)


def capture_under_pty(
    args: list[str],
    *,
    cwd: Path,
    env_overrides: dict[str, str] | None = None,
    timeout: float = RUN_TIMEOUT,
) -> tuple[int, bytes]:
    """Run `build/mtest args` with stdout+stderr on a real pty; return raw bytes.

    A real pty makes `stdout_isatty()` true, so `--color auto` engages exactly as
    it does for an interactive human. The whole group is hard-timeout guarded.
    """
    argv = [str(MTEST), *args]
    env = dict(os.environ)
    # A capture is not a CI-detection scenario: keep the console's Actions-only
    # stop-commands fencing out of the picture unless a scenario opts in.
    env["GITHUB_ACTIONS"] = ""
    if env_overrides:
        env.update(env_overrides)
    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        argv,
        cwd=str(cwd),
        stdout=slave_fd,
        stderr=slave_fd,
        env=env,
        start_new_session=True,
    )
    os.close(slave_fd)
    out = bytearray()
    deadline = time.monotonic() + timeout
    timed_out = False
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            ready, _, _ = select.select([master_fd], [], [], remaining)
            if not ready:
                continue
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                break  # child closed the pty: EOF
            if not chunk:
                break
            out += chunk
    finally:
        os.close(master_fd)
    if timed_out:
        _kill_group(proc)
        proc.wait(timeout=5)
        raise CaptureError(f"mtest did not return within {timeout:.0f}s for {argv}")
    returncode = proc.wait(timeout=5)
    return returncode, bytes(out)


def _write_tree(root: Path, files: dict[str, str]) -> None:
    """Materialize a throwaway suite under `root`."""
    for name, source in files.items():
        (root / name).write_text(source, encoding="utf-8")


def main() -> int:
    """Capture every scenario into notes/console-captures/."""
    if not MTEST.exists():
        print(
            f"pty-capture: FAIL: binary not found at {MTEST}; run `pixi run build-bin`",
            file=sys.stderr,
        )
        return 1
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="mtest-capture-") as raw:
        base = Path(raw)
        pass_tree = base / "passing"
        fail_tree = base / "failing"
        pass_tree.mkdir()
        fail_tree.mkdir()
        _write_tree(pass_tree, {"test_passing.mojo": _PASSING_SUITE})
        _write_tree(
            fail_tree,
            {
                "test_passing.mojo": _PASSING_SUITE,
                "test_failing.mojo": _FAILING_SUITE,
            },
        )

        # (name, argv, cwd, env_overrides) — cwd is the run root, so the binary
        # renders clean root-relative paths and `--color auto` sees the pty.
        scenarios: list[tuple[str, list[str], Path, dict[str, str] | None]] = [
            ("pass-pty", ["."], pass_tree, None),
            ("fail-pty", ["."], fail_tree, None),
            ("fail-verbose-pty", ["-v", "."], fail_tree, None),
            ("fail-quiet-pty", ["-q", "."], fail_tree, None),
            # Same failing run on the SAME pty, but NO_COLOR set: `--color auto`
            # must drop every escape even though stdout is a terminal.
            ("fail-nocolor-pty", ["."], fail_tree, {"NO_COLOR": "1"}),
        ]

        # Every absolute path in a capture points inside the throwaway `base`
        # (its `mkdtemp` name and the ambient TMPDIR both vary per run and per
        # machine). Rewrite that ephemeral root to a stable, neutral placeholder
        # BEFORE writing, so a capture is deterministic and never bakes in a
        # machine-specific sandbox path. Both the literal and the symlink-resolved
        # spellings are covered (the child's `cwd()` may canonicalize).
        roots = {str(base), os.path.realpath(base)}

        def _sanitize(raw: bytes) -> bytes:
            clean = raw
            for root in sorted(roots, key=len, reverse=True):
                clean = clean.replace(root.encode("utf-8"), _ROOT_PLACEHOLDER)
            return clean

        results: list[tuple[str, int, int]] = []
        for name, args, cwd, overrides in scenarios:
            code, raw_bytes = capture_under_pty(args, cwd=cwd, env_overrides=overrides)
            clean_bytes = _sanitize(raw_bytes)
            dest = OUTPUT_DIR / f"{name}.ansi"
            dest.write_bytes(clean_bytes)
            results.append((name, code, len(clean_bytes)))
            print(f"pty-capture: wrote {dest.relative_to(REPO_ROOT)} (exit {code}, {len(clean_bytes)} bytes)")

    print("pty-capture: OK -- " + ", ".join(n for n, _, _ in results))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CaptureError as error:
        print(f"pty-capture: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
