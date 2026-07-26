"""Tests for the byte-exact README help checker."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts.checks import readme_help


VALID_README = (
    b"# mtest\n\n"
    b"## CLI reference\n\n"
    b"```text\n"
    b"generated help\n"
    b"```\n\n"
    b"## Next section\n"
)


class ReadmeHelpExtractionTests(unittest.TestCase):
    def test_extracts_the_standalone_text_fence(self) -> None:
        self.assertEqual(
            readme_help._readme_help_block(VALID_README),
            b"generated help\n",
        )

    def test_rejects_a_suffixed_closing_fence(self) -> None:
        malformed = VALID_README.replace(b"```\n\n## Next", b"```suffix\n\n## Next")
        with self.assertRaisesRegex(AssertionError, "not closed"):
            readme_help._readme_help_block(malformed)

    def test_rejects_an_indented_closing_fence(self) -> None:
        malformed = VALID_README.replace(b"```\n\n## Next", b"  ```\n\n## Next")
        with self.assertRaisesRegex(AssertionError, "not closed"):
            readme_help._readme_help_block(malformed)

    def test_rejects_duplicate_cli_sections(self) -> None:
        malformed = VALID_README + VALID_README
        with self.assertRaisesRegex(AssertionError, "exactly one CLI"):
            readme_help._readme_help_block(malformed)

    def test_rejects_duplicate_text_fences(self) -> None:
        malformed = VALID_README.replace(
            b"```\n\n## Next",
            b"```\n\n```text\nother\n```\n\n## Next",
        )
        with self.assertRaisesRegex(AssertionError, "exactly one text fence"):
            readme_help._readme_help_block(malformed)


class ReadmeHelpSubprocessTests(unittest.TestCase):
    def _repo(self, raw_tmp: str) -> Path:
        repo = Path(raw_tmp)
        (repo / "README.md").write_bytes(VALID_README)
        return repo

    def test_rejects_nonzero_help_exit(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-readme-help-") as raw_tmp:
            run = subprocess.CompletedProcess(
                args=["mtest", "--help"],
                returncode=4,
                stdout=b"",
                stderr=b"bad invocation\n",
            )
            with mock.patch.object(readme_help.subprocess, "run", return_value=run):
                with self.assertRaisesRegex(AssertionError, "exited 4"):
                    readme_help.check_readme_help(self._repo(raw_tmp))

    def test_rejects_help_stderr(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-readme-help-") as raw_tmp:
            run = subprocess.CompletedProcess(
                args=["mtest", "--help"],
                returncode=0,
                stdout=b"generated help\n",
                stderr=b"unexpected\n",
            )
            with mock.patch.object(readme_help.subprocess, "run", return_value=run):
                with self.assertRaisesRegex(AssertionError, "wrote stderr"):
                    readme_help.check_readme_help(self._repo(raw_tmp))

    def test_rejects_help_timeout(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-readme-help-") as raw_tmp:
            timeout = subprocess.TimeoutExpired(["mtest", "--help"], 30)
            with mock.patch.object(
                readme_help.subprocess,
                "run",
                side_effect=timeout,
            ):
                with self.assertRaisesRegex(AssertionError, "exceeded 30 seconds"):
                    readme_help.check_readme_help(self._repo(raw_tmp))

    def test_rejects_missing_binary(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-readme-help-") as raw_tmp:
            with mock.patch.object(
                readme_help.subprocess,
                "run",
                side_effect=FileNotFoundError,
            ):
                with self.assertRaisesRegex(AssertionError, "binary is missing"):
                    readme_help.check_readme_help(self._repo(raw_tmp))

    def test_rejects_stdout_drift(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-readme-help-") as raw_tmp:
            run = subprocess.CompletedProcess(
                args=["mtest", "--help"],
                returncode=0,
                stdout=b"different help\n",
                stderr=b"",
            )
            with mock.patch.object(readme_help.subprocess, "run", return_value=run):
                with self.assertRaisesRegex(AssertionError, "differs"):
                    readme_help.check_readme_help(self._repo(raw_tmp))


if __name__ == "__main__":
    unittest.main()
