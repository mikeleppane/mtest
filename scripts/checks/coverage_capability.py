#!/usr/bin/env python3
"""Fail closed when the pinned Mojo toolchain grows a source-coverage facility.

mtest has no line or branch coverage number, because Mojo 1.0.0b2 ships no
coverage instrumentation: neither ``mojo build --help`` nor ``mojo --help``
mentions a coverage, profile, or instrumentation flag. Release confidence
therefore rests on the behavioral and mutation oracles catalogued in
``notes/test-confidence-map.md``.

That limitation is only honest while it is still true, so this probe is a gate
rather than a report. The ASYMMETRY is the point: an absent facility is the
quiet, passing outcome, and *discovering* a facility is the failure. A
toolchain upgrade cannot silently start emitting an unreviewed percentage —
somebody has to read the new flags and decide, in a commit, whether mtest gates
on them.

Four outcomes, three of them nonzero:

* the recorded probe finds nothing        -> print the pinned message, exit 0;
* coverage-shaped flags are discovered    -> echo them, exit nonzero;
* coverage-shaped prose is discovered     -> echo the lines, exit nonzero;
* the pin drifted or the probe failed     -> say why, exit nonzero.

Usage: ``pixi run coverage-capability``.
"""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys
import tomllib


REPO_ROOT = Path(__file__).resolve().parents[2]

# The toolchain this probe's recorded result belongs to. `check_version_pin`
# refuses to run against any other pin, so the pinned message below cannot
# outlive the version it names.
PINNED_MOJO_VERSION = "1.0.0b2"

# The exact commands recorded in notes/test-confidence-map.md. They are argv
# lists, never a shell string: no product or test oracle in this repo invokes
# `/bin/sh -c`.
PROBE_COMMANDS: tuple[tuple[str, ...], ...] = (
    ("mojo", "build", "--help"),
    ("mojo", "--help"),
)
PROBE_TIMEOUT_SECONDS = 60

# The same needles the recorded `rg -i 'cover|profile|instrument'` probe uses.
RELEVANT_WORDS: tuple[str, ...] = ("cover", "profile", "instrument")
_FLAG = re.compile(r"--[A-Za-z0-9][A-Za-z0-9-]*")

UNAVAILABLE_MESSAGE = (
    f"Mojo source coverage unavailable at {PINNED_MOJO_VERSION}; "
    "behavioral map applies"
)
DISCOVERY_INSTRUCTION = (
    "Evaluate each item above and gate it explicitly before this task can pass "
    "again: either wire the facility into a blocking check with a reviewed "
    "threshold, or record in notes/test-confidence-map.md why it is rejected. "
    "Do not publish a coverage number that no gate enforces."
)


class ProbeError(Exception):
    """The capability probe could not be carried out as recorded."""


def check_version_pin(repo_root: Path = REPO_ROOT) -> None:
    """Require pixi.toml to still pin the Mojo version this probe describes.

    Args:
        repo_root: Directory holding the ``pixi.toml`` manifest to read.

    Raises:
        ProbeError: The manifest is unreadable, or its `mojo` dependency no
            longer pins `PINNED_MOJO_VERSION` exactly. Both are failures: the
            unavailable message names a version, so it must not be printed for
            a toolchain nobody probed.
    """
    manifest_path = repo_root / "pixi.toml"
    try:
        with manifest_path.open("rb") as manifest:
            dependencies = tomllib.load(manifest)["dependencies"]
    except (OSError, KeyError, tomllib.TOMLDecodeError) as exc:
        raise ProbeError(f"cannot read {manifest_path} dependencies: {exc}") from exc
    spec = dependencies.get("mojo")
    if not isinstance(spec, str):
        raise ProbeError(f"{manifest_path} declares no string `mojo` dependency")
    if f"=={PINNED_MOJO_VERSION}" not in [part.strip() for part in spec.split(",")]:
        raise ProbeError(
            f"the toolchain pin moved to {spec!r}, but this probe's recorded "
            f"result covers =={PINNED_MOJO_VERSION}. Re-run the probe against "
            "the new toolchain, update PINNED_MOJO_VERSION and "
            "notes/test-confidence-map.md together, and only then let this "
            "task pass."
        )


