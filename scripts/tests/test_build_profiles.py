#!/usr/bin/env python3
"""Regression tests for the shared production host-profile grammar."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from scripts.build.profiles import (
    PROFILES_FILE,
    ProductionProfile,
    host_profile,
    load_profiles,
)


ROOT = Path(__file__).resolve().parents[2]
PRODUCTION_BUILD = ROOT / "scripts" / "build" / "production_build.sh"
PROFILE_SELECTOR_ARRAYS = (
    "current_c_flags",
    "seen_names",
    "seen_platform_systems",
    "seen_platform_machines",
)


def shell_expansion_scan_text(source: str) -> str:
    """Return executable shell text needed by the parameter scanner.

    This handles quotes, backslash escapes and continuations, and unquoted
    comments for the selector's syntax. It deliberately does not parse heredocs
    or the interiors of command and arithmetic substitutions, which the
    selector does not contain.
    """
    normalized: list[str] = []
    state = "unquoted"
    at_word_start = True
    index = 0
    while index < len(source):
        char = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""

        if state == "comment":
            if char == "\n":
                normalized.append(char)
                state = "unquoted"
                at_word_start = True
            else:
                normalized.append(" ")
            index += 1
            continue

        if state == "single":
            normalized.append("\n" if char == "\n" else " ")
            if char == "'":
                state = "unquoted"
            index += 1
            continue

        if char == "\\" and following == "\n":
            index += 2
            continue

        if state == "double":
            if char == "\\" and following in ('"', "$", "`", "\\"):
                normalized.extend((" ", " "))
                index += 2
                continue
            if char == '"':
                normalized.append(" ")
                state = "unquoted"
            else:
                normalized.append(char)
            index += 1
            continue

        if char == "\\":
            normalized.extend((" ", " ") if following else (" ",))
            at_word_start = False
            index += 2 if following else 1
            continue
        if char == "'":
            normalized.append(" ")
            state = "single"
            at_word_start = False
            index += 1
            continue
        if char == '"':
            normalized.append(" ")
            state = "double"
            at_word_start = False
            index += 1
            continue
        if char == "#" and at_word_start:
            normalized.append(" ")
            state = "comment"
            index += 1
            continue

        normalized.append(char)
        at_word_start = char.isspace() or char in ";&|()<>"
        index += 1

    return "".join(normalized)


def braced_parameter_expansions(source: str) -> tuple[tuple[int, str], ...]:
    """Return balanced braced parameter expansions without executing shell."""
    expansions: list[tuple[int, str]] = []
    search_from = 0
    while (start := source.find("${", search_from)) != -1:
        depth = 1
        cursor = start + 2
        while cursor < len(source):
            if source.startswith("${", cursor):
                depth += 1
                cursor += 2
                continue
            if source[cursor] == "}":
                depth -= 1
                if depth == 0:
                    expansions.append((start, source[start : cursor + 1]))
                    break
            cursor += 1
        search_from = start + 2
    return tuple(expansions)


def selector_array_expansion_violations(source: str) -> tuple[str, ...]:
    """Return non-indexed parameter expansions of profile-selector arrays."""
    source = shell_expansion_scan_text(source)
    violations: list[tuple[int, str]] = []
    for start, expansion in braced_parameter_expansions(source):
        body = expansion[2:-1]
        for name in PROFILE_SELECTOR_ARRAYS:
            if body == f"{name}[index]":
                break
            if re.match(rf"^[#!]?{re.escape(name)}(?:$|[^A-Za-z0-9_])", body):
                violations.append((start, expansion))
                break
    names = "|".join(re.escape(name) for name in PROFILE_SELECTOR_ARRAYS)
    violations.extend(
        (match.start(), match.group(0))
        for match in re.finditer(rf"\$(?:{names})(?![A-Za-z0-9_])", source)
    )
    return tuple(expansion for _, expansion in sorted(violations))


def shell_profile(
    system: str,
    machine: str,
    path: Path = PROFILES_FILE,
) -> ProductionProfile:
    """Read one profile through the production Bash implementation."""
    script = r"""
