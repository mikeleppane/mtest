#!/usr/bin/env python3
"""Render real mtest console runs into the SVG images embedded in README.md.

This is a DOCUMENTATION tool, not a gate. It drives the already-built
`build/mtest` binary against committed `e2e/` fixtures with stdout attached to a
real pseudo-terminal, so `--color auto` resolves ON exactly as it does for a
human at an interactive terminal, then converts the raw ANSI byte stream into a
self-contained SVG under `docs/assets/`. The committed images are a faithful
picture of real runs; they are deliberately NOT wired into any oracle or CI
check, so an incidental byte (a wall-clock timing) never freezes a gate.

Each scenario still pins its expected exit code and a few required output
markers, and a capture is published only after both hold, so a broken binary,
a missing `mojo`, or an internal error can never silently replace a README
image with an error card. `NO_COLOR` and `GITHUB_ACTIONS` are scrubbed from
the child environment so inherited settings cannot strip the colors or append
an annotation tail.

Regenerate with `python -m scripts.maintenance.console_svg` after building the
binary (`pixi run build-bin`), under `pixi run` so the spawned `mojo build`
children resolve. Wall-clock timings and the absolute repo root in the captured
output reflect the generating run and machine; that residual variance is
expected and is exactly why these are documentation, not wired into any check.
"""

from __future__ import annotations

import os
import pty
import re
import select
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MTEST = REPO_ROOT / "build" / "mtest"
OUTPUT_DIR = REPO_ROOT / "docs" / "assets"
RUN_TIMEOUT = 180.0

# GitHub dark-palette terminal card.
BG = "#0d1117"
BORDER = "#30363d"
FG = "#c9d1d9"
PROMPT = "#8b949e"
SGR_COLORS = {"31": "#ff7b72", "32": "#3fb950", "33": "#d29922"}

FONT = "ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace"
FONT_SIZE = 13
CHAR_W = 7.85
LINE_H = 20
PAD = 18

SGR_RE = re.compile(r"\x1b\[([0-9;]*)m")


@dataclass(frozen=True)
class Scenario:
    """One README image: display command, real argv, and its validity pins."""

    name: str
    display: str
    argv: tuple[str, ...]
    expected_exit: int
    require: tuple[str, ...]
    reset: tuple[str, ...] = field(default=())


SCENARIOS = (
    Scenario(
        name="mtest-run",
        display="mtest e2e/matrix e2e/suite/test_failing.mojo",
        argv=(str(MTEST), "e2e/matrix", "e2e/suite/test_failing.mojo"),
        expected_exit=1,
        require=("PASS", "FAIL", "reproduce: ", "====="),
    ),
    Scenario(
        name="mtest-flaky",
        display="mtest e2e/flaky/test_flaky.mojo --retries 1",
        argv=(str(MTEST), "e2e/flaky/test_flaky.mojo", "--retries", "1"),
        expected_exit=0,
        require=("TRY", "FLAKY", "====="),
        reset=("build/e2e-scratch/flaky_marker",),
    ),
)


def capture_pty(argv: tuple[str, ...]) -> tuple[bytes, int]:
    """Run argv on a PTY under a total deadline; return (bytes, exit code)."""
    env = dict(os.environ)
    env.pop("NO_COLOR", None)
    env.pop("GITHUB_ACTIONS", None)
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        argv,
        cwd=REPO_ROOT,
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave)
    deadline = time.monotonic() + RUN_TIMEOUT
    chunks: list[bytes] = []
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                raise RuntimeError(f"capture exceeded {RUN_TIMEOUT}s: {argv}")
            ready, _, _ = select.select([master], [], [], remaining)
            if not ready:
                continue
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            chunks.append(data)
    finally:
        os.close(master)
        returncode = proc.wait()
    return b"".join(chunks), returncode


def _xml_escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _line_segments(line: str) -> list[tuple[str, str]]:
    """Split one console line into (color, text) segments by its SGR codes."""
    segments: list[tuple[str, str]] = []
    color = FG
    pos = 0
    for match in SGR_RE.finditer(line):
        if match.start() > pos:
            segments.append((color, line[pos : match.start()]))
        codes = match.group(1).split(";")
        if "0" in codes or match.group(1) == "":
            color = FG
        for code in codes:
            if code in SGR_COLORS:
                color = SGR_COLORS[code]
            elif code not in ("", "0"):
                print(
                    f"console-svg: warning: unmapped SGR code {code!r} rendered"
                    " as plain foreground",
                    file=sys.stderr,
                )
        pos = match.end()
    if pos < len(line):
        segments.append((color, line[pos:]))
    return segments


def ansi_to_svg(raw: bytes, display_command: str) -> str:
    """Convert a captured ANSI byte stream into a terminal-card SVG."""
    text = raw.decode("utf-8").replace("\r\n", "\n").rstrip("\n")
    lines = [f"\x1b[0m$ {display_command}", *text.split("\n")]
    plain_lengths = [len(SGR_RE.sub("", line)) for line in lines]
    width = round(PAD * 2 + max(plain_lengths) * CHAR_W)
    height = PAD * 2 + len(lines) * LINE_H
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}"'
        f' font-family="{FONT}" font-size="{FONT_SIZE}">',
        f'<rect width="{width}" height="{height}" rx="8" fill="{BG}"'
        f' stroke="{BORDER}"/>',
    ]
    for index, line in enumerate(lines):
        y = PAD + LINE_H * index + FONT_SIZE
        spans = ""
        for color, segment in _line_segments(line):
            if index == 0 and segment.startswith("$ "):
                spans += f'<tspan fill="{PROMPT}">$ </tspan>'
                segment = segment[2:]
            spans += f'<tspan fill="{color}">{_xml_escape(segment)}</tspan>'
        if spans:
            parts.append(f'<text x="{PAD}" y="{y}" xml:space="preserve">{spans}</text>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main() -> int:
    if not MTEST.is_file():
        print(f"console-svg: missing {MTEST}; run `pixi run build-bin` first")
        return 1
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for scenario in SCENARIOS:
        for reset in scenario.reset:
            (REPO_ROOT / reset).unlink(missing_ok=True)
        raw, returncode = capture_pty(scenario.argv)
        text = raw.decode("utf-8", "replace")
        if returncode != scenario.expected_exit:
            print(
                f"console-svg: {scenario.name}: exit {returncode}, expected"
                f" {scenario.expected_exit}; nothing written. Captured:\n{text}",
                file=sys.stderr,
            )
            return 1
        missing = [marker for marker in scenario.require if marker not in text]
        if missing:
            print(
                f"console-svg: {scenario.name}: capture lacks expected"
                f" markers {missing}; nothing written. Captured:\n{text}",
                file=sys.stderr,
            )
            return 1
        svg = ansi_to_svg(raw, scenario.display)
        target = OUTPUT_DIR / f"{scenario.name}.svg"
        target.write_text(svg, encoding="utf-8")
        print(f"console-svg: wrote {target.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
