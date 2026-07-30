#!/usr/bin/env python3
"""Parse the strict production host-profile inventory."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING


if TYPE_CHECKING:
    from collections.abc import Iterable


ROOT = Path(__file__).resolve().parents[2]
PROFILES_FILE = ROOT / "scripts" / "build" / "production_profiles.txt"
_SINGLETON_KEYS = frozenset(
    {
        "system",
        "machine",
        "mojo_cpu",
        "mojo_triple",
        "deployment_target",
    }
)
_REQUIRED_KEYS = frozenset({"system", "machine", "mojo_cpu"})
_KNOWN_KEYS = _SINGLETON_KEYS | {"c_flag"}


@dataclass(frozen=True)
class ProductionProfile:
    """One supported production host and its exact compiler selections."""

    name: str
    system: str
    machine: str
    mojo_cpu: str
    mojo_triple: str | None
    c_flags: tuple[str, ...]
    deployment_target: str | None


def _fail(path: Path, line: int, message: str) -> None:
    raise SystemExit(f"production-profiles: {path}:{line}: {message}")


def load_profiles(path: Path = PROFILES_FILE) -> tuple[ProductionProfile, ...]:
    """Parse every production profile from ``path``.

    Raises:
        SystemExit: If the inventory is empty, malformed, ambiguous, or
            incomplete.
    """
    profiles: list[ProductionProfile] = []
    names: set[str] = set()
    platforms: set[tuple[str, str]] = set()
    current_name: str | None = None
    current_line = 0
    scalars: dict[str, str] = {}
    c_flags: list[str] = []

    def finish_profile() -> None:
        nonlocal current_name, current_line, scalars, c_flags
        if current_name is None:
            return
        missing = sorted(_REQUIRED_KEYS - scalars.keys())
        if not c_flags:
            missing.append("c_flag")
        if missing:
            _fail(
                path,
                current_line,
                f"profile '{current_name}' missing required key(s): "
                + ", ".join(missing),
            )
        platform = (scalars["system"], scalars["machine"])
        if platform in platforms:
            _fail(
                path,
                current_line,
                f"duplicate production platform {platform[0]}/{platform[1]}",
            )
        platforms.add(platform)
        profiles.append(
            ProductionProfile(
                name=current_name,
                system=platform[0],
                machine=platform[1],
                mojo_cpu=scalars["mojo_cpu"],
                mojo_triple=scalars.get("mojo_triple"),
                c_flags=tuple(c_flags),
                deployment_target=scalars.get("deployment_target"),
            )
        )
        current_name = None
        current_line = 0
        scalars = {}
        c_flags = []

    text = ""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        _fail(path, 1, f"cannot read profile inventory: {exc}")
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            if not line.endswith("]") or line.count("[") != 1 or line.count("]") != 1:
                _fail(path, line_number, "malformed profile section")
            name = line[1:-1].strip()
            if not name:
                _fail(path, line_number, "empty profile section")
            finish_profile()
            if name in names:
                _fail(path, line_number, f"duplicate profile section '{name}'")
            names.add(name)
            current_name = name
            current_line = line_number
            continue
        if current_name is None:
            _fail(path, line_number, "key before profile section")
        if "=" not in line:
            _fail(path, line_number, "malformed profile row")
        key, value = (part.strip() for part in line.split("=", 1))
        if key not in _KNOWN_KEYS:
            _fail(path, line_number, f"unknown key '{key}'")
        if not value:
            _fail(path, line_number, f"empty value for '{key}'")
        if key == "c_flag":
            c_flags.append(value)
        else:
            if key in scalars:
                _fail(path, line_number, f"duplicate key '{key}'")
            scalars[key] = value

    finish_profile()
    if not profiles:
        _fail(path, 1, "profile inventory is empty")
    return tuple(profiles)


def host_profile(
    *,
    system: str,
    machine: str,
    profiles: Iterable[ProductionProfile],
) -> ProductionProfile:
    """Return the unique production profile matching ``system`` and ``machine``.

    Raises:
        SystemExit: If the requested host is unsupported or ambiguous.
    """
    matches = tuple(
        profile
        for profile in profiles
        if profile.system == system and profile.machine == machine
    )
    if len(matches) != 1:
        if not matches:
            raise SystemExit(
                f"production-profiles: unsupported production host {system}/{machine}"
            )
        raise SystemExit(
            f"production-profiles: duplicate production host {system}/{machine}"
        )
    return matches[0]
