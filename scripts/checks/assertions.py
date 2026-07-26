#!/usr/bin/env python3
"""Compile and directly execute source-only assertion companion consumers."""

from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import cast
import unicodedata


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_ROOT = REPO_ROOT / "build" / "assertions-check"
ASSERTION_SOURCE_ROOT = REPO_ROOT / "assertions-src"
API_CONSUMER = REPO_ROOT / "tests" / "assertions" / "api_consumer.mojo"
LOCATION_CONSUMER = REPO_ROOT / "tests" / "assertions" / "location_consumer.mojo"
EXAMPLE_CONSUMER = REPO_ROOT / "examples" / "assertions" / "test_diagnostics.mojo"
COMPILE_TIMEOUT_SECONDS = 120
RUN_TIMEOUT_SECONDS = 30
LOCATION_MARKER = "# ASSERT-LOCATION:"
EXPLICIT_LOCATION_MARKER = "# ASSERT-EXPLICIT-LOCATION:"
ASSERTION_OPTIMIZATIONS = (("-O0", "o0"), ("-O3", "o3"))
ASSERTION_CONSUMERS = ("api", "location", "example")
STATIC_PROOF_IDS = (
    "unicode-categories",
    "dictionary-success",
    "dictionary-selection",
    "public-api",
)
PRIVATE_FACADE_HELPERS = (
    "BODY_BYTE_CAP",
    "BoundedWriter",
    "SourceLocation",
    "call_location",
)
LOCATION_TESTS = {
    "test_generic_omitted_message",
    "test_generic_positional_message",
    "test_generic_keyword_message",
    "test_string_location",
    "test_list_location",
    "test_dictionary_location",
    "test_generic_explicit_location",
    "test_string_explicit_location",
    "test_list_explicit_location",
    "test_dictionary_explicit_location",
}
API_TESTS = {
    "test_message_call_shapes_and_explicit_location",
    "test_standard_and_companion_names_coexist",
    "test_pass_compares_once_and_never_renders",
    "test_failure_compares_once_and_renders_each_operand_once",
    "test_opaque_render_caps_apply_after_escaping",
    "test_identical_opaque_projections_report_whether_they_were_truncated",
    "test_many_small_formatter_writes_and_body_are_bounded",
    "test_text_first_difference_at_start_middle_end_and_ending",
    "test_text_scalar_labels_expose_invisible_differences",
    "test_invisible_scalars_are_escaped_in_structural_values",
    "test_text_line_endings_and_final_newline_are_explicit",
    "test_text_context_has_two_lines_each_side_and_safe_prefixes",
    "test_text_crop_marker_requires_an_elided_line_prefix",
    "test_text_crop_reports_whole_elided_lines",
    "test_large_text_context_is_bounded_and_message_is_last",
    "test_list_replacement_and_insertions_are_clear_spans",
    "test_list_changed_content_and_lengths_have_exact_facts",
    "test_list_displays_eight_mismatches_and_counts_omitted_first",
    "test_list_values_are_individually_bounded_before_body_assembly",
    "test_nested_lists_are_opaque_and_user_message_is_last",
    "test_list_specializer_renders_zero_on_pass_and_eight_on_failure",
    "test_unequal_list_suffix_does_not_repeat_the_aligned_scan",
    "test_expected_front_insertion_compares_each_receiver_once",
    "test_dictionary_categories_are_distinct_and_ordered",
    "test_dictionary_order_is_full_unsigned_utf8_not_insertion_order",
    "test_dictionary_displays_eight_per_category_with_totals_first",
    "test_dictionary_values_are_individually_bounded_before_assembly",
    "test_dictionary_key_cap_boundary_and_omission",
    "test_oversized_dictionary_key_omission_is_truthful",
    "test_dictionary_key_omission_is_insertion_order_independent",
    "test_equal_dictionary_with_oversized_key_returns_without_rendering",
    "test_equal_oversized_dictionary_key_does_not_hide_short_change",
    "test_undisplayed_oversized_dictionary_key_keeps_short_details",
    "test_dictionary_specializer_renders_only_eight_changed_values",
}


def _unicode_mark_ranges() -> list[tuple[int, int]]:
    points = [
        value
        for value in range(0x110000)
        if unicodedata.category(chr(value)) in {"Mn", "Me"}
    ]
    ranges: list[tuple[int, int]] = []
    for value in points:
        if not ranges or value != ranges[-1][1] + 1:
            ranges.append((value, value))
        else:
            ranges[-1] = (ranges[-1][0], value)
    return ranges


