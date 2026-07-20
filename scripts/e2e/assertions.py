"""Shared exact parsers and assertions for E2E scenarios."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from scripts.e2e.runner import Run, ScenarioError


SUMMARY_RE = re.compile(
    r"=====\s+(?P<passed>\d+) passed,\s+(?P<failed>\d+) failed,\s+"
    r"(?P<skipped>\d+) skipped"
    r"(?:,\s+(?P<crashed>\d+) crashed)?"
    r"(?:,\s+(?P<timed_out>\d+) timed out)?"
    r"(?:,\s+(?P<compile_error>\d+) compile error)?"
    r"(?:,\s+(?P<malformed>\d+) malformed suite)?"
    r"[^(]*"
    r"\((?P<excluded>\d+) excluded,\s+(?P<not_run>\d+) not run"
    r"(?:,\s+(?P<deselected>\d+) deselected)?\)"
    r"\s+in\s+(?P<seconds>[\d.]+)s\s+====="
)
HEADER_RE = re.compile(r"root:\s+.*?selected:\s+(\d+) files\s+excluded:\s+(\d+)")

VERDICT_TO_BUCKET = {
    "PASS": "passed",
    "FAIL": "failed",
    "CRASH": "crashed",
    "TIMEOUT": "timed_out",
    "COMPILE-ERROR": "compile_error",
}
VERDICT_LINE_TOKENS = list(VERDICT_TO_BUCKET) + ["NO-TESTS"]
VERDICT_LINE_RE = re.compile(
    r"^(?:" + "|".join(re.escape(token) for token in VERDICT_LINE_TOKENS) + r")\s+(\S+)",
    re.MULTILINE,
)


@dataclass
class Summary:
    """Parsed totals from one console summary band."""

    passed: int
    failed: int
    skipped: int
    crashed: int
    timed_out: int
    compile_error: int
    malformed: int
    excluded: int
    not_run: int
    seconds: float
    deselected: int = 0


def verdict_paths_in_order(run: Run) -> list[str]:
    """Return verdict paths in stdout order."""
    return VERDICT_LINE_RE.findall(run.stdout)


def summary(run: Run) -> Summary:
    """Parse the exact summary band from a captured run."""
    match = SUMMARY_RE.search(run.combined)
    if not match:
        raise ScenarioError(f"no summary band in output for {run.argv}\n{run.combined}")
    groups = match.groupdict()

    def number(key: str) -> int:
        return int(groups[key]) if groups.get(key) is not None else 0

    return Summary(
        passed=number("passed"),
        failed=number("failed"),
        skipped=number("skipped"),
        crashed=number("crashed"),
        timed_out=number("timed_out"),
        compile_error=number("compile_error"),
        malformed=number("malformed"),
        excluded=number("excluded"),
        not_run=number("not_run"),
        deselected=number("deselected"),
        seconds=float(groups["seconds"]),
    )


def header(run: Run) -> tuple[int, int]:
    """Parse selected and excluded file counts from the header band."""
    match = HEADER_RE.search(run.combined)
    if not match:
        raise ScenarioError(f"no header band in output for {run.argv}\n{run.combined}")
    return int(match.group(1)), int(match.group(2))


def verdict_line(run: Run, token: str, path: str) -> str | None:
    """Return the first verdict line beginning with ``token`` and naming path."""
    for line in run.stdout.splitlines():
        if line.startswith(token) and path in line:
            return line
    return None


def expect(condition: bool, message: str) -> None:
    """Raise the expected scenario failure when an exact property is false."""
    if not condition:
        raise ScenarioError(message)


def expect_exit(run: Run, code: int) -> None:
    """Assert one exact process exit code with both streams on failure."""
    expect(
        run.returncode == code,
        f"expected exit {code}, got {run.returncode} for {run.argv}\n"
        f"--- stdout ---\n{run.stdout}\n--- stderr ---\n{run.stderr}",
    )


def expect_report(run: Run, path: str | Path, what: str) -> Path:
    """Assert a report exists before its format-specific oracle reads it."""
    report = Path(path)
    expect(
        report.exists(),
        f"{what} was never written to {report}: {run.argv} exited "
        f"{run.returncode} and produced no report\n"
        f"--- stdout ---\n{run.stdout}\n--- stderr ---\n{run.stderr}",
    )
    return report


def expect_accounting(run: Run) -> Summary:
    """Reconcile the summary and header excluded-file counts."""
    parsed_summary = summary(run)
    _selected, header_excluded = header(run)
    expect(
        parsed_summary.excluded == header_excluded,
        f"excluded mismatch: summary {parsed_summary.excluded} vs header "
        f"{header_excluded} for {run.argv}",
    )
    return parsed_summary
