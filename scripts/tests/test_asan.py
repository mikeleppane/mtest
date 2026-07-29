#!/usr/bin/env python3
"""Unit tests for the ASan gate's classified-suite compilation."""

from __future__ import annotations

import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
from typing import TYPE_CHECKING
import unittest
from unittest.mock import patch

from scripts.checks import native_abi as native_abi_check
from scripts.checks.memory import asan as asan_check


if TYPE_CHECKING:
    from collections.abc import Callable


class AsanCheckTests(unittest.TestCase):
    def test_repository_root_is_exact(self) -> None:
        self.assertEqual(asan_check.ROOT, Path(__file__).resolve().parents[2])

    def test_source_inventory_is_nonempty_and_exact(self) -> None:
        self.assertEqual(
            tuple(
                path.relative_to(asan_check.ROOT).as_posix()
                for path in asan_check.TESTS
            ),
            (
                "tests/integration/test_exec_capture.mojo",
                "tests/integration/test_exec_env.mojo",
                "tests/integration/test_exec_flood.mojo",
                "tests/integration/test_exec_timeout.mojo",
                "tests/integration/test_exec_interrupt.mojo",
                "tests/integration/test_exec_etxtbsy.mojo",
                "tests/integration/test_exec_reap.mojo",
                "tests/integration/test_exec_fdhygiene.mojo",
                "tests/integration/test_exec_pool.mojo",
                "tests/integration/test_session_schedule.mojo",
                "tests/integration/test_session_schedule_serial.mojo",
                "tests/unit/test_report_escape.mojo",
                "tests/unit/test_report_json_reporter.mojo",
                "tests/unit/test_report_junit.mojo",
                "tests/unit/test_report_junit_finalize.mojo",
            ),
        )
        self.assertGreater(len(asan_check.TESTS), 0)

    def test_empty_source_inventory_is_rejected(self) -> None:
        with (
            patch.object(asan_check, "TESTS", ()),
            self.assertRaisesRegex(SystemExit, "source inventory is empty"),
        ):
            asan_check.main()

    def test_classified_suite_builds_source_directly(self) -> None:
        """The ASan lane builds `source` itself, with no generated wrapper.

        Every classified module declares its own `main()` now, so there is no
        `*_main.mojo` wrapper and no `import tests.unit.<module>` alias to
        assert on.
        """
        source = asan_check.ROOT / "tests" / "unit" / "test_config.mojo"
        expected = asan_check.test_count(source)
        results = [
            subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout=""),
            subprocess.CompletedProcess(args=["nm"], returncode=0, stdout="__asan_"),
            subprocess.CompletedProcess(
                args=["test_config"],
                returncode=0,
                stdout=f"{expected} tests run: {expected} passed\n",
            ),
        ]
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(asan_check, "OUT", out),
                patch.object(asan_check, "run", side_effect=results) as mocked_run,
            ):
                asan_check.compile_and_run_test(source, {})

            compile_command = mocked_run.call_args_list[0].args[0]
            self.assertIn(str(source.relative_to(asan_check.ROOT)), compile_command)
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

    def test_a_suite_build_gets_the_compile_budget_not_the_run_budget(self) -> None:
        """Compiling a suite and running it are budgeted separately.

        A `mojo build` of a suite importing `mtest.session` compiles the whole
        session and cache closure, far more work than running the built binary.
        Sharing one budget forces a choice between killing a healthy compiler
        and letting a hung binary sit.
        """
        source = asan_check.ROOT / "tests" / "unit" / "test_config.mojo"
        expected = asan_check.test_count(source)
        results = [
            subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout=""),
            subprocess.CompletedProcess(args=["nm"], returncode=0, stdout="__asan_"),
            subprocess.CompletedProcess(
                args=["test_config"],
                returncode=0,
                stdout=f"{expected} tests run: {expected} passed\n",
            ),
        ]
        with tempfile.TemporaryDirectory() as raw_tmp:
            with (
                patch.object(asan_check, "OUT", Path(raw_tmp)),
                patch.object(asan_check, "run", side_effect=results) as mocked_run,
            ):
                asan_check.compile_and_run_test(source, {})

            self.assertEqual(
                mocked_run.call_args_list[0].kwargs.get("timeout"),
                asan_check.BUILD_TIMEOUT,
                "the suite build must carry the compile budget",
            )
            self.assertIsNone(
                mocked_run.call_args_list[2].kwargs.get("timeout"),
                "running the built binary must keep the tighter default budget",
            )

    def test_every_mojo_build_shares_one_compile_budget(self) -> None:
        """One number covers every compile in the lane, so growth trips none of them.

        The budget guards against a wedged compiler, so it is sized well above
        the slowest observed build rather than tuned per call site.
        """
        self.assertGreater(asan_check.BUILD_TIMEOUT, 180)

    def test_production_smoke_builds_only_the_exec_probe(self) -> None:
        results = [
            subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout=""),
            subprocess.CompletedProcess(args=["nm"], returncode=0, stdout="__asan_"),
            subprocess.CompletedProcess(
                args=["exec_probe"],
                returncode=0,
                stdout="1 tests run: 1 passed\n",
            ),
        ]
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(asan_check, "OUT", out),
                patch.object(asan_check, "run", side_effect=results) as mocked_run,
            ):
                asan_check.check_production_exec({})

            compile_command = mocked_run.call_args_list[0].args[0]
            self.assertIn("--sanitize", compile_command)
            self.assertIn("address", compile_command)
            self.assertIn("-I", compile_command)
            self.assertIn("src", compile_command)
            self.assertIn("tests/support", compile_command)
            self.assertIn(
                "tests/dogfood/exec_probe.mojo",
                compile_command,
            )
            self.assertIn(
                str(asan_check.NATIVE_PRODUCTION_OBJECT),
                compile_command,
            )
            self.assertNotIn("src/main.mojo", compile_command)
            self.assertFalse(
                any(
                    "vendor" in argument or argument == "toml"
                    for argument in compile_command
                )
            )


