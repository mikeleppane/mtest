#!/usr/bin/env python3
"""Negative controls for the packaged-artifact consumption gate's oracles.

`scripts/build/package_consumption.py` is expensive: it builds a conda package,
installs it into a scratch environment, and drives the installed binary. Those
stages cannot run inside a unit test, but the decisions the gate makes CAN,
because each is a pure function over data the stages collect:

  * `package_platform`: which subdir, loader command, and loader environment
    variables belong to the host being gated;
  * `scrubbed_probe_env` and `scratch_manifest_text`: the two places that
    descriptor has to reach for the gate to be platform-parameterized;
  * `verify_installed_artifact_identity`: whether the package the solver
    installed is byte-for-byte the artifact this run built, or a same-version
    impostor from another channel;
  * `check_failing_fixture_consumption`: whether the installed binary really
    reported the known-failing fixture as a failure.

Every test presents a double that differs from the truthful case in ONE named
way and requires the corresponding guard to reject it, so removing any guard
turns a named test red.

Usage:  python -m unittest scripts.tests.test_package_consumption
"""

from __future__ import annotations

import configparser
import contextlib
import dataclasses
import inspect
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from typing import TYPE_CHECKING, override
import unittest
from unittest import mock

from scripts.build import package_consumption
from scripts.build.package_consumption import (
    BuiltArtifact,
    PackageCheckError,
    audit_installed_dependency_closure,
    check_failing_fixture_consumption,
    package_platform,
    scratch_manifest_text,
    scrubbed_probe_env,
    verify_installed_artifact_identity,
)
from scripts.harness import dogfood, watchdog


INSTALLED_ASSERTION_SOURCE_ROOT = Path("share/mtest/companions/assertions/src")


if TYPE_CHECKING:
    from collections.abc import Callable


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


class DarwinDependencyClosureTests(unittest.TestCase):
    """The installed Mach-O closure stays inside the prefix and targets 14.0."""

    @override
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.prefix = Path(self._temp.name).resolve() / "prefix"
        self.mtest = self.prefix / "bin" / "mtest"
        self.first = self.prefix / "lib" / "first"
        self.second = self.prefix / "lib" / "second"
        self.lib_a = self.first / "libA.dylib"
        self.shadow_a = self.second / "libA.dylib"
        self.lib_b = self.first / "libB.dylib"
        for path in (self.mtest, self.lib_a, self.shadow_a, self.lib_b):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"Mach-O fixture\n")

    @staticmethod
    def _loads(version: str = "14.0", *rpaths: str) -> str:
        return "".join(
            "          cmd LC_RPATH\n"
            "      cmdsize 48\n"
            f"         path {rpath} (offset 12)\n"
            for rpath in rpaths
        ) + (
            "          cmd LC_BUILD_VERSION\n"
            "     platform 1\n"
            f"        minos {version}\n"
            "          sdk 26.0\n"
        )

    @staticmethod
    def _dependencies(path: Path, *dependencies: str) -> str:
        return f"{path}:\n" + "".join(
            f"\t{dependency} (compatibility version 1.0.0, current version 1.0.0)\n"
            for dependency in dependencies
        )

    def _run_with(
        self,
        dependencies: dict[Path, str],
        loads: dict[Path, str],
    ) -> mock.Mock:
        runner = mock.Mock()

        def fake_run(
            argv: list[str], **_kwargs: object
        ) -> subprocess.CompletedProcess[str]:
            """Return one exact `otool` fixture for the requested file."""
            runner(argv)
            path = Path(argv[2]).resolve()
            output = dependencies[path] if argv[1] == "-L" else loads[path]
            return subprocess.CompletedProcess(argv, 0, output, "")

        with mock.patch.object(subprocess, "run", side_effect=fake_run):
            audit_installed_dependency_closure(
                self.mtest,
                package_platform("darwin", "arm64"),
            )
        return runner

    def test_walks_ordered_inherited_runpaths_and_terminates_a_cycle(self) -> None:
        dependencies = {
            self.mtest: self._dependencies(self.mtest, "@rpath/libA.dylib"),
            self.lib_a: self._dependencies(self.lib_a, "@rpath/libB.dylib"),
            self.lib_b: self._dependencies(
                self.lib_b,
                "@loader_path/libA.dylib",
                "@executable_path/../lib/first/libA.dylib",
            ),
        }
        loads = {
            self.mtest: self._loads(
                "14.0",
                "@executable_path/../lib/first",
                "@executable_path/../lib/second",
            ),
            self.lib_a: self._loads("13.5"),
            self.lib_b: self._loads("14.0"),
        }

        runner = self._run_with(dependencies, loads)

        inspected = [Path(call.args[0][2]).resolve() for call in runner.call_args_list]
        self.assertEqual(inspected.count(self.mtest), 2)
        self.assertEqual(inspected.count(self.lib_a), 2)
        self.assertEqual(inspected.count(self.lib_b), 2)
        self.assertNotIn(self.shadow_a, inspected)

    def test_prefix_escape_is_rejected(self) -> None:
        outside = self.prefix.parent / "outside.dylib"
        outside.write_bytes(b"foreign Mach-O fixture\n")
        dependencies = self._dependencies(self.mtest, str(outside))
        with (
            mock.patch.object(
                subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    ["otool"], 0, dependencies, ""
                ),
            ),
            self.assertRaisesRegex(PackageCheckError, "escapes.*scratch prefix"),
        ):
            audit_installed_dependency_closure(
                self.mtest,
                package_platform("darwin", "arm64"),
            )

    def test_installed_root_symlink_escape_is_rejected_before_otool(self) -> None:
        outside = self.prefix.parent / "outside-mtest"
        outside.write_bytes(b"foreign Mach-O fixture\n")
        self.mtest.unlink()
        self.mtest.symlink_to(outside)
        with (
            mock.patch.object(package_consumption, "_run_otool") as run_otool,
            self.assertRaisesRegex(
                PackageCheckError,
                "installed Mach-O root escapes the scratch prefix",
            ),
        ):
            audit_installed_dependency_closure(
                self.mtest,
                package_platform("darwin", "arm64"),
            )
        run_otool.assert_not_called()

    def test_missing_rpath_match_is_rejected(self) -> None:
        dependencies = self._dependencies(self.mtest, "@rpath/missing.dylib")
        loads = self._loads("14.0", "@executable_path/../lib/first")

        def fake_run(
            argv: list[str], **_kwargs: object
        ) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(
                argv,
                0,
                dependencies if argv[1] == "-L" else loads,
                "",
            )

        with (
            mock.patch.object(subprocess, "run", side_effect=fake_run),
            self.assertRaisesRegex(PackageCheckError, "no match.*missing.dylib"),
        ):
            audit_installed_dependency_closure(
                self.mtest,
                package_platform("darwin", "arm64"),
            )

    def test_newer_dependency_minimum_names_its_relative_path(self) -> None:
        dependencies = {
            self.mtest: self._dependencies(self.mtest, "@rpath/libA.dylib"),
            self.lib_a: self._dependencies(self.lib_a),
        }
        loads = {
            self.mtest: self._loads("14.0", "@executable_path/../lib/first"),
            self.lib_a: self._loads("14.1"),
        }
        with self.assertRaisesRegex(
            PackageCheckError,
            r"lib/first/libA\.dylib.*14\.1.*14\.0",
        ):
            self._run_with(dependencies, loads)

    def test_linux_returns_without_invoking_otool(self) -> None:
        with mock.patch.object(subprocess, "run") as run:
            audit_installed_dependency_closure(
                self.mtest,
                package_platform("linux", "x86_64"),
            )
        run.assert_not_called()


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

    @override
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
        with contextlib.redirect_stdout(io.StringIO()):
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
        transcript = TRUTHFUL_TRANSCRIPT.split("=====", maxsplit=1)[0]
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
        with (
            contextlib.redirect_stdout(io.StringIO()),
            self.assertRaises(PackageCheckError),
        ):
            package_consumption.stage_failing_fixture_consumption(
                binary, TRUTHFUL_VERSION
            )
        self.assertTrue(marker.exists(), "stage never executed the binary")


