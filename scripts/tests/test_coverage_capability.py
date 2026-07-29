#!/usr/bin/env python3
"""Mutation tests for the fail-closed Mojo coverage-capability probe.

The probe's whole value is its asymmetry: an absent coverage facility is the
quiet passing outcome, and discovering one is the failure. These tests inject
compiler-help text for both branches, pin the exact wording of the absent
branch, and — separately from the branch logic — pin that ``main`` actually
runs the recorded probe commands. A guard nothing invokes is the defect this
suite is here to prevent.
"""

from __future__ import annotations

import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest
from unittest import mock

from scripts.checks import coverage_capability


# A verbatim slice of `mojo build --help` at the pinned 1.0.0b2 toolchain. It
# is deliberately the flag-dense OPTIONS body: if the matcher were sloppy about
# what counts as coverage-shaped, `--print-effective-target` and friends would
# trip it.
MOJO_BUILD_HELP_1_0_0B2 = """    Compilation options
        --optimization-level <LEVEL>, -O, --no-optimization (LEVEL=0)
            Sets the level of optimization to use at compilation.

        --debug-level <LEVEL>, -g (LEVEL=full), -g0 (LEVEL=none)
            Sets the level of debug info to use at compilation.

        --num-threads <NUM>, -j
            Sets the maximum number of threads to use for compilation.

    Target options
        --target-triple <TRIPLE>
            Sets the compilation target triple. Defaults to the host target.

        --target-cpu <CPU>
            Sets the compilation target CPU. Defaults to the host CPU.

        --print-effective-target
            Print the effective target configuration after absorbing all
            command-line flags and exit.
"""

# A verbatim slice of `mojo --help` at the same toolchain.
MOJO_HELP_1_0_0B2 = """OPTIONS
    Diagnostic options
        --version, -v
            Prints the Mojo version and exits.

    Cache management options
        --print-cache-location
            Prints the Mojo compile cache (.mojo_cache) location and exits.

    Common options
        --help, -h
            Displays help information.
"""

# A hypothetical future toolchain that grew the facility. The two flags are the
# spellings such a toolchain would use, in the shape a clang-derived driver
# would use.
MOJO_BUILD_HELP_WITH_COVERAGE = """    Instrumentation options
        --coverage
            Emit source-based coverage instrumentation.

        --profile-instr-generate <PATH>
            Write an instrumented profile to PATH at exit.
"""

ABSENT = (
    (("mojo", "build", "--help"), MOJO_BUILD_HELP_1_0_0B2),
    (("mojo", "--help"), MOJO_HELP_1_0_0B2),
)
DISCOVERED = (
    (("mojo", "build", "--help"), MOJO_BUILD_HELP_WITH_COVERAGE),
    (("mojo", "--help"), MOJO_HELP_1_0_0B2),
)


def _completed(stdout: str) -> subprocess.CompletedProcess[bytes]:
    """Build the CompletedProcess shape `collect_help_text` consumes."""
    return subprocess.CompletedProcess(
        args=["mojo"], returncode=0, stdout=stdout.encode("utf-8"), stderr=b""
    )


class AbsentFacilityBranchTests(unittest.TestCase):
    def test_representative_help_text_names_no_coverage_flag(self) -> None:
        for argv, text in ABSENT:
            with self.subTest(argv=argv):
                self.assertEqual(coverage_capability.discover_coverage_flags(text), ())
                self.assertEqual(coverage_capability.relevant_lines(text), ())

    def test_absent_facility_prints_the_pinned_message(self) -> None:
        message, _code = coverage_capability.evaluate(ABSENT)

        self.assertEqual(
            message,
            "Mojo source coverage unavailable at 1.0.0b2; behavioral map applies",
        )

    def test_absent_facility_exits_zero(self) -> None:
        _message, code = coverage_capability.evaluate(ABSENT)

        self.assertEqual(code, 0)

    def test_the_pinned_message_names_the_manifest_toolchain(self) -> None:
        # The message asserts a fact about one toolchain. If the manifest moves
        # and this constant does not, the message would be a claim about a
        # version nobody probed.
        with (coverage_capability.REPO_ROOT / "pixi.toml").open("rb") as manifest:
            spec = tomllib.load(manifest)["dependencies"]["mojo"]

        self.assertIn(
            f"=={coverage_capability.PINNED_MOJO_VERSION}",
            [part.strip() for part in spec.split(",")],
        )
        self.assertIn(
            coverage_capability.PINNED_MOJO_VERSION,
            coverage_capability.UNAVAILABLE_MESSAGE,
        )


