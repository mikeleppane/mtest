"""Tests for the shell-completion oracle.

These prove the gate's own machinery: that it fails closed on a missing shell
unless told not to, that it rejects a bad render or an unparsable script, and
that its probe tables address a fixture that exists. They do NOT start a shell
-- the terminal driver is exercised by the gate itself, on a host with all
three shells.
"""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
from typing import TYPE_CHECKING
import unittest
from unittest import mock

from scripts.checks import completion_shells


if TYPE_CHECKING:
    from collections.abc import Callable


def _which(*absent: str) -> Callable[[str], str | None]:
    """Resolve every shell but `absent`, which is reported missing."""
    return lambda name: None if name in absent else f"/bin/{name}"


def _bash_major(major: str) -> Callable[..., subprocess.CompletedProcess[bytes]]:
    """Answer the version probe with `major` without starting a shell."""
    return lambda *_a, **_k: subprocess.CompletedProcess(
        args=["bash"], returncode=0, stdout=major.encode(), stderr=b""
    )


class ShellResolutionTests(unittest.TestCase):
    def test_every_declared_shell_is_resolved(self) -> None:
        with (
            mock.patch.object(shutil, "which", side_effect=_which()),
            mock.patch.object(subprocess, "run", side_effect=_bash_major("5")),
        ):
            found, skipped = completion_shells.resolve_shells(False)

        self.assertEqual(skipped, {})
        self.assertEqual(
            found, {shell: f"/bin/{shell}" for shell in completion_shells.SHELLS}
        )

    def test_a_missing_shell_fails_the_gate_by_default(self) -> None:
        with (
            mock.patch.object(shutil, "which", side_effect=_which("fish")),
            mock.patch.object(subprocess, "run", side_effect=_bash_major("5")),
            self.assertRaisesRegex(AssertionError, r"fish \(not installed\)"),
        ):
            completion_shells.resolve_shells(False)

    def test_allow_missing_narrows_coverage_without_disabling_the_gate(self) -> None:
        with (
            mock.patch.object(shutil, "which", side_effect=_which("fish")),
            mock.patch.object(subprocess, "run", side_effect=_bash_major("5")),
        ):
            found, skipped = completion_shells.resolve_shells(True)

        self.assertEqual(skipped, {"fish": "not installed"})
        self.assertEqual(sorted(found), ["bash", "zsh"])

    def test_a_bash_too_old_for_the_rows_is_skipped_like_an_absent_one(self) -> None:
        """MacOS ships bash 3.2, which has neither `compopt` nor READLINE_LINE.

        Present-but-unusable used to be indistinguishable from present, so the
        osx-arm64 `--allow-missing` arm would have failed five bash rows
        instead of narrowing to the shells it can actually drive.
        """
        with (
            mock.patch.object(shutil, "which", side_effect=_which()),
            mock.patch.object(subprocess, "run", side_effect=_bash_major("3")),
        ):
            found, skipped = completion_shells.resolve_shells(True)

        self.assertEqual(sorted(found), ["fish", "zsh"])
        self.assertIn("bash 3.x", skipped["bash"])

        with (
            mock.patch.object(shutil, "which", side_effect=_which()),
            mock.patch.object(subprocess, "run", side_effect=_bash_major("3")),
            self.assertRaisesRegex(AssertionError, r"bash \(bash 3\.x"),
        ):
            completion_shells.resolve_shells(False)


class SubprocessTests(unittest.TestCase):
    def test_a_command_that_cannot_run_is_a_gate_failure(self) -> None:
        # A shell that will not start and a shell that never returns are the
        # same finding: this exchange produced no verdict.
        for broken in (FileNotFoundError("x"), subprocess.TimeoutExpired(["zsh"], 60)):
            with (
                self.subTest(repr(broken)),
                mock.patch.object(subprocess, "run", side_effect=broken),
                self.assertRaisesRegex(AssertionError, "cannot run /bin/zsh"),
            ):
                completion_shells._run(["/bin/zsh", "-n", "mtest.zsh"])


