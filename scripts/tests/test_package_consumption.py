#!/usr/bin/env python3
"""Negative controls for the packaged-artifact consumption gate's oracles.

`scripts/build/package_consumption.py` is expensive: it builds a conda package,
installs it into a scratch environment, and drives the installed binary. Those
stages cannot run inside a unit test, but the decisions the gate makes CAN,
because each is a pure function over data the stages collect:

  * `package_platform` -- which subdir, loader command, and loader environment
    variables belong to the host being gated;
  * `scrubbed_probe_env` and `scratch_manifest_text` -- the two places that
    descriptor has to reach for the gate to be platform-parameterized rather
    than platform-agnostic-looking;
  * `verify_installed_artifact_identity` -- whether the package the solver
    installed is byte-for-byte the artifact this run built, or a same-version
    impostor from another channel;
  * `check_failing_fixture_consumption` -- whether the installed binary really
    reported the known-failing fixture as a failure.

Every test presents a double that differs from the truthful case in ONE named
way and requires the corresponding guard to reject it, so removing any guard
turns a named test red.

Usage:  python -m unittest scripts.tests.test_package_consumption
"""

from __future__ import annotations

import contextlib
import dataclasses
import io
import json
import stat
import tempfile
import unittest
from pathlib import Path

from scripts.build import package_consumption
from scripts.build.package_consumption import (
    BuiltArtifact,
    PackageCheckError,
    check_failing_fixture_consumption,
    package_platform,
    scrubbed_probe_env,
    scratch_manifest_text,
    verify_installed_artifact_identity,
)


# One real transcript, captured from `build/mtest --no-config --color never
# e2e/suite/test_failing.mojo` (exit 1). Every failing-fixture double below is
# this text with exactly one property changed, so a red test names the property
# it changed rather than "the buffer differs".
TRUTHFUL_TRANSCRIPT = """mtest 0.6.0 (mojo)
root: /home/mikko/dev/mtest   selected: 1 files   excluded: 0

FAIL           e2e/suite/test_failing.mojo     0.02s

--- FAIL e2e/suite/test_failing.mojo::test_second_fails ---
    | At e2e/suite/test_failing.mojo:14:17: AssertionError: comparison failed
reproduce: mtest e2e/suite/test_failing.mojo::test_second_fails

--- FAIL e2e/suite/test_failing.mojo (exit 1) --- captured output ---
    | Running 3 tests for /home/mikko/dev/mtest/e2e/suite/test_failing.mojo
    |     PASS [ 0.001 ] test_first_passes
    |     FAIL [ 0.008 ] test_second_fails
    |     PASS [ 0.001 ] test_third_passes
    | --------
    | Summary [ 0.008 ] 3 tests run: 2 passed , 1 failed , 0 skipped

===== 2 passed, 1 failed, 0 skipped (0 excluded, 0 not run) in 0.4s =====
"""
TRUTHFUL_VERSION = "0.6.0"


class PackagePlatformDescriptorTests(unittest.TestCase):
    """One descriptor per gated platform, with no field silently shared."""

    def test_linux_subdir_is_linux_64(self) -> None:
        self.assertEqual(package_platform("linux", "x86_64").subdir, "linux-64")

    def test_linux_loader_command_is_ldd(self) -> None:
        self.assertEqual(package_platform("linux", "x86_64").loader_command, ("ldd",))

    def test_linux_loader_env_is_ld_library_path(self) -> None:
        self.assertEqual(
            package_platform("linux", "x86_64").loader_env_names,
            ("LD_LIBRARY_PATH",),
        )

    def test_darwin_subdir_is_osx_arm64(self) -> None:
        self.assertEqual(package_platform("darwin", "arm64").subdir, "osx-arm64")

    def test_darwin_loader_command_is_otool(self) -> None:
        self.assertEqual(
            package_platform("darwin", "arm64").loader_command, ("otool", "-L")
        )

    def test_darwin_loader_env_is_dyld_library_path(self) -> None:
        self.assertEqual(
            package_platform("darwin", "arm64").loader_env_names,
            ("DYLD_LIBRARY_PATH",),
        )

    def test_descriptor_is_immutable(self) -> None:
        descriptor = package_platform("linux", "x86_64")
        with self.assertRaises(dataclasses.FrozenInstanceError):
            descriptor.subdir = "osx-arm64"  # type: ignore[misc]

    def test_supported_pairs_are_exactly_the_two_gated_hosts(self) -> None:
        self.assertEqual(
            set(package_consumption.SUPPORTED_PLATFORMS),
            {("linux", "x86_64"), ("darwin", "arm64")},
        )

    def test_unsupported_pairs_raise(self) -> None:
        for sys_platform, machine in (
            ("linux", "aarch64"),
            ("linux", "arm64"),
            ("linux", "i686"),
            ("darwin", "x86_64"),
            ("darwin", "aarch64"),
            ("win32", "AMD64"),
            ("freebsd13", "x86_64"),
            ("Linux", "x86_64"),
            ("", ""),
        ):
            with self.subTest(sys_platform=sys_platform, machine=machine):
                with self.assertRaises(PackageCheckError) as caught:
                    package_platform(sys_platform, machine)
                self.assertIn(repr(sys_platform), str(caught.exception))
                self.assertIn(repr(machine), str(caught.exception))


