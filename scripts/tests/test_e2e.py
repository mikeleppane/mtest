#!/usr/bin/env python3
"""Focused tests for E2E native fault-source and command topology."""

from __future__ import annotations

import inspect
from dataclasses import FrozenInstanceError
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import time
import unittest

from scripts import e2e_check
from scripts.fixtures.toolchain import fake_retry_crash_mojo


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

CORE_SCENARIOS = (
    "manifest-completeness",
    "default-suite",
    "hostile",
    "single-pass",
    "exitfirst",
    "maxfail",
    "exclude+stale",
    "all-excluded",
    "empty-dir",
    "failing-gate",
    "quiet-verbose",
    "show-output",
    "durations",
    "color",
    "passthrough+forbidden",
    "out-of-root",
)
SELECTION_SCENARIOS = (
    "usage-refusals",
    "selection-keyword",
    "selection-node-id",
    "selection-union",
    "selection-malformed-node-id",
    "selection-unknown-test",
    "selection-empty",
    "selection-chameleon",
    "single-build",
    "stale-recovery-two-builds",
    "collect",
)
RESILIENCE_SCENARIOS = (
    "resilience-matrix",
    "retries-flaky",
    "crash-attribution",
    "attribution-reruns-crashed-binary",
    "compile-timeout",
    "compile-crash-signature",
    "timeout",
    "timeout-escalation",
    "precompile",
    "precompile-timeout",
    "precompile-crash-retry",
    "precompile-promotion",
    "internal-error",
    "runtime-open-failure",
    "interrupt",
)


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
    source = Path(e2e_check.JSON_TERMINAL_WRITE_FAULT).read_text(encoding="utf-8")
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
        e2e_check, "_json_terminal_write_fault_commands", None
    )
    if command_builder is None:
        raise AssertionError("E2E interposer command builder is missing")
    directory = "/tmp/mtest-json-terminal-fault"
    source = e2e_check.JSON_TERMINAL_WRITE_FAULT
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
            e2e_check._build_json_terminal_write_fault(
                raw_tmp,
                platform="darwin",
                compiler=false_program,
                platform_driver=str(marker_linker),
            )
        except e2e_check.ScenarioError as exc:
            if "could not compile" not in str(exc):
                raise AssertionError(
                    f"interposer compile failure lost its step: {exc}"
                ) from exc
        else:
            raise AssertionError("interposer compile failure was accepted")
        if link_marker.exists():
            raise AssertionError("interposer link ran after compilation failed")

        try:
            e2e_check._build_json_terminal_write_fault(
                raw_tmp,
                platform="darwin",
                compiler=compiler,
                platform_driver=false_program,
            )
        except e2e_check.ScenarioError as exc:
            if "could not link" not in str(exc):
                raise AssertionError(
                    f"interposer link failure lost its step: {exc}"
                ) from exc
        else:
            raise AssertionError("interposer link failure was accepted")


