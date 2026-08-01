#!/usr/bin/env python3
"""Build the documentation site from a pinned mkdocs.

mkdocs is a documentation tool, not something the product compiles against, so
neither it nor its theme is a pixi dependency. `uvx` fetches both at the
versions pinned below into its own cache and runs them there, leaving the
environment the product builds in untouched. That is the same arrangement
`scripts/checks/python_quality.py` uses for ruff and mypy, and it is here for
the same reason.

The versions are exact so the published site is a property of the tree rather
than of the day. mkdocs and its theme both render markup and emit HTML, so a
floating version can change every page in the site on its own release schedule,
with no diff in this repository to explain it.

The cost is the same prerequisite `pixi run py-check` already has: `uv` on
PATH. This module fails loudly and names the remedy when `uvx` is absent rather
than skipping, which is why the task is absent from `pixi run ci`: a floor
member that assumes a tool the pixi environment does not pin is green or red by
accident of the machine. A gate may run this build exactly when it supplies the
tool itself.

The build is `--strict`, so a broken internal link or any other mkdocs warning
fails it. A documentation gate that publishes a page with a dead cross-reference
and says nothing is not a gate.

`mkdocs.yml` owns where the output goes (`build/site`, which `.gitignore`
already covers). `build` takes a `site_dir` override for a caller that needs the
output somewhere else, and passing nothing leaves that decision in the one place
it is configured.
"""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]

MKDOCS_VERSION = "1.6.1"
"""The exact mkdocs release. It renders every page; bump it alone."""

MKDOCS_MATERIAL_VERSION = "9.6.14"
"""The exact theme release. It restyles every page; bump it alone."""

MKDOCS = (
    "uvx",
    "--from",
    f"mkdocs=={MKDOCS_VERSION}",
    "--with",
    f"mkdocs-material=={MKDOCS_MATERIAL_VERSION}",
    "mkdocs",
)
"""The pinned interpreter-free `mkdocs` entry point.

`mkdocs` is the `--from` package because it owns the executable of that name;
resolving the theme through `--with` instead pins both without asking uv for a
console script the theme does not provide.
"""

UVX_REMEDY = (
    "FATAL: docs-build: uvx not found on PATH. mkdocs runs through uv "
    "precisely so it is not a pixi dependency; install uv "
    "(https://docs.astral.sh/uv/) to build the documentation site. It is "
    "deliberately not part of `pixi run ci`, so the rest of the floor is "
    "unaffected."
)
"""What to print when the build cannot start because `uv` is not installed."""


class SiteBuildError(RuntimeError):
    """The documentation site could not be built.

    Raised for a missing `uvx` and for a nonzero mkdocs exit alike, so one
    `except` covers every way this build fails.
    """


def build_command(site_dir: Path | None = None, strict: bool = True) -> tuple[str, ...]:
    """Return the full argv that builds the site.

    Split out from `build` so the pins and the strictness flag are testable
    without fetching mkdocs or writing a site.

    Args:
        site_dir: Output directory, resolved by mkdocs against the repository
            root. None leaves `mkdocs.yml`'s `site_dir` in charge.
        strict: True fails the build on any mkdocs warning, a broken internal
            link included.

    Returns:
        The argv to execute from the repository root.
    """
    command: tuple[str, ...] = (*MKDOCS, "build")
    if strict:
        command = (*command, "--strict")
    if site_dir is not None:
        command = (*command, "--site-dir", str(site_dir))
    return command


def missing_uvx() -> str | None:
    """Return an actionable message when `uvx` cannot be found, else None.

    Returns:
        The message to print, or None when `uvx` is on PATH.
    """
    if shutil.which("uvx") is not None:
        return None
    return UVX_REMEDY


def build(site_dir: Path | None = None, strict: bool = True) -> None:
    """Build the documentation site with the pinned mkdocs.

    mkdocs' own output goes straight to this process's stdout and stderr, so a
    caller reads the real diagnosis rather than a summary of it.

    Args:
        site_dir: Output directory, resolved by mkdocs against the repository
            root. None leaves `mkdocs.yml`'s `site_dir` in charge, which is
            where the location belongs.
        strict: True fails the build on any mkdocs warning, a broken internal
            link included. Defaults to True; pass False only to inspect a
            failing site locally.

    Raises:
        SiteBuildError: `uvx` is not on PATH, or mkdocs exited nonzero.
    """
    unavailable = missing_uvx()
    if unavailable is not None:
        raise SiteBuildError(unavailable)
    command = build_command(site_dir=site_dir, strict=strict)
    print(f"docs-build: {' '.join(command)}", flush=True)
    completed = subprocess.run(command, cwd=REPO_ROOT, check=False)
    if completed.returncode != 0:
        raise SiteBuildError(
            f"FATAL: docs-build: mkdocs failed (exit {completed.returncode})"
        )


def main(argv: list[str] | None = None) -> int:
    """Build the site and report a shell exit status.

    Args:
        argv: Arguments after the module name. None are accepted: the output
            location is `mkdocs.yml`'s to decide and the build is always
            strict. Defaults to `sys.argv[1:]`.

    Returns:
        0 when the site built, 1 on bad usage, a missing `uvx`, or an mkdocs
        failure.
    """
    arguments = sys.argv[1:] if argv is None else argv
    if arguments:
        print(
            f"FATAL: docs-build: unexpected arguments {arguments!r}; this "
            "build takes none, because mkdocs.yml owns the output location "
            "and the build is always strict",
            file=sys.stderr,
        )
        return 1

    try:
        build()
    except SiteBuildError as error:
        print(str(error), file=sys.stderr)
        return 1

    print("docs-build: OK -- the documentation site built strict")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
