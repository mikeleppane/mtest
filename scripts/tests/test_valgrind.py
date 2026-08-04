#!/usr/bin/env python3
"""Unit tests for the Valgrind gate's fail-closed diagnostics."""

from __future__ import annotations

import contextlib
import inspect
import io
from pathlib import Path
import subprocess
import tempfile
from typing import TYPE_CHECKING
import unittest
from unittest.mock import patch

from scripts.checks import native_abi as native_abi_check
from scripts.checks.memory import asan as asan_check
from scripts.checks.memory import valgrind as valgrind_check


if TYPE_CHECKING:
    from collections.abc import Callable


def valgrind_writing_its_log(
    result: subprocess.CompletedProcess[str], log_text: str = ""
) -> Callable[..., subprocess.CompletedProcess[str]]:
    """Build a `valgrind` stand-in that materializes its `--log-file` target.

    The real `valgrind()` hands the CLI lane's Memcheck diagnostics to a file
    rather than to the pipe, so a bare `return_value` mock leaves `check_cli`
    with no log to read. Writing the file keeps these tests on the same
    two-channel shape production runs use.

    Args:
        result: What the stand-in returns, standing for the client's own run.
        log_text: What Valgrind is pretended to have written to its log.

    Returns:
        A callable usable as `patch.object(..., side_effect=...)`, so the mock
        still records the arguments each call site passed.
    """

    def fake(
        _command: list[str], _env: dict[str, str], **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        log_file = kwargs.get("log_file")
        if isinstance(log_file, Path):
            log_file.write_text(log_text, encoding="utf-8")
        return result

    return fake


class ValgrindCheckTests(unittest.TestCase):
    def test_repository_root_is_exact(self) -> None:
        self.assertEqual(valgrind_check.ROOT, Path(__file__).resolve().parents[2])

    def test_scanned_roots_are_exact(self) -> None:
        self.assertEqual(
            valgrind_check.EXEC_TEST_ROOT.relative_to(valgrind_check.ROOT).as_posix(),
            "tests/integration",
        )
        self.assertEqual(
            valgrind_check.CONFIG_TEST.relative_to(valgrind_check.ROOT).as_posix(),
            "tests/unit/test_config.mojo",
        )

    def test_source_inventories_are_nonempty(self) -> None:
        self.assertGreater(len(valgrind_check.NATIVE_TESTS), 0)
        self.assertGreater(len(valgrind_check.TESTS), 0)

    def test_empty_native_source_inventory_is_rejected(self) -> None:
        with (
            patch.object(valgrind_check, "NATIVE_TESTS", ()),
            self.assertRaisesRegex(SystemExit, "native source inventory is empty"),
        ):
            valgrind_check.main()

    def test_empty_mojo_source_inventory_is_rejected(self) -> None:
        with (
            patch.object(valgrind_check, "TESTS", ()),
            self.assertRaisesRegex(SystemExit, "Mojo source inventory is empty"),
        ):
            valgrind_check.main()

    def test_classified_suite_builds_source_directly(self) -> None:
        """The Valgrind lane builds `source` itself, with no generated wrapper.

        Every classified module declares its own `main()` now, so there is no
        `*_main.mojo` wrapper and no `import tests.unit.<module>` alias to
        assert on.
        """
        source = valgrind_check.ROOT / "tests" / "unit" / "test_config.mojo"
        completed = subprocess.CompletedProcess(
            args=["valgrind"], returncode=0, stdout=""
        )
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(valgrind_check, "OUT", out),
                patch.object(
                    valgrind_check, "run", return_value=completed
                ) as mocked_run,
                patch.object(valgrind_check, "valgrind", return_value=completed),
                patch.object(valgrind_check, "check_product_output"),
                patch.object(valgrind_check, "check_postfork_output"),
            ):
                valgrind_check.compile_and_run_test(source, {})

            compile_command = mocked_run.call_args_list[0].args[0]
            self.assertIn(str(source.relative_to(valgrind_check.ROOT)), compile_command)
            target_index = compile_command.index("--target-cpu")
            self.assertEqual(
                compile_command[target_index : target_index + 2],
                ["--target-cpu", "x86-64-v3"],
            )
            self.assertNotIn(
                ".",
                compile_command,
                "-I . is no longer needed: the source itself never imports "
                "tests.unit.<module> or tests.integration.<module>",
            )
            generated_wrappers = list(out.glob("*_main.mojo"))
            self.assertEqual(
                generated_wrappers,
                [],
                f"no *_main.mojo wrapper should be generated, "
                f"found {generated_wrappers}",
            )

    def test_prepare_test_scratch_creates_missing_parent_tree(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp) / "build" / "tests"
            with patch.object(valgrind_check, "TEST_SCRATCH", scratch):
                valgrind_check.prepare_test_scratch()

            self.assertTrue(scratch.is_dir())

    def test_startup_failure_reports_valgrind_diagnostic(self) -> None:
        result = subprocess.CompletedProcess(
            args=["valgrind"],
            returncode=1,
            stdout=(
                "valgrind:  Fatal error at startup: a function redirection\n"
                "valgrind:  Possible fixes: install libc6-dbg\n"
            ),
        )

        command = ["build/safety/valgrind/native_controls", "mem-undefined"]
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(valgrind_check, "OUT", out),
                patch.object(valgrind_check, "run", return_value=result),
                self.assertRaises(SystemExit) as raised,
            ):
                valgrind_check.valgrind(command, {}, quiet_child=False)

            log = out / "startup-failure.log"
            self.assertTrue(log.exists())
            self.assertEqual(log.read_text(), result.stdout)

        message = str(raised.exception)
        self.assertIn("Valgrind failed to start", message)
        self.assertIn("native_controls mem-undefined", message)
        self.assertIn("install libc6-dbg", message)

    def test_report_ownership_suites_are_in_the_source_built_subset(self) -> None:
        selected = tuple(
            path.relative_to(valgrind_check.ROOT).as_posix()
            for path in valgrind_check.TESTS
        )
        self.assertEqual(
            tuple(
                path.relative_to(valgrind_check.ROOT).as_posix()
                for path in valgrind_check.REPORT_TESTS
            ),
            (
                "tests/unit/test_report_escape.mojo",
                "tests/unit/test_report_junit.mojo",
                "tests/unit/test_report_junit_finalize.mojo",
                "tests/unit/test_report_writer.mojo",
            ),
        )
        for source in valgrind_check.REPORT_TESTS:
            self.assertIn(source.relative_to(valgrind_check.ROOT).as_posix(), selected)

    def test_the_descriptor_adversarial_suite_is_excluded_here_but_not_in_asan(
        self,
    ) -> None:
        """The one exclusion is deliberate, and covered by the other lane.

        `test_report_json_reporter.mojo` closes a descriptor then writes to it,
        and closes the same descriptor twice, on purpose. `--track-fds=yes`
        reports both, so this lane cannot run it without dropping the
        descriptor channel or relaxing a contract seventeen other suites depend
        on.
        """
        self.assertEqual(
            valgrind_check.FD_ADVERSARIAL_SUITE.relative_to(
                valgrind_check.ROOT
            ).as_posix(),
            "tests/unit/test_report_json_reporter.mojo",
        )
        self.assertNotIn(valgrind_check.FD_ADVERSARIAL_SUITE, valgrind_check.TESTS)
        self.assertIn(valgrind_check.FD_ADVERSARIAL_SUITE, asan_check.TESTS)