def _unicode_category_ranges(category: str) -> list[tuple[int, int]]:
    points = [
        value
        for value in range(0x110000)
        if unicodedata.category(chr(value)) == category
    ]
    ranges: list[tuple[int, int]] = []
    for value in points:
        if not ranges or value != ranges[-1][1] + 1:
            ranges.append((value, value))
        else:
            ranges[-1] = (ranges[-1][0], value)
    return ranges


def _mojo_enclosing_mark_ranges(text: str) -> list[tuple[int, int]]:
    start = text.find("def _is_enclosing_mark(value: Int) -> Bool:")
    if start == -1:
        raise AssertionError("assertion enclosing mark classifier is missing")
    stop = text.find("\ndef ", start + 1)
    function = text[start:] if stop == -1 else text[start:stop]
    token = re.compile(
        r"\(value >= 0x([0-9A-Fa-f]+) and value <= 0x([0-9A-Fa-f]+)\)"
        r"|value == 0x([0-9A-Fa-f]+)"
    )
    observed: list[tuple[int, int]] = []
    for match in token.finditer(function):
        if match.group(3) is not None:
            value = int(match.group(3), 16)
            observed.append((value, value))
        else:
            observed.append((int(match.group(1), 16), int(match.group(2), 16)))
    return observed


def validate_unicode_category_tables(source: Path) -> None:
    """Require Mojo's Unicode 15.0 mark tables to match Mn and Me exactly."""
    if unicodedata.unidata_version != "15.0.0":
        raise AssertionError(
            "assertion Unicode table checker requires Unicode 15.0.0, got "
            + unicodedata.unidata_version
        )
    text = source.read_text(encoding="utf-8")
    match = re.search(
        r'^comptime _MARK_RANGES: StaticString = "([0-9a-f]+)"$',
        text,
        re.MULTILINE,
    )
    if match is None or len(match.group(1)) % 12:
        raise AssertionError("assertion Unicode mark range encoding is invalid")
    packed = match.group(1)
    observed = [
        (int(packed[index : index + 6], 16), int(packed[index + 6 : index + 12], 16))
        for index in range(0, len(packed), 12)
    ]
    expected = _unicode_mark_ranges()
    if observed != expected:
        raise AssertionError(
            "assertion Unicode mark ranges differ from Unicode 15.0 "
            f"Mn/Me: expected {len(expected)}, got {len(observed)}"
        )
    derived_count = "comptime _MARK_RANGE_COUNT = _MARK_RANGES.byte_length() // 12"
    if derived_count not in text:
        raise AssertionError(
            "assertion Unicode mark range count must be derived from its bytes"
        )
    enclosing = _mojo_enclosing_mark_ranges(text)
    expected_enclosing = _unicode_category_ranges("Me")
    if enclosing != expected_enclosing:
        raise AssertionError(
            "assertion enclosing mark ranges differ from Unicode 15.0 Me: "
            f"expected {expected_enclosing}, got {enclosing}"
        )


def validate_dictionary_success_path(source: str) -> None:
    """Require key selection to receive only already-classified differences."""
    function_start = source.find("def write_dictionary_difference[")
    if function_start == -1:
        raise AssertionError("dictionary difference function is missing")
    function = source[function_start:]
    expected_selection_blocks = (
        (
            "if entry.key not in actual:\n"
            "            missing.consider(entry.key)\n"
            "        elif actual[entry.key] != entry.value:\n"
            "            changed.consider(entry.key)"
        ),
        ("if entry.key not in expected:\n            unexpected.consider(entry.key)"),
    )
    if function.count(".consider(") != 3 or any(
        block not in function for block in expected_selection_blocks
    ):
        raise AssertionError(
            "dictionary key projection must receive only classified differences"
        )
    equal_guard = "if not missing.total and not unexpected.total and not changed.total:"
    equal_guard_at = function.find(equal_guard)
    if equal_guard_at == -1:
        raise AssertionError("dictionary equality return guard is missing")
    equal_return_at = function.find("return True", equal_guard_at)
    if equal_return_at == -1:
        raise AssertionError("dictionary equality return is missing")


def expected_assertion_execution_roster() -> tuple[tuple[str, str], ...]:
    """Return every consumer and optimization pair the gate must complete."""
    return tuple(
        (consumer, optimization)
        for optimization, _suffix in ASSERTION_OPTIMIZATIONS
        for consumer in ASSERTION_CONSUMERS
    )