class AsanCliProbeTests(unittest.TestCase):
    """The instrumented real-CLI reporter run and the fixtures it depends on."""

    def test_cli_probe_inventory_is_exact(self) -> None:
        self.assertEqual(
            asan_check.CLI_SOURCE.relative_to(asan_check.ROOT).as_posix(),
            "src/main.mojo",
        )
        self.assertEqual(
            asan_check.VENDORED_TOML_INCLUDE.relative_to(asan_check.ROOT).as_posix(),
            "vendor/mojo-toml",
        )
        self.assertEqual(
            asan_check.HOSTILE_BUILD_STANDIN.relative_to(asan_check.ROOT).as_posix(),
            "scripts/fixtures/toolchain/fake_hostile_mojo.py",
        )
        self.assertEqual(
            asan_check.HOSTILE_ACTOR.relative_to(asan_check.ROOT).as_posix(),
            "tests/fixtures/exec/hostile_report_actor.py",
        )
        self.assertTrue(asan_check.HOSTILE_BUILD_STANDIN.is_file())
        self.assertTrue(asan_check.HOSTILE_ACTOR.is_file())

    def test_cli_probe_command_is_the_fixed_reporter_run(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp)
            command = asan_check.cli_probe_command(scratch / "mtest", scratch)

        self.assertEqual(command[0], str(scratch / "mtest"))
        self.assertEqual(command[1:3], ["--config", str(scratch / "mtest.toml")])
        self.assertIn("--mojo", command)
        mojo_index = command.index("--mojo")
        self.assertEqual(command[mojo_index + 1], str(asan_check.HOSTILE_BUILD_STANDIN))
        json_index = command.index("--json")
        self.assertEqual(
            command[json_index + 1], str(scratch / asan_check.CLI_PROBE_STREAM)
        )
        junit_index = command.index("--junit-xml")
        self.assertEqual(
            command[junit_index + 1], str(scratch / asan_check.CLI_PROBE_REPORT)
        )
        self.assertNotIn("--collect-only", command)

    def test_cli_probe_tree_carries_config_and_one_module(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp)
            asan_check.write_cli_probe_tree(scratch)

            config = (scratch / "mtest.toml").read_text(encoding="utf-8")
            self.assertIn('show-output = "all"', config)
            self.assertIn('color = "never"', config)
            self.assertIn("state = true", config)
            module = scratch / asan_check.CLI_PROBE_TREE / asan_check.CLI_PROBE_MODULE
            self.assertTrue(module.is_file())
            self.assertIn("TestSuite", module.read_text(encoding="utf-8"))

    def test_uninstrumented_cli_binary_is_rejected(self) -> None:
        results = [
            subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout=""),
            subprocess.CompletedProcess(
                args=["nm"], returncode=0, stdout="__libc_start_main\n"
            ),
        ]
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(asan_check, "OUT", out),
                patch.object(asan_check, "CLI_BINARY", out / "mtest"),
                patch.object(asan_check, "CLI_SCRATCH", out / "cli"),
                patch.object(asan_check, "run", side_effect=results),
                self.assertRaisesRegex(SystemExit, "ASan CLI is not instrumented"),
            ):
                asan_check.check_cli({})

    def test_check_cli_actually_calls_the_instrumentation_check(self) -> None:
        """The witness must be ON the call path, not merely defined.

        Every other test driving `check_cli` patches `check_cli_instrumentation`
        out, so without this one the control could be deleted from `check_cli`
        and the suite would stay green.
        """
        results = [
            subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout=""),
            subprocess.CompletedProcess(args=["nm"], returncode=0, stdout="__asan_"),
            subprocess.CompletedProcess(
                args=["mtest"],
                returncode=asan_check.CLI_PROBE_EXIT,
                stdout="a clean-looking run that never announced a leak check\n",
            ),
        ]
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(asan_check, "OUT", out),
                patch.object(asan_check, "CLI_BINARY", out / "mtest"),
                patch.object(asan_check, "CLI_SCRATCH", out / "cli"),
                patch.object(asan_check, "run", side_effect=results),
                patch.object(asan_check, "check_cli_probe_output", return_value="ok"),
                self.assertRaisesRegex(SystemExit, "leak check did not run"),
            ):
                asan_check.check_cli({})

    def test_a_run_without_the_leak_check_witness_is_rejected(self) -> None:
        """A silent run and a clean run must not be the same observation.

        The `__asan_` symbol guard is static: it proves linkage only. Without
        the witness, a probe whose leak check never ran passes every artifact
        assertion.
        """
        with self.assertRaisesRegex(SystemExit, "leak check did not run"):
            asan_check.check_cli_instrumentation("0 passed, 1 failed\n")

    def test_a_clean_witnessed_run_is_accepted(self) -> None:
        asan_check.check_cli_instrumentation(f"==1=={asan_check.CLI_LSAN_WITNESS}\n")

    def test_a_sanitizer_finding_is_rejected_even_with_the_witness(
        self,
    ) -> None:
        witnessed = f"==1=={asan_check.CLI_LSAN_WITNESS}\n"
        with self.assertRaisesRegex(SystemExit, "reported an ASan error"):
            asan_check.check_cli_instrumentation(
                witnessed + "==1==ERROR: AddressSanitizer: heap-use-after-free\n"
            )
        with self.assertRaisesRegex(SystemExit, "reported a leak"):
            asan_check.check_cli_instrumentation(
                witnessed + "==1==LeakSanitizer: detected memory leaks\n"
            )

    def test_the_probe_asks_for_the_witness_without_weakening_lsan(self) -> None:
        """`main` pops `LSAN_OPTIONS`; the probe puts back verbosity, only.

        A suppression file or a disabled detector smuggled in here would make
        the lane green for the wrong reason, so the value is pinned whole.
        """
        self.assertEqual(asan_check.CLI_PROBE_LSAN_OPTIONS, "verbosity=1")
        self.assertIn("detect_leaks=1", asan_check.ASAN_OPTIONS)

        results = [
            subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout=""),
            subprocess.CompletedProcess(args=["nm"], returncode=0, stdout="__asan_"),
            subprocess.CompletedProcess(
                args=["mtest"], returncode=asan_check.CLI_PROBE_EXIT, stdout=""
            ),
        ]
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            with (
                patch.object(asan_check, "OUT", out),
                patch.object(asan_check, "CLI_BINARY", out / "mtest"),
                patch.object(asan_check, "CLI_SCRATCH", out / "cli"),
                patch.object(asan_check, "run", side_effect=results) as mocked_run,
                patch.object(asan_check, "check_cli_instrumentation"),
                patch.object(asan_check, "check_cli_probe_output", return_value="ok"),
            ):
                asan_check.check_cli({"ASAN_OPTIONS": asan_check.ASAN_OPTIONS})

            probe_env = mocked_run.call_args_list[2].kwargs["env"]

        self.assertEqual(probe_env["LSAN_OPTIONS"], asan_check.CLI_PROBE_LSAN_OPTIONS)
        self.assertEqual(probe_env["ASAN_OPTIONS"], asan_check.ASAN_OPTIONS)

    def test_cli_probe_build_compiles_main_against_the_vendored_parser(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp)
            results = [
                subprocess.CompletedProcess(args=["mojo"], returncode=0, stdout=""),
                subprocess.CompletedProcess(
                    args=["nm"], returncode=0, stdout="__asan_"
                ),
                subprocess.CompletedProcess(
                    args=["mtest"], returncode=asan_check.CLI_PROBE_EXIT, stdout=""
                ),
            ]
            with (
                patch.object(asan_check, "OUT", out),
                patch.object(asan_check, "CLI_BINARY", out / "mtest"),
                patch.object(asan_check, "CLI_SCRATCH", out / "cli"),
                patch.object(asan_check, "run", side_effect=results) as mocked_run,
                patch.object(asan_check, "check_cli_instrumentation"),
                patch.object(asan_check, "check_cli_probe_output", return_value="ok"),
            ):
                asan_check.check_cli({})

            compile_command = mocked_run.call_args_list[0].args[0]
            self.assertIn("--sanitize", compile_command)
            self.assertIn("address", compile_command)
            self.assertIn("src/main.mojo", compile_command)
            self.assertIn(str(asan_check.VENDORED_TOML_INCLUDE), compile_command)
            self.assertIn(str(asan_check.NATIVE_PRODUCTION_OBJECT), compile_command)
            self.assertEqual(mocked_run.call_args_list[2].kwargs["cwd"], out / "cli")