class ValgrindCliProbeTests(unittest.TestCase):
    """The Memcheck-wrapped real-CLI reporter run and its provenance proof."""

    def test_cli_probe_inventory_is_exact(self) -> None:
        self.assertEqual(
            valgrind_check.CLI_SOURCE.relative_to(valgrind_check.ROOT).as_posix(),
            "src/main.mojo",
        )
        self.assertEqual(
            valgrind_check.VENDORED_TOML_INCLUDE.relative_to(
                valgrind_check.ROOT
            ).as_posix(),
            "vendor/mojo-toml",
        )
        self.assertEqual(
            valgrind_check.HOSTILE_BUILD_STANDIN.relative_to(
                valgrind_check.ROOT
            ).as_posix(),
            "scripts/fixtures/toolchain/fake_hostile_mojo.py",
        )
        self.assertEqual(
            valgrind_check.HOSTILE_ACTOR.relative_to(valgrind_check.ROOT).as_posix(),
            "tests/fixtures/exec/hostile_report_actor.py",
        )
        self.assertEqual(
            valgrind_check.NATIVE_PRODUCTION_OBJECT.name,
            "mtest_exec_native.o",
        )

    def test_both_lanes_drive_the_byte_identical_probe(self) -> None:
        """The two gate drivers hold their own copies; drift must be loud.

        Each lane defines the probe tree, its configuration, and its argv
        locally, because the two drivers share no module. A silent divergence
        would leave the lanes claiming the same coverage while running
        different programs, so every shared value is compared here.
        """
        for name in (
            "CLI_PROBE_TREE",
            "CLI_PROBE_MODULE",
            "CLI_PROBE_STREAM",
            "CLI_PROBE_REPORT",
            "CLI_PROBE_MD",
            "CLI_PROBE_HTML",
            "CLI_PROBE_KEYWORD",
            "CLI_PROBE_EXIT",
            "CLI_PROBE_ESCAPED_LINE",
            "CLI_PROBE_RAW_BYTES",
            "CLI_PROBE_SOURCE",
            "CLI_PROBE_CONFIG",
        ):
            with self.subTest(constant=name):
                self.assertEqual(
                    getattr(valgrind_check, name), getattr(asan_check, name)
                )
        for name in (
            "CLI_SOURCE",
            "VENDORED_TOML_INCLUDE",
            "HOSTILE_BUILD_STANDIN",
            "HOSTILE_ACTOR",
        ):
            with self.subTest(constant=name):
                self.assertEqual(
                    getattr(valgrind_check, name), getattr(asan_check, name)
                )
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp)
            self.assertEqual(
                valgrind_check.cli_probe_command(scratch / "mtest", scratch),
                asan_check.cli_probe_command(scratch / "mtest", scratch),
            )

    def test_both_lanes_hold_the_same_probe_oracle_source(self) -> None:
        """The duplicated FUNCTIONS, not just the constants, must stay in step.

        The constants above pin what the probe runs; these three functions
        materialize it and judge the result, copied into both drivers because
        the two share no module. Equal constants over a diverged oracle would
        let both lanes run the identical program and disagree about whether it
        passed.

        Comparing source text is exact and deliberately brittle about
        formatting: a reworded docstring in one copy reds here, which is the
        cost of keeping two copies at all.
        """
        for name in (
            "write_cli_probe_tree",
            "cli_probe_command",
            "check_cli_probe_output",
        ):
            with self.subTest(function=name):
                self.assertEqual(
                    inspect.getsource(getattr(valgrind_check, name)),
                    inspect.getsource(getattr(asan_check, name)),
                )

    def test_cli_probe_flags_keep_the_locked_scope(self) -> None:
        self.assertIn("--trace-children=no", valgrind_check.CLI_VALGRIND_FLAGS)
        self.assertIn("--track-fds=yes", valgrind_check.CLI_VALGRIND_FLAGS)
        self.assertIn("--tool=memcheck", valgrind_check.CLI_VALGRIND_FLAGS)
        self.assertIn("--error-exitcode=99", valgrind_check.CLI_VALGRIND_FLAGS)
        self.assertIn("--default-suppressions=no", valgrind_check.CLI_VALGRIND_FLAGS)
        self.assertIn("--leak-check=full", valgrind_check.CLI_VALGRIND_FLAGS)

    def test_only_the_cli_probe_drops_the_possibly_lost_error_channel(
        self,
    ) -> None:
        """The one relaxation is pinned on both sides, so it cannot spread.

        `CLI_VALGRIND_FLAGS` omits `possible` from `--errors-for-leak-kinds`
        because the Mojo runtime's unjoined CPU-device threads leave glibc TLS
        descriptor tables Memcheck can only classify that way, and that
        relaxation is legitimate for the CLI probe alone. Pinning both values
        makes the DIFFERENCE between the lanes the thing under test: copying
        the CLI precedent into `VALGRIND_FLAGS` would cost seventeen suites
        their possibly-lost channel while every other test here still passed.
        """
        self.assertIn(
            "--errors-for-leak-kinds=definite,indirect,possible",
            valgrind_check.VALGRIND_FLAGS,
        )
        self.assertIn(
            "--errors-for-leak-kinds=definite,indirect",
            valgrind_check.CLI_VALGRIND_FLAGS,
        )
        self.assertNotIn(
            "--errors-for-leak-kinds=definite,indirect",
            valgrind_check.VALGRIND_FLAGS,
        )
        self.assertNotIn(
            "--errors-for-leak-kinds=definite,indirect,possible",
            valgrind_check.CLI_VALGRIND_FLAGS,
        )
        # The post-fork audit sets `--leak-check=no`, so it carries no
        # leak-kind selection at all; a value appearing there would be new.
        self.assertFalse(
            any(
                flag.startswith("--errors-for-leak-kinds")
                for flag in valgrind_check.POSTFORK_FLAGS
            )
        )

    def test_the_relaxed_channel_is_compensated_by_the_frame_filter(
        self,
    ) -> None:
        """Dropping `possible` from the ERROR channel does not drop the claim.

        A possibly-lost record carrying a product frame must still fail the
        probe, because that is the finding the relaxation could otherwise hide.
        """
        polluted = ValgrindCliProvenanceTests.CLEAN.replace(
            "==1== LEAK SUMMARY:\n",
            "==1== 64 bytes in 1 blocks are possibly lost in loss record 1 of 1\n"
            "==1==    by 0x1: read_bounded_regular_file (src/mtest/platform/"
            "regular_file.mojo:76)\n"
            "==1== \n"
            "==1== LEAK SUMMARY:\n",
        )
        with self.assertRaisesRegex(SystemExit, "product allocation"):
            valgrind_check.check_cli_provenance(valgrind_check.CLI_PROBE_EXIT, polluted)

    def test_cli_probe_build_uses_the_locked_target_cpu_and_production_object(
        self,
    ) -> None:
        completed = subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout="")
        wrapped = subprocess.CompletedProcess(
            args=["valgrind"],
            returncode=valgrind_check.CLI_PROBE_EXIT,
            stdout="",
        )
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(valgrind_check, "OUT", out),
                patch.object(valgrind_check, "CLI_BINARY", out / "mtest"),
                patch.object(valgrind_check, "CLI_SCRATCH", out / "cli"),
                patch.object(
                    valgrind_check, "run", return_value=completed
                ) as mocked_run,
                patch.object(
                    valgrind_check,
                    "valgrind",
                    side_effect=valgrind_writing_its_log(wrapped),
                ) as mocked_valgrind,
                patch.object(valgrind_check, "check_cli_provenance"),
                patch.object(
                    valgrind_check, "check_cli_probe_output", return_value="ok"
                ),
            ):
                valgrind_check.check_cli({})

            compile_command = mocked_run.call_args_list[0].args[0]
            target_index = compile_command.index("--target-cpu")
            self.assertEqual(
                compile_command[target_index : target_index + 2],
                ["--target-cpu", "x86-64-v3"],
            )
            self.assertIn("src/main.mojo", compile_command)
            self.assertIn(str(valgrind_check.VENDORED_TOML_INCLUDE), compile_command)
            self.assertIn(str(valgrind_check.NATIVE_PRODUCTION_OBJECT), compile_command)

            wrapped_command = mocked_valgrind.call_args_list[0].args[0]
            self.assertEqual(wrapped_command[0], str(out / "mtest"))
            self.assertEqual(
                mocked_valgrind.call_args_list[0].kwargs["flags"],
                valgrind_check.CLI_VALGRIND_FLAGS,
            )
            # The Memcheck channel goes to its own file, and that file has to
            # keep the `.log` suffix: the workflow uploads this lane's artifact
            # as `build/safety/valgrind/*.log`, so any other name would drop
            # Valgrind's diagnostics out of the uploaded evidence entirely.
            log_file = mocked_valgrind.call_args_list[0].kwargs["log_file"]
            self.assertEqual(log_file.parent, out)
            self.assertEqual(log_file.suffix, ".log")
            self.assertTrue(log_file.is_file())

    def test_check_cli_actually_calls_the_provenance_check(self) -> None:
        """The provenance control must be ON the call path, not merely defined.

        The build/wrapper test above patches `check_cli_provenance` out, so
        without this one the whole Memcheck-provenance control could be deleted
        from `check_cli` and every test would stay green.

        The banner-less text is planted in the VALGRIND log rather than the
        client's stdout, so this also pins which channel provenance judges: it
        is the only one that can carry a banner.
        """
        completed = subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout="")
        unwrapped = subprocess.CompletedProcess(
            args=["mtest"],
            returncode=valgrind_check.CLI_PROBE_EXIT,
            stdout="mtest output with no Memcheck banner anywhere\n",
        )
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(valgrind_check, "OUT", out),
                patch.object(valgrind_check, "CLI_BINARY", out / "mtest"),
                patch.object(valgrind_check, "CLI_SCRATCH", out / "cli"),
                patch.object(valgrind_check, "CLI_HOME", out / "home"),
                patch.object(valgrind_check, "run", return_value=completed),
                patch.object(
                    valgrind_check,
                    "valgrind",
                    side_effect=valgrind_writing_its_log(
                        unwrapped, "no Memcheck banner in this log either\n"
                    ),
                ),
                patch.object(
                    valgrind_check, "check_cli_probe_output", return_value="ok"
                ),
                self.assertRaisesRegex(SystemExit, "Memcheck banner"),
            ):
                valgrind_check.check_cli({})

    def test_production_native_object_drops_the_testing_controls(self) -> None:
        completed = subprocess.CompletedProcess(args=["cc"], returncode=0, stdout="")
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(valgrind_check, "OUT", out),
                patch.object(
                    valgrind_check,
                    "NATIVE_PRODUCTION_OBJECT",
                    out / "mtest_exec_native.o",
                ),
                patch.object(valgrind_check, "NATIVE_OBJECT", out / "test.o"),
                patch.object(
                    valgrind_check, "run", return_value=completed
                ) as mocked_run,
            ):
                valgrind_check.compile_inputs("cc", {})

            production = [
                call.args[0]
                for call in mocked_run.call_args_list
                if str(out / "mtest_exec_native.o") in call.args[0]
            ]
            self.assertEqual(len(production), 1)
            self.assertIn("-DMTEST_EXEC_TESTING=0", production[0])
            self.assertNotIn("-DMTEST_EXEC_TESTING=1", production[0])


