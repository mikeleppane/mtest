#!/usr/bin/env python3
"""Compile and directly execute source-only assertion companion consumers."""

from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_ROOT = REPO_ROOT / "build" / "assertions-check"
ASSERTION_SOURCE_ROOT = REPO_ROOT / "assertions-src"
API_CONSUMER = REPO_ROOT / "tests" / "assertions" / "api_consumer.mojo"
LOCATION_CONSUMER = (
    REPO_ROOT / "tests" / "assertions" / "location_consumer.mojo"
)
COMPILE_TIMEOUT_SECONDS = 120
RUN_TIMEOUT_SECONDS = 30
LOCATION_MARKER = "# ASSERT-LOCATION:"
EXPLICIT_LOCATION_MARKER = "# ASSERT-EXPLICIT-LOCATION:"
API_TESTS = {
    "test_message_call_shapes_and_explicit_location",
    "test_standard_and_companion_names_coexist",
    "test_pass_compares_once_and_never_renders",
    "test_failure_compares_once_and_renders_each_operand_once",
    "test_opaque_render_caps_apply_after_escaping",
    "test_many_small_formatter_writes_and_body_are_bounded",
    "test_text_first_difference_at_start_middle_end_and_ending",
    "test_text_scalar_labels_expose_invisible_differences",
    "test_text_line_endings_and_final_newline_are_explicit",
    "test_text_context_has_two_lines_each_side_and_safe_prefixes",
    "test_large_text_context_is_bounded_and_message_is_last",
    "test_list_replacement_and_insertions_are_clear_spans",
    "test_list_changed_content_and_lengths_have_exact_facts",
    "test_list_displays_eight_mismatches_and_counts_omitted_first",
    "test_nested_lists_are_opaque_and_user_message_is_last",
    "test_list_specializer_renders_zero_on_pass_and_eight_on_failure",
    "test_dictionary_categories_are_distinct_and_ordered",
    "test_dictionary_order_is_full_unsigned_utf8_not_insertion_order",
    "test_dictionary_displays_eight_per_category_with_totals_first",
    "test_dictionary_key_cap_boundary_and_opaque_fallback",
    "test_equal_dictionary_with_oversized_key_returns_without_rendering",
    "test_dictionary_specializer_renders_only_eight_changed_values",
}


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
        coordinate = (
            last_explicit if marker == EXPLICIT_LOCATION_MARKER else last_call
        )
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
            f"location consumer must terminate with exact exit 1, got "
            f"{run.returncode}"
        )
    if run.stderr:
        raise AssertionError(f"location consumer wrote stderr: {run.stderr}")
    if "CRASH" in run.stdout:
        raise AssertionError("location consumer reported CRASH")

    fail_rows = set(
        re.findall(r"^\s+FAIL \[[^\]]+\] ([A-Za-z0-9_]+)\s*$", run.stdout, re.M)
    )
    expected_rows = set(expected)
    if fail_rows != expected_rows:
        raise AssertionError(
            f"location consumer FAIL rows differ: expected "
            f"{sorted(expected_rows)}, got {sorted(fail_rows)}"
        )

    count = len(expected)
    summary = (
        f"{count} tests run: 0 passed , {count} failed , 0 skipped"
    )
    if summary not in run.stdout:
        raise AssertionError(f"location consumer summary differs: want {summary!r}")

    provider_root = source.parents[2] / "assertions-src" / "mtest" / "assertions"
    if f"At {provider_root}" in run.stdout:
        raise AssertionError("location consumer exposed a provider coordinate")

    escaped_source = re.escape(str(source))
    observed = {
        (int(line), int(column))
        for line, column in re.findall(
            rf"At {escaped_source}:(\d+):(\d+):", run.stdout
        )
    }
    expected_coordinates = set(expected.values())
    if observed != expected_coordinates:
        raise AssertionError(
            "location consumer coordinates differ: "
            f"expected {sorted(expected_coordinates)}, got {sorted(observed)}"
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
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
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
    if not output.is_file():
        raise AssertionError(f"compile did not create a fresh binary: {output}")


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
    if re.search(r"^\s+(?:FAIL|CRASH) \[", run.stdout, re.M):
        raise AssertionError(f"API consumer did not pass cleanly:\n{run.stdout}")
    pass_rows = set(
        re.findall(r"^\s+PASS \[[^\]]+\] ([A-Za-z0-9_]+)\s*$", run.stdout, re.M)
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
        re.M,
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


def check_assertions() -> None:
    """Compile and execute every assertion consumer at both optimization levels."""
    mojo_raw = shutil.which("mojo")
    if mojo_raw is None:
        raise AssertionError("mojo is not available on PATH")
    mojo = Path(mojo_raw).resolve()
    reset_build_root()
    locations = expected_locations(LOCATION_CONSUMER)

    for optimization, suffix in (("-O0", "o0"), ("-O3", "o3")):
        api_binary = BUILD_ROOT / f"api-{suffix}"
        _compile(mojo, API_CONSUMER, api_binary, optimization)
        api_run = _run_checked(
            [str(api_binary)],
            cwd=REPO_ROOT,
            timeout=RUN_TIMEOUT_SECONDS,
        )
        _validate_api_run(api_run, API_TESTS)

        location_binary = BUILD_ROOT / f"location-{suffix}"
        _compile(mojo, LOCATION_CONSUMER, location_binary, optimization)
        location_run = _run_checked(
            [str(location_binary)],
            cwd=REPO_ROOT,
            timeout=RUN_TIMEOUT_SECONDS,
        )
        validate_location_run(location_run, LOCATION_CONSUMER, locations)


def main() -> int:
    """Run the assertion companion gate."""
    try:
        check_assertions()
    except AssertionError as exc:
        print(f"assertions-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("assertions-check: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