class E2EFaultTopologyTests(unittest.TestCase):
    def test_core_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import core

        owned = tuple(
            name
            for name, scenario in e2e_check.SCENARIOS
            if scenario.__module__ == core.__name__
        )
        self.assertEqual(owned, CORE_SCENARIOS)

    def test_selection_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import selection

        owned = tuple(
            name
            for name, scenario in e2e_check.SCENARIOS
            if scenario.__module__ == selection.__name__
        )
        self.assertEqual(owned, SELECTION_SCENARIOS)

    def test_resilience_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import resilience

        owned = tuple(
            name
            for name, scenario in e2e_check.SCENARIOS
            if scenario.__module__ == resilience.__name__
        )
        self.assertEqual(owned, RESILIENCE_SCENARIOS)
        source = inspect.getsource(resilience.s_resilience_matrix)
        self.assertIn("context.registry", source)
        self.assertNotIn("__main__", inspect.getsource(resilience))

    def test_runner_owns_results_manifest_access_and_hard_timeouts(self) -> None:
        from scripts.e2e import assertions, runner

        with tempfile.TemporaryDirectory(prefix="mtest-e2e-runner-") as raw_tmp:
            tmp = Path(raw_tmp)
            closes_streams = tmp / "closes-streams"
            _write_executable(
                closes_streams,
                "#!/usr/bin/env python3\n"
                "import os\n"
                "import time\n"
                "os.close(1)\n"
                "os.close(2)\n"
                "time.sleep(30)\n",
            )
            process_runner = runner.E2ERunner(
                repo_root=tmp,
                mtest=closes_streams,
                default_timeout=0.1,
                short_timeout=0.1,
            )

            started = time.monotonic()
            with self.assertRaisesRegex(
                runner.ScenarioError, "did not return within 0.1s"
            ):
                process_runner.run_mtest([])
            self.assertLess(time.monotonic() - started, 2.0)

            started = time.monotonic()
            with self.assertRaisesRegex(
                runner.ScenarioError, "closed its pty but never exited"
            ):
                process_runner.run_mtest_pty([])
            self.assertLess(time.monotonic() - started, 2.0)

        self.assertIs(e2e_check.Run, runner.Run)
        self.assertIs(e2e_check.ScenarioContext, runner.ScenarioContext)
        self.assertIs(e2e_check.expect_exit, assertions.expect_exit)
        self.assertEqual(
            runner.load_manifest()["e2e_root"],
            "e2e",
        )
        self.assertEqual(
            set(runner.load_manifest()["tests"]),
            runner.discovered_test_files(),
        )

    def test_main_open_check_has_one_package_owner(self) -> None:
        from scripts.e2e import main_open

        self.assertIs(e2e_check.main_open_check, main_open)

    def test_scenarios_receive_an_explicit_immutable_context(self) -> None:
        registry = tuple(e2e_check.SCENARIOS)
        context = e2e_check.ScenarioContext(manifest={}, registry=registry)

        self.assertIs(context.registry, registry)
        with self.assertRaises(FrozenInstanceError):
            context.registry = ()
        for name, scenario in registry:
            with self.subTest(scenario=name):
                self.assertEqual(
                    tuple(inspect.signature(scenario).parameters),
                    ("context",),
                )

    def test_harness_passes_the_context_and_contains_later_scenarios(self) -> None:
        registry = ()
        context = e2e_check.ScenarioContext(
            manifest={"sentinel": 42}, registry=registry
        )
        harness = e2e_check.Harness(context)
        received: list[e2e_check.ScenarioContext] = []

        def crashes(scenario_context: e2e_check.ScenarioContext) -> str:
            received.append(scenario_context)
            raise RuntimeError("escaped")

        def passes(scenario_context: e2e_check.ScenarioContext) -> str:
            received.append(scenario_context)
            return "continued"

        harness.scenario("crashes", crashes)
        harness.scenario("passes", passes)

        self.assertEqual(received, [context, context])
        self.assertEqual(
            [name for name, _ok, _detail in harness.results],
            ["crashes", "passes"],
        )
        self.assertFalse(harness.results[0][1])
        self.assertIn("RuntimeError escaped", harness.results[0][2])
        self.assertEqual(harness.results[1], ("passes", True, "continued"))

    def test_resilience_audit_reads_the_context_registry(self) -> None:
        from scripts.e2e.scenarios import resilience

        def harmless(_context: e2e_check.ScenarioContext) -> str:
            return ""

        names = tuple(dict.fromkeys(resilience.RESILIENCE_MATRIX.values()))
        context = e2e_check.ScenarioContext(
            manifest={},
            registry=tuple((name, harmless) for name in names),
        )
        original = e2e_check.SCENARIOS
        e2e_check.SCENARIOS = ()
        try:
            detail = resilience.s_resilience_matrix(context)
        finally:
            e2e_check.SCENARIOS = original

        self.assertIn("each covered by a registered scenario", detail)

    def test_paths_and_retry_marker_are_repository_anchored(self) -> None:
        root = Path(__file__).resolve().parents[2]
        fixture_root = root / "scripts" / "fixtures" / "toolchain"
        self.assertEqual(
            (
                Path(e2e_check.LOGGING_MOJO),
                Path(e2e_check.FAKE_SLOW_MOJO),
                Path(e2e_check.FAKE_CRASH_MOJO),
                Path(e2e_check.FAKE_RETRY_CRASH_MOJO),
            ),
            (
                fixture_root / "logging_mojo.py",
                fixture_root / "fake_slow_mojo.py",
                fixture_root / "fake_crash_mojo.py",
                fixture_root / "fake_retry_crash_mojo.py",
            ),
        )
        self.assertEqual(Path(fake_retry_crash_mojo.REPO_ROOT), root)
        self.assertEqual(
            Path(fake_retry_crash_mojo.MARKER),
            root / "build" / "e2e-scratch" / "retry_crash_build_marker",
        )

    def test_toolchain_fixtures_remain_executable(self) -> None:
        for fixture in (
            e2e_check.LOGGING_MOJO,
            e2e_check.FAKE_SLOW_MOJO,
            e2e_check.FAKE_CRASH_MOJO,
            e2e_check.FAKE_RETRY_CRASH_MOJO,
        ):
            with self.subTest(fixture=fixture):
                self.assertTrue(os.access(fixture, os.X_OK))

    def test_interposer_source_policy_rejects_mutations(self) -> None:
        check_e2e_interposer_source_policy()

    def test_interposer_commands_are_platform_exact(self) -> None:
        check_e2e_interposer_command_topology()

    def test_interposer_build_failures_name_the_failed_step(self) -> None:
        check_e2e_interposer_failure_propagation()


if __name__ == "__main__":
    unittest.main()