def verify_assertion_execution_roster(
    performed: tuple[tuple[str, str], ...],
) -> None:
    """Refuse success when any documented consumer compile or run was skipped."""
    expected = expected_assertion_execution_roster()
    if performed != expected:
        missing = [pair for pair in expected if pair not in performed]
        raise AssertionError(
            "assertion execution roster differs: "
            f"ran {list(performed)}, expected {list(expected)}, missing {missing}"
        )


def validate_dictionary_selection_bound(source: str) -> None:
    """Require oversized key displays to be omitted before selection retains them."""
    consider_at = source.find("def consider(mut self, key: String):")
    if consider_at == -1:
        raise AssertionError("dictionary key selection function is missing")
    function = source[consider_at:]
    guard_at = function.find("key.byte_length() > DICTIONARY_KEY_BYTE_CAP")
    projection_at = function.find("or not _key_projection_fits(key)")
    reject_at = function.find("return", guard_at)
    retain_at = function.find("self.keys.append(key)")
    if (
        guard_at == -1
        or projection_at == -1
        or reject_at == -1
        or retain_at == -1
        or guard_at > retain_at
        or projection_at > retain_at
        or reject_at > retain_at
    ):
        raise AssertionError(
            "oversized dictionary key display can be retained by selection"
        )


def compile_command(
    mojo: Path,
    repo_root: Path,
    source: Path,
    output: Path,
    optimization: str,
) -> list[str]:
    """Build one consumer against exactly the public assertion source root."""
    return [
        str(mojo),
        "build",
        optimization,
        "-I",
        str(repo_root / "assertions-src"),
        str(source),
        "-o",
        str(output),
    ]


def reset_build_root(build_root: Path = BUILD_ROOT) -> None:
    """Remove every prior assertion-check artifact and recreate its directory."""
    if build_root.exists():
        shutil.rmtree(build_root)
    build_root.mkdir(parents=True)


def expected_locations(source: Path) -> dict[str, tuple[int, int]]:
    """Extract expected first-argument coordinates from marked assertion calls."""
    source = source.resolve()
    locations: dict[str, tuple[int, int]] = {}
    last_call: tuple[int, int] | None = None
    last_explicit: tuple[int, int] | None = None
    for line_number, line in enumerate(
        source.read_text(encoding="utf-8").splitlines(), start=1
    ):
        call_start = line.find("assert_equal(")
        if call_start != -1:
            last_call = (line_number, line.index("(", call_start) + 1)
        explicit_start = line.find("source_location(")
        if explicit_start != -1:
            last_explicit = (
                line_number,
                line.index("(", explicit_start) + 1,
            )
        marker = (
            EXPLICIT_LOCATION_MARKER
            if EXPLICIT_LOCATION_MARKER in line
            else LOCATION_MARKER
        )
        if marker not in line:
            continue
        name = line.split(marker, 1)[1].strip()
        if not name:
            raise AssertionError(f"empty location marker at {source}:{line_number}")
        if name in locations:
            raise AssertionError(f"duplicate location marker: {name}")
        coordinate = last_explicit if marker == EXPLICIT_LOCATION_MARKER else last_call
        if coordinate is None:
            raise AssertionError(
                f"location marker has no preceding matching call at "
                f"{source}:{line_number}"
            )
        locations[name] = coordinate
    if not locations:
        raise AssertionError(f"no location markers found in {source}")
    return locations


def validate_location_run(
    run: subprocess.CompletedProcess[str],
    source: Path,
    expected: dict[str, tuple[int, int]],
) -> None:
    """Require ordinary TestSuite failures at every marked consumer location."""
    source = source.resolve()
    if run.returncode != 1:
        raise AssertionError(
            f"location consumer must terminate with exact exit 1, got {run.returncode}"
        )
    if run.stderr:
        raise AssertionError(f"location consumer wrote stderr: {run.stderr}")
    if "CRASH" in run.stdout:
        raise AssertionError("location consumer reported CRASH")

    fail_rows = set(
        re.findall(r"^\s+FAIL \[[^\]]+\] ([A-Za-z0-9_]+)\s*$", run.stdout, re.MULTILINE)
    )
    expected_rows = set(expected)
    if fail_rows != expected_rows:
        raise AssertionError(
            f"location consumer FAIL rows differ: expected "
            f"{sorted(expected_rows)}, got {sorted(fail_rows)}"
        )

    count = len(expected)
    summary = f"{count} tests run: 0 passed , {count} failed , 0 skipped"
    if summary not in run.stdout:
        raise AssertionError(f"location consumer summary differs: want {summary!r}")

    provider_root = source.parents[2] / "assertions-src" / "mtest" / "assertions"
    if f"At {provider_root}" in run.stdout:
        raise AssertionError("location consumer exposed a provider coordinate")

    escaped_source = re.escape(str(source))
    observed_rows = re.findall(
        rf"^\s+FAIL \[[^\]]+\] ([A-Za-z0-9_]+)\s*\n"
        rf"\s+At {escaped_source}:(\d+):(\d+):",
        run.stdout,
        re.MULTILINE,
    )
    observed = {name: (int(line), int(column)) for name, line, column in observed_rows}
    if len(observed_rows) != len(observed) or observed != expected:
        raise AssertionError(
            "location consumer name-to-coordinate mapping differs: "
            f"expected {sorted(expected.items())}, got "
            f"{sorted(observed.items())}"
        )