set -euo pipefail
profiles_file="$1"
source "$2"
select_profile "$3" "$4"
printf 'name\t%s\n' "$PROFILE_NAME"
printf 'system\t%s\n' "$PROFILE_SYSTEM"
printf 'machine\t%s\n' "$PROFILE_MACHINE"
printf 'mojo_cpu\t%s\n' "$MOJO_CPU"
printf 'mojo_triple\t%s\n' "$MOJO_TRIPLE"
printf 'deployment_target\t%s\n' "$DEPLOYMENT_TARGET"
for flag in "${PROFILE_C_FLAGS[@]}"; do
  printf 'c_flag\t%s\n' "$flag"
done
"""
    completed = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "production-profile-test",
            str(path),
            str(PRODUCTION_BUILD),
            system,
            machine,
        ],
        cwd=ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise SystemExit(completed.stderr.strip() or completed.stdout.strip())
    scalars: dict[str, str] = {}
    c_flags: list[str] = []
    for line in completed.stdout.splitlines():
        key, value = line.split("\t", 1)
        if key == "c_flag":
            c_flags.append(value)
        else:
            scalars[key] = value
    return ProductionProfile(
        name=scalars["name"],
        system=scalars["system"],
        machine=scalars["machine"],
        mojo_cpu=scalars["mojo_cpu"],
        mojo_triple=scalars["mojo_triple"] or None,
        c_flags=tuple(c_flags),
        deployment_target=scalars["deployment_target"] or None,
    )


class ProductionProfileTests(unittest.TestCase):
    """Keep Python and Bash strict readers byte-for-byte equivalent."""

    def test_repository_profile_file_parses_exactly(self) -> None:
        self.assertEqual(
            load_profiles(),
            (
                ProductionProfile(
                    name="linux-x86_64",
                    system="Linux",
                    machine="x86_64",
                    mojo_cpu="x86-64",
                    mojo_triple=None,
                    c_flags=("-march=x86-64", "-mtune=generic"),
                    deployment_target=None,
                ),
                ProductionProfile(
                    name="darwin-arm64",
                    system="Darwin",
                    machine="arm64",
                    mojo_cpu="apple-m1",
                    mojo_triple="arm64-apple-macosx14.0.0",
                    c_flags=("-mcpu=apple-m1", "-mmacosx-version-min=14.0"),
                    deployment_target="14.0",
                ),
            ),
        )

    def test_supported_hosts_match_through_both_readers(self) -> None:
        profiles = load_profiles()
        for system, machine in (("Linux", "x86_64"), ("Darwin", "arm64")):
            with self.subTest(system=system, machine=machine):
                self.assertEqual(
                    shell_profile(system, machine, PROFILES_FILE),
                    host_profile(
                        system=system,
                        machine=machine,
                        profiles=profiles,
                    ),
                )

    def test_unsupported_host_is_rejected(self) -> None:
        profiles = load_profiles()
        with self.assertRaisesRegex(SystemExit, "unsupported production host"):
            host_profile(system="Linux", machine="aarch64", profiles=profiles)

    def test_selector_uses_only_scalar_counts_and_indexed_array_access(self) -> None:
        source = PRODUCTION_BUILD.read_text(encoding="utf-8")
        start = source.index("select_profile() {")
        end = source.index("\nstage_precompile() {", start)
        selector = source[start:end]
        self.assertEqual(selector_array_expansion_violations(selector), ())
        for count in (
            "current_c_flag_count",
            "seen_name_count",
            "seen_platform_count",
        ):
            self.assertIn(f"local {count}=0", selector)
        for loop in (
            "for ((index = 0; index < current_c_flag_count; index++)); do",
            "for ((index = 0; index < seen_name_count; index++)); do",
            "for ((index = 0; index < seen_platform_count; index++)); do",
        ):
            self.assertIn(loop, selector)

    def test_selector_array_scanner_rejects_every_nonindexed_form(self) -> None:
        samples = (
            "${current_c_flags[*]}",
            "${seen_names[@]}",
            "${#seen_platform_systems[@]}",
            "${!seen_names[@]}",
            "${!seen_names}",
            "${seen_platform_systems}",
            "$seen_platform_machines",
            "${current_c_flags[${seen_name_count}]}",
        )
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertEqual(
                    selector_array_expansion_violations(f'printf "%s" "{sample}"'),
                    (sample,),
                )

    def test_selector_array_scanner_allows_exact_indexed_reads(self) -> None:
        for name in PROFILE_SELECTOR_ARRAYS:
            with self.subTest(name=name):
                self.assertEqual(
                    selector_array_expansion_violations(f'"${{{name}[index]}}"'),
                    (),
                )

    def test_selector_array_scanner_ignores_indexed_assignments(self) -> None:
        for name in PROFILE_SELECTOR_ARRAYS:
            with self.subTest(name=name):
                self.assertEqual(
                    selector_array_expansion_violations(f'{name}[index]="$value"'),
                    (),
                )

    def test_selector_array_scanner_ignores_nonexecuted_text(self) -> None:
        samples = (
            "# ${seen_names[@]}",
            "printf ok # ${seen_names[@]}",
            "printf '%s' '${seen_names[@]}'",
            r'''printf "%s" "\${seen_names[@]}"''',
        )
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertEqual(selector_array_expansion_violations(sample), ())

    def test_selector_array_scanner_splices_executed_continuations(self) -> None:
        sample = '"${seen_' + "\\\n" + 'names[@]}"'
        self.assertEqual(
            selector_array_expansion_violations(sample),
            ("${seen_names[@]}",),
        )

    def test_selector_array_scanner_keeps_hash_inside_shell_word(self) -> None:
        sample = "printf prefix#${seen_names[@]}"
        self.assertEqual(
            selector_array_expansion_violations(sample),
            ("${seen_names[@]}",),
        )

    def assert_readers_reject(self, text: str, message: str) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-profile-test-") as raw_tmp:
            path = Path(raw_tmp) / "profiles.txt"
            path.write_text(text, encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, message):
                load_profiles(path)
            with self.assertRaises(SystemExit):
                shell_profile("Linux", "x86_64", path)

    def test_duplicate_singleton_key_is_rejected(self) -> None:
        self.assert_readers_reject(
            "[one]\nsystem=Linux\nsystem=Linux\nmachine=x86_64\n"
            "mojo_cpu=x86-64\nc_flag=-march=x86-64\n",
            r":3: duplicate key 'system'",
        )

    def test_unknown_key_is_rejected(self) -> None:
        self.assert_readers_reject(
            "[one]\nsystem=Linux\nmachine=x86_64\nmojo_cpu=x86-64\n"
            "surprise=value\nc_flag=-march=x86-64\n",
            r":5: unknown key 'surprise'",
        )

    def test_every_required_key_is_rejected_when_missing(self) -> None:
        rows = (
            "system=Linux",
            "machine=x86_64",
            "mojo_cpu=x86-64",
            "c_flag=-march=x86-64",
        )
        for missing in rows:
            with self.subTest(missing=missing):
                text = (
                    "[one]\n" + "\n".join(row for row in rows if row != missing) + "\n"
                )
                self.assert_readers_reject(text, "missing required key")

    def test_empty_value_is_rejected(self) -> None:
        self.assert_readers_reject(
            "[one]\nsystem=Linux\nmachine=\nmojo_cpu=x86-64\nc_flag=-march=x86-64\n",
            r":3: empty value for 'machine'",
        )

    def test_duplicate_platform_tuple_is_rejected(self) -> None:
        self.assert_readers_reject(
            "[one]\nsystem=Linux\nmachine=x86_64\nmojo_cpu=x86-64\n"
            "c_flag=-march=x86-64\n\n[two]\nsystem=Linux\nmachine=x86_64\n"
            "mojo_cpu=x86-64\nc_flag=-mtune=generic\n",
            "duplicate production platform",
        )

    def test_key_value_before_section_is_rejected(self) -> None:
        self.assert_readers_reject(
            "system=Linux\n",
            r":1: key before profile section",
        )

    def test_malformed_key_value_row_is_rejected(self) -> None:
        self.assert_readers_reject(
            "[one]\nsystem Linux\n",
            r":2: malformed profile row",
        )

    def test_empty_inventory_is_rejected(self) -> None:
        self.assert_readers_reject("", "profile inventory is empty")


if __name__ == "__main__":
    unittest.main()