class ValgrindCliProvenanceTests(unittest.TestCase):
    """A probe that never ran under Memcheck must not read as a clean pass."""

    CLEAN = (
        "==1== Memcheck, a memory error detector\n"
        "==1== FILE DESCRIPTORS: 3 open (3 inherited) at exit.\n"
        # A real log always carries reachable records: the Mojo runtime
        # allocates and does not free at exit, which is what EXPECTED_REACHABLE
        # pins for the suite lane. The fixture carries one so the record scan
        # has something to inspect, exactly as the gate requires.
        "==1== 72 bytes in 3 blocks are still reachable in loss record 1 of 1\n"
        "==1==    at 0x1: malloc (vg_replace_malloc.c:1)\n"
        "==1==    by 0x2: runtime_init (libmojo.so)\n"
        "==1== \n"
        "==1== LEAK SUMMARY:\n"
        "==1==    definitely lost: 0 bytes in 0 blocks\n"
        "==1==    indirectly lost: 0 bytes in 0 blocks\n"
        "==1==         suppressed: 0 bytes in 0 blocks\n"
        "==1== ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 0 from 0)\n"
    )

    def test_clean_memcheck_log_is_accepted(self) -> None:
        valgrind_check.check_cli_provenance(valgrind_check.CLI_PROBE_EXIT, self.CLEAN)

    def test_log_without_the_memcheck_banner_is_rejected(self) -> None:
        stripped = self.CLEAN.replace("==1== Memcheck, a memory error detector\n", "")
        with self.assertRaisesRegex(SystemExit, "Memcheck banner"):
            valgrind_check.check_cli_provenance(valgrind_check.CLI_PROBE_EXIT, stripped)

    def test_log_without_a_zero_error_summary_is_rejected(self) -> None:
        stripped = self.CLEAN.replace(
            "==1== ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 0 from 0)\n",
            "",
        )
        with self.assertRaisesRegex(SystemExit, "ERROR SUMMARY"):
            valgrind_check.check_cli_provenance(valgrind_check.CLI_PROBE_EXIT, stripped)

    def test_log_without_the_expected_fd_summary_is_rejected(self) -> None:
        stripped = self.CLEAN.replace(
            "==1== FILE DESCRIPTORS: 3 open (3 inherited) at exit.\n", ""
        )
        with self.assertRaisesRegex(SystemExit, "descriptor summary"):
            valgrind_check.check_cli_provenance(valgrind_check.CLI_PROBE_EXIT, stripped)

    def test_memcheck_error_exit_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "exited 99"):
            valgrind_check.check_cli_provenance(99, self.CLEAN)

    def test_retained_product_allocation_is_rejected(self) -> None:
        polluted = self.CLEAN.replace(
            "==1== LEAK SUMMARY:\n",
            "==1== 64 bytes in 1 blocks are possibly lost in loss record 1 of 1\n"
            "==1==    by 0x1: something (src/mtest/report/junit.mojo:1)\n"
            "==1== \n"
            "==1== LEAK SUMMARY:\n",
        )
        with self.assertRaisesRegex(SystemExit, "product allocation"):
            valgrind_check.check_cli_provenance(valgrind_check.CLI_PROBE_EXIT, polluted)


