"""Resolved-configuration display E2E scenario."""

from __future__ import annotations

import os
from pathlib import Path
import tempfile
import tomllib

from scripts.e2e.assertions import expect, expect_exit
from scripts.e2e.runner import E2ERunner, ScenarioContext


def _runner(context: ScenarioContext, root: Path) -> E2ERunner:
    """Build a guarded runner rooted at one transient project."""
    return E2ERunner(
        repo_root=root,
        mtest=context.runner.mtest,
        default_timeout=context.runner.default_timeout,
        short_timeout=context.runner.short_timeout,
    )


def s_config_show(context: ScenarioContext) -> str:
    """Prove resolution-only config display through the real binary."""
    with tempfile.TemporaryDirectory(prefix="mtest-config-show-") as raw:
        root = Path(raw)
        configured_mojo = root / "must-not-run-mojo"
        config = root / "mtest.toml"
        config.write_text(
            "[run]\n"
            'paths = ["missing-tests"]\n'
            'exclude = ["quoted\\\\path"]\n'
            "state = true\n"
            "\n"
            "[build]\n"
            'mojo = "file-mojo"\n'
            'precompile = ["src/a", "src/b:out/b"]\n'
            "\n"
            "[report]\n"
            'color = "auto"\n'
            "\n"
            "[[override]]\n"
            'files = "tests/gpu_*"\n'
            "timeout = 3\n",
            encoding="utf-8",
        )
        runner = _runner(context, root)
        shown = runner.run_mtest(
            ["config", "show", "--timeout", "7", "--lf"],
            env_overrides={
                "MTEST_MOJO": os.fspath(configured_mojo),
                "NO_COLOR": "1",
            },
        )
        expect_exit(shown, 0)
        expect(shown.stderr == "", f"config show wrote stderr:\n{shown.stderr}")
        document = tomllib.loads(shown.stdout)
        expect(
            document["run"]["paths"] == ["missing-tests"],
            f"file paths did not round-trip:\n{shown.stdout}",
        )
        expect(
            document["run"]["timeout"] == 7,
            f"CLI timeout did not round-trip:\n{shown.stdout}",
        )
        expect(
            document["build"]["mojo"] == os.fspath(configured_mojo),
            f"environment mojo did not round-trip:\n{shown.stdout}",
        )
        expect(
            document["build"]["precompile"] == ["src/a", "src/b:out/b"],
            f"precompile values did not round-trip:\n{shown.stdout}",
        )
        expect(
            document["override"]
            == [{"files": "tests/gpu_*", "timeout": 3}],
            f"override did not round-trip:\n{shown.stdout}",
        )
        for fragment in (
            'paths = ["missing-tests"]  # (mtest.toml)',
            "timeout = 7  # (cli)",
            f'mojo = "{configured_mojo}"  # (env MTEST_MOJO)',
            "workers = 1  # (default)",
            'color = "auto"  # (mtest.toml; NO_COLOR active in this environment)',
            "# junit-xml = (unset)",
            "# json = (unset)",
            "# config file: mtest.toml",
            "# state file: .mtest-cache/lastrun (absent)",
            "# selection flags are per invocation and are not rendered",
        ):
            expect(fragment in shown.stdout, f"missing {fragment!r}:\n{shown.stdout}")
        expect(
            "last-failed" not in shown.stdout and "\nlf =" not in shown.stdout,
            f"--lf leaked into rendered configuration:\n{shown.stdout}",
        )
        expect(
            not (root / ".mtest-cache").exists(),
            "config show created or wrote last-run state",
        )
        selected = runner.run_mtest(
            [
                "config",
                "show",
                "--no-config",
                "plain-tests",
                "tests/test_math.mojo::test_add",
            ],
            env_overrides={"MTEST_MOJO": ""},
        )
        expect_exit(selected, 0)
        expect(
            'paths = ["plain-tests"]  # (cli)' in selected.stdout
            and "tests/test_math.mojo::test_add" not in selected.stdout,
            f"node id leaked or plain path disappeared:\n{selected.stdout}",
        )

        report_only = runner.run_mtest(
            [
                "config",
                "show",
                "--no-config",
                "--json",
                "missing/events.ndjson",
                "--junit-xml",
                "missing/junit.xml",
            ],
            env_overrides={"MTEST_MOJO": ""},
        )
        expect_exit(report_only, 0)
        expect(
            'json = "missing/events.ndjson"  # (cli)' in report_only.stdout
            and 'junit-xml = "missing/junit.xml"  # (cli)'
            in report_only.stdout,
            f"missing-parent report paths did not render:\n{report_only.stdout}",
        )
        expect(
            not (root / "missing").exists(),
            "config show validated or initialized a report destination parent",
        )
        expect_exit(
            runner.run_mtest(["--json", "missing/events.ndjson"]),
            4,
        )
        expect_exit(
            runner.run_mtest(["--junit-xml", "missing/junit.xml"]),
            4,
        )

        state = root / ".mtest-cache" / "lastrun"
        state.parent.mkdir()
        malformed_state = "not-a-state\nbad\n"
        state.write_text(malformed_state, encoding="utf-8")
        present = runner.run_mtest(["config", "show"])
        expect_exit(present, 0)
        expect(
            "# state file: .mtest-cache/lastrun (present)" in present.stdout,
            f"present state was not reported:\n{present.stdout}",
        )
        expect(
            "state:" not in present.stderr,
            f"config show parsed malformed state:\n{present.stderr}",
        )
        expect(
            state.read_text(encoding="utf-8") == malformed_state,
            "config show mutated malformed state",
        )

        disabled = runner.run_mtest(
            ["config", "show", "--no-config"],
            env_overrides={"MTEST_MOJO": ""},
        )
        expect_exit(disabled, 0)
        expect(
            "# config file: none" in disabled.stdout
            and "missing-tests" not in disabled.stdout,
            f"--no-config did not suppress discovery:\n{disabled.stdout}",
        )

        malformed = root / "bad.toml"
        malformed.write_text("[run]\ntimeout = nope\n", encoding="utf-8")
        shown_bad = runner.run_mtest(
            ["config", "show", "--config", os.fspath(malformed)]
        )
        run_bad = runner.run_mtest(["--config", os.fspath(malformed)])
        expect_exit(shown_bad, 4)
        expect_exit(run_bad, 4)
        expect(
            shown_bad.stdout == run_bad.stdout == ""
            and shown_bad.stderr == run_bad.stderr,
            "malformed config show diagnostic differed from an ordinary run",
        )

        missing = root / "missing.toml"
        shown_missing = runner.run_mtest(
            ["config", "show", "--config", os.fspath(missing)]
        )
        run_missing = runner.run_mtest(["--config", os.fspath(missing)])
        expect_exit(shown_missing, 4)
        expect_exit(run_missing, 4)
        expect(
            shown_missing.stderr == run_missing.stderr,
            "missing config show diagnostic differed from an ordinary run",
        )

    with tempfile.TemporaryDirectory(prefix="mtest-config-show-empty-") as raw:
        empty_runner = _runner(context, Path(raw))
        config_free = empty_runner.run_mtest(
            ["config", "show"],
            env_overrides={"MTEST_MOJO": "", "PYTHONHOME": "/nonexistent"},
        )
        expect_exit(config_free, 0)
        expect(
            "# config file: none" in config_free.stdout,
            f"config-free display failed under invalid PYTHONHOME:\n"
            f"{config_free.combined}",
        )

    return "TOML round-trip, provenance, resolution-only behavior, and state probe"
