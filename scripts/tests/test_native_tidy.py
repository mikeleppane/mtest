#!/usr/bin/env python3
"""Regression tests for deterministic native Clang-Tidy analysis."""

from __future__ import annotations

from pathlib import Path
import subprocess
import unittest
from unittest import mock

from scripts.build.profiles import ProductionProfile
from scripts.checks import native_abi, native_tidy


ROOT = Path(__file__).resolve().parents[2]
EXPECTED_TIDY_UNITS = (
    ("native/mtest_exec_native.c", False),
    ("tests/native/e2e_config_open_fault.c", True),
    ("tests/native/e2e_json_terminal_write_fault.c", True),
    ("tests/native/e2e_state_persistence_fault.c", True),
    ("tests/native/main_open_fault.c", True),
    ("tests/native/native_controls.c", True),
    ("tests/native/stack_protector_canary.c", True),
    ("tests/native/test_exec_native.c", True),
    ("tests/native/test_exec_native_signals.c", True),
)
PROFILE = ProductionProfile(
    name="test",
    system="Linux",
    machine="x86_64",
    mojo_cpu="x86-64",
    mojo_triple=None,
    c_flags=("-march=x86-64", "-mtune=generic"),
    deployment_target=None,
)
LINUX_DRIVER_OUTPUT = """
clang version 18.1.8
 "/opt/clang/bin/clang-18" "-cc1" "-triple" "x86_64-conda-linux-gnu" \
"-resource-dir" "/opt/clang/lib/clang/18" "-isystem" "/usr/include" \
"-x" "c" "/tmp/empty.c"
"""
DARWIN_DRIVER_OUTPUT = """
Apple clang version 18.1.8
 "/opt/clang/bin/clang-18" "-cc1" "-triple" "arm64-apple-macosx14.0.0" \
"-resource-dir" "/opt/clang/lib/clang/18" "-isysroot" \
"/Applications/Xcode.app/SDKs/MacOSX.sdk" "-x" "c" "/tmp/empty.c"
"""