class DiscoveredFacilityBranchTests(unittest.TestCase):
    def test_discovered_flags_are_extracted_exactly(self) -> None:
        self.assertEqual(
            coverage_capability.discover_coverage_flags(MOJO_BUILD_HELP_WITH_COVERAGE),
            ("--coverage", "--profile-instr-generate"),
        )

    def test_discovered_flags_are_echoed_with_an_instruction(self) -> None:
        message, _code = coverage_capability.evaluate(DISCOVERED)

        self.assertIn("mojo build --help: --coverage", message)
        self.assertIn("mojo build --help: --profile-instr-generate", message)
        self.assertIn(coverage_capability.DISCOVERY_INSTRUCTION, message)
        self.assertNotIn(coverage_capability.UNAVAILABLE_MESSAGE, message)

    def test_discovered_flags_exit_nonzero(self) -> None:
        # THE fail-closed contract: finding a coverage facility must break the
        # task, so a toolchain upgrade cannot silently bless an unreviewed
        # metric. Nothing else in this suite asserts this exit code.
        _message, code = coverage_capability.evaluate(DISCOVERED)

        self.assertNotEqual(code, 0)

    def test_a_coverage_mention_without_a_flag_still_fails(self) -> None:
        prose = (
            ("mojo", "--help"),
            "COMMANDS\n        coverage   — Reports source coverage.\n",
        )
        message, code = coverage_capability.evaluate((prose,))

        self.assertNotEqual(code, 0)
        self.assertIn("coverage   — Reports source coverage.", message)


class VersionPinTests(unittest.TestCase):
    def _repo_with_manifest(self, source: str) -> Path:
        raw = tempfile.TemporaryDirectory(prefix="mtest-coverage-capability-")
        self.addCleanup(raw.cleanup)
        repo = Path(raw.name)
        (repo / "pixi.toml").write_text(source, encoding="utf-8")
        return repo

    def test_the_checked_out_manifest_satisfies_the_pin(self) -> None:
        coverage_capability.check_version_pin()

    def test_a_moved_toolchain_pin_is_rejected(self) -> None:
        repo = self._repo_with_manifest(
            '[dependencies]\nmojo = "==1.0.0b3,<2"\n',
        )

        with self.assertRaisesRegex(coverage_capability.ProbeError, "pin moved"):
            coverage_capability.check_version_pin(repo)

    def test_a_manifest_without_a_mojo_pin_is_rejected(self) -> None:
        repo = self._repo_with_manifest('[dependencies]\npython = "3.12.*"\n')

        with self.assertRaisesRegex(coverage_capability.ProbeError, "no string"):
            coverage_capability.check_version_pin(repo)


class ProbeExecutionTests(unittest.TestCase):
    def test_a_missing_compiler_is_a_probe_failure_not_an_absence(self) -> None:
        with (
            mock.patch.object(subprocess, "run", side_effect=FileNotFoundError),
            self.assertRaisesRegex(
                coverage_capability.ProbeError, "executable not found"
            ),
        ):
            coverage_capability.collect_help_text()

    def test_a_nonzero_help_exit_is_a_probe_failure(self) -> None:
        failed = subprocess.CompletedProcess(
            args=["mojo"], returncode=2, stdout=b"", stderr=b""
        )
        with (
            mock.patch.object(subprocess, "run", return_value=failed),
            self.assertRaisesRegex(coverage_capability.ProbeError, "exited 2"),
        ):
            coverage_capability.collect_help_text()

    def test_a_hung_help_invocation_is_a_probe_failure(self) -> None:
        expired = subprocess.TimeoutExpired(cmd=["mojo"], timeout=60)
        with (
            mock.patch.object(subprocess, "run", side_effect=expired),
            self.assertRaisesRegex(coverage_capability.ProbeError, "exceeded"),
        ):
            coverage_capability.collect_help_text()

    def test_the_probe_passes_argv_lists_and_never_a_shell(self) -> None:
        with mock.patch.object(
            subprocess,
            "run",
            return_value=_completed(MOJO_HELP_1_0_0B2),
        ) as run:
            coverage_capability.collect_help_text()

        # Count first: a per-call loop over an empty call list would pass this
        # test without a single command having been spawned.
        self.assertEqual(run.call_count, len(coverage_capability.PROBE_COMMANDS))
        for call in run.call_args_list:
            self.assertIsInstance(call.args[0], list)
            self.assertNotIn("shell", call.kwargs)