def _run_checked(
    command: list[str],
    *,
    cwd: Path,
    timeout: int,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(
            f"command exceeded {timeout} seconds: {' '.join(command)}"
        ) from exc


def _compile(
    mojo: Path,
    source: Path,
    output: Path,
    optimization: str,
) -> None:
    command = compile_command(mojo, REPO_ROOT, source, output, optimization)
    result = _run_checked(
        command,
        cwd=REPO_ROOT,
        timeout=COMPILE_TIMEOUT_SECONDS,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"compile failed ({optimization}, {source.name}):\n"
            f"{result.stdout}{result.stderr}"
        )
    validate_clean_compile(result, optimization, source.name)
    if not output.is_file():
        raise AssertionError(f"compile did not create a fresh binary: {output}")


def validate_clean_compile(
    result: subprocess.CompletedProcess[str],
    optimization: str,
    source_name: str,
) -> None:
    """Reject warnings emitted while compiling the shipped public source."""
    transcript = result.stdout + result.stderr
    if "warning:" in transcript:
        raise AssertionError(
            f"compiler warning ({optimization}, {source_name}):\n{transcript}"
        )


def _reject_accidental_public_helpers(mojo: Path) -> tuple[str, ...]:
    completed: list[str] = []
    for helper in PRIVATE_FACADE_HELPERS:
        source = BUILD_ROOT / f"private-export-{helper}.mojo"
        output = BUILD_ROOT / f"private-export-{helper}"
        source.write_text(
            f"from mtest.assertions import {helper}\n\ndef main():\n    pass\n",
            encoding="utf-8",
        )
        result = _run_checked(
            compile_command(mojo, REPO_ROOT, source, output, "-O0"),
            cwd=REPO_ROOT,
            timeout=COMPILE_TIMEOUT_SECONDS,
        )
        diagnostic = result.stdout + result.stderr
        if result.returncode == 0 or output.exists():
            raise AssertionError(f"public assertion package exposed {helper}")
        validate_export_rejection(diagnostic, helper)
        completed.append(helper)
    return tuple(completed)


def validate_export_rejection(diagnostic: str, helper: str) -> None:
    """Require the compiler's semantic package-facade rejection."""
    expected = f"package 'assertions' does not contain '{helper}'"
    if expected not in diagnostic:
        raise AssertionError(
            f"{helper} probe failed for the wrong reason:\n" + diagnostic
        )


def _declaration_rows(
    declaration: dict[str, object],
    kind: str,
) -> list[dict[str, object]]:
    value = declaration.get(kind)
    if not isinstance(value, list) or not all(
        isinstance(item, dict) and all(isinstance(key, str) for key in item)
        for item in value
    ):
        raise AssertionError(f"public API {kind} declaration is malformed")
    return cast("list[dict[str, object]]", value)


def _declaration_names(
    declaration: dict[str, object],
    kind: str,
) -> list[str]:
    names: list[str] = []
    for item in _declaration_rows(declaration, kind):
        name = item.get("name")
        if not isinstance(name, str):
            raise AssertionError(f"public API {kind} name is malformed")
        names.append(name)
    return names


def public_api_surface(declaration: dict[str, object]) -> dict[str, object]:
    """Project every public declaration kind and exact function signature."""
    functions: list[dict[str, object]] = []
    for item in _declaration_rows(declaration, "functions"):
        name = item.get("name")
        overloads = item.get("overloads")
        if not isinstance(name, str) or not isinstance(overloads, list):
            raise AssertionError("public API function declaration is malformed")
        signatures: list[str] = []
        for overload in overloads:
            if not isinstance(overload, dict):
                raise AssertionError("public API function overload is malformed")
            signature = overload.get("signature")
            if not isinstance(signature, str):
                raise AssertionError("public API function signature is malformed")
            signatures.append(signature)
        functions.append({"name": name, "overloads": signatures})
    return {
        "functions": functions,
        "structs": _declaration_names(declaration, "structs"),
        "aliases": _declaration_names(declaration, "aliases"),
        "traits": _declaration_names(declaration, "traits"),
    }


def _validate_public_api_docs(mojo: Path) -> None:
    output = BUILD_ROOT / "public-api.json"
    result = _run_checked(
        [
            str(mojo),
            "doc",
            "--diagnose-missing-doc-strings",
            "--Werror",
            "-I",
            str(ASSERTION_SOURCE_ROOT),
            str(ASSERTION_SOURCE_ROOT / "mtest" / "assertions" / "__init__.mojo"),
            "-o",
            str(output),
        ],
        cwd=REPO_ROOT,
        timeout=COMPILE_TIMEOUT_SECONDS,
    )
    if result.returncode != 0 or not output.is_file():
        raise AssertionError(
            f"public assertion documentation failed:\n{result.stdout}{result.stderr}"
        )
    declaration = json.loads(output.read_text(encoding="utf-8"))["decl"]
    surface = public_api_surface(declaration)
    expected = {
        "functions": [
            {
                "name": "assert_equal",
                "overloads": [
                    (
                        "def assert_equal(actual: String, expected: String, "
                        'msg: String = "", *, location: '
                        "Optional[SourceLocation] = None)"
                    ),
                    (
                        "def assert_equal[T: Copyable & ImplicitlyDeletable & "
                        "Equatable & Writable](actual: List[T], expected: "
                        'List[T], msg: String = "", *, location: '
                        "Optional[SourceLocation] = None)"
                    ),
                    (
                        "def assert_equal[V: Copyable & ImplicitlyDeletable & "
                        "Equatable & Writable](actual: Dict[String, V], "
                        'expected: Dict[String, V], msg: String = "", *, '
                        "location: Optional[SourceLocation] = None)"
                    ),
                    (
                        "def assert_equal[T: Equatable & Writable, _fallback: "
                        "Bool = True, //](actual: T, expected: T, msg: String = "
                        '"", *, location: Optional[SourceLocation] = None)'
                    ),
                ],
            }
        ],
        "structs": [],
        "aliases": [],
        "traits": [],
    }
    if surface != expected:
        raise AssertionError(
            f"public assertion API differs: expected {expected}, got {surface}"
        )


def _validate_api_run(
    run: subprocess.CompletedProcess[str],
    expected_rows: set[str],
) -> None:
    if run.returncode != 0:
        raise AssertionError(
            f"API consumer exited {run.returncode}:\n{run.stdout}{run.stderr}"
        )
    if run.stderr:
        raise AssertionError(f"API consumer wrote stderr: {run.stderr}")
    if re.search(r"^\s+(?:FAIL|CRASH) \[", run.stdout, re.MULTILINE):
        raise AssertionError(f"API consumer did not pass cleanly:\n{run.stdout}")
    pass_rows = set(
        re.findall(r"^\s+PASS \[[^\]]+\] ([A-Za-z0-9_]+)\s*$", run.stdout, re.MULTILINE)
    )
    if pass_rows != expected_rows:
        raise AssertionError(
            f"API consumer PASS rows differ: expected {sorted(expected_rows)}, "
            f"got {sorted(pass_rows)}"
        )
    summary = re.search(
        r"^Summary \[[^\]]+\] (\d+) tests run: (\d+) passed , "
        r"(\d+) failed , (\d+) skipped\s*$",
        run.stdout,
        re.MULTILINE,
    )
    if summary is None:
        raise AssertionError("API consumer did not emit a TestSuite summary")
    total, passed, failed, skipped = map(int, summary.groups())
    if total != len(expected_rows) or (passed, failed, skipped) != (
        total,
        0,
        0,
    ):
        raise AssertionError(f"API consumer did not pass cleanly:\n{run.stdout}")


def validate_example_run(run: subprocess.CompletedProcess[str]) -> None:
    """Require the committed README source example to fail exactly as documented."""
    if run.returncode != 1:
        raise AssertionError(
            f"README example must terminate with exact exit 1, got {run.returncode}"
        )
    if run.stderr:
        raise AssertionError(f"README example wrote stderr: {run.stderr}")
    required = (
        "PASS [",
        "test_standard_assertion_still_coexists",
        "FAIL [",
        "test_text_difference_has_scalar_and_context",
        "text differs at scalar 6",
        "actual: U+0062 'b'",
        "expected: U+0042 'B'",
        "reason: configuration text changed",
        "2 tests run: 1 passed , 1 failed , 0 skipped",
    )
    missing = [item for item in required if item not in run.stdout]
    if missing:
        raise AssertionError(f"README example output is incomplete: {missing}")
    if "CRASH" in run.stdout:
        raise AssertionError("README example reported CRASH")


def run_static_assertion_proofs(mojo: Path) -> tuple[str, ...]:
    """Run and record every non-execution assertion proof."""
    completed: list[str] = []
    validate_unicode_category_tables(
        ASSERTION_SOURCE_ROOT / "mtest" / "assertions" / "_display.mojo"
    )
    completed.append("unicode-categories")
    mapping_source = (
        ASSERTION_SOURCE_ROOT / "mtest" / "assertions" / "_mapping.mojo"
    ).read_text(encoding="utf-8")
    validate_dictionary_success_path(mapping_source)
    completed.append("dictionary-success")
    validate_dictionary_selection_bound(mapping_source)
    completed.append("dictionary-selection")
    _validate_public_api_docs(mojo)
    completed.append("public-api")
    return tuple(completed)


def run_assertion_consumers(
    mojo: Path,
    locations: dict[str, tuple[int, int]],
) -> tuple[tuple[str, str], ...]:
    """Compile, execute, validate, and record every consumer matrix cell."""
    completed: list[tuple[str, str]] = []
    for optimization, suffix in ASSERTION_OPTIMIZATIONS:
        api_binary = BUILD_ROOT / f"api-{suffix}"
        _compile(mojo, API_CONSUMER, api_binary, optimization)
        api_run = _run_checked(
            [str(api_binary)],
            cwd=REPO_ROOT,
            timeout=RUN_TIMEOUT_SECONDS,
        )
        _validate_api_run(api_run, API_TESTS)
        completed.append(("api", optimization))

        location_binary = BUILD_ROOT / f"location-{suffix}"
        _compile(mojo, LOCATION_CONSUMER, location_binary, optimization)
        location_run = _run_checked(
            [str(location_binary)],
            cwd=REPO_ROOT,
            timeout=RUN_TIMEOUT_SECONDS,
        )
        validate_location_run(location_run, LOCATION_CONSUMER, locations)
        completed.append(("location", optimization))

        example_binary = BUILD_ROOT / f"example-{suffix}"
        _compile(mojo, EXAMPLE_CONSUMER, example_binary, optimization)
        example_run = _run_checked(
            [str(example_binary)],
            cwd=REPO_ROOT,
            timeout=RUN_TIMEOUT_SECONDS,
        )
        validate_example_run(example_run)
        completed.append(("example", optimization))
    return tuple(completed)


def check_assertions() -> tuple[tuple[str, str], ...]:
    """Compile and execute every assertion consumer at both optimization levels."""
    mojo_raw = shutil.which("mojo")
    if mojo_raw is None:
        raise AssertionError("mojo is not available on PATH")
    mojo = Path(mojo_raw).resolve()
    reset_build_root()
    locations = expected_locations(LOCATION_CONSUMER)
    if set(locations) != LOCATION_TESTS:
        raise AssertionError(
            "location consumer inventory differs: "
            f"expected {sorted(LOCATION_TESTS)}, got {sorted(locations)}"
        )
    static_proofs = run_static_assertion_proofs(mojo)
    if static_proofs != STATIC_PROOF_IDS:
        raise AssertionError(
            "static assertion proof roster differs: "
            f"ran {list(static_proofs)}, expected {list(STATIC_PROOF_IDS)}"
        )
    executions = run_assertion_consumers(mojo, locations)
    verify_assertion_execution_roster(executions)
    private_helpers = _reject_accidental_public_helpers(mojo)
    if private_helpers != PRIVATE_FACADE_HELPERS:
        raise AssertionError(
            "private facade helper roster differs: "
            f"ran {list(private_helpers)}, expected "
            f"{list(PRIVATE_FACADE_HELPERS)}"
        )
    return executions


def main() -> int:
    """Run the assertion companion gate."""
    try:
        performed = check_assertions()
    except AssertionError as exc:
        print(f"assertions-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"assertions-check: OK -- completed {list(performed)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