class StageLedgerTests(unittest.TestCase):
    """The gate records what it performed and refuses to overclaim."""

    @override
    def setUp(self) -> None:
        package_consumption.reset_completed_stages()
        self.addCleanup(package_consumption.reset_completed_stages)

    def test_completed_stages_start_empty(self) -> None:
        self.assertEqual(package_consumption.completed_stages(), ())

    def test_stage_roster_names_both_package_forms_assertion_proofs(self) -> None:
        self.assertEqual(
            package_consumption.GATE_STAGE_IDS,
            (
                "build",
                "install",
                "loader-clean",
                "assertion-source",
                "assertion-example",
                "dogfood",
                "failing-fixture",
                "tarball-assertion-source",
                "tarball-assertion-example",
                "tarball",
            ),
        )

    def test_recording_an_unknown_stage_is_rejected(self) -> None:
        with self.assertRaises(PackageCheckError):
            package_consumption.record_completed_stage("polish-the-badge")

    def test_recording_a_stage_twice_is_rejected(self) -> None:
        package_consumption.record_completed_stage("build")
        with self.assertRaises(PackageCheckError):
            package_consumption.record_completed_stage("build")

    def test_a_missing_stage_is_named(self) -> None:
        for stage in package_consumption.GATE_STAGE_IDS:
            if stage != "failing-fixture":
                package_consumption.record_completed_stage(stage)
        with self.assertRaises(PackageCheckError) as caught:
            package_consumption.verify_every_stage_ran()
        self.assertIn("failing-fixture", str(caught.exception))

    def test_a_full_roster_is_accepted(self) -> None:
        for stage in package_consumption.GATE_STAGE_IDS:
            package_consumption.record_completed_stage(stage)
        package_consumption.verify_every_stage_ran()

    def test_the_full_loader_probe_roster_is_accepted(self) -> None:
        package_consumption.verify_loader_probe_roster(
            package_consumption.LOADER_PROBE_FLAGS
        )

    def test_a_skipped_loader_probe_is_named(self) -> None:
        for skipped in package_consumption.LOADER_PROBE_FLAGS:
            with self.subTest(skipped=skipped):
                performed = tuple(
                    flag
                    for flag in package_consumption.LOADER_PROBE_FLAGS
                    if flag != skipped
                )
                with self.assertRaises(PackageCheckError) as caught:
                    package_consumption.verify_loader_probe_roster(performed)
                self.assertIn(skipped, str(caught.exception))

    def test_a_skipped_assertion_optimization_is_named(self) -> None:
        with self.assertRaises(PackageCheckError) as caught:
            package_consumption.verify_assertion_optimization_roster(("-O0",))
        self.assertIn("-O3", str(caught.exception))

    def test_assertion_optimization_roster_is_exact(self) -> None:
        self.assertEqual(
            package_consumption.ASSERTION_OPTIMIZATIONS,
            (("-O0", "o0"), ("-O3", "o3")),
        )