class NativeTidyTests(unittest.TestCase):
    """Pin the complete analyzer matrix and compiler context."""

    def test_translation_unit_matrix_is_sorted_and_exact(self) -> None:
        self.assertEqual(
            tuple(
                (unit.source.relative_to(ROOT).as_posix(), unit.testing)
                for unit in native_tidy.translation_units()
            ),
            EXPECTED_TIDY_UNITS,
        )

    def test_new_tracked_c_appears_as_a_testing_translation_unit(self) -> None:
        new_source = ROOT / "tests" / "native" / "new_fault_driver.c"
        sources = (
            ROOT / "native" / "mtest_exec_native.c",
            ROOT / "native" / "mtest_exec_native.h",
            new_source,
        )
        with mock.patch.object(
            native_tidy,
            "tracked_native_sources",
            return_value=sources,
        ):
            units = native_tidy.translation_units()

        self.assertEqual(
            units,
            (
                native_tidy.TranslationUnit(sources[0], testing=False),
                native_tidy.TranslationUnit(new_source, testing=True),
            ),
        )

    def test_root_config_owns_analyzer_only_selection(self) -> None:
        self.assertEqual(
            (ROOT / ".clang-tidy").read_text(encoding="utf-8"),
            "Checks: >-\n"
            "  -*,\n"
            "  clang-analyzer-*,\n"
            "  -clang-analyzer-security.insecureAPI."
            "DeprecatedOrUnsafeBufferHandling\n"
            "WarningsAsErrors: '*'\n"
            "SystemHeaders: false\n"
            "FormatStyle: file\n",
        )

    def test_linux_compiler_context_is_exact(self) -> None:
        self.assertEqual(
            native_tidy.parse_compiler_context(LINUX_DRIVER_OUTPUT),
            native_tidy.CompilerContext(
                target="x86_64-conda-linux-gnu",
                resource_dir=Path("/opt/clang/lib/clang/18"),
                sysroot=None,
            ),
        )

    def test_darwin_compiler_context_is_exact(self) -> None:
        self.assertEqual(
            native_tidy.parse_compiler_context(DARWIN_DRIVER_OUTPUT),
            native_tidy.CompilerContext(
                target="arm64-apple-macosx14.0.0",
                resource_dir=Path("/opt/clang/lib/clang/18"),
                sysroot=Path("/Applications/Xcode.app/SDKs/MacOSX.sdk"),
            ),
        )

    def test_compiler_context_rejects_missing_and_duplicate_values(self) -> None:
        cases = (
            (
                LINUX_DRIVER_OUTPUT.replace(
                    ' "-triple" "x86_64-conda-linux-gnu"',
                    "",
                ),
                "one -triple",
            ),
            (
                LINUX_DRIVER_OUTPUT.replace(
                    ' "-resource-dir" "/opt/clang/lib/clang/18"',
                    ' "-resource-dir" "/one" "-resource-dir" "/two"',
                ),
                "one -resource-dir",
            ),
            (
                DARWIN_DRIVER_OUTPUT.replace(
                    ' "-isysroot" "/Applications/Xcode.app/SDKs/MacOSX.sdk"',
                    ' "-isysroot" "/one" "-isysroot" "/two"',
                ),
                "at most one -isysroot",
            ),
        )
        for output, message in cases:
            with (
                self.subTest(message=message),
                self.assertRaisesRegex(SystemExit, message),
            ):
                native_tidy.parse_compiler_context(output)

    def test_compiler_context_probe_uses_profile_and_c_language(self) -> None:
        completed = subprocess.CompletedProcess(
            ["clang"],
            0,
            "",
            LINUX_DRIVER_OUTPUT,
        )
        with mock.patch.object(native_tidy, "run", return_value=completed) as run:
            context = native_tidy.compiler_context("clang", PROFILE)

        self.assertEqual(context.target, "x86_64-conda-linux-gnu")
        command = run.call_args.args[0]
        self.assertEqual(command[0], "clang")
        self.assertIn("-###", command)
        self.assertIn("-fsyntax-only", command)
        self.assertIn("-march=x86-64", command)
        self.assertIn("-mtune=generic", command)
        self.assertEqual(command[-3:-1], ["-x", "c"])
        self.assertTrue(Path(command[-1]).name.endswith(".c"))

    def test_commands_share_strict_profile_and_linux_context(self) -> None:
        unit = native_tidy.TranslationUnit(
            ROOT / "native" / "mtest_exec_native.c",
            testing=False,
        )
        context = native_tidy.CompilerContext(
            target="x86_64-conda-linux-gnu",
            resource_dir=Path("/opt/clang/lib/clang/18"),
            sysroot=None,
        )

        parse = native_tidy.parse_command("clang", unit, PROFILE, context)
        tidy = native_tidy.tidy_command(unit, PROFILE, context)

        compiler_argv = [
            *native_tidy.STRICT_FLAGS,
            *PROFILE.c_flags,
            "--target=x86_64-conda-linux-gnu",
            "-resource-dir",
            "/opt/clang/lib/clang/18",
            "-DMTEST_EXEC_TESTING=0",
            "-I",
            str(ROOT / "native"),
        ]
        self.assertEqual(
            parse,
            ["clang", *compiler_argv, "-fsyntax-only", str(unit.source)],
        )
        self.assertEqual(
            tidy,
            [
                "clang-tidy",
                str(unit.source),
                "--quiet",
                "--",
                *compiler_argv,
            ],
        )
        self.assertNotIn("-checks", tidy)
        self.assertNotIn("--checks", tidy)

    def test_commands_share_darwin_sysroot(self) -> None:
        unit = native_tidy.TranslationUnit(
            ROOT / "tests" / "native" / "native_controls.c",
            testing=True,
        )
        context = native_tidy.CompilerContext(
            target="arm64-apple-macosx14.0.0",
            resource_dir=Path("/opt/clang/lib/clang/18"),
            sysroot=Path("/Applications/Xcode.app/SDKs/MacOSX.sdk"),
        )

        for command in (
            native_tidy.parse_command("clang", unit, PROFILE, context),
            native_tidy.tidy_command(unit, PROFILE, context),
        ):
            self.assertIn("--target=arm64-apple-macosx14.0.0", command)
            self.assertIn("-resource-dir", command)
            self.assertIn("/opt/clang/lib/clang/18", command)
            self.assertIn("-isysroot", command)
            self.assertIn("/Applications/Xcode.app/SDKs/MacOSX.sdk", command)
            self.assertIn("-DMTEST_EXEC_TESTING=1", command)

    def test_every_unit_runs_parse_then_analysis_with_exact_variant(self) -> None:
        context = native_tidy.CompilerContext(
            target="x86_64-conda-linux-gnu",
            resource_dir=Path("/opt/clang/lib/clang/18"),
            sysroot=None,
        )
        completed = subprocess.CompletedProcess(["tool"], 0, "", "")
        with mock.patch.object(
            native_tidy,
            "run",
            return_value=completed,
        ) as run:
            native_tidy.analyze_units(
                "clang",
                native_tidy.translation_units(),
                PROFILE,
                context,
            )

        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(len(commands), 2 * len(EXPECTED_TIDY_UNITS))
        for index, (relative, testing) in enumerate(EXPECTED_TIDY_UNITS):
            parse, tidy = commands[index * 2 : index * 2 + 2]
            self.assertEqual(parse[0], "clang")
            self.assertIn("-fsyntax-only", parse)
            self.assertEqual(parse[-1], str(ROOT / relative))
            self.assertEqual(tidy[:2], ["clang-tidy", str(ROOT / relative)])
            self.assertNotIn("-checks", tidy)
            expected_define = f"-DMTEST_EXEC_TESTING={int(testing)}"
            self.assertIn(expected_define, parse)
            self.assertIn(expected_define, tidy)

    def test_parse_smoke_failure_stops_before_analysis(self) -> None:
        unit = native_tidy.translation_units()[0]
        failed = subprocess.CompletedProcess(["clang"], 1, "", "parse diagnostic")
        with (
            mock.patch.object(native_tidy, "run", return_value=failed) as run,
            self.assertRaisesRegex(SystemExit, "parse smoke failed"),
        ):
            native_tidy.analyze_units(
                "clang",
                (unit,),
                PROFILE,
                native_tidy.CompilerContext(
                    "x86_64-conda-linux-gnu",
                    Path("/opt/clang/lib/clang/18"),
                    None,
                ),
            )
        run.assert_called_once()

    def test_analysis_failure_exits_nonzero(self) -> None:
        unit = native_tidy.translation_units()[0]
        completed = subprocess.CompletedProcess(["clang"], 0, "", "")
        failed = subprocess.CompletedProcess(
            ["clang-tidy"],
            1,
            "",
            "analysis diagnostic",
        )
        with (
            mock.patch.object(native_tidy, "run", side_effect=(completed, failed)),
            self.assertRaisesRegex(SystemExit, "analysis failed"),
        ):
            native_tidy.analyze_units(
                "clang",
                (unit,),
                PROFILE,
                native_tidy.CompilerContext(
                    "x86_64-conda-linux-gnu",
                    Path("/opt/clang/lib/clang/18"),
                    None,
                ),
            )

    def test_tool_versions_are_both_pinned_before_analysis(self) -> None:
        clang = subprocess.CompletedProcess(
            ["clang", "--version"],
            0,
            "clang version 18.1.8\n",
            "",
        )
        tidy = subprocess.CompletedProcess(
            ["clang-tidy", "--version"],
            0,
            "LLVM version 18.1.8\n",
            "",
        )
        with mock.patch.object(
            native_tidy,
            "run",
            side_effect=(clang, tidy),
        ) as run:
            native_tidy.require_toolchain("clang")

        self.assertEqual(
            [call.args[0] for call in run.call_args_list],
            [["clang", "--version"], ["clang-tidy", "--version"]],
        )

    def test_tool_version_mismatch_fails_closed(self) -> None:
        pinned = subprocess.CompletedProcess(
            ["tool", "--version"],
            0,
            "LLVM version 18.1.8\n",
            "",
        )
        wrong = subprocess.CompletedProcess(
            ["tool", "--version"],
            0,
            "LLVM version 18.1.80\n",
            "",
        )
        for results in ((wrong,), (pinned, wrong)):
            with (
                self.subTest(results=results),
                mock.patch.object(native_tidy, "run", side_effect=results),
                self.assertRaisesRegex(SystemExit, "expected .* 18.1.8"),
            ):
                native_tidy.require_toolchain("clang")

    def test_main_verifies_versions_before_context_and_analysis(self) -> None:
        events: list[str] = []
        context = native_tidy.CompilerContext(
            "x86_64-conda-linux-gnu",
            Path("/opt/clang/lib/clang/18"),
            None,
        )

        def require_toolchain(cc: str) -> None:
            self.assertEqual(cc, "clang")
            events.append("versions")

        def compiler_context(
            cc: str,
            profile: ProductionProfile,
        ) -> native_tidy.CompilerContext:
            self.assertEqual(cc, "clang")
            self.assertEqual(profile, PROFILE)
            events.append("context")
            return context

        def analyze_units(
            cc: str,
            units: tuple[native_tidy.TranslationUnit, ...],
            profile: ProductionProfile,
            got_context: native_tidy.CompilerContext,
        ) -> None:
            self.assertEqual(cc, "clang")
            self.assertEqual(units, native_tidy.translation_units())
            self.assertEqual(profile, PROFILE)
            self.assertEqual(got_context, context)
            events.append("analysis")

        with (
            mock.patch.dict("os.environ", {"CC": "clang"}),
            mock.patch.object(
                native_tidy,
                "require_toolchain",
                side_effect=require_toolchain,
            ),
            mock.patch.object(
                native_abi,
                "current_profile",
                return_value=PROFILE,
            ),
            mock.patch.object(
                native_tidy,
                "compiler_context",
                side_effect=compiler_context,
            ),
            mock.patch.object(
                native_tidy,
                "analyze_units",
                side_effect=analyze_units,
            ),
        ):
            self.assertEqual(native_tidy.main(), 0)

        self.assertEqual(events, ["versions", "context", "analysis"])


if __name__ == "__main__":
    unittest.main()
