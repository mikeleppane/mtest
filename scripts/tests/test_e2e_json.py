#!/usr/bin/env python3
"""Focused tests for the JSON terminal-write fault source and build topology."""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import unittest

from scripts.e2e.scenarios import json_reporter


def _write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


DARWIN_INTERPOSE_DECLARATION = r"""#if defined(__APPLE__)
#define MTEST_PRELOAD_VARIABLE "DYLD_INSERT_LIBRARIES"
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee \
        __attribute__((section("__DATA,__interpose,interposing"))) = { \
            (const void *)(unsigned long)&_replacement, \
            (const void *)(unsigned long)&_replacee, \
        };
#else
#define MTEST_PRELOAD_VARIABLE "LD_PRELOAD"
#include <dlfcn.h>
#endif"""


def _check_e2e_interposer_source_policy(source: str) -> None:
    """Validate the write-fault fixture's platform forwarding contracts."""
    if source.count(DARWIN_INTERPOSE_DECLARATION) != 1:
        raise AssertionError(
            "E2E interposer must contain the canonical local Darwin declaration "
            "and select dlfcn.h only elsewhere"
        )
    inheritance_guard = (
        "__attribute__((constructor)) static void "
        "mtest_stop_preload_inheritance(void) {\n"
        "    unsetenv(MTEST_PRELOAD_VARIABLE);\n"
        "}"
    )
    if source.count(inheritance_guard) != 1:
        raise AssertionError(
            "E2E interposer must clear its loader variable before mtest spawns "
            "the Mojo compiler"
        )

    split_marker = "#if defined(__APPLE__)"
    platform_splits = source.split(split_marker)
    if len(platform_splits) != 3:
        raise AssertionError(
            "E2E interposer must contain exactly one include split and one "
            "platform implementation split"
        )
    apple_branch, separator, remainder = platform_splits[2].partition("#else")
    if not separator:
        raise AssertionError("E2E interposer platform split lacks a non-Darwin branch")
    other_branch, terminator, tail = remainder.partition("#endif")
    if not terminator:
        raise AssertionError("E2E interposer platform split lacks its #endif")

    def active_source(branch: str) -> str:
        without_blocks = re.sub(r"/\*.*?\*/", "", branch, flags=re.DOTALL)
        return "\n".join(
            line.split("//", 1)[0] for line in without_blocks.splitlines()
        )

    active_apple = active_source(apple_branch)
    active_other = active_source(other_branch)
    active_tail = active_source(tail)
    active_apple_lines = {line.strip() for line in active_apple.splitlines()}
    apple_required = {
        "struct iovec vector = {(void *)buffer, count};",
        "return writev(fd, &vector, 1);",
        "DYLD_INTERPOSE(mtest_faulting_write, write)",
    }
    apple_forbidden = (
        "RTLD_NEXT",
        "mtest_real_write",
        "__interpose",
        "return write(fd, buffer, count);",
        "ssize_t write(int fd, const void *buffer, size_t count)",
    )
    other_required = (
        "__attribute__((constructor))",
        'dlsym(RTLD_NEXT, "write")',
        "ssize_t write(int fd, const void *buffer, size_t count)",
    )
    if not apple_required.issubset(active_apple_lines):
        raise AssertionError(
            "Darwin E2E interposer must use DYLD_INTERPOSE and writev "
            "forwarding"
        )
    if any(fragment in active_apple for fragment in apple_forbidden):
        raise AssertionError(
            "Darwin E2E interposer contains Linux forwarding or a hand-rolled "
            "interpose tuple"
        )
    if any(fragment not in active_other for fragment in other_required):
        raise AssertionError(
            "non-Darwin E2E interposer must retain constructor-resolved "
            "RTLD_NEXT forwarding"
        )
    if "DYLD_INTERPOSE" in active_other:
        raise AssertionError("non-Darwin E2E interposer contains Darwin forwarding")
    if active_tail.strip():
        raise AssertionError(
            "E2E interposer platform implementation split must contain all "
            "active trailing code"
        )


def check_e2e_interposer_source_policy() -> None:
    """The interposer policy rejects known source-level bypass mutations."""
    source = Path(json_reporter.JSON_TERMINAL_WRITE_FAULT).read_text(encoding="utf-8")
    _check_e2e_interposer_source_policy(source)

    registration = "DYLD_INTERPOSE(mtest_faulting_write, write)"
    call_through = "return writev(fd, &vector, 1);"
    wrapper = (
        "ssize_t write(int fd, const void *buffer, size_t count) {\n"
        "    return mtest_faulting_write(fd, buffer, count);\n"
        "}\n\n"
    )
    mutations = {
        "commented Darwin registration": source.replace(
            registration, "// " + registration, 1
        ),
        "commented Darwin call-through": source.replace(
            call_through, "// " + call_through, 1
        ),
        "exported Darwin write wrapper": source.replace(
            registration + "\n", registration + "\n\n" + wrapper, 1
        ),
        "legacy Darwin section declaration": source.replace(
            "__DATA,__interpose,interposing", "__DATA,__interpose", 1
        ),
        "preload inherited by compiler child": source.replace(
            "    unsetenv(MTEST_PRELOAD_VARIABLE);",
            "    // unsetenv(MTEST_PRELOAD_VARIABLE);",
            1,
        ),
    }
    for name, mutation in mutations.items():
        if mutation == source:
            raise AssertionError(f"E2E interposer mutation did not apply: {name}")
        try:
            _check_e2e_interposer_source_policy(mutation)
        except AssertionError:
            continue
        raise AssertionError(f"E2E interposer policy accepted mutation: {name}")