class MainInvokesItsOwnProbeTests(unittest.TestCase):
    """`main` must actually run the recorded probe, not just own the logic.

    Mutating a branch proves the branch works; it never proves the branch is
    reached. These tests patch the callees and assert they ran.
    """

    def _run_main(self, texts: dict[tuple[str, ...], str]) -> tuple[int, str, str]:
        calls: list[tuple[str, ...]] = []

        def fake_run(
            argv: list[str], **_kwargs: object
        ) -> subprocess.CompletedProcess[bytes]:
            calls.append(tuple(argv))
            return _completed(texts[tuple(argv)])

        out, err = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(subprocess, "run", side_effect=fake_run),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            code = coverage_capability.main()
        self.assertEqual(tuple(calls), coverage_capability.PROBE_COMMANDS)
        return code, out.getvalue(), err.getvalue()

    def test_main_runs_every_recorded_probe_command(self) -> None:
        code, stdout, _stderr = self._run_main(dict(ABSENT))

        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), coverage_capability.UNAVAILABLE_MESSAGE)

    def test_main_fails_when_its_own_probe_discovers_a_flag(self) -> None:
        code, stdout, stderr = self._run_main(dict(DISCOVERED))

        self.assertNotEqual(code, 0)
        self.assertEqual(stdout, "")
        self.assertIn("--coverage", stderr)

    def test_main_checks_the_version_pin_before_probing(self) -> None:
        with (
            mock.patch.object(
                coverage_capability,
                "check_version_pin",
                side_effect=coverage_capability.ProbeError("pin moved for the test"),
            ) as pin,
            mock.patch.object(coverage_capability, "collect_help_text") as collect,
        ):
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                code = coverage_capability.main()

        pin.assert_called_once_with()
        collect.assert_not_called()
        self.assertEqual(code, 1)
        self.assertIn("pin moved for the test", err.getvalue())


class PixiTaskTests(unittest.TestCase):
    def test_the_diagnostic_task_runs_this_exact_module(self) -> None:
        with (coverage_capability.REPO_ROOT / "pixi.toml").open("rb") as manifest:
            tasks = tomllib.load(manifest)["tasks"]

        self.assertEqual(
            tasks.get("coverage-capability"),
            "python -m scripts.checks.coverage_capability",
        )


class EmptyProbeOutputFailsClosedTests(unittest.TestCase):
    """An exit-0 command that wrote nothing is not evidence of an absence.

    `collect_help_text` treats only a missing executable, a timeout, and a
    nonzero exit as failures, so a renamed subcommand path or a shim that pages
    its help leaves `evaluate` concluding the toolchain names no coverage
    facility having inspected zero bytes -- contradicting the docstring the
    probe's whole value rests on.
    """

    def test_no_reports_at_all_is_a_failure(self) -> None:
        message, code = coverage_capability.evaluate(())

        self.assertEqual(code, 1)
        self.assertIn("no command was probed at all", message)

    def test_an_empty_report_is_a_failure(self) -> None:
        message, code = coverage_capability.evaluate(
            ((("mojo", "build", "--help"), ""), (("mojo", "--help"), ""))
        )

        self.assertEqual(code, 1)
        self.assertIn("mojo build --help: 0 bytes", message)
        self.assertIn("being unable to look is a failure", message)

    def test_one_readable_report_does_not_excuse_an_empty_sibling(self) -> None:
        message, code = coverage_capability.evaluate(
            (
                (("mojo", "build", "--help"), MOJO_BUILD_HELP_1_0_0B2),
                (("mojo", "--help"), ""),
            )
        )

        self.assertEqual(code, 1)
        self.assertIn("mojo --help: 0 bytes", message)
        self.assertNotIn("mojo build --help", message)

    def test_prose_without_a_flag_is_long_enough_to_be_read(self) -> None:
        """A stub too short to be help fails even when it names a flag."""
        message, code = coverage_capability.evaluate(
            ((("mojo", "--help"), "--help\n"),)
        )

        self.assertEqual(code, 1)
        self.assertIn("a `--flag` named", message)

    def test_a_discovery_still_reports_itself_not_an_unreadable_probe(
        self,
    ) -> None:
        """The witness gates the PASS only; a discovery is already a failure."""
        message, code = coverage_capability.evaluate(
            ((("mojo", "--help"), "coverage   \u2014 Reports source coverage."),)
        )

        self.assertEqual(code, 1)
        self.assertIn("Reports source coverage.", message)
        self.assertNotIn("being unable to look", message)

    def test_the_recorded_toolchain_output_satisfies_the_witness(self) -> None:
        self.assertEqual(coverage_capability.unreadable_reports(ABSENT), "")
        self.assertEqual(coverage_capability.evaluate(ABSENT)[1], 0)


if __name__ == "__main__":
    unittest.main()