class DescriptorThreadingTests(unittest.TestCase):
    """The resolved descriptor reaches the probe env and the scratch manifest."""

    LINUX = package_platform("linux", "x86_64")
    DARWIN = package_platform("darwin", "arm64")

    def test_linux_probe_env_empties_ld_library_path(self) -> None:
        env = scrubbed_probe_env(self.LINUX)
        self.assertEqual(env["LD_LIBRARY_PATH"], "")
        self.assertNotIn("DYLD_LIBRARY_PATH", env)

    def test_darwin_probe_env_empties_dyld_library_path(self) -> None:
        env = scrubbed_probe_env(self.DARWIN)
        self.assertEqual(env["DYLD_LIBRARY_PATH"], "")
        self.assertNotIn("LD_LIBRARY_PATH", env)

    def test_probe_env_drops_the_ambient_toolchain_path(self) -> None:
        self.assertEqual(scrubbed_probe_env(self.DARWIN)["PATH"], "/usr/bin:/bin")

    def test_probe_env_carries_nothing_beyond_path_home_and_loader_names(
        self,
    ) -> None:
        self.assertEqual(
            set(scrubbed_probe_env(self.DARWIN)),
            {"PATH", "HOME", "DYLD_LIBRARY_PATH"},
        )

    def _artifact(self, subdir: str) -> BuiltArtifact:
        return BuiltArtifact(
            path=Path(f"/repo/build/conda-channel/{subdir}/mtest-0.6.0-hb0_0.conda"),
            version="0.6.0",
            build_string="hb0_0",
            sha256="c" * 64,
            subdir=subdir,
        )

    def test_manifest_pins_the_subdir_the_artifact_was_built_for(self) -> None:
        text = scratch_manifest_text(
            "conda-env", Path("/repo/build/conda-channel"), self._artifact("osx-arm64")
        )
        self.assertIn('platforms = ["osx-arm64"]', text)
        self.assertNotIn("linux-64", text)

    def test_manifest_pins_the_exact_build_string(self) -> None:
        text = scratch_manifest_text(
            "conda-env", Path("/repo/build/conda-channel"), self._artifact("linux-64")
        )
        self.assertIn('mtest = { version = "==0.6.0", build = "hb0_0" }', text)

    def test_manifest_puts_the_local_channel_first(self) -> None:
        text = scratch_manifest_text(
            "conda-env", Path("/repo/build/conda-channel"), self._artifact("linux-64")
        )
        channels = text.split("channels = [", 1)[1].split("]", 1)[0]
        self.assertTrue(
            channels.strip().startswith('"file:///repo/build/conda-channel"'),
            f"local channel is not solved first: {channels!r}",
        )


