#!/usr/bin/env python3
"""Format, lint, and type-check the repository's Python tooling.

Python is build and check tooling here, never product code, so it is not a
pixi dependency and neither are its tools. `uvx` fetches ruff and mypy at the
versions pinned below into its own cache and runs them there, which keeps the
environment the product builds in unchanged. That is also why this check is
absent from `pixi run ci` and from the hosted workflow: `uv` is a developer
tool on the contributor's machine, not something the gate may assume, and a
gate that silently passes when its tool is missing is worse than no gate.

The versions are exact on purpose. A floating formatter reformats the tree on
its next release and every diff after that carries unrelated churn, so the pin
is what makes `--check` mode a stable verdict rather than a moving one.

Two modes:

- `--fix` rewrites files in place: ruff's safe lint fixes, then ruff format.
  This is what `pixi run py-fmt` runs before committing. The order matters and
  is not interchangeable: a lint fix edits code and can leave formatting
  residue behind it, so formatting has to come second or `py-fmt` exits 0 on a
  tree that `py-check` then rejects. Formatting never introduces a finding the
  lint fixer would have removed, so one pass in this order is a fixed point.
- default (check) mode rewrites nothing and fails on any finding: formatting
  drift, a lint finding, or a mypy error. This is what `pixi run py-check`
  runs, and it is the verdict.
"""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]

RUFF_VERSION = "0.16.0"
"""The pinned ruff release. Bumping it can reformat the tree; do that alone."""

MYPY_VERSION = "2.1.0"
"""The pinned mypy release. Bumping it can surface new errors; do that alone."""

RUFF = ("uvx", f"ruff@{RUFF_VERSION}")
MYPY = ("uvx", "--from", f"mypy=={MYPY_VERSION}", "mypy")

TARGETS = ("scripts", "tests/fixtures/exec")
"""Every Python root in the repository. `mypy`'s own set is in pyproject.toml."""


def _run(label: str, command: tuple[str, ...]) -> bool:
    """Run one tool and report whether it passed.

    Args:
        label: The step name to print, matching the tool being run.
        command: The full argv to execute from the repository root.

    Returns:
        True when the tool exited 0.
    """
    print(f"python-quality: {label}: {' '.join(command)}", flush=True)
    completed = subprocess.run(command, cwd=REPO_ROOT, check=False)
    if completed.returncode != 0:
        print(
            f"FATAL: python-quality: {label} failed (exit {completed.returncode})",
            file=sys.stderr,
        )
        return False
    return True


def _missing_uvx() -> str | None:
    """Return an actionable message when `uvx` cannot be found, else None.

    Returns:
        The message to print, or None when `uvx` is on PATH.
    """
    if shutil.which("uvx") is not None:
        return None
    return (
        "FATAL: python-quality: uvx not found on PATH. ruff and mypy run "
        "through uv precisely so they are not pixi dependencies; install uv "
        "(https://docs.astral.sh/uv/) to run this check. It is deliberately "
        "not part of `pixi run ci`, so the rest of the floor is unaffected."
    )


def quality_steps(*, fix: bool) -> tuple[tuple[str, tuple[str, ...]], ...]:
    """Return the ordered (label, argv) steps for one mode.

    Split out from `main` so the step list is checkable without running the
    tools: what matters is that check mode rewrites nothing and still runs
    mypy, that fix mode lints before it formats, and that both modes pin their
    tool versions.

    Args:
        fix: True for the in-place mode, False for the verdict mode.

    Returns:
        The steps in fail-fast order.
    """
    if fix:
        # Lint fixes first. Removing an unused import leaves the blank lines
        # that followed it, which is drift only the formatter collapses, so
        # formatting last is what makes py-fmt's exit 0 mean py-check is green.
        return (
            ("ruff check --fix", (*RUFF, "check", "--fix", *TARGETS)),
            ("ruff format", (*RUFF, "format", *TARGETS)),
        )
    return (
        ("ruff format --check", (*RUFF, "format", "--check", *TARGETS)),
        ("ruff check", (*RUFF, "check", *TARGETS)),
        ("mypy --strict", MYPY),
    )


def main(argv: list[str] | None = None) -> int:
    """Run the Python quality steps in fail-fast order.

    Args:
        argv: Arguments after the module name. `--fix` rewrites files in place;
            anything else is rejected. Defaults to `sys.argv[1:]`.

    Returns:
        0 when every step passed, 1 on any finding, bad usage, or missing uvx.
    """
    arguments = sys.argv[1:] if argv is None else argv
    fix = arguments == ["--fix"]
    if arguments and not fix:
        print(
            f"FATAL: python-quality: unexpected arguments {arguments!r}; "
            "the only accepted flag is --fix",
            file=sys.stderr,
        )
        return 1

    unavailable = _missing_uvx()
    if unavailable is not None:
        print(unavailable, file=sys.stderr)
        return 1

    for label, command in quality_steps(fix=fix):
        if not _run(label, command):
            return 1

    print(
        "python-quality: OK -- "
        + ("rewrote in place" if fix else "format, lint, and types clean")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