class AsanCliProbeOracleTests(unittest.TestCase):
    """The probe's artifact judgment, one named rejection per failure mode."""

    def _tree(self, scratch: Path) -> None:
        asan_check.write_cli_probe_tree(scratch)
        (scratch / ".mtest-cache").mkdir(parents=True, exist_ok=True)
        (scratch / ".mtest-cache" / "lastrun").write_text("", encoding="utf-8")
        (scratch / asan_check.CLI_PROBE_STREAM).write_text(
            '{"event":"stream","version":1}\n'
            '{"event":"session_finished","exit_code":1}\n',
            encoding="utf-8",
        )
        (scratch / asan_check.CLI_PROBE_REPORT).write_text(
            self.REPORT.format(total=1), encoding="utf-8"
        )

    REPORT = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<testsuites name="mtest" tests="{total}" failures="1" errors="0">\n'
        '<testsuite name="s" tests="1" failures="1" errors="0" skipped="0"'
        ' time="0.0"><testcase name="t" classname="c">'
        "<failure>boom</failure></testcase></testsuite>\n"
        "</testsuites>\n"
    )
    """One accepted JUnit document, parameterized on the root `tests` total so a
    mutation of that one number is the only difference between the accepted and
    rejected cases below."""

    def test_wrong_client_exit_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp)
            self._tree(scratch)
            with self.assertRaisesRegex(SystemExit, "exited 0, expected 1"):
                asan_check.check_cli_probe_output(
                    0, asan_check.CLI_PROBE_ESCAPED_LINE, scratch, "ASan"
                )

    def test_missing_escaped_console_line_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp)
            self._tree(scratch)
            with self.assertRaisesRegex(SystemExit, "escaped hostile line"):
                asan_check.check_cli_probe_output(
                    asan_check.CLI_PROBE_EXIT, "nothing hostile here", scratch, "ASan"
                )

    def test_raw_control_byte_on_the_console_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp)
            self._tree(scratch)
            stdout = asan_check.CLI_PROBE_ESCAPED_LINE + "\x1b[0m"
            with self.assertRaisesRegex(SystemExit, "raw ESC"):
                asan_check.check_cli_probe_output(
                    asan_check.CLI_PROBE_EXIT, stdout, scratch, "ASan"
                )

    def test_missing_promoted_state_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp)
            self._tree(scratch)
            (scratch / ".mtest-cache" / "lastrun").unlink()
            with self.assertRaisesRegex(SystemExit, "state file"):
                asan_check.check_cli_probe_output(
                    asan_check.CLI_PROBE_EXIT,
                    asan_check.CLI_PROBE_ESCAPED_LINE,
                    scratch,
                    "ASan",
                )

    def test_corrupt_stream_is_rejected_by_the_strict_consumer(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp)
            self._tree(scratch)
            (scratch / asan_check.CLI_PROBE_STREAM).write_text(
                '{"event":"stream","version":1}\n{"event":"forged"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SystemExit, "strict NDJSON consumer"):
                asan_check.check_cli_probe_output(
                    asan_check.CLI_PROBE_EXIT,
                    asan_check.CLI_PROBE_ESCAPED_LINE,
                    scratch,
                    "ASan",
                )

    def test_invalid_report_is_rejected_by_the_junit_oracle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp)
            self._tree(scratch)
            (scratch / asan_check.CLI_PROBE_REPORT).write_text(
                self.REPORT.format(total=9), encoding="utf-8"
            )
            with self.assertRaisesRegex(SystemExit, "JUnit oracle"):
                asan_check.check_cli_probe_output(
                    asan_check.CLI_PROBE_EXIT,
                    asan_check.CLI_PROBE_ESCAPED_LINE,
                    scratch,
                    "ASan",
                )

    def test_clean_probe_output_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            scratch = Path(raw_tmp)
            self._tree(scratch)
            detail = asan_check.check_cli_probe_output(
                asan_check.CLI_PROBE_EXIT,
                asan_check.CLI_PROBE_ESCAPED_LINE,
                scratch,
                "ASan",
            )

        self.assertIn("NDJSON", detail)
        self.assertIn("JUnit", detail)


