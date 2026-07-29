"""Project-config discovery, diagnostics, state, and override E2E scenarios."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
from typing import Any

from scripts.e2e.assertions import expect, expect_exit
from scripts.e2e.runner import (
    CONFIG_OPEN_FAULT,
    DEFAULT_TIMEOUT,
    FAKE_WINDOW_MOJO,
    REPO_ROOT,
    SHORT_TIMEOUT,
    STATE_PERSISTENCE_FAULT,
    E2ERunner,
    Run,
    ScenarioContext,
    ScenarioError,
)
from scripts.e2e.scenarios.json_reporter import (
    _build_json_terminal_write_fault,
)


PROJECT = Path(REPO_ROOT, "e2e", "config_project")
STATE_PATH = PROJECT / ".mtest-cache" / "lastrun"
MARKER_PATH = PROJECT / "state-pass-marker"
STATE_HEADER = "mtest-lastrun v1\n"
STATE_FAILURE = (
    STATE_HEADER + "test\ttests/test_stateful.mojo::test_marker_controls_outcome\n"
)
TOML_SOURCE_MAX_BYTES = 4 * 1024 * 1024
TOML_SCALAR_MAX_BYTES = 1024 * 1024
TOML_TABLE_UPDATE_MAX = 512


def _project_runner(context: ScenarioContext) -> E2ERunner:
    return E2ERunner(
        repo_root=PROJECT,
        mtest=context.runner.mtest,
        default_timeout=context.runner.default_timeout,
        short_timeout=context.runner.short_timeout,
    )


def _clean_project_runtime() -> None:
    if MARKER_PATH.exists():
        MARKER_PATH.unlink()
    shutil.rmtree(PROJECT / ".mtest-cache", ignore_errors=True)
    shutil.rmtree(PROJECT / "build", ignore_errors=True)


def _started_record(stream_path: Path) -> dict[str, Any]:
    records: list[dict[str, Any]] = [
        json.loads(line)
        for line in stream_path.read_text(encoding="utf-8").splitlines()
    ]
    for record in records:
        if record.get("event") == "session_started":
            return record
    raise AssertionError(f"no session_started record in {stream_path}")


def _run_stream(
    runner: E2ERunner, args: list[str], stream_path: Path
) -> tuple[Run, dict[str, Any]]:
    run = runner.run_mtest(
        [*args, "--json", os.fspath(stream_path), "--gh-annotations", "off"]
    )
    return run, _started_record(stream_path)


def _assert_parser_resource_guards(context: ScenarioContext, tmp: Path) -> None:
    """Exercise parser termination and cost guards through the real binary."""
    assignment_boundary = tmp / "assignment-limit.toml"
    assignment_boundary.write_text(
        "".join(f"key{index} = 0\n" for index in range(TOML_TABLE_UPDATE_MAX)),
        encoding="utf-8",
    )
    boundary = context.runner.run_mtest(
        ["--config", os.fspath(assignment_boundary)], timeout=5.0
    )
    expect_exit(boundary, 4)
    expect(
        "table-update limit" not in boundary.stderr,
        f"the exact assignment ceiling was rejected:\n{boundary.combined[:1_024]}",
    )
    header_boundary = tmp / "table-header-limit.toml"
    header_boundary.write_text(
        "".join(f"[table{index}]\n" for index in range(TOML_TABLE_UPDATE_MAX)),
        encoding="utf-8",
    )
    boundary = context.runner.run_mtest(
        ["--config", os.fspath(header_boundary)], timeout=5.0
    )
    expect_exit(boundary, 4)
    expect(
        "table-update limit" not in boundary.stderr,
        f"the exact table-header ceiling was rejected:\n{boundary.combined[:1_024]}",
    )
    nested_arrays = tmp / "multiline-nested-arrays.toml"
    nested_arrays.write_text(
        "[run]\npaths = " + ("[\n" * 64) + '"value"\n' + ("]\n" * 64),
        encoding="utf-8",
    )
    boundary = context.runner.run_mtest(
        ["--config", os.fspath(nested_arrays)], timeout=5.0
    )
    expect_exit(boundary, 4)
    expect(
        "table-update limit" not in boundary.stderr
        and "nesting limit" not in boundary.stderr,
        f"line-leading nested arrays were misclassified:\n{boundary.combined[:1_024]}",
    )

    guarded_documents = (
        (
            "long-bare-token.toml",
            b"[run]\n" + (b"x" * (TOML_SCALAR_MAX_BYTES + 1)) + b" = 1\n",
            "1048576-byte limit",
        ),
        (
            "long-quoted-token.toml",
            b'[run]\npaths = ["' + (b"x" * (TOML_SCALAR_MAX_BYTES + 1)) + b'"]\n',
            "1048576-byte limit",
        ),
        (
            "assignment-limit-plus-one.toml",
            "".join(
                f"key{index} = 0\n" for index in range(TOML_TABLE_UPDATE_MAX + 1)
            ).encode(),
            "table-update limit",
        ),
        (
            "table-header-limit-plus-one.toml",
            "".join(
                f"[table{index}]\n" for index in range(TOML_TABLE_UPDATE_MAX + 1)
            ).encode(),
            "table-update limit",
        ),
        (
            "long-float-token.toml",
            b"[run]\ntimeout = "
            + (b"1" * (TOML_SCALAR_MAX_BYTES // 2))
            + b"."
            + (b"1" * (TOML_SCALAR_MAX_BYTES // 2))
            + b"\n",
            "1048576-byte limit",
        ),
    )
    for name, contents, expected in guarded_documents:
        path = tmp / name
        path.write_bytes(contents)
        run = context.runner.run_mtest(["--config", os.fspath(path)], timeout=5.0)
        expect_exit(run, 4)
        expect(
            expected in run.stderr,
            f"parser resource guard drifted for {name}:\n{run.combined[:1_024]}",
        )

    for name, character in (
        ("unexpected-at.toml", "@"),
        ("unexpected-backtick.toml", "`"),
        ("unexpected-punctuation.toml", "?"),
    ):
        path = tmp / name
        path.write_text(character, encoding="utf-8")
        run = context.runner.run_mtest(["--config", os.fspath(path)], timeout=2.0)
        expect_exit(run, 4)
        expect(
            "line 1, column 1" in run.stderr,
            f"unexpected TOML byte lost its position for {name}:\n{run.combined}",
        )


def s_config_resolution(context: ScenarioContext) -> str:
    """Discovery, explicit paths, precedence, every key, and stream identity."""
    _clean_project_runtime()
    runner = _project_runner(context)
    try:
        with tempfile.TemporaryDirectory(prefix="mtest-config-resolution-") as raw:
            tmp = Path(raw)

            auto, auto_started = _run_stream(
                runner, ["tests/test_other.mojo"], tmp / "auto.ndjson"
            )
            expect_exit(auto, 0)
            expect(
                auto_started.get("config_file") == "mtest.toml",
                f"automatic config representation drifted: {auto_started}",
            )

            inside, inside_started = _run_stream(
                runner,
                ["--config", "configs/inside.toml"],
                tmp / "inside.ndjson",
            )
            expect_exit(inside, 0)
            expect(
                inside_started.get("config_file") == "configs/inside.toml",
                f"inside config representation drifted: {inside_started}",
            )

            outside_arg = "../config_shared/./shared.toml"
            outside, outside_started = _run_stream(
                runner,
                ["--config", outside_arg],
                tmp / "outside.ndjson",
            )
            expect_exit(outside, 0)
            outside_expected = os.path.normpath(os.path.join(PROJECT, outside_arg))
            expect(
                outside_started.get("config_file") == outside_expected,
                f"outside config was not normalized absolute: "
                f"{outside_started} expected={outside_expected!r}",
            )

            disabled, disabled_started = _run_stream(
                runner,
                ["--no-config", "tests/test_other.mojo"],
                tmp / "disabled.ndjson",
            )
            expect_exit(disabled, 0)
            expect(
                disabled_started.get("config_file") == "",
                f"--no-config did not serialize empty identity: {disabled_started}",
            )

            # CLI operands replace [run] paths, rather than extending them.
            replaced = runner.run_mtest(["tests/test_other.mojo"])
            expect_exit(replaced, 0)
            expect(
                "tests/test_stateful.mojo" not in replaced.stdout,
                f"config paths leaked beside the CLI operand:\n{replaced.stdout}",
            )

            bad_mojo = tmp / "bad-mojo.toml"
            bad_mojo.write_text(
                '[run]\npaths = ["tests/test_other.mojo"]\nstate = false\n'
                '[build]\nmojo = "/definitely/missing/mojo"\n',
                encoding="utf-8",
            )
            from_env = runner.run_mtest(
                ["--config", os.fspath(bad_mojo)],
                env_overrides={"MTEST_MOJO": "mojo"},
            )
            expect_exit(from_env, 0)
            from_cli = runner.run_mtest(
                ["--config", os.fspath(bad_mojo), "--mojo", "mojo"]
            )
            expect_exit(from_cli, 0)

            junit_path = tmp / "all-keys.xml"
            json_path = tmp / "all-keys.ndjson"
            complete = tmp / "all-keys.toml"
            complete.write_text(
                "[run]\n"
                'paths = ["tests/test_other.mojo"]\n'
                "exclude = []\n"
                "gates = []\n"
                "serial = []\n"
                "workers = 1\n"
                "timeout = 30\n"
                "retries = 0\n"
                "maxfail = 0\n"
                "state = false\n"
                "[build]\n"
                'mojo = "mojo"\n'
                "include = []\n"
                "build-args = []\n"
                "precompile = []\n"
                "compile-timeout = 60\n"
                "[report]\n"
                'color = "never"\n'
                'show-output = "none"\n'
                'verbosity = "quiet"\n'
                "durations = 0\n"
                f"junit-xml = {json.dumps(os.fspath(junit_path))}\n"
                f"json = {json.dumps(os.fspath(json_path))}\n"
                'gh-annotations = "off"\n'
                "[[override]]\n"
                'files = "tests/test_other.mojo"\n'
                "timeout = 30\n"
                "compile-timeout = 60\n"
                "retries = 0\n"
                "serial = true\n",
                encoding="utf-8",
            )
            every_key = runner.run_mtest(["--config", os.fspath(complete)])
            expect_exit(every_key, 0)
            expect(
                junit_path.exists() and json_path.exists(),
                "the all-keys config did not reach both report destinations",
            )

            # An explicitly empty list replaces the lower value like every other
            # list key. Discovery once read it as "no paths given" and reopened
            # the default tree, so a project that meant to select nothing ran
            # its whole suite.
            empty_paths = tmp / "empty-paths.toml"
            empty_paths.write_text(
                "[run]\npaths = []\nstate = false\n", encoding="utf-8"
            )
            emptied = runner.run_mtest(["--config", os.fspath(empty_paths)])
            expect_exit(emptied, 5)
            expect(
                "selected: 0 files" in emptied.stdout,
                f"configured empty paths still selected files:\n{emptied.stdout}",
            )
    finally:
        _clean_project_runtime()
    return "root/inside/outside/disabled identity + precedence + all keys"


def s_config_diagnostics(context: ScenarioContext) -> str:
    """Absent-file behavior and stable explicit/malformed failure classes."""
    with tempfile.TemporaryDirectory(prefix="mtest-config-diag-") as raw:
        tmp = Path(raw)
        _assert_parser_resource_guards(context, tmp)

        absent_run = context.runner.run_mtest(["e2e/suite/test_passing.mojo"])
        expect_exit(absent_run, 0)
        absent_collect = context.runner.run_mtest(
            ["collect", "e2e/collect/test_probe_ok.mojo"],
        )
        expect_exit(absent_collect, 0)
        expect(
            "config:" not in absent_run.combined
            and "config:" not in absent_collect.combined,
            "an absent implicit config emitted a config diagnostic:\n"
            f"run={absent_run.combined}\ncollect={absent_collect.combined}",
        )

        conflict = context.runner.run_mtest(
            ["--config", "elsewhere.toml", "--no-config"]
        )
        expect_exit(conflict, 4)
        missing = context.runner.run_mtest(
            ["--config", os.fspath(tmp / "missing.toml")]
        )
        expect_exit(missing, 4)
        unreadable = context.runner.run_mtest(["--config", os.fspath(tmp)])
        expect_exit(unreadable, 4)
        fifo = tmp / "blocking-config.toml"
        os.mkfifo(fifo)
        blocked = context.runner.run_mtest(["--config", os.fspath(fifo)], timeout=30.0)
        expect_exit(blocked, 4)
        expect(
            blocked.stdout == ""
            and blocked.stderr
            == f"config: {fifo}: configuration path is not a regular file\n",
            f"FIFO config path was not rejected before opening:\n{blocked.combined}",
        )
        with tempfile.TemporaryDirectory(
            prefix="mtest-config-open-fault-"
        ) as fault_root:
            library = _build_config_open_fault(fault_root)
            loader = (
                "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD"
            )
            inherited = os.environ.get(loader, "")
            preload = library + (os.pathsep + inherited if inherited else "")
            swapped = tmp / "swapped-before-open.toml"
            swapped.write_text("[run]\ntimeout = 1\n", encoding="utf-8")
            raced = context.runner.run_mtest(
                ["--config", os.fspath(swapped)],
                timeout=5.0,
                env_overrides={
                    loader: preload,
                    "MTEST_CONFIG_SWAP_PATH": os.fspath(swapped),
                },
            )
            expect_exit(raced, 4)
            expect(
                raced.stdout == ""
                and raced.stderr
                == (f"config: {swapped}: configuration path is not a regular file\n"),
                "a regular-to-FIFO pathname swap was not rejected from the "
                f"opened descriptor:\n{raced.combined}",
            )

        malformed = tmp / "malformed.toml"
        malformed.write_text("[run\n", encoding="utf-8")
        malformed_run = context.runner.run_mtest(["--config", os.fspath(malformed)])
        expect_exit(malformed_run, 4)
        expect(
            malformed_run.stderr.startswith("config: "),
            f"malformed config lost owned framing:\n{malformed_run.stderr}",
        )

        hostile_documents = (
            (
                "oversized.toml",
                "[run]\ntimeout = 999999999999999999999999999999999999\n",
            ),
            ("negative.toml", "[run]\nretries = -1\n"),
            ("bool-int.toml", "[run]\nmaxfail = true\n"),
            ("float.toml", "[run]\nworkers = 1.5\n"),
            (
                "nested-run-array.toml",
                '[run]\npaths = ["ok", ["nested"]]\n',
            ),
            ("table-run-array.toml", "[[run.paths]]\nvalue = 1\n"),
            ("unknown-run-table.toml", "[run.nested]\nvalue = 1\n"),
            (
                "build-bool-int.toml",
                "[build]\ncompile-timeout = true\n",
            ),
            (
                "datetime.toml",
                "[build]\nmojo = 1979-05-27T07:32:00Z\n",
            ),
            (
                "nested-build-array.toml",
                '[build]\ninclude = ["ok", { nested = true }]\n',
            ),
            (
                "hostile-build-value.toml",
                (
                    "[build]\n"
                    'build-args = ["-o=SENTINEL\\nFAIL config: forged'
                    '\\u001b\\u0003"]\n'
                ),
            ),
            ("report-negative.toml", "[report]\ndurations = -1\n"),
            ("report-float.toml", "[report]\ncolor = 1.5\n"),
            (
                "report-table-array.toml",
                "[report]\nverbosity = [{ nested = true }]\n",
            ),
            ("unknown-report-key.toml", "[report]\nunknown = 1\n"),
            ("empty-overrides.toml", "override = []\n"),
            (
                "empty-override-files.toml",
                "[[override]]\nfiles = []\ntimeout = 1\n",
            ),
            (
                "nested-override-files.toml",
                '[[override]]\nfiles = ["ok", ["nested"]]\ntimeout = 1\n',
            ),
            (
                "oversized-override.toml",
                (
                    '[[override]]\nfiles = "*"\n'
                    "timeout = 999999999999999999999999999999999999\n"
                ),
            ),
            ("malformed\nFAIL config: forged\x1b.toml", "[run\n"),
            (
                "duplicate.toml",
                "[run]\ntimeout = 1\ntimeout = 2\n",
            ),
        )
        for name, text in hostile_documents:
            hostile_path = tmp / name
            hostile_path.write_text(text, encoding="utf-8")
            hostile = context.runner.run_mtest(["--config", os.fspath(hostile_path)])
            expect_exit(hostile, 4)
            lines = hostile.stderr.splitlines()
            expect(
                hostile.stdout == ""
                and 1 <= len(lines) <= 2
                and "\nFAIL config: forged" not in hostile.stderr
                and "\x1b" not in hostile.stderr
                and "\x01" not in hostile.stderr
                and "\x02" not in hostile.stderr
                and "\x03" not in hostile.stderr,
                f"hostile TOML escaped owned diagnostics for {name!r}:\n"
                f"{hostile.combined}",
            )

        for name, contents in (
            ("invalid-utf8.toml", b'[run]\ntimeout = "\xff"\n'),
            ("embedded-nul.toml", b"[run]\ntimeout = 1\x00\n"),
            (
                "large-malformed.toml",
                b"[run]\n" + (b"x" * (2 * 1024 * 1024)),
            ),
        ):
            arbitrary_path = tmp / name
            arbitrary_path.write_bytes(contents)
            arbitrary = context.runner.run_mtest(
                ["--config", os.fspath(arbitrary_path)], timeout=30.0
            )
            expect_exit(arbitrary, 4)
            expect(
                arbitrary.stdout == ""
                and arbitrary.stderr.startswith(f"config: {arbitrary_path}: ")
                and len(arbitrary.stderr) < 1_024
                and "Traceback" not in arbitrary.stderr,
                f"arbitrary config bytes escaped containment for {name}:\n"
                f"{arbitrary.combined}",
            )

        exact_limit = tmp / "exact-source-limit.toml"
        exact_limit.write_bytes(b" " * TOML_SOURCE_MAX_BYTES)
        exact = context.runner.run_mtest(
            [
                "--config",
                os.fspath(exact_limit),
                "e2e/suite/test_passing.mojo",
            ],
            timeout=120.0,
        )
        expect_exit(exact, 0)

        oversized_source = tmp / "source-limit-plus-one.toml"
        oversized_source.write_bytes(b" " * (TOML_SOURCE_MAX_BYTES + 1))
        oversized = context.runner.run_mtest(
            ["--config", os.fspath(oversized_source)], timeout=30.0
        )
        expect_exit(oversized, 4)
        expect(
            oversized.stdout == ""
            and oversized.stderr
            == (
                f"config: {oversized_source}: configuration file exceeds "
                f"{TOML_SOURCE_MAX_BYTES}-byte limit\n"
            ),
            f"oversized source lost its owned limit diagnostic:\n{oversized.combined}",
        )

        zero_device = Path("/dev/zero")
        if zero_device.exists():
            unbounded = context.runner.run_mtest(
                ["--config", os.fspath(zero_device)], timeout=30.0
            )
            expect_exit(unbounded, 4)
            expect(
                unbounded.stdout == ""
                and unbounded.stderr
                == "config: /dev/zero: configuration path is not a regular file\n",
                f"device config path was not rejected before opening:\n"
                f"{unbounded.combined}",
            )

        missing_parent_config = tmp / "missing-parent.toml"
        missing_parent_config.write_text(
            '[report]\njson = "definitely-missing/events.ndjson"\n'
            'gh-annotations = "off"\n',
            encoding="utf-8",
        )
        missing_parent = context.runner.run_mtest(
            [
                "--config",
                os.fspath(missing_parent_config),
                "e2e/suite/test_passing.mojo",
            ]
        )
        expect_exit(missing_parent, 4)
        expect(
            missing_parent.stderr.startswith(
                "config: "
                + os.fspath(missing_parent_config)
                + ": [report] json destination parent directory does not "
                "exist:"
            ),
            "a configured report destination must be named where it was set, "
            "not as a '--json' flag the reader never typed:\n"
            f"{missing_parent.stderr}",
        )

        missing_junit_parent_config = tmp / "missing-junit-parent.toml"
        missing_junit_parent_config.write_text(
            '[report]\njunit-xml = "definitely-missing/report.xml"\n',
            encoding="utf-8",
        )
        missing_junit_parent = context.runner.run_mtest(
            [
                "--config",
                os.fspath(missing_junit_parent_config),
                "e2e/suite/test_passing.mojo",
            ]
        )
        expect_exit(missing_junit_parent, 4)
        expect(
            missing_junit_parent.stderr.startswith(
                "config: "
                + os.fspath(missing_junit_parent_config)
                + ": [report] junit-xml destination parent directory does not "
                "exist:"
            ),
            "a configured JUnit destination must be named where it was set, "
            "not as a '--junit-xml' flag the reader never typed:\n"
            f"{missing_junit_parent.stderr}",
        )

        project_runner = _project_runner(context)
        no_config_run = project_runner.run_mtest(
            ["--no-config", "tests/test_other.mojo"]
        )
        expect_exit(no_config_run, 0)
        no_config_collect = project_runner.run_mtest(
            ["collect", "--no-config", "tests/test_other.mojo"],
        )
        expect_exit(no_config_collect, 0)

        collect = project_runner.run_mtest(
            ["collect", "--config", "configs/collect-report.toml"]
        )
        expect_exit(collect, 0)
        expect(
            "tests/test_other.mojo::test_other_passes" in collect.stdout,
            f"collect ignored the active configured path:\n{collect.stdout}",
        )
    _clean_project_runtime()
    return "native TOML diagnostics, bounded inputs, and non-regular paths"


def _read_state() -> str:
    return STATE_PATH.read_text(encoding="utf-8")


def _write_state(text: str) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(text, encoding="utf-8")


def _build_state_persistence_fault(directory: str) -> str:
    """Build the test-only state-persistence interposer in `directory`."""
    compiler = os.environ.get("CC", "clang")
    object_path = os.path.join(directory, "mtest_state_persistence_fault.o")
    compile_command = [
        compiler,
        "-std=c17",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        "-fPIC",
        "-c",
        STATE_PERSISTENCE_FAULT,
        "-o",
        object_path,
    ]
    if sys.platform == "darwin":
        library = os.path.join(directory, "libmtest_state_persistence_fault.dylib")
        link_command = [
            "/usr/bin/cc",
            "-dynamiclib",
            object_path,
            "-o",
            library,
        ]
    else:
        library = os.path.join(directory, "libmtest_state_persistence_fault.so")
        link_command = [
            compiler,
            "-shared",
            object_path,
            "-o",
            library,
            "-ldl",
        ]
    for action, command in (
        ("compile", compile_command),
        ("link", link_command),
    ):
        process = subprocess.Popen(
            command,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        try:
            output, _ = process.communicate(timeout=SHORT_TIMEOUT)
        except subprocess.TimeoutExpired as exc:
            E2ERunner.kill_group(process)
            output, _ = process.communicate()
            raise ScenarioError(
                "the state-persistence fault interposer did not "
                f"{action} within {SHORT_TIMEOUT}s:\n{output}"
            ) from exc
        expect(
            process.returncode == 0,
            "could not "
            f"{action} the state-persistence fault interposer "
            f"({process.returncode}):\n{output}",
        )
    return library


def _build_config_open_fault(directory: str) -> str:
    """Build the test-only configuration-open interposer in `directory`."""
    compiler = os.environ.get("CC", "clang")
    object_path = os.path.join(directory, "mtest_config_open_fault.o")
    compile_command = [
        compiler,
        "-std=c17",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        "-fPIC",
        "-c",
        CONFIG_OPEN_FAULT,
        "-o",
        object_path,
    ]
    if sys.platform == "darwin":
        library = os.path.join(directory, "libmtest_config_open_fault.dylib")
        link_command = ["/usr/bin/cc", "-dynamiclib", object_path, "-o", library]
    else:
        library = os.path.join(directory, "libmtest_config_open_fault.so")
        link_command = [
            compiler,
            "-shared",
            object_path,
            "-o",
            library,
            "-ldl",
        ]
    for action, command in (("compile", compile_command), ("link", link_command)):
        process = subprocess.Popen(
            command,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        try:
            output, _ = process.communicate(timeout=SHORT_TIMEOUT)
        except subprocess.TimeoutExpired as exc:
            E2ERunner.kill_group(process)
            output, _ = process.communicate()
            raise ScenarioError(
                "the configuration-open fault interposer did not "
                f"{action} within {SHORT_TIMEOUT}s:\n{output}"
            ) from exc
        expect(
            process.returncode == 0,
            "could not "
            f"{action} the configuration-open fault interposer "
            f"({process.returncode}):\n{output}",
        )
    return library


def s_config_state(context: ScenarioContext) -> str:
    """Live delta, preservation, warning, and post-finalization write policy."""
    _clean_project_runtime()
    runner = _project_runner(context)
    try:
        failed = runner.run_mtest([])
        expect_exit(failed, 1)
        expect(
            _read_state() == STATE_FAILURE,
            f"failing test did not produce the exact state record:\n{_read_state()}",
        )

        MARKER_PATH.write_text("pass\n", encoding="utf-8")
        passed = runner.run_mtest([])
        expect_exit(passed, 0)
        expect(
            _read_state() == STATE_HEADER,
            f"passing rerun did not clear the exact test record:\n{_read_state()}",
        )

        sentinel = STATE_HEADER + "file\tpreserve.mojo\n"
        _write_state(sentinel)
        preserved = runner.run_mtest(["tests/test_other.mojo"])
        expect_exit(preserved, 0)
        expect(
            _read_state() == sentinel,
            "a successful unfiltered run discarded a prior record outside "
            "its selected file",
        )

        _write_state("not-a-state\nbad\n")
        with tempfile.TemporaryDirectory(prefix="mtest-state-disabled-") as raw:
            stream = Path(raw, "disabled.ndjson")
            disabled = runner.run_mtest(
                [
                    "--config",
                    "configs/inside.toml",
                    "--json",
                    os.fspath(stream),
                    "--gh-annotations",
                    "off",
                ]
            )
            expect_exit(disabled, 0)
            disabled_records = [
                json.loads(line)
                for line in stream.read_text(encoding="utf-8").splitlines()
            ]
            expect(
                not any(
                    row.get("event") == "warning"
                    and row.get("warning_kind") == "state-malformed-line"
                    for row in disabled_records
                ),
                f"state=false read malformed prior state: {disabled_records}",
            )
            expect(
                _read_state() == "not-a-state\nbad\n",
                "state=false rewrote prior state",
            )

        _write_state("not-a-state\nbad\n")
        collect = runner.run_mtest(
            ["collect", "--config", "configs/collect-report.toml"]
        )
        expect_exit(collect, 0)
        expect(
            "state-malformed-line" not in collect.combined
            and "mtest: state:" not in collect.combined,
            f"collect read prior state:\n{collect.combined}",
        )
        expect(
            _read_state() == "not-a-state\nbad\n",
            "collect rewrote last-run state",
        )

        _write_state(sentinel)
        nothing = runner.run_mtest(["tests/test_zero.mojo"])
        expect_exit(nothing, 5)
        expect(_read_state() == sentinel, "exit 5 rewrote last-run state")

        sharded = runner.run_mtest(["tests/test_other.mojo", "--shard", "1/1"])
        expect_exit(sharded, 0)
        expect(_read_state() == sentinel, "sharded invocation rewrote state")

        internal = runner.run_mtest(
            ["tests/test_other.mojo", "--mojo", "/definitely/missing/mojo"]
        )
        expect_exit(internal, 3)
        expect(_read_state() == sentinel, "exit 3 rewrote last-run state")

        usage = runner.run_mtest(["missing-test-file.mojo"])
        expect_exit(usage, 4)
        expect(_read_state() == sentinel, "exit 4 rewrote last-run state")

        interrupt_probe = PROJECT / "interrupt_probe.mojo"
        interrupt_probe.write_text(
            '"""Transient E2E actor: stay live until mtest receives SIGINT."""\n'
            "from std.time import sleep\n"
            "from std.testing import TestSuite\n\n"
            "def test_waits_for_interrupt() raises:\n"
            "    while True:\n"
            "        sleep(3600.0)\n\n"
            "def main() raises:\n"
            "    TestSuite.discover_tests[__functions_in_module()]().run()\n",
            encoding="utf-8",
        )
        try:
            interrupted, _pgid = runner.run_mtest_signaled(
                [
                    "interrupt_probe.mojo",
                    "--timeout",
                    "60",
                    "--color",
                    "never",
                ],
                signal_number=signal.SIGINT,
                delay=8.0,
                timeout=60.0,
            )
        finally:
            interrupt_probe.unlink(missing_ok=True)
        expect_exit(interrupted, 2)
        expect(_read_state() == sentinel, "exit 2 rewrote last-run state")

        _write_state("not-a-state\nbad\n")
        with tempfile.TemporaryDirectory(prefix="mtest-state-warning-") as raw:
            stream = Path(raw, "warning.ndjson")
            warned = runner.run_mtest(
                [
                    "tests/test_other.mojo",
                    "--json",
                    os.fspath(stream),
                    "--gh-annotations",
                    "off",
                ]
            )
            expect_exit(warned, 0)
            records = [
                json.loads(line)
                for line in stream.read_text(encoding="utf-8").splitlines()
            ]
            warnings = [
                row
                for row in records
                if row.get("event") == "warning"
                and row.get("warning_kind") == "state-malformed-line"
            ]
            expect(
                bool(warnings),
                f"malformed state emitted no state-malformed-line: {records}",
            )

        collision_probe = PROJECT / "state_collision_probe.mojo"
        collision_probe.write_text(
            '"""Transient state-temp actor: leave time to plant a collision."""\n'
            "from std.time import sleep\n"
            "from std.testing import assert_true, TestSuite\n\n"
            "def test_waits_before_passing() raises:\n"
            "    sleep(2.0)\n"
            "    assert_true(True)\n\n"
            "def main() raises:\n"
            "    TestSuite.discover_tests[__functions_in_module()]().run()\n",
            encoding="utf-8",
        )
        try:
            for collision_kind in ("symlink", "hardlink"):
                victim = PROJECT / f"state-{collision_kind}-victim"
                victim.write_text("do-not-touch\n", encoding="utf-8")
                _write_state(STATE_HEADER)
                child = subprocess.Popen(
                    [
                        os.fspath(context.runner.mtest),
                        "--no-config",
                        collision_probe.name,
                        "--color",
                        "never",
                    ],
                    cwd=PROJECT,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    start_new_session=True,
                    env={**os.environ, "GITHUB_ACTIONS": ""},
                )
                collision = Path(os.fspath(STATE_PATH) + f".tmp.{child.pid}")
                try:
                    if collision_kind == "symlink":
                        collision.symlink_to(victim)
                    else:
                        os.link(victim, collision)
                    stdout, stderr = child.communicate(timeout=DEFAULT_TIMEOUT)
                except BaseException:
                    if child.poll() is None:
                        E2ERunner.kill_group(child)
                        child.wait(timeout=5)
                    raise
                finally:
                    if os.path.lexists(collision):
                        collision.unlink()
                expect(
                    child.returncode == 0,
                    f"{collision_kind} collision probe exited "
                    f"{child.returncode}:\n{stdout}\n{stderr}",
                )
                expect(
                    victim.read_text(encoding="utf-8") == "do-not-touch\n",
                    f"state writer followed a predictable {collision_kind}",
                )
                victim.unlink()
                expect(
                    not list(STATE_PATH.parent.glob("lastrun.tmp.*")),
                    f"state writer left a temporary after {collision_kind}",
                )
        finally:
            collision_probe.unlink(missing_ok=True)
            for victim in PROJECT.glob("state-*-victim"):
                victim.unlink(missing_ok=True)
            if STATE_PATH.is_symlink():
                STATE_PATH.unlink()

        persistence_diagnostic = "mtest: state: could not persist .mtest-cache/lastrun"
        with tempfile.TemporaryDirectory(
            prefix="mtest-state-persistence-fault-"
        ) as raw:
            library = _build_state_persistence_fault(raw)
            loader = (
                "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD"
            )
            inherited = os.environ.get(loader, "")
            preload = library + (os.pathsep + inherited if inherited else "")
            fault_sentinel = (
                STATE_HEADER + "test\ttests/test_other.mojo::test_other_passes\n"
            )
            for fault in ("short-eintr", "write", "close", "rename"):
                _write_state(fault_sentinel)
                faulted = runner.run_mtest(
                    [
                        "--no-config",
                        "tests/test_other.mojo",
                        "--color",
                        "never",
                    ],
                    env_overrides={
                        loader: preload,
                        "MTEST_STATE_FAULT": fault,
                    },
                )
                expect_exit(faulted, 0)
                if fault == "short-eintr":
                    expect(
                        _read_state() == STATE_HEADER,
                        "short-write/EINTR recovery did not publish the "
                        f"complete state:\n{_read_state()}",
                    )
                    expect(
                        persistence_diagnostic not in faulted.stderr,
                        "recovered short-write/EINTR emitted a persistence "
                        f"failure:\n{faulted.stderr}",
                    )
                else:
                    expect(
                        _read_state() == fault_sentinel,
                        f"{fault} failure damaged the prior state file",
                    )
                    expect(
                        faulted.stderr.splitlines() == [persistence_diagnostic],
                        f"{fault} failure did not emit exactly one stable "
                        f"diagnostic:\n{faulted.stderr}",
                    )
                expect(
                    not list(STATE_PATH.parent.glob("lastrun.tmp.*")),
                    f"{fault} path left an owned temporary behind",
                )

        promotion_sentinel = (
            STATE_HEADER + "test\ttests/test_other.mojo::test_other_passes\n"
        )
        _write_state(promotion_sentinel)
        original_mode = STATE_PATH.parent.stat().st_mode
        STATE_PATH.parent.chmod(0o500)
        try:
            promotion_failed = runner.run_mtest(["tests/test_other.mojo"])
        finally:
            STATE_PATH.parent.chmod(original_mode)
        expect_exit(promotion_failed, 0)
        expect(
            _read_state() == promotion_sentinel,
            "failed atomic promotion damaged the prior state file",
        )
        expect(
            promotion_failed.stderr.count(persistence_diagnostic) == 1,
            f"state write failure was not one post-finalization line:\n"
            f"{promotion_failed.stderr}",
        )

        # A terminal machine-stream failure resolves to 3 before state promotion.
        close_sentinel = (
            STATE_HEADER + "test\ttests/test_other.mojo::test_other_passes\n"
        )
        _write_state(close_sentinel)
        with tempfile.TemporaryDirectory(prefix="mtest-state-close-") as raw:
            tmp = Path(raw)
            stream = tmp / "stream.ndjson"
            library = _build_json_terminal_write_fault(raw)
            loader = (
                "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD"
            )
            inherited = os.environ.get(loader, "")
            preload = os.fspath(library) + (os.pathsep + inherited if inherited else "")
            terminal = runner.run_mtest(
                [
                    "--no-config",
                    "tests/test_other.mojo",
                    "--json",
                    os.fspath(stream),
                    "--gh-annotations",
                    "off",
                ],
                timeout=DEFAULT_TIMEOUT,
                env_overrides={loader: preload},
            )
            expect_exit(terminal, 3)
            expect(
                _read_state() == close_sentinel,
                "terminal delivery failure promoted state before final code 3",
            )

        # An unusable state path must never block the run. Before the guarded
        # bounded read was wired into the run path, a FIFO here blocked the
        # process forever: the read happens before the exec runtime exists, so
        # neither --timeout nor the interrupt handler covered it.
        STATE_PATH.unlink(missing_ok=True)
        os.mkfifo(STATE_PATH)
        try:
            fifo = runner.run_mtest(["tests/test_other.mojo"], timeout=DEFAULT_TIMEOUT)
            expect_exit(fifo, 0)
            expect(
                "not a regular file" in fifo.combined,
                f"a FIFO state path was not reported loudly:\n{fifo.combined}",
            )
        finally:
            STATE_PATH.unlink(missing_ok=True)

        _write_state(STATE_HEADER + "x" * (1024 * 1024 + 1) + "\n")
        oversized = runner.run_mtest(["tests/test_other.mojo"], timeout=DEFAULT_TIMEOUT)
        expect_exit(oversized, 0)
        expect(
            "exceeds the size limit" in oversized.combined,
            f"an oversized state file was not refused loudly:\n{oversized.combined}",
        )
    finally:
        _clean_project_runtime()
    return "live delta + 0/1 writes; 2/3/4/5/collect/shard disabled; atomic"


def _file_started_paths(stream_path: Path) -> list[str]:
    return [
        str(row["path"])
        for row in (
            json.loads(line)
            for line in stream_path.read_text(encoding="utf-8").splitlines()
        )
        if row.get("event") == "file_started"
    ]


def s_failure_reselection(context: ScenarioContext) -> str:
    """Last-failed filtering, failed-first bands, gates, and fallbacks."""
    _clean_project_runtime()
    runner = _project_runner(context)
    poison = PROJECT / "tests" / "test_poison_temp.mojo"
    truncate_a = PROJECT / "tests" / "test_a_truncate_temp.mojo"
    truncate_b = PROJECT / "tests" / "test_b_truncate_temp.mojo"
    try:
        red = runner.run_mtest([])
        expect_exit(red, 1)
        MARKER_PATH.write_text("pass\n", encoding="utf-8")
        poison.write_text(
            '"""Transient poison: proves --lf narrows the ordinary set."""\n'
            "from std.testing import assert_true, TestSuite\n\n"
            "def test_must_not_run() raises:\n"
            "    assert_true(False)\n\n"
            "def main() raises:\n"
            "    TestSuite.discover_tests[__functions_in_module()]().run()\n",
            encoding="utf-8",
        )
        narrowed = runner.run_mtest(["tests", "--lf"])
        expect_exit(narrowed, 0)
        expect(
            "test_poison_temp.mojo" not in narrowed.combined,
            f"--lf ran the non-remembered poison:\n{narrowed.combined}",
        )
        poison.unlink()

        _write_state(
            STATE_HEADER
            + "file\ttests/gone.mojo\n"
            + "test\ttests/test_other.mojo::test_gone\n"
            + "test\ttests/test_other.mojo::test_other_passes\n"
        )
        with tempfile.TemporaryDirectory(prefix="mtest-lf-warnings-") as raw:
            stream = Path(raw, "warnings.ndjson")
            stale = runner.run_mtest(
                [
                    "tests/test_other.mojo",
                    "--lf",
                    "--json",
                    os.fspath(stream),
                    "--gh-annotations",
                    "off",
                ]
            )
            expect_exit(stale, 0)
            for identifier in (
                "tests/gone.mojo",
                "tests/test_other.mojo::test_gone",
            ):
                line = f"lf: previously-failing {identifier} no longer exists — dropped"
                expect(
                    stale.combined.count(line) == 1,
                    f"stale identifier was not one exact line: {identifier}\n"
                    f"{stale.combined}",
                )
            warning_kinds = {
                row.get("warning_kind")
                for row in (
                    json.loads(line)
                    for line in stream.read_text(encoding="utf-8").splitlines()
                )
                if row.get("event") == "warning"
            }
            expect(
                "lf-stale" in warning_kinds,
                f"JSON stream missed lf-stale: {warning_kinds}",
            )

        fallback = (
            "lf: no previously-failing tests match this selection — "
            "running the full selection"
        )
        STATE_PATH.unlink()
        missing_state = runner.run_mtest(["tests/test_other.mojo", "--lf"])
        expect_exit(missing_state, 0)
        expect(
            missing_state.combined.count(fallback) == 1,
            f"missing state did not fall back once:\n{missing_state.combined}",
        )

        _write_state(
            STATE_HEADER
            + "file\ttests/all-gone.mojo\n"
            + "test\ttests/test_other.mojo::test_all_gone\n"
        )
        all_stale = runner.run_mtest(["tests/test_other.mojo", "--lf"])
        expect_exit(all_stale, 0)
        expect(
            all_stale.combined.count("no longer exists — dropped") == 2
            and all_stale.combined.count(fallback) == 1,
            f"all-stale-only state did not drop and fall back:\n{all_stale.combined}",
        )

        _write_state(STATE_HEADER)
        with tempfile.TemporaryDirectory(prefix="mtest-lf-empty-") as raw:
            stream = Path(raw, "empty.ndjson")
            empty = runner.run_mtest(
                [
                    "tests/test_other.mojo",
                    "--lf",
                    "--json",
                    os.fspath(stream),
                    "--gh-annotations",
                    "off",
                ]
            )
            expect_exit(empty, 0)
            expect(
                empty.combined.count(fallback) == 1,
                f"empty state did not fall back once:\n{empty.combined}",
            )
            rows = [
                json.loads(line)
                for line in stream.read_text(encoding="utf-8").splitlines()
            ]
            expect(
                any(
                    row.get("event") == "warning"
                    and row.get("warning_kind") == "lf-empty"
                    for row in rows
                ),
                f"JSON stream missed lf-empty: {rows}",
            )
        _write_state(STATE_HEADER)
        ff_empty = runner.run_mtest(["tests/test_other.mojo", "--ff"])
        expect_exit(ff_empty, 0)
        expect(
            ff_empty.combined.count(fallback) == 1,
            f"empty state did not fall back under --ff:\n{ff_empty.combined}",
        )

        _write_state("unknown-state\n")
        malformed = runner.run_mtest(["tests/test_other.mojo", "--lf"])
        expect_exit(malformed, 0)
        expect(
            fallback in malformed.combined
            and "state-malformed-line" in malformed.combined,
            f"malformed state did not warn and fall back:\n{malformed.combined}",
        )

        _write_state(STATE_HEADER + "test\ttests/test_other.mojo::test_other_passes\n")
        disabled = runner.run_mtest(
            [
                "--config",
                "configs/inside.toml",
                "tests/test_other.mojo",
                "--lf",
            ]
        )
        expect_exit(disabled, 0)
        disabled_line = "lf: state disabled by mtest.toml — running the full selection"
        expect(
            disabled.combined.count(disabled_line) == 1,
            f"state=false fallback did not name state:\n{disabled.combined}",
        )
        disabled_ff = runner.run_mtest(
            [
                "--config",
                "configs/inside.toml",
                "tests/test_other.mojo",
                "--ff",
            ]
        )
        expect_exit(disabled_ff, 0)
        expect(
            disabled_ff.combined.count(disabled_line) == 1,
            f"state=false fallback did not cover --ff:\n{disabled_ff.combined}",
        )

        _write_state(STATE_HEADER + "file\ttests/test_stateful.mojo\n")
        with tempfile.TemporaryDirectory(prefix="mtest-ff-order-") as raw:
            stream = Path(raw, "order.ndjson")
            ordered = runner.run_mtest(
                [
                    "tests",
                    "--ff",
                    "-n",
                    "2",
                    "--json",
                    os.fspath(stream),
                    "--gh-annotations",
                    "off",
                ]
            )
            expect_exit(ordered, 0)
            starts = _file_started_paths(stream)
            expect(
                starts[:2]
                == [
                    "tests/test_stateful.mojo",
                    "tests/test_other.mojo",
                ],
                f"--ff did not admit remembered parallel file first: {starts}",
            )

        with tempfile.TemporaryDirectory(prefix="mtest-ff-bands-") as raw:
            stream = Path(raw, "bands.ndjson")
            bands = runner.run_mtest(
                [
                    "tests",
                    "--ff",
                    "-n",
                    "2",
                    "--serial",
                    "*stateful*",
                    "--json",
                    os.fspath(stream),
                    "--gh-annotations",
                    "off",
                ]
            )
            expect_exit(bands, 0)
            starts = _file_started_paths(stream)
            expect(
                starts.index("tests/test_other.mojo")
                < starts.index("tests/test_stateful.mojo"),
                f"--ff moved a serial file into the parallel band: {starts}",
            )

        MARKER_PATH.unlink()
        _write_state(STATE_HEADER + "file\ttests/test_stateful.mojo\n")
        lf_keyword = runner.run_mtest(["tests", "-k", "other", "--lf"])
        expect_exit(lf_keyword, 0)
        expect(
            fallback in lf_keyword.combined,
            "--lf did not fall back to the ordinary -k selection on an "
            f"empty intersection:\n{lf_keyword.combined}",
        )

        _write_state(STATE_HEADER + "file\ttests/test_other.mojo\n")
        gate_lf = runner.run_mtest(
            [
                "tests/test_other.mojo",
                "--gate",
                "tests/test_stateful.mojo",
                "--lf",
            ]
        )
        expect_exit(gate_lf, 1)
        gate_ff = runner.run_mtest(
            [
                "tests/test_other.mojo",
                "--gate",
                "tests/test_stateful.mojo",
                "--ff",
            ]
        )
        expect_exit(gate_ff, 1)

        _write_state(STATE_HEADER)
        gate_empty = runner.run_mtest(
            [
                "tests/test_other.mojo",
                "--gate",
                "tests/test_stateful.mojo",
                "--lf",
            ]
        )
        expect_exit(gate_empty, 1)
        expect(
            gate_empty.combined.count(fallback) == 1,
            f"a failing gate suppressed the known-empty fallback:\n"
            f"{gate_empty.combined}",
        )

        gate_disabled = runner.run_mtest(
            [
                "--config",
                "configs/inside.toml",
                "tests/test_other.mojo",
                "--gate",
                "tests/test_stateful.mojo",
                "--lf",
            ]
        )
        expect_exit(gate_disabled, 1)
        expect(
            gate_disabled.combined.count(disabled_line) == 1,
            f"a failing gate suppressed the state-disabled fallback:\n"
            f"{gate_disabled.combined}",
        )

        _write_state(STATE_HEADER + "file\ttests/test_stateful.mojo\n")
        remembered_gate = runner.run_mtest(
            [
                "tests/test_other.mojo",
                "--gate",
                "tests/test_stateful.mojo",
                "--ff",
            ]
        )
        expect_exit(remembered_gate, 1)
        expect(
            "lf: previously-failing" not in remembered_gate.combined
            and fallback not in remembered_gate.combined,
            f"--ff treated a remembered gate as stale or empty:\n"
            f"{remembered_gate.combined}",
        )

        failing_source = (
            '"""Transient truncation-preservation actor."""\n'
            "from std.testing import assert_true, TestSuite\n\n"
            "def test_fails() raises:\n"
            "    assert_true(False)\n\n"
            "def main() raises:\n"
            "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
        )
        truncate_a.write_text(failing_source, encoding="utf-8")
        truncate_b.write_text(failing_source, encoding="utf-8")
        _write_state(
            STATE_HEADER
            + "file\ttests/test_a_truncate_temp.mojo\n"
            + "file\ttests/test_b_truncate_temp.mojo\n"
        )
        truncated = runner.run_mtest(
            [
                "--no-config",
                "tests/test_a_truncate_temp.mojo",
                "tests/test_b_truncate_temp.mojo",
                "--lf",
                "-x",
                "--color",
                "never",
            ]
        )
        expect_exit(truncated, 1)
        truncated_state = _read_state()
        expect(
            "file\ttests/test_b_truncate_temp.mojo\n" in truncated_state,
            f"--lf -x discarded the unverdicted B record:\n{truncated_state}",
        )
        expect(
            "test\ttests/test_a_truncate_temp.mojo::test_fails\n" in truncated_state,
            f"--lf -x did not replace A with its fresh failure:\n{truncated_state}",
        )
        truncate_a.unlink()
        truncate_b.unlink()

        MARKER_PATH.write_text("pass\n", encoding="utf-8")
        _write_state(STATE_HEADER + "file\ttests/test_stateful.mojo\n")
        with tempfile.TemporaryDirectory(prefix="mtest-ff-select-") as raw:
            stream = Path(raw, "selection.ndjson")
            composed = runner.run_mtest(
                [
                    "tests",
                    "-k",
                    "other",
                    "--ff",
                    "-n",
                    "2",
                    "--serial",
                    "*other*",
                    "--json",
                    os.fspath(stream),
                    "--gh-annotations",
                    "off",
                ]
            )
            expect_exit(composed, 0)
            started = _started_record(stream)
            expect(
                started.get("workers") == 1,
                f"selection-active --ff claimed pooled workers: {started}",
            )
            expect(
                _file_started_paths(stream)
                == [
                    "tests/test_stateful.mojo",
                    "tests/test_other.mojo",
                    "tests/test_zero.mojo",
                ],
                "-k composition did not use one failed-first sequential band: "
                f"{_file_started_paths(stream)}",
            )

        with tempfile.TemporaryDirectory(prefix="mtest-lf-no-config-") as raw:
            scratch = Path(raw)
            (scratch / ".mtest-cache").mkdir()
            (scratch / ".mtest-cache" / "lastrun").write_text(
                STATE_HEADER + "test\ttest_scratch.mojo::test_passes\n",
                encoding="utf-8",
            )
            (scratch / "test_scratch.mojo").write_text(
                '"""Config-free --lf laziness actor."""\n'
                "from std.testing import assert_true, TestSuite\n\n"
                "def test_passes() raises:\n"
                "    assert_true(True)\n\n"
                "def main() raises:\n"
                "    TestSuite.discover_tests[__functions_in_module()]().run()\n",
                encoding="utf-8",
            )
            scratch_runner = E2ERunner(
                repo_root=scratch,
                mtest=context.runner.mtest,
                default_timeout=context.runner.default_timeout,
                short_timeout=context.runner.short_timeout,
            )
            lazy = scratch_runner.run_mtest(
                ["--lf"], env_overrides={"PYTHONHOME": "/nonexistent"}
            )
            expect_exit(lazy, 0)
            expect(
                not (scratch / "mtest.toml").exists(),
                "the config-free --lf fixture grew a config file",
            )
    finally:
        poison.unlink(missing_ok=True)
        truncate_a.unlink(missing_ok=True)
        truncate_b.unlink(missing_ok=True)
        _clean_project_runtime()
    return "lf filter/fallback/stale + ff bands + gates + selection + laziness"


def _log_path(prefix: str) -> str:
    handle, path = tempfile.mkstemp(prefix=prefix, suffix=".tsv")
    os.close(handle)
    os.remove(path)
    return path


def _intervals(path: str, kind: str) -> dict[str, tuple[float, float]]:
    edges: dict[str, list[float]] = {}
    with open(path, encoding="utf-8") as source:
        for line in source:
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 3 and fields[0] == kind:
                edges.setdefault(fields[1], []).append(float(fields[2]))
    return {
        name: (values[0], values[-1])
        for name, values in edges.items()
        if len(values) >= 2
    }


def s_config_overrides(context: ScenarioContext) -> str:
    """Config override timeout kills and serial pins drain after parallel work."""
    with tempfile.TemporaryDirectory(prefix="mtest-config-overrides-") as raw:
        tmp = Path(raw)
        timeout_config = tmp / "timeout.toml"
        timeout_config.write_text(
            "[run]\n"
            'paths = ["e2e/slow/test_hanging.mojo"]\n'
            "timeout = 10\n"
            "state = false\n"
            "[[override]]\n"
            'files = "e2e/slow/test_hanging.mojo"\n'
            "timeout = 1\n",
            encoding="utf-8",
        )
        timed = context.runner.run_mtest(
            ["--config", os.fspath(timeout_config)], timeout=30.0
        )
        expect_exit(timed, 1)
        expect(
            "TIMEOUT" in timed.stdout and "1s" in timed.stdout,
            f"override timeout did not reach supervision:\n{timed.stdout}",
        )

        # collect must apply overrides too. main once passed the flattened
        # config here, selecting the compatibility overload that carries no
        # override tables, so the probe was bounded by the global deadline
        # alone, invisibly to a test that calls the resolved overload itself.
        # The hang must be in the fixture's main(), where --skip-all cannot
        # skip it; a body-level hang never reaches the probe.
        probe_config = tmp / "collect-timeout.toml"
        probe_config.write_text(
            "[run]\n"
            'paths = ["e2e/collect/test_probe_hang.mojo"]\n'
            "timeout = 20\n"
            "state = false\n"
            "[[override]]\n"
            'files = "e2e/collect/test_probe_hang.mojo"\n'
            "timeout = 1\n",
            encoding="utf-8",
        )
        collected = context.runner.run_mtest(
            ["collect", "--config", os.fspath(probe_config)], timeout=60.0
        )
        expect_exit(collected, 1)
        expect(
            "timed out" in collected.stderr,
            f"override timeout did not reach the collect probe:\n{collected.stderr}",
        )
        expect(
            collected.wall < 15.0,
            "collect probe ran to the global deadline, so the override was "
            f"dropped: {collected.wall:.2f}s",
        )

        build_log = _log_path("mtest_config_serial_build_")
        run_log = _log_path("mtest_config_serial_run_")
        serial_config = tmp / "serial.toml"
        serial_config.write_text(
            "[run]\n"
            'paths = ["e2e/parallel"]\n'
            "workers = 2\n"
            "state = false\n"
            "[build]\n"
            f"mojo = {json.dumps(FAKE_WINDOW_MOJO)}\n"
            "[report]\n"
            'gh-annotations = "off"\n'
            "[[override]]\n"
            'files = "e2e/parallel/test_window_c.mojo"\n'
            "serial = true\n",
            encoding="utf-8",
        )
        serial = context.runner.run_mtest(
            ["--config", os.fspath(serial_config)],
            timeout=240.0,
            env_overrides={
                "MTEST_WINDOW_LOG": build_log,
                "MTEST_WINDOW_RUN_LOG": run_log,
                "MTEST_WINDOW_BUILD_FLOOR": "0.6",
                "MTEST_WINDOW_RUN_FLOOR": "0.6",
            },
        )
        expect_exit(serial, 0)
        builds = _intervals(build_log, "build")
        runs = _intervals(run_log, "run")
        serial_path = "e2e/parallel/test_window_c.mojo"
        expect(serial_path in builds, f"no serial build window: {builds}")
        expect("c" in runs, f"no serial run window: {runs}")
        for name, window in builds.items():
            if name != serial_path:
                expect(
                    window[1] <= builds[serial_path][0],
                    f"serial build admitted before parallel drain: {builds}",
                )
        for name, window in runs.items():
            if name != "c":
                expect(
                    window[1] <= runs["c"][0],
                    f"serial run admitted before parallel drain: {runs}",
                )
    return "override timeout=1 killed; override serial=true drained serial-last"