class ArtifactIdentityTests(unittest.TestCase):
    """The installed record must name the artifact this run built."""

    ARTIFACT_SHA = "a" * 64
    IMPOSTOR_SHA = "b" * 64

    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.prefix = Path(self._temp.name)
        (self.prefix / "conda-meta").mkdir()
        self.artifact = BuiltArtifact(
            path=self.prefix / "mtest-0.6.0-hb0f4dca_0.conda",
            version="0.6.0",
            build_string="hb0f4dca_0",
            sha256=self.ARTIFACT_SHA,
            subdir="linux-64",
        )

    def _write_record(self, **overrides: object) -> None:
        """Write the installed conda-meta record with named fields replaced."""
        record: dict[str, object] = {
            "name": "mtest",
            "version": "0.6.0",
            "build": "hb0f4dca_0",
            "sha256": self.ARTIFACT_SHA,
            "subdir": "linux-64",
            "channel": "file:///repo/build/conda-channel/",
        }
        record.update(overrides)
        for key in [key for key, value in record.items() if value is None]:
            del record[key]
        path = self.prefix / "conda-meta" / "mtest-0.6.0-hb0f4dca_0.json"
        path.write_text(json.dumps(record), encoding="utf-8")

    def test_matching_record_is_accepted(self) -> None:
        self._write_record()
        verify_installed_artifact_identity(self.prefix, self.artifact)

    def test_same_version_artifact_with_a_foreign_sha256_is_rejected(self) -> None:
        # The exact defect this gate exists for: the solver picked an mtest of
        # the same version and build string from some other channel.
        self._write_record(sha256=self.IMPOSTOR_SHA)
        with self.assertRaises(PackageCheckError) as caught:
            verify_installed_artifact_identity(self.prefix, self.artifact)
        message = str(caught.exception)
        self.assertIn(self.IMPOSTOR_SHA, message)
        self.assertIn(self.ARTIFACT_SHA, message)

    def test_foreign_subdir_is_rejected(self) -> None:
        self._write_record(subdir="osx-arm64")
        with self.assertRaises(PackageCheckError) as caught:
            verify_installed_artifact_identity(self.prefix, self.artifact)
        self.assertIn("osx-arm64", str(caught.exception))

    def test_absent_sha256_field_is_rejected(self) -> None:
        self._write_record(sha256=None)
        with self.assertRaises(PackageCheckError):
            verify_installed_artifact_identity(self.prefix, self.artifact)

    def test_absent_record_is_rejected(self) -> None:
        with self.assertRaises(PackageCheckError) as caught:
            verify_installed_artifact_identity(self.prefix, self.artifact)
        self.assertIn("mtest-0.6.0-hb0f4dca_0.json", str(caught.exception))

    def test_record_for_another_build_string_is_not_consulted(self) -> None:
        # A same-version package with a different build string leaves its own
        # record name; the gate must not accept it as ours.
        path = self.prefix / "conda-meta" / "mtest-0.6.0-hdeadbee_0.json"
        path.write_text(
            json.dumps({"sha256": self.ARTIFACT_SHA, "subdir": "linux-64"}),
            encoding="utf-8",
        )
        with self.assertRaises(PackageCheckError):
            verify_installed_artifact_identity(self.prefix, self.artifact)


class FailingFixtureConsumptionTests(unittest.TestCase):
    """The installed binary must be seen failing the known-failing fixture."""

    def _check(self, transcript: str, returncode: int = 1) -> None:
        check_failing_fixture_consumption(returncode, transcript, TRUTHFUL_VERSION)

    def test_truthful_transcript_is_accepted(self) -> None:
        self._check(TRUTHFUL_TRANSCRIPT)

    def test_exit_zero_is_rejected(self) -> None:
        # An installed mtest that reports the failure but exits 0 is the defect
        # a consuming CI would silently accept.
        with self.assertRaises(PackageCheckError) as caught:
            self._check(TRUTHFUL_TRANSCRIPT, returncode=0)
        self.assertIn("exit", str(caught.exception))

    def test_exit_two_is_rejected(self) -> None:
        with self.assertRaises(PackageCheckError):
            self._check(TRUTHFUL_TRANSCRIPT, returncode=2)

    def test_pass_verdict_row_for_the_fixture_is_rejected(self) -> None:
        transcript = TRUTHFUL_TRANSCRIPT.replace(
            "FAIL           e2e/suite/test_failing.mojo",
            "PASS           e2e/suite/test_failing.mojo",
        )
        with self.assertRaises(PackageCheckError) as caught:
            self._check(transcript)
        self.assertIn("PASS", str(caught.exception))

    def test_missing_verdict_row_is_rejected(self) -> None:
        transcript = TRUTHFUL_TRANSCRIPT.replace(
            "FAIL           e2e/suite/test_failing.mojo     0.02s\n", ""
        )
        with self.assertRaises(PackageCheckError):
            self._check(transcript)

    def test_verdict_row_for_another_file_is_rejected(self) -> None:
        transcript = TRUTHFUL_TRANSCRIPT.replace(
            "FAIL           e2e/suite/test_failing.mojo",
            "FAIL           e2e/suite/test_crashing.mojo",
        )
        with self.assertRaises(PackageCheckError) as caught:
            self._check(transcript)
        self.assertIn("e2e/suite/test_failing.mojo", str(caught.exception))

    def test_summary_without_a_failure_is_rejected(self) -> None:
        transcript = TRUTHFUL_TRANSCRIPT.replace(
            "===== 2 passed, 1 failed, 0 skipped",
            "===== 3 passed, 0 failed, 0 skipped",
        )
        with self.assertRaises(PackageCheckError) as caught:
            self._check(transcript)
        self.assertIn("failed", str(caught.exception))

    def test_summary_without_the_fixtures_passing_tests_is_rejected(self) -> None:
        transcript = TRUTHFUL_TRANSCRIPT.replace(
            "===== 2 passed, 1 failed, 0 skipped",
            "===== 0 passed, 1 failed, 0 skipped",
        )
        with self.assertRaises(PackageCheckError) as caught:
            self._check(transcript)
        self.assertIn("passed", str(caught.exception))

    def test_unrun_file_is_rejected(self) -> None:
        # A failure count alone can be satisfied without the fixture having run.
        transcript = TRUTHFUL_TRANSCRIPT.replace(
            "(0 excluded, 0 not run)", "(0 excluded, 1 not run)"
        )
        with self.assertRaises(PackageCheckError) as caught:
            self._check(transcript)
        self.assertIn("not run", str(caught.exception))

    def test_missing_summary_band_is_rejected(self) -> None:
        transcript = TRUTHFUL_TRANSCRIPT.split("=====")[0]
        with self.assertRaises(PackageCheckError):
            self._check(transcript)

    def test_transcript_from_another_version_is_rejected(self) -> None:
        # Evidence must come from the package under test, not from some other
        # mtest that happens to be present on the machine.
        transcript = TRUTHFUL_TRANSCRIPT.replace(
            "mtest 0.6.0 (mojo)", "mtest 0.5.0 (mojo)"
        )
        with self.assertRaises(PackageCheckError) as caught:
            self._check(transcript)
        self.assertIn("0.6.0", str(caught.exception))

    def test_empty_transcript_is_rejected(self) -> None:
        with self.assertRaises(PackageCheckError):
            self._check("")


