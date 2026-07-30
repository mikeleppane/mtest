#!/usr/bin/env python3
"""Regression tests for native lifecycle build command construction."""

from __future__ import annotations

from contextlib import redirect_stdout
from io import StringIO
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts.build import native as native_build
from scripts.build.profiles import ProductionProfile, host_profile, load_profiles
from scripts.checks import native as native_check
from scripts.checks import native_abi


EXPECTED_WARNING_FLAGS = (
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wpedantic",
    "-Wconversion",
    "-Wsign-conversion",
    "-Wshadow",
    "-Wstrict-prototypes",
    "-Wmissing-prototypes",
    "-Wformat=2",
    "-Wundef",
    "-Wcast-qual",
    "-Wwrite-strings",
    "-Wvla",
    "-Wimplicit-fallthrough",
    "-Wdouble-promotion",
    "-Wnull-dereference",
    "-Wswitch-enum",
    "-Wswitch-default",
    "-Wcast-align",
    "-Wbad-function-cast",
    "-Wmissing-noreturn",
    "-Wredundant-decls",
    "-Walloca",
    "-Warray-bounds",
    "-Wconditional-uninitialized",
    "-Wunreachable-code-aggressive",
)


class NativeCheckCommandTests(unittest.TestCase):
    """Keep Darwin lifecycle links independent of the pinned Clang driver."""

    def test_repository_root_is_exact(self) -> None:
        root = Path(__file__).resolve().parents[2]
        self.assertEqual(native_check.ROOT, root)
        self.assertEqual(
            native_abi.PRODUCTION_OBJECT,
            root / "build/native/mtest_exec_native.o",
        )

    def test_strict_inventory_requires_strong_stack_protection(self) -> None:
        self.assertIn("-fstack-protector-strong", native_abi.STRICT_FLAGS)
        self.assertNotIn("-fstack-protector", native_abi.STRICT_FLAGS)

    def test_curated_warning_inventory_is_exact_and_ordered(self) -> None:
        self.assertEqual(
            tuple(flag for flag in native_abi.STRICT_FLAGS if flag.startswith("-W")),
            EXPECTED_WARNING_FLAGS,
        )

    def test_curated_warning_inventory_rejects_removal_and_addition(self) -> None:
        original = native_abi.STRICT_FLAGS_FILE.read_text(encoding="utf-8")
        mutations = (
            original.replace("-Wextra\n", "", 1),
            original.replace("-Wextra\n", "-Wextra\n-Wunknown-warning\n", 1),
        )
        for index, text in enumerate(mutations):
            with tempfile.TemporaryDirectory(
                prefix=f"mtest-warning-flags-{index}-"
            ) as raw_tmp:
                inventory = Path(raw_tmp) / "native_strict_flags.txt"
                inventory.write_text(text, encoding="utf-8")
                with (
                    self.subTest(mutation=index),
                    self.assertRaisesRegex(
                        SystemExit,
                        "curated warning flags differ",
                    ),
                ):
                    native_abi.load_strict_flags(inventory)

    def test_linux_stack_check_names_every_protected_function(self) -> None:
        disassembly = """
0000000000000010 <mtest_exec_process_open>:
  10: e8 00 00 00 00 call 15 <mtest_exec_process_open+0x5>
      11: R_X86_64_PLT32 __stack_chk_fail-0x4
0000000000000020 <mtest_exec_process_close>:
  20: c3 ret
0000000000000030 <mtest_exec_process_poll>:
  30: e8 00 00 00 00 call 35 <mtest_exec_process_poll+0x5>
      31: R_X86_64_PLT32 __stack_chk_fail-0x4
"""
        self.assertEqual(
            native_abi.protected_function_names(
                disassembly,
                symbol="__stack_chk_fail",
                platform="linux",
            ),
            ("mtest_exec_process_open", "mtest_exec_process_poll"),
        )

    def test_darwin_stack_check_names_every_protected_function(self) -> None:
        disassembly = """
(__TEXT,__text) section
_mtest_exec_runtime_open:
0000000000000000 stp x29, x30, [sp, #-0x10]!
0000000000000004 bl 0x0000000000000004
0000000000000008 ret
_mtest_exec_process_close:
000000000000000c ret
_mtest_exec_process_poll:
0000000000000010 stp x29, x30, [sp, #-0x10]!
0000000000000014 bl 0x0000000000000014
0000000000000018 ret
"""
        relocations = """
Relocation information (__TEXT,__text) 2 entries
address  pcrel length extern type    scattered symbolnum/value
00000004 True  long   True   BR26    False     ___stack_chk_fail
00000014 True  long   True   BR26    False     ___stack_chk_fail
"""
        self.assertEqual(
            native_abi.protected_function_names(
                disassembly,
                symbol="___stack_chk_fail",
                platform="darwin",
                relocations=relocations,
            ),
            ("mtest_exec_process_poll", "mtest_exec_runtime_open"),
        )

    def test_darwin_relocations_map_at_function_range_boundaries(self) -> None:
        disassembly = """
(__TEXT,__text) section
_mtest_exec_first:
0000000000000000 nop
0000000000000004 bl 0x0000000000000004
_mtest_exec_second:
0000000000000008 bl 0x0000000000000008
000000000000000c ret
"""
        relocations = """
Relocation information (__TEXT,__text) 2 entries
address  pcrel length extern type    scattered symbolnum/value
00000004 True  long   True   BR26    False     ___stack_chk_fail
00000008 True  long   True   BR26    False     ___stack_chk_fail
"""
        self.assertEqual(
            native_abi.protected_function_names(
                disassembly,
                symbol="___stack_chk_fail",
                platform="darwin",
                relocations=relocations,
            ),
            ("mtest_exec_first", "mtest_exec_second"),
        )

    def test_stack_symbol_must_be_a_complete_disassembly_token(self) -> None:
        disassembly = """
0000000000000010 <mtest___stack_chk_fail_probe>:
  10: c3 ret
"""
        self.assertEqual(
            native_abi.protected_function_names(
                disassembly,
                symbol="__stack_chk_fail",
                platform="linux",
            ),
            (),
        )

    def test_darwin_non_text_target_relocation_is_rejected(self) -> None:
        disassembly = """
(__TEXT,__text) section
_mtest_exec_process_open:
0000000000000000 bl 0x0000000000000000
"""
        relocations = """
Relocation information (__DATA,__data) 1 entries
address  pcrel length extern type    scattered symbolnum/value
00000000 True  long   True   BR26    False     ___stack_chk_fail
"""
        with self.assertRaisesRegex(
            SystemExit,
            r"stack-check relocation.*outside \(__TEXT,__text\)",
        ):
            native_abi.protected_function_names(
                disassembly,
                symbol="___stack_chk_fail",
                platform="darwin",
                relocations=relocations,
            )

    def test_darwin_malformed_section_cannot_inherit_text_context(self) -> None:
        disassembly = """
(__TEXT,__text) section
_mtest_exec_process_open:
0000000000000000 bl 0x0000000000000000
"""
        relocations = """
Relocation information (__TEXT,__text) 1 entries
address  pcrel length extern type    scattered symbolnum/value
Relocation information (__DATA,__data): 1 entries
00000000 True  long   True   BR26    False     ___stack_chk_fail
"""
        with self.assertRaisesRegex(
            SystemExit,
            r"unparsed Darwin relocation section header.*__DATA,__data",
        ):
            native_abi.protected_function_names(
                disassembly,
                symbol="___stack_chk_fail",
                platform="darwin",
                relocations=relocations,
            )

    def test_darwin_partial_stack_symbol_is_not_artifact_evidence(self) -> None:
        disassembly = """
(__TEXT,__text) section
_mtest_exec_process_open:
0000000000000000 bl 0x0000000000000000
"""
        relocations = """
Relocation information (__TEXT,__text) 1 entries
address  pcrel length extern type    scattered symbolnum/value
00000000 True  long   True   BR26    False     ___stack_chk_fail_probe
"""
        self.assertEqual(
            native_abi.protected_function_names(
                disassembly,
                symbol="___stack_chk_fail",
                platform="darwin",
                relocations=relocations,
            ),
            (),
        )

    def test_darwin_raw_target_in_unparsed_relocation_fails_closed(self) -> None:
        disassembly = """
(__TEXT,__text) section
_mtest_exec_process_open:
0000000000000000 bl 0x0000000000000000
"""
        relocations = """
Relocation information (__TEXT,__text) 1 entries
address  pcrel length extern type    scattered symbolnum/value
00000000 True long True BR26 ___stack_chk_fail
"""
        with self.assertRaisesRegex(
            SystemExit,
            r"unparsed Darwin relocation.*___stack_chk_fail.*00000000",
        ):
            native_abi.protected_function_names(
                disassembly,
                symbol="___stack_chk_fail",
                platform="darwin",
                relocations=relocations,
            )

    def test_darwin_target_relocation_address_must_match_a_function(self) -> None:
        disassembly = """
(__TEXT,__text) section
_mtest_exec_process_open:
0000000000000000 bl 0x0000000000000000
0000000000000004 ret
"""
        relocations = """
Relocation information (__TEXT,__text) 1 entries
address  pcrel length extern type    scattered symbolnum/value
00000020 True  long   True   BR26    False     ___stack_chk_fail
"""
        with self.assertRaisesRegex(
            SystemExit,
            r"relocation address 0x20.*does not map.*mtest_exec_process_open",
        ):
            native_abi.protected_function_names(
                disassembly,
                symbol="___stack_chk_fail",
                platform="darwin",
                relocations=relocations,
            )

    def test_darwin_ambiguous_function_ranges_fail_closed(self) -> None:
        disassembly = """
(__TEXT,__text) section
_mtest_exec_first:
0000000000000000 bl 0x0000000000000000
_mtest_exec_alias:
0000000000000000 bl 0x0000000000000000
"""
        relocations = """
Relocation information (__TEXT,__text) 1 entries
address  pcrel length extern type    scattered symbolnum/value
00000000 True  long   True   BR26    False     ___stack_chk_fail
"""
        with self.assertRaisesRegex(
            SystemExit,
            r"ambiguous Darwin function start 0x0.*"
            r"mtest_exec_alias, mtest_exec_first",
        ):
            native_abi.protected_function_names(
                disassembly,
                symbol="___stack_chk_fail",
                platform="darwin",
                relocations=relocations,
            )

    def test_empty_protected_set_names_every_parsed_function(self) -> None:
        disassembly = """
(__TEXT,__text) section
_mtest_exec_process_open:
0000000000000000 ret
_mtest_exec_process_close:
0000000000000004 ret
"""
        relocations = """
Relocation information (__TEXT,__text) 1 entries
address  pcrel length extern type    scattered symbolnum/value
00000000 True  long   True   BR26    False     ___stack_chk_fail_probe
"""
        with self.assertRaisesRegex(
            SystemExit,
            "no stack-check relocations mapped to functions.*"
            "mtest_exec_process_close, mtest_exec_process_open",
        ):
            native_abi.require_protected_functions(
                disassembly,
                symbol="___stack_chk_fail",
                platform="darwin",
                relocations=relocations,
            )

    def test_disassembly_drift_reports_that_no_functions_were_parsed(self) -> None:
        with self.assertRaisesRegex(
            SystemExit,
            "Darwin disassembly parsed no function ranges",
        ):
            native_abi.require_protected_functions(
                "(__TEXT,__text) section\n",
                symbol="___stack_chk_fail",
                platform="darwin",
                relocations=(
                    "Relocation information (__TEXT,__text) 0 entries\n"
                    "address pcrel length extern type scattered symbolnum/value\n"
                ),
            )

    def test_main_reports_sorted_stack_protected_functions(self) -> None:
        existing = Path(__file__)
        expected_testing = native_abi.PRODUCTION_SYMBOLS | native_abi.TEST_ONLY_SYMBOLS
        output = StringIO()
        with (
            mock.patch.object(native_abi, "SOURCE_FILES", (existing,)),
            mock.patch.object(native_abi, "PRODUCTION_OBJECT", existing),
            mock.patch.object(native_abi, "TESTING_OBJECT", existing),
            mock.patch.object(
                native_abi,
                "load_strict_flags",
                return_value=native_abi.STRICT_FLAGS,
            ),
            mock.patch.object(native_abi, "compiler", return_value="clang"),
            mock.patch.object(
                native_abi,
                "current_profile",
                return_value=mock.sentinel.profile,
            ),
            mock.patch.object(
                native_abi,
                "defined_symbols",
                side_effect=(native_abi.PRODUCTION_SYMBOLS, expected_testing),
            ),
            mock.patch.object(
                native_abi,
                "verify_stack_protector",
                return_value=(
                    "mtest_exec_process_poll",
                    "mtest_exec_runtime_open",
                ),
            ),
            redirect_stdout(output),
        ):
            self.assertEqual(native_abi.main(), 0)

        self.assertIn(
            "native-abi-check: stack-protected functions: "
            "mtest_exec_process_poll, mtest_exec_runtime_open\n",
            output.getvalue(),
        )

    def test_copied_inventory_without_strong_flag_is_rejected(self) -> None:
        retained = [
            flag
            for flag in native_abi.STRICT_FLAGS_FILE.read_text(
                encoding="utf-8"
            ).splitlines()
            if flag.strip() != "-fstack-protector-strong"
        ]
        with tempfile.TemporaryDirectory(prefix="mtest-native-flags-") as raw_tmp:
            inventory = Path(raw_tmp) / "native_strict_flags.txt"
            inventory.write_text("\n".join(retained) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(
                SystemExit,
                "missing required flag -fstack-protector-strong",
            ):
                native_abi.main(strict_flags_file=inventory)

    def test_stack_canary_has_four_way_strong_flag_control(self) -> None:
        cc = native_abi.compiler()
        profiles = load_profiles()
        linux = host_profile(
            system="Linux",
            machine="x86_64",
            profiles=profiles,
        )
        darwin = host_profile(
            system="Darwin",
            machine="arm64",
            profiles=profiles,
        )

        def assembly(
            profile: ProductionProfile,
            *,
            strong: bool,
            target: str,
        ) -> tuple[list[str], str]:
            flags = (
                native_abi.STRICT_FLAGS
                if strong
                else tuple(
                    flag
                    for flag in native_abi.STRICT_FLAGS
                    if flag != "-fstack-protector-strong"
                )
            )
            command = [
                cc,
                f"--target={target}",
                *flags,
                *profile.c_flags,
                "-S",
                str(native_abi.CANARY_SOURCE),
                "-o",
                "-",
            ]
            compiled = native_abi.run(command)
            self.assertEqual(compiled.returncode, 0, compiled.stdout)
            return command, compiled.stdout

        cases = (
            (
                linux,
                "x86_64-unknown-linux-gnu",
                ("-march=x86-64", "-mtune=generic"),
                "__stack_chk_fail",
            ),
            (
                darwin,
                "arm64-apple-macosx14.0.0",
                ("-mcpu=apple-m1", "-mmacosx-version-min=14.0"),
                "___stack_chk_fail",
            ),
        )
        for profile, target, profile_flags, symbol in cases:
            with self.subTest(profile=profile.name):
                self.assertEqual(profile.c_flags, profile_flags)
                positive_command, positive = assembly(
                    profile,
                    strong=True,
                    target=target,
                )
                negative_command, negative = assembly(
                    profile,
                    strong=False,
                    target=target,
                )
                for command in (positive_command, negative_command):
                    self.assertEqual(
                        command[:2],
                        [cc, f"--target={target}"],
                    )
                    self.assertEqual(
                        tuple(command[-6:-4]),
                        profile_flags,
                    )
                self.assertIn(symbol, positive)
                self.assertNotIn(symbol, negative)

    def test_production_shell_ignores_ambient_compiler_flags(self) -> None:
        profile = host_profile(
            system=platform.system(),
            machine=platform.machine(),
            profiles=load_profiles(),
        )
        with tempfile.TemporaryDirectory(prefix="mtest-native-command-") as raw_tmp:
            tmp = Path(raw_tmp)
            build_scripts = tmp / "scripts" / "build"
            build_scripts.mkdir(parents=True)
            for source in (
                native_build.ROOT / "scripts" / "build" / "production_build.sh",
                native_abi.STRICT_FLAGS_FILE,
                native_build.ROOT / "scripts" / "build" / "production_profiles.txt",
            ):
                shutil.copyfile(source, build_scripts / source.name)
            (tmp / "native").mkdir()
            (tmp / "native" / "mtest_exec_native.c").write_text(
                "int command_capture_only;\n",
                encoding="ascii",
            )
            fake_bin = tmp / "bin"
            fake_bin.mkdir()
            capture = tmp / "clang.args"
            fake_clang = fake_bin / "clang"
            fake_clang.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'printf \'%s\\n\' "$@" >"$MTEST_COMMAND_CAPTURE"\n'
                "output=''\n"
                "while [[ $# -gt 0 ]]; do\n"
                "  if [[ \"$1\" == '-o' ]]; then\n"
                '    output="$2"\n'
                "    shift 2\n"
                "  else\n"
                "    shift\n"
                "  fi\n"
                "done\n"
                ': >"$output"\n',
                encoding="ascii",
            )
            fake_clang.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
                "MTEST_COMMAND_CAPTURE": str(capture),
                "CFLAGS": "-march=native -DPOISON_CFLAGS",
                "CPPFLAGS": "-DPOISON_CPPFLAGS",
            }
            completed = subprocess.run(
                ["bash", str(build_scripts / "production_build.sh"), "native"],
                cwd=tmp,
                check=False,
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            command = capture.read_text(encoding="utf-8").splitlines()
        for flag in profile.c_flags:
            self.assertIn(flag, command)
        self.assertIn("-DMTEST_EXEC_TESTING=0", command)
        self.assertNotIn("-march=native", command)
        self.assertNotIn("-DPOISON_CFLAGS", command)
        self.assertNotIn("-DPOISON_CPPFLAGS", command)

    def test_testing_commands_ignore_ambient_compiler_flags(self) -> None:
        profile = host_profile(
            system=platform.system(),
            machine=platform.machine(),
            profiles=load_profiles(),
        )
        poison = {
            "CFLAGS": "-march=native -DPOISON_CFLAGS",
            "CPPFLAGS": "-DPOISON_CPPFLAGS",
        }
        with mock.patch.dict(os.environ, poison):
            adapter_command = native_abi.variant_compile_command(
                "clang",
                native_abi.TESTING_OBJECT,
                testing=True,
                profile=profile,
            )
            lifecycle_command = native_check.test_compile_command(
                "clang",
                native_check.TEST_SOURCES[0],
                Path("lifecycle.o"),
                profile,
            )
        for command in (adapter_command, lifecycle_command):
            for flag in profile.c_flags:
                self.assertIn(flag, command)
            self.assertIn("-DMTEST_EXEC_TESTING=1", command)
            self.assertNotIn("-march=native", command)
            self.assertNotIn("-DPOISON_CFLAGS", command)
            self.assertNotIn("-DPOISON_CPPFLAGS", command)

    def test_source_inventory_is_nonempty_and_exact(self) -> None:
        root = Path(__file__).resolve().parents[2]
        self.assertEqual(
            tuple(
                path.relative_to(root).as_posix() for path in native_check.TEST_SOURCES
            ),
            (
                "tests/native/test_exec_native.c",
                "tests/native/test_exec_native_signals.c",
            ),
        )
        self.assertGreater(len(native_check.TEST_SOURCES), 0)

    def test_empty_source_inventory_is_rejected(self) -> None:
        with (
            mock.patch.object(native_check, "TEST_SOURCES", ()),
            self.assertRaisesRegex(SystemExit, "source inventory is empty"),
        ):
            native_check.main()

    def test_darwin_link_uses_system_driver_and_precompiled_objects(self) -> None:
        command = native_check.link_command(
            "clang",
            (Path("adapter.o"), Path("lifecycle.o")),
            Path("lifecycle"),
            platform="darwin",
        )

        self.assertEqual(command[0], "/usr/bin/cc")
        self.assertEqual(
            command,
            ["/usr/bin/cc", "adapter.o", "lifecycle.o", "-o", "lifecycle"],
        )

    def test_linux_link_retains_pinned_driver(self) -> None:
        command = native_check.link_command(
            "/pinned/clang",
            (Path("adapter.o"), Path("lifecycle.o")),
            Path("lifecycle"),
            platform="linux",
        )

        self.assertEqual(command[0], "/pinned/clang")


if __name__ == "__main__":
    unittest.main()