def discover_coverage_flags(help_text: str) -> tuple[str, ...]:
    """Return every coverage-shaped command-line flag named in one help text.

    Args:
        help_text: Combined stdout and stderr from one ``--help`` invocation.

    Returns:
        The distinct ``--flag`` spellings whose own name contains `cover`,
        `profile`, or `instrument`, in first-seen order. Empty when the
        toolchain names no such flag.
    """
    found: list[str] = []
    for match in _FLAG.finditer(help_text):
        flag = match.group(0)
        name = flag.lower()
        if any(word in name for word in RELEVANT_WORDS) and flag not in found:
            found.append(flag)
    return tuple(found)


def relevant_lines(help_text: str) -> tuple[str, ...]:
    """Return the lines the recorded ripgrep probe would have matched.

    A coverage facility does not have to be spelled as a flag — it could arrive
    as a subcommand or an environment variable — so the gate also fails on a
    bare mention. Flags are reported preferentially because they are the
    actionable form; these lines are the fallback that keeps the gate closed.

    Args:
        help_text: Combined stdout and stderr from one ``--help`` invocation.

    Returns:
        Every stripped, non-empty line containing `cover`, `profile`, or
        `instrument` case-insensitively, in file order.
    """
    matched: list[str] = []
    for line in help_text.splitlines():
        lowered = line.lower()
        if any(word in lowered for word in RELEVANT_WORDS) and line.strip():
            matched.append(line.strip())
    return tuple(matched)


def collect_help_text(
    commands: tuple[tuple[str, ...], ...] = PROBE_COMMANDS,
) -> tuple[tuple[tuple[str, ...], str], ...]:
    """Run each recorded help command and return its combined output.

    Args:
        commands: The argv lists to execute, each without a shell.

    Returns:
        One ``(argv, combined output)`` pair per command, in the given order.

    Raises:
        ProbeError: A command was missing, timed out, or exited nonzero. The
            probe's whole claim is "we looked and found nothing", so being
            unable to look is a failure, never an absence.
    """
    reports: list[tuple[tuple[str, ...], str]] = []
    for argv in commands:
        try:
            run = subprocess.run(
                list(argv),
                cwd=REPO_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=PROBE_TIMEOUT_SECONDS,
                check=False,
            )
        except FileNotFoundError as exc:
            raise ProbeError(f"{' '.join(argv)}: executable not found") from exc
        except subprocess.TimeoutExpired as exc:
            raise ProbeError(
                f"{' '.join(argv)}: exceeded {PROBE_TIMEOUT_SECONDS} seconds"
            ) from exc
        if run.returncode != 0:
            raise ProbeError(f"{' '.join(argv)}: exited {run.returncode}")
        combined = run.stdout.decode("utf-8", errors="replace") + run.stderr.decode(
            "utf-8", errors="replace"
        )
        reports.append((tuple(argv), combined))
    return tuple(reports)


def evaluate(
    reports: tuple[tuple[tuple[str, ...], str], ...],
) -> tuple[str, int]:
    """Turn probe output into the message to print and the exit status to use.

    Args:
        reports: ``(argv, combined output)`` pairs from `collect_help_text`.

    Returns:
        A ``(message, exit code)`` pair. The code is ``0`` only when no command
        named anything coverage-shaped; any discovery returns a nonzero code so
        the task fails until a human gates the facility.
    """
    discovered: list[str] = []
    for argv, text in reports:
        label = " ".join(argv)
        flags = discover_coverage_flags(text)
        if flags:
            discovered.extend(f"  {label}: {flag}" for flag in flags)
            continue
        discovered.extend(f"  {label}: {line}" for line in relevant_lines(text))
    if not discovered:
        return UNAVAILABLE_MESSAGE, 0
    body = "\n".join(discovered)
    return (
        "coverage-capability: FAIL: the pinned Mojo toolchain now names a "
        f"coverage facility:\n{body}\n{DISCOVERY_INSTRUCTION}",
        1,
    )


def main() -> int:
    """Run the recorded probe and report the capability verdict.

    Returns:
        ``0`` when the toolchain still exposes no coverage facility, and a
        nonzero status for every other outcome, including an unrunnable probe
        and a drifted toolchain pin.
    """
    try:
        check_version_pin()
        reports = collect_help_text()
    except ProbeError as exc:
        print(f"coverage-capability: FAIL: {exc}", file=sys.stderr)
        return 1
    message, code = evaluate(reports)
    print(message, file=sys.stderr if code else sys.stdout)
    return code


if __name__ == "__main__":
    sys.exit(main())