class CallSiteTests(unittest.TestCase):
    """The proofs are invoked, not merely correct.

    A guard mutation shows a guard works; only these tests show the gate calls
    it. Each patches the callee out, so deleting the CALL leaves nothing to
    observe.
    """

    @override
    def setUp(self) -> None:
        package_consumption.reset_completed_stages()
        self.addCleanup(package_consumption.reset_completed_stages)
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.root = Path(self._temp.name)
        self.version = package_consumption.repo_version()
        self.artifact = BuiltArtifact(
            path=self.root / "channel" / "linux-64" / "mtest-x.conda",
            version=self.version,
            build_string="hb0f4dca_0",
            sha256="d" * 64,
            subdir="linux-64",
        )

    @staticmethod
    def _install_prefix(env_dir: Path) -> Path:
        """Create a plausible installed prefix under one scratch env dir."""
        prefix = env_dir / ".pixi" / "envs" / "default"
        (prefix / "bin").mkdir(parents=True, exist_ok=True)
        (prefix / "bin" / "mtest").write_text("", encoding="utf-8")
        (prefix / "conda-meta").mkdir(parents=True, exist_ok=True)
        (prefix / "conda-meta" / "mojo-compiler-1.0.0b2-release.json").write_text(
            "{}", encoding="utf-8"
        )
        return prefix

    def test_install_stage_calls_the_artifact_identity_proof(self) -> None:
        scratch = self.root / "package-check"
        env_dir = scratch / "conda-env"
        prefix = env_dir / ".pixi" / "envs" / "default"
        identity = mock.Mock()
        with (
            mock.patch.multiple(
                package_consumption,
                REPO_ROOT=self.root,
                SCRATCH_ROOT=scratch,
                CONDA_ENV_DIR=env_dir,
                CONDA_CHANNEL_DIR=self.root / "channel",
                _run_streamed=mock.Mock(
                    side_effect=lambda *_a, **_k: (self._install_prefix(env_dir), 0)[1]
                ),
                verify_installed_artifact_identity=identity,
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            package_consumption.stage_install_from_local_channel(self.artifact)
        identity.assert_called_once_with(prefix, self.artifact)

    def test_tarball_stage_calls_the_artifact_identity_proof(self) -> None:
        channel_dir = self.root / "tarball-channel"
        env_dir = self.root / "tarball-env"
        prefix = env_dir / ".pixi" / "envs" / "default"
        artifact_name = f"mtest-{self.version}-hb0f4dca_0.tar.bz2"

        def build_or_install(argv: list[str], **_kwargs: object) -> int:
            """Stand in for rattler-build and pixi install, in that order."""
            if argv[0] == "rattler-build":
                path = channel_dir / "linux-64" / artifact_name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"tarball")
            else:
                self._install_prefix(env_dir)
            return 0

        identity = mock.Mock()
        assertion_probe = mock.Mock()
        assertion_example = mock.Mock()
        smoke = mock.Mock(
            return_value=subprocess.CompletedProcess(
                args=[], returncode=0, stdout=f"mtest {self.version}\n", stderr=""
            )
        )
        with (
            mock.patch.multiple(
                package_consumption,
                REPO_ROOT=self.root,
                TARBALL_CHANNEL_DIR=channel_dir,
                TARBALL_ENV_DIR=env_dir,
                _run_streamed=mock.Mock(side_effect=build_or_install),
                verify_installed_artifact_identity=identity,
                stage_assertion_source_probe=assertion_probe,
                stage_assertion_example=assertion_example,
            ),
            mock.patch.object(subprocess, "run", smoke),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            package_consumption.stage_tarball_fallback_smoke(
                package_platform("linux", "x86_64")
            )
        self.assertEqual(len(identity.call_args_list), 1)
        self.assertEqual(identity.call_args_list[0].args[0], prefix)
        self.assertEqual(identity.call_args_list[0].args[1].path.name, artifact_name)
        assertion_probe.assert_called_once_with(
            prefix,
            "tarball",
            completion_id="tarball-assertion-source",
        )
        assertion_example.assert_called_once_with(
            prefix,
            prefix / "bin" / "mtest",
            allow_installer_group_write=True,
            completion_id="tarball-assertion-example",
        )

    def test_loader_clean_stage_calls_the_probe_roster_check(self) -> None:
        roster = mock.Mock()
        closure = mock.Mock()
        installed = self.root / "bin" / "mtest"
        target = package_platform("linux", "x86_64")

        def fake_run(
            argv: list[str], **_kwargs: object
        ) -> subprocess.CompletedProcess[str]:
            """Answer each loader-clean probe as a healthy install would."""
            if argv[0] == "ldd":
                return subprocess.CompletedProcess(argv, 0, "", "")
            if "--version" in argv:
                return subprocess.CompletedProcess(
                    argv, 0, f"mtest {self.version}\n", ""
                )
            if "--help" in argv:
                return subprocess.CompletedProcess(argv, 0, "usage: mtest\n", "")
            return subprocess.CompletedProcess(argv, 4, "", "discover: no such file\n")

        with (
            mock.patch.multiple(
                package_consumption,
                LOADER_PROBE_CWD=self.root / "loader-probe-cwd",
                verify_loader_probe_roster=roster,
                audit_installed_dependency_closure=closure,
            ),
            mock.patch.object(subprocess, "run", side_effect=fake_run),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            package_consumption.stage_loader_clean_probe(
                installed,
                target,
            )
        roster.assert_called_once_with(package_consumption.LOADER_PROBE_FLAGS)
        closure.assert_called_once_with(installed, target)

    def test_dogfood_stage_drives_the_installed_binary_through_the_probes(
        self,
    ) -> None:
        """Stage 4's body is otherwise the one stage no test executes.

        Every `main` case replaces this stage with a recording double, so
        deleting the `dogfood.verify` call while keeping
        `record_completed_stage("dogfood")` left `verify_every_stage_ran`
        satisfied and the gate exiting 0 claiming probes that never ran. The
        argv matters as much as the call: passing `dogfood.MTEST` instead of
        the installed path would prove `build/mtest`, not the artifact.
        """
        installed = self.root / "prefix" / "bin" / "mtest"
        installed.parent.mkdir(parents=True, exist_ok=True)
        installed.write_text("", encoding="utf-8")
        include = self.root / "include"
        include.mkdir(parents=True, exist_ok=True)
        (include / "mtest.mojoc").write_text("", encoding="utf-8")
        native = self.root / "mtest_exec_native_test.o"
        native.write_text("", encoding="utf-8")
        verify = mock.Mock(return_value=0)

        with (
            mock.patch.multiple(
                package_consumption,
                CHECKOUT_PACKAGE_INCLUDE_DIR=include,
                NATIVE_TEST_OBJECT=native,
            ),
            mock.patch.object(dogfood, "verify", verify),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            package_consumption.stage_suite_run_with_installed_binary(installed)

        verify.assert_called_once_with(str(installed), str(native))
        self.assertIn("dogfood", package_consumption.completed_stages())

    def test_dogfood_stage_refuses_to_record_when_the_probes_fail(self) -> None:
        installed = self.root / "prefix" / "bin" / "mtest"
        installed.parent.mkdir(parents=True, exist_ok=True)
        installed.write_text("", encoding="utf-8")
        include = self.root / "include"
        include.mkdir(parents=True, exist_ok=True)
        (include / "mtest.mojoc").write_text("", encoding="utf-8")
        native = self.root / "mtest_exec_native_test.o"
        native.write_text("", encoding="utf-8")

        with (
            mock.patch.multiple(
                package_consumption,
                CHECKOUT_PACKAGE_INCLUDE_DIR=include,
                NATIVE_TEST_OBJECT=native,
            ),
            mock.patch.object(dogfood, "verify", mock.Mock(return_value=1)),
            contextlib.redirect_stdout(io.StringIO()),
            self.assertRaises(package_consumption.PackageCheckError),
        ):
            package_consumption.stage_suite_run_with_installed_binary(installed)

        self.assertNotIn("dogfood", package_consumption.completed_stages())

    def _patched_main(self, *, skip_recording: str | None = None) -> mock.Mock:
        """Patch every stage with a recording double and return the call log.

        Args:
            skip_recording: A stage id whose double must NOT record itself,
                simulating a stage that silently did not happen.

        Returns:
            A parent mock whose `mock_calls` carry the stage call order.
        """
        parent = mock.Mock()

        def stage(stage_id: str, result: object = None) -> Callable[..., object]:
            def run(*_args: object, **_kwargs: object) -> object:
                parent.stage(stage_id)
                if stage_id != skip_recording:
                    package_consumption.record_completed_stage(stage_id)
                return result

            return run

        install_result = self.root / "prefix" / "bin" / "mtest"
        self._patches = mock.patch.multiple(
            package_consumption,
            host_platform=mock.Mock(return_value=package_platform("linux", "x86_64")),
            stage_build_local_channel=mock.Mock(
                side_effect=stage("build", self.artifact)
            ),
            stage_install_from_local_channel=mock.Mock(
                side_effect=stage("install", install_result)
            ),
            stage_loader_clean_probe=mock.Mock(side_effect=stage("loader-clean")),
            stage_assertion_source_probe=mock.Mock(
                side_effect=stage("assertion-source")
            ),
            stage_assertion_example=mock.Mock(side_effect=stage("assertion-example")),
            stage_suite_run_with_installed_binary=mock.Mock(
                side_effect=stage("dogfood")
            ),
            stage_failing_fixture_consumption=mock.Mock(
                side_effect=stage("failing-fixture")
            ),
            stage_tarball_fallback_smoke=mock.Mock(
                side_effect=lambda *_args, **_kwargs: (
                    stage("tarball-assertion-source")(),
                    stage("tarball-assertion-example")(),
                    stage("tarball")(),
                )[-1]
            ),
        )
        return parent

    def test_main_invokes_every_stage_once_in_the_declared_order(self) -> None:
        parent = self._patched_main()
        out, err = io.StringIO(), io.StringIO()
        with (
            self._patches,
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            code = package_consumption.main()
        self.assertEqual(code, 0, err.getvalue())
        self.assertEqual(
            [call.args[0] for call in parent.stage.call_args_list],
            list(package_consumption.GATE_STAGE_IDS),
        )
        self.assertIn("package-check: OK (linux-64)", out.getvalue())

    def test_main_reports_the_stages_it_actually_performed(self) -> None:
        self._patched_main()
        out = io.StringIO()
        with (
            self._patches,
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            package_consumption.main()
        self.assertIn(
            f"stages performed: {list(package_consumption.GATE_STAGE_IDS)}",
            out.getvalue(),
        )

    def test_main_refuses_to_report_ok_when_a_stage_did_not_happen(self) -> None:
        # The banner must not be able to claim a proof the run never performed.
        for missing_stage in (
            "assertion-source",
            "assertion-example",
            "failing-fixture",
            "tarball-assertion-source",
            "tarball-assertion-example",
        ):
            with self.subTest(missing_stage=missing_stage):
                self._patched_main(skip_recording=missing_stage)
                out, err = io.StringIO(), io.StringIO()
                with (
                    self._patches,
                    contextlib.redirect_stdout(out),
                    contextlib.redirect_stderr(err),
                ):
                    code = package_consumption.main()
                self.assertEqual(code, 1)
                self.assertNotIn("package-check: OK (", out.getvalue())
                self.assertIn(missing_stage, err.getvalue())


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


class AssertionPackageCommandTests(unittest.TestCase):
    def test_assertion_stages_use_only_the_supervised_process_helper(self) -> None:
        expected_calls = (
            (package_consumption.stage_assertion_source_probe, 4),
            (package_consumption.stage_assertion_example, 1),
        )
        for stage, count in expected_calls:
            with self.subTest(stage=stage.__name__):
                source = inspect.getsource(stage)
                self.assertNotIn("subprocess.run(", source)
                self.assertEqual(source.count("_run_assertion_process("), count)

    def test_assertion_example_disables_project_configuration(self) -> None:
        prefix = Path("/prefix")
        stopped = package_consumption.PackageCheckError("stop after argv capture")
        with (
            mock.patch.object(
                package_consumption,
                "validate_assertion_install",
                return_value=prefix / INSTALLED_ASSERTION_SOURCE_ROOT,
            ),
            mock.patch.object(
                package_consumption,
                "assertion_probe_environment",
                return_value={"PATH": "/prefix/bin"},
            ),
            mock.patch.object(
                package_consumption,
                "_run_assertion_process",
                side_effect=stopped,
            ) as run,
            contextlib.redirect_stdout(io.StringIO()),
            self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "stop after argv capture",
            ),
        ):
            package_consumption.stage_assertion_example(
                prefix,
                prefix / "bin/mtest",
            )
        command = run.call_args.args[0]
        self.assertEqual(
            command[:5],
            [
                "/prefix/bin/mtest",
                "--no-config",
                "--no-cache",
                "--show-output",
                "failures",
            ],
        )
        self.assertEqual(command.count("--no-cache"), 1)

    def test_assertion_process_helper_delegates_environment_and_timeout(
        self,
    ) -> None:
        command = ["/prefix/bin/mojo", "build"]
        cwd = Path("/scratch/probe")
        environment = {"PATH": "/prefix/bin:/usr/bin"}
        captured = watchdog.CapturedCommand(
            watchdog.Exited(7),
            "bounded stdout",
            "bounded stderr",
        )
        with mock.patch.object(
            watchdog,
            "run_captured_command",
            return_value=captured,
        ) as run:
            result = package_consumption._run_assertion_process(
                command,
                cwd=cwd,
                env=environment,
                timeout=12.5,
            )

        self.assertEqual(result.args, command)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, "bounded stdout")
        self.assertEqual(result.stderr, "bounded stderr")
        run.assert_called_once_with(
            command,
            source="/prefix/bin/mojo",
            step="package assertion probe",
            timeout_seconds=12.5,
            cwd=cwd,
            env=environment,
        )

    def test_assertion_process_helper_rejects_a_watchdog_timeout(self) -> None:
        captured = watchdog.CapturedCommand(
            watchdog.TimedOut(),
            "",
            "",
        )
        with (
            mock.patch.object(
                watchdog,
                "run_captured_command",
                return_value=captured,
            ),
            self.assertRaisesRegex(PackageCheckError, "exceeded 3.0 seconds"),
        ):
            package_consumption._run_assertion_process(
                ["/prefix/bin/mojo", "build"],
                cwd=Path("/scratch/probe"),
                env={},
                timeout=3.0,
            )

    def test_assertion_process_helper_rejects_signal_death(self) -> None:
        captured = watchdog.CapturedCommand(
            watchdog.Signaled(11),
            "expected semantic diagnostic",
            "",
        )
        with (
            mock.patch.object(
                watchdog,
                "run_captured_command",
                return_value=captured,
            ),
            self.assertRaisesRegex(PackageCheckError, "signal 11"),
        ):
            package_consumption._run_assertion_process(
                ["/prefix/bin/mojo", "build"],
                cwd=Path("/scratch/probe"),
                env={},
                timeout=3.0,
            )

    def test_assertion_process_helper_rejects_incomplete_pipe_drain(self) -> None:
        captured = watchdog.CapturedCommand(
            watchdog.Exited(0),
            "",
            "",
            capture_complete=False,
        )
        with (
            mock.patch.object(
                watchdog,
                "run_captured_command",
                return_value=captured,
            ),
            self.assertRaisesRegex(PackageCheckError, "capture was incomplete"),
        ):
            package_consumption._run_assertion_process(
                ["/prefix/bin/mojo", "build"],
                cwd=Path("/scratch/probe"),
                env={},
                timeout=3.0,
            )

    def test_assertion_process_helper_rejects_truncated_output(self) -> None:
        captured = watchdog.CapturedCommand(
            watchdog.Exited(0),
            watchdog.CAPTURE_TRUNCATION_MARKER,
            "",
        )
        with (
            mock.patch.object(
                watchdog,
                "run_captured_command",
                return_value=captured,
            ),
            self.assertRaisesRegex(PackageCheckError, "output was truncated"),
        ):
            package_consumption._run_assertion_process(
                ["/prefix/bin/mojo", "build"],
                cwd=Path("/scratch/probe"),
                env={},
                timeout=3.0,
            )

    def test_installed_probe_instantiates_every_public_overload(self) -> None:
        source = package_consumption.ASSERTION_PROBE_SOURCE
        self.assertIn('assert_equal("left", "right")', source)
        self.assertIn("assert_equal([1, 2], [1, 2])", source)
        self.assertIn(
            'assert_equal({"key": 1}, {"key": 1})',
            source,
        )
        self.assertIn("assert_equal(1, 1)", source)

    def test_compile_command_uses_absolute_installed_paths(self) -> None:
        prefix = Path("/scratch/prefix")
        self.assertEqual(
            package_consumption.assertion_compile_command(
                prefix,
                Path("/scratch/probe.mojo"),
                Path("/scratch/probe-o0"),
                "-O0",
            ),
            [
                "/scratch/prefix/bin/mojo",
                "build",
                "-O0",
                "-I",
                "/scratch/prefix/share/mtest/companions/assertions/src",
                "/scratch/probe.mojo",
                "-o",
                "/scratch/probe-o0",
            ],
        )

    def test_probe_environment_pins_modular_home_to_installed_prefix(self) -> None:
        prefix = Path("/scratch/prefix")
        environment = package_consumption.assertion_probe_environment(
            prefix,
            package_platform("linux", "x86_64"),
        )
        self.assertEqual(environment["PATH"], "/usr/bin:/bin")
        self.assertEqual(
            environment["MODULAR_HOME"],
            "/scratch/prefix/share/max",
        )
        self.assertEqual(
            environment["LD_LIBRARY_PATH"],
            "/scratch/prefix/lib",
        )
        self.assertEqual(
            environment["HOME"],
            str(
                package_consumption.SCRATCH_ROOT
                / "assertion-environments"
                / "probe"
                / "home"
            ),
        )
        self.assertEqual(
            environment["MODULAR_CACHE_DIR"],
            str(
                package_consumption.SCRATCH_ROOT
                / "assertion-environments"
                / "probe"
                / "cache"
            ),
        )
        self.assertTrue(Path(environment["HOME"]).is_dir())
        self.assertTrue(Path(environment["MODULAR_CACHE_DIR"]).is_dir())
        dev_prefix = str(package_consumption.REPO_ROOT / ".pixi")
        self.assertFalse(any(dev_prefix in value for value in environment.values()))

    def test_probe_environment_uses_the_platform_loader_variable(self) -> None:
        prefix = Path("/scratch/prefix")
        environment = package_consumption.assertion_probe_environment(
            prefix,
            package_platform("darwin", "arm64"),
        )
        self.assertEqual(
            environment["DYLD_LIBRARY_PATH"],
            "/scratch/prefix/lib",
        )
        self.assertNotIn("LD_LIBRARY_PATH", environment)

    def test_installed_consumer_compile_rejects_warnings(self) -> None:
        with self.assertRaisesRegex(
            package_consumption.PackageCheckError,
            "compiler warning",
        ):
            package_consumption.require_warning_free_assertion_compile(
                "consumer.mojo:1:1: warning: shipped warning\n",
                "conda",
                "-O0",
            )

    def test_installed_consumer_compile_rejects_truncated_capture(self) -> None:
        with self.assertRaisesRegex(
            package_consumption.PackageCheckError,
            "output was truncated",
        ):
            package_consumption.require_warning_free_assertion_compile(
                watchdog.CAPTURE_TRUNCATION_MARKER,
                "conda",
                "-O0",
            )


class AssertionReadmeExampleTests(unittest.TestCase):
    def test_extracts_the_only_console_fence_from_assertion_section(self) -> None:
        contents = (
            "# mtest\n\n"
            "## Assertion diagnostics\n\n"
            "```mojo\nassert_equal(1, 2)\n```\n\n"
            "```console\n$ mtest companions/assertions/examples\noutput\n```\n\n"
            "## Usage\n"
        )
        self.assertEqual(
            package_consumption.readme_assertion_example_block(contents),
            "$ mtest companions/assertions/examples\noutput\n",
        )

    def test_extracts_the_only_mojo_fence_from_assertion_section(self) -> None:
        contents = (
            "# mtest\n\n"
            "## Assertion diagnostics\n\n"
            "```mojo\nassert_equal(1, 2)\n```\n\n"
            "```console\n$ mtest companions/assertions/examples\noutput\n```\n\n"
            "## Usage\n"
        )
        self.assertEqual(
            package_consumption.readme_assertion_source_block(contents),
            "assert_equal(1, 2)\n",
        )

    def test_normalizes_only_paths_and_elapsed_times(self) -> None:
        output = (
            "root: /checkout\n"
            "FAIL           companions/assertions/examples/test.mojo  0.07s\n"
            "detail /prefix/share/mtest/companions/assertions/src\n"
            "    |     PASS [ 0.001 ] test_pass\n"
            "    |     FAIL [ 0.082 ] test_fail\n"
            "    | Summary [ 0.083 ] 2 tests run: 1 passed , 1 failed , "
            "0 skipped \n"
            "    | diagnostic payload keeps its trailing space \n"
            "    | \n"
            "===== 1 passed, 1 failed in 2.2s =====\n"
        )

        self.assertEqual(
            package_consumption.normalize_assertion_example(
                output,
                Path("/prefix"),
                Path("/checkout"),
            ),
            "root: <REPO>\n"
            "FAIL           companions/assertions/examples/test.mojo  <TIME>\n"
            "detail <PREFIX>/share/mtest/companions/assertions/src\n"
            "    |     PASS [ <TIME> ] test_pass\n"
            "    |     FAIL [ <TIME> ] test_fail\n"
            "    | Summary [ <TIME> ] 2 tests run: 1 passed , 1 failed , "
            "0 skipped\n"
            "    | diagnostic payload keeps its trailing space \n"
            "    |\n"
            "===== 1 passed, 1 failed in <TIME> =====\n",
        )

    def test_readme_command_prefix_derives_public_paths(self) -> None:
        installed_source = (
            package_consumption.INSTALLED_ASSERTION_SOURCE_RELATIVE.as_posix()
        )
        example_directory = package_consumption.ASSERTION_EXAMPLE.parent.relative_to(
            package_consumption.REPO_ROOT
        ).as_posix()
        self.assertEqual(
            package_consumption.assertion_readme_command_prefix(),
            "$ mtest --no-config --no-cache --show-output failures \\\n"
            f"    -I <PREFIX>/{installed_source} \\\n"
            f"    {example_directory}\n",
        )
        self.assertEqual(
            package_consumption.assertion_readme_command_prefix().count("--no-cache"),
            1,
        )


class AssertionPackageLayoutTests(unittest.TestCase):
    def test_assertion_file_mode_policies_are_exact(self) -> None:
        self.assertEqual(
            package_consumption.PRIMARY_ASSERTION_FILE_MODES,
            (0o644,),
        )
        self.assertEqual(
            package_consumption.TARBALL_ASSERTION_FILE_MODES,
            (0o644, 0o664),
        )

    def _valid_prefix(self, root: Path) -> Path:
        prefix = root.resolve() / "prefix"
        library_suffix = ".dylib" if sys.platform == "darwin" else ".so"
        for relative in package_consumption.INSTALLED_ASSERTION_FILES:
            path = prefix / INSTALLED_ASSERTION_SOURCE_ROOT / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            checkout = (
                package_consumption.REPO_ROOT
                / package_consumption.CHECKOUT_ASSERTION_SOURCE_ROOT.relative_to(
                    package_consumption.REPO_ROOT
                )
                / relative
            )
            path.write_bytes(checkout.read_bytes())
            path.chmod(0o644)
        for directory_name in (
            "share/mtest",
            str(INSTALLED_ASSERTION_SOURCE_ROOT),
            f"{INSTALLED_ASSERTION_SOURCE_ROOT}/mtest",
            f"{INSTALLED_ASSERTION_SOURCE_ROOT}/mtest/assertions",
        ):
            (prefix / directory_name).chmod(0o755)
        mojo = prefix / "bin" / "mojo"
        mojo.parent.mkdir(parents=True)
        mojo.write_text("#!/bin/sh\n", encoding="utf-8")
        mojo.chmod(0o755)
        (prefix / "lib" / "mojo").mkdir(parents=True)
        (prefix / "lib" / f"libAsyncRTMojoBindings{library_suffix}").write_bytes(
            b"runtime"
        )
        config = prefix / "share" / "max" / "modular.cfg"
        config.parent.mkdir(parents=True)
        config.write_text(
            "[max]\n"
            f"package_root = {prefix}\n"
            f"cache_dir = {prefix}/share/max/.max_cache\n"
            "enable_model_ir_cache = true\n"
            "name = MAX Platform\n"
            f"path = {prefix}\n"
            "version = 1.0.0b2\n"
            "[mojo-max]\n"
            f"package_root = {prefix}\n"
            f"compilerrt_path = {prefix}/lib/libKGENCompilerRTShared{library_suffix}\n"
            f"mgprt_path = {prefix}/lib/libMGPRT{library_suffix}\n"
            f"shared_libs = {prefix}/lib/libAsyncRTMojoBindings{library_suffix},"
            f"-Xlinker,-rpath,-Xlinker,{prefix}/lib;\n"
            f"driver_path = {prefix}/bin/mojo\n"
            f"import_path = {prefix}/lib/mojo\n"
            f"jupyter_path = {prefix}/lib/libMojoJupyter{library_suffix}\n"
            f"lldb_path = {prefix}/bin/mojo-lldb\n"
            f"lldb_plugin_path = {prefix}/lib/libMojoLLDB{library_suffix}\n"
            f"lldb_visualizers_path = {prefix}/lib/lldb-visualizers\n"
            f"lldb_vscode_path = {prefix}/bin/mojo-lldb-dap\n"
            f"lsp_server_path = {prefix}/bin/mojo-lsp-server\n"
            f"mblack_path = {prefix}/bin/mblack\n"
            f"repl_entry_point = {prefix}/lib/mojo-repl-entry-point\n"
            f"lld_path = {prefix}/bin/lld;\n",
            encoding="utf-8",
        )
        return prefix

    def test_rejects_changed_installed_source_bytes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            source = (
                prefix
                / INSTALLED_ASSERTION_SOURCE_ROOT
                / "mtest"
                / "assertions"
                / "_mapping.mojo"
            )
            source.write_text("# changed installed bytes\n", encoding="utf-8")
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "source bytes differ",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_accepts_owner_only_prefix_and_share_directories(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            prefix.chmod(0o700)
            (prefix / "share").chmod(0o700)
            package_consumption.validate_assertion_install(prefix)

    def test_valid_prefix_uses_the_darwin_runtime_library_suffix(self) -> None:
        with (
            tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw,
            mock.patch.object(sys, "platform", "darwin"),
        ):
            prefix = self._valid_prefix(Path(raw))
            package_consumption.validate_assertion_install(prefix)

    def test_rejects_a_symlinked_installed_compiler(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            root = Path(raw)
            prefix = self._valid_prefix(root)
            external = root / "external-mojo"
            external.write_text("#!/bin/sh\n", encoding="utf-8")
            external.chmod(0o755)
            mojo = prefix / "bin" / "mojo"
            mojo.unlink()
            mojo.symlink_to(external)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "real regular file",
            ):
                package_consumption.validate_assertion_install(prefix)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_rejects_a_non_regular_extra_entry(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            fifo = prefix / INSTALLED_ASSERTION_SOURCE_ROOT / "unexpected-fifo"
            os.mkfifo(fifo)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "installed assertion entry set",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_tarball_accepts_installer_normalized_group_write(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            source = prefix / INSTALLED_ASSERTION_SOURCE_ROOT / "mtest/__init__.mojo"
            source.chmod(0o664)
            (prefix / INSTALLED_ASSERTION_SOURCE_ROOT / "mtest/assertions").chmod(0o775)
            package_consumption.validate_assertion_install(
                prefix,
                allow_installer_group_write=True,
            )

    def test_primary_package_rejects_group_writable_source(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            source = prefix / INSTALLED_ASSERTION_SOURCE_ROOT / "mtest/__init__.mojo"
            source.chmod(0o664)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "exact mode 644",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_primary_package_accepts_installer_normalized_directories(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            for relative in (
                "share/mtest",
                str(INSTALLED_ASSERTION_SOURCE_ROOT),
                f"{INSTALLED_ASSERTION_SOURCE_ROOT}/mtest",
                f"{INSTALLED_ASSERTION_SOURCE_ROOT}/mtest/assertions",
            ):
                (prefix / relative).chmod(0o775)
            package_consumption.validate_assertion_install(prefix)

    def test_private_probe_diagnostics_require_semantic_rejections(self) -> None:
        with self.assertRaisesRegex(
            package_consumption.PackageCheckError,
            "wrong reason",
        ):
            package_consumption.require_missing_facade_export(
                "unable to locate module 'mtest'\n"
                "from mtest.assertions import BoundedWriter\n",
                "BoundedWriter",
            )
        package_consumption.require_missing_facade_export(
            "package 'assertions' does not contain 'BoundedWriter'",
            "BoundedWriter",
        )
        with self.assertRaisesRegex(
            package_consumption.PackageCheckError,
            "wrong reason",
        ):
            package_consumption.require_missing_runner_module(
                "unable to locate module 'mtest'\n"
                "from mtest.session import run_session\n"
            )
        package_consumption.require_missing_runner_module(
            "error: unable to locate module 'session'"
        )

    def test_rejects_an_extra_public_mojopkg(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            extra = prefix / INSTALLED_ASSERTION_SOURCE_ROOT / "mtest.mojopkg"
            extra.write_text("opaque", encoding="utf-8")
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "installed assertion entry set",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_a_world_writable_source_file(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            source = prefix / INSTALLED_ASSERTION_SOURCE_ROOT / "mtest/__init__.mojo"
            source.chmod(0o666)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "exact mode 644",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_an_executable_source_file(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            source = prefix / INSTALLED_ASSERTION_SOURCE_ROOT / "mtest/__init__.mojo"
            source.chmod(0o744)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "exact mode 644",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_a_world_writable_source_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            directory = prefix / INSTALLED_ASSERTION_SOURCE_ROOT / "mtest/assertions"
            directory.chmod(0o777)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "not world-writable",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_a_world_writable_share_ancestor(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            (prefix / "share").chmod(0o777)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "not world-writable",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_a_world_writable_prefix(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            prefix.chmod(0o777)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "not world-writable",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_tarball_policy_rejects_unsafe_source_modes(self) -> None:
        for mode in (0o666, 0o744):
            with (
                self.subTest(mode=oct(mode)),
                tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw,
            ):
                prefix = self._valid_prefix(Path(raw))
                source = (
                    prefix / INSTALLED_ASSERTION_SOURCE_ROOT / "mtest/__init__.mojo"
                )
                source.chmod(mode)
                with self.assertRaisesRegex(
                    package_consumption.PackageCheckError,
                    "mode 644 or installer-normalized 664",
                ):
                    package_consumption.validate_assertion_install(
                        prefix,
                        allow_installer_group_write=True,
                    )

    def test_tarball_policy_rejects_world_writable_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            directory = prefix / INSTALLED_ASSERTION_SOURCE_ROOT / "mtest"
            directory.chmod(0o777)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "not world-writable",
            ):
                package_consumption.validate_assertion_install(
                    prefix,
                    allow_installer_group_write=True,
                )

    def test_rejects_toolchain_provenance_from_another_prefix(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            config = prefix / "share" / "max" / "modular.cfg"
            config.write_text(
                "[max]\npackage_root = /developer/pixi\n"
                "[mojo-max]\nimport_path = /developer/pixi/lib/mojo\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "modular.cfg",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_compiler_runtime_paths_from_another_prefix(self) -> None:
        options = ("compilerrt_path", "mgprt_path", "shared_libs", "lld_path")
        for option in options:
            with (
                self.subTest(option=option),
                tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw,
            ):
                prefix = self._valid_prefix(Path(raw))
                config = prefix / "share" / "max" / "modular.cfg"
                parser = configparser.ConfigParser(interpolation=None)
                parser.read(config, encoding="utf-8")
                parser.set("mojo-max", option, f"/developer/pixi/{option}")
                with config.open("w", encoding="utf-8") as stream:
                    parser.write(stream)
                with self.assertRaisesRegex(
                    package_consumption.PackageCheckError,
                    "modular.cfg",
                ):
                    package_consumption.validate_assertion_install(prefix)

    def test_rejects_an_import_path_symlink_that_escapes_the_prefix(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            root = Path(raw)
            prefix = self._valid_prefix(root)
            external = root / "external-imports"
            external.mkdir()
            import_path = prefix / "lib" / "mojo"
            import_path.rmdir()
            import_path.symlink_to(external, target_is_directory=True)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "import_path.*inside prefix",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_a_runtime_library_symlink_that_escapes_the_prefix(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            root = Path(raw)
            prefix = self._valid_prefix(root)
            library_suffix = ".dylib" if sys.platform == "darwin" else ".so"
            external = root / f"external-runtime{library_suffix}"
            external.write_bytes(b"foreign runtime")
            runtime = prefix / "lib" / (f"libAsyncRTMojoBindings{library_suffix}")
            runtime.unlink()
            runtime.symlink_to(external)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "runtime library.*inside prefix",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_flag_encoded_shared_library_search_paths(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            config = prefix / "share" / "max" / "modular.cfg"
            parser = configparser.ConfigParser(interpolation=None)
            parser.read(config, encoding="utf-8")
            parser.set(
                "mojo-max",
                "shared_libs",
                parser.get("mojo-max", "shared_libs") + ",-L/developer/pixi/lib",
            )
            with config.open("w", encoding="utf-8") as stream:
                parser.write(stream)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "modular.cfg",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_in_prefix_wrong_shared_library_paths(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            config = prefix / "share" / "max" / "modular.cfg"
            parser = configparser.ConfigParser(interpolation=None)
            parser.read(config, encoding="utf-8")
            parser.set(
                "mojo-max",
                "shared_libs",
                f"{prefix}/lib/libWrong.so,-Xlinker,-rpath,-Xlinker,{prefix}/share;",
            )
            with config.open("w", encoding="utf-8") as stream:
                parser.write(stream)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "shared_libs",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_an_unknown_toolchain_config_option(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            config = prefix / "share" / "max" / "modular.cfg"
            parser = configparser.ConfigParser(interpolation=None)
            parser.read(config, encoding="utf-8")
            parser.set(
                "mojo-max",
                "sanitizer_rt_path",
                "/developer/pixi/lib/libSanitizerRT.so",
            )
            with config.open("w", encoding="utf-8") as stream:
                parser.write(stream)
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "modular.cfg",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_assertion_package_timeouts_cover_cold_compiles(self) -> None:
        self.assertEqual(package_consumption.ASSERTION_COMPILE_TIMEOUT, 120.0)
        self.assertEqual(package_consumption.ASSERTION_EXAMPLE_TIMEOUT, 300.0)

    def test_rejects_commented_or_extended_toolchain_assignments(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            config = prefix / "share" / "max" / "modular.cfg"
            config.write_text(
                "[max]\n"
                f"# package_root = {prefix}\n"
                f"package_root_extra = {prefix}\n"
                "[mojo-max]\n"
                f"package_root = {prefix}/foreign\n"
                f"driver_path = {prefix}/bin/mojo-foreign\n"
                f"import_path = {prefix}/lib/mojo-foreign\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "modular.cfg",
            ):
                package_consumption.validate_assertion_install(prefix)

    def test_rejects_duplicate_toolchain_assignments(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-package-test-") as raw:
            prefix = self._valid_prefix(Path(raw))
            config = prefix / "share" / "max" / "modular.cfg"
            config.write_text(
                "[max]\n"
                f"package_root = {prefix}\n"
                f"package_root = {prefix}/foreign\n"
                "[mojo-max]\n"
                f"package_root = {prefix}\n"
                f"driver_path = {prefix}/bin/mojo\n"
                f"import_path = {prefix}/lib/mojo\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                package_consumption.PackageCheckError,
                "duplicate",
            ):
                package_consumption.validate_assertion_install(prefix)


def main() -> int:
    """Run this module's negative controls as a standalone gate step."""
    result = unittest.main(module=__name__, exit=False, verbosity=0).result
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