class ValgrindCliChannelSeparationTests(unittest.TestCase):
    r"""Valgrind's own diagnostics must never be judged as client output.

    `run` merges the client's stderr into its stdout, and Valgrind writes its
    diagnostics to stderr, so an unredirected wrapped run hands
    `check_cli_probe_output` one string holding both channels. That gate's
    subject is what a HOSTILE child can make mtest's console emit, and Memcheck
    prints demangled symbol names verbatim: the 1.0.0b2 toolchain mangles a
    parameterized `_Global` type name with a literal ESC byte, so Valgrind's own
    frame lines failed the raw-control-byte scan for bytes mtest never wrote.

    Separating the channels is the fix under test. Filtering `^==\d+== ` lines
    out before the scan would leave a hostile child printing `==999== <ESC>[2J`
    to walk straight through, whereas a client cannot write into Valgrind's
    private log no matter what bytes it emits.
    """

    MANGLED_GLOBAL_FRAME = (
        "==1==    by 0x4081915: std::ffi::__init__::_Global::get_or_create_ptr(),"
        'StorageType=[typevalue<#kgen.instref<\x1b"mtest::session::store::'
        '_ToolchainDigest">>],name={ #interp.memref<16, '
        '"mtest_store_toolchain_digest\\00" string> } (__init__.mojo:939)\n'
        "==1==    by 0x40EF45F: _toolchain_identity (store.mojo:790)\n"
    )
    """Two frames copied from the CI log this defect was diagnosed from.

    The ESC is the real payload, in the real position: immediately before the
    quoted type name inside `#kgen.instref<...>`. The frames name `store.mojo`
    rather than `src/mtest/session/store.mojo`, exactly as Memcheck rendered
    them, which is why `check_cli_provenance`'s product-frame rejection reads
    this record as a runtime allocation and passes it."""

    CLIENT_STDOUT = (
        "mtest 0.6.0 (fake_hostile_mojo.py)\n"
        "FAIL           hostile/test_hostile_report.mojo  0.03s\n"
        f"{valgrind_check.CLI_PROBE_ESCAPED_LINE}\n"
        "===== 0 passed, 1 failed, 0 skipped, builds: 1, cached: 0 "
        "(0 excluded, 0 not run) in 1.2s =====\n"
    )
    """What the console legitimately renders: every control byte escaped."""

    MEMCHECK_LOG = ValgrindCliProvenanceTests.CLEAN.replace(
        "==1==    by 0x2: runtime_init (libmojo.so)\n",
        "==1==    by 0x2: runtime_init (libmojo.so)\n" + MANGLED_GLOBAL_FRAME,
    )
    """A log that passes provenance on every count and still carries the ESC."""

    def _fake_run(self, client_stdout: str) -> Callable[..., object]:
        """Stand in for `run`, reproducing both capture shapes faithfully.

        With `--log-file` in the argv, Valgrind writes its diagnostics to that
        file and the pipe carries the client alone; without it, `run`'s
        `stderr=subprocess.STDOUT` returns both channels as one string. Driving
        the real `check_cli` through this makes the test sensitive to the
        wiring rather than to either checker in isolation.

        Args:
            client_stdout: What the wrapped client itself printed.

        Returns:
            A `run` replacement. Non-`valgrind` commands (the CLI build) return
            a clean, empty result.
        """

        def fake(
            command: list[str], **_kwargs: object
        ) -> subprocess.CompletedProcess[str]:
            if command[0] != "valgrind":
                return subprocess.CompletedProcess(
                    args=command, returncode=0, stdout=""
                )
            redirected = [arg for arg in command if arg.startswith("--log-file=")]
            if not redirected:
                return subprocess.CompletedProcess(
                    args=command,
                    returncode=valgrind_check.CLI_PROBE_EXIT,
                    stdout=client_stdout + self.MEMCHECK_LOG,
                )
            target = Path(redirected[0].removeprefix("--log-file="))
            target.write_text(self.MEMCHECK_LOG, encoding="utf-8")
            return subprocess.CompletedProcess(
                args=command,
                returncode=valgrind_check.CLI_PROBE_EXIT,
                stdout=client_stdout,
            )

        return fake

    def _drive_check_cli(self, client_stdout: str) -> str:
        """Run the real `check_cli` over the two-channel stand-in.

        Args:
            client_stdout: What the wrapped client itself printed.

        Returns:
            The diagnostic `check_cli` failed with. It always fails: the probe
            writes no state file, NDJSON, or JUnit report under a stand-in, and
            those assertions all sit AFTER the raw-byte scan, which is what
            makes the exact message the informative result.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(valgrind_check, "OUT", out),
                patch.object(valgrind_check, "CLI_BINARY", out / "mtest"),
                patch.object(valgrind_check, "CLI_SCRATCH", out / "cli"),
                patch.object(valgrind_check, "CLI_HOME", out / "home"),
                patch.object(valgrind_check, "run", self._fake_run(client_stdout)),
                self.assertRaises(SystemExit) as raised,
            ):
                valgrind_check.check_cli({})
        return str(raised.exception)

    def test_a_mangled_type_name_in_the_memcheck_log_is_not_a_client_byte(
        self,
    ) -> None:
        """The reported false positive: Valgrind's ESC read as mtest's."""
        message = self._drive_check_cli(self.CLIENT_STDOUT)

        self.assertNotIn("raw ESC", message)
        # Naming the state-file diagnostic proves the run reached the far side
        # of the raw-byte scan. Asserting only the absence of "raw ESC" would
        # also pass if `check_cli` had failed earlier and scanned nothing.
        self.assertIn("wrote no state file", message)

    def test_a_raw_escape_from_the_client_is_still_rejected(self) -> None:
        """The gate the fix must not weaken, driven through the same path."""
        hostile = self.CLIENT_STDOUT + "    | \x1b[2Jcleared-your-terminal\n"

        message = self._drive_check_cli(hostile)

        self.assertIn("emitted a raw ESC byte", message)

    def test_the_probe_run_is_the_only_redirected_lane(self) -> None:
        """Redirection is scoped to the CLI probe; every other lane is untouched.

        The controls, the native suites, and the seventeen product suites keep
        the combined capture their assertions read, so this stays one lane's
        change rather than a rewrite of how the gate captures output.
        """
        completed = subprocess.CompletedProcess(
            args=["valgrind"], returncode=0, stdout=""
        )
        recorded: list[list[str]] = []

        def recorder(command: list[str], **_kwargs: object) -> object:
            recorded.append(command)
            return completed

        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(valgrind_check, "OUT", out),
                patch.object(valgrind_check, "run", recorder),
            ):
                valgrind_check.valgrind(["prog"], {}, quiet_child=True)
                valgrind_check.valgrind(
                    ["prog"], {}, quiet_child=True, log_file=out / "probe.log"
                )

        plain, redirected = recorded
        self.assertFalse([arg for arg in plain if arg.startswith("--log-file")])
        self.assertIn(f"--log-file={out / 'probe.log'}", redirected)
        # Measured on valgrind-3.27.1: without this flag a fork child inherits
        # the log and writes its own records into the same file, since the
        # value carries no `%p`. The CLI lane is the one that forks.
        self.assertIn("--child-silent-after-fork=yes", redirected)

    def test_a_startup_failure_written_to_the_redirected_log_still_fails(
        self,
    ) -> None:
        """The startup diagnostic must follow the log, or it silently retires.

        Measured on valgrind-3.27.1: a fatal raised after command-line parsing,
        which is where the mandatory-redirection failure this probe exists for
        happens, is written to `--log-file` and leaves the wrapped process's
        pipe empty. Scanning `result.stdout` alone would turn every redirected
        startup failure into a confusing downstream rejection.
        """
        fatal = (
            "valgrind:  Fatal error at startup: a function redirection\n"
            "valgrind:  Possible fixes: install libc6-dbg\n"
        )
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            log = out / "probe.log"

            def fake(command: list[str], **_kwargs: object) -> object:
                log.write_text(fatal, encoding="utf-8")
                return subprocess.CompletedProcess(
                    args=command, returncode=1, stdout=""
                )

            with (
                patch.object(valgrind_check, "OUT", out),
                patch.object(valgrind_check, "run", fake),
                self.assertRaises(SystemExit) as raised,
            ):
                valgrind_check.valgrind(["prog"], {}, quiet_child=True, log_file=log)

            self.assertEqual((out / "startup-failure.log").read_text(), fatal)

        self.assertIn("install libc6-dbg", str(raised.exception))


class ValgrindMainProbeRosterTests(unittest.TestCase):
    """Pin that `main` performs the probes its closing banner claims.

    Every other test in this file calls a probe directly, and the only `main`
    cases stop at an empty-inventory guard, so deleting `check_cli(env)` from
    `main` left the whole suite green while the gate still exited 0 printing
    "+ 1 CLI reporter run".
    """

    EXPECTED_PROBES = ("controls", "native", "cli")

    def _main_with_recorded_probes(self) -> tuple[int, list[str], list[str], str]:
        performed: list[str] = []
        compiled: list[str] = []
        version = subprocess.CompletedProcess(
            args=["valgrind"], returncode=0, stdout="valgrind-3.27.1\n"
        )

        def probe(name: str) -> Callable[[dict[str, str]], None]:
            def run(_env: dict[str, str]) -> None:
                performed.append(name)

            return run

        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp) / "valgrind"
            with (
                patch.object(valgrind_check, "OUT", out),
                patch.object(valgrind_check, "TESTS", (Path("tests/unit/a.mojo"),)),
                patch.object(
                    valgrind_check, "NATIVE_TESTS", (Path("tests/native/a.c"),)
                ),
                patch.object(valgrind_check, "prepare_test_scratch", lambda: None),
                patch.object(valgrind_check, "clean_environment", dict),
                patch.object(valgrind_check, "run", lambda *_a, **_k: version),
                patch.object(valgrind_check, "compile_inputs", lambda _cc, _env: None),
                patch.object(valgrind_check, "check_controls", probe("controls")),
                patch.object(valgrind_check, "check_native_tests", probe("native")),
                patch.object(valgrind_check, "check_cli", probe("cli")),
                patch.object(
                    valgrind_check,
                    "compile_and_run_test",
                    lambda source, _env: compiled.append(source.name),
                ),
                patch.object(native_abi_check, "compiler", lambda: "clang"),
            ):
                with contextlib.redirect_stdout(io.StringIO()) as captured:
                    code = valgrind_check.main()
                summary = (out / "summary.log").read_text(encoding="utf-8")
        return code, performed, compiled, summary + captured.getvalue()

    def test_main_runs_every_probe_once_in_order(self) -> None:
        code, performed, compiled, _text = self._main_with_recorded_probes()

        self.assertEqual(code, 0)
        self.assertEqual(tuple(performed), self.EXPECTED_PROBES)
        self.assertEqual(compiled, ["a.mojo"])

    def test_the_banner_only_claims_probes_that_ran(self) -> None:
        _code, performed, _compiled, text = self._main_with_recorded_probes()

        self.assertIn("cli", performed)
        self.assertIn("Real-CLI reporter run", text)
        self.assertIn("+ 1 CLI reporter run", text)


class LeakRecordParseTests(unittest.TestCase):
    """The compensating control must not be able to pass by matching nothing."""

    HEALTHY = (
        "==1== 40 bytes in 2 blocks are still reachable in loss record 1 of 2\n"
        "==1==    at 0x4: malloc (vg_replace_malloc.c:1)\n"
        "==1==    by 0x5: something (elsewhere.c:9)\n"
        "==1== 8 bytes in 1 blocks are possibly lost in loss record 2 of 2\n"
        "==1==    at 0x4: malloc (vg_replace_malloc.c:1)\n"
        "==1==    by 0x6: other (other.c:9)\n"
        "==1== LEAK SUMMARY:\n"
    )

    def test_records_are_returned_when_the_wording_is_intact(self) -> None:
        records = valgrind_check.leak_records(
            self.HEALTHY, "possibly lost|still reachable", "probe"
        )
        self.assertEqual(len(records), 2)

    def test_drifted_record_wording_fails_closed(self) -> None:
        drifted = self.HEALTHY.replace("still reachable", "STILL-REACHABLE")
        drifted = drifted.replace("possibly lost", "MAYBE-LOST")
        with self.assertRaisesRegex(SystemExit, "record parse found nothing"):
            valgrind_check.leak_records(
                drifted, "possibly lost|still reachable", "probe"
            )


class LeakRecordsCallSiteTests(unittest.TestCase):
    """Pin that both leak scans route through the fail-closed helper.

    `leak_records` failing closed protects nothing if a caller reverts to a
    bare `re.findall`, which returns `[]` on drifted wording and skips the
    record loop silently. The helper's own tests call it directly and cannot
    see that, so these two drive the real callers with the helper replaced by
    a recorder.
    """

    REACHABLE_LOG = (
        "==1== 78,596 bytes in 10 blocks are still reachable in loss record 1 of 1\n"
        "==1==    at 0x1: malloc (vg_replace_malloc.c:1)\n"
        "==1==    by 0x2: runtime_init (libmojo.so)\n"
        "==1== LEAK SUMMARY:\n"
        "==1==    still reachable: 78,596 bytes in 10 blocks\n"
    )

    def test_parse_reachable_routes_through_leak_records(self) -> None:
        seen: list[str] = []

        def _recorder(_log: str, _kinds: str, label: str) -> list[str]:
            seen.append(label)
            return []

        source = Path("tests/unit/test_example.mojo")
        with patch.object(valgrind_check, "leak_records", _recorder):
            valgrind_check.parse_reachable(self.REACHABLE_LOG, source)
        self.assertEqual(seen, [source.name])

    def test_cli_provenance_routes_through_leak_records(self) -> None:
        seen: list[str] = []

        def _recorder(_log: str, _kinds: str, label: str) -> list[str]:
            seen.append(label)
            return []

        with patch.object(valgrind_check, "leak_records", _recorder):
            valgrind_check.check_cli_provenance(
                valgrind_check.CLI_PROBE_EXIT, ValgrindCliProvenanceTests.CLEAN
            )
        self.assertEqual(seen, ["CLI artifact probe"])


if __name__ == "__main__":
    unittest.main()
