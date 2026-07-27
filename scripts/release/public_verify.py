#!/usr/bin/env python3
"""Install mtest from public channels and verify the published package."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import tempfile
from typing import Protocol


REPO_ROOT = Path(__file__).resolve().parents[2]
VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
SUPPORTED_PLATFORMS = {"linux-64", "osx-arm64"}
CHANNELS = (
    "https://conda.modular.com/max/",
    "https://repo.prefix.dev/modular-community",
    "conda-forge",
)
COMPANION_FILES = (
    "mtest/__init__.mojo",
    "mtest/assertions/__init__.mojo",
    "mtest/assertions/_display.mojo",
    "mtest/assertions/_mapping.mojo",
    "mtest/assertions/_sequence.mojo",
    "mtest/assertions/_text.mojo",
)


class PublicVerifyError(RuntimeError):
    """A public package failed an acceptance invariant."""


@dataclass(frozen=True)
class CommandResult:
    """Captured result from one acceptance command."""

    returncode: int
    stdout: str
    stderr: str


class CommandRunner(Protocol):
    """Command boundary used by acceptance checks."""

    def __call__(
        self,
        command: tuple[str, ...],
        environment: dict[str, str],
    ) -> CommandResult:
        """Execute one command with the supplied complete environment."""
        ...


def _run(
    command: tuple[str, ...],
    environment: dict[str, str],
) -> CommandResult:
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PublicVerifyError(f"could not execute {command!r}: {exc}") from exc
    return CommandResult(result.returncode, result.stdout, result.stderr)


def install_manifest(version: str, target_platform: str) -> str:
    """Return a minimal Pixi manifest using only approved public channels."""
    if VERSION_RE.fullmatch(version) is None:
        raise ValueError(f"invalid public version: {version!r}")
    if target_platform not in SUPPORTED_PLATFORMS:
        raise ValueError(f"unsupported public verification platform: {target_platform}")
    channels = ", ".join(f'"{channel}"' for channel in CHANNELS)
    return (
        '[workspace]\nname = "mtest-public-verify"\n'
        f"channels = [{channels}]\n"
        f'platforms = ["{target_platform}"]\n\n'
        "[dependencies]\n"
        f'mtest = "=={version}"\n'
    )


def _metadata(
    prefix: Path,
    version: str,
    build_number: int,
    target_platform: str,
) -> None:
    records = tuple((prefix / "conda-meta").glob("mtest-*.json"))
    if len(records) != 1 or records[0].is_symlink():
        raise PublicVerifyError(
            f"expected exactly one regular mtest metadata record, found {records!r}"
        )
    try:
        document = json.loads(records[0].read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PublicVerifyError(f"invalid mtest metadata: {exc}") from exc
    expected = {
        "name": "mtest",
        "version": version,
        "build_number": build_number,
        "subdir": target_platform,
    }
    actual = (
        {key: document.get(key) for key in expected}
        if isinstance(document, dict)
        else document
    )
    if actual != expected or isinstance(
        document.get("build_number") if isinstance(document, dict) else None,
        bool,
    ):
        raise PublicVerifyError(
            f"installed package identity mismatch: expected={expected}, actual={actual}"
        )
    url = document.get("url") if isinstance(document, dict) else None
    expected_url_prefix = (
        f"https://repo.prefix.dev/modular-community/{target_platform}/"
    )
    if not isinstance(url, str) or not url.startswith(expected_url_prefix):
        raise PublicVerifyError(
            "installed mtest did not come from modular-community: "
            f"expected URL prefix={expected_url_prefix!r}, actual={url!r}"
        )


def _companion(prefix: Path) -> Path:
    root = prefix / "share" / "mtest" / "companions" / "assertions" / "src"
    if root.is_symlink() or not root.is_dir():
        raise PublicVerifyError(
            "installed assertion companion root is missing or linked"
        )
    actual: set[str] = set()
    for path in root.rglob("*"):
        if path.is_dir() and not path.is_symlink():
            continue
        relative = path.relative_to(root).as_posix()
        mode = path.stat(follow_symlinks=False).st_mode
        if path.is_symlink() or not stat.S_ISREG(mode):
            raise PublicVerifyError(
                f"installed assertion companion entry is not regular: {relative}"
            )
        actual.add(relative)
    if actual != set(COMPANION_FILES):
        raise PublicVerifyError(
            "installed assertion companion membership mismatch: "
            f"expected={list(COMPANION_FILES)!r}, actual={sorted(actual)!r}"
        )
    return root


def _write_fixtures(workspace: Path) -> tuple[Path, Path, Path, Path]:
    fixtures = workspace / "fixtures"
    fixtures.mkdir(parents=True, exist_ok=True)
    passing = fixtures / "test_passing.mojo"
    failing = fixtures / "test_failing.mojo"
    crashing = fixtures / "test_crashing.mojo"
    consumer = fixtures / "assertion_consumer.mojo"
    passing.write_text(
        '"""Public verification passing fixture."""\n'
        "from std.testing import assert_equal, TestSuite\n\n"
        "def test_passes() raises:\n"
        "    assert_equal(2 + 2, 4)\n\n"
        "def main() raises:\n"
        "    TestSuite.discover_tests[__functions_in_module()]().run()\n",
        encoding="utf-8",
    )
    failing.write_text(
        '"""Public verification failing fixture."""\n'
        "from std.testing import assert_equal, TestSuite\n\n"
        "def test_fails() raises:\n"
        "    assert_equal(1, 2)\n\n"
        "def main() raises:\n"
        "    TestSuite.discover_tests[__functions_in_module()]().run()\n",
        encoding="utf-8",
    )
    crashing.write_text(
        '"""Public verification crashing fixture."""\n'
        "from std.os import abort\n"
        "from std.testing import TestSuite\n\n"
        "def test_crashes() raises:\n"
        '    abort("public verification crash")\n\n'
        "def main() raises:\n"
        "    TestSuite.discover_tests[__functions_in_module()]().run()\n",
        encoding="utf-8",
    )
    consumer.write_text(
        '"""Installed assertion companion consumer."""\n'
        "from mtest.assertions import assert_equal\n\n"
        "def main() raises:\n"
        '    assert_equal("published", "published")\n',
        encoding="utf-8",
    )
    return passing, failing, crashing, consumer


def _expect(
    runner: CommandRunner,
    command: tuple[str, ...],
    environment: dict[str, str],
    *,
    returncode: int,
    marker: str | None = None,
) -> CommandResult:
    result = runner(command, environment)
    if result.returncode != returncode:
        raise PublicVerifyError(
            f"command {command!r} returned {result.returncode}, "
            f"expected {returncode}; stdout={result.stdout!r}, stderr={result.stderr!r}"
        )
    if marker is not None and marker not in result.stdout + result.stderr:
        raise PublicVerifyError(
            f"command {command!r} omitted marker {marker!r}; "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}"
        )
    return result


def verify_installed_package(
    prefix: Path,
    workspace: Path,
    version: str,
    build_number: int,
    target_platform: str,
    runner: CommandRunner,
    environment: dict[str, str],
) -> None:
    """Verify identity, files, runner behavior, and assertion consumption."""
    if VERSION_RE.fullmatch(version) is None:
        raise PublicVerifyError(f"invalid public version: {version!r}")
    build: object = build_number
    if isinstance(build, bool) or not isinstance(build, int) or build < 0:
        raise PublicVerifyError(f"invalid public build number: {build!r}")
    if target_platform not in SUPPORTED_PLATFORMS:
        raise PublicVerifyError(
            f"unsupported installed package platform: {target_platform!r}"
        )
    _metadata(prefix, version, build_number, target_platform)
    source = _companion(prefix)
    mtest = prefix / "bin" / "mtest"
    mojo = prefix / "bin" / "mojo"
    if mtest.is_symlink() or not mtest.is_file() or not os.access(mtest, os.X_OK):
        raise PublicVerifyError("installed mtest binary is missing or not executable")
    if mojo.is_symlink() or not mojo.is_file():
        raise PublicVerifyError("verification Mojo compiler is missing")

    passing, failing, crashing, consumer = _write_fixtures(workspace)
    version_result = _expect(
        runner,
        (str(mtest), "--version"),
        environment,
        returncode=0,
    )
    if version_result.stdout != f"mtest {version}\n":
        raise PublicVerifyError(
            f"installed version output mismatch: {version_result.stdout!r}"
        )
    _expect(
        runner,
        (str(mtest), "--help"),
        environment,
        returncode=0,
        marker="Usage:",
    )
    for fixture, returncode, marker in (
        (passing, 0, "PASS"),
        (failing, 1, "FAIL"),
        (crashing, 1, "CRASH"),
    ):
        _expect(
            runner,
            (str(mtest), "--no-config", str(fixture)),
            environment,
            returncode=returncode,
            marker=marker,
        )

    for optimization in ("-O0", "-O3"):
        binary = workspace / f"assertion-{optimization.removeprefix('-')}"
        _expect(
            runner,
            (
                str(mojo),
                "build",
                optimization,
                "-I",
                str(source),
                str(consumer),
                "-o",
                str(binary),
            ),
            environment,
            returncode=0,
        )
        _expect(runner, (str(binary),), environment, returncode=0)


def _host_platform() -> str:
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Linux" and machine in {"x86_64", "amd64"}:
        return "linux-64"
    if system == "Darwin" and machine in {"arm64", "aarch64"}:
        return "osx-arm64"
    raise PublicVerifyError(f"unsupported public verification host: {system}/{machine}")


def _acceptance_environment(prefix: Path, workspace: Path) -> dict[str, str]:
    home = workspace / "home"
    temporary = workspace / "tmp"
    cache = workspace / "modular-cache"
    for path in (home, temporary, cache):
        path.mkdir()
    return {
        "HOME": str(home),
        "MODULAR_CACHE_DIR": str(cache),
        "PATH": os.pathsep.join((str(prefix / "bin"), os.defpath)),
        "TMPDIR": str(temporary),
    }


def verify_public_package(version: str, build_number: int) -> None:
    """Install from public channels into a clean prefix and run acceptance."""
    target = _host_platform()
    scratch_root = REPO_ROOT / "build" / "public-verify"
    scratch_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="run-", dir=scratch_root) as raw_tmp:
        workspace = Path(raw_tmp)
        manifest = workspace / "pixi.toml"
        manifest.write_text(install_manifest(version, target), encoding="utf-8")
        install_environment = dict(os.environ)
        install = _run(
            ("pixi", "install", "--manifest-path", str(manifest)),
            install_environment,
        )
        if install.returncode != 0:
            raise PublicVerifyError(
                "public package install failed; "
                f"stdout={install.stdout!r}, stderr={install.stderr!r}"
            )
        prefix = workspace / ".pixi" / "envs" / "default"
        environment = _acceptance_environment(prefix, workspace)
        verify_installed_package(
            prefix,
            workspace,
            version,
            build_number,
            target,
            _run,
            environment,
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    return parser


def _build_number(raw: str) -> int:
    if re.fullmatch(r"(?:0|[1-9][0-9]*)", raw) is None:
        raise PublicVerifyError(f"invalid public build number: {raw!r}")
    return int(raw)


def main(argv: list[str] | None = None) -> int:
    """Run public-channel installation and acceptance."""
    args = _parser().parse_args(argv)
    try:
        verify_public_package(args.version, _build_number(args.build_number))
    except (OSError, PublicVerifyError, ValueError) as exc:
        print(f"public-verify: FAIL: {exc}", file=sys.stderr)
        return 1
    print("public-verify: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