class FailingFixtureStageTests(unittest.TestCase):
    """The stage must actually execute a binary and judge what it produced."""

    def _fake_mtest(self, transcript: str, exit_code: int) -> tuple[Path, Path]:
        """Write an executable stand-in that records that it ran.

        Args:
            transcript: Text the stand-in writes to stdout.
            exit_code: Status the stand-in exits with.

        Returns:
            The stand-in's path and the marker path it creates when invoked.
        """
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        marker = root / "invoked"
        binary = root / "mtest"
        binary.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            f"open({str(marker)!r}, 'w').close()\n"
            f"sys.stdout.write({transcript!r})\n"
            f"raise SystemExit({exit_code})\n",
            encoding="utf-8",
        )
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
        return binary, marker

    def test_stage_accepts_a_stand_in_that_reports_the_failure(self) -> None:
        binary, marker = self._fake_mtest(TRUTHFUL_TRANSCRIPT, 1)
        with contextlib.redirect_stdout(io.StringIO()):
            package_consumption.stage_failing_fixture_consumption(
                binary, TRUTHFUL_VERSION
            )
        self.assertTrue(marker.exists(), "stage never executed the binary")

    def test_stage_rejects_a_stand_in_that_exits_zero(self) -> None:
        binary, marker = self._fake_mtest(TRUTHFUL_TRANSCRIPT, 0)
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(PackageCheckError):
                package_consumption.stage_failing_fixture_consumption(
                    binary, TRUTHFUL_VERSION
                )
        self.assertTrue(marker.exists(), "stage never executed the binary")


class FixtureInventoryTests(unittest.TestCase):
    """The consumed fixture is a real, still-failing file in this checkout."""

    def test_failing_fixture_exists_and_is_a_regular_file(self) -> None:
        path = package_consumption.REPO_ROOT / package_consumption.FAILING_FIXTURE
        self.assertTrue(path.is_file())
        self.assertFalse(path.is_symlink())

    def test_failing_fixture_is_declared_failing_in_the_e2e_manifest(self) -> None:
        manifest = json.loads(
            (package_consumption.REPO_ROOT / "e2e" / "manifest.json").read_text(
                encoding="utf-8"
            )
        )
        row = manifest["tests"][package_consumption.FAILING_FIXTURE]
        self.assertEqual(row["verdict"], "FAIL")
        self.assertEqual(row["exit_class"], 1)
        self.assertEqual(
            row["per_test"]["passed"], package_consumption.FAILING_FIXTURE_PASSED
        )
        self.assertEqual(
            row["per_test"]["failed"], package_consumption.FAILING_FIXTURE_FAILED
        )


def main() -> int:
    """Run this module's negative controls as a standalone gate step."""
    result = unittest.main(module=__name__, exit=False, verbosity=0).result
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