def check_e2e_interposer_command_topology() -> None:
    """The E2E write-fault interposer has exact target-specific build steps."""
    command_builder = getattr(
        json_reporter, "_json_terminal_write_fault_commands", None
    )
    if command_builder is None:
        raise AssertionError("E2E interposer command builder is missing")
    directory = "/tmp/mtest-json-terminal-fault"
    source = json_reporter.JSON_TERMINAL_WRITE_FAULT
    object_path = os.path.join(directory, "mtest_json_terminal_fault.o")
    common_compile = [
        "/pinned/clang",
        "-std=c17",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        "-fPIC",
        "-c",
        source,
        "-o",
        object_path,
    ]

    darwin_library, darwin_steps = command_builder(
        directory,
        "/pinned/clang",
        platform="darwin",
        platform_driver="/usr/bin/cc",
    )
    expected_darwin_library = os.path.join(
        directory, "libmtest_json_terminal_fault.dylib"
    )
    expected_darwin_steps = [
        ("compile", common_compile),
        (
            "link",
            [
                "/usr/bin/cc",
                "-dynamiclib",
                object_path,
                "-o",
                expected_darwin_library,
            ],
        ),
    ]
    if (darwin_library, darwin_steps) != (
        expected_darwin_library,
        expected_darwin_steps,
    ):
        raise AssertionError(
            "Darwin E2E interposer command topology mismatch: "
            f"actual={(darwin_library, darwin_steps)!r}"
        )

    linux_library, linux_steps = command_builder(
        directory,
        "/pinned/clang",
        platform="linux",
        platform_driver="/unused/platform/driver",
    )
    expected_linux_library = os.path.join(
        directory, "libmtest_json_terminal_fault.so"
    )
    expected_linux_steps = [
        ("compile", common_compile),
        (
            "link",
            [
                "/pinned/clang",
                "-shared",
                object_path,
                "-o",
                expected_linux_library,
                "-ldl",
            ],
        ),
    ]
    if (linux_library, linux_steps) != (
        expected_linux_library,
        expected_linux_steps,
    ):
        raise AssertionError(
            "Linux E2E interposer command topology mismatch: "
            f"actual={(linux_library, linux_steps)!r}"
        )


def check_e2e_interposer_failure_propagation() -> None:
    """Compile and link failures stop at, and name, their exact build step."""
    false_program = shutil.which("false")
    compiler = shutil.which("clang")
    if false_program is None or compiler is None:
        raise AssertionError("harness lacks clang/false for E2E interposer probes")
    with tempfile.TemporaryDirectory(prefix="mtest-e2e-interposer-") as raw_tmp:
        tmp = Path(raw_tmp)
        link_marker = tmp / "link-ran"
        marker_linker = tmp / "marker-linker"
        _write_executable(
            marker_linker,
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            f"Path({str(link_marker)!r}).touch()\n",
        )
        try:
            json_reporter._build_json_terminal_write_fault(
                raw_tmp,
                platform="darwin",
                compiler=false_program,
                platform_driver=str(marker_linker),
            )
        except json_reporter.ScenarioError as exc:
            if "could not compile" not in str(exc):
                raise AssertionError(
                    f"interposer compile failure lost its step: {exc}"
                ) from exc
        else:
            raise AssertionError("interposer compile failure was accepted")
        if link_marker.exists():
            raise AssertionError("interposer link ran after compilation failed")

        try:
            json_reporter._build_json_terminal_write_fault(
                raw_tmp,
                platform="darwin",
                compiler=compiler,
                platform_driver=false_program,
            )
        except json_reporter.ScenarioError as exc:
            if "could not link" not in str(exc):
                raise AssertionError(
                    f"interposer link failure lost its step: {exc}"
                ) from exc
        else:
            raise AssertionError("interposer link failure was accepted")


class E2EJsonFaultTopologyTests(unittest.TestCase):
    def test_interposer_source_policy_rejects_mutations(self) -> None:
        check_e2e_interposer_source_policy()

    def test_interposer_commands_are_platform_exact(self) -> None:
        check_e2e_interposer_command_topology()

    def test_interposer_build_failures_name_the_failed_step(self) -> None:
        check_e2e_interposer_failure_propagation()


if __name__ == "__main__":
    unittest.main()