class RenderTests(unittest.TestCase):
    def _done(
        self,
        returncode: int = 0,
        stdout: bytes = b"complete -F _x mtest\n",
        stderr: bytes = b"",
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.CompletedProcess(
            args=["mtest", "completions", "bash"],
            returncode=returncode,
            stdout=stdout,
            stderr=stderr,
        )

    def test_writes_one_script_per_shell(self) -> None:
        with (
            tempfile.TemporaryDirectory() as raw,
            mock.patch.object(subprocess, "run", return_value=self._done()),
        ):
            scripts = completion_shells.render_completion_scripts(
                Path("/nonexistent/mtest"), Path(raw)
            )

            self.assertEqual(sorted(scripts), sorted(completion_shells.SHELLS))
            for shell, path in scripts.items():
                self.assertEqual(path.name, f"mtest.{shell}")
                self.assertEqual(path.read_bytes(), b"complete -F _x mtest\n")

    def test_a_render_that_did_not_cleanly_produce_a_script_is_rejected(self) -> None:
        # Nonzero, noisy and empty are one finding: this build cannot be asked
        # what its completion script is.
        for label, done in (
            ("nonzero", self._done(returncode=4)),
            ("noisy", self._done(stderr=b"warn\n")),
            ("empty", self._done(stdout=b" \n")),
        ):
            with (
                self.subTest(label),
                tempfile.TemporaryDirectory() as raw,
                mock.patch.object(subprocess, "run", return_value=done),
                self.assertRaisesRegex(AssertionError, "mtest completions bash"),
            ):
                completion_shells.render_completion_scripts(Path("mtest"), Path(raw))


class SyntaxTests(unittest.TestCase):
    def test_a_parse_failure_names_the_shell_and_its_message(self) -> None:
        failed = subprocess.CompletedProcess(
            args=["zsh", "-n"], returncode=1, stdout=b"", stderr=b"parse error\n"
        )
        with (
            mock.patch.object(subprocess, "run", return_value=failed),
            self.assertRaisesRegex(AssertionError, "zsh cannot parse.*parse error"),
        ):
            completion_shells.check_syntax("zsh", "/bin/zsh", Path("mtest.zsh"))


class FixtureTests(unittest.TestCase):
    def test_the_tree_is_built_with_the_sole_shapes_the_rows_need(self) -> None:
        # Two rows depend on the last two assertions: a bare `md:` prefix must
        # resolve to a file in `solefile` and to a directory in `soledir`,
        # which only tests the script while each holds exactly one entry.
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            completion_shells.build_fixture(root)

            for directory in completion_shells.FIXTURE_DIRECTORIES:
                self.assertTrue((root / directory).is_dir(), directory)
            for name in completion_shells.FIXTURE_FILES:
                self.assertTrue((root / name).is_file(), name)
            sole = [p.name for p in (root / "solefile").iterdir()]
            self.assertEqual(sole, ["tail.md"])
            sole = [p.name for p in (root / "soledir").iterdir()]
            self.assertEqual(sole, ["reports"])


class ProbeTableTests(unittest.TestCase):
    def test_every_row_names_a_real_shell_and_asserts_something(self) -> None:
        for shell, directory, typed, _ in completion_shells.BUFFER_PROBES:
            self.assertIn(shell, completion_shells.SHELLS, typed)
            self.assertIn(directory, completion_shells.FIXTURE_DIRECTORIES, typed)
        for line, offers, exact in completion_shells.CANDIDATE_PROBES:
            self.assertTrue(offers or exact is not None, line)

    def test_no_table_can_be_emptied_into_a_vacuous_gate(self) -> None:
        # zsh has no candidate API, so losing its buffer rows would leave that
        # shell with syntax coverage alone.
        self.assertGreaterEqual(len(completion_shells.BUFFER_PROBES), 8)
        self.assertGreaterEqual(len(completion_shells.CANDIDATE_PROBES), 3)
        self.assertTrue(any(row[0] == "zsh" for row in completion_shells.BUFFER_PROBES))


class MainTests(unittest.TestCase):
    def test_a_failure_exits_one(self) -> None:
        failed = AssertionError("row failed")
        with mock.patch.object(
            completion_shells, "check_completion_shells", side_effect=failed
        ):
            self.assertEqual(completion_shells.main([]), 1)

    def test_require_all_is_the_default_and_allow_missing_is_opt_in(self) -> None:
        with mock.patch.object(completion_shells, "check_completion_shells") as check:
            self.assertEqual(completion_shells.main([]), 0)
            self.assertEqual(completion_shells.main(["--allow-missing"]), 0)

        self.assertIs(check.call_args_list[0].args[0], False)
        self.assertIs(check.call_args_list[1].args[0], True)


if __name__ == "__main__":
    unittest.main()
