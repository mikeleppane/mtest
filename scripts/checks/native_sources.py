#!/usr/bin/env python3
"""Provide one tracked, safe inventory for native quality checks."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
from typing import TYPE_CHECKING


if TYPE_CHECKING:
    from collections.abc import Iterable


NATIVE_DIRS = ("native", "tests/native")
SOURCE_SUFFIXES = frozenset({".c", ".h"})


def tracked_native_sources(root: Path) -> tuple[Path, ...]:
    """Return every tracked C source or header below the native source roots.

    Args:
        root: Repository root from which Git reports tracked paths.

    Raises:
        SystemExit: If Git fails, reports no supported sources, or reports an
            absent or escaping path.
    """
    command = ["git", "ls-files", "-z", "--", *NATIVE_DIRS]
    listed = subprocess.run(
        command,
        cwd=root,
        check=False,
        capture_output=True,
    )
    if listed.returncode != 0:
        raise SystemExit(
            "native-sources: git ls-files failed:\n"
            + listed.stderr.decode(errors="replace")
        )

    resolved_root = root.resolve()
    sources: list[Path] = []
    for entry in listed.stdout.split(b"\0"):
        if not entry:
            continue
        relative = Path(os.fsdecode(entry))
        if relative.suffix not in SOURCE_SUFFIXES:
            continue
        if relative.is_absolute():
            raise SystemExit(f"native-sources: tracked path escapes root: {relative}")
        source = (resolved_root / relative).resolve()
        try:
            source.relative_to(resolved_root)
        except ValueError as exc:
            raise SystemExit(
                f"native-sources: tracked path escapes root: {relative}"
            ) from exc
        if not source.is_file():
            raise SystemExit(f"native-sources: tracked source is missing: {relative}")
        sources.append(source)

    sources.sort(key=lambda path: path.relative_to(resolved_root).as_posix())
    if not sources:
        raise SystemExit("native-sources: tracked source inventory is empty")
    return tuple(sources)


def require_ascii(sources: Iterable[Path], *, label: str) -> None:
    """Fail when a native source contains a non-ASCII byte.

    Args:
        sources: Native paths whose bytes must stay ASCII-only.
        label: Name of the caller shown in a failure diagnostic.

    Raises:
        SystemExit: If a source contains a byte greater than ``0x7f``.
    """
    for source in sources:
        for offset, byte in enumerate(source.read_bytes()):
            if byte > 0x7F:
                raise SystemExit(f"{label}: {source}: non-ASCII byte {offset}")
