#!/usr/bin/env python3
"""Pure parser tests for the production artifact-profile gate."""

from __future__ import annotations

import unittest

from scripts.checks.build_profile import (
    BuildProfileError,
    parse_elf_debug_sections,
    parse_llvm_target_attributes,
    parse_macho_minimum_versions,
)


LLVM_SAMPLE = (
    'attributes #0 = { nounwind "target-cpu"="x86-64" '
    '"target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" }\n'
)
ELF_SECTIONS = "  [12] .text PROGBITS\n  [20] .debug_info PROGBITS\n"
MACHO_LOADS = (
    "      cmd LC_BUILD_VERSION\n platform 1\n    minos 14.0\n      sdk 26.0\n"
)
MACHO_LEGACY_LOAD = (
    "      cmd LC_VERSION_MIN_MACOSX\n  cmdsize 16\n  version 13.5\n      sdk 14.4\n"
)


class LlvmTargetAttributeParserTests(unittest.TestCase):
    """LLVM target attributes must be complete and unambiguous."""

    def test_returns_the_cpu_and_feature_pair(self) -> None:
        self.assertEqual(
            parse_llvm_target_attributes(LLVM_SAMPLE),
            (("x86-64", "+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87"),),
        )

    def test_returns_every_attribute_group_in_order(self) -> None:
        sample = LLVM_SAMPLE + LLVM_SAMPLE.replace("#0", "#1").replace(
            '"x86-64"', '"apple-m1"'
        )
        self.assertEqual(
            parse_llvm_target_attributes(sample),
            (
                ("x86-64", "+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87"),
                ("apple-m1", "+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87"),
            ),
        )

    def test_missing_target_attribute_is_rejected(self) -> None:
        for label, sample in (
            (
                "cpu",
                'attributes #0 = { nounwind "target-features"="+sse2" }\n',
            ),
            (
                "features",
                'attributes #0 = { nounwind "target-cpu"="x86-64" }\n',
            ),
            ("attribute group", "define void @main() {\n  ret void\n}\n"),
        ):
            with self.subTest(missing=label), self.assertRaises(BuildProfileError):
                parse_llvm_target_attributes(sample)

    def test_malformed_target_attribute_is_rejected(self) -> None:
        malformed = (
            'attributes #0 = { "target-cpu"="x86-64" "target-features"=+sse2 }\n'
        )
        with self.assertRaises(BuildProfileError):
            parse_llvm_target_attributes(malformed)


class ElfSectionParserTests(unittest.TestCase):
    """ELF debug sections are reported by their exact section names."""

    def test_returns_debug_sections_only(self) -> None:
        self.assertEqual(parse_elf_debug_sections(ELF_SECTIONS), (".debug_info",))

    def test_binary_without_debug_sections_returns_empty(self) -> None:
        self.assertEqual(
            parse_elf_debug_sections("  [12] .text PROGBITS\n"),
            (),
        )


class MachoMinimumVersionParserTests(unittest.TestCase):
    """Both current and legacy Mach-O deployment commands are understood."""

    def test_parses_build_version_minimum(self) -> None:
        self.assertEqual(
            parse_macho_minimum_versions(MACHO_LOADS),
            ((14, 0, 0),),
        )

    def test_parses_legacy_minimum(self) -> None:
        self.assertEqual(
            parse_macho_minimum_versions(MACHO_LEGACY_LOAD),
            ((13, 5, 0),),
        )

    def test_mixed_commands_preserve_loader_order(self) -> None:
        self.assertEqual(
            parse_macho_minimum_versions(MACHO_LOADS + MACHO_LEGACY_LOAD),
            ((14, 0, 0), (13, 5, 0)),
        )

    def test_missing_version_is_rejected(self) -> None:
        for sample in (
            "      cmd LC_BUILD_VERSION\n platform 1\n      sdk 26.0\n",
            "      cmd LC_VERSION_MIN_MACOSX\n  cmdsize 16\n      sdk 14.4\n",
        ):
            with self.subTest(sample=sample), self.assertRaises(BuildProfileError):
                parse_macho_minimum_versions(sample)

    def test_output_without_a_minimum_command_is_rejected(self) -> None:
        with self.assertRaises(BuildProfileError):
            parse_macho_minimum_versions("      cmd LC_LOAD_DYLIB\n")


if __name__ == "__main__":
    unittest.main()
