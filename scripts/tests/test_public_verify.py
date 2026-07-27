#!/usr/bin/env python3
"""Public-channel package verification behavior tests."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from scripts.release.public_verify import (
    CommandResult,
    PublicVerifyError,
    install_manifest,
    verify_installed_package,
)


VERSION = "1.0.0"
BUILD_NUMBER = 0
COMPANION_FILES = (
    "mtest/__init__.mojo",
    "mtest/assertions/__init__.mojo",
    "mtest/assertions/_display.mojo",
    "mtest/assertions/_mapping.mojo",
    "mtest/assertions/_sequence.mojo",
    "mtest/assertions/_text.mojo",
)


class FakeRunner:
    """Deterministic command boundary for an installed public package."""

    def __init__(self) -> None:
        self.commands: list[tuple[str, ...]] = []

    def __call__(
        self,
        command: tuple[str, ...],
        environment: dict[str, str],
    ) -> CommandResult:
        _ = environment
        self.commands.append(command)
        executable = Path(command[0]).name
        if executable == "mtest":
            if command[1:] == ("--version",):
                return CommandResult(0, "mtest 1.0.0\n", "")
            if command[1:] == ("--help",):
                return CommandResult(0, "Usage: mtest [OPTIONS]\n", "")
            fixture = Path(command[-1]).name
            if fixture == "test_passing.mojo":
                return CommandResult(0, "PASS\n", "")
            if fixture == "test_failing.mojo":
                return CommandResult(1, "FAIL\n", "")
            if fixture == "test_crashing.mojo":
                return CommandResult(1, "CRASH\n", "")
        if executable == "mojo":
            Path(command[-1]).write_text("binary\n", encoding="utf-8")
            return CommandResult(0, "", "")
        if executable.startswith("assertion-"):
            return CommandResult(0, "", "")
        return CommandResult(99, "", f"unexpected command: {command!r}")


class ManifestTests(unittest.TestCase):
    def test_manifest_uses_only_public_channels_in_exact_order(self) -> None:
        self.assertEqual(
            install_manifest(VERSION, "linux-64"),
            (
                '[workspace]\nname = "mtest-public-verify"\n'
                'channels = ["https://conda.modular.com/max/", '
                '"https://repo.prefix.dev/modular-community", "conda-forge"]\n'
                'platforms = ["linux-64"]\n\n'
                "[dependencies]\n"
                'mtest = "==1.0.0"\n'
                'mojo = "==1.0.0b2"\n'
            ),
        )

    def test_manifest_rejects_invalid_version_or_platform(self) -> None:
        for version, platform in (
            ("v1.0.0", "linux-64"),
            ("1.0.0", "linux-aarch64"),
        ):
            with (
                self.subTest(version=version, platform=platform),
                self.assertRaises(ValueError),
            ):
                install_manifest(version, platform)


class InstalledPackageTests(unittest.TestCase):
    def _prefix(self, root: Path) -> Path:
        prefix = root / "prefix"
        metadata = prefix / "conda-meta"
        metadata.mkdir(parents=True)
        (metadata / "mtest-1.0.0-0.json").write_text(
            json.dumps(
                {
                    "name": "mtest",
                    "version": VERSION,
                    "build_number": BUILD_NUMBER,
                }
            ),
            encoding="utf-8",
        )
        binary = prefix / "bin" / "mtest"
        binary.parent.mkdir()
        binary.write_text("binary\n", encoding="utf-8")
        binary.chmod(0o755)
        source = prefix / "share" / "mtest" / "companions" / "assertions" / "src"
        for relative in COMPANION_FILES:
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("source\n", encoding="utf-8")
        (prefix / "bin" / "mojo").write_text("compiler\n", encoding="utf-8")
        return prefix

    def test_acceptance_runs_all_public_behavior_and_assertion_probes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-public-verify-") as raw_tmp:
            workspace = Path(raw_tmp)
            prefix = self._prefix(workspace)
            runner = FakeRunner()

            verify_installed_package(
                prefix,
                workspace,
                VERSION,
                BUILD_NUMBER,
                runner,
                {"PATH": str(prefix / "bin")},
            )

        command_text = [" ".join(command) for command in runner.commands]
        self.assertEqual(len(command_text), 9)
        self.assertTrue(any("--version" in command for command in command_text))
        self.assertTrue(any("--help" in command for command in command_text))
        self.assertTrue(any("test_passing.mojo" in command for command in command_text))
        self.assertTrue(any("test_failing.mojo" in command for command in command_text))
        self.assertTrue(
            any("test_crashing.mojo" in command for command in command_text)
        )
        self.assertTrue(any("-O0" in command for command in command_text))
        self.assertTrue(any("-O3" in command for command in command_text))
        self.assertEqual(
            sum(
                Path(command.split()[0]).name.startswith("assertion-")
                for command in command_text
            ),
            2,
        )

    def test_metadata_and_companion_tampering_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-public-verify-") as raw_tmp:
            workspace = Path(raw_tmp)
            prefix = self._prefix(workspace)
            metadata = next((prefix / "conda-meta").glob("mtest-*.json"))
            source = prefix / "share" / "mtest" / "companions" / "assertions" / "src"
            for index, kind in enumerate(("metadata", "extra", "missing")):
                with self.subTest(kind=kind):
                    prefix = self._prefix(workspace / str(index))
                    metadata = next((prefix / "conda-meta").glob("mtest-*.json"))
                    source = (
                        prefix / "share" / "mtest" / "companions" / "assertions" / "src"
                    )
                    if kind == "metadata":
                        metadata.write_text(
                            '{"name":"mtest","version":"1.0.1","build_number":0}',
                            encoding="utf-8",
                        )
                    elif kind == "extra":
                        (source / "extra.mojo").write_text(
                            "extra\n",
                            encoding="utf-8",
                        )
                    else:
                        (source / "mtest" / "__init__.mojo").unlink()
                    with self.assertRaises(PublicVerifyError):
                        verify_installed_package(
                            prefix,
                            workspace / str(index),
                            VERSION,
                            BUILD_NUMBER,
                            FakeRunner(),
                            {"PATH": str(prefix / "bin")},
                        )

    def test_symlinked_companion_source_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-public-verify-") as raw_tmp:
            workspace = Path(raw_tmp)
            prefix = self._prefix(workspace)
            source = prefix / "share" / "mtest" / "companions" / "assertions" / "src"
            target = source / "mtest" / "__init__.mojo"
            target.unlink()
            target.symlink_to("assertions/__init__.mojo")
            with self.assertRaises(PublicVerifyError):
                verify_installed_package(
                    prefix,
                    workspace,
                    VERSION,
                    BUILD_NUMBER,
                    FakeRunner(),
                    {"PATH": str(prefix / "bin")},
                )


if __name__ == "__main__":
    unittest.main()