class AsanMainProbeRosterTests(unittest.TestCase):
    """Pin that `main` performs the probes its closing banner claims.

    Every other test in this file calls a probe directly, and the only `main`
    cases stop at the empty-inventory guard, so deleting `check_cli(env)` from
    `main` left the whole suite green while the gate still exited 0 printing
    "+ 1 CLI reporter run".
    """

    EXPECTED_PROBES = ("controls", "production-exec", "cli")

    def _main_with_recorded_probes(self) -> tuple[int, list[str], list[str], str]:
        performed: list[str] = []
        compiled: list[str] = []

        def probe(name: str) -> Callable[[dict[str, str]], None]:
            def run(env: dict[str, str]) -> None:
                performed.append(name)
                self.assertIn("ASAN_OPTIONS", env)

            return run

        with tempfile.TemporaryDirectory() as raw_tmp:
            out = Path(raw_tmp) / "asan"
            with (
                patch.object(asan_check, "OUT", out),
                patch.object(asan_check, "TESTS", (Path("tests/unit/a.mojo"),)),
                patch.object(asan_check, "compile_native", lambda _cc: None),
                patch.object(asan_check, "check_controls", probe("controls")),
                patch.object(
                    asan_check, "check_production_exec", probe("production-exec")
                ),
                patch.object(asan_check, "check_cli", probe("cli")),
                patch.object(
                    asan_check,
                    "compile_and_run_test",
                    lambda source, _env: compiled.append(source.name),
                ),
                patch.object(native_abi_check, "compiler", lambda: "clang"),
            ):
                with contextlib.redirect_stdout(io.StringIO()) as captured:
                    code = asan_check.main()
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
        self.assertIn("ASan real-CLI reporter run", text)
        self.assertIn("+ 1 CLI reporter run", text)


if __name__ == "__main__":
    unittest.main()
