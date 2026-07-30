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
    "define void @main() #0 {\n"
    "  ret void\n"
    "}\n"
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
        sample = (
            "define void @first() #0 {\n"
            "  ret void\n"
            "}\n"
            "define void @second() #1 {\n"
            "  ret void\n"
            "}\n"
            'attributes #0 = { "target-cpu"="x86-64" '
            '"target-features"="+sse2" }\n'
            'attributes #1 = { "target-cpu"="apple-m1" '
            '"target-features"="+neon" }\n'
        )
        self.assertEqual(
            parse_llvm_target_attributes(sample),
            (
                ("x86-64", "+sse2"),
                ("apple-m1", "+neon"),
            ),
        )

    def test_missing_target_attribute_is_rejected(self) -> None:
        for label, sample in (
            (
                "cpu",
                (
                    "define void @main() #0 {\n"
                    "  ret void\n"
                    "}\n"
                    'attributes #0 = { nounwind "target-features"="+sse2" }\n'
                ),
            ),
            (
                "features",
                (
                    "define void @main() #0 {\n"
                    "  ret void\n"
                    "}\n"
                    'attributes #0 = { nounwind "target-cpu"="x86-64" }\n'
                ),
            ),
        ):
            with self.subTest(missing=label), self.assertRaises(BuildProfileError):
                parse_llvm_target_attributes(sample)

    def test_definition_referencing_attribute_less_group_is_rejected(self) -> None:
        sample = (
            "define void @main() #0 {\n  ret void\n}\nattributes #0 = { nounwind }\n"
        )
        with self.assertRaisesRegex(
            BuildProfileError, "references attribute group without target attributes"
        ):
            parse_llvm_target_attributes(sample)

    def test_definition_without_attribute_group_is_rejected(self) -> None:
        sample = (
            "define void @main() {\n"
            "  ret void\n"
            "}\n"
            'attributes #0 = { "target-cpu"="x86-64" '
            '"target-features"="+sse2" }\n'
        )
        with self.assertRaisesRegex(
            BuildProfileError, "must reference exactly one attribute group"
        ):
            parse_llvm_target_attributes(sample)

    def test_output_without_a_function_definition_is_rejected(self) -> None:
        sample = 'attributes #0 = { "target-cpu"="x86-64" "target-features"="+sse2" }\n'
        with self.assertRaisesRegex(
            BuildProfileError, "LLVM output contains no function definition"
        ):
            parse_llvm_target_attributes(sample)

    def test_definition_referencing_missing_group_is_rejected(self) -> None:
        sample = (
            "define void @main() #7 {\n"
            "  ret void\n"
            "}\n"
            'attributes #0 = { "target-cpu"="x86-64" '
            '"target-features"="+sse2" }\n'
        )
        with self.assertRaisesRegex(
            BuildProfileError, "references missing attribute group #7"
        ):
            parse_llvm_target_attributes(sample)

    def test_definition_with_multiple_group_references_is_rejected(self) -> None:
        sample = (
            "define void @main() #0 #1 {\n"
            "  ret void\n"
            "}\n"
            'attributes #0 = { "target-cpu"="x86-64" '
            '"target-features"="+sse2" }\n'
            'attributes #1 = { "target-cpu"="x86-64" '
            '"target-features"="+sse2" }\n'
        )
        with self.assertRaisesRegex(
            BuildProfileError, "must reference exactly one attribute group"
        ):
            parse_llvm_target_attributes(sample)

    def test_definition_with_malformed_group_reference_is_rejected(self) -> None:
        sample = (
            "define void @main() #invalid {\n"
            "  ret void\n"
            "}\n"
            'attributes #0 = { "target-cpu"="x86-64" '
            '"target-features"="+sse2" }\n'
        )
        with self.assertRaisesRegex(
            BuildProfileError, "must reference exactly one attribute group"
        ):
            parse_llvm_target_attributes(sample)

    def test_duplicate_attribute_group_is_rejected(self) -> None:
        sample = (
            "define void @main() #0 {\n"
            "  ret void\n"
            "}\n"
            'attributes #0 = { "target-cpu"="x86-64" '
            '"target-features"="+sse2" }\n'
            'attributes #0 = { "target-cpu"="x86-64" '
            '"target-features"="+sse2" }\n'
        )
        with self.assertRaisesRegex(
            BuildProfileError, "duplicate LLVM attribute group"
        ):
            parse_llvm_target_attributes(sample)

    def test_declaration_does_not_require_an_attribute_group(self) -> None:
        sample = (
            "declare void @external() #1\n"
            + LLVM_SAMPLE
            + "attributes #1 = { nounwind }\n"
        )
        self.assertEqual(
            parse_llvm_target_attributes(sample),
            (("x86-64", "+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87"),),
        )

    def test_malformed_target_attribute_is_rejected(self) -> None:
        malformed = (
            "define void @main() #0 {\n"
            "  ret void\n"
            "}\n"
            'attributes #0 = { "target-cpu"="x86-64" "target-features"=+sse2 }\n'
        )
        with self.assertRaises(BuildProfileError):
            parse_llvm_target_attributes(malformed)

    def test_malformed_attribute_group_is_rejected(self) -> None:
        malformed = (
            "define void @main() #0 {\n  ret void\n}\nattributes #0 = nounwind\n"
        )
        with self.assertRaisesRegex(
            BuildProfileError, "malformed LLVM attribute group"
        ):
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
